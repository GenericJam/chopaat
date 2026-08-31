defmodule Chopaat.Screens.SettingsScreen do
  @moduledoc """
  The variant surface, read-only for now: every house rule the engine
  reads is `Chopaat.Variant` data, and nine RULESET.md interpretation
  choices are still pending owner confirmation
  (`decisions/2026-08-30-gujarat-formalization.md`) — so this screen
  displays the config rather than editing it. The live controls: the
  cosmetic shell-pool reshuffle toggle (new shell set per game vs a kept
  set) and the board-mode toggle (2D vs 3D board, bead chopaat-u8x) —
  both reported back to the menu screen that owns them. The board mode
  set here is the default for new games; the game screen's own toggle
  switches mid-game. When the scene3d viewport is unsupported the 3D
  option stays visible but the game screen falls back to 2D with a
  notice.
  """

  use Mob.Screen

  alias Chopaat.Variant

  @impl Mob.Screen
  def mount(params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       variant: params[:variant] || Variant.gujarat(),
       reshuffle: Map.get(params, :reshuffle, true),
       board_mode: Map.get(params, :board_mode, :board3d),
       parent: params[:parent]
     )}
  end

  @impl Mob.Screen
  def handle_info({:change, :reshuffle, value}, socket) do
    case socket.assigns.parent do
      pid when is_pid(pid) -> send(pid, {:settings_reshuffle, value})
      _no_parent -> :ok
    end

    {:noreply, Mob.Socket.assign(socket, :reshuffle, value)}
  end

  def handle_info({:change, :board2d, value}, socket) do
    mode = if value, do: :board2d, else: :board3d

    case socket.assigns.parent do
      pid when is_pid(pid) -> send(pid, {:settings_board_mode, mode})
      _no_parent -> :ok
    end

    {:noreply, Mob.Socket.assign(socket, :board_mode, mode)}
  end

  def handle_info({:tap, :back}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Mob.Screen
  def render(assigns) do
    variant = assigns.variant

    %{
      type: :scroll,
      props: %{background: :background},
      children: [
        %{
          type: :column,
          props: %{background: :background, padding: :space_lg, gap: :space_sm},
          children:
            [
              %{
                type: :text,
                props: %{
                  text: "Settings",
                  text_size: :"2xl",
                  font_weight: "bold",
                  text_color: :on_background
                },
                children: []
              },
              %{
                type: :toggle,
                props: %{
                  id: :reshuffle,
                  label: "New shell set every game",
                  value: assigns.reshuffle,
                  on_change: {self(), :reshuffle}
                },
                children: []
              },
              %{
                type: :toggle,
                props: %{
                  id: :board2d,
                  label: "2D board (always playable)",
                  value: assigns.board_mode == :board2d,
                  on_change: {self(), :board2d}
                },
                children: []
              },
              %{
                type: :text,
                props: %{
                  text: "Variant — #{variant.name} (read-only)",
                  text_size: :lg,
                  font_weight: "semibold",
                  text_color: :on_background,
                  padding_top: :space_md
                },
                children: []
              }
            ] ++
              variant_rows(variant) ++
              [
                %{
                  type: :button,
                  props: %{id: :back, text: "Back", on_tap: {self(), :back}},
                  children: []
                }
              ]
        }
      ]
    }
  end

  defp variant_rows(variant) do
    throw_table =
      variant.throw_table
      |> Enum.sort()
      |> Enum.map_join("  ", fn {up, score} -> "#{up}↑=#{score}" end)

    [
      row("Shells", "#{variant.shell_count}"),
      row("Throw table", throw_table),
      row("Extra-roll scores", scores(variant.special_scores)),
      row("Entry scores", scores(variant.entry_scores)),
      row("Bonus-step scores", scores(variant.bonus_step_scores)),
      row("Repeat cancellation", "groups of #{variant.repeat_cancel_group}"),
      row("Pawns per player", "#{variant.pawns_per_player}"),
      row("Gate track", gate_tracks(variant)),
      row("Khadu reverse", "#{variant.khadu_reverse} cells"),
      row("Capture grants extra turn", "#{variant.capture_grants_extra_turn}"),
      row("Assist after drought", "> #{variant.assist_drought_turns} turns"),
      row(
        "Shell up-probability",
        "fair #{variant.fair_up_probability} · assisted #{variant.assist_up_probability}"
      )
    ]
  end

  defp scores(scores), do: Enum.map_join(scores, ", ", &to_string/1)

  defp gate_tracks(variant) do
    Enum.map_join(Enum.sort(variant.gate_track_by_players), " · ", fn {players, track} ->
      "#{players}p: track #{track}"
    end)
  end

  defp row(label, value) do
    %{
      type: :row,
      props: %{gap: :space_sm, padding: :space_xs},
      children: [
        %{
          type: :text,
          props: %{text: label, text_size: :sm, text_color: :muted, width: 170},
          children: []
        },
        %{
          type: :text,
          props: %{text: value, text_size: :sm, text_color: :on_background},
          children: []
        }
      ]
    }
  end
end
