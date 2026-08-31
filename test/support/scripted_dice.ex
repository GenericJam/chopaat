defmodule Chopaat.Support.ScriptedDice do
  @moduledoc """
  A scripted shells draw for `Chopaat.Session`'s `:draw` injection seam —
  the randomness stays server-side (in the session), tests just decide
  what it yields:

      Session.start_link(draw: ScriptedDice.draw())
      ScriptedDice.script([2, 5])   # first throw scores 2, second 25

  The script lives in a run-long unlinked Agent (started from
  `test_helper.exs` — the session draws from its own process, so the
  test-process dictionary can't carry it, and a test-linked agent would
  die between tests). Drawing from an empty script raises inside the
  session — a scripted test that throws more than it scripted fails
  loudly.
  """

  @name __MODULE__

  @doc "Starts the run-long script holder (call once, in `test_helper.exs`)."
  def start, do: Agent.start(fn -> [] end, name: @name)

  @doc "Sets (or replaces) the scripted up-counts."
  def script(up_counts), do: Agent.update(@name, fn _old -> up_counts end)

  @doc "The `Chopaat.Session` `:draw` function reading the script."
  def draw do
    fn variant, _up_probability, rng ->
      up_count =
        Agent.get_and_update(@name, fn
          [] -> raise "ScriptedDice script exhausted"
          [next | rest] -> {next, rest}
        end)

      shells =
        List.duplicate(true, up_count) ++
          List.duplicate(false, variant.shell_count - up_count)

      {shells, rng}
    end
  end
end
