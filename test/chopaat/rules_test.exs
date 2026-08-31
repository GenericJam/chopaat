defmodule Chopaat.RulesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  doctest Chopaat.Rules

  alias Chopaat.Rules
  alias Chopaat.Support.Craft
  alias Chopaat.Throw
  alias Chopaat.Variant

  describe "throw_score/2" do
    test "maps every shells-up count per the RULESET.md table" do
      variant = Variant.gujarat()
      scores = Map.new(0..7, fn up -> {up, Rules.throw_score(variant, up).score} end)

      assert scores == %{0 => 7, 1 => 11, 2 => 2, 3 => 3, 4 => 4, 5 => 25, 6 => 30, 7 => 14}
    end

    test "flags specials (extra roll) and entry scores" do
      variant = Variant.gujarat()

      assert %Throw{score: 30, special: true, entry: true} = Rules.throw_score(variant, 6)
      assert %Throw{score: 7, special: true, entry: false} = Rules.throw_score(variant, 0)
      assert %Throw{score: 14, special: true, entry: false} = Rules.throw_score(variant, 7)
      assert %Throw{score: 3, special: false, entry: false} = Rules.throw_score(variant, 3)
    end

    test "scores a shell configuration by its up-count" do
      variant = Variant.gujarat()
      shells = [true, false, true, false, false, false, false]

      assert Rules.throw_score(variant, shells) == Rules.throw_score(variant, 2)
      assert Rules.throw_score(variant, Craft.shells(5)).score == 25
    end
  end

  describe "cancel_repeats/2 (triple-repeat cancellation)" do
    test "a run of three identical rolls is nullified" do
      assert Rules.cancel_repeats(Variant.gujarat(), [25, 25, 25, 3]) == [3]
    end

    test "a fourth consecutive identical roll does not reset the count" do
      assert Rules.cancel_repeats(Variant.gujarat(), [30, 30, 30, 30, 3]) == [30, 3]
    end

    test "run of 6 cancels all six; run of 7 leaves only the seventh" do
      six = List.duplicate(7, 6)
      seven = List.duplicate(7, 7)

      assert Rules.cancel_repeats(Variant.gujarat(), six ++ [2]) == [2]
      assert Rules.cancel_repeats(Variant.gujarat(), seven ++ [2]) == [7, 2]
    end

    test "non-consecutive repeats are separate runs" do
      assert Rules.cancel_repeats(Variant.gujarat(), [30, 11, 30, 7, 3]) == [30, 11, 30, 7, 3]
      assert Rules.cancel_repeats(Variant.gujarat(), [11, 11, 25, 25, 25, 2]) == [11, 11, 2]
    end
  end

  describe "action_path/2 (move-animation waypoints, bead chopaat-hre)" do
    # 4p Gujarat geometry: gate 54, connector 75, marker 77, home 83.

    test "a plain move traverses each cell to the landing" do
      game = Craft.game() |> Craft.pawns(0, [20, :base, :base, :base]) |> Craft.assigning([4])

      assert Rules.action_path(game, {:assign, 0, 0}) ==
               [{:track, 21}, {:track, 22}, {:track, 23}, {:track, 24}]
    end

    test "an unlock steps onto the launch square" do
      game = Craft.game() |> Craft.assigning([25])
      assert Rules.action_path(game, {:assign, 0, 2}) == [{:track, 0}]
    end

    test "a bonus step is one cell" do
      game = Craft.game() |> Craft.pawns(0, [20, :base, :base, :base]) |> Craft.assigning([], 1)
      assert Rules.action_path(game, {:bonus_step, 0}) == [{:track, 21}]
    end

    test "a wrap-mode pawn skips the private passage at the connector" do
      game =
        Craft.game()
        |> Craft.tod(0)
        |> Craft.pawns(0, [{74, :bypass}, :home, :home, :home])
        |> Craft.assigning([3])

      # 75 is the connector; the next step skips the 15 private cells.
      assert Rules.action_path(game, {:assign, 0, 0}) ==
               [{:track, 75}, {:track, 8}, {:track, 9}]
    end

    test "a finishing move lands :home last" do
      game =
        Craft.game()
        |> Craft.tod(0)
        |> Craft.pawns(0, [80, :home, :home, :home])
        |> Craft.assigning([3])

      assert Rules.action_path(game, {:assign, 0, 0}) ==
               [{:track, 81}, {:track, 82}, :home]
    end

    test "a khadu reverses four cells then runs the full roll forward" do
      # RULESET.md finishing-khadu example: 72, roll 25 → 25.
      game =
        Craft.game()
        |> Craft.tod(0)
        |> Craft.pawns(0, [72, :home, :home, :home])
        |> Craft.assigning([25])

      path = Rules.action_path(game, {:khadu, 0, 0})

      assert Enum.take(path, 4) == [{:track, 71}, {:track, 70}, {:track, 69}, {:track, 68}]
      assert length(path) == 4 + 25
      assert List.last(path) == {:track, 25}
      # The private final stretch is skipped mid-path, not entered.
      assert {:track, 8} in path
      refute Enum.any?(path, &match?({:track, x} when x > 75, &1))
    end

    test "every path's landing agrees with the executed move" do
      game = Chopaat.Support.Fixtures.simple_move([7])
      [action | _rest] = Chopaat.Game.legal_actions(game)
      landing = game |> Rules.action_path(action) |> List.last()

      next = Craft.apply!(game, action)
      assert Craft.pos(next, 0, 0) == landing
    end

    test "waste actions traverse nothing" do
      game = Craft.game() |> Craft.assigning([2])
      assert Rules.action_path(game, {:waste, 0}) == []
      assert Rules.action_path(game, :waste_bonus) == []
    end
  end
end
