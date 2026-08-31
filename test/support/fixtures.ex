defmodule Chopaat.Support.Fixtures do
  @moduledoc """
  Interesting game positions for screen tests, built on `Craft`. All are
  4-player Gujarat games (gate 54, connector 75, marker 77, home 83) with
  player 0 to act.
  """

  alias Chopaat.Support.Craft

  @doc """
  Gate jam: all four of player 0's pawns stuck behind the active gate with
  a special roll pending — every legal action is a `{:khadu, _, _}`.
  """
  def gate_jam(pending \\ [7]) do
    Craft.game()
    |> Craft.pawns(0, [54, 53, 52, 51])
    |> Craft.assigning(pending)
  end

  @doc """
  Mid-khadu with a burn at stake: the khadu is forced while dana (a 2 and
  a 3) and a pagdu (bonus step) are still pending — committing must burn
  them (dana ane pagdu badi gaya).
  """
  def mid_khadu do
    Craft.game()
    |> Craft.pawns(0, [54, 53, 52, 51])
    |> Craft.assigning([7, 2, 3], 1)
  end

  @doc """
  Near-finish: player 0 holds a tod; one pawn is deep in the private final
  stretch (tipped visually), one mid-lap, two home.
  """
  def near_finish do
    Craft.game()
    |> Craft.tod(0)
    |> Craft.pawns(0, [78, 40, :home, :home])
  end

  @doc "A movable single-pawn position: one pawn mid-lap, a 4 pending."
  def simple_move(pending \\ [4]) do
    Craft.game()
    |> Craft.pawns(0, [20, :base, :base, :base])
    |> Craft.assigning(pending)
  end

  @doc """
  Capture at hand: player 0's pawn lands exactly on player 1's lone pawn
  with the pending roll, granting a tod and an extra turn.
  """
  def capture_ready do
    # Player 0's lap 35 is {:cell, 2, 2, 3} (not safe); player 1's lap 18
    # sits on the same absolute cell — a 2 from lap 33 lands exactly on it.
    Craft.game()
    |> Craft.pawns(0, [33, :base, :base, :base])
    |> Craft.pawns(1, [18, 1, :base, :base])
    |> Craft.assigning([2])
  end

  @doc "A finished 4-player game (placements 1,2,0 with 3 losing)."
  def finished do
    game = Craft.game()

    %{
      game
      | phase: :finished,
        placements: [1, 2, 0, 3],
        pawns:
          Map.new(0..3, fn player ->
            {player, List.duplicate(%Chopaat.Pawn{pos: :home}, 4)}
          end)
    }
  end
end
