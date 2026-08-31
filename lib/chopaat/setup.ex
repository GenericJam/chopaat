defmodule Chopaat.Setup do
  @moduledoc """
  Per-game setup state: the players (name + tint) and the cosmetic shell
  set. This lives beside the rules, not inside them — `Chopaat.Game` sees
  only up/down counts; which 7 cowrie meshes perform the throw is a
  per-game cosmetic choice (owner ruling, bead notes on chopaat-mgw).

  The shell set is a seeded draw of 7 members from the owner-ruled game
  pool (`assets/shell_pool.json`, bead chopaat-cbr); `reshuffle/1` draws a
  fresh set for the next game when the settings toggle asks for it.
  """

  alias Chopaat.RNG
  alias Chopaat.Variant

  @pool_path "assets/shell_pool.json"
  @external_resource @pool_path
  @pool @pool_path
        |> File.read!()
        |> :json.decode()
        |> Map.fetch!("members")
        |> Map.keys()
        |> Enum.sort()

  # Player tints (linear 0..1 floats, glTF factor semantics — the IR
  # material convention) applied to the neutral near-white pawn asset.
  @palette [
    {:red, {0.72, 0.11, 0.10, 1.0}},
    {:blue, {0.12, 0.29, 0.68, 1.0}},
    {:green, {0.13, 0.45, 0.17, 1.0}},
    {:yellow, {0.85, 0.62, 0.08, 1.0}},
    {:purple, {0.40, 0.15, 0.55, 1.0}},
    {:orange, {0.80, 0.33, 0.05, 1.0}}
  ]

  @enforce_keys [:num_players, :players, :seed, :shells]
  defstruct [:num_players, :players, :seed, :shells, variant: Variant.gujarat()]

  @type player :: %{name: String.t(), color: atom(), tint: {float(), float(), float(), float()}}
  @type t :: %__MODULE__{
          num_players: pos_integer(),
          players: [player()],
          seed: integer(),
          shells: [String.t()],
          variant: Variant.t()
        }

  @doc """
  Setup for a pass-and-play game. `names` fills in for `"Player N"`
  defaults; the seed (default: unique) picks the game's 7 shells.
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(num_players, opts \\ []) do
    variant = Keyword.get(opts, :variant, Variant.gujarat())
    true = num_players in variant.supported_player_counts
    seed = Keyword.get_lazy(opts, :seed, fn -> System.unique_integer([:positive]) end)
    names = Keyword.get(opts, :names, [])

    players =
      for {{color, tint}, ix} <- Enum.with_index(Enum.take(@palette, num_players)) do
        %{name: Enum.at(names, ix) || "Player #{ix + 1}", color: color, tint: tint}
      end

    %__MODULE__{
      num_players: num_players,
      players: players,
      seed: seed,
      shells: draw_shells(seed, variant.shell_count),
      variant: variant
    }
  end

  @doc "A fresh cosmetic shell set for the same players (new seed)."
  @spec reshuffle(t()) :: t()
  def reshuffle(%__MODULE__{} = setup) do
    seed = System.unique_integer([:positive])
    %{setup | seed: seed, shells: draw_shells(seed, setup.variant.shell_count)}
  end

  @doc "The owner-ruled cowrie game pool (asset base names, sorted)."
  @spec pool() :: [String.t()]
  def pool, do: @pool

  @doc """
  A linear-float tint as the `0xAARRGGBB` integer the 2D HUD needs
  (gamma-encoded, since the 2D layer draws in sRGB).

      iex> Chopaat.Setup.argb({1.0, 1.0, 1.0, 1.0})
      0xFFFFFFFF
  """
  @spec argb({float(), float(), float(), float()}) :: non_neg_integer()
  def argb({r, g, b, a}) do
    # Alpha is coverage, not light — it stays linear; rgb gamma-encode.
    [round(a * 255) | Enum.map([r, g, b], &round(:math.pow(&1, 1 / 2.2) * 255))]
    |> Enum.reduce(0, fn channel, acc -> acc * 256 + channel end)
  end

  @doc "A player's setup entry."
  @spec player(t(), non_neg_integer()) :: player()
  def player(%__MODULE__{players: players}, ix), do: Enum.at(players, ix)

  @doc "Renames one player (menu-screen editing)."
  @spec rename(t(), non_neg_integer(), String.t()) :: t()
  def rename(%__MODULE__{} = setup, ix, name) do
    %{setup | players: List.update_at(setup.players, ix, &%{&1 | name: name})}
  end

  # Seeded draw without replacement: slot i of the tumble scene gets
  # shells |> Enum.at(i). Deterministic per seed so a game's shell set is
  # reproducible (and host-testable) from setup state alone.
  defp draw_shells(seed, count) do
    Enum.map_reduce(1..count, {RNG.new(seed), @pool}, fn _slot, {rng, remaining} ->
      {member, rng} = RNG.pick(rng, remaining)
      {member, {rng, List.delete(remaining, member)}}
    end)
    |> elem(0)
  end
end
