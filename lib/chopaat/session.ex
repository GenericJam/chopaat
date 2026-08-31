defmodule Chopaat.Session do
  @moduledoc """
  The presentation-agnostic host of one game (owner ruling, AGENTS.md
  "Presentation is a client"): a process owning the pure `Chopaat.Game`
  reducer, the `Chopaat.RNG` state, the variant, the player config and
  cosmetic seed (`Chopaat.Setup`), and the drought-assist facts. Every
  renderer — 3D, 2D, a projected web client — and every headless driver
  (bots, the machine API) is a *client* of this process: commands in,
  events out, all plain data.

  Commands are seat-checked calls; each accepted command returns the
  events it produced and broadcasts the same events to every subscriber
  as `{:chopaat_session, session_pid, seq, event}` with `seq` strictly
  increasing. The event vocabulary is designed for renderers and recorded
  in `decisions/2026-08-31-session-boundary.md` (the chopaat-85o protocol
  doc will formalize its serialization).

  The throw flow (rules first, animation performs the answer): `throw/2`
  draws the shells server-side — fair or drought-assisted per
  `Chopaat.Game.assisted?/2` — plus one uniform *cosmetic* integer, and
  applies the roll immediately. Presentation is a grace, not a
  dependency: the session never waits for any renderer ack; a client that
  wants to tumble shells holds its own presented state until its
  animation settles, and a headless client ignores the cosmetic entirely.
  Renderers map `cosmetic` onto their take library (`rem/2` by take
  count) so every client presents the identical outcome.

  Khadu commits are destructive (*dana ane pagdu badi gaya*), so they are
  explicit at the API level: `assign/3` refuses `{:khadu, _, _}` actions
  with `{:error, :khadu_requires_confirmation}`; only `confirm_khadu/3`
  commits one.

  `observe/1` is the machine-facing public state: strictly
  JSON-serializable (maps, lists, numbers, strings, whitelisted atoms —
  no tuples), board occupancy keyed by cell-name strings. `game/1` and
  `setup/1` return the underlying structs for in-BEAM clients (renderers
  may depend on game modules; game modules never depend on renderers —
  enforced by `Chopaat.BoundaryTest`).
  """

  use GenServer

  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Pawn
  alias Chopaat.RNG
  alias Chopaat.Rules
  alias Chopaat.Setup
  alias Chopaat.Variant

  @typedoc "Anything `GenServer.call/2` accepts."
  @type session :: GenServer.server()

  @typedoc "A seat index, `0..num_players-1` (the reducer's player id)."
  @type seat :: non_neg_integer()

  @type event ::
          {:game_started, map()}
          | {:throw_result, map()}
          | {:moved, map()}
          | {:captured, map()}
          | {:khadu, map()}
          | {:wasted, map()}
          | {:turn_passed, map()}
          | {:placement, map()}
          | {:game_over, map()}

  @cosmetic_range 2 ** 32

  # ── client API ───────────────────────────────────────────────────────────

  @doc """
  Starts a session.

  Options:

    * `:setup` — a `Chopaat.Setup` (players, variant, cosmetic seed);
      built from `:players` / `:names` / `:variant` when absent.
    * `:players` — player count when no `:setup` is given (default 4).
    * `:rng_seed` — the game-randomness seed (default: unique). All
      randomness lives here, server-side.
    * `:game` — an initial `Chopaat.Game` state (test fixtures, resume).
    * `:draw` — shells-draw injection for deterministic tests:
      `(variant, up_probability, rng) -> {shells, rng}`. Defaults to
      `Chopaat.RNG.draw/3`.
    * `:name` — optional `GenServer` registration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Resets to a fresh game, same seats. Options: `:rng_seed`, `:game`, and
  `:reshuffle` — `true` draws a fresh cosmetic shell set (a rematch keeps
  the players but re-rolls the presentation seed, bead chopaat-27z).
  """
  @spec new_game(session(), keyword()) :: {:ok, [event()]}
  def new_game(session, opts \\ []), do: GenServer.call(session, {:new_game, opts})

  @doc "The full public state as JSON-serializable plain data."
  @spec observe(session()) :: map()
  def observe(session), do: GenServer.call(session, :observe)

  @doc "The current `Chopaat.Game` snapshot (in-BEAM client convenience)."
  @spec game(session()) :: Game.t()
  def game(session), do: GenServer.call(session, :game)

  @doc "The session's `Chopaat.Setup` (seats, tints, cosmetic shell set)."
  @spec setup(session()) :: Setup.t()
  def setup(session), do: GenServer.call(session, :setup)

  @doc """
  The full session state — `%{game:, rng:, setup:, seq:}` — for
  diagnostics, persistence, and host-side predictors (the device
  acceptance script replays `draw_throw/3` against this snapshot).
  """
  @spec export(session()) :: %{game: Game.t(), rng: RNG.t(), setup: Setup.t(), seq: integer()}
  def export(session), do: GenServer.call(session, :export)

  @doc """
  The exact action terms `assign/3` / `confirm_khadu/3` accept for a
  seat — `[]` off-turn or outside the `:assigning` phase.
  """
  @spec legal_actions(session(), seat()) :: [Rules.action()]
  def legal_actions(session, seat), do: GenServer.call(session, {:legal_actions, seat})

  @doc """
  Throws the shells for `seat`: the session draws the configuration
  (fair or drought-assisted) and a cosmetic integer, applies the roll,
  and returns the resulting events (a `:throw_result` first).
  """
  @spec throw(session(), seat()) :: {:ok, [event()]} | {:error, atom()}
  def throw(session, seat), do: GenServer.call(session, {:throw, seat})

  @doc """
  Applies a non-khadu assignment action for `seat`. Khadu actions are
  refused with `{:error, :khadu_requires_confirmation}` — commit them via
  `confirm_khadu/3`.
  """
  @spec assign(session(), seat(), Rules.action()) :: {:ok, [event()]} | {:error, atom()}
  def assign(session, seat, action), do: GenServer.call(session, {:assign, seat, action})

  @doc """
  Explicitly commits a forced khadu — the destructive burn (*dana ane
  pagdu badi gaya*) is a distinct command so no client can commit one by
  accident.
  """
  @spec confirm_khadu(session(), seat(), Rules.action()) :: {:ok, [event()]} | {:error, atom()}
  def confirm_khadu(session, seat, {:khadu, _i, _ix} = action) do
    GenServer.call(session, {:confirm_khadu, seat, action})
  end

  @doc """
  Subscribes `pid` (default: the caller) to session events, delivered as
  `{:chopaat_session, session_pid, seq, event}` messages in emission
  order, `seq` strictly increasing.
  """
  @spec subscribe(session(), pid()) :: :ok
  def subscribe(session, pid \\ self()), do: GenServer.call(session, {:subscribe, pid})

  @doc "Removes `pid` (default: the caller) from the subscriber set."
  @spec unsubscribe(session(), pid()) :: :ok
  def unsubscribe(session, pid \\ self()), do: GenServer.call(session, {:unsubscribe, pid})

  @doc """
  The server-side throw draw as a pure function: shells (via the
  drought-assisted or fair probability the game facts dictate) plus the
  cosmetic integer. Public so host-side predictors (device scripts)
  can replay the session's exact RNG sequence from `export/1`.
  """
  @spec draw_throw(Game.t(), RNG.t(), (Variant.t(), float(), RNG.t() -> {[boolean()], RNG.t()})) ::
          {[boolean()], non_neg_integer(), RNG.t()}
  def draw_throw(%Game{} = game, rng, draw \\ &default_draw/3) do
    {shells, rng} = draw.(game.variant, up_probability(game), rng)
    {cosmetic, rng} = RNG.uniform(rng, @cosmetic_range)
    {shells, cosmetic, rng}
  end

  # ── server ───────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    setup = opts[:setup] || Setup.new(opts[:players] || 4, Keyword.take(opts, [:names, :variant]))
    game = opts[:game] || Game.new(setup.variant, setup.num_players)
    rng = RNG.new(opts[:rng_seed] || System.unique_integer([:positive]))

    {:ok,
     %{
       game: game,
       rng: rng,
       setup: setup,
       draw: opts[:draw] || (&default_draw/3),
       seq: 0,
       subscribers: %{}
     }}
  end

  @impl GenServer
  def handle_call(:observe, _from, state), do: {:reply, observe_map(state), state}
  def handle_call(:game, _from, state), do: {:reply, state.game, state}
  def handle_call(:setup, _from, state), do: {:reply, state.setup, state}

  def handle_call(:export, _from, state) do
    {:reply, Map.take(state, [:game, :rng, :setup, :seq]), state}
  end

  def handle_call({:legal_actions, seat}, _from, state) do
    case seat == state.game.turn do
      true -> {:reply, Game.legal_actions(state.game), state}
      false -> {:reply, [], state}
    end
  end

  def handle_call({:throw, seat}, _from, state) do
    with :ok <- seat_check(state.game, seat),
         :ok <- phase_check(state.game, :rolling) do
      {shells, cosmetic, rng} = draw_throw(state.game, state.rng, state.draw)
      {:ok, next} = Game.apply_event(state.game, {:roll, shells})

      events = [throw_result(state.game, next, shells, cosmetic) | turn_events(state.game, next)]
      commit(%{state | rng: rng}, next, events)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:assign, _seat, {:khadu, _i, _ix}}, _from, state) do
    {:reply, {:error, :khadu_requires_confirmation}, state}
  end

  def handle_call({:assign, seat, action}, _from, state) do
    act(state, seat, action)
  end

  def handle_call({:confirm_khadu, seat, action}, _from, state) do
    act(state, seat, action)
  end

  def handle_call({:new_game, opts}, _from, state) do
    setup = if opts[:reshuffle], do: Setup.reshuffle(state.setup), else: state.setup
    game = opts[:game] || Game.new(setup.variant, setup.num_players)
    rng = if seed = opts[:rng_seed], do: RNG.new(seed), else: state.rng

    event =
      {:game_started,
       %{
         variant: setup.variant.name,
         num_players: setup.num_players,
         turn: game.turn
       }}

    commit(%{state | rng: rng, setup: setup}, game, [event])
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  # ── command execution ────────────────────────────────────────────────────

  defp act(state, seat, action) do
    with :ok <- seat_check(state.game, seat),
         {:ok, next} <- Game.apply_event(state.game, action) do
      commit(
        state,
        next,
        action_events(state.game, next, action) ++ turn_events(state.game, next)
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp seat_check(%Game{turn: seat}, seat), do: :ok
  defp seat_check(%Game{}, _seat), do: {:error, :not_your_turn}

  defp phase_check(%Game{phase: phase}, phase), do: :ok
  defp phase_check(%Game{phase: :finished}, _phase), do: {:error, :game_over}
  defp phase_check(%Game{}, _phase), do: {:error, :wrong_phase}

  # Broadcast each event (seq strictly increasing) before replying, so a
  # client that both commands and subscribes sees its own events queued by
  # the time the call returns.
  defp commit(state, next, events) do
    seq = state.seq

    for {event, offset} <- Enum.with_index(events, 1),
        {pid, _ref} <- state.subscribers do
      send(pid, {:chopaat_session, self(), seq + offset, event})
    end

    {:reply, {:ok, events}, %{state | game: next, seq: seq + length(events)}}
  end

  # ── event derivation ─────────────────────────────────────────────────────

  defp throw_result(prev, next, shells, cosmetic) do
    throw = Rules.throw_score(prev.variant, shells)

    {:throw_result,
     %{
       seat: prev.turn,
       shells: shells,
       up_count: throw.up_count,
       score: throw.score,
       special: throw.special,
       entry: throw.entry,
       cosmetic: cosmetic,
       phase: next.phase,
       rolls: next.turn_rolls,
       pending: next.pending,
       bonus_steps: next.bonus_steps
     }}
  end

  defp action_events(prev, _next, {:waste, i}) do
    [{:wasted, %{seat: prev.turn, roll: Enum.at(prev.pending, i)}}]
  end

  defp action_events(prev, _next, :waste_bonus) do
    [{:wasted, %{seat: prev.turn, roll: :bonus}}]
  end

  defp action_events(prev, next, action) do
    {ix, roll} = mover(prev, action)
    seat = prev.turn

    moved =
      {:moved,
       %{
         seat: seat,
         pawn: ix,
         action: action,
         roll: roll,
         from: position_data(prev, seat, pawn_pos(prev, seat, ix)),
         to: position_data(next, seat, pawn_pos(next, seat, ix)),
         path: Enum.map(Rules.action_path(prev, action), &position_data(prev, seat, &1))
       }}

    [moved | khadu_event(prev, action)] ++ capture_events(prev, next)
  end

  defp mover(prev, {:assign, i, ix}), do: {ix, Enum.at(prev.pending, i)}
  defp mover(prev, {:khadu, i, ix}), do: {ix, Enum.at(prev.pending, i)}
  defp mover(_prev, {:bonus_step, ix}), do: {ix, :bonus}

  defp pawn_pos(game, seat, ix), do: Enum.at(Map.fetch!(game.pawns, seat), ix).pos

  defp khadu_event(_prev, {:assign, _i, _ix}), do: []
  defp khadu_event(_prev, {:bonus_step, _ix}), do: []

  # The burn (dana ane pagdu badi gaya): every other pending non-special
  # roll and every bonus step dies with the commit.
  defp khadu_event(prev, {:khadu, i, ix}) do
    dana =
      prev.pending
      |> List.delete_at(i)
      |> Enum.reject(&Variant.special?(prev.variant, &1))

    [
      {:khadu,
       %{
         seat: prev.turn,
         pawn: ix,
         roll: Enum.at(prev.pending, i),
         burned: %{dana: dana, pagdu: prev.bonus_steps}
       }}
    ]
  end

  # Victims: opponent pawns that were on track before and in base after.
  defp capture_events(prev, next) do
    seat = prev.turn

    for victim <- 0..(prev.num_players - 1),
        victim != seat,
        {before_pawn, ix} <- Enum.with_index(Map.fetch!(prev.pawns, victim)),
        match?({:track, _}, before_pawn.pos),
        Enum.at(Map.fetch!(next.pawns, victim), ix).pos == :base do
      {:track, x} = before_pawn.pos

      {:captured,
       %{
         seat: seat,
         victim_seat: victim,
         victim_pawn: ix,
         cell: Board.cell_name(Board.cell(prev.board, victim, x)),
         tod_earned: Map.fetch!(next.tod, seat) and not Map.fetch!(prev.tod, seat),
         victim_tod_lost: Map.fetch!(prev.tod, victim) and not Map.fetch!(next.tod, victim)
       }}
    end
  end

  defp turn_events(prev, next) do
    placements =
      for {seat, rank} <- Enum.with_index(next.placements, 1),
          rank > length(prev.placements) do
        {:placement, %{seat: seat, rank: rank}}
      end

    placements ++ transition_events(prev, next)
  end

  defp transition_events(_prev, %Game{phase: :finished} = next) do
    [{:game_over, %{placements: next.placements, loser: List.last(next.placements)}}]
  end

  defp transition_events(%Game{phase: :assigning} = prev, %Game{phase: :rolling} = next) do
    [
      {:turn_passed, %{seat: prev.turn, next_seat: next.turn, extra_turn: next.turn == prev.turn}}
    ]
  end

  defp transition_events(_prev, _next), do: []

  # ── observe ──────────────────────────────────────────────────────────────

  defp observe_map(%{game: game, setup: setup, seq: seq}) do
    %{
      seq: seq,
      variant: game.variant.name,
      num_players: game.num_players,
      turn: game.turn,
      phase: game.phase,
      rolls: game.turn_rolls,
      pending: game.pending,
      bonus_steps: game.bonus_steps,
      captured_this_turn: game.captured_this_turn,
      placements: game.placements,
      board: board_data(game.board),
      seats: Enum.map(0..(game.num_players - 1), &seat_data(game, setup, &1)),
      occupancy: occupancy_data(game)
    }
  end

  defp board_data(%Board{} = board) do
    Map.take(board, [:arms, :home, :connector, :gate, :marker, :khadu_skip])
  end

  defp seat_data(game, setup, seat) do
    entry = Setup.player(setup, seat)
    tod = Map.fetch!(game.tod, seat)

    %{
      seat: seat,
      name: entry.name,
      color: entry.color,
      tod: tod,
      gate: if(tod, do: :open, else: :active),
      assisted: Game.assisted?(game, seat),
      drought: Map.fetch!(game.droughts, seat),
      pawns:
        game.pawns
        |> Map.fetch!(seat)
        |> Enum.with_index()
        |> Enum.map(fn {pawn, ix} -> pawn_data(game, seat, ix, pawn) end)
    }
  end

  defp pawn_data(game, seat, ix, %Pawn{} = pawn) do
    game
    |> position_data(seat, pawn.pos)
    |> Map.merge(%{
      pawn: ix,
      bypass: pawn.bypass,
      tipped: tipped?(game, pawn),
      jammed: jammed?(game, seat, pawn)
    })
  end

  # Positions as plain data: the lap coordinate for logic, the cell-name
  # string for renderers (the 2D board draws straight from it).
  defp position_data(_game, _seat, :base), do: %{state: :base, track: nil, cell: nil}

  defp position_data(_game, _seat, :home), do: %{state: :home, track: nil, cell: "center_home"}

  defp position_data(game, seat, {:track, x}) do
    %{state: :track, track: x, cell: Board.cell_name(Board.cell(game.board, seat, x))}
  end

  # RULESET.md finishing visual: tipped inside the private final stretch.
  defp tipped?(game, %Pawn{pos: {:track, x}}), do: x > game.board.connector
  defp tipped?(_game, _pawn), do: false

  # Jammed hard at the gate: the gate is active and even the smallest
  # score in the throw table would cross it — the pawn cannot move at all
  # until a tod is earned.
  defp jammed?(game, seat, %Pawn{pos: {:track, x}}) do
    min_score = game.variant.throw_table |> Map.values() |> Enum.min()
    not Map.fetch!(game.tod, seat) and x <= game.board.gate and x + min_score > game.board.gate
  end

  defp jammed?(_game, _seat, _pawn), do: false

  defp occupancy_data(game) do
    for {seat, pawns} <- game.pawns,
        {%Pawn{pos: {:track, x}}, ix} <- Enum.with_index(pawns),
        reduce: %{} do
      acc ->
        cell = Board.cell_name(Board.cell(game.board, seat, x))
        Map.update(acc, cell, [%{seat: seat, pawn: ix}], &(&1 ++ [%{seat: seat, pawn: ix}]))
    end
  end

  # ── randomness ───────────────────────────────────────────────────────────

  defp default_draw(variant, up_probability, rng) do
    RNG.draw(rng, variant.shell_count, up_probability)
  end

  defp up_probability(game) do
    case Game.assisted?(game, game.turn) do
      true -> game.variant.assist_up_probability
      false -> game.variant.fair_up_probability
    end
  end
end
