defmodule Chopaat.Support.MachineBot do
  @moduledoc """
  Acceptance A for bead chopaat-85o: `Chopaat.Bot.Random` reimplemented
  as a client of the PUBLIC machine protocol only. Every value that
  crosses the boundary — observation, legal list, chosen action, events,
  errors — passes through a strict JSON encode/decode round trip
  (`:json`), so the bot plays entirely off post-JSON-decode string-keyed
  data and anything non-serializable that leaked would raise here.

  `run/2` plays one seeded headless game mixing machine seats (this
  module, over `Chopaat.MachinePlay`) with internal-bot seats (a
  `Chopaat.Bot` module, over `Chopaat.Session` — the chopaat-27z path),
  asserting the SAME legality properties on both planes at every
  decision, plus the plane-agreement property: the wire legal list is
  exactly the session legal list encoded. Bots and external agents share
  one interface, proven per decision.
  """

  import ExUnit.Assertions

  alias Chopaat.MachinePlay
  alias Chopaat.RNG
  alias Chopaat.Session

  @doc """
  The JSON boundary: encode to a binary, decode back (the stdlib `JSON`
  module, whose encoder maps `nil` to JSON null). Raises on anything not
  JSON-representable — the "nothing leaks" proof, applied to every call
  in both directions.
  """
  def roundtrip(data), do: data |> JSON.encode!() |> JSON.decode!()

  @doc "The observation as an external client would hold it (post-decode)."
  def observe(session), do: roundtrip(MachinePlay.observe(session))

  @doc "The wire legal list as an external client would hold it."
  def legal_actions(session, seat), do: roundtrip(MachinePlay.legal_actions(session, seat))

  @doc "Submits a wire action; the events return through the same boundary."
  def act(session, seat, wire_action) do
    case MachinePlay.act(session, seat, roundtrip(wire_action)) do
      {:ok, events} -> {:ok, roundtrip(events)}
      {:error, reason} -> {:error, roundtrip(reason)}
    end
  end

  @doc "The Bot.Random policy over the wire: uniform over the legal list."
  def choose(_obs, [_head | _rest] = legal, rng), do: RNG.pick(rng, legal)

  @doc """
  One full seeded headless game. Options:

    * `:seats` (required) — one driver per seat: `:machine` (this module
      over MachinePlay) or a `Chopaat.Bot` module (over Session).
    * `:max_commands` — stall bound (default 100_000).

  Returns `%{placements, winner, commands, machine_decisions}`.
  """
  def run(seed, opts) do
    seats = Keyword.fetch!(opts, :seats)

    {:ok, session} =
      Session.start_link(players: length(seats), rng_seed: seed, names: names(seats))

    stats =
      loop(
        session,
        List.to_tuple(seats),
        RNG.new(seed + 1_000_003),
        Keyword.get(opts, :max_commands, 100_000),
        %{commands: 0, machine_decisions: 0}
      )

    :ok = GenServer.stop(session)
    stats
  end

  defp names(seats), do: Enum.with_index(seats, fn seat, ix -> "#{inspect(seat)} #{ix}" end)

  # The harness routes on the session's snapshot; a machine seat's own
  # inputs come exclusively through the wire helpers above.
  defp loop(session, seats, rng, max, stats) do
    obs = Session.observe(session)

    assert stats.commands < max,
           "mixed game did not terminate within #{max} commands (seq #{obs.seq})"

    case obs.phase do
      :finished ->
        Map.merge(stats, %{placements: obs.placements, winner: hd(obs.placements)})

      _playing ->
        rng =
          case elem(seats, obs.turn) do
            :machine -> machine_turn(session, obs.turn, rng)
            bot -> internal_turn(session, obs, bot, rng)
          end

        loop(session, seats, rng, max, bump(stats, elem(seats, obs.turn)))
    end
  end

  # A machine seat: wire observation, wire legal list, wire action —
  # MachinePlay only, JSON round trip on every call.
  defp machine_turn(session, seat, rng) do
    wire_obs = observe(session)
    assert wire_obs["turn"] == seat

    legal = legal_actions(session, seat)
    assert legal != [], "machine seat #{seat} has no legal wire actions"
    assert_plane_agreement(session, seat, wire_obs["phase"], legal)

    {action, rng} = choose(wire_obs, legal, rng)

    # The bot-legality property, on the wire plane.
    assert action in legal, "machine chose #{inspect(action)} ∉ #{inspect(legal)}"

    {:ok, events} = act(session, seat, action)
    assert is_list(events) and Enum.all?(events, &is_map_key(&1, "event"))
    rng
  end

  # Plane agreement: the wire legal list is exactly the session legal
  # list encoded (and the rolling phase offers exactly the throw).
  defp assert_plane_agreement(_session, _seat, "rolling", legal) do
    assert legal == [%{"type" => "throw"}]
  end

  defp assert_plane_agreement(session, seat, "assigning", legal) do
    encoded =
      session
      |> Session.legal_actions(seat)
      |> Enum.map(&(&1 |> MachinePlay.encode_action() |> roundtrip()))

    assert legal == encoded
  end

  # An internal-bot seat: the chopaat-27z path, verbatim from BotMatch —
  # the same legality property asserted on the session plane.
  defp internal_turn(session, %{phase: :rolling} = obs, _bot, rng) do
    {:ok, _events} = Session.throw(session, obs.turn)
    rng
  end

  defp internal_turn(session, %{phase: :assigning} = obs, bot, rng) do
    legal = Session.legal_actions(session, obs.turn)
    assert legal != [], "internal seat #{obs.turn} has no legal actions"

    {action, rng} = bot.choose(obs, legal, rng)
    assert action in legal, "#{inspect(bot)} chose #{inspect(action)} ∉ #{inspect(legal)}"

    {:ok, _events} = dispatch(session, obs.turn, action)
    rng
  end

  defp dispatch(session, seat, {:khadu, _i, _ix} = action) do
    Session.confirm_khadu(session, seat, action)
  end

  defp dispatch(session, seat, action), do: Session.assign(session, seat, action)

  defp bump(stats, :machine) do
    %{stats | commands: stats.commands + 1, machine_decisions: stats.machine_decisions + 1}
  end

  defp bump(stats, _bot), do: %{stats | commands: stats.commands + 1}
end
