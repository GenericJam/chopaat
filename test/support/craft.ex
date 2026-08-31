defmodule Chopaat.Support.Craft do
  @moduledoc false

  alias Chopaat.Game
  alias Chopaat.Pawn
  alias Chopaat.Variant

  @doc "A fresh game (4 players, Gujarat variant by default)."
  def game(opts \\ []) do
    Game.new(Keyword.get(opts, :variant, Variant.gujarat()), Keyword.get(opts, :players, 4))
  end

  @doc "Puts the game straight into the assignment phase with these pending rolls."
  def assigning(game, pending, bonus_steps \\ 0) do
    %{game | phase: :assigning, pending: pending, bonus_steps: bonus_steps}
  end

  @doc """
  Places a player's pawns. Each entry: `:base`, `:home`, a track position,
  or `{position, :bypass}` for a pawn owing a gate-khadu bypass.
  """
  def pawns(game, player, positions) do
    pawns =
      Enum.map(positions, fn
        :base -> %Pawn{}
        :home -> %Pawn{pos: :home}
        {x, :bypass} -> %Pawn{pos: {:track, x}, bypass: true}
        x when is_integer(x) -> %Pawn{pos: {:track, x}}
      end)

    %{game | pawns: Map.put(game.pawns, player, pawns)}
  end

  @doc "Sets a player's tod flag."
  def tod(game, player, flag \\ true), do: %{game | tod: Map.put(game.tod, player, flag)}

  @doc "A shell list with the given up-count (7 shells)."
  def shells(up_count, shell_count \\ 7) do
    List.duplicate(true, up_count) ++ List.duplicate(false, shell_count - up_count)
  end

  @doc "Position of player 0's pawn `ix`."
  def pos(game, player, ix), do: Enum.at(Map.fetch!(game.pawns, player), ix).pos

  @doc "The pawn struct."
  def pawn(game, player, ix), do: Enum.at(Map.fetch!(game.pawns, player), ix)

  @doc "Applies an event, asserting success."
  def apply!(game, event) do
    {:ok, next} = Game.apply_event(game, event)
    next
  end
end
