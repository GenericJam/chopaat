defmodule Mix.Tasks.Chopaat.Gen.Cells do
  @shortdoc "Regenerates priv/assets/board_cells.json from the board .glb files"

  @moduledoc """
  Extracts the named placement nodes (`cell_t*_l*_r*`, `center_home`,
  `base_t*` seats) from `priv/assets/board.glb` and `board_6p.glb` into
  `priv/assets/board_cells.json` — the precomputed cell-transform table
  `Chopaat.Scene.BoardMap` embeds at compile time.

  The JSON is committed: pawn placement must not depend on parsing 600 KB
  of GLB at app boot, and the committed artifact makes the transforms
  reviewable. A freshness test (`test/chopaat/board_map_test.exs`)
  re-derives the table from the GLBs and fails when this task needs a
  re-run.

      mix chopaat.gen.cells
  """

  use Mix.Task

  @boards ~w(board.glb board_6p.glb)
  @output "priv/assets/board_cells.json"

  @impl Mix.Task
  def run(_args) do
    json =
      @boards
      |> Map.new(&{&1, Chopaat.Scene.BoardMap.derive(Path.join("priv/assets", &1))})
      |> :json.encode()
      |> IO.iodata_to_binary()

    File.write!(@output, json <> "\n")
    Mix.shell().info("wrote #{@output}")
  end
end
