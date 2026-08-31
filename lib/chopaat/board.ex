defmodule Chopaat.Board do
  @moduledoc """
  Board topology per RULESET.md, shared with the asset pipeline's addressing
  convention (`assets/scripts/README.md`).

  Cells are addressed `{:cell, track, lane, row}` where `track` is the
  ABSOLUTE arm index, counter-clockwise; `lane` 0/1/2 as seen from the
  center looking outward with lane 0 on the counter-clockwise side; `row` 1
  (nearest center) to 8 (outer end). The shared center is `:center_home`.
  Player `p`'s home arm is absolute track `p`; their relative track `t`
  (RULESET.md numbering) is absolute track `p + t` mod arms.

  Each player also has a continuous lap scale — position 0 (launch square,
  own lane 1 row 1) through `home - 1` (last on-board cell), with `home`
  (`17 * arms + 15`) the off-board center. The lap: down own lane 1
  (0..7), up own lane 0 (8..15), then for each foreign track lane 2 down,
  the lane 1 row 8 transit square, lane 0 up (17 cells each), then own
  lane 2 down, the own lane 1 row 8 connector (`home - 8`), and the 7-cell
  final stretch. The finishing safe/overshoot marker is `home - 6` (own
  lane 1 row 6).
  """

  alias Chopaat.Variant

  @rows 8

  @type lane :: 0 | 1 | 2
  @type cell :: {:cell, non_neg_integer(), lane(), 1..8} | :center_home

  @enforce_keys [:arms, :home, :connector, :gate, :marker, :khadu_skip]
  defstruct [:arms, :home, :connector, :gate, :marker, :khadu_skip]

  @type t :: %__MODULE__{
          arms: pos_integer(),
          home: pos_integer(),
          connector: pos_integer(),
          gate: pos_integer(),
          marker: pos_integer(),
          khadu_skip: pos_integer()
        }

  @doc """
  Builds the board for a variant and player count.

      iex> board = Chopaat.Board.build(Chopaat.Variant.gujarat(), 4)
      iex> {board.home, board.connector, board.gate, board.marker}
      {83, 75, 54, 77}

      iex> board = Chopaat.Board.build(Chopaat.Variant.gujarat(), 6)
      iex> {board.home, board.connector, board.gate, board.marker}
      {117, 109, 71, 111}
  """
  @spec build(Variant.t(), pos_integer()) :: t()
  def build(%Variant{} = variant, players) do
    true = players in variant.supported_player_counts
    home = (2 * @rows + 1) * players + 2 * @rows - 1
    gate_track = Map.fetch!(variant.gate_track_by_players, players)

    %__MODULE__{
      arms: players,
      home: home,
      connector: home - @rows,
      gate: 2 * @rows + (2 * @rows + 1) * (gate_track - 1) + 4,
      marker: home - 6,
      khadu_skip: 2 * @rows - 1
    }
  end

  @doc """
  The absolute cell under position `pos` of player `player`'s lap scale.

      iex> board = Chopaat.Board.build(Chopaat.Variant.gujarat(), 4)
      iex> Chopaat.Board.cell(board, 0, 0)
      {:cell, 0, 1, 1}
      iex> Chopaat.Board.cell(board, 0, 54)
      {:cell, 3, 2, 5}
      iex> Chopaat.Board.cell(board, 1, 75)
      {:cell, 1, 1, 8}
      iex> Chopaat.Board.cell(board, 2, 83)
      :center_home

      iex> board6 = Chopaat.Board.build(Chopaat.Variant.gujarat(), 6)
      iex> Chopaat.Board.cell(board6, 0, 71)
      {:cell, 4, 2, 5}
  """
  @spec cell(t(), non_neg_integer(), non_neg_integer()) :: cell()
  def cell(%__MODULE__{home: home}, _player, home), do: :center_home

  def cell(%__MODULE__{} = board, player, pos) when pos < board.home do
    {rel_track, lane, row} = relative_cell(board, pos)
    {:cell, abs_track(board, player, rel_track), lane, row}
  end

  @doc """
  The glTF node name for a cell, per the asset addressing convention.

      iex> Chopaat.Board.cell_name({:cell, 2, 0, 5})
      "cell_t2_l0_r5"
      iex> Chopaat.Board.cell_name(:center_home)
      "center_home"
  """
  @spec cell_name(cell()) :: String.t()
  def cell_name(:center_home), do: "center_home"
  def cell_name({:cell, track, lane, row}), do: "cell_t#{track}_l#{lane}_r#{row}"

  @doc """
  Absolute arm index of a player's relative track.

      iex> board = Chopaat.Board.build(Chopaat.Variant.gujarat(), 4)
      iex> Chopaat.Board.abs_track(board, 2, 3)
      1
  """
  @spec abs_track(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def abs_track(%__MODULE__{arms: arms}, player, rel), do: Integer.mod(player + rel, arms)

  @doc """
  A player's relative track number for an absolute arm index.

      iex> board = Chopaat.Board.build(Chopaat.Variant.gujarat(), 4)
      iex> Chopaat.Board.rel_track(board, 2, 1)
      3
  """
  @spec rel_track(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def rel_track(%__MODULE__{arms: arms}, player, abs), do: Integer.mod(abs - player, arms)

  @doc """
  Whether a cell is safe (no captures, opponents cannot land there while
  occupied): row 5 of both peripheral lanes on every arm, and row 6 of the
  private middle lane (the final-stretch marker).
  """
  @spec safe?(cell()) :: boolean()
  def safe?({:cell, _track, 0, 5}), do: true
  def safe?({:cell, _track, 2, 5}), do: true
  def safe?({:cell, _track, 1, 6}), do: true
  def safe?(_cell), do: false

  @doc "Remaining steps to home from a lap position."
  @spec distance_home(t(), non_neg_integer()) :: non_neg_integer()
  def distance_home(%__MODULE__{home: home}, pos), do: home - pos

  defp relative_cell(_board, pos) when pos in 0..7, do: {0, 1, pos + 1}
  defp relative_cell(_board, pos) when pos in 8..15, do: {0, 0, 16 - pos}

  defp relative_cell(%__MODULE__{arms: arms}, pos)
       when pos < 2 * @rows + (2 * @rows + 1) * (arms - 1) do
    track = div(pos - 2 * @rows, 2 * @rows + 1) + 1
    offset = rem(pos - 2 * @rows, 2 * @rows + 1)

    cond do
      offset < @rows -> {track, 2, offset + 1}
      offset == @rows -> {track, 1, @rows}
      true -> {track, 0, 2 * @rows + 1 - offset}
    end
  end

  defp relative_cell(%__MODULE__{connector: connector}, pos) when pos < connector do
    {0, 2, pos - connector + @rows + 1}
  end

  defp relative_cell(%__MODULE__{connector: connector}, connector), do: {0, 1, @rows}

  defp relative_cell(%__MODULE__{connector: connector}, pos) do
    {0, 1, connector + @rows - pos}
  end
end
