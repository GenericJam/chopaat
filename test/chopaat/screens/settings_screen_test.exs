defmodule Chopaat.Screens.SettingsScreenTest do
  @moduledoc false

  use Mob.ScreenCase, async: false

  alias Chopaat.Screens.SettingsScreen

  test "surfaces the variant config read-only" do
    view = mount_screen(SettingsScreen)

    assert_renderable(view)
    assert text(view) =~ "Variant — gujarat (read-only)"
    assert text(view) =~ "0↑=7"
    assert text(view) =~ "1↑=11"
    assert text(view) =~ "7, 11, 14, 25, 30"
    assert text(view) =~ "11, 25, 30"
    assert text(view) =~ "groups of 3"
    assert text(view) =~ "4p: track 3 · 6p: track 4"
    assert text(view) =~ "4 cells"
    assert text(view) =~ "> 3 turns"
    assert text(view) =~ "fair 0.5 · assisted 0.7"
  end

  test "the reshuffle toggle reports back to the owning screen" do
    view = mount_screen(SettingsScreen, %{reshuffle: true, parent: self()})
    assert find(view, :toggle, id: :reshuffle).props.value == true

    view = render_info(view, {:change, :reshuffle, false})

    assert assigns(view).reshuffle == false
    assert_receive {:settings_reshuffle, false}
    assert find(view, :toggle, id: :reshuffle).props.value == false
  end

  test "back pops the screen" do
    view = mount_screen(SettingsScreen) |> render_info({:tap, :back})
    assert navigated_to(view) == {:pop}
  end
end
