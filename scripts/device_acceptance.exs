# Device acceptance driver for bead chopaat-hre: a full scripted 4-player
# game driven over distribution (Mob.Test tap_id / send_message — the
# game's own seams — plus one real Mob.Scene3d.pick/3), with per-step
# readback assertions:
#
#   * after each settled move: the moved pawn's native world transform
#     matches the scene the rules + BoardMap dictate (skipped when the
#     handoff prompt replaces the board — the viewport unmounts);
#   * after each throw: the screen's own settle_check verdict (scene
#     readback vs tumble_manifest) recorded in assigns.settle must stay
#     mismatch/error-free;
#   * frame_stats sampled through the game must stay sane (rendering
#     alive, no entity leak).
#
# One full turn cycle (throw → tumble → assign → move → capture) is screen-
# recorded: the driver simulates each upcoming turn locally from the live
# session snapshot (Chopaat.Session.export/1 over dist — identical RNG
# threading to the device's session) and starts recording when a capture
# is coming.
#
# Usage (host, repo root):
#   CHOPAAT_NODE=chopaat_android_xxx@127.0.0.1 \
#   CHOPAAT_RECORD=adb:127.0.0.1:5821 \            # or simctl:<UDID>
#   CHOPAAT_EVIDENCE=evidence/android_emu \
#     mise exec -- elixir --name acc@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/device_acceptance.exs
#
# Exits non-zero on any contract violation. The printed values ARE the
# evidence.

