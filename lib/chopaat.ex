defmodule Chopaat do
  @moduledoc """
  Chopaat — the cross-and-circle cowrie game, Gujarat variation
  (see `RULESET.md`, the authoritative rules).

  This application currently ships the pure rules engine:

    * `Chopaat.Variant` — house rules as data; `:gujarat` is the default
    * `Chopaat.Board` — topology and the asset-shared cell addressing
    * `Chopaat.Rules` — throw scoring, cancellation, legal actions, khadus,
      captures, tod, finishing
    * `Chopaat.Game` — a pure event reducer over game state (roll
      collection, assignment, turns, placements, drought facts)
    * `Chopaat.RNG` — the only randomness: seedable shell draws, fair or
      drought-assisted
  """
end
