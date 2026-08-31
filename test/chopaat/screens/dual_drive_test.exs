defmodule Chopaat.Screens.DualDriveTest do
  @moduledoc false

  # Acceptance C for bead chopaat-85o (the owner's dual-drive note): a
  # game driven ENTIRELY through GameScreen taps while, after every
  # event batch, Chopaat.Support.DualDrive asserts the screen's rendered
  # state equals MachinePlay.observe/1 — the machine API as the oracle
  # for UI-driven games. Any divergence is a presentation bug by
  # construction (the two-plane model's bridge, reused at chopaat-4nn).

  # async: false — the scene3d support probe and scripted session draw
  # are app-env / run-global seams.
  use Mob.ScreenCase, async: false

  alias Chopaat.MachinePlay
  alias Chopaat.Screens.GameScreen
  alias Chopaat.Setup
  alias Chopaat.Support.DualDrive
  alias Chopaat.Support.Fixtures
  alias Chopaat.Support.ScriptedDice
  alias Chopaat.Support.ThrowsStub

  setup do
    Application.put_env(:chopaat, :throws, ThrowsStub)
    Application.put_env(:chopaat, :scene3d_support, :supported)

    on_exit(fn ->
      Application.delete_env(:chopaat, :throws)
      Application.delete_env(:chopaat, :scene3d_support)
    end)

    :ok
  end

  defp mount_game(opts \\ []) do
    params = %{
      setup: Setup.new(4, seed: 1),
      mode: :board2d,
      rng_seed: 1,
      draw: ScriptedDice.draw()
    }

    params =
      case Keyword.get(opts, :game) do
        nil -> params
        game -> Map.put(params, :game, game)
      end

    # The API oracle holds from the very first render.
    GameScreen |> mount_screen(params) |> DualDrive.assert_api()
  end

  test "several tap-driven turns hold the API oracle at every event batch" do
    # Turn 0: collect 25 then 2; unlock with the 25, advance 2; hand off.
    # Turn 1: a lone 3 with a full base has no use — waste it; hand off.
    ScriptedDice.script([5, 2, 3])
    view = mount_game()

    view = DualDrive.drive_ui(view, {:tap, :throw})
    assert assigns(view).game.turn_rolls == [25]

    view = DualDrive.drive_ui(view, {:tap, :throw})
    assert assigns(view).game.pending == [25, 2]

    view =
      view
      |> DualDrive.drive_ui({:tap, {:pawn2d, 0}})
      |> DualDrive.drive_ui({:tap, {:action, {:assign, 0, 0}}})

    assert MachinePlay.observe(assigns(view).session).occupancy == %{
             "cell_t0_l1_r1" => [%{seat: 0, pawn: 0}]
           }

    view =
      view
      |> DualDrive.drive_ui({:tap, {:cell2d, "cell_t0_l1_r1"}})
      |> DualDrive.drive_ui({:tap, {:action, {:assign, 0, 0}}})
      |> DualDrive.drive_ui({:tap, :handoff_done})

    view = DualDrive.drive_ui(view, {:tap, :throw})

    view =
      view
      |> DualDrive.drive_ui({:tap, {:action, {:waste, 0}}})
      |> DualDrive.drive_ui({:tap, :handoff_done})

    observed = MachinePlay.observe(assigns(view).session)
    assert observed.turn == 2
    assert observed.occupancy == %{"cell_t0_l1_r3" => [%{seat: 0, pawn: 0}]}
  end

  test "a tap-driven capture (extra turn) matches the API at each step" do
    view = mount_game(game: Fixtures.capture_ready())

    view =
      view
      |> DualDrive.drive_ui({:tap, {:cell2d, "cell_t2_l2_r1"}})
      |> DualDrive.drive_ui({:tap, {:action, {:assign, 0, 0}}})

    observed = MachinePlay.observe(assigns(view).session)
    assert Enum.at(observed.seats, 0).tod
    assert observed.turn == 0
    assert observed.occupancy["cell_t2_l2_r3"] == [%{seat: 0, pawn: 0}]
    assert text(view) =~ "Extra turn"
  end

  test "a forced khadu routed through the confirm dialog stays on-oracle" do
    view = mount_game(game: Fixtures.mid_khadu())

    view =
      view
      |> DualDrive.drive_ui({:tap, {:cell2d, "cell_t3_l2_r5"}})
      |> DualDrive.drive_ui({:tap, {:action, {:khadu, 0, 0}}})

    # The dialog is up, nothing committed — the oracle already held
    # inside drive_ui; the burn commits only on confirm.
    assert find(view, :column, id: :khadu_dialog)
    assert MachinePlay.observe(assigns(view).session).bonus_steps == 1

    view = DualDrive.drive_ui(view, {:tap, :khadu_confirm})

    observed = MachinePlay.observe(assigns(view).session)
    assert observed.pending == []
    assert observed.bonus_steps == 0
    assert observed.turn == 1
  end
end
