defmodule Chopaat.VariantTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.Variant

  describe "gujarat/0" do
    test "throw table is the RULESET.md table verbatim" do
      assert Variant.gujarat().throw_table ==
               %{0 => 7, 1 => 11, 2 => 2, 3 => 3, 4 => 4, 5 => 25, 6 => 30, 7 => 14}
    end

    test "special, entry and bonus score sets" do
      variant = Variant.gujarat()

      assert variant.special_scores == [7, 11, 14, 25, 30]
      assert variant.entry_scores == [11, 25, 30]
      assert variant.bonus_step_scores == [11, 25, 30]
    end

    test "shells, pawns, cancellation group and player counts" do
      variant = Variant.gujarat()

      assert variant.shell_count == 7
      assert variant.pawns_per_player == 4
      assert variant.repeat_cancel_group == 3
      assert variant.supported_player_counts == [4, 6]
      assert variant.gate_track_by_players == %{4 => 3, 6 => 4}
    end

    test "assistance parameters" do
      variant = Variant.gujarat()

      assert variant.assist_drought_turns == 3
      assert variant.fair_up_probability == 0.5
      assert variant.assist_up_probability == 0.7
    end

    test "deferred rules are represented but off" do
      variant = Variant.gujarat()

      refute variant.gandi
      refute variant.teams
    end
  end

  describe "predicates" do
    test "special?/2, entry?/2 and bonus?/2 follow the score sets" do
      variant = Variant.gujarat()

      assert Enum.filter(Map.values(variant.throw_table), &Variant.special?(variant, &1))
             |> Enum.sort() == [7, 11, 14, 25, 30]

      assert Enum.filter(Map.values(variant.throw_table), &Variant.entry?(variant, &1))
             |> Enum.sort() == [11, 25, 30]

      refute Variant.bonus?(variant, 7)
      assert Variant.bonus?(variant, 25)
    end
  end
end
