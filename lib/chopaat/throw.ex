defmodule Chopaat.Throw do
  @moduledoc """
  A scored shell throw: the shells-up count, the score it maps to via the
  variant table, and the derived flags — `special` (grants an extra roll)
  and `entry` (can unlock a pawn from base).
  """

  @enforce_keys [:up_count, :score, :special, :entry]
  defstruct [:up_count, :score, :special, :entry]

  @type t :: %__MODULE__{
          up_count: non_neg_integer(),
          score: pos_integer(),
          special: boolean(),
          entry: boolean()
        }
end
