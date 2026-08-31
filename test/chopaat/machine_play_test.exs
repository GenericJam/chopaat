defmodule Chopaat.MachinePlayTest do
  @moduledoc false

  # The machine-play protocol (bead chopaat-85o): the stable wire facade
  # over the session, plus Acceptance A — Bot.Random reimplemented over
  # the PUBLIC protocol (Chopaat.Support.MachineBot, strict JSON boundary
  # on every call) playing headless full games mixed with the internal
  # bot, identical legality asserted on both planes per decision.

  use ExUnit.Case, async: true

  alias Chopaat.Bot
  alias Chopaat.MachinePlay
  alias Chopaat.Session
  alias Chopaat.Support.Craft
  alias Chopaat.Support.Fixtures
  alias Chopaat.Support.MachineBot

  @moduletag timeout: 300_000

  @action_terms [
    :throw,
    {:assign, 1, 2},
    {:bonus_step, 3},
    {:khadu, 0, 1},
    {:waste, 2},
    :waste_bonus
  ]

  defp start_session(opts) do
    {:ok, session} = Session.start_link(opts)
    session
  end

  defp scripted(up_counts) do
    {:ok, agent} = Agent.start_link(fn -> up_counts end)

    fn variant, _up_probability, rng ->
      up = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      {List.duplicate(true, up) ++ List.duplicate(false, variant.shell_count - up), rng}
    end
  end

  # ── the contract as data ──────────────────────────────────────────────────

  describe "describe/0 (the contract as data)" do
    test "is versioned and strictly JSON-serializable" do
      contract = MachinePlay.describe()

      assert contract["version"] == MachinePlay.protocol_version()
      assert contract["version"] =~ ~r/^\d+\.\d+\.\d+$/
      assert MachineBot.roundtrip(contract) == contract
    end

    test "the action grammar covers exactly the decodable wire types" do
      described = for action <- MachinePlay.describe()["actions"], do: action["type"]
      encoded = for term <- @action_terms, do: MachinePlay.encode_action(term)["type"]

      assert Enum.sort(described) == Enum.sort(encoded)
    end

    test "the state schema names every observe field, recursively" do
      session = start_session(game: Fixtures.near_finish())
      observed = MachinePlay.observe(session)
      schema = MachinePlay.describe()["state"]

      assert field_names(observed) == field_names(schema)
    end

    test "the event vocabulary names every session event type" do
      names = MachinePlay.describe()["events"] |> Map.keys() |> Enum.sort()

      assert names ==
               Enum.sort(~w[
                 game_started throw_result moved captured khadu wasted
                 turn_passed placement game_over
               ])
    end
  end

  # observe's top-level field names against the schema's, one level into
  # board/seats/pawns — the schema documents exactly what ships.
  defp field_names(%{seq: _seq} = observed) do
    seat = hd(observed.seats)

    %{
      top: keys(observed),
      board: keys(observed.board),
      seat: keys(seat),
      pawn: keys(hd(seat.pawns)),
      drought: keys(seat.drought)
    }
  end

  defp field_names(%{"seq" => _doc} = schema) do
    seat = schema["seats"]

    %{
      top: keys(schema),
      board: keys(schema["board"]),
      seat: keys(seat),
      pawn: keys(seat["pawns"]),
      drought: keys(seat["drought"])
    }
  end

  defp keys(map), do: map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  # ── the action grammar ────────────────────────────────────────────────────

  describe "the action grammar" do
    test "encode and decode are inverse across every action type" do
      for term <- @action_terms do
        wire = term |> MachinePlay.encode_action() |> MachineBot.roundtrip()
        assert MachinePlay.decode_action(wire) == {:ok, term}
      end
    end

    test "decoding ignores unknown extra fields (append-only policy)" do
      wire = %{"type" => "assign", "roll_index" => 0, "pawn" => 1, "hint" => "future"}
      assert MachinePlay.decode_action(wire) == {:ok, {:assign, 0, 1}}
    end

    test "unknown types, missing fields, and non-maps are bad_action" do
      for bad <- [
            %{"type" => "leap", "pawn" => 0},
            %{"type" => "assign", "pawn" => 1},
            %{"type" => "assign", "roll_index" => "0", "pawn" => 1},
            [],
            "throw"
          ] do
        assert MachinePlay.decode_action(bad) == {:error, :bad_action}
      end
    end
  end

  # ── legal_actions on the wire ─────────────────────────────────────────────

  describe "legal_actions/2 (wire shape)" do
    test "the rolling phase offers exactly the throw, only to the turn seat" do
      session = start_session(players: 4, rng_seed: 1)

      assert MachinePlay.legal_actions(session, 0) == [%{"type" => "throw"}]
      assert MachinePlay.legal_actions(session, 1) == []
    end

    test "the assigning phase offers the session's terms, encoded verbatim" do
      session = start_session(game: Fixtures.simple_move([4]))

      assert MachinePlay.legal_actions(session, 0) ==
               [%{"type" => "assign", "roll_index" => 0, "pawn" => 0}]
    end

    test "a forced khadu surfaces only as confirm_khadu actions" do
      session = start_session(game: Fixtures.gate_jam([7]))
      legal = MachinePlay.legal_actions(session, 0)

      assert legal != []
      assert Enum.all?(legal, &(&1["type"] == "confirm_khadu"))
    end

    test "a finished game offers nothing to anyone" do
      session = start_session(game: Fixtures.finished())
      assert Enum.map(0..3, &MachinePlay.legal_actions(session, &1)) == [[], [], [], []]
    end
  end

  # ── act ───────────────────────────────────────────────────────────────────

  describe "act/3" do
    test "plays a wire exchange end to end: throw, then assign the roll" do
      game = Craft.game() |> Craft.pawns(0, [20, :base, :base, :base])
      session = start_session(game: game, draw: scripted([4]))

      {:ok, events} = MachinePlay.act(session, 0, %{"type" => "throw"})
      assert [%{event: :throw_result, score: 4, phase: :assigning} | _rest] = events

      [action] = MachinePlay.legal_actions(session, 0)
      {:ok, events} = MachinePlay.act(session, 0, action)

      assert [%{event: :moved, action: ^action, roll: 4}, %{event: :turn_passed}] = events
      assert [_moved, _passed] = MachineBot.roundtrip(events)
    end

    test "a capture returns the captured event and the extra turn, encoded" do
      session = start_session(game: Fixtures.capture_ready())

      {:ok, events} =
        MachinePlay.act(session, 0, %{"type" => "assign", "roll_index" => 0, "pawn" => 0})

      assert Enum.map(events, & &1.event) == [:moved, :captured, :turn_passed]
      assert [_moved, %{tod_earned: true}, %{extra_turn: true}] = events
    end

    test "the khadu commit is explicit: assign never commits one" do
      session = start_session(game: Fixtures.mid_khadu())
      assign = %{"type" => "assign", "roll_index" => 0, "pawn" => 0}

      assert MachinePlay.act(session, 0, assign) == {:error, :illegal_action}

      khadu = %{"type" => "confirm_khadu", "roll_index" => 0, "pawn" => 0}
      {:ok, events} = MachinePlay.act(session, 0, khadu)

      assert Enum.any?(events, &match?(%{event: :khadu, burned: %{dana: [2, 3], pagdu: 1}}, &1))
    end

    test "errors are the documented reasons" do
      rolling = start_session(players: 4, rng_seed: 1)
      assigning = start_session(game: Fixtures.simple_move([4]))
      finished = start_session(game: Fixtures.finished())
      assign = %{"type" => "assign", "roll_index" => 0, "pawn" => 0}

      assert MachinePlay.act(rolling, 1, %{"type" => "throw"}) == {:error, :not_your_turn}
      assert MachinePlay.act(rolling, 0, assign) == {:error, :invalid_event}
      assert MachinePlay.act(assigning, 0, %{"type" => "throw"}) == {:error, :wrong_phase}
      assert MachinePlay.act(assigning, 0, %{"type" => "levitate"}) == {:error, :bad_action}
      assert MachinePlay.act(finished, 0, %{"type" => "throw"}) == {:error, :game_over}
    end
  end

  # ── Acceptance A: the machine bot over the public protocol ───────────────

  describe "acceptance A: MachineBot.Random over MachinePlay only" do
    # 2 machine + 2 internal Bot.Random per game, the machine pair
    # rotating through the seats so every seat plays both planes.
    @mixed_patterns [
      [:machine, Bot.Random, :machine, Bot.Random],
      [Bot.Random, :machine, Bot.Random, :machine],
      [:machine, :machine, Bot.Random, Bot.Random],
      [Bot.Random, Bot.Random, :machine, :machine]
    ]

    test "mixed 4p games terminate with identical legality on both planes" do
      stats =
        for seed <- 1..40 do
          MachineBot.run(seed, seats: Enum.at(@mixed_patterns, rem(seed, 4)))
        end

      assert Enum.all?(stats, &(Enum.sort(&1.placements) == [0, 1, 2, 3]))
      assert Enum.all?(stats, &(&1.machine_decisions > 0))
    end

    test "an all-machine 6p game plays to completion over the wire" do
      stats = MachineBot.run(7, seats: List.duplicate(:machine, 6))

      assert Enum.sort(stats.placements) == Enum.to_list(0..5)
      assert stats.machine_decisions == stats.commands
    end
  end
end
