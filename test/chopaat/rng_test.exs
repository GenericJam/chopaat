defmodule Chopaat.RNGTest do
  @moduledoc false

  # Fairness gates. The SCORE distribution is deliberately not uniform —
  # the shells-up count is what must match its binomial law: Binomial(7, .5)
  # for fair shells, Binomial(7, .7) for drought-assisted shells. Fixed
  # seeds make the chi-square values deterministic.

  use ExUnit.Case, async: true

  alias Chopaat.RNG

  @draws 100_000
  @shells 7
  # chi-square critical values at p = 0.001
  @crit_df7 24.322
  @crit_df127 181.993

  describe "determinism" do
    test "the same seed reproduces the same draw sequence" do
      {a, _rng} = RNG.draw(RNG.new(1234), @shells)
      {b, _rng} = RNG.draw(RNG.new(1234), @shells)
      {c, _rng} = RNG.draw(RNG.new(1235), @shells)

      assert a == b
      assert length(c) == @shells
    end
  end

  describe "fair shells (p = 0.5)" do
    test "shells-up counts match Binomial(7, 0.5) by chi-square over 100k draws" do
      counts = up_count_frequencies(42, 0.5)
      expected = fn k -> @draws * choose(@shells, k) / 128 end

      assert chi_square(counts, expected) < @crit_df7
    end

    test "every shell position is individually unbiased" do
      position_ups = position_frequencies(43, 0.5)

      chi2 =
        Enum.reduce(position_ups, 0.0, fn ups, acc ->
          acc + 4.0 * :math.pow(ups - @draws / 2, 2) / @draws
        end)

      assert chi2 < @crit_df7
    end

    test "full configurations are uniform over all 128 outcomes" do
      {counts, _rng} =
        Enum.reduce(1..@draws, {%{}, RNG.new(44)}, fn _draw, {acc, rng} ->
          {shells, rng} = RNG.draw(rng, @shells, 0.5)
          {Map.update(acc, shells, 1, &(&1 + 1)), rng}
        end)

      expected = @draws / 128

      chi2 =
        Enum.reduce(0..127, 0.0, fn code, acc ->
          config = for bit <- 6..0//-1, do: Bitwise.band(Bitwise.bsr(code, bit), 1) == 1
          observed = Map.get(counts, config, 0)
          acc + :math.pow(observed - expected, 2) / expected
        end)

      assert chi2 < @crit_df127
    end
  end

  describe "assisted shells (p = 0.7)" do
    test "shells-up counts match Binomial(7, 0.7) by chi-square over 100k draws" do
      counts = up_count_frequencies(45, 0.7)

      expected = fn k ->
        @draws * choose(@shells, k) * :math.pow(0.7, k) * :math.pow(0.3, @shells - k)
      end

      assert chi_square(counts, expected) < @crit_df7
    end

    test "assisted draws skew up: mean up-count is near 4.9, not 3.5" do
      counts = up_count_frequencies(46, 0.7)
      total_ups = Enum.reduce(counts, 0, fn {k, n}, acc -> acc + k * n end)
      mean = total_ups / @draws

      assert_in_delta mean, @shells * 0.7, 0.05
    end
  end

  defp up_count_frequencies(seed, up_probability) do
    {counts, _rng} =
      Enum.reduce(1..@draws, {%{}, RNG.new(seed)}, fn _draw, {acc, rng} ->
        {shells, rng} = RNG.draw(rng, @shells, up_probability)
        {Map.update(acc, Enum.count(shells, & &1), 1, &(&1 + 1)), rng}
      end)

    counts
  end

  defp position_frequencies(seed, up_probability) do
    {sums, _rng} =
      Enum.reduce(1..@draws, {List.duplicate(0, @shells), RNG.new(seed)}, fn _draw, {acc, rng} ->
        {shells, rng} = RNG.draw(rng, @shells, up_probability)
        {Enum.zip_with(acc, shells, fn n, up -> if up, do: n + 1, else: n end), rng}
      end)

    sums
  end

  defp chi_square(counts, expected) do
    Enum.reduce(0..@shells, 0.0, fn k, acc ->
      e = expected.(k)
      observed = Map.get(counts, k, 0)
      acc + :math.pow(observed - e, 2) / e
    end)
  end

  defp choose(n, k) do
    Enum.reduce(1..k//1, 1, fn i, acc -> div(acc * (n - i + 1), i) end)
  end
end
