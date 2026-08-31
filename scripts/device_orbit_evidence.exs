# Device evidence driver for bead chopaat-4g7 (per-turn camera orbit):
# drives pass-and-play turns over distribution and verifies, on device,
#
#   * the camera mounts framing seat 0 (the tuned rig, yaw 0) — native
#     scene/1 world_transform, not the Elixir intent;
#   * every handoff confirm orbits the camera to the incoming seat: the
#     in-flight orbit is observed mid-swing (assigns polled fast), and the
#     landed camera's native world transform matches Scene.build/3 at that
#     seat's yaw — position AND full rotation basis (4p: 90° steps across
#     4 handoffs incl. the 270→0 wrap; 6p: 60° steps across 6 handoffs);
#   * the handoff sequencing: while the prompt is up the camera still
#     holds the PREVIOUS seat's yaw (the orbit waits for the confirm);
#   * throws keep settling clean under orbited cameras (assigns.settle).
#
# The first two consecutive handoffs of the 4p leg are screen-recorded —
# the orbit IS motion, so the recording (not stills) is the evidence.
#
# Usage (host, repo root):
#   CHOPAAT_NODE=chopaat_orbitpool1@127.0.0.1 \
#   CHOPAAT_RECORD=adb:127.0.0.1:5821 \
#   CHOPAAT_EVIDENCE=evidence/android_emu_orbit \
#     mise exec -- elixir --name orbit_acc@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/device_orbit_evidence.exs
#
# Exits non-zero on any contract violation. The printed values ARE the
# evidence.

