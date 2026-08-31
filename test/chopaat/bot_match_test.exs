defmodule Chopaat.BotMatchTest do
  @moduledoc false

  # Mass bot-vs-bot games through the session client API (bead
  # chopaat-27z): the termination gate for bot play, the bot-legality
  # property (asserted inside Chopaat.Support.BotMatch on every single
  # decision), and the strength check — the heuristic must beat
  # legal-random by a clear margin over a statistically meaningful
  # sample.

  use ExUnit.Case, async: true

  alias Chopaat.Bot.Heuristic
  alias Chopaat.Bot.Random
  alias Chopaat.Support.BotMatch

  @moduletag timeout: 600_000

  # 1_000 headless auto games in total, every one asserted to terminate
  # and every bot action asserted legal at decision time.
  @mixed_4p 500
  @heuristic_4p 200
  @random_4p 200
  @mixed_6p 100

  # 2 heuristic + 2 random per mixed 4p game, seat pattern rotating so
  # every seat hosts each bot equally often (seat-order bias cancels).
  @mixed_seats [
    [Heuristic, Heuristic, Random, Random],
    [Random, Heuristic, Heuristic, Random],
    [Random, Random, Heuristic, Heuristic],
    [Heuristic, Random, Random, Heuristic]
  ]

  setup_all do
    mixed =
      run_corpus(@mixed_4p, fn i -> Enum.at(@mixed_seats, rem(i, 4)) end)

    heuristic = run_corpus(@heuristic_4p, fn _i -> List.duplicate(Heuristic, 4) end)
    random = run_corpus(@random_4p, fn _i -> List.duplicate(Random, 4) end)

    mixed_6p =
      run_corpus(@mixed_6p, fn i ->
        Enum.map(0..5, fn seat ->
          if rem(seat + i, 2) == 0, do: Heuristic, else: Random
        end)
      end)

    IO.puts(
      "\n[bot-match] heuristic-vs-random 4p (2v2, #{@mixed_4p} games): " <>
        "heuristic wins #{win_share(mixed)} (parity would be 0.50)\n" <>
        "[bot-match] heuristic-vs-random 6p (3v3, #{@mixed_6p} games): " <>
        "heuristic wins #{win_share(mixed_6p)}"
    )

    %{mixed: mixed, heuristic: heuristic, random: random, mixed_6p: mixed_6p}
  end

  defp run_corpus(games, seats_for) do
    1..games
    |> Task.async_stream(
      fn i -> {seats_for.(i), BotMatch.run(1_000 + i, bots: seats_for.(i))} end,
      timeout: 300_000,
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.map(fn {:ok, game} -> game end)
  end

  defp heuristic_wins(corpus) do
    Enum.count(corpus, fn {seats, stats} -> Enum.at(seats, stats.winner) == Heuristic end)
  end

  defp win_share(corpus) do
    Float.round(heuristic_wins(corpus) / length(corpus), 3)
  end

  test "all 1000 headless auto games terminate with complete placements", ctx do
    for {corpus, players} <- [
          {ctx.mixed, 4},
          {ctx.heuristic, 4},
          {ctx.random, 4},
          {ctx.mixed_6p, 6}
        ] do
      assert Enum.all?(corpus, fn {_seats, stats} ->
               Enum.sort(stats.placements) == Enum.to_list(0..(players - 1))
             end)
    end

    assert Enum.sum(
             Enum.map(
               [ctx.mixed, ctx.heuristic, ctx.random, ctx.mixed_6p],
               &length/1
             )
           ) == 1_000
  end

  test "the heuristic beats legal-random with a clear margin (4p, 2v2)", %{mixed: mixed} do
    share = heuristic_wins(mixed) / length(mixed)

    # Parity is 0.50; observed ~0.87 over 500 games (binomial sd ~1.5%
    # at that rate). 0.75 is far above parity yet leaves wide headroom
    # for seed-to-seed wobble — a genuine heuristic regression, not
    # noise, is what trips this.
    assert share > 0.75,
           "heuristic won only #{Float.round(share * 100, 1)}% of mixed-seat games"
  end

  test "the heuristic edge holds on the 6-player board (3v3)", %{mixed_6p: mixed_6p} do
    share = heuristic_wins(mixed_6p) / length(mixed_6p)

    # Observed ~0.97 over 100 games; 0.70 tolerates the small sample.
    assert share > 0.70,
           "heuristic won only #{Float.round(share * 100, 1)}% of 6p mixed-seat games"
  end

  test "no seat is systematically shut out in all-heuristic play", %{heuristic: corpus} do
    winners = corpus |> Enum.map(fn {_seats, stats} -> stats.winner end) |> Enum.frequencies()

    assert winners |> Map.keys() |> Enum.sort() == [0, 1, 2, 3]
  end
end
