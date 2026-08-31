# Device SANITY for bead chopaat-uzu (NOT the full acceptance matrix —
# that re-runs at chopaat-4nn via scripts/device_acceptance.exs): one
# scripted short game segment on a device/emulator confirming the
# session-refactored screen still plays the core loop —
#
#   throw → tumble (session-decided outcome, client-performed) →
#   assign → move performance
#
# with the settle readback staying clean (every throw natively verified,
# zero mismatches — the renderer agreeing with the session's truth) and
# one settled move's native world transform matching the pose the session
# state dictates. Exits non-zero on any violation; takes a screenshot as
# evidence when CHOPAAT_SCREENSHOT names an adb serial.
#
# Usage (host, repo root):
#   CHOPAAT_NODE=chopaat_android_xxx@127.0.0.1 \
#   CHOPAAT_SCREENSHOT=adb:127.0.0.1:5821 \
#   CHOPAAT_EVIDENCE=evidence/session_sanity \
#     mise exec -- elixir --name sanity@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/device_sanity.exs

defmodule ChopaatSanity do
  alias Chopaat.Game
  alias Chopaat.Scene
  alias Chopaat.Setup
  alias Mob.Scene3d.IR

  @poll_ms 150
  # Enough turns to see throws, specials, an assignment and a move — short.
  @target_throws 4

  def run do
    node = String.to_atom(System.fetch_env!("CHOPAAT_NODE"))
    seed = String.to_integer(System.get_env("CHOPAAT_SEED", "222"))
    speed = String.to_float(System.get_env("CHOPAAT_SPEED", "4.0"))

    check!(Node.connect(node), "connect to #{node}")
    IO.puts("screen: #{inspect(Mob.Test.screen(node))}")

    :rpc.call(node, Application, :put_env, [:chopaat, :throw_speed, speed])

    setup = Setup.new(4, seed: 7)
    Mob.Test.pop_to_root(node)
    :ok = Mob.Test.navigate(node, Chopaat.Screens.GameScreen, %{setup: setup, rng_seed: seed})
    await_viewport(node)

    state = %{node: node, setup: setup, throws: 0, moves: 0, move_readbacks: 0}
    state = drive(state, fetch(node))

    screenshot(state)

    IO.puts(
      "\nSANITY PASS: throws=#{state.throws} settled+verified, " <>
        "moves=#{state.moves}, move_readbacks=#{state.move_readbacks}"
    )
  end

  # ── the short drive ───────────────────────────────────────────────────────

  defp drive(%{throws: throws, moves: moves} = state, _a)
       when throws >= @target_throws and moves >= 1 do
    state
  end

  defp drive(state, %{handoff: %{player: _p}}) do
    :ok = tap_ui(state.node, :handoff_done)
    await(state.node, fn a -> a.handoff == nil end, "handoff dismissed")
    await_viewport(state.node)
    drive(state, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :rolling}, throw: nil, move: nil} = a) do
    before = length(a.game.turn_rolls)
    :ok = tap_ui(state.node, :throw)

    await(
      state.node,
      fn b ->
        b.throw == nil and
          (length(b.game.turn_rolls) > before or b.game.phase != :rolling or b.handoff != nil)
      end,
      "throw ##{state.throws + 1} settles and applies"
    )

    state = %{state | throws: state.throws + 1}
    assert_settle_health(state)
    drive(state, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :assigning} = game, move: nil, khadu: nil}) do
    action = hd(Game.legal_actions(game))
    consumed = {game.pending, game.bonus_steps, game.turn, game.phase}

    :ok = Mob.Test.send_message(state.node, {:tap, {:action, action}})

    case action do
      {:khadu, _i, _ix} ->
        await(state.node, fn b -> b.khadu == action end, "khadu confirm dialog")
        :ok = tap_ui(state.node, :khadu_confirm)

      _plain ->
        :ok
    end

    await(
      state.node,
      fn b ->
        b.move == nil and {b.game.pending, b.game.bonus_steps, b.game.turn, b.game.phase} != consumed
      end,
      "action #{inspect(action)} applied and move settled"
    )

    state =
      case moved_ix(action) do
        nil -> state
        ix -> state |> Map.update!(:moves, &(&1 + 1)) |> assert_move_readback(ix, game.turn)
      end

    drive(state, fetch(state.node))
  end

  defp drive(state, _in_flight) do
    Process.sleep(@poll_ms)
    drive(state, fetch(state.node))
  end

  defp moved_ix({:assign, _i, ix}), do: ix
  defp moved_ix({:bonus_step, ix}), do: ix
  defp moved_ix({:khadu, _i, ix}), do: ix
  defp moved_ix(_waste), do: nil

  # ── assertions ────────────────────────────────────────────────────────────

  # On device every settled throw must be readback-verified: no skips, no
  # mismatches — the renderer agreeing with the session's decided outcome.
  defp assert_settle_health(state) do
    %{settle: settle} = fetch(state.node)

    check!(
      settle.mismatch == 0 and settle.error == 0 and settle.skipped == 0 and
        settle.ok == state.throws,
      "settle verdicts clean after throw ##{state.throws} (#{inspect(settle)})"
    )
  end

  # The settled pawn's native world transform equals the pose Scene.build
  # computes from the session-adopted state (skipped under the handoff
  # prompt — the viewport unmounts).
  defp assert_move_readback(state, ix, player) do
    a = fetch(state.node)

    case {a.handoff, a.game.phase} do
      {handoff, phase} when handoff != nil or phase == :finished ->
        state

      {nil, _phase} ->
        id = "pawn_#{player}_#{ix}"
        {:ok, scene} = with_retry(fn -> Mob.Scene3d.scene(state.node, "board") end)
        native = scene["entities"][id]["world_transform"]

        {:ok, expected} = a.game |> Scene.build(state.setup) |> IR.fetch(id)
        {ex, ey, ez} = expected.transform.position
        [nx, ny, nz] = Enum.slice(native, 12, 3)

        check!(
          abs(nx - ex) < 1.0e-3 and abs(ny - ey) < 1.0e-3 and abs(nz - ez) < 1.0e-3,
          "move readback: #{id} at #{inspect({nx, ny, nz})} ≈ session pose #{inspect({ex, ey, ez})}"
        )

        Map.update!(state, :move_readbacks, &(&1 + 1))
    end
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp screenshot(state) do
    case System.get_env("CHOPAAT_SCREENSHOT") do
      "adb:" <> serial ->
        out = System.get_env("CHOPAAT_EVIDENCE", "evidence/session_sanity") <> "_board.png"
        File.mkdir_p!(Path.dirname(out))

        # The pool emulators are shared — another app may hold the
        # foreground. Bring chopaat forward so the capture shows the board.
        System.cmd(
          "adb",
          ~w(-s #{serial} shell am start -n com.genericjam.chopaat/.MainActivity),
          stderr_to_stdout: true
        )

        Process.sleep(2_000)

        {png, 0} = System.cmd("adb", ~w(-s #{serial} exec-out screencap -p))
        File.write!(out, png)
        IO.puts("screenshot → #{out}")
        state

      _unset ->
        state
    end
  end

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
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        IO.puts("TIMEOUT #{label}")

        IO.inspect(
          a
          |> Map.take([:game, :throw, :move, :khadu, :handoff, :settle])
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
        case System.monotonic_time(:millisecond) > deadline do
          true ->
            IO.puts("TIMEOUT waiting for the board viewport")
            System.halt(1)

          false ->
            Process.sleep(@poll_ms)
            poll_viewport(node, deadline)
        end
    end
  end

  defp check!(true, label), do: IO.puts("ok: #{label}")

  defp check!(other, label) do
    IO.puts("FAIL: #{label} — got #{inspect(other)}")
    System.halt(1)
  end
end

ChopaatSanity.run()
