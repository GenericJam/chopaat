defmodule Chopaat.Support.Invariants do
  @moduledoc false

  import ExUnit.Assertions

  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Pawn

  @doc "Asserts every structural invariant of a game state; raises on violation."
  def check!(%Game{} = game) do
    check_pawns!(game)
    check_cells!(game)
    check_gate_discipline!(game)
    check_turn!(game)
    :ok
  end

  defp check_pawns!(game) do
    Enum.each(game.pawns, fn {player, pawns} ->
      assert length(pawns) == game.variant.pawns_per_player,
             "player #{player} pawn count drifted"

      Enum.each(pawns, fn pawn -> assert valid_position?(game.board, pawn) end)
    end)
  end

  defp valid_position?(_board, %Pawn{pos: :base}), do: true
  defp valid_position?(_board, %Pawn{pos: :home}), do: true
  defp valid_position?(board, %Pawn{pos: {:track, x}}), do: x >= 0 and x < board.home
  defp valid_position?(_board, _pawn), do: false

  defp check_cells!(game) do
    game.pawns
    |> Enum.flat_map(fn {player, pawns} ->
      for %Pawn{pos: {:track, x}} <- pawns, do: {Board.cell(game.board, player, x), player}
    end)
    |> Enum.group_by(fn {cell, _player} -> cell end, fn {_cell, player} -> player end)
    |> Enum.each(fn {cell, owners} ->
      assert match?([_single_owner], Enum.uniq(owners)),
             "cell #{Board.cell_name(cell)} occupied by two players"
    end)
  end

  defp check_gate_discipline!(game) do
    Enum.each(game.pawns, fn {player, pawns} ->
      tod? = Map.fetch!(game.tod, player)

      Enum.each(pawns, fn pawn -> check_pawn_discipline!(game.board, tod?, pawn) end)
    end)
  end

  defp check_pawn_discipline!(board, tod?, %Pawn{pos: {:track, x}} = pawn) do
    if x > board.gate and not tod? do
      assert pawn.bypass, "no-tod pawn beyond the gate without a khadu bypass debt"
    end

    if x > board.connector do
      assert tod? and not pawn.bypass, "pawn in the final stretch without tod / with debt"
    end
  end

  defp check_pawn_discipline!(_board, _tod?, _pawn), do: :ok

  defp check_turn!(game) do
    assert game.turn in 0..(game.num_players - 1)
    assert game.placements == Enum.uniq(game.placements)
    assert game.bonus_steps >= 0
    assert Enum.all?(game.pending, &(&1 in Map.values(game.variant.throw_table)))

    case game.phase do
      :finished ->
        assert length(game.placements) == game.num_players

      :assigning ->
        assert game.turn not in game.placements
        assert Game.legal_actions(game) != [], "assigning phase with no legal action (stall)"

      :rolling ->
        assert game.turn not in game.placements
    end
  end
end
