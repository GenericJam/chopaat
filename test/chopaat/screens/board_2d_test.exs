defmodule Chopaat.Screens.Board2DTest do
  @moduledoc false

  # Pure rendering: fixture game → session → observe/1 plain data →
  # node tree. No screen, no env seams — the 2D board is a function.
  use Mob.ScreenCase, async: true

  alias Chopaat.Board
  alias Chopaat.Screens.Board2D
  alias Chopaat.Session
  alias Chopaat.Setup
  alias Chopaat.Support.Craft
  alias Chopaat.Support.Fixtures

  # The 3D board's material palette, gamma-encoded (see board.py).
  @tile Setup.argb({0.070, 0.063, 0.055, 1.0})
  @safe Setup.argb({0.035, 0.11, 0.30, 1.0})
  @gate Setup.argb({0.45, 0.23, 0.035, 1.0})
  @shell_up Setup.argb({0.85, 0.62, 0.08, 1.0})
  @khadu_glow 0xFFCC2222

  defp observe(game, players) do
    setup = Setup.new(players, seed: 1)
    {:ok, session} = Session.start_link(setup: setup, game: game, rng_seed: 1)
    {Session.observe(session), setup}
  end

  defp tints(setup) do
    Map.new(0..(setup.num_players - 1), &{&1, Setup.argb(Setup.player(setup, &1).tint)})
  end

  defp render(game, opts \\ []) do
    {observed, setup} = observe(game, Keyword.get(opts, :players, 4))
    Board2D.render(observed, [on: self(), tints: tints(setup)] ++ opts)
  end

  describe "the cross (4 players)" do
    test "a fresh game: 19 grid rows, every cell addressed, base pads full" do
      tree = render(Craft.game())

      grid = find(tree, :column, id: :grid2d)
      assert Enum.count(grid.children) == 19

      # Every board cell renders as a box whose id IS its cell address.
      for track <- 0..3, lane <- 0..2, row <- 1..8 do
        assert find(tree, :box, id: :"cell_t#{track}_l#{lane}_r#{row}"),
               "missing cell t#{track} l#{lane} r#{row}"
      end

      # All 16 pawns start in base — a disc on every base pad slot.
      for seat <- 0..3, ix <- 0..3 do
        assert find(tree, :box, id: :"pawn2d_#{seat}_#{ix}")
        assert find(tree, :box, id: :"base2d_#{seat}_#{ix}")
      end

      # Nobody home yet: no center tally discs.
      for seat <- 0..3, do: refute(find(tree, :box, id: :"home2d_#{seat}"))

      assert_renderable(tree)
    end

    test "the visual language: safe blue, active gates ochre, tinted home lanes" do
      tree = render(Craft.game())

      # Row-5 peripheral safe cells are safe-blue.
      assert find(tree, :box, id: :cell_t0_l0_r5).props.background == @safe

      # Every seat's gate starts active (no tod): solid ochre. Seat 0's
      # gate (lap 54) sits on arm t3 lane 2 row 5.
      board = Board.build(Chopaat.Variant.gujarat(), 4)
      assert Board.cell(board, 0, board.gate) == {:cell, 3, 2, 5}

      for track <- 0..3 do
        assert find(tree, :box, id: :"cell_t#{track}_l2_r5").props.background == @gate
      end

      # Private middle lanes carry their owner's wash, not the plain tile.
      refute find(tree, :box, id: :cell_t0_l1_r3).props.background == @tile
      assert find(tree, :box, id: :cell_t0_l0_r3).props.background == @tile
    end

    test "a tod-holding player's gate opens: ochre ring on the safe cell" do
      tree = render(Craft.game() |> Craft.tod(0))

      gate = find(tree, :box, id: :cell_t3_l2_r5)
      assert gate.props.background == @safe
      assert gate.props.border_color == @gate
      assert gate.props.border_width == 2
    end
  end

  describe "pawns" do
    test "an on-track pawn renders as a tinted disc on its occupancy cell" do
      tree = render(Fixtures.simple_move())

      cell = find(tree, :box, id: :cell_t1_l2_r5)
      assert [%{props: %{id: :pawn2d_0_0}}] = cell.children
      # Tinted with seat 0's color.
      setup = Setup.new(4, seed: 1)
      assert hd(cell.children).props.background == Setup.argb(Setup.player(setup, 0).tint)
    end

    test "a stack shows its count; a tipped pawn its glyph; a jammed pawn its glyph" do
      stacked = Craft.game() |> Craft.pawns(0, [20, 20, :base, :base])
      tree = render(stacked)
      [disc] = find(tree, :box, id: :cell_t1_l2_r5).children
      assert find(disc, :text, text: "2")

      tree = render(Fixtures.near_finish())
      [tipped] = find(tree, :box, id: :cell_t0_l1_r5).children
      assert find(tipped, :text, text: "▸")

      tree = render(Fixtures.gate_jam())
      [jammed] = find(tree, :box, id: :cell_t3_l2_r5).children
      assert find(jammed, :text, text: "✕")
    end

    test "home pawns tally on the center seat slot" do
      tree = render(Fixtures.near_finish())

      home = find(tree, :box, id: :home2d_0)
      assert find(home, :text, text: "2")
      refute find(tree, :box, id: :home2d_1)
    end
  end

  describe "interaction wiring" do
    test "own-pawn cells tap as {:cell2d, name}; opponents' don't" do
      game =
        Craft.game()
        |> Craft.pawns(0, [20, :base, :base, :base])
        |> Craft.pawns(1, [20, :base, :base, :base])
        |> Craft.assigning([4])

      tree = render(game)

      own = find(tree, :box, id: :cell_t1_l2_r5)
      assert own.props.on_tap == {self(), {:cell2d, "cell_t1_l2_r5"}}

      # Player 1's lap 20 is on arm t2 — not the mover's pawn, no tap.
      other = find(tree, :box, id: :cell_t2_l2_r5)
      refute Map.has_key?(other.props, :on_tap)
    end

    test "base pads of the player to act tap as {:pawn2d, ix}" do
      tree = render(Fixtures.simple_move())

      assert find(tree, :box, id: :base2d_0_1).props.on_tap == {self(), {:pawn2d, 1}}
      refute Map.has_key?(find(tree, :box, id: :base2d_1_0).props, :on_tap)
    end

    test "outside the assigning phase nothing on the board taps" do
      tree = render(Craft.game() |> Craft.pawns(0, [20, :base, :base, :base]))

      refute Map.has_key?(find(tree, :box, id: :cell_t1_l2_r5).props, :on_tap)
      refute Map.has_key?(find(tree, :box, id: :base2d_0_0).props, :on_tap)
    end

    test "targets draw a glow border and tap as the tray's {:action, action}" do
      tree =
        render(Fixtures.simple_move(),
          selected: 0,
          targets: [%{action: {:assign, 0, 0}, cell: "cell_t1_l1_r8", khadu: false}]
        )

      target = find(tree, :box, id: :cell_t1_l1_r8)
      assert target.props.border_color == @shell_up
      assert target.props.on_tap == {self(), {:action, {:assign, 0, 0}}}

      # The selected pawn wears the ring.
      [disc] = find(tree, :box, id: :cell_t1_l2_r5).children
      assert disc.props.border_color == 0xFFFFFFFF
    end

    test "khadu targets glow red; a home landing highlights the seat's center slot" do
      tree =
        render(Fixtures.gate_jam(),
          selected: 0,
          targets: [
            %{action: {:khadu, 0, 0}, cell: "cell_t3_l2_r8", khadu: true},
            %{action: {:assign, 0, 1}, cell: "center_home", khadu: false}
          ]
        )

      khadu = find(tree, :box, id: :cell_t3_l2_r8)
      assert khadu.props.border_color == @khadu_glow
      assert khadu.props.on_tap == {self(), {:action, {:khadu, 0, 0}}}

      center = find(tree, :box, id: :center2d_0)
      assert center.props.border_color == @shell_up
      assert center.props.on_tap == {self(), {:action, {:assign, 0, 1}}}
      refute Map.has_key?(find(tree, :box, id: :center2d_1).props, :border_color)
    end
  end

  describe "the shell tray" do
    test "before any throw: muted rings, no score" do
      tree = render(Craft.game())

      for ix <- 0..6 do
        shell = find(tree, :box, id: :"shell2d_#{ix}")
        refute Map.has_key?(shell.props, :background)
        assert shell.props.border_width == 1
      end

      assert find(tree, :text, id: :shells2d_score).props.text == "—"
    end

    test "flips to the drawn configuration — up filled, down hollow — with the score" do
      shells = [true, false, true, false, false, false, false]
      tree = render(Craft.game(), last_throw: %{shells: shells, score: 2})

      assert find(tree, :box, id: :shell2d_0).props.background == @shell_up
      down = find(tree, :box, id: :shell2d_1)
      refute Map.has_key?(down.props, :background)
      assert down.props.border_color == @shell_up

      assert find(tree, :text, id: :shells2d_score).props.text == "2 up · 2"
    end
  end

  describe "the debug overlay" do
    test "labels arms, lanes, and rows so any cell address reads off the board" do
      tree = render(Craft.game() |> Craft.pawns(0, [20, :base, :base, :base]), debug: true)

      assert find(find(tree, :box, id: :cell_t2_l1_r8), :text, text: "t2")
      assert find(find(tree, :box, id: :cell_t1_l0_r7), :text, text: "l0")
      assert find(find(tree, :box, id: :cell_t3_l2_r3), :text, text: "3")

      # An occupied cell keeps its pawn disc, not a label.
      [disc] = find(tree, :box, id: :cell_t1_l2_r5).children
      assert disc.props.id == :pawn2d_0_0
    end

    test "off by default — no address labels" do
      tree = render(Craft.game())
      refute find(find(tree, :box, id: :cell_t2_l1_r8), :text, text: "t2")
    end
  end

  describe "the six-arm board" do
    test "lays out flat: center bar, six strips, base pads — same addressing" do
      tree = render(Craft.game(players: 6), players: 6)

      grid = find(tree, :column, id: :grid2d)
      assert Enum.count(grid.children) == 11

      for track <- 0..5, lane <- 0..2 do
        assert find(tree, :box, id: :"cell_t#{track}_l#{lane}_r1")
        assert find(tree, :box, id: :"cell_t#{track}_l#{lane}_r8")
      end

      for seat <- 0..5 do
        assert find(tree, :box, id: :"center2d_#{seat}")
        assert find(tree, :box, id: :"base2d_#{seat}_3")
      end

      # 6p gate is relative track 4: seat 0's gate lands on arm t4.
      board = Board.build(Chopaat.Variant.gujarat(), 6)
      assert Board.cell(board, 0, board.gate) == {:cell, 4, 2, 5}
      assert find(tree, :box, id: :cell_t4_l2_r5).props.background == @gate

      assert_renderable(tree)
    end
  end
end
