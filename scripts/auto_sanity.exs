# AUTO-mode device sanity for bead chopaat-27z: one all-bot game on the
# pool emulator, started from the REAL menu (the AUTO button — seat-config
# plumbing exercised on device), then running unattended to placements
# while this host only watches. Evidence produced:
#
#   * ~35s screen recording of live auto-play (the human evidence —
#     stills prove nothing about motion);
#   * a mid-game screencap and the end-screen screencap;
#   * the settle ledger stays within policy for the whole game (every
#     tumble the bots caused, natively readback-verified — see below);
#   * the end screen's Rematch starts a fresh game (the loop seam).
#
# Exits non-zero on any violation. The printed values ARE the evidence.
#
# Usage (host, repo root):
#   CHOPAAT_NODE=chopaat_auto27z@127.0.0.1 \
#   CHOPAAT_SERIAL=127.0.0.1:5821 \
#   CHOPAAT_EVIDENCE=evidence/auto_mode \
#     mise exec -- elixir --name auto@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/auto_sanity.exs
#
# Settle policy (two-plane model): `mismatch` is the renderer LYING —
# strictly zero, always. `error` is the readback failing to RUN (e.g.
# Mob.Scene3d.scene/1 returning :timeout under sustained load on the
# shared pool emulators — observed once in 147 reads, logged by the
# screen as "trusting the rules"); the soak tolerates a rare few
# (max(3, 2%) of settled throws) and reports every one.
#
# Knobs: CHOPAAT_BOT_DELAY (ms between bot commands, default 1200 —
# watchable but finishes a full game in a sitting), CHOPAAT_SPEED
# (tumble playback scale, default 2.0 so clips settle within the
# cadence), CHOPAAT_TIMEOUT_MIN (whole-game bound, default 45),
# CHOPAAT_RESUME=1 (attach to an already-running auto game instead of
# starting one from the menu — no recording pass).

