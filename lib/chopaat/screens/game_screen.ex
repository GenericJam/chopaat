defmodule Chopaat.Screens.GameScreen do
  @moduledoc """
  The game screen: a `Mob.Scene3d` viewport hosting the board composition
  (`Chopaat.Scene`) under a HUD that makes the two-phase turn structure
  visible — the roll-collection tray with its throw button while specials
  chain, then the assignment tray listing every legal action for the
  surviving rolls and bonus steps.

  State is the pure reducer in assigns: `Chopaat.Game` advances only via
  `apply_event/2`; randomness is a threaded `Chopaat.RNG` state fed
  through the `Chopaat.Throws` boundary (drought assistance from
  `Game.assisted?/2` selects the up-probability). A throw applies its
  `{:roll, shells}` only on `{:animation_done, play_id}` — shells settle
  before the score counts.

  Forced khadus surface as explicit options gated by a confirm dialog that
  names what burns (*dana ane pagdu badi gaya*). Pass-and-play handoff: a
  full-screen prompt replaces the board whenever the turn passes to
  another player.

  Boundary note (bead chopaat-mgw): assignment here is HUD-driven; 3D
  pick-to-move, real tumble playback, and camera work are the integration
  bead (chopaat-hre).
  """

  use Mob.Screen

  alias Chopaat.Game
  alias Chopaat.RNG
  alias Chopaat.Scene
  alias Chopaat.Setup
  alias Chopaat.Throws
  alias Chopaat.Variant

  @impl Mob.Screen
  def mount(params, _session, socket) do
    setup = params[:setup] || Setup.new(4)
    game = params[:game] || Game.new(setup.variant, setup.num_players)

    socket =
      Mob.Socket.assign(socket,
        setup: setup,
        game: game,
        rng: RNG.new(params[:rng_seed] || System.unique_integer([:positive])),
        last_shells: nil,
        throw: nil,
        khadu: nil,
        handoff: nil,
        banner: nil
      )

    {:ok, rebuild_scene(socket)}
  end

  # ── throwing ─────────────────────────────────────────────────────────────

  @impl Mob.Screen
  def handle_info({:tap, :throw}, socket) do
    %{game: game, rng: rng, throw: in_flight, handoff: handoff} = socket.assigns

    case game.phase == :rolling and is_nil(in_flight) and is_nil(handoff) do
      false ->
        {:noreply, socket}

      true ->
        {throw, rng} = Throws.throw(rng, game.variant, up_probability(game))
        Throws.schedule_done(self(), throw.animation.play_id)

        socket = Mob.Socket.assign(socket, rng: rng, throw: throw, banner: nil)
        {:noreply, rebuild_scene(socket)}
    end
  end

  def handle_info({:animation_done, play_id}, socket) do
    case socket.assigns.throw do
      %{animation: %{play_id: ^play_id}, shells: shells} ->
        socket = Mob.Socket.assign(socket, throw: nil, last_shells: shells)
        {:noreply, advance(socket, {:roll, shells})}

      _stale_or_none ->
        {:noreply, socket}
    end
  end

  # ── assignment ───────────────────────────────────────────────────────────

  def handle_info({:tap, {:action, {:khadu, _roll, _pawn} = action}}, socket) do
    # Khadu commits are gated behind the confirm dialog naming the burn.
    {:noreply, Mob.Socket.assign(socket, :khadu, action)}
  end

  def handle_info({:tap, {:action, action}}, socket) do
    {:noreply, advance(socket, action)}
  end

  def handle_info({:tap, :khadu_confirm}, socket) do
    case socket.assigns.khadu do
      nil -> {:noreply, socket}
      action -> {:noreply, socket |> Mob.Socket.assign(:khadu, nil) |> advance(action)}
    end
  end

  def handle_info({:tap, :khadu_cancel}, socket) do
    {:noreply, Mob.Socket.assign(socket, :khadu, nil)}
  end

  # ── flow ─────────────────────────────────────────────────────────────────

  def handle_info({:tap, :handoff_done}, socket) do
    {:noreply, Mob.Socket.assign(socket, :handoff, nil)}
  end

  def handle_info({:tap, :back_to_menu}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:pawn_picked, _entity_id}, socket) do
    # 3D pick-to-move is the integration bead (chopaat-hre); the viewport
    # already tags pawns pickable so the event arrives here when wired.
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp advance(socket, event) do
    game = socket.assigns.game

    case Game.apply_event(game, event) do
      {:ok, next} ->
        socket
        |> Mob.Socket.assign(:game, next)
        |> note_transition(game, next)
        |> rebuild_scene()

      {:error, _reason} ->
        # legal_actions drives the HUD, so an illegal action here is a
        # stale tap (double-fire) — the render already moved on.
        socket
    end
  end

  defp note_transition(socket, prev, next) do
    cond do
      next.phase == :finished ->
        Mob.Socket.assign(socket, handoff: nil, banner: nil)

      next.turn != prev.turn and next.phase == :rolling ->
        Mob.Socket.assign(socket, handoff: %{player: next.turn}, banner: nil, last_shells: nil)

      next.turn == prev.turn and next.phase == :rolling and prev.phase == :assigning ->
        Mob.Socket.assign(socket, :banner, "Extra turn — capture!")

      true ->
        socket
    end
  end

  defp up_probability(game) do
    case Game.assisted?(game, game.turn) do
      true -> game.variant.assist_up_probability
      false -> game.variant.fair_up_probability
    end
  end

  defp rebuild_scene(socket) do
    %{game: game, setup: setup, throw: throw, last_shells: last_shells} = socket.assigns

    scene =
      Scene.build(game, setup,
        shells_up: last_shells,
        throw_animation: throw && throw.animation
      )

    Mob.Socket.assign(socket, :scene, scene)
  end

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

  def render(%{game: %Game{phase: :finished}} = assigns) do
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
          [
            %{
              type: :button,
              props: %{id: :back_to_menu, text: "Back to menu", on_tap: {self(), :back_to_menu}},
              children: []
            }
          ]
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

  defp header(assigns) do
    entry = Setup.player(assigns.setup, assigns.game.turn)

    phase_label =
      case assigns.game.phase do
        :rolling -> "Collect rolls"
        :assigning -> "Assign moves"
      end

    %{
      type: :row,
      props: %{id: :turn_header, gap: :space_sm, padding: :space_xs},
      children:
        compact([
          swatch(entry),
          name_text(entry),
          muted_text(phase_label),
          assisted_marker(assigns.game)
        ])
    }
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
  # bonus steps, and one button per legal action.
  defp tray(%{game: %Game{phase: :rolling}} = assigns) do
    collected =
      case assigns.game.turn_rolls do
        [] -> "Throw the shells"
        rolls -> "Rolls so far: " <> Enum.map_join(rolls, " · ", &to_string/1)
      end

    hint =
      cond do
        assigns.throw != nil -> "Shells are tumbling…"
        assigns.game.turn_rolls == [] -> nil
        true -> "Special score — throw again!"
      end

    [
      %{
        type: :text,
        props: %{id: :roll_tray, text: collected, text_color: :on_background},
        children: []
      },
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

  defp tray(%{game: %Game{phase: :assigning} = game} = assigns) do
    pending =
      "Pending: " <>
        Enum.map_join(game.pending, " · ", &to_string/1) <>
        bonus_suffix(game.bonus_steps)

    [
      %{
        type: :text,
        props: %{id: :pending_tray, text: pending, text_color: :on_background},
        children: []
      }
      | action_buttons(assigns)
    ]
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
