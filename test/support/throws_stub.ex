defmodule Chopaat.Support.ThrowsStub do
  @moduledoc """
  Scripted `Chopaat.Throws` impl for screen tests — the *performance*
  half only (the outcome is the session's; script it with
  `Chopaat.Support.ScriptedDice`). `perform/2` always names take `v0` so
  scene assertions are deterministic; `schedule_done/2` is a no-op —
  tests deliver `{:animation_done, play_id}` explicitly via
  `render_info/2`, exactly the seam the native plugin event replaces.
  Settle verdicts are scripted in the test process dictionary (ScreenCase
  drives the screen callbacks in the test process).
  """

  @behaviour Chopaat.Throws

  alias Mob.Scene3d.IR.Animation

  @settle_key :chopaat_throws_stub_settle

  @impl Chopaat.Throws
  def perform(up_count, _cosmetic) do
    play_id = "stub_#{System.unique_integer([:positive])}"
    %{animation: %Animation{name: "throw_k#{up_count}_v0", play_id: play_id}}
  end

  @impl Chopaat.Throws
  def schedule_done(_pid, _play_id), do: :ok

  @doc "Scripts the next settle verdicts (defaults to `:skipped`)."
  def settle_verdicts(verdicts), do: Process.put(@settle_key, verdicts)

  @impl Chopaat.Throws
  def settle_check(_viewport_id, _animation_name) do
    case Process.get(@settle_key) do
      [verdict | rest] ->
        Process.put(@settle_key, rest)
        verdict

      _empty_or_unset ->
        :skipped
    end
  end
end
