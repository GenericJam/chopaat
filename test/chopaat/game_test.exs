defmodule Chopaat.GameTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.Game
  alias Chopaat.Support.Craft
  alias Chopaat.Variant

  describe "new/2" do
    test "starts with all pawns in base, gates active, player 0 rolling" do
      game = Game.new(Variant.gujarat(), 4)

      assert {game.turn, game.phase} == {0, :rolling}
      assert Enum.all?(0..3, &(Game.base_count(game, &1) == 4))
      assert Enum.all?(Map.values(game.tod), &(&1 == false))
    end

    test "rejects unsupported player counts" do
      assert_raise MatchError, fn -> Game.new(Variant.gujarat(), 5) end
    end
  end

  describe "event validation" do
    test "rejects a wrong shell count" do
      assert Game.apply_event(Craft.game(), {:roll, [true, false]}) ==
               {:error, :bad_shell_count}
    end

    test "rejects assignment events while rolling and illegal actions while assigning" do
      assert Game.apply_event(Craft.game(), {:assign, 0, 0}) == {:error, :invalid_event}

      game = Craft.assigning(Craft.game(), [11])
      assert Game.apply_event(game, {:assign, 5, 0}) == {:error, :illegal_action}
    end

    test "rejects any event once finished" do
      game = %{Craft.game() | phase: :finished}

      assert Game.apply_event(game, {:roll, Craft.shells(2)}) == {:error, :game_over}
    end
  end

  describe "roll collection" do
    test "special scores keep the turn rolling; the first non-special finalizes" do
      game = Craft.game()

      game =
        Enum.reduce([6, 1, 6, 0], game, fn up, acc ->
          acc = Craft.apply!(acc, {:roll, Craft.shells(up)})
          assert acc.phase == :rolling
          acc
        end)

      game = Craft.apply!(game, {:roll, Craft.shells(3)})

      assert game.phase == :assigning
      assert game.pending == [30, 11, 30, 7, 3]
    end
  end

  describe "turn sequencing" do
    test "an unusable turn passes to the next player and counts both droughts" do
      game =
        Craft.game()
        |> Craft.apply!({:roll, Craft.shells(2)})
        |> Craft.apply!({:waste, 0})

      assert {game.turn, game.phase} == {1, :rolling}
      assert game.droughts[0] == %{entry: 1, move: 1}
    end

    test "an entry turn resets the droughts" do
      game =
        Craft.game()
        |> Craft.apply!({:roll, Craft.shells(1)})
        |> Craft.apply!({:roll, Craft.shells(3)})
        |> Craft.apply!({:assign, 0, 0})
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 3}
      assert game.turn == 1
      assert game.droughts[0] == %{entry: 0, move: 0}
    end

    test "a capture grants exactly one extra turn; a quiet extra turn passes on" do
      game =
        Craft.game()
        |> Craft.pawns(0, [19, :home, :home, :home])
        |> Craft.pawns(1, [72, 1, :base, :base])
        |> Craft.tod(1)
        |> Craft.assigning([2])
        |> Craft.apply!({:assign, 0, 0})

      assert {game.turn, game.phase} == {0, :rolling}

      game =
        game
        |> Craft.apply!({:roll, Craft.shells(3)})
        |> Craft.apply!({:assign, 0, 0})

      assert game.turn == 1
    end

    test "rotation skips players who already finished" do
      game =
        Craft.game()
        |> Craft.pawns(0, [10, :home, :home, :home])
        |> Craft.pawns(1, [:home, :home, :home, :home])
        |> Map.put(:placements, [1])
        |> Craft.assigning([2])
        |> Craft.apply!({:assign, 0, 0})

      assert game.turn == 2
    end
  end

  describe "finishing and placements" do
    test "finishing all four pawns records the placement and discards the rest of the turn" do
      game =
        Craft.game()
        |> Craft.pawns(0, [81, :home, :home, :home])
        |> Craft.tod(0)
        |> Craft.assigning([2, 3])
        |> Craft.apply!({:assign, 0, 0})

      assert game.placements == [0]
      assert {game.turn, game.phase} == {1, :rolling}
      assert game.pending == []
    end

    test "the game ends when all but one player finished; the last player loses" do
      game =
        Craft.game()
        |> Craft.pawns(0, [:home, :home, :home, :home])
        |> Craft.pawns(1, [:home, :home, :home, :home])
        |> Craft.pawns(2, [81, :home, :home, :home])
        |> Craft.tod(2)
        |> Map.put(:placements, [0, 1])
        |> Map.put(:turn, 2)
        |> Craft.assigning([2])
        |> Craft.apply!({:assign, 0, 0})

      assert game.phase == :finished
      assert game.placements == [0, 1, 2, 3]
    end
  end

  describe "drought assistance facts" do
    test "assisted after more than three turns of entry drought, reset mid-turn by an entry roll" do
      game = Craft.game()
      droughted = %{game | droughts: Map.put(game.droughts, 0, %{entry: 4, move: 0})}

      assert Game.assisted?(droughted, 0)
      refute Game.assisted?(droughted, 1)

      reset = Craft.apply!(droughted, {:roll, Craft.shells(1)})
      refute Game.assisted?(reset, 0)
    end

    test "assisted after more than three turns without a legal move, reset by a usable roll" do
      game =
        Craft.game()
        |> Craft.pawns(0, [10, :home, :home, :home])

      droughted = %{game | droughts: Map.put(game.droughts, 0, %{entry: 0, move: 4})}

      assert Game.assisted?(droughted, 0)

      reset = Craft.apply!(droughted, {:roll, Craft.shells(0)})
      refute Game.assisted?(reset, 0)
    end

    test "exactly three drought turns is not yet assisted" do
      game = Craft.game()
      droughts = %{game | droughts: Map.put(game.droughts, 0, %{entry: 3, move: 3})}

      refute Game.assisted?(droughts, 0)
    end
  end
end
