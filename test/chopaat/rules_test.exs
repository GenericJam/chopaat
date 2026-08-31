defmodule Chopaat.RulesTest do
  @moduledoc false

  use ExUnit.Case, async: true

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
end
