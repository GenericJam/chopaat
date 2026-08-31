defmodule Chopaat.BotRunnerTest do
  @moduledoc false

  # The bot runner as a session client: plays its seat to placements,
  # chains extra rolls and extra turns, commits khadus through the
  # explicit confirm command, and survives crashes without wedging the
  # game (supervised restart; raising bots degrade to legal-random).

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Chopaat.Bot
  alias Chopaat.Session
  alias Chopaat.Support.Craft
  alias Chopaat.Support.Fixtures

  defmodule CrashBot do
    @moduledoc false
    @behaviour Chopaat.Bot

    @impl Chopaat.Bot
    def choose(_obs, _legal, _rng), do: raise("deliberately broken bot")
  end

  # A scripted session draw local to one test: up-counts pop from an
  # agent (the draw runs in the session process, so test state can't be
  # process-local).
  defp scripted_draw(up_counts) do
    {:ok, agent} = Agent.start_link(fn -> up_counts end)

    fn variant, _up_probability, rng ->
      up = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      {Craft.shells(up, variant.shell_count), rng}
    end
  end

  defp await(session, matcher, timeout \\ 30_000) do
    receive do
      {:chopaat_session, ^session, _seq, event} ->
        case matcher.(event) do
          true -> event
          false -> await(session, matcher, timeout)
        end
    after
      timeout -> flunk("expected session event did not arrive within #{timeout}ms")
    end
  end

  test "a full-auto table of runners plays a seeded game to placements" do
    {:ok, session} = Session.start_link(players: 4, rng_seed: 99)
    :ok = Session.subscribe(session)

    {:ok, _sup} =
      Bot.Supervisor.start_link(
        session: session,
        seats: Enum.map(0..3, &{&1, Bot.Heuristic}),
        delay_ms: 0,
        rng_seed: 5
      )

    {:game_over, over} = await(session, &match?({:game_over, _}, &1))

    assert Enum.sort(over.placements) == [0, 1, 2, 3]
    assert over.loser == List.last(over.placements)
  end

  test "the runner chains extra rolls and disposes the surviving rolls" do
    # Score 7 (special) then 2: two throws in one turn; neither is an
    # entry score with all pawns in base, so both surviving rolls waste
    # and the turn passes.
    {:ok, session} = Session.start_link(players: 4, draw: scripted_draw([0, 2]))
    :ok = Session.subscribe(session)

    {:ok, _runner} = Bot.Runner.start_link(session: session, seat: 0, delay_ms: 0, rng_seed: 1)

    assert {:throw_result, %{seat: 0, score: 7, special: true}} =
             await(session, &match?({:throw_result, _}, &1))

    assert {:throw_result, %{seat: 0, score: 2, special: false}} =
             await(session, &match?({:throw_result, _}, &1))

    assert {:turn_passed, %{seat: 0, next_seat: 1, extra_turn: false}} =
             await(session, &match?({:turn_passed, _}, &1))
  end

  test "the runner commits a forced khadu via the explicit confirm command" do
    {:ok, session} = Session.start_link(game: Fixtures.gate_jam([7]))
    :ok = Session.subscribe(session)

    {:ok, _runner} = Bot.Runner.start_link(session: session, seat: 0, delay_ms: 0, rng_seed: 1)

    # The heuristic picks the least-bad pawn (54 keeps the most progress).
    assert {:khadu, %{seat: 0, pawn: 0, roll: 7}} = await(session, &match?({:khadu, _}, &1))
  end

  test "a capture's extra turn is played by the same runner" do
    {:ok, session} =
      Session.start_link(game: Fixtures.capture_ready(), draw: scripted_draw([3]))

    :ok = Session.subscribe(session)

    {:ok, _runner} = Bot.Runner.start_link(session: session, seat: 0, delay_ms: 0, rng_seed: 1)

    assert {:captured, %{seat: 0, victim_seat: 1}} = await(session, &match?({:captured, _}, &1))

    assert {:turn_passed, %{seat: 0, next_seat: 0, extra_turn: true}} =
             await(session, &match?({:turn_passed, _}, &1))

    # The same runner rolls its extra turn (the scripted 3) and moves.
    assert {:throw_result, %{seat: 0, score: 3}} =
             await(session, &match?({:throw_result, _}, &1))

    assert {:moved, %{seat: 0}} = await(session, &match?({:moved, _}, &1))
  end

  test "a raising bot degrades to legal-random — the seat keeps playing" do
    {:ok, session} = Session.start_link(game: Fixtures.simple_move([4]))
    :ok = Session.subscribe(session)

    log =
      capture_log(fn ->
        {:ok, _runner} =
          Bot.Runner.start_link(session: session, seat: 0, bot: CrashBot, delay_ms: 0)

        assert {:moved, %{seat: 0, pawn: 0}} = await(session, &match?({:moved, _}, &1))
      end)

    assert log =~ "crashed choosing"
    assert log =~ "falling back to legal-random"
  end

  test "a killed runner is restarted by the supervisor and the game still finishes" do
    {:ok, session} = Session.start_link(players: 4, rng_seed: 424_242)
    :ok = Session.subscribe(session)

    {:ok, sup} =
      Bot.Supervisor.start_link(
        session: session,
        seats: Enum.map(0..3, &{&1, Bot.Random}),
        delay_ms: 0,
        rng_seed: 6
      )

    # Let the game get going, then murder a runner mid-flight.
    await(session, &match?({:turn_passed, _}, &1))
    runner = Bot.Supervisor.runner(sup, 0)
    assert is_pid(runner)
    Process.exit(runner, :kill)

    {:game_over, over} = await(session, &match?({:game_over, _}, &1))
    assert Enum.sort(over.placements) == [0, 1, 2, 3]

    restarted = Bot.Supervisor.runner(sup, 0)
    assert is_pid(restarted)
    refute restarted == runner
  end

  test "runners stop normally when their session goes down" do
    {:ok, session} = Session.start_link(players: 4)
    {:ok, runner} = Bot.Runner.start_link(session: session, seat: 1, delay_ms: 60_000)

    ref = Process.monitor(runner)
    :ok = GenServer.stop(session)

    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 1_000
  end

  test "runners never act off-turn or off-phase" do
    # Seat 2's runner with seat 0 to play: it must observe and do nothing.
    {:ok, session} = Session.start_link(game: Fixtures.simple_move([4]))
    :ok = Session.subscribe(session)

    {:ok, _runner} = Bot.Runner.start_link(session: session, seat: 2, delay_ms: 0)

    # Give it ample time to (wrongly) command; the observation must not
    # move — seq stays where the fixture left it.
    Process.sleep(100)
    assert Session.observe(session).seq == 0
    assert Session.observe(session).turn == 0
  end
end
