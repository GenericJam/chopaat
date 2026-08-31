defmodule Chopaat.SimulationTest do
  @moduledoc false

  # Mass simulated playthroughs — the termination and liveness gate.

  use ExUnit.Case, async: true

  alias Chopaat.Support.Simulator

  @moduletag timeout: 600_000

  @games_4p 1_500
  @games_6p 300

  setup_all do
    four = run_corpus(4, @games_4p)
    six = run_corpus(6, @games_6p)

    IO.puts("\n[simulation] 4p: #{summary(four)}\n[simulation] 6p: #{summary(six)}")

    %{four: four, six: six}
  end

  defp run_corpus(players, games) do
    1..games
    |> Task.async_stream(&Simulator.run(&1, players: players),
      timeout: 300_000,
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.map(fn {:ok, stats} -> stats end)
  end

  defp summary(corpus) do
    games = length(corpus)
    mean_events = div(Enum.sum(Enum.map(corpus, & &1.events)), games)
    mean_turns = div(Enum.sum(Enum.map(corpus, & &1.turns)), games)
    mean_rolls = div(Enum.sum(Enum.map(corpus, & &1.rolls)), games)
    max_events = Enum.max(Enum.map(corpus, & &1.events))
    captures = Enum.sum(Enum.map(corpus, & &1.captures))
    khadus = Enum.sum(Enum.map(corpus, & &1.khadus))
    assisted = Enum.sum(Enum.map(corpus, & &1.assisted_rolls))

    "games=#{games} mean_events=#{mean_events} mean_turns=#{mean_turns} " <>
      "mean_rolls=#{mean_rolls} max_events=#{max_events} captures=#{captures} " <>
      "khadus=#{khadus} assisted_rolls=#{assisted}"
  end

  test "every 4-player game terminates with a complete placement order", %{four: corpus} do
    assert length(corpus) == @games_4p
    assert Enum.all?(corpus, &(Enum.sort(&1.placements) == [0, 1, 2, 3]))
  end

  test "every 6-player game terminates with a complete placement order", %{six: corpus} do
    assert length(corpus) == @games_6p
    assert Enum.all?(corpus, &(Enum.sort(&1.placements) == [0, 1, 2, 3, 4, 5]))
  end

  test "every finisher earned a tod: at least players-1 captures per game", %{
    four: four,
    six: six
  } do
    assert Enum.all?(four, &(&1.captures >= 3))
    assert Enum.all?(six, &(&1.captures >= 5))
  end

  test "captured pawns re-enter: entries exceed the finishers' initial four each", %{
    four: four
  } do
    assert Enum.all?(four, &(&1.entries >= 4 * 3))
    assert Enum.any?(four, &(&1.entries > 4 * 4))
  end

  test "extra-roll chains terminate quickly in practice", %{four: four, six: six} do
    assert Enum.all?(four ++ six, &(&1.max_rolls_per_turn < 60))
  end

  test "no seat is systematically shut out of winning", %{four: four} do
    wins = four |> Enum.map(& &1.winner) |> Enum.frequencies()

    assert Map.keys(wins) |> Enum.sort() == [0, 1, 2, 3]
  end

  test "the drought-assistance path is exercised", %{four: four} do
    assert Enum.sum(Enum.map(four, & &1.assisted_rolls)) > 0
  end
end
