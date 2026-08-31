# Device acceptance for bead chopaat-u8x: a short game played ENTIRELY in
# 2D on a device/emulator, driven through the same tap tags a finger hits —
#
#   throw (instant shell-glyph flip) → select pawn on its board cell →
#   tap the highlighted landing cell → khadu via the confirm dialog →
#   handoff
#
# with the two-plane check after every settled state: the screen's
# presented `observed` snapshot must equal `Chopaat.Session.observe/1`
# fetched fresh from the session process (presented truth == session
# truth), and the rendered tree must contain the 2D grid and ZERO scene3d
# viewports (2D playability involves no scene3d at all).
#
# With CHOPAAT_TOGGLE=1 it additionally proves the mid-game mode toggle on
# device once: 2D → 3D → 2D with the game state identical across both
# flips (same session, different client — the session-boundary acceptance).
#
# Usage (host, repo root):
#   CHOPAAT_NODE=chopaat_u8xdroid@127.0.0.1 \
#   CHOPAAT_EVIDENCE=evidence/android_emu_2d \
#   CHOPAAT_TOGGLE=1 \
#     mise exec -- elixir --name accept2d@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/device_2d_acceptance.exs

defmodule Chopaat2DAcceptance do
  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Setup

  @poll_ms 150
  @target_throws 10
  @target_moves 3

  def run do
    node = String.to_atom(System.fetch_env!("CHOPAAT_NODE"))
    seed = String.to_integer(System.get_env("CHOPAAT_SEED", "77"))
    evidence = System.get_env("CHOPAAT_EVIDENCE", "evidence/device_2d")

    check!(Node.connect(node), "connect to #{node}")
    check!(match?({:module, _}, :rpc.call(node, Code, :ensure_loaded, [Chopaat.Screens.Board2D])),
      "Chopaat.Screens.Board2D loaded on device"
    )

    setup = Setup.new(4, seed: 7)
    Mob.Test.pop_to_root(node)

    :ok =
      Mob.Test.navigate(node, Chopaat.Screens.GameScreen, %{
        setup: setup,
        rng_seed: seed,
        mode: :board2d
      })

    await(node, fn a -> a[:mode] == :board2d end, "game screen mounted in 2D")

    state = %{node: node, evidence: evidence, throws: 0, moves: 0, shot: false}
    state = drive(state, fetch(node))

    if System.get_env("CHOPAAT_TOGGLE") == "1", do: verify_toggle(node, evidence)

    screenshot(node, "#{state.evidence}_endgame.png")

    IO.puts("\n2D ACCEPTANCE PASS: throws=#{state.throws} moves=#{state.moves} (all in 2D)")
  end

  # ── the drive ─────────────────────────────────────────────────────────────

  defp drive(%{throws: t, moves: m} = state, _a) when t >= @target_throws and m >= @target_moves,
    do: state

  defp drive(state, %{game: %Game{phase: :finished}}), do: state

  defp drive(state, %{handoff: %{player: _p}}) do
    :ok = Mob.Test.tap(state.node, :handoff_done)
    await(state.node, fn a -> a.handoff == nil end, "handoff dismissed")
    drive(state, fetch(state.node))
  end

  defp drive(state, %{khadu: {:khadu, _i, _ix}}) do
    :ok = Mob.Test.tap(state.node, :khadu_confirm)
    await(state.node, fn a -> a.khadu == nil end, "khadu committed")
    state = two_plane!(state)
    drive(state, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :rolling} = game}) do
    before = length(game.turn_rolls)
    :ok = Mob.Test.tap(state.node, :throw)

    await(
      state.node,
      fn a ->
        length(a.game.turn_rolls) > before or a.game.phase != :rolling or a.handoff != nil
      end,
      "throw ##{state.throws + 1} presented instantly (2D)"
    )

    state = %{state | throws: state.throws + 1} |> two_plane!()
    drive(state, fetch(state.node))
  end

  defp drive(state, %{game: %Game{phase: :assigning} = game}) do
    # Mid-game evidence once pawns are out on the board and it's visible.
    state = if state.shot or state.moves == 0, do: state, else: midgame_shot(state)
    action = choose(Game.legal_actions(game))
    state = commit(state, game, action)
    drive(state, fetch(state.node))
  end

  # Prefer real moves (board-driven), then wastes, then khadus.
  defp choose(actions) do
    Enum.min_by(actions, fn
      {:assign, _i, _ix} -> 0
      {:bonus_step, _ix} -> 1
      :waste_bonus -> 2
      {:waste, _i} -> 3
      {:khadu, _i, _ix} -> 4
    end)
  end

  # Wastes have no board cell — the tray button is the only surface.
  defp commit(state, _game, {:waste, _i} = action), do: tap_action(state, action)
  defp commit(state, _game, :waste_bonus = action), do: tap_action(state, action)

  # Khadu: tap through the board target (raises the dialog), then confirm.
  defp commit(state, game, {:khadu, _i, ix} = action) do
    select!(state, game, ix)
    tap_action(state, action)
    await(state.node, fn b -> b.khadu != nil end, "khadu dialog raised from board tap")

    :ok = Mob.Test.tap(state.node, :khadu_confirm)
    await(state.node, fn b -> b.khadu == nil end, "khadu confirmed — dana ane pagdu badi gaya")
    %{state | moves: state.moves + 1} |> two_plane!()
  end

  defp commit(state, game, action) do
    ix = action_pawn(action)
    select!(state, game, ix)
    before = {game.pending, game.bonus_steps, game.turn}
    tap_action(state, action)

    await(
      state.node,
      fn b ->
        {b.game.pending, b.game.bonus_steps, b.game.turn} != before or b.handoff != nil
      end,
      "move committed from board tap (#{inspect(action)})"
    )

    %{state | moves: state.moves + 1} |> two_plane!()
  end

  # Selection through the board surface: base pad tap for base pawns,
  # cell tap for on-track pawns (cycling the stack until ours is ringed).
  defp select!(state, game, ix) do
    case Enum.at(Map.fetch!(game.pawns, game.turn), ix).pos do
      :base ->
        :ok = Mob.Test.tap(state.node, {:pawn2d, ix})
        await(state.node, fn a -> a.selected == ix end, "base pawn #{ix} selected via pad")

      {:track, x} ->
        cell = Board.cell_name(Board.cell(game.board, game.turn, x))
        cycle_select(state, cell, ix, 8)
        IO.puts("OK   pawn #{ix} selected via cell #{cell}")

      :home ->
        raise "cannot select a home pawn"
    end
  end

  defp cycle_select(_state, cell, ix, 0), do: raise("never selected pawn #{ix} on #{cell}")

  defp cycle_select(state, cell, ix, tries) do
    :ok = Mob.Test.tap(state.node, {:cell2d, cell})
    :ok = Mob.Test.settle(state.node)

    case fetch(state.node).selected do
      ^ix -> :ok
      _other -> cycle_select(state, cell, ix, tries - 1)
    end
  end

  defp tap_action(state, action) do
    :ok = Mob.Test.tap(state.node, {:action, action})
    state
  end

  defp action_pawn({:assign, _i, ix}), do: ix
  defp action_pawn({:bonus_step, ix}), do: ix

  # ── the two-plane check ───────────────────────────────────────────────────

  # The screen's presented snapshot must equal the session's truth, fetched
  # independently from the session process — a presentation bug cannot hide
  # behind correct rules, nor vice versa. And in 2D the rendered tree must
  # carry the grid with zero scene3d viewports.
  defp two_plane!(state) do
    a = fetch(state.node)

    observed = :rpc.call(state.node, Chopaat.Session, :observe, [a.session])

    check!(
      a.observed == observed,
      "presented snapshot == session observe (seq #{observed.seq})"
    )

    types = state.node |> Mob.Test.tree() |> types(MapSet.new())
    check!(not MapSet.member?(types, "native_view"), "no scene3d viewport in the 2D tree")
    check!(MapSet.member?(types, "box"), "2D grid present")

    state
  end

  # The live render tree uses atom keys; native dumps use strings — take both.
  defp types(%{} = node, acc) do
    type = node[:type] || node["type"]
    children = node[:children] || node["children"] || []
    acc = if type, do: MapSet.put(acc, to_string(type)), else: acc
    Enum.reduce(List.wrap(children), acc, &types/2)
  end

  defp types(_other, acc), do: acc

  # ── mid-game toggle: same session, different client ──────────────────────

  defp verify_toggle(node, evidence) do
    before = fetch(node)
    check!(before.mode == :board2d, "toggle starts from 2D")

    :ok = Mob.Test.tap(node, :toggle_board_mode)
    a = await(node, fn b -> b.mode == :board3d end, "toggled to 3D mid-game")

    check!(a.session == before.session, "same session process across the toggle")
    check!(a.game == before.game, "identical game state presented in 3D")

    types = node |> Mob.Test.tree() |> types(MapSet.new())
    check!(MapSet.member?(types, "native_view"), "scene3d viewport live after toggle")
    Process.sleep(600)
    screenshot(node, "#{evidence}_toggle_3d.png")

    :ok = Mob.Test.tap(node, :toggle_board_mode)
    back = await(node, fn b -> b.mode == :board2d end, "toggled back to 2D")
    check!(back.session == before.session, "same session process after the round trip")
    check!(back.game == before.game, "identical game state back in 2D")
    screenshot(node, "#{evidence}_toggle_back_2d.png")
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp fetch(node), do: Mob.Test.assigns(node)

  defp midgame_shot(state) do
    Process.sleep(300)
    screenshot(state.node, "#{state.evidence}_midgame.png")
    %{state | shot: true}
  end

  defp screenshot(node, path) do
    case Mob.Test.screenshot(node) do
      {:ok, png} ->
        File.write!(path, png)
        IO.puts("EVIDENCE #{path}")

      {:error, reason} ->
        IO.puts("WARN screenshot failed: #{inspect(reason)}")
    end
  end

  defp await(node, fun, label, deadline_ms \\ 8_000) do
    a = poll(node, fun, System.monotonic_time(:millisecond) + deadline_ms, label)
    if label, do: IO.puts("OK   #{label}")
    a
  end

  defp poll(node, fun, deadline, label) do
    a = fetch(node)

    cond do
      fun.(a) ->
        a

      System.monotonic_time(:millisecond) > deadline ->
        raise "TIMEOUT #{label || "await"}: #{inspect(Map.take(a, [:mode, :selected, :khadu, :handoff]))}"

      true ->
        Process.sleep(@poll_ms)
        poll(node, fun, deadline, label)
    end
  end

  defp check!(true, label), do: IO.puts("OK   #{label}")
  defp check!(other, label), do: raise("FAIL #{label}: #{inspect(other)}")
end

Chopaat2DAcceptance.run()
