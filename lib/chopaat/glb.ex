defmodule Chopaat.Glb do
  @moduledoc """
  Minimal reader for the JSON chunk of a `.glb` (glTF 2.0 binary) file —
  just enough to pull named node transforms out of our own gated assets.

  The board assets export every cell as a named empty at the cell's top
  surface (`assets/scripts/README.md` → Board addressing); those nodes are
  root-level with plain `translation` arrays, which is all pawn placement
  needs. This module never touches buffer data.
  """

  @magic "glTF"
  @json_chunk 0x4E4F534A

  @doc """
  The named node transforms of a `.glb`: `%{name => %{translation: vec3,
  rotation: quat | nil}}`. Nodes without a name are skipped.
  """
  @spec named_nodes(Path.t()) :: %{String.t() => %{translation: tuple(), rotation: tuple() | nil}}
  def named_nodes(path) do
    for %{"name" => name} = node <- json_chunk(path)["nodes"] || [], into: %{} do
      {name,
       %{
         translation: vec(node["translation"], {0.0, 0.0, 0.0}),
         rotation: quat(node["rotation"])
       }}
    end
  end

  @doc "The decoded JSON chunk of a `.glb` file. Raises on a malformed header."
  @spec json_chunk(Path.t()) :: map()
  def json_chunk(path) do
    <<@magic, 2::little-32, _total::little-32, len::little-32, @json_chunk::little-32,
      json::binary-size(len), _rest::binary>> = File.read!(path)

    :json.decode(json)
  end

  defp vec([x, y, z], _default), do: {x * 1.0, y * 1.0, z * 1.0}
  defp vec(nil, default), do: default

  defp quat([x, y, z, w]), do: {x * 1.0, y * 1.0, z * 1.0, w * 1.0}
  defp quat(nil), do: nil
end
