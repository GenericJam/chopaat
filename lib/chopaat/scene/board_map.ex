defmodule Chopaat.Scene.BoardMap do
  @moduledoc """
  Cell name → world position for both board assets, embedded at compile
  time from `priv/assets/board_cells.json` (regenerate with
  `mix chopaat.gen.cells` after any board asset change).

  The board `.glb`s export every cell as a named root-level empty at the
  cell's top surface (`assets/scripts/README.md` → Board addressing), so a
  pawn placed at a cell's translation stands on the board — engine
  position → `Chopaat.Board.cell/3` → `Chopaat.Board.cell_name/1` →
  `position/2` is the whole placement pipeline.
  """

  @table_path "priv/assets/board_cells.json"
  @external_resource @table_path

  @placement_prefixes ~w(cell_ base_ center_home)

  @table (case File.read(@table_path) do
            {:ok, json} ->
              for {board, cells} <- :json.decode(json), into: %{} do
                {board, Map.new(cells, fn {name, [x, y, z]} -> {name, {x, y, z}} end)}
              end

            {:error, reason} ->
              raise "#{@table_path} unreadable (#{inspect(reason)}) — run mix chopaat.gen.cells"
          end)

  @doc """
  World position `{x, y, z}` (meters, glTF frame) of a named placement
  node on a board asset.

      iex> {x, y, z} = Chopaat.Scene.BoardMap.position("board.glb", "cell_t0_l1_r1")
      iex> {Float.round(x, 3), Float.round(y, 3), Float.round(z, 3)}
      {0.0, 0.011, 0.1}
  """
  @spec position(String.t(), String.t()) :: {float(), float(), float()}
  def position(board, name), do: @table |> Map.fetch!(board) |> Map.fetch!(name)

  @doc "All placement node names for a board asset."
  @spec names(String.t()) :: [String.t()]
  def names(board), do: @table |> Map.fetch!(board) |> Map.keys()

  @doc """
  Derives the placement table straight from a board `.glb` — the source
  of truth `mix chopaat.gen.cells` snapshots and the freshness test
  compares against. Node names outside the placement set (meshes, the
  gate rims) are skipped.
  """
  @spec derive(Path.t()) :: %{String.t() => [float()]}
  def derive(glb_path) do
    for {name, %{translation: {x, y, z}}} <- Chopaat.Glb.named_nodes(glb_path),
        String.starts_with?(name, @placement_prefixes),
        into: %{} do
      {name, [x, y, z]}
    end
  end
end
