defmodule Chopaat.Bot.Random do
  @moduledoc """
  Tier 1 (the menu's Bot · easy): a legal-random bot — uniform over the
  session's legal action list. Exists to prove the loop and to anchor the
  strength check: `Chopaat.Bot.Heuristic` must beat this over a mass
  sample (`Chopaat.BotMatchTest`).
  """

  @behaviour Chopaat.Bot

  alias Chopaat.RNG

  @impl Chopaat.Bot
  def choose(_obs, [_ | _] = legal, rng), do: RNG.pick(rng, legal)
end
