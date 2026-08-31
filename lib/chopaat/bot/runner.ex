defmodule Chopaat.Bot.Runner do
  @moduledoc """
  Plays one bot seat as an ordinary session client: subscribes to the
  session, and whenever the public state says it's this seat's turn it
  issues exactly one command — `throw/2` while rolling (extra rolls and
  extra turns fall out naturally: each result event triggers the next
  look), `assign/3` for ordinary actions, `confirm_khadu/3` for the
  explicit destructive commit. Everything it knows comes from
  `Chopaat.Session.observe/1` + `legal_actions/2` — the same public
  surface any remote client gets.

  Pacing is client-local (the session never waits): every session event
  (re)schedules a single debounced `{:act, token}` after `:delay_ms`, so
  a watchable cadence is one command per delay tick and tests run at
  `delay_ms: 0`. Acting is idempotent — the runner re-observes before
  every command and does nothing off-turn, off-phase, or after
  `:finished` — which is also what makes crash recovery trivial: a
  restarted runner just looks at the board and continues.

  Crash policy (bead chopaat-27z, recorded in the bead notes): a bot
  never wedges or forfeits the game.

    * A raising `choose/3` is rescued and degraded to a legal-random
      pick for that decision (logged loudly) — the seat keeps playing.
    * A crashed runner process is restarted by `Chopaat.Bot.Supervisor`
      (`:transient`), re-subscribes, re-observes, and resumes mid-turn.
    * The session going down stops the runner normally (no restart churn
      against a dead host).
  """

  use GenServer, restart: :transient

  require Logger

  alias Chopaat.RNG
  alias Chopaat.Session

  @doc """
  Options: `:session` (required), `:seat` (required), `:bot` (a
  `Chopaat.Bot` module, default `Chopaat.Bot.Heuristic`), `:delay_ms`
  (pacing between commands, default 0), `:rng_seed` (bot-choice
  randomness, default unique — distinct from the session's game RNG).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    :ok = Session.subscribe(session)

    session_pid = GenServer.whereis(session)
    if is_pid(session_pid), do: Process.monitor(session_pid)

    state = %{
      session: session,
      seat: Keyword.fetch!(opts, :seat),
      bot: Keyword.get(opts, :bot, Chopaat.Bot.Heuristic),
      delay: Keyword.get(opts, :delay_ms, 0),
      rng:
        RNG.new(Keyword.get_lazy(opts, :rng_seed, fn -> System.unique_integer([:positive]) end)),
      token: nil
    }

    # Look immediately (well, one delay tick) — covers joining or being
    # restarted while it is already this seat's turn.
    {:ok, schedule(state)}
  end

  @impl GenServer
  def handle_info({:chopaat_session, _session, _seq, _event}, state) do
    {:noreply, schedule(state)}
  end

  def handle_info({:act, token}, %{token: token} = state), do: {:noreply, act(state)}
  def handle_info({:act, _stale_token}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  # One debounced act per event burst: a command's whole event batch
  # collapses into a single look `delay` ms after its last event.
  defp schedule(state) do
    token = make_ref()
    Process.send_after(self(), {:act, token}, state.delay)
    %{state | token: token}
  end

  defp act(%{session: session, seat: seat} = state) do
    obs = Session.observe(session)

    cond do
      obs.turn != seat or obs.phase == :finished ->
        state

      obs.phase == :rolling ->
        command(state, fn -> Session.throw(session, seat) end)

      obs.phase == :assigning ->
        assign(state, obs, Session.legal_actions(session, seat))
    end
  end

  defp assign(state, _obs, []), do: state

  defp assign(%{session: session, seat: seat} = state, obs, legal) do
    {action, rng} = decide(state, obs, legal)

    dispatch = fn ->
      case action do
        {:khadu, _i, _ix} -> Session.confirm_khadu(session, seat, action)
        _ordinary -> Session.assign(session, seat, action)
      end
    end

    command(%{state | rng: rng}, dispatch)
  end

  # The bot decision, guarded twice: a raising bot and an off-list pick
  # both degrade to legal-random for this decision (the graceful-forfeit
  # ruling: forfeit the intelligence, never the seat).
  defp decide(%{bot: bot, rng: rng, seat: seat}, obs, legal) do
    {action, next_rng} = bot.choose(obs, legal, rng)

    case action in legal do
      true ->
        {action, next_rng}

      false ->
        Logger.error(
          "[chopaat.bot] #{inspect(bot)} (seat #{seat}) chose off-list " <>
            "#{inspect(action)} — falling back to legal-random"
        )

        RNG.pick(next_rng, legal)
    end
  rescue
    error ->
      Logger.error(
        "[chopaat.bot] #{inspect(bot)} (seat #{seat}) crashed choosing: " <>
          "#{Exception.format(:error, error, __STACKTRACE__)} — falling back to legal-random"
      )

      RNG.pick(rng, legal)
  end

  defp command(state, dispatch) do
    case dispatch.() do
      {:ok, _events} ->
        # The events are already in our mailbox (broadcast-before-reply);
        # they reschedule the next act.
        state

      {:error, reason} ->
        # A race (another seat's command landed between observe and here)
        # or a stale look — log at debug and look again after a delay so
        # an all-bot game can never stall on a swallowed error.
        Logger.debug("[chopaat.bot] seat #{state.seat} command rejected: #{inspect(reason)}")
        schedule(state)
    end
  end
end
