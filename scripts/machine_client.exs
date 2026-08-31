# Acceptance B for bead chopaat-85o: an EXTERNAL client of the machine-play
# protocol. This script runs on a plain BEAM node — no Chopaat application,
# no UI modules, nothing but the standard library loaded locally (asserted
# below) — connects over Erlang dist, and plays a complete seeded 4-player
# game through Chopaat.MachinePlay only:
#
#   observe/1, legal_actions/2, act/3 — every argument and result passes a
#   local :json encode/decode round trip, so the client provably plays off
#   pure JSON-shaped data (the protocol as it would ride HTTP/MCP later).
#
# It prints the JSON exchanges for the first sample turns (the transcript
# quoted in guides/machine-play.md) and exits non-zero on any violation.
#
# Usage (host machine, repo root — spawns its own host node):
#   mise exec -- elixir scripts/machine_client.exs
#
# Or against an existing host that registered a session:
#   CHOPAAT_NODE=host@127.0.0.1 CHOPAAT_SESSION=chopaat_machine_session \
#     mise exec -- elixir --name mclient@127.0.0.1 --cookie chopaat_machine \
#     scripts/machine_client.exs

defmodule MachineClient do
  @protocol Chopaat.MachinePlay
  @session_name :chopaat_machine_session
  @cookie :chopaat_machine
  @seed 85
  @max_commands 200_000
  @transcript_acts 8

  def run do
    ensure_no_game_code_loaded!()
    start_distribution!()
    {host, port} = host_node()

    contract = boundary(rpc(host, :describe, []))
    check!(contract["version"] != nil, "describe/0 carries a version")

    IO.puts(
      "protocol #{contract["protocol"]} v#{contract["version"]} — actions: " <>
        Enum.map_join(contract["actions"], ", ", & &1["type"])
    )

    IO.puts("\n── sample-turn transcript (seed #{@seed}) " <> String.duplicate("─", 30))
    state = loop(host, %{commands: 0, acts: 0, rng: :rand.seed_s(:exsss, {@seed, 1, 2})})

    finale = boundary(rpc(host, :observe, [@session_name]))
    check!(finale["phase"] == "finished", "game reached the finished phase")

    check!(
      Enum.sort(finale["placements"]) == [0, 1, 2, 3],
      "placements are complete: #{inspect(finale["placements"])}"
    )

    IO.puts(
      "\nMACHINE CLIENT PASS: #{state.commands} commands over dist, " <>
        "placements #{inspect(finale["placements"])}, " <>
        "every action picked from the wire legal list, JSON boundary on every call"
    )

    stop_host(host, port)
  end

  # ── the play loop: MachinePlay only, JSON boundary on every call ──────────

  defp loop(host, state) do
    assert!(state.commands < @max_commands, "game terminates within #{@max_commands} commands")
    observed = boundary(rpc(host, :observe, [@session_name]))

    case observed["phase"] do
      "finished" ->
        state

      _playing ->
        seat = observed["turn"]
        legal = boundary(rpc(host, :legal_actions, [@session_name, seat]))
        assert!(legal != [], "the turn seat always has a legal wire action")

        {ix, rng} = :rand.uniform_s(length(legal), state.rng)
        action = Enum.at(legal, ix - 1)

        transcript(state, seat, observed, legal, action)
        events = act!(host, seat, action)
        transcript_events(state, events)

        loop(host, %{state | commands: state.commands + 1, acts: state.acts + 1, rng: rng})
    end
  end

  defp act!(host, seat, action) do
    case rpc(host, :act, [@session_name, seat, boundary(action)]) do
      {:ok, events} -> boundary(events)
      {:error, reason} -> fail("act #{json(action)} for seat #{seat}: #{inspect(reason)}")
    end
  end

  # The JSON boundary: encode locally, decode locally (the stdlib JSON
  # module — nil is null on the wire). Raises if anything non-JSON leaked
  # through the protocol.
  defp boundary(data), do: data |> JSON.encode!() |> JSON.decode!()

  defp json(data), do: JSON.encode!(data)

  # ── the printed sample (quoted in guides/machine-play.md) ─────────────────

  defp transcript(%{acts: acts}, seat, observed, legal, action) when acts < @transcript_acts do
    if acts == 0 do
      IO.puts(">> observe()\n<< #{json(observed)}\n")
    end

    IO.puts(">> legal_actions(seat #{seat})\n<< #{json(legal)}")
    IO.puts(">> act(seat #{seat}, #{json(action)})")
  end

  defp transcript(_state, _seat, _observed, _legal, _action), do: :ok

  defp transcript_events(%{acts: acts}, events) when acts < @transcript_acts do
    IO.puts("<< #{json(events)}\n")
  end

  defp transcript_events(_state, _events), do: :ok

  # ── plumbing: a plain node, a spawned host, dist wiring ───────────────────

  # The point of the exercise: this node runs no game code. The protocol
  # module is a remote name here, nothing more.
  defp ensure_no_game_code_loaded! do
    for module <- [Chopaat, Chopaat.Session, Chopaat.MachinePlay, Chopaat.Screens.GameScreen] do
      check!(:code.is_loaded(module) == false, "#{inspect(module)} is not loaded locally")
    end
  end

  defp start_distribution! do
    case node() do
      :nonode@nohost ->
        _epmd = System.cmd("epmd", ["-daemon"])
        name = :"machine_client_#{System.pid()}@127.0.0.1"
        {:ok, _pid} = :net_kernel.start(name, %{name_domain: :longnames})

      _named ->
        :ok
    end

    Node.set_cookie(cookie())
  end

  defp cookie do
    case System.get_env("CHOPAAT_COOKIE") do
      nil -> @cookie
      cookie -> String.to_atom(cookie)
    end
  end

  defp host_node do
    case System.get_env("CHOPAAT_NODE") do
      nil -> spawn_host()
      node -> {String.to_atom(node), nil}
    end
  end

  # A host node running the real app with one registered session — spawned
  # the way any host (a phone, a server) would exist already in production.
  defp spawn_host do
    host = :"machine_host_#{System.pid()}@127.0.0.1"

    eval = """
    {:ok, _session} =
      Chopaat.Session.start_link(
        players: 4,
        rng_seed: #{@seed},
        name: :#{@session_name}
      )

    spawn(fn ->
      IO.read(:stdio, :eof)
      System.halt(0)
    end)

    IO.puts("MACHINE_HOST_READY")
    Process.sleep(:infinity)
    """

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "--name",
          Atom.to_string(host),
          "--cookie",
          Atom.to_string(cookie()),
          "-S",
          "mix",
          "run",
          "-e",
          eval
        ],
        cd: Path.expand("..", __DIR__)
      ])

    await_host(host, port, System.monotonic_time(:millisecond) + 120_000)
    {host, port}
  end

  defp await_host(host, port, deadline) do
    flush_port(port)

    ready? =
      Node.connect(host) == true and
        is_pid(:rpc.call(host, Process, :whereis, [@session_name]))

    cond do
      ready? -> :ok
      System.monotonic_time(:millisecond) > deadline -> fail("host node did not come up")
      true -> Process.sleep(250) && await_host(host, port, deadline)
    end
  end

  defp flush_port(nil), do: :ok

  defp flush_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write("[host] #{data}")
        flush_port(port)

      {^port, {:exit_status, status}} ->
        fail("host node exited early with status #{status}")
    after
      0 -> :ok
    end
  end

  defp stop_host(_host, nil), do: :ok

  defp stop_host(host, port) do
    _stopping = :rpc.call(host, System, :halt, [0])
    catch_close(port)
  end

  defp catch_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp rpc(host, fun, args) do
    case :rpc.call(host, @protocol, fun, args, 30_000) do
      {:badrpc, reason} -> fail("rpc #{fun} failed: #{inspect(reason)}")
      result -> result
    end
  end

  defp check!(true, what), do: IO.puts("ok: #{what}")
  defp check!(_false, what), do: fail(what)

  defp assert!(true, _what), do: :ok
  defp assert!(_false, what), do: fail(what)

  defp fail(what) do
    IO.puts(:stderr, "MACHINE CLIENT FAIL: #{what}")
    System.halt(1)
  end
end

MachineClient.run()
