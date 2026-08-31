defmodule Chopaat.ThrowsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.RNG
  alias Chopaat.Throws
  alias Chopaat.Variant

  test "the baked impl names a tumble matching the drawn up-count" do
    variant = Variant.gujarat()

    Enum.reduce(1..50, RNG.new(7), fn _i, rng ->
      {%{shells: shells, animation: animation}, rng} =
        Throws.Baked.throw(rng, variant, 0.5)

      assert Enum.count(shells) == 7
      up_count = Enum.count(shells, & &1)
      assert animation.name =~ ~r/^throw_k#{up_count}_v[0-3]$/
      rng
    end)
  end

  test "play_ids are unique per throw — replay is a play_id change" do
    variant = Variant.gujarat()
    {a, rng} = Throws.Baked.throw(RNG.new(1), variant, 0.5)
    {b, _rng} = Throws.Baked.throw(rng, variant, 0.5)

    refute a.animation.play_id == b.animation.play_id
  end

  test "the baked impl delivers completion itself (no native playback yet)" do
    Throws.Baked.schedule_done(self(), "abc")
    assert_receive {:animation_done, "abc"}
  end

  test "the drawn configuration is deterministic per RNG state" do
    variant = Variant.gujarat()
    {a, _} = Throws.Baked.throw(RNG.new(42), variant, 0.5)
    {b, _} = Throws.Baked.throw(RNG.new(42), variant, 0.5)

    assert a.shells == b.shells
    assert a.animation.name == b.animation.name
  end
end
