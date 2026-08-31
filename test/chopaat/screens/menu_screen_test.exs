defmodule Chopaat.Screens.MenuScreenTest do
  @moduledoc false

  use Mob.ScreenCase, async: false

  alias Chopaat.Screens.GameScreen
  alias Chopaat.Screens.MenuScreen
  alias Chopaat.Screens.SettingsScreen

  test "mounts with 4-player pass-and-play and greyed coming-soon modes" do
    view = mount_screen(MenuScreen)

    assert_renderable(view)
    assert assigns(view).num_players == 4
    for ix <- 0..3, do: assert(find(view, :text_field, id: :"player_name_#{ix}"))
    refute find(view, :text_field, id: :player_name_4)

    # Online/LAN are visible but inert — no tap handler.
    assert %{props: online_props} = find(view, :row, id: :coming_soon_online)
    refute Map.has_key?(online_props, :on_tap)
    assert find(view, :row, id: :coming_soon_lan)
    assert text(view) =~ "coming soon"
  end

  test "selecting 6 players grows the name list (RULESET.md player counts)" do
    view = mount_screen(MenuScreen) |> render_info({:tap, {:players, 6}})

    assert assigns(view).num_players == 6
    for ix <- 0..5, do: assert(find(view, :text_field, id: :"player_name_#{ix}"))
  end

  test "start builds a setup with the entered names and pushes the game screen" do
    view =
      MenuScreen
      |> mount_screen()
      |> render_info({:change, {:name, 0}, "Asha"})
      |> render_info({:tap, :start})

    assert navigated_to(view) == GameScreen
    assert is_integer(assigns(view).shell_seed)
  end

  test "the reshuffle toggle governs whether the shell seed is kept between games" do
    view = mount_screen(MenuScreen) |> render_info({:settings_reshuffle, false})
    assert assigns(view).reshuffle == false

    view = render_info(view, {:tap, :start})
    kept = assigns(view).shell_seed
    view = render_info(view, {:tap, :start})
    assert assigns(view).shell_seed == kept

    # Back on (the default), every start draws a fresh cosmetic seed.
    view = render_info(view, {:settings_reshuffle, true})
    view = render_info(view, {:tap, :start})
    refute assigns(view).shell_seed == kept
  end

  test "settings opens the settings screen" do
    view = mount_screen(MenuScreen) |> render_info({:tap, :settings})
    assert navigated_to(view) == SettingsScreen
  end

  # The push params carried to the game screen (in-BEAM nav action).
  defp pushed_params(view) do
    {:push, GameScreen, params} = view.socket.__mob__.nav_action
    params
  end

  describe "seat configuration (bead chopaat-27z)" do
    test "every seat mounts human with a cycling seat-type chip" do
      view = mount_screen(MenuScreen)

      for ix <- 0..3 do
        assert %{props: %{text: "Human"}} = find(view, :button, id: :"seat_type_#{ix}")
      end

      view = render_info(view, {:tap, {:seat_type, 1}})
      assert %{props: %{text: "Bot · easy"}} = find(view, :button, id: :seat_type_1)

      view = render_info(view, {:tap, {:seat_type, 1}})
      assert %{props: %{text: "Bot · normal"}} = find(view, :button, id: :seat_type_1)

      view = render_info(view, {:tap, {:seat_type, 1}})
      assert %{props: %{text: "Human"}} = find(view, :button, id: :seat_type_1)
    end

    test "start plumbs the configured bot seats (and their default names)" do
      view =
        MenuScreen
        |> mount_screen()
        |> render_info({:tap, {:seat_type, 1}})
        |> render_info({:tap, {:seat_type, 2}})
        |> render_info({:tap, {:seat_type, 2}})
        |> render_info({:change, {:name, 2}, "Asha"})
        |> render_info({:tap, :start})

      assert navigated_to(view) == GameScreen

      %{setup: setup, bots: bots} = pushed_params(view)
      assert bots == %{1 => Chopaat.Bot.Random, 2 => Chopaat.Bot.Heuristic}

      names = Enum.map(setup.players, & &1.name)
      # A typed name wins; an unnamed bot seat self-identifies.
      assert names == ["Player 1", "Bot 2", "Asha", "Player 4"]
    end

    test "AUTO makes every seat a normal bot and starts the game" do
      view =
        MenuScreen
        |> mount_screen()
        |> render_info({:tap, {:players, 6}})
        |> render_info({:tap, :auto})

      assert navigated_to(view) == GameScreen

      %{setup: setup, bots: bots} = pushed_params(view)
      assert bots == Map.new(0..5, &{&1, Chopaat.Bot.Heuristic})
      assert setup.num_players == 6
      assert Enum.map(setup.players, & &1.name) == Enum.map(1..6, &"Bot #{&1}")

      # The preset persists in the chips for the next visit to the menu.
      assert %{props: %{text: "Bot · normal"}} = find(view, :button, id: :seat_type_0)
    end
  end
end
