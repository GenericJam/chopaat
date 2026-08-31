defmodule Chopaat.Game do
  @moduledoc """
  A game as a pure reducer: a state struct plus `apply_event/2`. No
  processes, no randomness — roll events carry the shell configuration
  (drawn elsewhere, e.g. `Chopaat.RNG`), assignment events carry a
  `Chopaat.Rules.action/0`.

  Phases:

    * `:rolling` — the player throws shells (`{:roll, shells}`); special
      scores keep the phase; the first non-special finalizes the turn's
      rolls (triple-repeat cancellation, bonus steps) into `pending`.
    * `:assigning` — the player issues assignment actions until every
      pending roll and bonus step is consumed; the turn then ends (with an
      extra turn if the player captured).
    * `:finished` — all placements decided; the last-placed player loses.

  The struct also carries the per-player drought counters and turn facts
  (`entry_available`, `action_available`, `unlocked`) that the RNG
  assistance layer consumes via `assisted?/2` — the rules expose the facts,
  the session layer applies the bias.
  """

  alias Chopaat.Board
  alias Chopaat.Pawn
  alias Chopaat.Rules
  alias Chopaat.Variant

  @type player :: non_neg_integer()
  @type phase :: :rolling | :assigning | :finished
  @type event :: {:roll, [boolean()]} | Rules.action()

  @enforce_keys [:variant, :board, :num_players, :pawns, :tod, :turn, :droughts]
  defstruct [
    :variant,
    :board,
    :num_players,
    :pawns,
    :tod,
    :turn,
    :droughts,
    phase: :rolling,
    turn_rolls: [],
    pending: [],
    bonus_steps: 0,
    captured_this_turn: false,
    turn_facts: %{unlocked: false, entry_available: false, action_available: false},
    placements: []
  ]

  @type t :: %__MODULE__{
          variant: Variant.t(),
          board: Board.t(),
          num_players: pos_integer(),
          pawns: %{player() => [Pawn.t()]},
          tod: %{player() => boolean()},
          turn: player(),
          droughts: %{player() => %{entry: non_neg_integer(), move: non_neg_integer()}},
          phase: phase(),
          turn_rolls: [pos_integer()],
          pending: [pos_integer()],
          bonus_steps: non_neg_integer(),
          captured_this_turn: boolean(),
          turn_facts: %{
            unlocked: boolean(),
            entry_available: boolean(),
            action_available: boolean()
          },
          placements: [player()]
        }

  @doc "A fresh game: all pawns in base, gates active, player 0 to roll."
  @spec new(Variant.t(), pos_integer()) :: t()
  def new(%Variant{} = variant \\ Variant.gujarat(), num_players) do
    true = num_players in variant.supported_player_counts
    players = 0..(num_players - 1)

    %__MODULE__{
      variant: variant,
      board: Board.build(variant, num_players),
      num_players: num_players,
      pawns: Map.new(players, &{&1, for(_pawn <- 1..variant.pawns_per_player, do: %Pawn{})}),
      tod: Map.new(players, &{&1, false}),
      turn: 0,
      droughts: Map.new(players, &{&1, %{entry: 0, move: 0}})
    }
  end

  @doc "Legal assignment actions (empty outside the `:assigning` phase)."
  @spec legal_actions(t()) :: [Rules.action()]
  def legal_actions(%__MODULE__{} = game), do: Rules.legal_actions(game)

  @doc "Advances the game by one event."
  @spec apply_event(t(), event()) :: {:ok, t()} | {:error, atom()}
  def apply_event(%__MODULE__{phase: :finished}, _event), do: {:error, :game_over}

  def apply_event(%__MODULE__{phase: :rolling} = game, {:roll, shells}) when is_list(shells) do
    case length(shells) == game.variant.shell_count do
      true -> {:ok, collect_roll(game, Rules.throw_score(game.variant, shells))}
      false -> {:error, :bad_shell_count}
    end
  end

  def apply_event(%__MODULE__{phase: :assigning} = game, action) do
    case Rules.apply_action(game, action) do
      {:ok, next} -> {:ok, sequence(next)}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_event(%__MODULE__{}, _event), do: {:error, :invalid_event}

  @doc """
  Whether this player's shells are currently assisted (70/30 up-bias):
  strictly more than the variant's drought limit of turns without an entry
  score for a remaining base pawn, or without any legal move — reset the
  moment either becomes available, including mid-turn.
  """
  @spec assisted?(t(), player()) :: boolean()
  def assisted?(%__MODULE__{} = game, player) do
    limit = game.variant.assist_drought_turns
    droughts = Map.fetch!(game.droughts, player)
    in_turn? = player == game.turn and game.phase == :rolling

    entry_reset? =
      in_turn? and base_count(game, player) > 0 and
        Enum.any?(game.turn_rolls, &Variant.entry?(game.variant, &1))

    move_reset? = in_turn? and Enum.any?(game.turn_rolls, &Rules.score_usable?(game, &1))

    (droughts.entry > limit and not entry_reset?) or
      (droughts.move > limit and not move_reset?)
  end

  @doc "How many of a player's pawns are still in base."
  @spec base_count(t(), player()) :: non_neg_integer()
  def base_count(%__MODULE__{pawns: pawns}, player) do
    pawns |> Map.fetch!(player) |> Enum.count(&(&1.pos == :base))
  end

  @doc "The final placement order (only complete once the game finishes)."
  @spec placements(t()) :: [player()]
  def placements(%__MODULE__{placements: placements}), do: placements

  # ── rolling ────────────────────────────────────────────────────────────

  defp collect_roll(game, throw) do
    game = %{game | turn_rolls: game.turn_rolls ++ [throw.score]}

    case throw.special do
      true -> game
      false -> finalize_rolls(game)
    end
  end

  defp finalize_rolls(game) do
    surviving = Rules.cancel_repeats(game.variant, game.turn_rolls)
    base = base_count(game, game.turn)

    bonus =
      case base do
        0 -> Enum.count(surviving, &Variant.bonus?(game.variant, &1))
        _pawns_in_base -> 0
      end

    entry_available? = base > 0 and Enum.any?(surviving, &Variant.entry?(game.variant, &1))

    game = %{
      game
      | pending: surviving,
        bonus_steps: bonus,
        phase: :assigning,
        turn_facts: %{game.turn_facts | entry_available: entry_available?}
    }

    action_available? = Enum.any?(Rules.legal_actions(game), &productive?/1)
    %{game | turn_facts: %{game.turn_facts | action_available: action_available?}}
  end

  defp productive?({:waste, _ix}), do: false
  defp productive?(:waste_bonus), do: false
  defp productive?(_action), do: true

  # ── sequencing ─────────────────────────────────────────────────────────

  defp sequence(game) do
    cond do
      finished?(game, game.turn) -> record_finish(game)
      game.pending == [] and game.bonus_steps == 0 -> end_turn(game)
      true -> game
    end
  end

  defp finished?(game, player) do
    game.pawns |> Map.fetch!(player) |> Enum.all?(&(&1.pos == :home))
  end

  defp record_finish(game) do
    game = %{game | placements: game.placements ++ [game.turn]}

    case length(game.placements) == game.num_players - 1 do
      true ->
        loser = Enum.find(players(game), &(&1 not in game.placements))
        %{reset_turn(game) | placements: game.placements ++ [loser], phase: :finished}

      false ->
        game |> Map.put(:captured_this_turn, false) |> end_turn()
    end
  end

  defp end_turn(game) do
    game = update_droughts(game)

    extra? = game.captured_this_turn and game.variant.capture_grants_extra_turn
    next = if extra?, do: game.turn, else: next_player(game)

    %{reset_turn(game) | turn: next}
  end

  defp reset_turn(game) do
    %{
      game
      | turn_rolls: [],
        pending: [],
        bonus_steps: 0,
        captured_this_turn: false,
        turn_facts: %{unlocked: false, entry_available: false, action_available: false},
        phase: :rolling
    }
  end

  defp next_player(game) do
    game.turn
    |> Stream.iterate(&rem(&1 + 1, game.num_players))
    |> Stream.drop(1)
    |> Enum.find(&(&1 not in game.placements))
  end

  defp players(game), do: Enum.to_list(0..(game.num_players - 1))

  defp update_droughts(game) do
    player = game.turn
    droughts = Map.fetch!(game.droughts, player)
    facts = game.turn_facts

    entry =
      cond do
        base_count(game, player) == 0 -> 0
        facts.unlocked or facts.entry_available -> 0
        true -> droughts.entry + 1
      end

    move =
      case facts.action_available do
        true -> 0
        false -> droughts.move + 1
      end

    %{game | droughts: Map.put(game.droughts, player, %{entry: entry, move: move})}
  end
end
