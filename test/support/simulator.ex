defmodule Chopaat.Support.Simulator do
  @moduledoc false

  import ExUnit.Assertions

  alias Chopaat.Game
  alias Chopaat.RNG
  alias Chopaat.Variant

  @doc """
  Runs one full seeded random game to completion and returns stats. The
  driver draws shells through `Chopaat.RNG` (fair or drought-assisted, as
  the rules facts dictate) and picks uniformly among legal actions. An
  optional `:check` callback runs after every event.
  """
  def run(seed, opts \\ []) do
    variant = Keyword.get(opts, :variant, Variant.gujarat())
    players = Keyword.get(opts, :players, 4)
    max_events = Keyword.get(opts, :max_events, 400_000)
    check = Keyword.get(opts, :check, fn _game -> :ok end)

    stats = %{
      events: 0,
      rolls: 0,
      turns: 0,
      captures: 0,
      khadus: 0,
      entries: 0,
      assisted_rolls: 0,
      rolls_this_turn: 0,
      max_rolls_per_turn: 0
    }

    loop(Game.new(variant, players), RNG.new(seed), check, max_events, stats)
  end

  defp loop(%Game{phase: :finished} = game, _rng, _check, _max, stats) do
    stats
    |> Map.put(:placements, game.placements)
    |> Map.put(:winner, hd(game.placements))
    |> Map.put(:game, game)
  end

  defp loop(game, rng, check, max, stats) do
    assert stats.events < max, "game did not terminate within #{max} events"

    {event, rng, stats} = next_event(game, rng, stats)
    {:ok, next} = Game.apply_event(game, event)
    check.(next)
    loop(next, rng, check, max, track(stats, game, next, event))
  end

  defp next_event(%Game{phase: :rolling} = game, rng, stats) do
    assisted? = Game.assisted?(game, game.turn)

    up_probability =
      case assisted? do
        true -> game.variant.assist_up_probability
        false -> game.variant.fair_up_probability
      end

    {shells, rng} = RNG.draw(rng, game.variant.shell_count, up_probability)
    stats = if assisted?, do: Map.update!(stats, :assisted_rolls, &(&1 + 1)), else: stats
    {{:roll, shells}, rng, stats}
  end

  defp next_event(%Game{phase: :assigning} = game, rng, stats) do
    {action, rng} = RNG.pick(rng, Game.legal_actions(game))
    {action, rng, stats}
  end

  defp track(stats, game, next, event) do
    stats
    |> Map.update!(:events, &(&1 + 1))
    |> track_roll(event)
    |> track_action(game, event)
    |> track_capture(game, next)
    |> track_turn(game, next)
  end

  defp track_roll(stats, {:roll, _shells}) do
    rolls = stats.rolls_this_turn + 1

    %{
      stats
      | rolls: stats.rolls + 1,
        rolls_this_turn: rolls,
        max_rolls_per_turn: max(stats.max_rolls_per_turn, rolls)
    }
  end

  defp track_roll(stats, _event), do: stats

  defp track_action(stats, _game, {:khadu, _i, _ix}), do: Map.update!(stats, :khadus, &(&1 + 1))

  defp track_action(stats, game, {:assign, _i, ix}) do
    case Enum.at(Map.fetch!(game.pawns, game.turn), ix).pos do
      :base -> Map.update!(stats, :entries, &(&1 + 1))
      _on_board -> stats
    end
  end

  defp track_action(stats, _game, _event), do: stats

  # Counts pawns sent back to base by this event (positive base-count deltas
  # of the non-moving players).
  defp track_capture(stats, game, next) do
    captured =
      0..(game.num_players - 1)
      |> Enum.reject(&(&1 == game.turn))
      |> Enum.map(&max(Game.base_count(next, &1) - Game.base_count(game, &1), 0))
      |> Enum.sum()

    Map.update!(stats, :captures, &(&1 + captured))
  end

  defp track_turn(stats, %Game{phase: :assigning}, %Game{phase: after_phase})
       when after_phase != :assigning do
    %{stats | turns: stats.turns + 1, rolls_this_turn: 0}
  end

  defp track_turn(stats, _game, _next), do: stats
end
