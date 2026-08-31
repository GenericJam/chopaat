defmodule Chopaat.ThrowsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.RNG
  alias Chopaat.Throws
  alias Chopaat.Throws.Manifest
  alias Chopaat.Throws.Native
  alias Chopaat.Throws.Settle
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

  test "takes vary: many throws of the same outcome use different takes" do
    variant = Variant.gujarat()

    {names, _rng} =
      Enum.map_reduce(1..80, RNG.new(3), fn _i, rng ->
        {%{animation: animation}, rng} = Throws.Baked.throw(rng, variant, 0.5)
        {animation.name, rng}
      end)

    # Group by outcome: outcomes drawn several times should not be canned
    # onto one take (the manifest carries ≥4 takes per outcome).
    takes_used =
      names
      |> Enum.group_by(fn "throw_k" <> <<k::binary-size(1)>> <> _ -> k end)
      |> Enum.filter(fn {_k, list} -> Enum.count_until(list, 8) >= 8 end)

    assert takes_used != []
    assert Enum.all?(takes_used, fn {_k, list} -> match?([_, _ | _], Enum.uniq(list)) end)
  end

  describe "the tumble manifest contract" do
    test "every outcome has takes and every take a 7-slot aperture array" do
      for count <- 0..7 do
        takes = Manifest.takes(count)
        assert Enum.count_until(takes, 4) >= 4

        for name <- takes do
          up = Manifest.aperture_up(name)
          assert Enum.count(up) == 7
          assert Enum.count(up, & &1) == count
        end
      end
    end

    test "the classifier tolerance matches the bake acceptance rule" do
      assert Manifest.up_axis_tolerance() == 0.7
    end
  end

  describe "the settle classifier (tumble.py's rule over scene readback)" do
    # A column-major world matrix whose local +Y axis has world-Y `up_y`
    # (second column), unit-ish scale — the only part classify/1 reads.
    defp matrix(up_y) do
      x = :math.sqrt(max(1.0 - up_y * up_y, 0.0))
      [1.0, 0.0, 0.0, 0.0, x, up_y, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.1, 0.2, 0.3, 1.0]
    end

    defp scene_with(up_ys) do
      nodes = up_ys |> Enum.with_index() |> Map.new(fn {y, i} -> {"shell_#{i}", matrix(y)} end)
      %{"entities" => %{"tumbles" => %{"nodes" => nodes}}}
    end

    test "classify: aperture-up ⇔ local +Y world-Y ≤ −0.7, dome-up ⇔ ≥ +0.7" do
      assert Settle.classify(matrix(-1.0)) == :aperture_up
      assert Settle.classify(matrix(-0.71)) == :aperture_up
      assert Settle.classify(matrix(1.0)) == :dome_up
      assert Settle.classify(matrix(0.71)) == :dome_up
      assert {:ambiguous, _y} = Settle.classify(matrix(0.3))
      assert {:error, _reason} = Settle.classify(nil)
    end

    test "verify: matching orientations pass, a flipped slot fails loudly" do
      name = "throw_k4_v0"
      expected = Manifest.aperture_up(name)
      up_ys = Enum.map(expected, fn up? -> if up?, do: -0.99, else: 0.99 end)

      assert Settle.verify(scene_with(up_ys), name) == :ok

      flipped = List.update_at(up_ys, 0, &(-&1))
      assert {:mismatch, report} = Settle.verify(scene_with(flipped), name)
      assert report.animation == name
      assert Enum.count(report.observed) == 7

      # An ambiguous slot (never numerically settled) is also a mismatch.
      wobbling = List.update_at(up_ys, 3, fn _y -> 0.2 end)
      assert {:mismatch, _report} = Settle.verify(scene_with(wobbling), name)
    end

    test "verify: a readback without tumble nodes is a readback error" do
      assert {:error, {:no_tumble_nodes, _}} = Settle.verify(%{"entities" => %{}}, "throw_k0_v0")
    end
  end

  describe "the native impl (device default)" do
    test "draws the exact RNG sequence the baked impl draws" do
      variant = Variant.gujarat()
      {baked, _} = Throws.Baked.throw(RNG.new(42), variant, 0.5)
      {native, _} = Native.throw(RNG.new(42), variant, 0.5)

      assert native.shells == baked.shells
      assert native.animation.name == baked.animation.name
    end

    test "schedule_done is a no-op — the plugin delivers the event" do
      assert Native.schedule_done(self(), "abc") == :ok
      refute_receive {:animation_done, "abc"}, 10
    end

    test "throw honors the :throw_speed override (scripted acceptance)" do
      Application.put_env(:chopaat, :throw_speed, 4.0)
      on_exit(fn -> Application.delete_env(:chopaat, :throw_speed) end)

      {throw, _rng} = Native.throw(RNG.new(1), Variant.gujarat(), 0.5)
      assert throw.animation.speed == 4.0
    end

    test "settle_check without the native half degrades to :skipped" do
      assert Native.settle_check("board", "throw_k0_v0") == :skipped
    end
  end
end
