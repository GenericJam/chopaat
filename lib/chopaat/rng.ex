defmodule Chopaat.RNG do
  @moduledoc """
  The only randomness in the engine. Draws a shell configuration — a list
  of up/down booleans — with an independent up-probability per shell:
  `0.5` for fair shells (uniform over all `2^shell_count` configurations)
  or the variant's assisted bias (`0.7`) when `Chopaat.Game.assisted?/2`
  says a player's drought warrants it. The score derives from the
  configuration via `Chopaat.Rules.throw_score/2`; nothing here knows the
  throw table.

  State is explicit and threaded (`:rand`'s pure `_s` API), so every draw
  is reproducible from a seed.
  """

  @opaque t :: :rand.state()

  @doc "A seeded RNG state."
  @spec new(integer()) :: t()
  def new(seed) when is_integer(seed) do
    :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
  end

  @doc "Draws one shell configuration: `count` shells, each up with `up_probability`."
  @spec draw(t(), pos_integer(), float()) :: {[boolean()], t()}
  def draw(rng, count, up_probability \\ 0.5) when count > 0 do
    Enum.map_reduce(1..count, rng, fn _shell, acc ->
      {u, next} = :rand.uniform_real_s(acc)
      {u < up_probability, next}
    end)
  end

  @doc "A uniform pick from a non-empty list (for simulation drivers)."
  @spec pick(t(), [item]) :: {item, t()} when item: var
  def pick(rng, [_ | _] = items) do
    {ix, next} = :rand.uniform_s(length(items), rng)
    {Enum.at(items, ix - 1), next}
  end
end
