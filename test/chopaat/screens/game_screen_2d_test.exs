defmodule Chopaat.Screens.GameScreen2DTest do
  @moduledoc false

  # async: false — the scene3d support probe and scripted session draw
  # are app-env / run-global seams.
  use Mob.ScreenCase, async: false

  alias Chopaat.Bot
  alias Chopaat.Screens.GameScreen
  alias Chopaat.Session
  alias Chopaat.Setup
  alias Chopaat.Support.Craft
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
      setup: Keyword.get(opts, :setup, Setup.new(4, seed: 1)),
      mode: Keyword.get(opts, :mode, :board2d),
      rng_seed: 1,
      draw: ScriptedDice.draw()
    }

    params =
      case Keyword.get(opts, :game) do
        nil -> params
        game -> Map.put(params, :game, game)
      end

    params =
      case Keyword.get(opts, :bots) do
        nil ->
          params

        bots ->
          # Real runners under a real supervisor, frozen by default (an
          # hour of delay) so spectator-HUD assertions hold still; the
          # composition test runs them live with bot_delay_ms: 0.
          params
          |> Map.put(:bots, bots)
          |> Map.put(:bot_delay_ms, Keyword.get(opts, :bot_delay_ms, 3_600_000))
      end

    mount_screen(GameScreen, params)
  end

  defp drive(view, message), do: view |> render_info(message) |> pump()

  defp pump(view) do
    receive do
      {:chopaat_session, _session, _seq, _event} = message ->
        pump(render_info(view, message))
    after
      0 -> view
    end
  end

  # Live bots act on their own cadence (delay 0): wait for each session
  # event, render it, and assert the 2D invariant — the presentation is
  # instant, so no tumble is ever in flight — at every step.
  defp pump_until(view, done?) do
    case done?.(assigns(view)) do
      true ->
        view

      false ->
        assert_receive {:chopaat_session, _session, _seq, _event} = message, 5_000
        view = render_info(view, message)
        assert assigns(view).throw == nil
        pump_until(view, done?)
    end
  end

  describe "mounting in 2D" do
    test "renders the grid board, no scene3d viewport, full HUD" do
      view = mount_game()

      assert_renderable(view)
      assert assigns(view).mode == :board2d
      assert assigns(view).notice == nil

      assert find(view, :column, id: :board2d)
      refute find(view, :native_view, id: :board)

      # The HUD is untouched: throw button, players tray, phase header.
      assert find(view, :button, id: :throw)
      assert text(view) =~ "Collect rolls"
      assert text(view) =~ "base 4 · home 0 · gated"

      # The mid-game toggle offers the OTHER mode.
      assert find(view, :button, id: :toggle_board_mode).props.text == "3D"
    end

    test "a 6-player game lays out the flat six-strip board" do
      view = mount_game(setup: Setup.new(6, seed: 1))

      assert find(view, :column, id: :board2d)
      assert find(view, :box, id: :cell_t5_l1_r4)
    end
  end

  describe "fallback when scene3d is unsupported" do
    test "a requested 3D board degrades to 2D with the one-line notice" do
      Application.put_env(:chopaat, :scene3d_support, :unsupported)
      view = mount_game(mode: :board3d)

      assert assigns(view).mode == :board2d
      assert find(view, :column, id: :board2d)
      refute find(view, :native_view, id: :board)
      assert find(view, :text, id: :board_mode_notice)
      assert text(view) =~ "3D board unsupported"
    end

    test "an explicit 2D request needs no notice, supported or not" do
      Application.put_env(:chopaat, :scene3d_support, :unsupported)
      view = mount_game(mode: :board2d)

      assert assigns(view).mode == :board2d
      assert assigns(view).notice == nil
    end

    test "toggling to 3D while unsupported stays on 2D and says why" do
      Application.put_env(:chopaat, :scene3d_support, :unsupported)
      view = mount_game(mode: :board2d) |> drive({:tap, :toggle_board_mode})

      assert assigns(view).mode == :board2d
      assert text(view) =~ "3D board unsupported"
    end
  end

  describe "the 2D throw" do
    test "presents instantly: shells flip to the drawn configuration, state adopts" do
      ScriptedDice.script([2])
      view = mount_game() |> drive({:tap, :throw})

      # No tumble, no animation_done — the session's truth is presented
      # the moment the event lands (the glyphs ARE the outcome).
      assert assigns(view).throw == nil
      assert assigns(view).game.phase == :assigning
      assert assigns(view).game.pending == [2]
      assert text(view) =~ "Pending: 2"

      shell_up = Setup.argb({0.85, 0.62, 0.08, 1.0})
      assert find(view, :box, id: :shell2d_0).props.background == shell_up
      assert find(view, :box, id: :shell2d_1).props.background == shell_up
      refute Map.has_key?(find(view, :box, id: :shell2d_2).props, :background)
      assert find(view, :text, id: :shells2d_score).props.text == "2 up · 2"
    end

    test "special scores chain exactly as in 3D — same session rules" do
      ScriptedDice.script([5, 2])
      view = mount_game() |> drive({:tap, :throw})

      assert assigns(view).game.phase == :rolling
      assert text(view) =~ "Rolls so far: 25"

      view = drive(view, {:tap, :throw})
      assert assigns(view).game.pending == [25, 2]
    end
  end

  describe "2D pick-to-move" do
    test "cell tap selects the pawn; its legal landing glows and taps to commit" do
      view = mount_game(game: Fixtures.simple_move([4]))

      view = drive(view, {:tap, {:cell2d, "cell_t1_l2_r5"}})
      assert assigns(view).selected == 0

      # Lap 20 + 4 = 24 → the t1 middle-lane transit square.
      target = find(view, :box, id: :cell_t1_l1_r8)
      assert target.props.on_tap == {self(), {:action, {:assign, 0, 0}}}

      view = drive(view, {:tap, {:action, {:assign, 0, 0}}})

      # Instant in 2D: no move performance, the handoff arrives directly.
      assert assigns(view).move == nil
      assert assigns(view).game.turn == 1
      assert assigns(view).handoff == %{player: 1}
      assert text(view) =~ "Pass the device"

      view = drive(view, {:tap, :handoff_done})
      assert find(view, :column, id: :board2d)

      # 2D never orbits — the 3D camera yaw snaps to the new seat so the
      # rig is right whenever the board toggles back (bead chopaat-4g7),
      # and input is never orbit-locked.
      assert assigns(view).orbit == nil
      assert assigns(view).camera_yaw == 90.0
    end

    test "a base pad tap selects for unlocking; the launch cell is the target" do
      view = mount_game(game: Craft.game() |> Craft.assigning([25]))

      view = drive(view, {:tap, {:pawn2d, 2}})
      assert assigns(view).selected == 2

      launch = find(view, :box, id: :cell_t0_l1_r1)
      assert launch.props.on_tap == {self(), {:action, {:assign, 0, 2}}}

      view = drive(view, {:tap, {:action, {:assign, 0, 2}}})
      assert Craft.pos(assigns(view).game, 0, 2) == {:track, 0}
    end

    test "tapping a stacked cell cycles the selection through the stack, then off" do
      game =
        Craft.game()
        |> Craft.pawns(0, [20, 20, :base, :base])
        |> Craft.assigning([4])

      view = mount_game(game: game)
      cell = {:tap, {:cell2d, "cell_t1_l2_r5"}}

      view = drive(view, cell)
      assert assigns(view).selected == 0
      view = drive(view, cell)
      assert assigns(view).selected == 1
      view = drive(view, cell)
      assert assigns(view).selected == nil
    end

    test "a khadu target routes through the same confirm dialog before committing" do
      view = mount_game(game: Fixtures.mid_khadu())

      view = drive(view, {:tap, {:cell2d, "cell_t3_l2_r5"}})
      assert assigns(view).selected == 0

      khadu = find(view, :box, id: :cell_t3_l2_r8)
      assert khadu.props.border_color == 0xFFCC2222
      assert khadu.props.on_tap == {self(), {:action, {:khadu, 0, 0}}}

      before = assigns(view).game
      view = drive(view, {:tap, {:action, {:khadu, 0, 0}}})

      assert find(view, :column, id: :khadu_dialog)
      assert text(view) =~ "dana ane pagdu badi gaya"
      assert assigns(view).game == before

      view = drive(view, {:tap, :khadu_confirm})
      assert assigns(view).game != before
      assert assigns(view).game.bonus_steps == 0
    end

    test "selection taps are inert off-phase and never select opponents" do
      rolling = mount_game() |> drive({:tap, {:cell2d, "cell_t0_l1_r1"}})
      assert assigns(rolling).selected == nil

      view = mount_game(game: Fixtures.capture_ready())
      # Player 1's pawn cell (lap 18 → t2 l2 r3) holds no own pawn: no-op.
      view = drive(view, {:tap, {:cell2d, "cell_t2_l2_r3"}})
      assert assigns(view).selected == nil
    end
  end

  describe "mode toggle mid-game (the session-boundary acceptance proof)" do
    test "2D → 3D → 2D keeps the same session and the same game state" do
      ScriptedDice.script([2])
      # A (frozen) bot on seat 1: the mid-game toggle must also preserve
      # the bot plumbing (composition with bead chopaat-27z).
      view = mount_game(bots: %{1 => Bot.Random}) |> drive({:tap, :throw})

      session = assigns(view).session
      bot_sup = assigns(view).bot_sup
      assert is_pid(bot_sup)
      game = assigns(view).game
      assert game.pending == [2]

      view = drive(view, {:tap, :toggle_board_mode})
      assert assigns(view).mode == :board3d
      assert assigns(view).session == session
      assert assigns(view).bot_sup == bot_sup
      assert assigns(view).game == game
      assert find(view, :native_view, id: :board)
      refute find(view, :column, id: :board2d)
      assert find(view, :button, id: :toggle_board_mode).props.text == "2D"
      # The 3D scene reflects the same settled shell configuration.
      assert assigns(view).last_shells == assigns(view).last_throw.shells

      view = drive(view, {:tap, :toggle_board_mode})
      assert assigns(view).mode == :board2d
      assert assigns(view).session == session
      assert assigns(view).bot_sup == bot_sup
      assert assigns(view).game == game
      assert find(view, :column, id: :board2d)
      assert text(view) =~ "Pending: 2"
    end

    test "toggling out of 3D mid-tumble drops the performance for the session's truth" do
      ScriptedDice.script([2])
      view = mount_game(mode: :board3d) |> drive({:tap, :throw})
      assert %{shells: _in_flight} = assigns(view).throw

      view = drive(view, {:tap, :toggle_board_mode})

      assert assigns(view).mode == :board2d
      assert assigns(view).throw == nil
      # The session had already advanced; 2D presents it immediately.
      assert assigns(view).game.pending == [2]
      assert find(view, :column, id: :board2d)
    end
  end

  describe "auto mode on the 2D board (composition: beads chopaat-u8x × chopaat-27z)" do
    @all_bots Map.new(0..3, &{&1, Bot.Heuristic})

    test "a full-auto 2D game runs to a placement and game over on scripted draws" do
      # Seats 1 and 2 already placed; seat 0's last pawn sits 4 short of
      # home. The scripted 4 lets the runners finish unattended: seat 0's
      # bot throws, assigns, places — the third placement ends the game.
      game =
        Craft.game()
        |> Craft.tod(0)
        |> Craft.pawns(0, [79, :home, :home, :home])
        |> Craft.pawns(1, [:home, :home, :home, :home])
        |> Craft.pawns(2, [:home, :home, :home, :home])

      game = %{game | placements: [1, 2]}

      ScriptedDice.script([4])
      view = mount_game(game: game, bots: @all_bots, bot_delay_ms: 0)

      # The mounted screen spectates on the grid: bot marker, no inputs.
      assert find(view, :column, id: :board2d)
      assert find(view, :text, id: :bot_marker)
      refute find(view, :button, id: :throw)

      view = pump_until(view, &(&1.game.phase == :finished))

      # The bots played through the session and the grid presented every
      # event instantly: no tumble mounted, no settle reads happened.
      assert assigns(view).throw == nil
      assert assigns(view).settle == %{ok: 0, mismatch: 0, skipped: 0, error: 0}
      assert assigns(view).game.placements == [1, 2, 0, 3]

      # The presented plain data is exactly the session's truth.
      assert assigns(view).observed == Session.observe(assigns(view).session)

      # The 2D game-over report carries the full-auto controls.
      assert find(view, :button, id: :rematch)
      assert find(view, :button, id: :auto_loop_toggle)
    end

    test "2D spectator taps are inert on a bot's turn" do
      view = mount_game(game: Fixtures.simple_move([4]), bots: %{0 => Bot.Heuristic})
      session = assigns(view).session

      view =
        view
        |> drive({:tap, {:cell2d, "cell_t1_l2_r5"}})
        |> drive({:tap, {:pawn2d, 0}})
        |> drive({:tap, {:action, {:assign, 0, 0}}})
        |> drive({:tap, :throw})

      assert assigns(view).selected == nil
      assert Session.observe(session).seq == 0
      assert assigns(view).game.pending == [4]
    end

    test "rematch from the 2D game-over report starts a fresh game on the grid" do
      view = mount_game(game: Fixtures.finished(), bots: @all_bots)

      assert find(view, :button, id: :rematch)
      view = drive(view, {:tap, :rematch})

      assert assigns(view).mode == :board2d
      assert assigns(view).game.phase == :rolling
      assert assigns(view).game.placements == []
      assert find(view, :column, id: :board2d)
      assert assigns(view).observed == Session.observe(assigns(view).session)
    end
  end

  describe "the debug overlay" do
    test "shows raw seq/phase/turn plus the last session event, and cell addresses" do
      ScriptedDice.script([2])
      view = mount_game() |> drive({:tap, :throw}) |> drive({:tap, :toggle_debug})

      status = find(view, :text, id: :debug_status)
      assert status.props.text =~ "phase assigning"
      assert status.props.text =~ "turn 0"
      assert status.props.text =~ "seq"
      assert status.props.text =~ ":throw_result"

      # Cell addresses on the board (empty middle-lane row 8 carries "t2").
      assert find(find(view, :box, id: :cell_t2_l1_r8), :text, text: "t2")

      view = drive(view, {:tap, :toggle_debug})
      refute find(view, :text, id: :debug_status)
    end
  end
end
