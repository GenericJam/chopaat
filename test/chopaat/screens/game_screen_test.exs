defmodule Chopaat.Screens.GameScreenTest do
  @moduledoc false

  # async: false — the Chopaat.Throws impl is swapped via application env.
  use Mob.ScreenCase, async: false

  alias Chopaat.Game
  alias Chopaat.Screens.GameScreen
  alias Chopaat.Setup
  alias Chopaat.Support.Fixtures
  alias Chopaat.Support.ThrowsStub
  alias Mob.Scene3d.IR

  setup do
    Application.put_env(:chopaat, :throws, ThrowsStub)
    on_exit(fn -> Application.delete_env(:chopaat, :throws) end)
    :ok
  end

  defp mount_game(opts \\ []) do
    params = %{
      setup: Keyword.get(opts, :setup, Setup.new(4, seed: 1)),
      rng_seed: 1
    }

    params =
      case Keyword.get(opts, :game) do
        nil -> params
        game -> Map.put(params, :game, game)
      end

    mount_screen(GameScreen, params)
  end

  defp play_id(view), do: assigns(view).throw.animation.play_id

  describe "mounting" do
    test "opens in the rolling phase: viewport, throw button, players tray" do
      view = mount_game()

      assert_renderable(view)
      assert assigns(view).game.phase == :rolling

      viewport = find(view, :native_view, id: :board)
      assert viewport.props.module == Mob.Scene3d.Viewport
      assert viewport.props.ir == assigns(view).scene

      assert find(view, :button, id: :throw)
      assert text(view) =~ "Collect rolls"
      assert text(view) =~ "Throw the shells"

      # All four players in the tray, all gated (no tod) at game start.
      for player <- 0..3, do: assert(find(view, :row, id: :"player_row_#{player}"))
      assert text(view) =~ "base 4 · home 0 · gated"
    end

    test "a fixture game state mounts directly (near-finish: tipped pawn in scene)" do
      view = mount_game(game: Fixtures.near_finish())

      {:ok, tipped} = IR.fetch(assigns(view).scene, "pawn_0_0")
      {x, _y, _z, w} = tipped.transform.rotation
      assert_in_delta x, 0.7071, 0.001
      assert_in_delta w, 0.7071, 0.001
    end
  end

  describe "the roll-collection phase" do
    test "a throw tumbles the shells, and the roll lands on animation_done" do
      ThrowsStub.script([2])
      view = mount_game() |> render_info({:tap, :throw})

      # In flight: tumble entity visible and animating, static shells hidden.
      assert %{shells: shells} = assigns(view).throw
      assert Enum.count(shells, & &1) == 2
      assert text(view) =~ "Shells are tumbling"
      {:ok, tumbles} = IR.fetch(assigns(view).scene, "tumbles")
      assert tumbles.visible
      assert tumbles.data.animation.name == "throw_k2_v0"
      {:ok, shell} = IR.fetch(assigns(view).scene, "shell_0")
      refute shell.visible

      # The roll applies only when the shells settle.
      assert assigns(view).game.turn_rolls == []
      view = render_info(view, {:animation_done, play_id(view)})

      assert assigns(view).throw == nil
      assert assigns(view).game.phase == :assigning
      assert assigns(view).game.pending == [2]
      assert text(view) =~ "Pending: 2"
      {:ok, tumbles} = IR.fetch(assigns(view).scene, "tumbles")
      refute tumbles.visible
    end

    test "special scores chain — throw again — until a non-special finalizes" do
      ThrowsStub.script([5, 2])
      view = mount_game() |> render_info({:tap, :throw})
      view = render_info(view, {:animation_done, play_id(view)})

      # 5 up scores 25: special, still rolling.
      assert assigns(view).game.phase == :rolling
      assert assigns(view).game.turn_rolls == [25]
      assert text(view) =~ "Rolls so far: 25"
      assert text(view) =~ "Special score — throw again!"
      assert find(view, :button, id: :throw).props.text == "Throw again"

      view = render_info(view, {:tap, :throw})
      view = render_info(view, {:animation_done, play_id(view)})

      assert assigns(view).game.phase == :assigning
      assert assigns(view).game.pending == [25, 2]
      # 25 unlocks from base — the assignment tray offers it.
      assert find(view, :button, text: "Unlock pawn 1 (25)")
    end

    test "a throw tap while shells are in flight is ignored" do
      ThrowsStub.script([2])
      view = mount_game() |> render_info({:tap, :throw})
      id = play_id(view)

      # The stub's script is exhausted — a second draw would raise.
      view = render_info(view, {:tap, :throw})
      assert play_id(view) == id
    end

    test "a stale animation_done is ignored" do
      ThrowsStub.script([2])
      view = mount_game() |> render_info({:tap, :throw})
      before = assigns(view).game

      view = render_info(view, {:animation_done, "some_other_play"})
      assert assigns(view).game == before
      assert %{shells: _still_in_flight} = assigns(view).throw
    end
  end

  describe "the assignment phase" do
    test "moving a pawn consumes the roll; an exhausted turn hands the device over" do
      view = mount_game(game: Fixtures.simple_move([4]))

      assert text(view) =~ "Assign moves"
      assert find(view, :button, text: "Move pawn 1 by 4")

      action = hd(Game.legal_actions(assigns(view).game))
      view = render_info(view, {:tap, {:action, action}})

      assert assigns(view).game.turn == 1
      assert text(view) =~ "Pass the device"
      assert find(view, :button, id: :handoff_done)
      # The board is hidden during handoff.
      refute find(view, :native_view, id: :board)

      view = render_info(view, {:tap, :handoff_done})
      assert text(view) =~ "Player 2"
      assert text(view) =~ "Collect rolls"
      assert find(view, :native_view, id: :board)
    end

    test "an unusable roll is offered as an explicit waste" do
      game =
        Chopaat.Support.Craft.game()
        |> Chopaat.Support.Craft.pawns(0, [50, :base, :base, :base])
        |> Chopaat.Support.Craft.assigning([7])

      view = mount_game(game: game)
      assert find(view, :button, text: "Waste the 7")
    end

    test "bonus steps show in the tray and assign independently" do
      view = mount_game(game: Fixtures.simple_move([4]) |> Map.put(:bonus_steps, 2))

      assert text(view) =~ "bonus +1 ×2"
      assert find(view, :button, text: "Bonus +1 → pawn 1")

      view = render_info(view, {:tap, {:action, {:bonus_step, 0}}})
      assert assigns(view).game.bonus_steps == 1
    end

    test "a capture grants tod and an extra turn for the same player" do
      view = mount_game(game: Fixtures.capture_ready())
      view = render_info(view, {:tap, {:action, {:assign, 0, 0}}})

      game = assigns(view).game
      assert game.tod[0]
      assert game.turn == 0
      assert game.phase == :rolling
      assert assigns(view).handoff == nil
      assert find(view, :text, id: :banner)
      assert text(view) =~ "Extra turn"
      # The victim went back to base.
      assert Game.base_count(game, 1) == 3
    end
  end

  describe "khadu confirmation" do
    test "khadu commits are gated: the dialog names the dana and pagdu that burn" do
      view = mount_game(game: Fixtures.mid_khadu())

      # Forced khadu preempts everything — every offered action is a khadu.
      actions = Game.legal_actions(assigns(view).game)
      assert actions != []
      assert Enum.all?(actions, &match?({:khadu, _roll, _pawn}, &1))
      assert find(view, :button, text: "Khadu — pawn 1 defaults with 7")

      before = assigns(view).game
      view = render_info(view, {:tap, {:action, hd(actions)}})

      # Dialog up, game untouched, action list hidden behind it.
      assert find(view, :column, id: :khadu_dialog)
      assert text(view) =~ "dana 2, 3"
      assert text(view) =~ "pagdu ×1"
      assert text(view) =~ "dana ane pagdu badi gaya"
      assert assigns(view).game == before
      refute find(view, :button, id: :action_0)

      # Cancel restores the choice.
      view = render_info(view, {:tap, :khadu_cancel})
      refute find(view, :column, id: :khadu_dialog)
      assert find(view, :button, id: :action_0)

      # Confirm commits: the pawn defaults, dana and pagdu burn.
      view = render_info(view, {:tap, {:action, hd(actions)}})
      view = render_info(view, {:tap, :khadu_confirm})

      game = assigns(view).game
      assert game != before
      assert Enum.all?(game.pending, &(&1 in [7, 11, 14, 25, 30]))
      assert game.bonus_steps == 0
    end

    test "with nothing else pending the dialog says no burn" do
      view = mount_game(game: Fixtures.gate_jam([7]))
      action = hd(Game.legal_actions(assigns(view).game))

      view = render_info(view, {:tap, {:action, action}})
      assert text(view) =~ "Nothing else is pending"
    end

    test "confirm without a pending khadu selection is a no-op" do
      view = mount_game(game: Fixtures.simple_move([4]))
      before = assigns(view).game

      view = render_info(view, {:tap, :khadu_confirm})
      assert assigns(view).game == before
    end
  end

  describe "game over" do
    test "placements render in finish order and the loser is named" do
      view = mount_game(game: Fixtures.finished())

      assert_renderable(view)
      assert text(view) =~ "Game over"
      assert find(view, :row, id: :placement_1)
      assert text(view) =~ "loses"

      view = render_info(view, {:tap, :back_to_menu})
      assert navigated_to(view) == {:pop}
    end
  end

  describe "chopaat-hre seam" do
    test "pawn pick events are received and deliberately unhandled here" do
      view = mount_game()
      before = assigns(view).game

      view = render_info(view, {:pawn_picked, "pawn_0_0"})
      assert assigns(view).game == before
    end
  end
end
