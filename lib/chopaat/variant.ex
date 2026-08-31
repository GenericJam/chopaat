defmodule Chopaat.Variant do
  @moduledoc """
  House rules as data. The engine reads this struct and nothing else for
  every family-disputed rule; the defaults are the owner's authoritative
  Gujarat variation, verbatim from `RULESET.md`.

  Fields:

    * `:throw_table` — shells-up count to score.
    * `:special_scores` — scores that grant an extra roll (collected within
      the same turn before assignment).
    * `:entry_scores` — scores that can unlock a pawn from base.
    * `:bonus_step_scores` — scores that grant a free-floating +1 bonus step
      when the player's base is empty.
    * `:repeat_cancel_group` — consecutive identical rolls cancel in complete
      groups of this size (`N % group` trailing rolls of a run survive).
    * `:gate_track_by_players` — the relative track holding each player's
      gate, keyed by player count.
    * `:khadu_reverse` — cells reversed before re-applying the roll in a
      khadu (both gate and finishing variants).
    * `:assist_drought_turns` — strictly more than this many drought turns
      switches that player's shells to `:assist_up_probability`.
    * `:gandi`, `:teams` — deferred rules (mad pawn, 2v2); representational
      room only, implemented as always-false for now.
  """

  @type score :: pos_integer()

  @type t :: %__MODULE__{
          name: atom(),
          shell_count: pos_integer(),
          throw_table: %{non_neg_integer() => score()},
          special_scores: [score()],
          entry_scores: [score()],
          bonus_step_scores: [score()],
          repeat_cancel_group: pos_integer(),
          pawns_per_player: pos_integer(),
          supported_player_counts: [pos_integer()],
          gate_track_by_players: %{pos_integer() => pos_integer()},
          khadu_reverse: pos_integer(),
          capture_grants_extra_turn: boolean(),
          assist_drought_turns: non_neg_integer(),
          fair_up_probability: float(),
          assist_up_probability: float(),
          gandi: boolean(),
          teams: boolean()
        }

  defstruct name: :gujarat,
            shell_count: 7,
            throw_table: %{0 => 7, 1 => 11, 2 => 2, 3 => 3, 4 => 4, 5 => 25, 6 => 30, 7 => 14},
            special_scores: [7, 11, 14, 25, 30],
            entry_scores: [11, 25, 30],
            bonus_step_scores: [11, 25, 30],
            repeat_cancel_group: 3,
            pawns_per_player: 4,
            supported_player_counts: [4, 6],
            gate_track_by_players: %{4 => 3, 6 => 4},
            khadu_reverse: 4,
            capture_grants_extra_turn: true,
            assist_drought_turns: 3,
            fair_up_probability: 0.5,
            assist_up_probability: 0.7,
            gandi: false,
            teams: false

  @doc "The authoritative Gujarat variation (RULESET.md), the default."
  @spec gujarat() :: t()
  def gujarat, do: %__MODULE__{}

  @doc "Whether a score grants an extra roll."
  @spec special?(t(), score()) :: boolean()
  def special?(%__MODULE__{special_scores: specials}, score), do: score in specials

  @doc "Whether a score can unlock a pawn from base."
  @spec entry?(t(), score()) :: boolean()
  def entry?(%__MODULE__{entry_scores: entries}, score), do: score in entries

  @doc "Whether a score grants a +1 bonus step when the base is empty."
  @spec bonus?(t(), score()) :: boolean()
  def bonus?(%__MODULE__{bonus_step_scores: bonuses}, score), do: score in bonuses
end
