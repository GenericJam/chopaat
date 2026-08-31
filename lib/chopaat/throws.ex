defmodule Chopaat.Throws do
  @moduledoc """
  The presentation-side boundary for shell-throw *performance*. The
  outcome is not decided here: `Chopaat.Session` draws the shells and a
  cosmetic integer server-side (rules first, animation performs the
  answer); this boundary turns that decided outcome into a performance —
  a baked tumble whose settled configuration matches the drawn up-count
  (`Chopaat.Throws.Manifest`, `throw_k{count}_v{take}`), expressed as the
  `%Mob.Scene3d.IR.Animation{}` state the scene assigns to the tumble
  entity.

  The screen adopts the session's post-roll state only when
  `{:animation_done, play_id}` arrives — never before the shells visually
  settle — and first runs `settle_check/2`, the post-settle scene
  readback asserting the seven slot orientations match the manifest
  (`Chopaat.Throws.Settle`). The check verifies the RENDERER against the
  session's truth (the two-plane model): a mismatch is logged loudly and
  the rules are trusted, never the visual.

  The take pick is deterministic in the session's `cosmetic` integer
  (`rem` by the outcome's take count), so every client — and a host-side
  predictor replaying the session RNG — performs the identical take.

  Impls: `Chopaat.Throws.Native` (device default, set by
  `Chopaat.MobApp.on_start/0`) lets the plugin deliver the completion
  event and does the real readback; `Chopaat.Throws.Baked` (host default)
  delivers completion instantly so the game stays playable and
  host-testable without the native half. Swap impls via
  `config :chopaat, :throws, Module`.
  """

  alias Mob.Scene3d.IR.Animation

  @typedoc "A performance for a decided throw."
  @type throw :: %{animation: Animation.t()}

  @typedoc "Post-settle readback verdict (`:skipped` = no native scene)."
  @type settle :: :ok | :skipped | {:mismatch, map()} | {:error, term()}

  @doc """
  The tumble performance for a session-decided outcome: `up_count` names
  the take family, `cosmetic` picks the take deterministically.
  """
  @callback perform(non_neg_integer(), non_neg_integer()) :: throw()

  @doc """
  Arrange for `{:animation_done, play_id}` to reach `pid`. The baked impl
  sends it immediately; the native impl is a no-op — the plugin delivers
  the event when the clip finishes.
  """
  @callback schedule_done(pid(), String.t()) :: :ok

  @doc """
  Post-settle honesty check for `animation_name` on `viewport_id`: read the
  applied scene back and assert the slot orientations match the manifest.
  Impls without a native scene return `:skipped`.
  """
  @callback settle_check(String.t(), String.t()) :: settle()

  @spec perform(non_neg_integer(), non_neg_integer()) :: throw()
  def perform(up_count, cosmetic), do: impl().perform(up_count, cosmetic)

  @spec schedule_done(pid(), String.t()) :: :ok
  def schedule_done(pid, play_id), do: impl().schedule_done(pid, play_id)

  @spec settle_check(String.t(), String.t()) :: settle()
  def settle_check(viewport_id, animation_name),
    do: impl().settle_check(viewport_id, animation_name)

  defp impl, do: Application.get_env(:chopaat, :throws, Chopaat.Throws.Baked)
end

defmodule Chopaat.Throws.Baked do
  @moduledoc """
  The host-default `Chopaat.Throws` impl: a take picked deterministically
  from the tumble manifest by the session's cosmetic integer, instant
  completion delivery, and no settle readback (`:skipped`) — the game
  stays playable and host-testable without the native half. Devices run
  `Chopaat.Throws.Native`.
  """

  @behaviour Chopaat.Throws

  alias Chopaat.Throws.Manifest
  alias Mob.Scene3d.IR.Animation

  @impl Chopaat.Throws
  def perform(up_count, cosmetic) do
    takes = Manifest.takes(up_count)
    name = Enum.at(takes, rem(cosmetic, length(takes)))
    play_id = Base.encode16(:crypto.strong_rand_bytes(8))

    %{animation: %Animation{name: name, play_id: play_id}}
  end

  @impl Chopaat.Throws
  def schedule_done(pid, play_id) do
    send(pid, {:animation_done, play_id})
    :ok
  end

  @impl Chopaat.Throws
  def settle_check(_viewport_id, _animation_name), do: :skipped
end

defmodule Chopaat.Throws.Native do
  @moduledoc """
  The on-device `Chopaat.Throws` impl (default set by
  `Chopaat.MobApp.on_start/0`): the same deterministic take pick as
  `Chopaat.Throws.Baked` (delegated, so host predictions perform the
  exact take), but completion comes from the plugin's
  `{:animation_done, play_id}` event — `schedule_done/2` is a no-op — and
  `settle_check/2` performs the real `Mob.Scene3d.scene/1` readback
  assertion (`Chopaat.Throws.Settle`).

  `config :chopaat, :throw_speed` (default 1.0) scales clip playback — the
  scripted-acceptance runs use it to keep a full game inside a session; the
  settle contract is speed-independent (the readback asserts the final
  pose, not timing).
  """

  @behaviour Chopaat.Throws

  alias Chopaat.Throws.Baked
  alias Chopaat.Throws.Settle

  @impl Chopaat.Throws
  def perform(up_count, cosmetic) do
    throw = Baked.perform(up_count, cosmetic)
    speed = Application.get_env(:chopaat, :throw_speed, 1.0)
    %{throw | animation: %{throw.animation | speed: speed}}
  end

  @impl Chopaat.Throws
  def schedule_done(_pid, _play_id), do: :ok

  @impl Chopaat.Throws
  def settle_check(viewport_id, animation_name) do
    case Mob.Scene3d.scene(viewport_id) do
      {:ok, scene} -> Settle.verify(scene, animation_name)
      {:error, :nif_not_loaded} -> :skipped
      {:error, reason} -> {:error, reason}
    end
  end
end
