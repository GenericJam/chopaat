defmodule Chopaat.SessionTest do
  @moduledoc false

  # The session boundary, exercised headlessly: no screen, scene, or
  # throws module appears anywhere in this file — a renderer-free host
  # (auto-play bots, the machine API) drives games exactly this way.
  use ExUnit.Case, async: true

  alias Chopaat.Game
  alias Chopaat.Session
  alias Chopaat.Setup
  alias Chopaat.Support.Craft
  alias Chopaat.Support.Fixtures

  @max_commands 20_000

  defp start_session(opts) do
    {:ok, session} = Session.start_link(opts)
    session
  end

  # A per-test scripted draw: the queue lives in a test-linked Agent (the
  # session draws from its own process; the agent is a third process, so
  # no call cycle).
  defp scripted(up_counts) do
    {:ok, agent} = Agent.start_link(fn -> up_counts end)

    fn variant, _up_probability, rng ->
      up = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      {List.duplicate(true, up) ++ List.duplicate(false, variant.shell_count - up), rng}
    end
  end

  defp collect_events(count, acc \\ []) do
    case count do
      0 ->
        Enum.reverse(acc)

      _more ->
        receive do
          {:chopaat_session, _session, seq, event} ->
            collect_events(count - 1, [{seq, event} | acc])
        after
          500 -> Enum.reverse(acc)
        end
    end
  end

  # ── full games, headless ─────────────────────────────────────────────────

  describe "full games through the session API alone" do
    test "a seeded 4-player game runs to placements with no renderer anywhere" do
      session = start_session(players: 4, rng_seed: 11)
      final = drive_to_completion(session)

      assert final.phase == :finished
      assert Enum.sort(final.placements) == [0, 1, 2, 3]
    end

    test "a seeded 6-player game runs to placements" do
      session = start_session(players: 6, rng_seed: 5)
      final = drive_to_completion(session)

      assert final.phase == :finished
      assert Enum.sort(final.placements) == Enum.to_list(0..5)
    end

    test "a subscriber sees the whole game as an ordered event stream" do
      session = start_session(players: 4, rng_seed: 11)
      :ok = Session.subscribe(session)
      final = drive_to_completion(session)

      events = drain_events()
      seqs = Enum.map(events, &elem(&1, 0))
      assert seqs == Enum.to_list(1..length(events))

      assert {_seq, {:game_over, over}} = List.last(events)
      assert over.placements == final.placements
      assert over.loser == List.last(final.placements)

      # Placements were announced in rank order before the game_over.
      ranks = for {_seq, {:placement, %{rank: rank}}} <- events, do: rank
      assert ranks == Enum.to_list(1..4)
    end
  end

  defp drive_to_completion(session, commands \\ 0) do
    assert commands < @max_commands, "game did not terminate within #{@max_commands} commands"
    state = Session.observe(session)

    case state.phase do
      :finished ->
        state

      :rolling ->
        {:ok, _events} = Session.throw(session, state.turn)
        drive_to_completion(session, commands + 1)

      :assigning ->
        action = session |> Session.legal_actions(state.turn) |> hd()

        {:ok, _events} =
          case action do
            {:khadu, _i, _ix} -> Session.confirm_khadu(session, state.turn, action)
            _plain -> Session.assign(session, state.turn, action)
          end

        drive_to_completion(session, commands + 1)
    end
  end

  defp drain_events(acc \\ []) do
    receive do
      {:chopaat_session, _session, seq, event} -> drain_events([{seq, event} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── the throw flow ───────────────────────────────────────────────────────

  describe "the throw flow (RNG server-side, presentation a grace)" do
    test "throw decides and advances immediately — no presentation ack exists" do
      session = start_session(draw: scripted([2]), rng_seed: 1)
      {:ok, events} = Session.throw(session, 0)

      assert [{:throw_result, result}] = events
      assert Enum.count(result.shells, & &1) == 2
      assert result.score == 2
      refute result.special
      assert result.phase == :assigning
      assert result.pending == [2]
      assert is_integer(result.cosmetic)

      # The session already finalized the turn's rolls; a headless client
      # needs nothing else to keep acting.
      assert Session.observe(session).phase == :assigning
      assert Session.legal_actions(session, 0) != []
    end

    test "special scores keep the rolling phase and chain throws" do
      session = start_session(draw: scripted([5, 2]), rng_seed: 1)

      {:ok, [{:throw_result, first}]} = Session.throw(session, 0)
      assert first.score == 25
      assert first.special
      assert first.phase == :rolling
      assert first.rolls == [25]

      {:ok, [{:throw_result, second}]} = Session.throw(session, 0)
      assert second.phase == :assigning
      assert second.pending == [25, 2]
    end

    test "drought assistance biases the server-side draw" do
      probabilities = :ets.new(:probabilities, [:public])

      draw = fn variant, up_probability, rng ->
        :ets.insert(probabilities, {up_probability, true})
        Chopaat.RNG.draw(rng, variant.shell_count, up_probability)
      end

      parched = %{
        Craft.game()
        | droughts: %{
            0 => %{entry: 4, move: 0},
            1 => %{entry: 0, move: 0},
            2 => %{entry: 0, move: 0},
            3 => %{entry: 0, move: 0}
          }
      }

      session = start_session(game: parched, draw: draw, rng_seed: 1)

      assert Session.observe(session).seats |> hd() |> Map.fetch!(:assisted)
      {:ok, _events} = Session.throw(session, 0)

      variant = Craft.game().variant
      assert :ets.lookup(probabilities, variant.assist_up_probability) != []
    end
  end

  # ── command validation ───────────────────────────────────────────────────

  describe "command validation" do
    test "off-turn commands are refused" do
      session = start_session(rng_seed: 1)

      assert Session.throw(session, 2) == {:error, :not_your_turn}
      assert Session.assign(session, 2, {:waste, 0}) == {:error, :not_your_turn}
      assert Session.legal_actions(session, 2) == []
    end

    test "throwing outside the rolling phase is refused" do
      session = start_session(game: Fixtures.simple_move([4]))
      assert Session.throw(session, 0) == {:error, :wrong_phase}
    end

    test "illegal actions are refused without advancing" do
      session = start_session(game: Fixtures.simple_move([4]))
      before = Session.game(session)

      assert Session.assign(session, 0, {:assign, 0, 3}) == {:error, :illegal_action}
      assert Session.game(session) == before
    end

    test "khadu actions demand the explicit confirm command" do
      session = start_session(game: Fixtures.gate_jam([7]))
      [khadu | _rest] = Session.legal_actions(session, 0)
      assert match?({:khadu, _i, _ix}, khadu)

      assert Session.assign(session, 0, khadu) == {:error, :khadu_requires_confirmation}

      {:ok, events} = Session.confirm_khadu(session, 0, khadu)
      assert Enum.any?(events, &match?({:khadu, _facts}, &1))
    end

    test "a finished game refuses further play" do
      session = start_session(game: Fixtures.finished())
      assert Session.throw(session, 0) == {:error, :game_over}
    end
  end

  # ── event vocabulary ─────────────────────────────────────────────────────

  describe "the event vocabulary (renderer-facing facts)" do
    test "a move carries pawn, roll, positions and the traversed path" do
      session = start_session(game: Fixtures.simple_move([4]))
      {:ok, events} = Session.assign(session, 0, {:assign, 0, 0})

      assert [{:moved, moved}, {:turn_passed, passed}] = events
      assert moved.seat == 0
      assert moved.pawn == 0
      assert moved.roll == 4
      assert moved.action == {:assign, 0, 0}
      assert moved.from == %{state: :track, track: 20, cell: "cell_t1_l2_r5"}
      assert moved.to.track == 24
      assert Enum.count(moved.path) == 4
      assert List.last(moved.path) == moved.to
      assert Enum.all?(moved.path, &is_binary(&1.cell))

      assert passed == %{seat: 0, next_seat: 1, extra_turn: false}
    end

    test "an unlock is a move from base onto the launch square" do
      session = start_session(game: Craft.game() |> Craft.assigning([25]))
      {:ok, [{:moved, moved} | _rest]} = Session.assign(session, 0, {:assign, 0, 0})

      assert moved.from.state == :base
      assert moved.to == %{state: :track, track: 0, cell: "cell_t0_l1_r1"}
      assert moved.path == [moved.to]
    end

    test "a capture names the victim, the cell, and the tod consequences" do
      session = start_session(game: Fixtures.capture_ready())
      {:ok, events} = Session.assign(session, 0, {:assign, 0, 0})

      assert [{:moved, _moved}, {:captured, captured}, {:turn_passed, passed}] = events
      assert captured.seat == 0
      assert captured.victim_seat == 1
      assert captured.victim_pawn == 0
      assert captured.cell == "cell_t2_l2_r3"
      assert captured.tod_earned
      refute captured.victim_tod_lost

      # Capture grants an extra turn: same seat rolls again.
      assert passed == %{seat: 0, next_seat: 0, extra_turn: true}
    end

    test "a khadu names the burn — dana ane pagdu badi gaya" do
      session = start_session(game: Fixtures.mid_khadu())
      [khadu | _rest] = Session.legal_actions(session, 0)

      {:ok, events} = Session.confirm_khadu(session, 0, khadu)

      assert {:khadu, facts} = Enum.find(events, &match?({:khadu, _facts}, &1))
      assert facts.seat == 0
      assert facts.roll == 7
      assert facts.burned == %{dana: [2, 3], pagdu: 1}
      assert Enum.any?(events, &match?({:moved, _moved}, &1))
    end

    test "wasting a roll is announced" do
      game = Craft.game() |> Craft.pawns(0, [50, :base, :base, :base]) |> Craft.assigning([7])
      session = start_session(game: game)

      {:ok, events} = Session.assign(session, 0, {:waste, 0})
      assert [{:wasted, %{seat: 0, roll: 7}} | _rest] = events
    end

    test "a finishing move announces the placement, the last one the game over" do
      finishing =
        Craft.game()
        |> Craft.tod(0)
        |> Craft.pawns(0, [82, :home, :home, :home])
        |> Craft.pawns(1, home_pawns())
        |> Craft.pawns(2, home_pawns())
        |> Craft.assigning([2])

      finishing = %{finishing | placements: [1, 2]}
      session = start_session(game: %{finishing | pending: [1]})

      {:ok, events} = Session.assign(session, 0, {:assign, 0, 0})

      assert [
               {:moved, %{to: %{state: :home}}},
               {:placement, %{seat: 0, rank: 3}},
               {:placement, %{seat: 3, rank: 4}},
               {:game_over, %{placements: [1, 2, 0, 3], loser: 3}}
             ] = events

      assert Session.observe(session).phase == :finished
    end
  end

  defp home_pawns, do: [:home, :home, :home, :home]

  # ── observers ────────────────────────────────────────────────────────────

  describe "subscription" do
    test "concurrent observers receive identical, ordered streams" do
      session = start_session(game: Fixtures.capture_ready())
      parent = self()

      observers =
        for _observer <- 1..2 do
          spawn_link(fn ->
            :ok = Session.subscribe(session)
            send(parent, {:ready, self()})
            send(parent, {:stream, self(), collect_events(3)})
          end)
        end

      for pid <- observers, do: assert_receive({:ready, ^pid})

      {:ok, events} = Session.assign(session, 0, {:assign, 0, 0})

      streams =
        for pid <- observers do
          assert_receive {:stream, ^pid, stream}
          stream
        end

      assert [stream, stream] = streams
      assert Enum.map(stream, &elem(&1, 1)) == events
      assert Enum.map(stream, &elem(&1, 0)) == Enum.to_list(1..length(events))
    end

    test "unsubscribe stops the stream; a dead observer is dropped silently" do
      session = start_session(game: Fixtures.simple_move([4, 3]))
      :ok = Session.subscribe(session)

      doomed = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Session.subscribe(session, doomed)
      Process.exit(doomed, :kill)

      :ok = Session.unsubscribe(session)
      {:ok, _events} = Session.assign(session, 0, {:assign, 0, 0})

      refute_receive {:chopaat_session, _session, _seq, _event}, 50
    end
  end

  # ── observe ──────────────────────────────────────────────────────────────

  describe "observe/1 (the machine-facing public state)" do
    test "is JSON-serializable end to end (whitelisted atoms, no tuples)" do
      session = start_session(game: Fixtures.near_finish(), players: 4)
      observed = Session.observe(session)

      json = observed |> :json.encode() |> IO.iodata_to_binary()
      assert json =~ ~s("cell":"center_home")
      assert json =~ ~s("variant":"gujarat")
    end

    test "exposes pawn states: home, tipped in the stretch, jammed at the gate" do
      # near_finish: pawn 0 at 78 (past connector 75, tipped), pawn 1 at
      # 40, pawns 2/3 home; player 0 holds a tod.
      session = start_session(game: Fixtures.near_finish())
      %{seats: [seat0 | _rest]} = Session.observe(session)

      assert seat0.tod
      assert seat0.gate == :open
      assert [p0, p1, p2, _p3] = seat0.pawns
      assert p0.tipped
      assert p0.state == :track
      assert p0.cell == "cell_t0_l1_r5"
      refute p1.tipped
      assert p2.state == :home

      # gate_jam: pawns at 54..51 against the active gate at 54 — the two
      # that can absorb no score at all read as jammed.
      jam = start_session(game: Fixtures.gate_jam([7]))
      %{seats: [jammed_seat | _others]} = Session.observe(jam)

      assert jammed_seat.gate == :active
      assert Enum.map(jammed_seat.pawns, & &1.jammed) == [true, true, false, false]
    end

    test "occupancy is keyed by cell-name strings" do
      session = start_session(game: Fixtures.capture_ready())
      %{occupancy: occupancy} = Session.observe(session)

      # Player 0's lap 33 and player 1's laps 18 and 1.
      assert occupancy["cell_t2_l2_r1"] == [%{seat: 0, pawn: 0}]
      assert %{seat: 1, pawn: 0} in Map.fetch!(occupancy, "cell_t2_l2_r3")
    end

    test "carries the board geometry and the phase facts" do
      session = start_session(players: 4, rng_seed: 3)
      observed = Session.observe(session)

      assert observed.board == %{
               arms: 4,
               home: 83,
               connector: 75,
               gate: 54,
               marker: 77,
               khadu_skip: 15
             }

      assert observed.phase == :rolling
      assert observed.turn == 0
      assert observed.variant == :gujarat
      assert observed.placements == []
      assert observed.seq == 0
    end
  end

  # ── lifecycle ────────────────────────────────────────────────────────────

  describe "lifecycle" do
    test "new_game resets to a fresh game for the same seats" do
      session = start_session(game: Fixtures.finished(), rng_seed: 1)
      :ok = Session.subscribe(session)

      {:ok, [{:game_started, started}]} = Session.new_game(session, rng_seed: 2)
      assert started == %{variant: :gujarat, num_players: 4, turn: 0}

      observed = Session.observe(session)
      assert observed.phase == :rolling
      assert observed.placements == []
      assert Game.base_count(Session.game(session), 0) == 4

      assert_receive {:chopaat_session, _session, _seq, {:game_started, _started}}
    end

    test "export exposes the session snapshot for predictors and persistence" do
      setup = Setup.new(4, seed: 9)
      session = start_session(setup: setup, rng_seed: 7)

      snapshot = Session.export(session)
      assert %Game{} = snapshot.game
      assert snapshot.setup == setup
      assert snapshot.seq == 0

      # The exported RNG replays the session's exact next draw.
      {shells, cosmetic, _rng} = Session.draw_throw(snapshot.game, snapshot.rng)
      {:ok, [{:throw_result, result}]} = Session.throw(session, 0)
      assert result.shells == shells
      assert result.cosmetic == cosmetic
    end
  end

  describe "event payload hygiene" do
    test "a khadu from x < khadu_reverse emits only real cell names (soak regression)" do
      # Bead chopaat-27z: the reversal from x=2 passes through positions
      # before the launch square; the moved event's path (and every
      # position payload) must still name only cells that exist —
      # renderers key their lookups on these strings.
      game =
        Craft.game()
        |> Craft.tod(0)
        |> Craft.pawns(0, [2, :home, :home, :home])
        |> Craft.assigning([30, 30, 25])

      session = start_session(game: game)
      [action | _rest] = Session.legal_actions(session, 0)
      assert {:khadu, _i, 0} = action

      {:ok, events} = Session.confirm_khadu(session, 0, action)
      {:moved, moved} = Enum.find(events, &match?({:moved, _}, &1))

      assert moved.path != []

      for %{cell: cell} <- [moved.from, moved.to | moved.path], cell != nil do
        assert cell == "center_home" or cell =~ ~r/^cell_t\d+_l[012]_r[1-8]$/
      end
    end
  end
end
