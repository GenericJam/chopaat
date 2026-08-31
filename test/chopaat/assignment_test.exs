defmodule Chopaat.AssignmentTest do
  @moduledoc false

  # Entry, movement, bonus steps, captures and tod — the assignment phase.
  # Cell collision used throughout (4 players): player 0's position 21 and
  # player 1's position 72 are both {:cell, 1, 2, 6} (non-safe); player 0's
  # 20 and player 1's 71 are both {:cell, 1, 2, 5} (safe).

  use ExUnit.Case, async: true

  alias Chopaat.Game
  alias Chopaat.Support.Craft

  describe "entry" do
    test "only entry scores unlock pawns from base" do
      game = Craft.assigning(Craft.game(), [11])

      assert Game.legal_actions(game) == for(ix <- 0..3, do: {:assign, 0, ix})
    end

    test "a non-entry roll with all pawns in base can only be wasted" do
      game = Craft.assigning(Craft.game(), [4])

      assert Game.legal_actions(game) == [{:waste, 0}]
    end

    test "unlocking places the pawn on the launch square, consuming the roll" do
      game = Craft.game() |> Craft.assigning([25, 3]) |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 0}
      assert game.pending == [3]
      assert game.turn_facts.unlocked
    end

    test "a captured pawn needs a fresh entry roll like any base pawn" do
      game =
        Craft.game()
        |> Craft.pawns(0, [:base, 10, 20, 30])
        |> Craft.assigning([3])

      refute {:assign, 0, 0} in Game.legal_actions(game)
    end
  end

  describe "rolls are atomic but independently assignable" do
    test "one roll moves one pawn its full value; rolls can stack on one pawn" do
      game =
        Craft.game()
        |> Craft.pawns(0, [10, 20, :home, :home])
        |> Craft.assigning([30, 2])
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 40}

      game = Craft.apply!(game, {:assign, 0, 0})
      assert Craft.pos(game, 0, 0) == {:track, 42}
    end

    test "a usable roll cannot be wasted" do
      game = Craft.game() |> Craft.pawns(0, [10, :home, :home, :home]) |> Craft.assigning([2])

      assert Game.legal_actions(game) == [{:assign, 0, 0}]
    end
  end

  describe "bonus steps" do
    test "entry-score rolls grant +1 bonus steps once the base is empty" do
      game =
        Craft.game()
        |> Craft.pawns(0, [10, 12, 14, 16])
        |> Craft.apply!({:roll, Craft.shells(5)})
        |> Craft.apply!({:roll, Craft.shells(2)})

      assert game.pending == [25, 2]
      assert game.bonus_steps == 1
    end

    test "no bonus step while a pawn remains in base" do
      game =
        Craft.game()
        |> Craft.pawns(0, [10, :base, :base, :base])
        |> Craft.apply!({:roll, Craft.shells(5)})
        |> Craft.apply!({:roll, Craft.shells(2)})

      assert game.bonus_steps == 0
    end

    test "cancelled rolls grant no bonus steps" do
      game =
        Craft.game()
        |> Craft.pawns(0, [10, 12, 14, 16])
        |> Craft.apply!({:roll, Craft.shells(5)})
        |> Craft.apply!({:roll, Craft.shells(5)})
        |> Craft.apply!({:roll, Craft.shells(5)})
        |> Craft.apply!({:roll, Craft.shells(2)})

      assert game.pending == [2]
      assert game.bonus_steps == 0
    end

    test "a bonus step is a free-floating +1 move on any pawn" do
      game =
        Craft.game()
        |> Craft.pawns(0, [10, 20, :home, :home])
        |> Craft.assigning([], 2)

      assert Enum.sort(Game.legal_actions(game)) == [{:bonus_step, 0}, {:bonus_step, 1}]

      game = Craft.apply!(game, {:bonus_step, 1})
      assert Craft.pos(game, 0, 1) == {:track, 21}
      assert game.bonus_steps == 1
    end
  end

  defp capture_setup do
    Craft.game()
    |> Craft.pawns(0, [19, :home, :home, :home])
    |> Craft.pawns(1, [72, 1, :base, :base])
    |> Craft.tod(1)
  end

  describe "capturing" do
    test "landing exactly on a lone enemy captures it and earns tod + extra turn" do
      game = capture_setup() |> Craft.assigning([2]) |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 1, 0) == :base
      assert game.tod[0]
      assert {game.turn, game.phase} == {0, :rolling}
    end

    test "passing over an enemy never captures" do
      game = capture_setup() |> Craft.assigning([4]) |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 23}
      assert Craft.pos(game, 1, 0) == {:track, 72}
      refute game.tod[0]
    end

    test "cumulative rolls on one pawn capture on the final exact landing" do
      game =
        capture_setup()
        |> Craft.pawns(0, [15, :home, :home, :home])
        |> Craft.assigning([4, 2])
        |> Craft.apply!({:assign, 0, 0})
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 21}
      assert Craft.pos(game, 1, 0) == :base
    end

    test "two same-owner pawns on a cell block enemy landings" do
      game =
        capture_setup()
        |> Craft.pawns(1, [72, 72, :base, :base])
        |> Craft.assigning([2])

      assert Game.legal_actions(game) == [{:waste, 0}]
    end

    test "an occupied safe cell cannot be landed on" do
      game =
        Craft.game()
        |> Craft.pawns(0, [18, :home, :home, :home])
        |> Craft.pawns(1, [71, 1, :base, :base])
        |> Craft.tod(1)
        |> Craft.assigning([2])

      assert Game.legal_actions(game) == [{:waste, 0}]
    end

    test "own pawns may stack" do
      game =
        Craft.game()
        |> Craft.pawns(0, [19, 21, :home, :home])
        |> Craft.assigning([2])
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 21}
      assert Craft.pos(game, 0, 1) == {:track, 21}
    end
  end

  describe "tod loss" do
    test "losing all four pawns to base loses the tod" do
      game =
        capture_setup()
        |> Craft.pawns(1, [72, :base, :base, :base])
        |> Craft.assigning([2])
        |> Craft.apply!({:assign, 0, 0})

      refute game.tod[1]
    end

    test "a pawn already home keeps the tod alive" do
      game =
        capture_setup()
        |> Craft.pawns(1, [72, :home, :base, :base])
        |> Craft.assigning([2])
        |> Craft.apply!({:assign, 0, 0})

      assert game.tod[1]
    end
  end
end
