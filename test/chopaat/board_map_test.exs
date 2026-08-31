defmodule Chopaat.Scene.BoardMapTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.Board
  alias Chopaat.Scene.BoardMap
  alias Chopaat.Variant

  doctest Chopaat.Scene.BoardMap

  @boards %{"board.glb" => 4, "board_6p.glb" => 6}

  test "the committed cell table is fresh against both board assets" do
    for {board, _players} <- @boards do
      derived = BoardMap.derive(Path.join("priv/assets", board))

      committed =
        Map.new(BoardMap.names(board), fn name ->
          {x, y, z} = BoardMap.position(board, name)
          {name, [x, y, z]}
        end)

      assert committed == derived,
             "#{board} cell table is stale — run mix chopaat.gen.cells"
    end
  end

  test "every position the engine can produce has a placement node" do
    for {asset, players} <- @boards do
      board = Board.build(Variant.gujarat(), players)
      names = MapSet.new(BoardMap.names(asset))

      for player <- 0..(players - 1) do
        for pos <- 0..(board.home - 1) do
          name = Board.cell_name(Board.cell(board, player, pos))
          assert MapSet.member?(names, name), "#{asset}: missing #{name}"
        end

        for seat <- 0..3 do
          assert MapSet.member?(names, "base_t#{player}_seat_#{seat}")
        end
      end

      assert MapSet.member?(names, "center_home")
    end
  end
end
