defmodule Chopaat.Bot.Supervisor do
  @moduledoc """
  Supervises the `Chopaat.Bot.Runner` per bot seat of one session
  (one_for_one, `:transient` children): a crashed runner is restarted,
  re-subscribes, re-observes and resumes — a bot crash never wedges the
  game (policy recorded on bead chopaat-27z). Restart intensity is kept
  generous because a healthy runner already degrades raising bot
  decisions to legal-random internally; blowing through the intensity
  means a real runner bug, which should crash loudly (taking the linked
  client down) rather than stall silently.

  Started by whoever hosts the bot seats (the game screen for local
  play, a headless harness for soak runs) and linked to it, so bots die
  with their game.
  """

  use Supervisor

  alias Chopaat.Bot.Runner

  @doc """
  Options: `:session` (required), `:seats` (required — a list of
  `{seat, bot_module}`), `:delay_ms` (pacing for every runner, default
  0), `:rng_seed` (base seed; each seat derives its own).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl Supervisor
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    delay = Keyword.get(opts, :delay_ms, 0)
    base_seed = Keyword.get_lazy(opts, :rng_seed, fn -> System.unique_integer([:positive]) end)

    children =
      for {seat, bot} <- Keyword.fetch!(opts, :seats) do
        Supervisor.child_spec(
          {Runner,
           session: session, seat: seat, bot: bot, delay_ms: delay, rng_seed: base_seed + seat},
          id: {:bot_runner, seat}
        )
      end

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 10)
  end

  @doc "The live runner pid for a seat (crash-drill and test plumbing)."
  @spec runner(Supervisor.supervisor(), non_neg_integer()) :: pid() | nil
  def runner(supervisor, seat) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{:bot_runner, ^seat}, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end
end