defmodule ChopaatOrbitEvidence do
  alias Chopaat.Game
  alias Chopaat.Scene
  alias Chopaat.Scene.Orbit
  alias Chopaat.Setup
  alias Mob.Scene3d.IR

  @poll_ms 150
  @orbit_poll_ms 40
  @setup_seed 7
  @pos_tol 2.0e-3
  @basis_tol 2.0e-3

  def run do
    node = String.to_atom(System.fetch_env!("CHOPAAT_NODE"))
    check!(Node.connect(node), "connect to #{node}")
    IO.puts("screen host: #{inspect(Mob.Test.screen(node))}")

    # Compress the tumbles so both legs fit one sitting; the orbit itself
    # runs at its real 800 ms — that is the motion under test.
    :rpc.call(node, Application, :put_env, [:chopaat, :throw_speed, 4.0])

    leg(node, 4, "4p", record_handoffs: 2)
    leg(node, 6, "6p", record_handoffs: 0)

    IO.puts("\nALL ORBIT EVIDENCE CHECKS PASSED")
  end

  # One leg: a fresh num_players game, driven until every seat's camera
  # frame has been readback-verified (num_players handoffs — the last one
  # wraps back to seat 0, exercising the shortest-arc direction).
  defp leg(node, num_players, label, opts) do
    IO.puts("\n== #{label} leg — #{num_players} handoffs, one per seat ==")
    setup = Setup.new(num_players, seed: @setup_seed)

    Mob.Test.pop_to_root(node)
    :ok = Mob.Test.navigate(node, Chopaat.Screens.GameScreen, %{setup: setup, rng_seed: 11})
    await_viewport(node)

    a = fetch(node)
    check!(a.camera_yaw == 0.0 and a.orbit == nil, "#{label} mounts at seat-0 yaw 0.0")
    assert_camera_readback(node, setup, a.game, 0.0, "#{label} mount")

    state = %{
      node: node,
      setup: setup,
      label: label,
      handoffs: 0,
      throws: 0,
      actions: 0,
      orbit_samples: 0,
      recording: nil,
      record_handoffs: Keyword.fetch!(opts, :record_handoffs)
    }

    state =
      case state.record_handoffs > 0 do
        true -> %{state | recording: start_recording()}
        false -> state
      end

    state = drive(state, fetch(node))

    settle = fetch(node).settle

    check!(
      settle.mismatch == 0 and settle.error == 0 and settle.skipped == 0,
      "#{label} throw settle verdicts stayed clean under orbited cameras " <>
        "(#{inspect(settle)}, throws #{state.throws})"
    )

    IO.puts(
      "#{label} leg done: #{state.handoffs} handoffs, #{state.throws} throws, " <>
        "#{state.actions} actions, #{state.orbit_samples} mid-orbit samples"
    )
  end

  # ── the drive loop ────────────────────────────────────────────────────────

  # Every seat verified — stop this leg.
  defp drive(%{handoffs: done, setup: %Setup{num_players: n}} = state, _a) when done >= n,
    do: state

  # The pass-and-play prompt: sequencing check, confirm, observe the
  # orbit in flight, then verify the landed camera natively.
  defp drive(state, %{handoff: %{player: seat}} = a) do
    n = state.setup.num_players
    prev_yaw = Orbit.seat_yaw(n, rem(seat + n - 1, n))
    target_yaw = Orbit.seat_yaw(n, seat)

    # Wait for any landing move performance to drop before reading yaw.
    check!(
      a.orbit == nil and a.camera_yaw == prev_yaw,
      "#{state.label} handoff ##{state.handoffs + 1}: camera still at the " <>
        "outgoing seat's yaw #{prev_yaw} while the prompt is up"
    )

    # While recording, hold the prompt a beat at human pace — the clip
    # should read: settled frame → prompt → confirm → orbit → new frame.
    if state.recording not in [nil, :none], do: Process.sleep(1_200)

    :ok = tap_ui(state.node, :handoff_done)

    samples = observe_orbit(state.node, target_yaw)

    check!(
      samples > 0,
      "#{state.label} handoff ##{state.handoffs + 1}: orbit observed in flight " <>
        "(#{samples} mid-swing samples) before landing at yaw #{target_yaw}"
    )

    await_viewport(state.node)
    b = fetch(state.node)

    check!(
      b.orbit == nil and b.camera_yaw == target_yaw,
      "#{state.label} handoff ##{state.handoffs + 1}: orbit landed at seat #{seat} " <>
        "yaw #{target_yaw}"
    )

    assert_camera_readback(
      state.node,
      state.setup,
      b.game,
      target_yaw,
      "#{state.label} seat #{seat}"
    )

    state = %{state | handoffs: state.handoffs + 1, orbit_samples: state.orbit_samples + samples}
    state = maybe_stop_recording(state)
    drive(state, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :rolling}, throw: nil, move: nil, orbit: nil} = a) do
    before = length(a.game.turn_rolls)
    :ok = tap_ui(state.node, :throw)

    await(
      state.node,
      fn b ->
        b.throw == nil and
          (length(b.game.turn_rolls) > before or b.game.phase != :rolling or b.handoff != nil)
      end,
      "#{state.label} throw ##{state.throws + 1} settles"
    )

    drive(%{state | throws: state.throws + 1}, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :assigning} = game, move: nil, khadu: nil, orbit: nil}) do
    actions = Game.legal_actions(game)
    action = Enum.find(actions, &(not match?({:khadu, _, _}, &1))) || hd(actions)
    consumed = consumed_probe(game)

    send_msg(state.node, {:tap, {:action, action}})

    case action do
      {:khadu, _i, _ix} ->
        await(state.node, fn b -> b.khadu == action end, "khadu confirm dialog")
        :ok = tap_ui(state.node, :khadu_confirm)

      _plain ->
        :ok
    end

    await(
      state.node,
      fn b -> b.move == nil and consumed_probe(b.game) != consumed end,
      "#{state.label} action #{inspect(action)} applied"
    )

    drive(%{state | actions: state.actions + 1}, fetch(state.node))
  end

  defp drive(state, _in_flight) do
    Process.sleep(@poll_ms)
    drive(state, fetch(state.node))
  end

  defp consumed_probe(game),
    do: {game.pending, game.bonus_steps, game.turn, game.phase, game.turn_rolls}

  # Fast-poll while the ~800 ms orbit flies: count mid-swing samples
  # (orbit struct present / yaw strictly between the endpoints), return
  # once the target yaw holds with no orbit in flight.
  defp observe_orbit(node, target_yaw, samples \\ 0, tries \\ 200) do
    if tries == 0 do
      check!(false, "orbit toward yaw #{target_yaw} landed within the poll budget")
    end

    a = fetch(node)

    case {a.orbit, a.camera_yaw} do
      {nil, ^target_yaw} ->
        samples

      {orbit, _yaw} ->
        # Only a live %Orbit{} counts as a mid-swing observation — the
        # polls between the tap and the orbit start prove nothing.
        Process.sleep(@orbit_poll_ms)
        observe_orbit(node, target_yaw, samples + bool_to_int(orbit != nil), tries - 1)
    end
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  # ── the native camera readback ────────────────────────────────────────────

  # The applied camera (Filament's TransformManager, via scene/1) must
  # match Scene.build/3 at this yaw: position and all three rotated basis
  # columns — elevation, distance, pitch and roll all pinned at once.
  defp assert_camera_readback(node, setup, game, yaw, label) do
    {:ok, scene} = scene_with_retry(node)
    native = scene["entities"]["camera"]["world_transform"]
    check!(is_list(native), "#{label}: camera world_transform present in scene/1 readback")

    {:ok, expected} =
      game |> Scene.build(setup, camera_yaw: yaw) |> IR.fetch("camera")

    %{position: {ex, ey, ez}, rotation: quat} = expected.transform

    expected16 =
      basis(quat, {1.0, 0.0, 0.0}) ++
        basis(quat, {0.0, 1.0, 0.0}) ++ basis(quat, {0.0, 0.0, 1.0}) ++ [ex, ey, ez, 1.0]

    deltas =
      native
      |> Enum.zip(expected16)
      |> Enum.map(fn {n, e} -> abs(n - e) end)

    {pos_delta, basis_delta} =
      {deltas |> Enum.slice(12, 3) |> Enum.max(), deltas |> Enum.take(12) |> Enum.max()}

    check!(
      pos_delta < @pos_tol and basis_delta < @basis_tol,
      "#{label}: native camera matches Scene.build at yaw #{yaw} " <>
        "(pos Δ #{Float.round(pos_delta, 6)}, basis Δ #{Float.round(basis_delta, 6)})"
    )
  end

  # Column of the world matrix: the quaternion-rotated basis vector,
  # padded with the matrix's 0.0 w row entry.
  defp basis({qx, qy, qz, qw}, {vx, vy, vz}) do
    {tx, ty, tz} = {2 * (qy * vz - qz * vy), 2 * (qz * vx - qx * vz), 2 * (qx * vy - qy * vx)}

    [
      vx + qw * tx + qy * tz - qz * ty,
      vy + qw * ty + qz * tx - qx * tz,
      vz + qw * tz + qx * ty - qy * tx,
      0.0
    ]
  end

  # ── recording (two consecutive handoffs, 4p leg) ──────────────────────────

  defp start_recording do
    case System.get_env("CHOPAAT_RECORD") do
      nil ->
        IO.puts("CHOPAAT_RECORD unset — skipping the screen recording")
        :none

      "adb:" <> serial ->
        # CHOPAAT_RECORD_SIZE (e.g. 540x1170): full-size screenrecord
        # virtual displays show the scene3d SurfaceView black on redroid
        # with the current plugin native (regression vs the native that
        # recorded android_emu_turn_cycle.mp4 — filed as mob_scene3d-10z);
        # a scaled capture composites it fine. Physical devices capture
        # full-size correctly.
        size_args =
          case System.get_env("CHOPAAT_RECORD_SIZE") do
            nil -> []
            size -> ["--size", size]
          end

        task =
          Task.async(fn ->
            System.cmd(
              "adb",
              ~w(-s #{serial} shell screenrecord --time-limit 170) ++
                size_args ++ ["/data/local/tmp/chopaat_orbit.mp4"],
              stderr_to_stdout: true
            )
          end)

        IO.puts("recording two consecutive handoffs (adb #{serial})...")
        Process.sleep(500)
        {:adb, serial, task}
    end
  end

  defp maybe_stop_recording(%{recording: nil} = state), do: state
  defp maybe_stop_recording(%{recording: :none} = state), do: %{state | recording: nil}

  defp maybe_stop_recording(%{handoffs: done, record_handoffs: wanted} = state)
       when done < wanted,
       do: state

  defp maybe_stop_recording(%{recording: {:adb, serial, task}} = state) do
    # A beat so the landed frame is in the clip, then SIGINT finalizes.
    Process.sleep(1_000)
    System.cmd("adb", ~w(-s #{serial} shell pkill -l2 screenrecord), stderr_to_stdout: true)
    Task.await(task, 15_000)
    out = System.get_env("CHOPAAT_EVIDENCE", "evidence/orbit") <> "_handoffs.mp4"
    {_out, 0} = System.cmd("adb", ~w(-s #{serial} pull /data/local/tmp/chopaat_orbit.mp4 #{out}))
    IO.puts("recorded #{state.record_handoffs} consecutive handoffs → #{out}")
    %{state | recording: nil}
  end

  # ── plumbing (device_acceptance.exs conventions) ──────────────────────────

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
          Map.take(a, [:game, :throw, :move, :khadu, :handoff, :orbit, :camera_yaw])
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

      _not_yet ->
        if System.monotonic_time(:millisecond) > deadline do
          check!(false, "viewport \"board\" attached")
        end

        Process.sleep(@poll_ms)
        poll_viewport(node, deadline)
    end
  end

  defp check!(true, label), do: IO.puts("OK   #{label}")

  defp check!(other, label) do
    IO.puts("FAIL #{label} — got #{inspect(other)}")
    System.halt(1)
  end
end

ChopaatOrbitEvidence.run()
