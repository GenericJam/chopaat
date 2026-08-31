defmodule Chopaat.Throws.Manifest do
  @moduledoc """
  The tumble library's runtime contract (`assets/tumble_manifest.json`),
  embedded at compile time: which baked takes exist per settled up-count,
  and the per-slot `aperture_up` array each take must settle into — the
  array the post-settle readback assertion (`Chopaat.Throws.Settle`)
  checks against. `gate.mjs` re-verifies the same manifest against the
  shipped GLB, so this module never re-reads the binary.
  """

  @manifest_path "assets/tumble_manifest.json"
  @external_resource @manifest_path

  @manifest @manifest_path |> File.read!() |> :json.decode()
  @animations Map.fetch!(@manifest, "animations")

  @takes_by_count @animations
                  |> Enum.group_by(fn {_name, meta} -> meta["count"] end, fn {name, _meta} ->
                    name
                  end)
                  |> Map.new(fn {count, names} -> {count, Enum.sort(names)} end)

  @aperture_up Map.new(@animations, fn {name, meta} ->
                 {name, Enum.map(meta["aperture_up"], &(&1 == true))}
               end)

  # tumble.py / gate.mjs classification threshold: |local +Y world-Y| ≥ 0.7.
  @up_axis_tolerance Map.fetch!(@manifest, "up_axis_tolerance")

  @doc "The baked take names whose settled configuration shows `up_count` up."
  @spec takes(non_neg_integer()) :: [String.t()]
  def takes(up_count), do: Map.fetch!(@takes_by_count, up_count)

  @doc "The per-slot settled aperture-up array for a take."
  @spec aperture_up(String.t()) :: [boolean()]
  def aperture_up(name), do: Map.fetch!(@aperture_up, name)

  @doc "All take names in the library."
  @spec names() :: [String.t()]
  def names, do: @aperture_up |> Map.keys() |> Enum.sort()

  @doc "The classifier tolerance the bake was accepted under."
  @spec up_axis_tolerance() :: float()
  def up_axis_tolerance, do: @up_axis_tolerance
end
