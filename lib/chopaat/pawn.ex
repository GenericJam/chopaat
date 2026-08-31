defmodule Chopaat.Pawn do
  @moduledoc """
  One pawn: its position on the owner's continuous lap scale, plus the
  gate-khadu `bypass` debt — true while the pawn still owes one skip of the
  private final stretch (set by a gate khadu that landed at or before the
  bottom middle-lane connector, cleared when the pawn wraps past it).

  Positions: `:base` (off-board reserve), `{:track, n}` with `n` in
  `0..home-1` on the owner's relative lap scale, or `:home` (finished).
  """

  defstruct pos: :base, bypass: false

  @type position :: :base | {:track, non_neg_integer()} | :home

  @type t :: %__MODULE__{pos: position(), bypass: boolean()}
end
