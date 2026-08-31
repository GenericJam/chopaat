defmodule Chopaat.Support.BotMatch do
  @moduledoc """
  Headless bot-vs-bot games through a REAL `Chopaat.Session` process —
  the mass-simulation posture of `Chopaat.Support.Simulator` lifted onto
  the session client API (bead chopaat-27z): every decision consumes
  exactly `Session.observe/1` + `Session.legal_actions/2`, and every
  chosen action is asserted to be a member of the legal list at decision
  time (the bot-legality property) before it is committed via
  `assign/3` / `confirm_khadu/3`.

  `run/2` plays one seeded game to completion synchronously (no runner
  processes, no pacing — the runner has its own tests) and returns
  stats: `%{placements, winner, commands}`.
  """

  import ExUnit.Assertions

  alias Chopaat.RNG
  alias Chopaat.Session

  @doc """
  One full game. Options:

    * `:bots` (required) — one `Chopaat.Bot` module per seat.
    * `:max_commands` — stall bound (default 100_000).
  """
  def run(seed, opts) do
    bots = Keyword.fetch!(opts, :bots)

    {:ok, session} =
      Session.start_link(players: length(bots), rng_seed: seed, names: names(bots))

    stats =
      loop(
        session,
        List.to_tuple(bots),
        RNG.new(seed + 1_000_003),
        Keyword.get(opts, :max_commands, 100_000),
        %{commands: 0}
      )

    :ok = GenServer.stop(session)
    stats
  end

  defp names(bots), do: Enum.with_index(bots, fn bot, ix -> "#{inspect(bot)} #{ix}" end)

  defp loop(session, bots, rng, max, stats) do
    obs = Session.observe(session)

    assert stats.commands < max,
           "bot game did not terminate within #{max} commands (seq #{obs.seq})"

    case obs.phase do
      :finished ->
        Map.merge(stats, %{placements: obs.placements, winner: hd(obs.placements)})

      :rolling ->
        {:ok, _events} = Session.throw(session, obs.turn)
        loop(session, bots, rng, max, bump(stats))

      :assigning ->
        legal = Session.legal_actions(session, obs.turn)
        assert legal != [], "assigning phase with no legal actions (seq #{obs.seq})"

        {action, rng} = elem(bots, obs.turn).choose(obs, legal, rng)

        # The bot-legality property: every bot action is a member of
        # legal_actions/2 at decision time. No exceptions, ever.
        assert action in legal,
               "#{inspect(elem(bots, obs.turn))} chose #{inspect(action)} ∉ #{inspect(legal)}"

        {:ok, _events} = dispatch(session, obs.turn, action)
        loop(session, bots, rng, max, bump(stats))
    end
  end

  defp dispatch(session, seat, {:khadu, _i, _ix} = action) do
    Session.confirm_khadu(session, seat, action)
  end

  defp dispatch(session, seat, action), do: Session.assign(session, seat, action)

  defp bump(stats), do: %{stats | commands: stats.commands + 1}
end
