defmodule Chopaat.Rules do
  @moduledoc """
  The pure rules of the Gujarat variation (RULESET.md). Every function takes
  everything it needs — shell results are inputs, never drawn here.

  A turn has two phases, sequenced by `Chopaat.Game`:

    * roll collection — special scores (7/11/14/25/30) chain extra rolls;
      the first non-special ends rolling; triple-repeat cancellation then
      yields the surviving rolls and bonus steps.
    * assignment — each surviving roll is an atomic move assigned to one
      pawn at a time, legality recomputed per assignment. Forced khadus
      (gate or finishing) preempt all other actions and burn pending
      `2`/`3`/`4` rolls and bonus steps (*dana ane pagdu badi gaya*).

  Assignment actions:

    * `{:assign, roll_index, pawn_index}` — unlock from base (entry scores)
      or a normal move by the roll's full value.
    * `{:bonus_step, pawn_index}` — spend one free-floating +1 step.
    * `{:khadu, roll_index, pawn_index}` — commit a forced gate/finishing
      khadu with a special roll.
    * `{:waste, roll_index}` / `:waste_bonus` — discard an unusable item.
  """

  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Pawn
  alias Chopaat.Throw
  alias Chopaat.Variant

  @type action ::
          {:assign, non_neg_integer(), non_neg_integer()}
          | {:bonus_step, non_neg_integer()}
          | {:khadu, non_neg_integer(), non_neg_integer()}
          | {:waste, non_neg_integer()}
          | :waste_bonus

  @doc """
  Scores a shell configuration (list of up-booleans, or the up-count itself)
  against the variant's throw table.
  """
  @spec throw_score(Variant.t(), [boolean()] | non_neg_integer()) :: Throw.t()
  def throw_score(%Variant{} = variant, shells) when is_list(shells) do
    throw_score(variant, Enum.count(shells, & &1))
  end

  def throw_score(%Variant{} = variant, up_count) when is_integer(up_count) do
    score = Map.fetch!(variant.throw_table, up_count)

    %Throw{
      up_count: up_count,
      score: score,
      special: Variant.special?(variant, score),
      entry: Variant.entry?(variant, score)
    }
  end

  @doc """
  Triple-repeat cancellation: for each run of consecutive identical scores,
  only `length(run) % group` trailing rolls survive; cancellation keeps
  consuming complete groups for as long as the run continues.
  """
  @spec cancel_repeats(Variant.t(), [pos_integer()]) :: [pos_integer()]
  def cancel_repeats(%Variant{repeat_cancel_group: group}, scores) do
    scores
    |> Enum.chunk_by(& &1)
    |> Enum.flat_map(fn run -> Enum.take(run, -rem(length(run), group)) end)
  end

  @doc "All legal assignment actions in the current state."
  @spec legal_actions(Game.t()) :: [action()]
  def legal_actions(%Game{phase: :assigning} = game) do
    ctx = context(game)

    case khadu_actions(game, ctx) do
      [] -> assign_actions(game, ctx) ++ bonus_actions(game, ctx) ++ waste_actions(game, ctx)
      khadus -> khadus
    end
  end

  def legal_actions(%Game{}), do: []

  @doc """
  Applies an assignment action, validating it against `legal_actions/1`.
  Handles unlocks, moves, wraps, khadus, captures, tod bookkeeping and burn;
  turn sequencing belongs to `Chopaat.Game`.
  """
  @spec apply_action(Game.t(), action()) :: {:ok, Game.t()} | {:error, :illegal_action}
  def apply_action(%Game{phase: :assigning} = game, action) do
    case action in legal_actions(game) do
      true -> {:ok, execute(game, action)}
      false -> {:error, :illegal_action}
    end
  end

  def apply_action(%Game{}, _action), do: {:error, :illegal_action}

  @doc """
  Whether a score has an ordinary use (unlock or normal move) for the player
  to move, independent of any pending-roll context. This is the "legal move
  becomes available" fact the RNG-assistance layer consumes.
  """
  @spec score_usable?(Game.t(), pos_integer()) :: boolean()
  def score_usable?(%Game{} = game, score) do
    ctx = %{context(game) | frozen: MapSet.new()}
    uses(game, ctx, score) != []
  end

  # ── context ────────────────────────────────────────────────────────────

  defp context(game) do
    player = game.turn
    pawns = Map.fetch!(game.pawns, player)
    base_ixs = for {%Pawn{pos: :base}, ix} <- Enum.with_index(pawns), do: ix
    total = Enum.sum(game.pending) + game.bonus_steps

    ctx = %{
      player: player,
      pawns: pawns,
      base_ixs: base_ixs,
      total: total,
      occupancy: occupancy(game),
      frozen: MapSet.new()
    }

    %{ctx | frozen: frozen_set(game, ctx)}
  end

  # Pawns below the row-6 marker whose remaining distance is exceeded by the
  # total of all still-pending rolls and bonus steps (finishing accounting).
  # Only applies once no pawns remain in base and a special roll is pending.
  defp frozen_set(game, ctx) do
    special_pending? = Enum.any?(game.pending, &Variant.special?(game.variant, &1))

    case ctx.base_ixs == [] and special_pending? do
      false ->
        MapSet.new()

      true ->
        board = game.board

        for {%Pawn{pos: {:track, x}} = pawn, ix} <- Enum.with_index(ctx.pawns),
            not wrap_mode?(game, ctx.player, pawn),
            x < board.marker,
            ctx.total > Board.distance_home(board, x),
            into: MapSet.new() do
          ix
        end
    end
  end

  defp occupancy(game) do
    for {player, pawns} <- game.pawns,
        {%Pawn{pos: {:track, x}}, ix} <- Enum.with_index(pawns),
        reduce: %{} do
      acc ->
        cell = Board.cell(game.board, player, x)
        Map.update(acc, cell, [{player, ix}], &[{player, ix} | &1])
    end
  end

  defp tod?(game, player), do: Map.fetch!(game.tod, player)

  defp gate_active?(game, player), do: not tod?(game, player)

  # A pawn skips the private final stretch: always while its owner holds no
  # tod (gate-khadu circulation), or once more while it owes a bypass.
  defp wrap_mode?(game, player, %Pawn{bypass: bypass}) do
    bypass or gate_active?(game, player)
  end

  # ── move geometry ──────────────────────────────────────────────────────

  defp move_target(game, player, %Pawn{pos: {:track, x}} = pawn, steps) do
    board = game.board
    raw = x + steps

    cond do
      gate_active?(game, player) and x <= board.gate and raw > board.gate ->
        :error

      wrap_mode?(game, player, pawn) and raw > board.connector ->
        {:ok, {:track, rem(raw + board.khadu_skip, board.home)}, true}

      raw > board.home ->
        :error

      raw == board.home ->
        {:ok, :home, false}

      true ->
        {:ok, {:track, raw}, false}
    end
  end

  defp landing(_game, _ctx, :home), do: {:ok, []}

  defp landing(game, ctx, {:track, x}) do
    cell = Board.cell(game.board, ctx.player, x)

    enemies =
      ctx.occupancy
      |> Map.get(cell, [])
      |> Enum.reject(fn {owner, _ix} -> owner == ctx.player end)

    case {enemies, Board.safe?(cell)} do
      {[], _safe} -> {:ok, []}
      {_occupied, true} -> :blocked
      {[lone], false} -> {:ok, [lone]}
      {_stack, false} -> :blocked
    end
  end

  # Ordinary uses of a score: unlock from base, or a normal move.
  defp uses(game, ctx, score) do
    entry? = Variant.entry?(game.variant, score)

    ctx.pawns
    |> Enum.with_index()
    |> Enum.flat_map(fn {pawn, ix} -> pawn_use(game, ctx, score, pawn, ix, entry?) end)
  end

  defp pawn_use(_game, _ctx, _score, %Pawn{pos: :base}, ix, true), do: [{:unlock, ix}]
  defp pawn_use(_game, _ctx, _score, %Pawn{pos: :base}, _ix, false), do: []
  defp pawn_use(_game, _ctx, _score, %Pawn{pos: :home}, _ix, _entry), do: []

  defp pawn_use(game, ctx, score, %Pawn{pos: {:track, _}} = pawn, ix, _entry) do
    with false <- MapSet.member?(ctx.frozen, ix),
         {:ok, target, wrapped} <- move_target(game, ctx.player, pawn, score),
         {:ok, captures} <- landing(game, ctx, target) do
      [{:move, ix, target, wrapped, captures}]
    else
      _unusable -> []
    end
  end

  # ── actions ────────────────────────────────────────────────────────────

  defp assign_actions(game, ctx) do
    for {score, i} <- Enum.with_index(game.pending),
        use <- uses(game, ctx, score) do
      {:assign, i, use_pawn(use)}
    end
  end

  defp bonus_actions(%Game{bonus_steps: 0}, _ctx), do: []

  defp bonus_actions(game, ctx) do
    for {:move, ix, _target, _wrapped, _captures} <- uses(game, ctx, 1), do: {:bonus_step, ix}
  end

  defp waste_actions(game, ctx) do
    rolls =
      for {score, i} <- Enum.with_index(game.pending),
          uses(game, ctx, score) == [] do
        {:waste, i}
      end

    case game.bonus_steps > 0 and bonus_actions(game, ctx) == [] do
      true -> rolls ++ [:waste_bonus]
      false -> rolls
    end
  end

  defp use_pawn({:unlock, ix}), do: ix
  defp use_pawn({:move, ix, _target, _wrapped, _captures}), do: ix

  # Forced khadus: only once no pawns remain in base, only with a special
  # roll that has no ordinary use on any pawn; qualifying pawns are those
  # blocked at/by the active gate, or endangered per finishing accounting.
  # When any khadu is forced it preempts every other action.
  defp khadu_actions(_game, %{base_ixs: [_ | _]}), do: []

  defp khadu_actions(game, ctx) do
    for {score, i} <- Enum.with_index(game.pending),
        Variant.special?(game.variant, score),
        uses(game, ctx, score) == [],
        {%Pawn{pos: {:track, x}}, ix} <- Enum.with_index(ctx.pawns),
        gate_blocked?(game, ctx.player, x, score) or MapSet.member?(ctx.frozen, ix),
        {target, _wrapped} = khadu_landing(game, x, score),
        match?({:ok, _captures}, landing(game, ctx, {:track, target})) do
      {:khadu, i, ix}
    end
  end

  defp gate_blocked?(game, player, x, score) do
    board = game.board
    gate_active?(game, player) and x <= board.gate and x + score > board.gate
  end

  # Reverse `khadu_reverse` cells, continue forward by the full roll; skip
  # the private passage (+`khadu_skip`, mod home) when the path passes the
  # bottom middle-lane connector.
  defp khadu_landing(game, x, score) do
    board = game.board
    raw = x - game.variant.khadu_reverse + score

    case raw > board.connector do
      true -> {rem(raw + board.khadu_skip, board.home), true}
      false -> {raw, false}
    end
  end

  # ── execution ──────────────────────────────────────────────────────────

  defp execute(game, {:assign, i, ix}) do
    score = Enum.at(game.pending, i)
    ctx = context(game)

    case Enum.at(ctx.pawns, ix) do
      %Pawn{pos: :base} ->
        game
        |> put_pawn(ctx.player, ix, %Pawn{pos: {:track, 0}, bypass: false})
        |> put_fact(:unlocked, true)
        |> consume_roll(i)

      %Pawn{pos: {:track, _}} = pawn ->
        {:ok, target, wrapped} = move_target(game, ctx.player, pawn, score)

        game
        |> land(ctx, ix, pawn, target, wrapped)
        |> consume_roll(i)
    end
  end

  defp execute(game, {:bonus_step, ix}) do
    ctx = context(game)
    pawn = Enum.at(ctx.pawns, ix)
    {:ok, target, wrapped} = move_target(game, ctx.player, pawn, 1)

    game
    |> land(ctx, ix, pawn, target, wrapped)
    |> Map.update!(:bonus_steps, &(&1 - 1))
  end

  defp execute(game, {:khadu, i, ix}) do
    score = Enum.at(game.pending, i)
    ctx = context(game)
    %Pawn{pos: {:track, x}} = pawn = Enum.at(ctx.pawns, ix)
    gate_khadu? = gate_blocked?(game, ctx.player, x, score)
    {target, wrapped} = khadu_landing(game, x, score)
    debt = gate_khadu? and not wrapped

    game
    |> land(ctx, ix, %{pawn | bypass: debt}, {:track, target}, wrapped)
    |> burn_dana(i)
  end

  defp execute(game, {:waste, i}), do: consume_roll(game, i)

  defp execute(game, :waste_bonus), do: Map.update!(game, :bonus_steps, &(&1 - 1))

  # Landing: place the mover (clearing its bypass debt if it wrapped),
  # capture any lone enemy on the cell, and settle tod bookkeeping.
  defp land(game, ctx, ix, pawn, target, wrapped) do
    {:ok, captures} = landing(game, ctx, target)
    bypass = target != :home and not wrapped and pawn.bypass

    game
    |> put_pawn(ctx.player, ix, %{pawn | pos: target, bypass: bypass})
    |> resolve_captures(ctx.player, captures)
  end

  defp resolve_captures(game, _player, []), do: game

  defp resolve_captures(game, player, captures) do
    game =
      Enum.reduce(captures, game, fn {owner, ix}, acc ->
        put_pawn(acc, owner, ix, %Pawn{pos: :base, bypass: false})
      end)

    game = %{game | tod: Map.put(game.tod, player, true), captured_this_turn: true}

    captures
    |> Enum.map(fn {owner, _ix} -> owner end)
    |> Enum.uniq()
    |> Enum.reduce(game, &lose_tod_if_all_dead(&2, &1))
  end

  # Tod is lost when all of a player's pawns are simultaneously back in
  # base; a pawn already home keeps the tod alive.
  defp lose_tod_if_all_dead(game, player) do
    case Enum.all?(Map.fetch!(game.pawns, player), &(&1.pos == :base)) do
      true -> %{game | tod: Map.put(game.tod, player, false)}
      false -> game
    end
  end

  # Committing a khadu burns every pending 2/3/4 roll and all bonus steps.
  defp burn_dana(game, committed_ix) do
    pending =
      game.pending
      |> List.delete_at(committed_ix)
      |> Enum.filter(&Variant.special?(game.variant, &1))

    %{game | pending: pending, bonus_steps: 0}
  end

  defp put_pawn(game, player, ix, pawn) do
    %{game | pawns: Map.update!(game.pawns, player, &List.replace_at(&1, ix, pawn))}
  end

  defp put_fact(game, key, value) do
    %{game | turn_facts: Map.put(game.turn_facts, key, value)}
  end

  defp consume_roll(game, i), do: %{game | pending: List.delete_at(game.pending, i)}
end
