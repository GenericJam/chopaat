defmodule Chopaat.Screens.GameScreen do
  @moduledoc """
  The game screen: a *client* of `Chopaat.Session` (owner ruling,
  AGENTS.md "Presentation is a client"). It holds no game authority —
  the session owns the reducer and all randomness; the screen subscribes,
  renders from observed state plus events, and sends commands.

  A `Mob.Scene3d` viewport hosts the board composition (`Chopaat.Scene`)
  under a HUD that makes the two-phase turn structure visible — the
  roll-collection tray with its throw button while specials chain, then
  the assignment tray listing every legal action for the surviving rolls
  and bonus steps.

  The throw flow: `Session.throw/2` decides the outcome server-side and
  the `{:throw_result, ...}` event carries shells + a cosmetic integer;
  the screen performs it (`Chopaat.Throws.perform/2`, the baked tumble)
  and adopts the session's post-roll state only on
  `{:animation_done, play_id}` — presentation grace, not dependency: the
  session has already advanced, and headless clients never wait. Before
  adopting, the screen runs `Chopaat.Throws.settle_check/2` — scene
  readback asserting the slot orientations match the manifest — recording
  the verdict in `assigns.settle` and logging mismatches loudly (this
  verifies the RENDERER against the session's truth; rules are trusted,
  never the visual — the two-plane model).

  Forced khadus surface as explicit options gated by a confirm dialog that
  names what burns (*dana ane pagdu badi gaya*); confirmation commits via
  `Session.confirm_khadu/3`, the API's explicit destructive command.
  Pass-and-play handoff: a full-screen prompt replaces the board whenever
  `{:turn_passed, ...}` hands to another player (deferred until an
  in-flight move animation lands, so the viewport survives the
  performance).

  Pick-to-move (bead chopaat-hre): `{:pawn_picked, id}` on a
  current-player pawn selects it and the scene grows pickable `"target_*"`
  markers on every legal landing (tapping one commits the action; khadu
  targets route through the confirm dialog). Committed movement actions
  play as an eased per-cell hop (`Chopaat.Scene.Move`, `{:move_tick, ref}`
  self-messages) along the `{:moved, ...}` event's path.

  Bot seats (bead chopaat-27z): `params[:bots]` maps seats to
  `Chopaat.Bot` modules; the screen starts a linked
  `Chopaat.Bot.Supervisor` whose runners play those seats through the
  same session API. On a bot's turn the screen is a spectator — throws,
  tumbles and moves render exactly as for humans, the header names whose
  turn it is (with a `bot` marker), but no throw/action buttons appear
  and stray taps are ignored; the pass-the-device handoff is skipped when
  the next seat is a bot. Cadence lives in the runners
  (`:chopaat, :bot_delay_ms`, default 1600 ms — comfortably longer
  than a tumble so a human can follow; tests pass `bot_delay_ms: 0`).

  The game-over report offers a rematch (`Session.new_game/2` with
  `reshuffle: true` — same seats, fresh cosmetic shell set) and, when bot
  seats exist, an auto-loop toggle: with it ON every finished game
  rematches itself after a short beat (`:chopaat, :auto_rematch_ms`) —
  the standing soak mode from the owner directive.
  """

  use Mob.Screen

  require Logger

  alias Chopaat.Game
  alias Chopaat.Scene
  alias Chopaat.Scene.Move
  alias Chopaat.Session
  alias Chopaat.Setup
  alias Chopaat.Throws
  alias Chopaat.Variant
  alias Mob.Scene3d.IR

  @viewport_id "board"

  @default_bot_delay_ms 1600
  @default_auto_rematch_ms 4000

  @impl Mob.Screen
  def mount(params, _session, socket) do
    session = params[:session] || start_session(params)
    :ok = Session.subscribe(session)
    bots = params[:bots] || %{}

    socket =
      Mob.Socket.assign(socket,
        session: session,
        setup: Session.setup(session),
        game: Session.game(session),
        bots: bots,
        bot_sup: start_bots(session, bots, params),
        auto_loop: params[:auto_loop] || false,
        rematch_timer: nil,
        last_shells: nil,
        throw: nil,
        khadu: nil,
        handoff: nil,
        deferred_handoff: nil,
        banner: nil,
        selected: nil,
        move: nil,
        settle: %{ok: 0, mismatch: 0, skipped: 0, error: 0},
        last_settle: nil
      )

    {:ok, rebuild_scene(socket)}
  end

  # A screen-owned session (pass-and-play): linked, so it lives and dies
  # with its only client. External hosts pass `:session` instead.
  defp start_session(params) do
    {:ok, session} =
      Session.start_link(
        setup: params[:setup] || Setup.new(4),
        game: params[:game],
        rng_seed: params[:rng_seed],
        draw: params[:draw]
      )

    session
  end

  # Bot seats play through the same session API, from supervised runner
  # processes linked to this screen (they die with their game). Pacing is
  # the runners' delay — the session itself never waits.
  defp start_bots(_session, bots, _params) when map_size(bots) == 0, do: nil

  defp start_bots(session, bots, params) do
    delay =
      params[:bot_delay_ms] ||
        Application.get_env(:chopaat, :bot_delay_ms, @default_bot_delay_ms)

    {:ok, sup} =
      Chopaat.Bot.Supervisor.start_link(
        session: session,
        seats: Enum.to_list(bots),
        delay_ms: delay
      )

    sup
  end

  defp bot_turn?(assigns), do: Map.has_key?(assigns.bots, assigns.game.turn)

  # ── commands ─────────────────────────────────────────────────────────────

  @impl Mob.Screen
  def handle_info({:tap, :throw}, socket) do
    %{game: game, throw: in_flight, handoff: handoff, move: move} = socket.assigns

    idle? = game.phase == :rolling and is_nil(in_flight) and is_nil(handoff) and is_nil(move)

    case idle? and not bot_turn?(socket.assigns) do
      false -> {:noreply, socket}
      true -> {:noreply, command(socket, &Session.throw(&1, game.turn))}
    end
  end

  def handle_info({:tap, {:action, _action}}, %{assigns: %{move: move}} = socket)
      when not is_nil(move) do
    # A move performance is in flight; the tray re-renders when it lands.
    {:noreply, socket}
  end

  def handle_info({:tap, {:action, action}}, socket) do
    cond do
      # A bot's turn: the screen is a spectator — stray taps are inert.
      bot_turn?(socket.assigns) ->
        {:noreply, socket}

      # Khadu commits are gated behind the confirm dialog naming the burn.
      match?({:khadu, _roll, _pawn}, action) ->
        {:noreply, Mob.Socket.assign(socket, :khadu, action)}

      true ->
        {:noreply, command(socket, &Session.assign(&1, socket.assigns.game.turn, action))}
    end
  end

  def handle_info({:tap, :khadu_confirm}, socket) do
    case socket.assigns.khadu do
      nil ->
        {:noreply, socket}

      action ->
        socket = Mob.Socket.assign(socket, :khadu, nil)
        {:noreply, command(socket, &Session.confirm_khadu(&1, socket.assigns.game.turn, action))}
    end
  end

  def handle_info({:tap, :khadu_cancel}, socket) do
    {:noreply, Mob.Socket.assign(socket, :khadu, nil)}
  end

  # ── session events ───────────────────────────────────────────────────────

  def handle_info({:chopaat_session, session, _seq, event}, socket) do
    case socket.assigns.session == session do
      true -> {:noreply, handle_event(event, socket)}
      false -> {:noreply, socket}
    end
  end

  # ── flow ─────────────────────────────────────────────────────────────────

  def handle_info({:animation_done, play_id}, socket) do
    case socket.assigns.throw do
      %{animation: %{play_id: ^play_id, name: name}, shells: shells} ->
        # The shells have settled — before the presented state advances,
        # assert the performance matched the session's draw (two-plane
        # posture): readback runs while the tumble is the visible truth.
        socket = record_settle(socket, name, Throws.settle_check(@viewport_id, name))

        socket
        |> Mob.Socket.assign(throw: nil, last_shells: shells)
        |> adopt()
        |> then(&{:noreply, &1})

      _stale_or_none ->
        {:noreply, socket}
    end
  end

  def handle_info({:tap, :handoff_done}, socket) do
    {:noreply, Mob.Socket.assign(socket, :handoff, nil)}
  end

  def handle_info({:tap, :back_to_menu}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  # ── rematch / auto-loop (bead chopaat-27z) ───────────────────────────────

  def handle_info({:tap, :rematch}, socket), do: {:noreply, rematch(socket)}

  def handle_info({:tap, :auto_loop_toggle}, socket) do
    {:noreply, Mob.Socket.update(socket, :auto_loop, &(not &1))}
  end

  def handle_info({:auto_rematch, timer}, socket) do
    %{rematch_timer: current, auto_loop: loop?, game: game} = socket.assigns

    case timer == current and loop? and game.phase == :finished do
      true -> {:noreply, rematch(socket)}
      false -> {:noreply, socket}
    end
  end

  # ── pick-to-move ─────────────────────────────────────────────────────────

  def handle_info({:pawn_picked, entity_id}, socket) do
    %{game: game, move: move, khadu: khadu, handoff: handoff} = socket.assigns

    case is_nil(move) and is_nil(khadu) and is_nil(handoff) and not bot_turn?(socket.assigns) do
      false -> {:noreply, socket}
      true -> {:noreply, picked(socket, game, entity_id)}
    end
  end

  def handle_info({:move_tick, ref}, socket) do
    case socket.assigns.move do
      %Move{ref: ^ref} = move ->
        now = now_ms()

        case Move.done?(move, now) do
          true -> {:noreply, socket |> Mob.Socket.assign(:move, nil) |> land_move()}
          false -> {:noreply, tick_move(socket, move, now)}
        end

      _stale_or_none ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # legal_actions drives the HUD, so a rejected command here is a stale
  # tap (double-fire) — the render already moved on. State flows back via
  # the subscription events either way.
  defp command(socket, command) do
    _ok_or_stale = command.(socket.assigns.session)
    socket
  end

  # Same seats, fresh game, fresh cosmetic shell set; the :game_started
  # event resets the presented state (and wakes the bot runners).
  defp rematch(socket) do
    socket = Mob.Socket.assign(socket, :rematch_timer, nil)
    command(socket, &Session.new_game(&1, reshuffle: true))
  end

  # ── event handling (the render plane follows the session's truth) ────────

  # The tumble performs the session's decided outcome; the presented game
  # state stays put until the shells settle ({:animation_done, _}).
  defp handle_event({:throw_result, result}, socket) do
    throw =
      result.up_count
      |> Throws.perform(result.cosmetic)
      |> Map.put(:shells, result.shells)

    Throws.schedule_done(self(), throw.animation.play_id)

    socket
    |> Mob.Socket.assign(throw: throw, banner: nil)
    |> rebuild_scene()
  end

  # A committed movement: adopt the session state and perform the hop
  # along the event's path, starting from the pawn's pre-move scene pose
  # (captured before the adopted state rebuilds the scene).
  defp handle_event({:moved, moved}, socket) do
    prev_scene = socket.assigns.scene

    socket
    |> Mob.Socket.assign(game: Session.game(socket.assigns.session), selected: nil)
    |> start_move(moved, prev_scene)
    |> rebuild_scene()
  end

  # A rematch: fresh game (and possibly a reshuffled cosmetic shell set) —
  # re-fetch setup, drop every in-flight performance, present the reset.
  defp handle_event({:game_started, _started}, socket) do
    socket
    |> Mob.Socket.assign(
      setup: Session.setup(socket.assigns.session),
      last_shells: nil,
      throw: nil,
      khadu: nil,
      handoff: nil,
      deferred_handoff: nil,
      banner: nil,
      move: nil,
      rematch_timer: nil
    )
    |> adopt()
  end

  defp handle_event({:turn_passed, %{extra_turn: true}}, socket) do
    socket
    |> Mob.Socket.assign(:banner, "Extra turn — capture!")
    |> adopt()
  end

  defp handle_event({:turn_passed, %{next_seat: seat, extra_turn: false}}, socket) do
    case Map.has_key?(socket.assigns.bots, seat) do
      # A bot needs no device: skip the pass-and-play prompt and spectate.
      true ->
        socket
        |> Mob.Socket.assign(banner: nil, last_shells: nil)
        |> adopt()

      false ->
        # The handoff prompt replaces the board — while a move performance
        # is in flight it waits for the landing (land_move/1 releases it).
        key = if socket.assigns.move, do: :deferred_handoff, else: :handoff

        socket
        |> Mob.Socket.assign([{key, %{player: seat}}, {:banner, nil}, {:last_shells, nil}])
        |> adopt()
    end
  end

  defp handle_event({:game_over, _over}, socket) do
    socket
    |> Mob.Socket.assign(handoff: nil, deferred_handoff: nil, banner: nil)
    |> schedule_auto_rematch()
    |> adopt()
  end

  # Captures, khadus, wastes, placements: no dedicated performance — the
  # adopted state renders them (players tray, trays, scene).
  defp handle_event(_event, socket), do: adopt(socket)

  # The soak loop: with the auto-loop toggle ON, a finished game rematches
  # itself after a beat (long enough to read the podium). The timer ref
  # guards against a stale fire after a manual rematch.
  defp schedule_auto_rematch(%{assigns: %{auto_loop: false}} = socket), do: socket

  defp schedule_auto_rematch(socket) do
    timer = make_ref()
    delay = Application.get_env(:chopaat, :auto_rematch_ms, @default_auto_rematch_ms)
    Process.send_after(self(), {:auto_rematch, timer}, delay)
    Mob.Socket.assign(socket, :rematch_timer, timer)
  end

  # Re-render from the session's current truth. Idempotent per event
  # batch: the session settles every event of a command before
  # broadcasting, so mid-batch snapshots are identical.
  defp adopt(socket) do
    socket
    |> Mob.Socket.assign(game: Session.game(socket.assigns.session), selected: nil)
    |> rebuild_scene()
  end

  # On mismatch the visual lied (a wire/applier/asset bug, by construction).
  # Log loudly, count it, and trust the rules — the session's state stands
  # regardless.
  defp record_settle(socket, name, verdict) do
    key =
      case verdict do
        :ok -> :ok
        :skipped -> :skipped
        {:mismatch, report} -> loud(name, report, :mismatch)
        {:error, reason} -> loud(name, reason, :error)
      end

    settle = Map.update!(socket.assigns.settle, key, &(&1 + 1))
    Mob.Socket.assign(socket, settle: settle, last_settle: {name, verdict})
  end

  defp loud(name, detail, key) do
    Logger.error(
      "[chopaat] tumble settle #{key} for #{name}: #{inspect(detail)} — trusting the rules"
    )

    key
  end

  # Tapping a current-player pawn in the assigning phase (toggle-)selects
  # it; the scene rebuild grows its target markers.
  defp picked(socket, %Game{phase: :assigning} = game, "pawn_" <> _ = id) do
    with [player, ix] <- decode_pawn(id),
         true <- player == game.turn do
      selected = if socket.assigns.selected == ix, do: nil, else: ix
      socket |> Mob.Socket.assign(:selected, selected) |> rebuild_scene()
    else
      _other_player_or_bad_id -> socket
    end
  end

  # Tapping a target marker commits its action (khadus via the confirm
  # dialog — they burn dana/pagdu, a destructive choice the player must
  # see coming). Stale marker taps fail the legality re-check and drop.
  defp picked(socket, %Game{phase: :assigning} = game, "target_" <> _ = id) do
    with {:ok, action} <- Scene.decode_target(id),
         true <- action in Game.legal_actions(game) do
      case action do
        {:khadu, _i, _ix} ->
          Mob.Socket.assign(socket, :khadu, action)

        _committable ->
          command(socket, &Session.assign(&1, game.turn, action))
      end
    else
      _stale_or_bad_id -> socket
    end
  end

  defp picked(socket, _game, _entity_id), do: socket

  defp decode_pawn(id) do
    with ["pawn", player, ix] <- String.split(id, "_"),
         {player, ""} <- Integer.parse(player),
         {ix, ""} <- Integer.parse(ix) do
      [player, ix]
    else
      _malformed -> :error
    end
  end

  # A committed movement performs as an eased per-cell hop from the pawn's
  # pre-move scene pose to its settled one, along the session event's path.
  defp start_move(socket, %{seat: seat, pawn: ix, path: path}, prev_scene) do
    id = "pawn_#{seat}_#{ix}"
    positions = Enum.map(path, &to_position/1)

    with true <- positions != [],
         {:ok, %{transform: from}} <- IR.fetch(prev_scene, id),
         {:ok, %{transform: to}} <- IR.fetch(settled_scene(socket), id) do
      waypoints = Scene.waypoints(socket.assigns.game, seat, positions)
      move = Move.new(id, from, to, waypoints, now_ms())
      Process.send_after(self(), {:move_tick, move.ref}, Move.tick_ms())
      Mob.Socket.assign(socket, :move, move)
    else
      _no_path_or_entity -> socket
    end
  end

  # Session events carry positions as plain data (renderer vocabulary);
  # the 3D scene's geometry helpers speak lap coordinates.
  defp to_position(%{state: :track, track: x}), do: {:track, x}
  defp to_position(%{state: :home}), do: :home
  defp to_position(%{state: :base}), do: :base

  # Where the pawn will rest once the move lands: the adopted state's
  # scene without the in-flight override (stack fan-out, tip, home ring).
  defp settled_scene(socket) do
    %{game: game, setup: setup, throw: throw, last_shells: last_shells} = socket.assigns
    Scene.build(game, setup, shells_up: last_shells, throw_animation: throw && throw.animation)
  end

  defp tick_move(socket, move, now) do
    Process.send_after(self(), {:move_tick, move.ref}, Move.tick_ms())
    rebuild_scene(socket, now)
  end

  # The landing beat: drop the override (the settled scene pose is the
  # landing) and release any handoff deferred behind the performance.
  defp land_move(socket) do
    case socket.assigns.deferred_handoff do
      nil ->
        rebuild_scene(socket)

      handoff ->
        socket
        |> Mob.Socket.assign(handoff: handoff, deferred_handoff: nil)
        |> rebuild_scene()
    end
  end

  defp rebuild_scene(socket, now \\ nil) do
    %{game: game, setup: setup, throw: throw, last_shells: last_shells} = socket.assigns

    scene =
      Scene.build(game, setup,
        shells_up: last_shells,
        throw_animation: throw && throw.animation,
        selected: socket.assigns.selected,
        move: socket.assigns.move,
        move_now: now || now_ms()
      )

    Mob.Socket.assign(socket, :scene, scene)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ── render ───────────────────────────────────────────────────────────────

  @impl Mob.Screen
  def render(%{handoff: %{player: player}} = assigns) do
    entry = Setup.player(assigns.setup, player)

    %{
      type: :column,
      props: %{background: :background, padding: :space_lg, gap: :space_md, fill_height: true},
      children: [
        %{
          type: :text,
          props: %{
            text: "Pass the device",
            text_size: :"2xl",
            font_weight: "bold",
            text_color: :on_background
          },
          children: []
        },
        %{type: :row, props: %{gap: :space_sm}, children: [swatch(entry), name_text(entry)]},
        %{
          type: :button,
          props: %{
            id: :handoff_done,
            text: "I'm #{entry.name} — start my turn",
            on_tap: {self(), :handoff_done}
          },
          children: []
        }
      ]
    }
  end

  # The game-over report waits for the final move performance to land
  # (`move: nil`) so the last hop plays out on the board.
  def render(%{game: %Game{phase: :finished}, move: nil} = assigns) do
    placements =
      for {player, rank} <- Enum.with_index(assigns.game.placements, 1) do
        entry = Setup.player(assigns.setup, player)
        label = if rank == length(assigns.game.placements), do: "loses", else: "##{rank}"

        %{
          type: :row,
          props: %{id: :"placement_#{rank}", gap: :space_sm, padding: :space_xs},
          children: [swatch(entry), name_text(entry), muted_text(label)]
        }
      end

    %{
      type: :column,
      props: %{background: :background, padding: :space_lg, gap: :space_md},
      children:
        [
          %{
            type: :text,
            props: %{
              text: "Game over",
              text_size: :"2xl",
              font_weight: "bold",
              text_color: :on_background
            },
            children: []
          }
        ] ++
          placements ++
          end_buttons(assigns)
    }
  end

  def render(assigns) do
    %{
      type: :scroll,
      props: %{background: :background},
      children: [
        %{
          type: :column,
          props: %{background: :background, padding: :space_md, gap: :space_sm},
          children:
            compact(
              [header(assigns), banner(assigns.banner), viewport(assigns)] ++
                tray(assigns) ++
                khadu_dialog(assigns) ++
                [players_tray(assigns)]
            )
        }
      ]
    }
  end

  # Rematch keeps the seats (humans and bots alike) and reshuffles the
  # cosmetic shell set. The auto-loop toggle appears in full-auto games —
  # the soak switch: every finished game rematches itself.
  defp end_buttons(assigns) do
    compact([
      %{
        type: :button,
        props: %{id: :rematch, text: "Rematch", on_tap: {self(), :rematch}},
        children: []
      },
      auto_loop_toggle(assigns),
      %{
        type: :button,
        props: %{
          id: :back_to_menu,
          text: "Back to menu",
          background: :surface_raised,
          text_color: :on_surface,
          on_tap: {self(), :back_to_menu}
        },
        children: []
      }
    ])
  end

  defp auto_loop_toggle(assigns) do
    case map_size(assigns.bots) == assigns.game.num_players do
      false ->
        nil

      true ->
        %{
          type: :button,
          props: %{
            id: :auto_loop_toggle,
            text: "Auto-rematch: #{if assigns.auto_loop, do: "on", else: "off"}",
            background: if(assigns.auto_loop, do: :primary, else: :surface_raised),
            text_color: if(assigns.auto_loop, do: :on_primary, else: :on_surface),
            on_tap: {self(), :auto_loop_toggle}
          },
          children: []
        }
    end
  end

  defp header(assigns) do
    entry = Setup.player(assigns.setup, assigns.game.turn)

    phase_label =
      case assigns.game.phase do
        :rolling -> "Collect rolls"
        :assigning -> "Assign moves"
        # Visible only while the final move performance lands.
        :finished -> "Game over"
      end

    %{
      type: :row,
      props: %{id: :turn_header, gap: :space_sm, padding: :space_xs},
      children:
        compact([
          swatch(entry),
          name_text(entry),
          muted_text(phase_label),
          bot_marker(assigns),
          assisted_marker(assigns.game)
        ])
    }
  end

  # The spectator HUD's "whose turn" honesty: bot seats are named as such.
  defp bot_marker(assigns) do
    case bot_turn?(assigns) do
      true ->
        %{
          type: :text,
          props: %{id: :bot_marker, text: "bot", text_size: :xs, text_color: :muted},
          children: []
        }

      false ->
        nil
    end
  end

  defp assisted_marker(game) do
    case Game.assisted?(game, game.turn) do
      true ->
        %{
          type: :text,
          props: %{id: :assisted, text: "assisted", text_size: :xs, text_color: :muted},
          children: []
        }

      false ->
        nil
    end
  end

  defp compact(children), do: Enum.filter(children, &is_map/1)

  defp banner(nil), do: nil

  defp banner(text) do
    %{
      type: :text,
      props: %{
        id: :banner,
        text: text,
        text_color: :on_surface,
        background: :surface_raised,
        padding: :space_sm,
        corner_radius: :radius_md
      },
      children: []
    }
  end

  defp viewport(assigns) do
    Mob.Scene3d.viewport(
      id: :board,
      ir: assigns.scene,
      width: 360,
      height: 400,
      on_pick: :pawn_picked
    )
  end

  # The two-phase turn structure, visibly: rolling shows the collected
  # sequence and the throw button; assigning shows the surviving rolls,
  # bonus steps, and one button per legal action. On a bot's turn the
  # tray is read-only — same trays, no inputs (the runner commands the
  # session; the human just watches).
  defp tray(%{game: %Game{phase: :finished}}), do: []

  defp tray(assigns) do
    case bot_turn?(assigns) do
      true -> spectator_tray(assigns)
      false -> player_tray(assigns)
    end
  end

  defp spectator_tray(%{game: %Game{phase: :rolling}} = assigns) do
    [roll_tray(assigns), bot_hint(assigns, "is throwing…")]
  end

  defp spectator_tray(%{game: %Game{phase: :assigning}} = assigns) do
    [pending_tray(assigns.game), bot_hint(assigns, "is choosing a move…")]
  end

  defp bot_hint(assigns, doing) do
    entry = Setup.player(assigns.setup, assigns.game.turn)

    %{
      type: :text,
      props: %{id: :bot_hint, text: "#{entry.name} #{doing}", text_size: :sm, text_color: :muted},
      children: []
    }
  end

  defp player_tray(%{game: %Game{phase: :rolling}} = assigns) do
    hint =
      cond do
        assigns.throw != nil -> "Shells are tumbling…"
        assigns.game.turn_rolls == [] -> nil
        true -> "Special score — throw again!"
      end

    [
      roll_tray(assigns),
      hint &&
        %{
          type: :text,
          props: %{id: :roll_hint, text: hint, text_size: :sm, text_color: :muted},
          children: []
        },
      %{
        type: :button,
        props: %{
          id: :throw,
          text: throw_label(assigns),
          on_tap: {self(), :throw}
        },
        children: []
      }
    ]
  end

  defp player_tray(%{game: %Game{phase: :assigning}} = assigns) do
    [pending_tray(assigns.game) | action_buttons(assigns)]
  end

  defp roll_tray(assigns) do
    collected =
      case assigns.game.turn_rolls do
        [] -> "Throw the shells"
        rolls -> "Rolls so far: " <> Enum.map_join(rolls, " · ", &to_string/1)
      end

    %{
      type: :text,
      props: %{id: :roll_tray, text: collected, text_color: :on_background},
      children: []
    }
  end

  defp pending_tray(game) do
    pending =
      "Pending: " <>
        Enum.map_join(game.pending, " · ", &to_string/1) <>
        bonus_suffix(game.bonus_steps)

    %{
      type: :text,
      props: %{id: :pending_tray, text: pending, text_color: :on_background},
      children: []
    }
  end

  defp throw_label(%{throw: throw, game: game}) do
    cond do
      throw != nil -> "…"
      game.turn_rolls == [] -> "Throw"
      true -> "Throw again"
    end
  end

  defp bonus_suffix(0), do: ""
  defp bonus_suffix(n), do: "  ·  bonus +1 ×#{n}"

  defp action_buttons(%{khadu: khadu} = assigns) when not is_nil(khadu), do: dialog_only(assigns)

  defp action_buttons(assigns) do
    game = assigns.game

    for {action, ix} <- Enum.with_index(Game.legal_actions(game)) do
      %{
        type: :button,
        props: %{
          id: :"action_#{ix}",
          text: action_label(game, action),
          background: action_background(action),
          text_color: :on_primary,
          on_tap: {self(), {:action, action}}
        },
        children: []
      }
    end
  end

  # While the confirm dialog is up the action list hides — the only exits
  # are confirm and cancel.
  defp dialog_only(_assigns), do: []

  defp action_label(game, {:assign, i, ix}) do
    score = Enum.at(game.pending, i)

    case pawn_pos(game, ix) do
      :base -> "Unlock pawn #{ix + 1} (#{score})"
      _on_board -> "Move pawn #{ix + 1} by #{score}"
    end
  end

  defp action_label(_game, {:bonus_step, ix}), do: "Bonus +1 → pawn #{ix + 1}"

  defp action_label(game, {:khadu, i, ix}),
    do: "Khadu — pawn #{ix + 1} defaults with #{Enum.at(game.pending, i)}"

  defp action_label(game, {:waste, i}), do: "Waste the #{Enum.at(game.pending, i)}"
  defp action_label(_game, :waste_bonus), do: "Waste a bonus step"

  defp action_background({:khadu, _i, _ix}), do: :error
  defp action_background(_action), do: :primary

  defp pawn_pos(game, ix), do: Enum.at(Map.fetch!(game.pawns, game.turn), ix).pos

  # ── khadu confirm ────────────────────────────────────────────────────────

  defp khadu_dialog(%{khadu: nil}), do: []

  defp khadu_dialog(%{khadu: {:khadu, i, ix}, game: game}) do
    score = Enum.at(game.pending, i)

    [
      %{
        type: :column,
        props: %{
          id: :khadu_dialog,
          background: :surface_raised,
          padding: :space_md,
          corner_radius: :radius_md,
          gap: :space_sm
        },
        children: [
          %{
            type: :text,
            props: %{
              text: "Commit khadu?",
              text_size: :lg,
              font_weight: "semibold",
              text_color: :on_surface
            },
            children: []
          },
          %{
            type: :text,
            props: %{
              text: "Pawn #{ix + 1} reverses 4 and defaults forward #{score}.",
              text_size: :sm,
              text_color: :on_surface
            },
            children: []
          },
          %{
            type: :text,
            props: %{
              id: :khadu_burns,
              text: burn_text(game, i),
              text_size: :sm,
              text_color: :on_surface
            },
            children: []
          },
          %{
            type: :row,
            props: %{gap: :space_sm},
            children: [
              %{
                type: :button,
                props: %{
                  id: :khadu_confirm,
                  text: "Commit — badi gaya",
                  background: :error,
                  fill_width: false,
                  on_tap: {self(), :khadu_confirm}
                },
                children: []
              },
              %{
                type: :button,
                props: %{
                  id: :khadu_cancel,
                  text: "Choose another",
                  background: :surface,
                  text_color: :on_surface,
                  fill_width: false,
                  on_tap: {self(), :khadu_cancel}
                },
                children: []
              }
            ]
          }
        ]
      }
    ]
  end

  # Committing a khadu burns every pending dana (2/3/4) and pagdu (bonus
  # step) — dana ane pagdu badi gaya. Name exactly what dies.
  defp burn_text(game, committed_ix) do
    dana =
      game.pending
      |> List.delete_at(committed_ix)
      |> Enum.reject(&Variant.special?(game.variant, &1))

    burns =
      Enum.reject(
        [
          dana != [] && "dana #{Enum.map_join(dana, ", ", &to_string/1)}",
          game.bonus_steps > 0 && "pagdu ×#{game.bonus_steps}"
        ],
        &(&1 == false)
      )

    case burns do
      [] -> "Nothing else is pending — no dana or pagdu burn."
      parts -> "Burns #{Enum.join(parts, " and ")} — dana ane pagdu badi gaya."
    end
  end

  # ── players tray ─────────────────────────────────────────────────────────

  defp players_tray(assigns) do
    game = assigns.game

    %{
      type: :column,
      props: %{id: :players_tray, gap: :space_xs, padding_top: :space_sm},
      children:
        for player <- 0..(game.num_players - 1) do
          entry = Setup.player(assigns.setup, player)
          pawns = Map.fetch!(game.pawns, player)
          base = Enum.count(pawns, &(&1.pos == :base))
          home = Enum.count(pawns, &(&1.pos == :home))

          status =
            Enum.join(
              ["base #{base}", "home #{home}", if(game.tod[player], do: "tod", else: "gated")],
              " · "
            )

          %{
            type: :row,
            props: %{id: :"player_row_#{player}", gap: :space_sm},
            children: [swatch(entry), name_text(entry), muted_text(status)]
          }
        end
    }
  end

  # ── shared bits ──────────────────────────────────────────────────────────

  defp swatch(entry) do
    %{
      type: :box,
      props: %{
        width: 18,
        height: 18,
        corner_radius: :radius_sm,
        background: Setup.argb(entry.tint)
      },
      children: []
    }
  end

  defp name_text(entry) do
    %{
      type: :text,
      props: %{text: entry.name, font_weight: "medium", text_color: :on_background},
      children: []
    }
  end

  defp muted_text(text) do
    %{type: :text, props: %{text: text, text_size: :sm, text_color: :muted}, children: []}
  end
end
