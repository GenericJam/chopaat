defmodule Chopaat.BoundaryTest do
  @moduledoc """
  The teeth of the owner ruling "Presentation is a client" (AGENTS.md,
  2026-08-31; decisions/2026-08-31-session-boundary.md): no game-plane
  module may reference any presentation module. If this test fails, game
  code touched a renderer — fix the dependency direction, never this
  test.

  Mechanics (compile-level, xref-grade): for every game-plane BEAM the
  test reads two chunks —

    * `:atoms` — every atom the module embeds. This catches *all* module
      references: remote calls, struct literals (`%Mob.X{}` compiles to a
      map literal with a module atom and no call), module attributes,
      aliases used as values. A forbidden module cannot appear in a
      module's atom table without the source referencing it.
    * `:imports` — the remote-call graph, used to walk the *transitive*
      closure inside `Chopaat.*`: a game module may not launder a
      presentation dependency through an intermediary (e.g. reaching
      `Mob.*` via `Chopaat.Throws`).
  """

  use ExUnit.Case, async: true

  # The game plane: the modules that must stay hostable with no renderer
  # compiled anywhere near them (bead chopaat-uzu; bots — pure session
  # clients — joined at chopaat-27z; the machine-play protocol facade at
  # chopaat-85o).
  @game_plane [
    Chopaat.Game,
    Chopaat.Rules,
    Chopaat.Board,
    Chopaat.Variant,
    Chopaat.Throw,
    Chopaat.Pawn,
    Chopaat.RNG,
    Chopaat.Session,
    Chopaat.Setup,
    Chopaat.MachinePlay,
    Chopaat.Bot,
    Chopaat.Bot.Random,
    Chopaat.Bot.Heuristic,
    Chopaat.Bot.Runner,
    Chopaat.Bot.Supervisor
  ]

  # Forbidden by prefix (atom text): the Mob runtime and every chopaat
  # presentation namespace. "Elixir.Mob" also catches the bare `Mob`
  # module; "Elixir.Chopaat.Scene" covers Scene, Scene.Move, BoardMap.
  @forbidden_prefixes [
    "Elixir.Mob.",
    "Elixir.Chopaat.Scene",
    "Elixir.Chopaat.Screens."
  ]
  @forbidden_exact ["Elixir.Mob"]

  test "no game-plane module references Mob.*, Chopaat.Scene*, or Chopaat.Screens.*" do
    offenses =
      for module <- @game_plane,
          forbidden = forbidden_atoms(module),
          forbidden != [] do
        {module, forbidden}
      end

    assert offenses == [], """
    GAME/PRESENTATION BOUNDARY VIOLATION (owner ruling: presentation is a client).

    Game-plane modules referencing presentation modules:

    #{Enum.map_join(offenses, "\n", fn {module, atoms} -> "  #{inspect(module)} -> #{Enum.join(atoms, ", ")}" end)}

    Game code must never depend on a renderer. Move the dependency into a
    client (screen / scene / throws impl) or expose the fact as plain data
    through Chopaat.Session. See AGENTS.md ("Presentation is a client")
    and decisions/2026-08-31-session-boundary.md. Do not weaken this test.
    """
  end

  test "no game-plane module reaches a presentation module transitively (within Chopaat.*)" do
    graph = chopaat_call_graph()

    offenses =
      for module <- @game_plane,
          reached = reachable(graph, module) |> Enum.filter(&presentation?/1),
          reached != [] do
        {module, reached}
      end

    assert offenses == [], """
    TRANSITIVE BOUNDARY VIOLATION: a game-plane module reaches presentation
    code through an intermediary Chopaat module:

    #{Enum.map_join(offenses, "\n", fn {module, mods} -> "  #{inspect(module)} ~> #{Enum.map_join(mods, ", ", &inspect/1)}" end)}

    Invert the dependency: presentation consumes the game plane, never the
    reverse (AGENTS.md, "Presentation is a client").
    """
  end

  test "the game plane is fully present (a rename must update this list, not dodge it)" do
    for module <- @game_plane do
      assert Code.ensure_loaded?(module), "#{inspect(module)} is gone — update the boundary list"
      assert is_list(beam_atoms(module)), "no BEAM atoms chunk for #{inspect(module)}"
    end
  end

  # ── beam chunk plumbing ────────────────────────────────────────────────

  defp forbidden_atoms(module) do
    self_name = Atom.to_string(module)

    module
    |> beam_atoms()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.filter(fn name ->
      name != self_name and
        (name in @forbidden_exact or String.starts_with?(name, @forbidden_prefixes))
    end)
    |> Enum.sort()
  end

  defp beam_atoms(module) do
    {:ok, {^module, [atoms: atoms]}} = :beam_lib.chunks(beam_path(module), [:atoms])
    Enum.map(atoms, fn {_index, atom} -> atom end)
  end

  defp beam_path(module) do
    {_module, _binary, path} = :code.get_object_code(module)
    path
  end

  # Remote-call edges between Chopaat modules (plus any direct edge into a
  # presentation module), from the BEAM imports chunk.
  defp chopaat_call_graph do
    modules = Application.spec(:chopaat, :modules)

    Map.new(modules, fn module ->
      {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(beam_path(module), [:imports])

      targets =
        imports
        |> Enum.map(fn {target, _fun, _arity} -> target end)
        |> Enum.uniq()
        |> Enum.filter(&(chopaat?(&1) or presentation?(&1)))

      {module, targets}
    end)
  end

  defp chopaat?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.Chopaat.")

  defp presentation?(module) do
    name = Atom.to_string(module)
    name in @forbidden_exact or String.starts_with?(name, @forbidden_prefixes)
  end

  defp reachable(graph, start), do: walk(graph, Map.get(graph, start, []), MapSet.new())

  defp walk(_graph, [], seen), do: MapSet.to_list(seen)

  defp walk(graph, [module | rest], seen) do
    case MapSet.member?(seen, module) do
      true -> walk(graph, rest, seen)
      false -> walk(graph, Map.get(graph, module, []) ++ rest, MapSet.put(seen, module))
    end
  end
end