defmodule ChopaatAutoSanity do
  alias Chopaat.Game

  @poll_ms 500

  def run do
    node = String.to_atom(System.fetch_env!("CHOPAAT_NODE"))
    serial = System.fetch_env!("CHOPAAT_SERIAL")
    evidence = System.get_env("CHOPAAT_EVIDENCE", "evidence/auto_mode")
    bot_delay = String.to_integer(System.get_env("CHOPAAT_BOT_DELAY", "1200"))
    speed = String.to_float(System.get_env("CHOPAAT_SPEED", "2.0"))
    timeout_min = String.to_integer(System.get_env("CHOPAAT_TIMEOUT_MIN", "45"))

    File.mkdir_p!(Path.dirname(evidence <> "_x"))

    resume? = System.get_env("CHOPAAT_RESUME") == "1"

    check!(Node.connect(node), "connect to #{node}")
    :rpc.call(node, Application, :put_env, [:chopaat, :throw_speed, speed])
    :rpc.call(node, Application, :put_env, [:chopaat, :bot_delay_ms, bot_delay])

    unless resume? do
      # From the real menu: AUTO flips every seat to Bot · normal and starts.
      Mob.Test.pop_to_root(node)
      await(node, fn _a -> Mob.Test.screen(node) == Chopaat.Screens.MenuScreen end, "menu shown")
      foreground(serial)
      :ok = tap_ui(node, :auto)
    end

    await(
      node,
      fn _a -> Mob.Test.screen(node) == Chopaat.Screens.GameScreen end,
      "AUTO game screen is up"
    )

    a = fetch(node)
    check!(map_size(a.bots) == a.game.num_players, "every seat is a bot (#{map_size(a.bots)})")
    check!(is_pid(a.bot_sup), "bot runner supervisor is live")

    # The human evidence: ~35s of the game playing itself, recorded while
    # nobody drives anything (skipped on resume — already captured).
    recording =
      unless resume? or System.get_env("CHOPAAT_NO_RECORD") == "1" do
        record_async(serial, evidence <> "_play.mp4", 35)
      end

    state = %{
      node: node,
      serial: serial,
      evidence: evidence,
      started: System.monotonic_time(:millisecond),
      deadline: System.monotonic_time(:millisecond) + timeout_min * 60_000,
      mid_shot: false,
      last_report: 0
    }

    state = watch(state)

    if recording do
      Task.await(recording, 120_000)
      IO.puts("recording → #{evidence}_play.mp4")
    end

    finish(state)
  end

  # ── the unattended watch loop ─────────────────────────────────────────────

  defp watch(state) do
    a = fetch(state.node)

    check!(
      settle_ok?(a.settle),
      "settle ledger within policy (#{inspect(a.settle)})",
      quiet: true
    )

    check!(
      System.monotonic_time(:millisecond) < state.deadline,
      "auto game finished within the time bound",
      quiet: true
    )

    state = state |> maybe_report(a) |> maybe_mid_shot(a)

    case a.game.phase do
      :finished -> Map.put(state, :final, a)
      _running -> tick(state)
    end
  end

  defp tick(state) do
    Process.sleep(@poll_ms)
    watch(state)
  end

  defp maybe_report(state, a) do
    elapsed = System.monotonic_time(:millisecond) - state.started

    case elapsed - state.last_report > 60_000 do
      false ->
        state

      true ->
        home = a.game.pawns |> Map.values() |> List.flatten() |> Enum.count(&(&1.pos == :home))

        IO.puts(
          "t+#{div(elapsed, 60_000)}m: phase=#{a.game.phase} turn=#{a.game.turn} " <>
            "home_pawns=#{home} placements=#{inspect(a.game.placements)} " <>
            "settle=#{inspect(a.settle)}"
        )

        %{state | last_report: elapsed}
    end
  end

  # Mid-game screencap: once the board is visibly mid-fight (any pawn
  # home or 3+ minutes in), whichever comes first.
  defp maybe_mid_shot(%{mid_shot: true} = state, _a), do: state

  defp maybe_mid_shot(state, a) do
    home = a.game.pawns |> Map.values() |> List.flatten() |> Enum.count(&(&1.pos == :home))
    elapsed = System.monotonic_time(:millisecond) - state.started

    case home >= 1 or elapsed > 180_000 do
      false ->
        state

      true ->
        screencap(state.serial, state.evidence <> "_midgame.png")
        %{state | mid_shot: true}
    end
  end

  # ── the finish: placements, end screen, rematch seam ─────────────────────

  defp finish(%{final: a} = state) do
    %Game{placements: placements, num_players: players} = a.game

    check!(
      Enum.sort(placements) == Enum.to_list(0..(players - 1)),
      "complete placements #{inspect(placements)}"
    )

    check!(settle_ok?(a.settle), "final settle within policy #{inspect(a.settle)}")

    # Let the last move performance land so the podium renders.
    await(state.node, fn b -> b.move == nil end, "final move performance lands")
    screencap(state.serial, state.evidence <> "_end.png")

    # The rematch loop seam, on device: same seats, fresh game.
    :ok = tap_ui(state.node, :rematch)

    await(
      state.node,
      fn b -> b.game.phase == :rolling and b.game.placements == [] end,
      "rematch starts a fresh game"
    )

    check!(map_size(fetch(state.node).bots) == players, "rematch keeps the bot seats")

    # Leave the pool device clean (and stop the fresh game's runners).
    Mob.Test.pop_to_root(state.node)

    IO.puts("\nAUTO SANITY PASS: unattended to placements, rematch verified")
  end

  # Mismatch (the renderer lying) is never tolerated; readback errors
  # (scene/1 :timeout under pool load) are tolerated rarely and loudly.
  defp settle_ok?(settle) do
    reads = settle.ok + settle.error
    settle.mismatch == 0 and settle.error <= max(3, div(reads * 2, 100))
  end

  # ── device plumbing ───────────────────────────────────────────────────────

  defp foreground(serial) do
    System.cmd(
      "adb",
      ~w(-s #{serial} shell am start -n com.genericjam.chopaat/.MainActivity),
      stderr_to_stdout: true
    )

    Process.sleep(2_000)
  end

  defp record_async(serial, out, seconds) do
    Task.async(fn ->
      remote = "/data/local/tmp/chopaat_auto.mp4"

      {_out, 0} =
        System.cmd(
          "adb",
          ~w(-s #{serial} shell screenrecord --time-limit #{seconds} #{remote}),
          stderr_to_stdout: true
        )

      {_out, 0} = System.cmd("adb", ~w(-s #{serial} pull #{remote} #{out}))
      System.cmd("adb", ~w(-s #{serial} shell rm #{remote}))
      :ok
    end)
  end

  # The pool emulators are shared — another app may hold the foreground
  # (the first end-screen capture shot a different app entirely). Bring
  # chopaat forward before every capture.
  defp screencap(serial, out) do
    foreground(serial)
    {png, 0} = System.cmd("adb", ~w(-s #{serial} exec-out screencap -p))
    File.write!(out, png)
    IO.puts("screenshot → #{out}")
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
        Mob.Test.send_message(node, {:tap, id})
        :ok
    end
  end

  defp await(node, predicate, label, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(node, predicate, label, deadline)
  end

  defp poll(node, predicate, label, deadline) do
    a = fetch(node)

    cond do
      predicate.(a) ->
        IO.puts("ok: #{label}")
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        IO.puts("TIMEOUT #{label}")
        System.halt(1)

      true ->
        Process.sleep(@poll_ms)
        poll(node, predicate, label, deadline)
    end
  end

  defp check!(result, label, opts \\ []) do
    case result do
      falsy when falsy in [false, nil] ->
        IO.puts("FAIL #{label}")
        System.halt(1)

      _truthy ->
        unless opts[:quiet], do: IO.puts("ok: #{label}")
        :ok
    end
  end
end

ChopaatAutoSanity.run()
