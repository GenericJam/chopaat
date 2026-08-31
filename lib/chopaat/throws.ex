defmodule Chopaat.Throws do
  @moduledoc """
  The boundary between the game screen and shell-throw *performance*.

  Rules first, animation performs the answer (AGENTS.md): a throw draws the
  shell configuration from `Chopaat.RNG`, then names a baked tumble whose
  settled configuration matches the drawn up-count
  (`assets/tumble_manifest.json`, `throw_k{count}_v{take}`), expressed as
  the `%Mob.Scene3d.IR.Animation{}` state the scene assigns to the tumble
  entity. The screen applies `{:roll, shells}` to `Chopaat.Game` only when
  `{:animation_done, play_id}` arrives — never before the shells visually
  settle.

  Playback itself is the plugin's parallel lane (bead `mob_scene3d-al6`);
  until the integration bead (`chopaat-hre`) wires the native
  `{:animation_done, play_id}` event, the default `Chopaat.Throws.Baked`
  impl delivers the completion message itself so the game is fully playable
  and host-testable. Swap impls via `config :chopaat, :throws, Module`.
  """

  alias Chopaat.RNG
  alias Chopaat.Variant
  alias Mob.Scene3d.IR.Animation

  @typedoc "A drawn throw awaiting its performance."
  @type throw :: %{shells: [boolean()], animation: Animation.t()}

  @doc """
  Draw one shell configuration (fair or drought-assisted probability) and
  the matching tumble animation state.
  """
  @callback throw(RNG.t(), Variant.t(), float()) :: {throw(), RNG.t()}

  @doc """
  Arrange for `{:animation_done, play_id}` to reach `pid`. The baked impl
  sends it immediately; the native-playback impl (chopaat-hre) is a no-op —
  the plugin delivers the event when the clip finishes.
  """
  @callback schedule_done(pid(), String.t()) :: :ok

  @spec throw(RNG.t(), Variant.t(), float()) :: {throw(), RNG.t()}
  def throw(rng, variant, up_probability), do: impl().throw(rng, variant, up_probability)

  @spec schedule_done(pid(), String.t()) :: :ok
  def schedule_done(pid, play_id), do: impl().schedule_done(pid, play_id)

  defp impl, do: Application.get_env(:chopaat, :throws, Chopaat.Throws.Baked)
end

defmodule Chopaat.Throws.Baked do
  @moduledoc """
  The default `Chopaat.Throws` impl: real RNG draw, a take picked from the
  tumble manifest, and instant completion delivery (native playback is the
  chopaat-hre integration; this impl keeps the game playable without it).
  """

  @behaviour Chopaat.Throws

  alias Chopaat.RNG
  alias Chopaat.Rules
  alias Mob.Scene3d.IR.Animation

  @manifest_path "assets/tumble_manifest.json"
  @external_resource @manifest_path
  # Animation names per settled up-count, from the manifest the tumble
  # generator wrote (and gate.mjs re-verifies against the GLB).
  @takes_by_count @manifest_path
                  |> File.read!()
                  |> :json.decode()
                  |> Map.fetch!("animations")
                  |> Enum.group_by(fn {_name, meta} -> meta["count"] end, fn {name, _meta} ->
                    name
                  end)
                  |> Map.new(fn {count, names} -> {count, Enum.sort(names)} end)

  @impl Chopaat.Throws
  def throw(rng, variant, up_probability) do
    {shells, rng} = RNG.draw(rng, variant.shell_count, up_probability)
    up_count = Rules.throw_score(variant, shells).up_count
    {name, rng} = RNG.pick(rng, Map.fetch!(@takes_by_count, up_count))

    play_id = Base.encode16(:crypto.strong_rand_bytes(8))
    {%{shells: shells, animation: %Animation{name: name, play_id: play_id}}, rng}
  end

  @impl Chopaat.Throws
  def schedule_done(pid, play_id) do
    send(pid, {:animation_done, play_id})
    :ok
  end
end
