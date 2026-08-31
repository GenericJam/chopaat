defmodule Chopaat.PropertyTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chopaat.Rules
  alias Chopaat.Support.Invariants
  alias Chopaat.Support.Simulator
  alias Chopaat.Variant

  @moduletag timeout: 300_000

  property "random 4-player games terminate with full placements and no illegal state" do
    check all seed <- positive_integer(), max_runs: 40 do
      stats = Simulator.run(seed, players: 4, check: &Invariants.check!/1)

      assert Enum.sort(stats.placements) == [0, 1, 2, 3]
      assert stats.max_rolls_per_turn < 60
    end
  end

  property "random 6-player games terminate with full placements and no illegal state" do
    check all seed <- positive_integer(), max_runs: 10 do
      stats = Simulator.run(seed, players: 6, check: &Invariants.check!/1)

      assert Enum.sort(stats.placements) == [0, 1, 2, 3, 4, 5]
      assert stats.max_rolls_per_turn < 60
    end
  end

  property "every shell configuration scores through the variant table" do
    variant = Variant.gujarat()

    check all shells <- list_of(boolean(), length: 7) do
      throw = Rules.throw_score(variant, shells)
      up = Enum.count(shells, & &1)

      assert throw.up_count == up
      assert throw.score == Map.fetch!(variant.throw_table, up)
      assert throw.special == throw.score in [7, 11, 14, 25, 30]
      assert throw.entry == throw.score in [11, 25, 30]
    end
  end

  property "triple-repeat cancellation keeps exactly length-mod-3 of every run, from the tail" do
    variant = Variant.gujarat()
    scores = Map.values(variant.throw_table)

    check all rolls <- list_of(member_of(scores), min_length: 1, max_length: 30) do
      surviving = Rules.cancel_repeats(variant, rolls)

      expected =
        rolls
        |> Enum.chunk_by(& &1)
        |> Enum.flat_map(fn run ->
          List.duplicate(hd(run), rem(length(run), variant.repeat_cancel_group))
        end)

      assert surviving == expected
    end
  end
end