defmodule ChopaatAcceptance do
  alias Chopaat.Game
  alias Chopaat.Scene
  alias Chopaat.Setup
  alias Chopaat.Session
  alias Mob.Scene3d.IR

  @poll_ms 150
  @setup_seed 7

  def run do
    node = String.to_atom(System.fetch_env!("CHOPAAT_NODE"))
    seed = String.to_integer(System.get_env("CHOPAAT_SEED", "222"))
    speed = String.to_float(System.get_env("CHOPAAT_SPEED", "4.0"))
    evidence = System.get_env("CHOPAAT_EVIDENCE", "evidence/acceptance")

    check!(Node.connect(node), "connect to #{node}")
    IO.puts("screen: #{inspect(Mob.Test.screen(node))}")

    # Scripted runs compress the clips; the settle contract is pose-based,
    # speed-independent.
    :rpc.call(node, Application, :put_env, [:chopaat, :throw_speed, speed])

    setup = Setup.new(4, seed: @setup_seed)
    # Idempotent restarts: back to the menu root before pushing the game.
    Mob.Test.pop_to_root(node)
    :ok = Mob.Test.navigate(node, Chopaat.Screens.GameScreen, %{setup: setup, rng_seed: seed})
    await_viewport(node)

    {:ok, first_stats} = Mob.Scene3d.frame_stats(node, "board")
    IO.inspect(first_stats, label: "frame_stats at start")

    pick_probe(node)

    state = %{
      node: node,
      setup: setup,
      evidence: evidence,
      turns: 0,
      throws: 0,
      actions: 0,
      picks_driven: 0,
      readback_checks: 0,
      readback_skipped_handoff: 0,
      tipped_checks: 0,
      stats: [first_stats],
      recording: nil,
      recorded: false
    }

    state = drive(state, fetch(node))
    finish(state)
  end

  # ── the drive loop ────────────────────────────────────────────────────────

  defp drive(state, %{game: %Game{phase: :finished}} = a) do
    IO.puts("\ngame finished: placements #{inspect(a.game.placements)}")
    Map.put(state, :final, a)
  end

  defp drive(state, %{handoff: %{player: _p}} = _a) do
    state = stop_recording_if_turn_ended(state)
    :ok = tap_ui(state.node, :handoff_done)
    await(state.node, fn a -> a.handoff == nil end, "handoff dismissed")
    await_viewport(state.node)
    drive(state, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :rolling}, throw: nil, move: nil} = a) do
    state =
      case a.game.turn_rolls do
        [] -> begin_turn(state, a)
        _mid_chain -> state
      end

    before = length(a.game.turn_rolls)
    :ok = tap_ui(state.node, :throw)

    await(
      state.node,
      fn b ->
        b.throw == nil and
          (length(b.game.turn_rolls) > before or b.game.phase != :rolling or
             b.handoff != nil)
      end,
      "throw ##{state.throws + 1} settles and applies"
    )

    state = %{state | throws: state.throws + 1}
    assert_settle_health(state)
    drive(state, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :assigning} = game, move: nil, khadu: nil} = a) do
    action = hd(Game.legal_actions(game))
    state = perform(state, a, action)
    drive(state, fetch(state.node))
  end

  defp drive(state, _in_flight) do
    Process.sleep(@poll_ms)
    drive(state, fetch(state.node))
  end

  # A new turn: any active recording covered the previous full cycle —
  # stop it (this is how a capture's extra turn closes the recording).
  # Sample stats occasionally; start the recording when the local
  # simulation says this turn captures.
  defp begin_turn(state, a) do
    state = stop_recording_if_turn_ended(state)
    state = %{state | turns: state.turns + 1}

    state =
      case rem(state.turns, 20) == 1 do
        true ->
          {:ok, stats} = with_retry(fn -> Mob.Scene3d.frame_stats(state.node, "board") end)
          %{state | stats: [stats | state.stats]}

        false ->
          state
      end

    case not state.recorded and state.recording == nil and
           predict_capture?(a.session) do
      true ->
        IO.puts("turn #{state.turns}: capture predicted — recording this turn cycle")
        %{state | recording: start_recording(state)}

      false ->
        state
    end
  end

  # ── performing one action ─────────────────────────────────────────────────

  # Movement actions drive the pick-to-move seam: select the pawn, verify
  # the marker grew, tap the marker (khadu → confirm dialog). Wastes go
  # through the HUD-chip seam.
  defp perform(state, a, action) do
    game = a.game
    consumed = consumed_probe(game)

    state =
      case pick_target(action) do
        {pawn_ix, target_id} ->
          send_msg(state.node, {:pawn_picked, "pawn_#{game.turn}_#{pawn_ix}"})
          await(state.node, fn b -> b.selected == pawn_ix end, "pawn #{pawn_ix} selected")

          %{scene: scene} = fetch(state.node)
          {:ok, marker} = IR.fetch(scene, target_id)
          check!(marker.pickable, "target marker #{target_id} present and pickable")

          send_msg(state.node, {:pawn_picked, target_id})

          case action do
            {:khadu, _i, _ix} ->
              await(state.node, fn b -> b.khadu == action end, "khadu confirm dialog")
              :ok = tap_ui(state.node, :khadu_confirm)

            _plain ->
              :ok
          end

          %{state | picks_driven: state.picks_driven + 1}

        nil ->
          send_msg(state.node, {:tap, {:action, action}})
          state
      end

    await(
      state.node,
      fn b -> b.move == nil and consumed_probe(b.game) != consumed end,
      "action #{inspect(action)} applied and move settled"
    )

    state = %{state | actions: state.actions + 1}
    assert_move_readback(state, action, game.turn)
  end

  # Something the action must change: pending list, bonus count, turn, phase.
  defp consumed_probe(game),
    do: {game.pending, game.bonus_steps, game.turn, game.phase, game.turn_rolls}

  defp pick_target({:assign, i, ix}), do: {ix, "target_assign_#{i}_#{ix}"}
  defp pick_target({:khadu, i, ix}), do: {ix, "target_khadu_#{i}_#{ix}"}
  defp pick_target({:bonus_step, ix}), do: {ix, "target_bonus_#{ix}"}
  defp pick_target(_waste), do: nil

  # ── readback assertions ───────────────────────────────────────────────────

  # After a settled move: the pawn's native world transform equals the pose
  # Scene.build computes from the engine state (BoardMap cell, stack
  # fan-out, tipped-in-stretch). Skipped when the handoff replaced the
  # board (viewport unmounted).
  defp assert_move_readback(state, action, player) do
    a = fetch(state.node)
    ix = moved_ix(action)

    case {ix, a.handoff, a.game.phase} do
      {nil, _handoff, _phase} ->
        state

      {_ix, handoff, phase} when handoff != nil or phase == :finished ->
        %{state | readback_skipped_handoff: state.readback_skipped_handoff + 1}

      {ix, nil, _phase} ->
        id = "pawn_#{player}_#{ix}"
        {:ok, scene} = scene_with_retry(state.node)
        native = scene["entities"][id]["world_transform"]

        expected = Scene.build(a.game, state.setup) |> IR.fetch(id) |> then(fn {:ok, e} -> e end)
        {ex, ey, ez} = expected.transform.position
        [nx, ny, nz] = Enum.slice(native, 12, 3)

        check!(
          abs(nx - ex) < 1.0e-3 and abs(ny - ey) < 1.0e-3 and abs(nz - ez) < 1.0e-3,
          "move readback: #{id} at #{inspect({nx, ny, nz})} ≈ engine pose #{inspect({ex, ey, ez})}"
        )

        state = %{state | readback_checks: state.readback_checks + 1}
        assert_tipped(state, a.game, player, ix, native)
    end
  end

  defp moved_ix({:assign, _i, ix}), do: ix
  defp moved_ix({:bonus_step, ix}), do: ix
  defp moved_ix({:khadu, _i, ix}), do: ix
  defp moved_ix(_waste), do: nil

  # RULESET.md visual note, natively: in the private final stretch the
  # pawn lies on its side (local +Y no longer world-up); anywhere else it
  # stands upright — including right after a khadu out of the stretch.
  defp assert_tipped(state, game, player, ix, native) do
    case Enum.at(Map.fetch!(game.pawns, player), ix).pos do
      {:track, x} ->
        [yx, yy, yz] = Enum.slice(native, 4, 3)
        up_y = yy / :math.sqrt(yx * yx + yy * yy + yz * yz)

        case x > game.board.connector do
          true -> check!(abs(up_y) < 0.3, "pawn_#{player}_#{ix} tipped in final stretch")
          false -> check!(up_y > 0.9, "pawn_#{player}_#{ix} upright outside the stretch")
        end

        %{state | tipped_checks: state.tipped_checks + 1}

      _base_or_home ->
        state
    end
  end

  # Every settled throw so far must have a clean readback verdict: on
  # device nothing may be skipped, nothing mismatched.
  defp assert_settle_health(state) do
    %{settle: settle} = fetch(state.node)

    check!(
      settle.mismatch == 0 and settle.error == 0,
      "settle verdicts clean after throw ##{state.throws} (#{inspect(settle)})"
    )

    check!(
      settle.ok == state.throws and settle.skipped == 0,
      "every throw readback-verified natively (#{inspect(settle)}, throws #{state.throws})"
    )
  end

  # ── the local turn simulation (recording trigger) ─────────────────────────

  # Mirrors the session exactly: Session.export/1 (a GenServer call on the
  # device session over dist) snapshots {game, rng}; Session.draw_throw/2
  # replays the identical server-side draw sequence (shells + cosmetic,
  # drought-assisted probability included); policy = first legal action.
  # Returns whether this turn captures.
  defp predict_capture?(session) do
    %{game: game, rng: rng} = Session.export(session)
    simulate_turn(game, rng, game.turn)
  end

  defp simulate_turn(%Game{phase: :finished}, _rng, _player), do: false

  defp simulate_turn(%Game{phase: :rolling} = game, rng, player) do
    case game.turn == player do
      false ->
        false

      true ->
        {shells, _cosmetic, rng} = Session.draw_throw(game, rng)
        {:ok, next} = Game.apply_event(game, {:roll, shells})
        next.captured_this_turn or simulate_turn(next, rng, player)
    end
  end

  defp simulate_turn(%Game{phase: :assigning} = game, rng, player) do
    action = hd(Game.legal_actions(game))
    {:ok, next} = Game.apply_event(game, action)
    next.captured_this_turn or simulate_turn(next, rng, player)
  end

  # ── recording ─────────────────────────────────────────────────────────────

  defp start_recording(state) do
    case System.get_env("CHOPAAT_RECORD") do
      nil ->
        IO.puts("CHOPAAT_RECORD unset — skipping the screen recording")
        :none

      "adb:" <> serial ->
        task =
          Task.async(fn ->
            System.cmd(
              "adb",
              ~w(-s #{serial} shell screenrecord --time-limit 170 /data/local/tmp/chopaat_turn.mp4),
              stderr_to_stdout: true
            )
          end)

        {:adb, serial, task}

      "simctl:" <> udid ->
        out = state.evidence <> "_turn_cycle.mov"
        File.mkdir_p!(Path.dirname(out))

        port =
          Port.open({:spawn_executable, System.find_executable("xcrun")}, [
            :binary,
            :exit_status,
            args: ~w(simctl io #{udid} recordVideo --codec h264 --force #{out})
          ])

        {:simctl, port, out}
    end
  end

  defp stop_recording_if_turn_ended(%{recording: nil} = state), do: state
  defp stop_recording_if_turn_ended(%{recording: :none} = state), do: %{state | recording: nil}

  defp stop_recording_if_turn_ended(%{recording: {:adb, serial, task}} = state) do
    # SIGINT finalizes the mp4; give the muxer a beat before pulling.
    System.cmd("adb", ~w(-s #{serial} shell pkill -l2 screenrecord), stderr_to_stdout: true)
    Task.await(task, 15_000)
    Process.sleep(1_000)
    out = state.evidence <> "_turn_cycle.mp4"
    File.mkdir_p!(Path.dirname(out))
    {_out, 0} = System.cmd("adb", ~w(-s #{serial} pull /data/local/tmp/chopaat_turn.mp4 #{out}))
    IO.puts("recorded turn cycle → #{out}")
    %{state | recording: nil, recorded: true}
  end

  defp stop_recording_if_turn_ended(%{recording: {:simctl, port, out}} = state) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-INT", to_string(os_pid)])

    receive do
      {^port, {:exit_status, _any}} -> :ok
    after
      15_000 -> :ok
    end

    IO.puts("recorded turn cycle → #{out}")
    %{state | recording: nil, recorded: true}
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  # A slow emulator frame can miss the 2 s introspection window — one-off
  # timeouts are retried, only persistent failure is a finding.
  defp scene_with_retry(node), do: with_retry(fn -> Mob.Scene3d.scene(node, "board") end)

  defp with_retry(fun, attempts \\ 4) do
    case {fun.(), attempts} do
      {{:ok, _} = ok, _} ->
        ok

      {other, 1} ->
        other

      {_retryable, n} ->
        Process.sleep(500)
        with_retry(fun, n - 1)
    end
  end

  defp fetch(node) do
    case Mob.Test.assigns(node) do
      nil ->
        Process.sleep(@poll_ms)
        fetch(node)

      assigns ->
        assigns
    end
  end

  # Real touch path when the element is on screen (buttons carry :id);
  # falls back to the message seam so pass-and-play prompts on small
  # viewports can't stall the run.
  defp tap_ui(node, id) do
    case Mob.Test.tap_id(node, id) do
      :ok ->
        :ok

      _off_screen_or_unsupported ->
        send_msg(node, {:tap, id})
        :ok
    end
  end

  defp send_msg(node, message), do: Mob.Test.send_message(node, message)

  defp await(node, predicate, label, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(node, predicate, label, deadline)
  end

  defp poll(node, predicate, label, deadline) do
    a = fetch(node)

    cond do
      predicate.(a) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        IO.puts("TIMEOUT #{label}")

        IO.inspect(
          Map.take(a, [:game, :throw, :move, :khadu, :handoff, :selected, :settle])
          |> Map.update!(:game, &Map.take(&1, [:phase, :turn, :pending, :turn_rolls])),
          label: "assigns at timeout"
        )

        System.halt(1)

      true ->
        Process.sleep(@poll_ms)
        poll(node, predicate, label, deadline)
    end
  end

  defp await_viewport(node) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    poll_viewport(node, deadline)
  end

  defp poll_viewport(node, deadline) do
    case Mob.Scene3d.viewports(node) do
      {:ok, ["board"]} ->
        :ok

      other ->
        case System.monotonic_time(:millisecond) > deadline do
          true ->
            IO.puts("TIMEOUT viewport attach: #{inspect(other)}")
            System.halt(1)

          false ->
            Process.sleep(@poll_ms)
            poll_viewport(node, deadline)
        end
    end
  end

  # One real ray pick through the native surface: scan until a pawn
  # answers (all pawns start on base pads — always visible).
  defp pick_probe(node) do
    hit =
      Enum.find_value(for(x <- 30..330//25, y <- 30..390//25, do: {x, y}), fn {x, y} ->
        case Mob.Scene3d.pick(node, "board", x * 1.0, y * 1.0) do
          {:ok, "pawn_" <> _ = id} -> {x, y, id}
          _miss_or_other -> nil
        end
      end)

    check!(match?({_x, _y, _id}, hit), "ray pick resolves a pawn (#{inspect(hit)})")
  end

  # ── wrap-up ───────────────────────────────────────────────────────────────

  defp finish(state) do
    a = state.final
    {:ok, last_stats} = final_stats(state.node)
    stats = Enum.reverse([last_stats | state.stats])

    IO.puts("""

    ── acceptance summary ──────────────────────────────────────────
    turns driven:        #{state.turns}
    throws (all settle-verified): #{state.throws}
    actions applied:     #{state.actions}
    pick-to-move driven: #{state.picks_driven}
    move readbacks:      #{state.readback_checks} asserted, \
    #{state.readback_skipped_handoff} skipped (board hidden by handoff)
    tipped-pose checks:  #{state.tipped_checks}
    settle verdicts:     #{inspect(a.settle)}
    placements:          #{inspect(a.game.placements)}
    frame_stats samples: #{length(stats)}
    """)

    Enum.each(stats, &IO.inspect(&1, label: "frame_stats"))

    check!(length(a.game.placements) == 4, "full placement order decided")
    check!(a.settle.mismatch == 0 and a.settle.error == 0, "no settle mismatches all game")
    check!(a.settle.ok == state.throws, "all #{state.throws} throws natively verified")
    check!(state.readback_checks > 50, "readback coverage is real (>50 asserted moves)")

    live = Enum.filter(stats, &(&1.entities > 0))
    entities = Enum.map(live, & &1.entities)

    check!(
      Enum.max(entities) <= Enum.min(entities) + 12,
      "no entity leak across the game (#{inspect(entities)})"
    )

    check!(Enum.all?(live, &(&1.frames > 0)), "renderer alive at every sample")
    check!(state.recorded or System.get_env("CHOPAAT_RECORD") == nil, "turn cycle recorded")

    IO.puts("\nALL DEVICE ACCEPTANCE CHECKS PASSED")
  end

  defp final_stats(node) do
    # The game-over report replaces the board and the viewport tears down —
    # possibly racing this query. Any failure here falls back to a
    # placeholder; the leak check filters entities == 0 samples out.
    placeholder = %{frames: 1, avg_ms: 0.0, p95_ms: 0.0, dropped: 0, entities: 0}

    with {:ok, ["board"]} <- Mob.Scene3d.viewports(node),
         {:ok, stats} <- with_retry(fn -> Mob.Scene3d.frame_stats(node, "board") end, 2) do
      {:ok, stats}
    else
      _gone_or_timeout -> {:ok, placeholder}
    end
  end

  defp check!(true, label), do: IO.puts("OK   #{label}")
  defp check!({:ok, _} = _ok, label), do: IO.puts("OK   #{label}")

  defp check!(other, label) do
    IO.puts("FAIL #{label} (got #{inspect(other)})")
    System.halt(1)
  end
end

ChopaatAcceptance.run()
