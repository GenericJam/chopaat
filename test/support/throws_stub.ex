defmodule Chopaat.Support.ThrowsStub do
  @moduledoc """
  Scripted `Chopaat.Throws` impl for screen tests. The script is a list of
  shells-up counts in the test process dictionary (ScreenCase drives the
  screen callbacks in the test process, so this stays test-local):

      ThrowsStub.script([2, 5])   # first throw scores 2, second 25

  `schedule_done/2` is a no-op — tests deliver `{:animation_done, play_id}`
  explicitly via `render_info/2`, which is exactly the seam the chopaat-hre
  integration replaces with the native event.
  """

  @behaviour Chopaat.Throws

  alias Mob.Scene3d.IR.Animation

  @key :chopaat_throws_stub_script

  def script(up_counts), do: Process.put(@key, up_counts)

  @impl Chopaat.Throws
  def throw(rng, variant, _up_probability) do
    [up_count | rest] = Process.get(@key) || raise "ThrowsStub.script/1 not set"
    Process.put(@key, rest)

    shells =
      List.duplicate(true, up_count) ++ List.duplicate(false, variant.shell_count - up_count)

    play_id = "stub_#{System.unique_integer([:positive])}"

    {%{shells: shells, animation: %Animation{name: "throw_k#{up_count}_v0", play_id: play_id}},
     rng}
  end

  @impl Chopaat.Throws
  def schedule_done(_pid, _play_id), do: :ok
end
