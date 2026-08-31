defmodule Chopaat.Bot do
  @moduledoc """
  The bot decision contract (bead chopaat-27z): a bot is a pure chooser
  over the session's PUBLIC state. It receives exactly what any remote
  client could see — `Chopaat.Session.observe/1`'s plain-data snapshot —
  plus the legal action terms `Chopaat.Session.legal_actions/2` returned,
  and must pick one of them. No cheating by construction: bots never see
  `Chopaat.Game` structs, the RNG state, or anything a human opponent
  couldn't read off the board.

  Deciding is pure and seedable: randomness is threaded as an explicit
  `Chopaat.RNG` state, so bot-vs-bot games are reproducible from seeds
  (the mass strength/termination suites depend on this).

  Bots are game-plane modules (they extend the boundary-test list): they
  may use the pure geometry helpers (`Chopaat.Board`) over the public
  board facts the observation carries, but never `Mob.*` or any
  `Chopaat.Scene*`/`Chopaat.Screens.*` module — a bot must be hostable
  headless, exactly like the session it drives.

  Implementations: `Chopaat.Bot.Random` (legal-random, the menu's
  Bot · easy) and `Chopaat.Bot.Heuristic` (Bot · normal). Turn pacing is
  not a bot concern — `Chopaat.Bot.Runner` owns cadence.

  The helpers below are shared observation arithmetic: landing positions
  recomputed from the public board facts (`arms`/`home`/`connector`/
  `gate`/`khadu_skip`) with the same wrap rules the ruleset defines.
  Legality is never re-derived here — the session already guaranteed the
  action list; bots only *rank* outcomes.
  """

  alias Chopaat.Board
  alias Chopaat.RNG
  alias Chopaat.Rules

  @typedoc "The `Chopaat.Session.observe/1` snapshot."
  @type observation :: map()

  @doc """
  Picks one action from `legal` (non-empty, exactly as
  `Chopaat.Session.legal_actions/2` returned it) given the public
  observation. Must return a member of `legal`; randomness (if any) is
  threaded through the `Chopaat.RNG` state.
  """
  @callback choose(observation(), [Rules.action()], RNG.t()) :: {Rules.action(), RNG.t()}

  @doc "The seat entry of the player to act."
  @spec me(observation()) :: map()
  def me(obs), do: Enum.at(obs.seats, obs.turn)

  @doc "The acting player's pawn entry `ix` (public pawn facts)."
  @spec pawn(observation(), non_neg_integer()) :: map()
  def pawn(obs, ix), do: Enum.at(me(obs).pawns, ix)

  @doc """
  Where an action lands, recomputed from public facts: `:entry` (unlock
  from base), `:home`, or `{:track, x}` on the actor's lap scale. Uses
  the same wrap rule as the rules engine: a pawn skips the private final
  stretch while its owner holds no tod, or while it owes a bypass.
  """
  @spec landing(observation(), Rules.action()) :: :entry | :home | {:track, non_neg_integer()}
  def landing(obs, {:assign, i, ix}) do
    case pawn(obs, ix) do
      %{state: :base} -> :entry
      %{track: x} = pawn -> forward(obs, pawn, x, Enum.at(obs.pending, i))
    end
  end

  def landing(obs, {:bonus_step, ix}) do
    %{track: x} = pawn = pawn(obs, ix)
    forward(obs, pawn, x, 1)
  end

  # Khadu: reverse 4 (the variant's khadu_reverse is board-implied via the
  # marker/connector facts; the reverse distance is the ruleset's 4),
  # continue forward by the full roll, skipping the private passage.
  def landing(obs, {:khadu, i, ix}) do
    %{track: x} = pawn(obs, ix)
    board = obs.board
    raw = x - khadu_reverse() + Enum.at(obs.pending, i)

    case raw > board.connector do
      true -> {:track, rem(raw + board.khadu_skip, board.home)}
      false -> {:track, raw}
    end
  end

  @doc "Whether an action's landing captures (an enemy sits on the cell)."
  @spec captures?(observation(), Rules.action()) :: boolean()
  def captures?(obs, action) do
    case landing(obs, action) do
      {:track, x} ->
        obs.occupancy
        |> Map.get(cell_name(obs, x), [])
        |> Enum.any?(&(&1.seat != obs.turn))

      _entry_or_home ->
        false
    end
  end

  @doc "Whether lap position `x` (for the actor) is a safe cell."
  @spec safe?(observation(), non_neg_integer()) :: boolean()
  def safe?(obs, x), do: Board.safe?(cell(obs, x))

  @doc "The actor's lap position `x` as the shared cell-name string."
  @spec cell_name(observation(), non_neg_integer()) :: String.t()
  def cell_name(obs, x), do: Board.cell_name(cell(obs, x))

  defp cell(obs, x), do: Board.cell(struct!(Board, obs.board), obs.turn, x)

  # RULESET.md: both khadu flavors reverse 4 cells before re-applying the
  # roll. A future variant surfacing a different reverse belongs in the
  # observation's board facts; until then the ruleset constant lives here.
  defp khadu_reverse, do: 4

  defp forward(obs, pawn, x, steps) do
    board = obs.board
    raw = x + steps
    wrap? = pawn.bypass or not me(obs).tod

    cond do
      wrap? and raw > board.connector -> {:track, rem(raw + board.khadu_skip, board.home)}
      raw == board.home -> :home
      true -> {:track, raw}
    end
  end
end
