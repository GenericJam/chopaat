defmodule Chopaat.BoardTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.Board
  alias Chopaat.Variant

  doctest Chopaat.Board

  defp board(players), do: Board.build(Variant.gujarat(), players)

  # The lap per RULESET.md Movement, built independently of the code under
  # test: own lane 1 down, own lane 0 up, each foreign track (lane 2 down,
  # lane 1 row 8 transit, lane 0 up), own lane 2 down, connector, stretch.
  defp expected_lap(players, player) do
    arm = fn rel -> Integer.mod(player + rel, players) end

    own_out =
      for(r <- 1..8, do: {:cell, arm.(0), 1, r}) ++ for(r <- 8..1//-1, do: {:cell, arm.(0), 0, r})

    foreign =
      Enum.flat_map(1..(players - 1), fn t ->
        for(r <- 1..8, do: {:cell, arm.(t), 2, r}) ++
          [{:cell, arm.(t), 1, 8}] ++ for(r <- 8..1//-1, do: {:cell, arm.(t), 0, r})
      end)

    own_return =
      for(r <- 1..8, do: {:cell, arm.(0), 2, r}) ++
        [{:cell, arm.(0), 1, 8}] ++ for(r <- 7..1//-1, do: {:cell, arm.(0), 1, r})

    own_out ++ foreign ++ own_return
  end

  describe "lap geometry" do
    test "four-player lap visits the documented cell sequence for every seat" do
      board = board(4)

      for player <- 0..3 do
        lap = for pos <- 0..(board.home - 1), do: Board.cell(board, player, pos)
        assert lap == expected_lap(4, player)
      end
    end

    test "six-player lap visits the documented cell sequence for every seat" do
      board = board(6)

      for player <- 0..5 do
        lap = for pos <- 0..(board.home - 1), do: Board.cell(board, player, pos)
        assert lap == expected_lap(6, player)
      end
    end

    test "home position is one step past the final stretch" do
      assert Board.cell(board(4), 3, 83) == :center_home
      assert Board.cell(board(6), 5, 117) == :center_home
    end

    test "every on-board position has exactly one cell address" do
      board = board(4)

      for player <- 0..3, pos <- 0..(board.home - 1) do
        assert {:cell, track, lane, row} = Board.cell(board, player, pos)
        assert track in 0..3
        assert lane in 0..2
        assert row in 1..8
      end
    end
  end

  describe "landmarks" do
    test "gate sits on lane 2 row 5 of the gate track (relative 3 for 4p, 4 for 6p)" do
      assert Board.cell(board(4), 0, board(4).gate) == {:cell, 3, 2, 5}
      assert Board.cell(board(6), 0, board(6).gate) == {:cell, 4, 2, 5}
    end

    test "connector is the own middle-lane bottom cell" do
      assert Board.cell(board(4), 2, board(4).connector) == {:cell, 2, 1, 8}
      assert Board.cell(board(6), 3, board(6).connector) == {:cell, 3, 1, 8}
    end

    test "marker is own lane 1 row 6, six steps from home" do
      board = board(4)

      assert Board.cell(board, 0, board.marker) == {:cell, 0, 1, 6}
      assert Board.distance_home(board, board.marker) == 6
    end
  end

  describe "safe cells" do
    test "row 5 of both peripheral lanes and the lane-1 row-6 marker are safe" do
      assert Board.safe?({:cell, 2, 0, 5})
      assert Board.safe?({:cell, 1, 2, 5})
      assert Board.safe?({:cell, 0, 1, 6})
    end

    test "transit squares and ordinary cells are not safe" do
      refute Board.safe?({:cell, 0, 1, 8})
      refute Board.safe?({:cell, 3, 2, 6})
      refute Board.safe?({:cell, 1, 0, 4})
    end
  end

  describe "track numbering" do
    test "relative and absolute track mappings invert each other" do
      board = board(6)

      for player <- 0..5, rel <- 0..5 do
        assert Board.rel_track(board, player, Board.abs_track(board, player, rel)) == rel
      end
    end
  end
end
