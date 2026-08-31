defmodule Chopaat.Screens.MenuScreen do
  @moduledoc """
  Entry screen: local pass-and-play setup (player count per RULESET.md — 4
  or 6 — plus names), with online/LAN modes surfaced but greyed out as
  coming-soon. Start builds a `Chopaat.Setup` and pushes the game screen.

  Every seat is configurable (bead chopaat-27z): Human, Bot · easy
  (`Chopaat.Bot.Random`) or Bot · normal (`Chopaat.Bot.Heuristic`) — tap
  the seat-type chip to cycle. The AUTO preset flips every seat to
  Bot · normal and starts immediately: the game plays itself on a
  watchable cadence and the game screen spectates (the standing soak
  mode, owner directive on the bead).

  The cosmetic shell-set seed lives here between games: with the settings
  screen's reshuffle toggle ON (default) every game draws a fresh set;
  OFF keeps one seed across games.

  The board mode (2D/3D, bead chopaat-u8x) also lives here between games:
  it defaults to 2D when the scene3d native half is unsupported (the
  always-playable ground truth), 3D otherwise, and the settings screen's
  toggle overrides it for subsequent games.
  """

  use Mob.Screen

  alias Chopaat.Bot
  alias Chopaat.Screens.Board2D
  alias Chopaat.Screens.GameScreen
  alias Chopaat.Screens.SettingsScreen
  alias Chopaat.Setup

  @seat_cycle %{human: :bot_easy, bot_easy: :bot_normal, bot_normal: :human}
  @seat_bots %{bot_easy: Bot.Random, bot_normal: Bot.Heuristic}
  @seat_labels %{human: "Human", bot_easy: "Bot · easy", bot_normal: "Bot · normal"}

  @impl Mob.Screen
  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       num_players: 4,
       names: %{},
       seat_types: %{},
       reshuffle: true,
       shell_seed: nil,
       board_mode: if(Board2D.scene3d_supported?(), do: :board3d, else: :board2d)
     )}
  end

  @impl Mob.Screen
  def handle_info({:tap, {:players, count}}, socket) do
    {:noreply, Mob.Socket.assign(socket, :num_players, count)}
  end

  def handle_info({:change, {:name, ix}, value}, socket) do
    {:noreply, Mob.Socket.update(socket, :names, &Map.put(&1, ix, value))}
  end

  def handle_info({:tap, {:seat_type, ix}}, socket) do
    cycled = Map.fetch!(@seat_cycle, seat_type(socket.assigns, ix))
    {:noreply, Mob.Socket.update(socket, :seat_types, &Map.put(&1, ix, cycled))}
  end

  def handle_info({:tap, :start}, socket) do
    {:noreply, start_game(socket)}
  end

  # AUTO (owner directive, bead chopaat-27z): every seat a bot; the game
  # plays itself to placements and the screen spectates. The preset
  # persists in the seat chips, so a rematch-loop soak survives returning
  # to the menu.
  def handle_info({:tap, :auto}, socket) do
    seat_types = Map.new(0..(socket.assigns.num_players - 1), &{&1, :bot_normal})

    socket
    |> Mob.Socket.assign(:seat_types, seat_types)
    |> start_game()
    |> then(&{:noreply, &1})
  end

  def handle_info({:tap, :settings}, socket) do
    params = %{
      reshuffle: socket.assigns.reshuffle,
      board_mode: socket.assigns.board_mode,
      parent: self()
    }

    {:noreply, Mob.Socket.push_screen(socket, SettingsScreen, params)}
  end

  def handle_info({:settings_reshuffle, value}, socket) do
    {:noreply, Mob.Socket.assign(socket, :reshuffle, value)}
  end

  def handle_info({:settings_board_mode, mode}, socket) do
    {:noreply, Mob.Socket.assign(socket, :board_mode, mode)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp start_game(socket) do
    %{num_players: num_players, names: names} = socket.assigns
    seed = shell_seed(socket.assigns)
    seats = 0..(num_players - 1)

    setup =
      Setup.new(num_players,
        names: Enum.map(seats, &seat_name(socket.assigns, names, &1)),
        seed: seed
      )

    bots =
      for ix <- seats,
          bot = Map.get(@seat_bots, seat_type(socket.assigns, ix)),
          into: %{} do
        {ix, bot}
      end

    socket
    |> Mob.Socket.assign(:shell_seed, seed)
    |> Mob.Socket.push_screen(GameScreen, %{
      setup: setup,
      bots: bots,
      mode: socket.assigns.board_mode
    })
  end

  defp seat_type(assigns, ix), do: Map.get(assigns.seat_types, ix, :human)

  # A typed name always wins; an unnamed bot seat defaults to "Bot N" so
  # the HUD and podium read honestly in auto/mixed games.
  defp seat_name(assigns, names, ix) do
    case {names[ix], seat_type(assigns, ix)} do
      {name, _type} when is_binary(name) and name != "" -> name
      {_blank, :human} -> nil
      {_blank, _bot} -> "Bot #{ix + 1}"
    end
  end

  defp shell_seed(%{reshuffle: false, shell_seed: seed}) when is_integer(seed), do: seed
  defp shell_seed(_assigns), do: System.unique_integer([:positive])

  @impl Mob.Screen
  def render(assigns) do
    %{
      type: :scroll,
      props: %{background: :background},
      children: [
        %{
          type: :column,
          props: %{background: :background, padding: :space_lg, gap: :space_md},
          children: [
            %{
              type: :text,
              props: %{
                text: "Chopaat",
                text_size: :"4xl",
                font_weight: "bold",
                text_color: :on_background
              },
              children: []
            },
            %{
              type: :text,
              props: %{text: "the Gujarat variation", text_size: :sm, text_color: :muted},
              children: []
            },
            section_label("Pass & play"),
            player_count_row(assigns.num_players),
            %{
              type: :column,
              props: %{gap: :space_sm},
              children: Enum.map(0..(assigns.num_players - 1), &seat_row(&1, assigns))
            },
            %{
              type: :button,
              props: %{id: :start, text: "Start game", on_tap: {self(), :start}},
              children: []
            },
            %{
              type: :button,
              props: %{
                id: :auto,
                text: "Auto — bots play, you watch",
                background: :surface_raised,
                text_color: :on_surface,
                on_tap: {self(), :auto}
              },
              children: []
            },
            section_label("Other modes"),
            coming_soon("Online"),
            coming_soon("LAN"),
            %{
              type: :button,
              props: %{
                id: :settings,
                text: "Settings",
                background: :surface_raised,
                text_color: :on_surface,
                on_tap: {self(), :settings}
              },
              children: []
            }
          ]
        }
      ]
    }
  end

  defp section_label(text) do
    %{
      type: :text,
      props: %{text: text, text_size: :lg, font_weight: "semibold", text_color: :on_background},
      children: []
    }
  end

  defp player_count_row(selected) do
    %{
      type: :row,
      props: %{gap: :space_sm},
      children: Enum.map([4, 6], &player_count_tab(&1, selected))
    }
  end

  defp player_count_tab(count, selected) do
    %{
      type: :button,
      props: %{
        id: :"players_#{count}",
        text: "#{count} players",
        fill_width: false,
        background: if(count == selected, do: :primary, else: :surface_raised),
        text_color: if(count == selected, do: :on_primary, else: :on_surface),
        on_tap: {self(), {:players, count}}
      },
      children: []
    }
  end

  # A seat: its name field beside the Human/Bot cycle chip.
  defp seat_row(ix, assigns) do
    %{
      type: :row,
      props: %{gap: :space_sm},
      children: [name_field(ix, assigns.names), seat_type_chip(ix, assigns)]
    }
  end

  defp name_field(ix, names) do
    %{
      type: :text_field,
      props: %{
        id: :"player_name_#{ix}",
        value: names[ix] || "",
        placeholder: "Player #{ix + 1}",
        return_key: :done,
        on_change: {self(), {:name, ix}}
      },
      children: []
    }
  end

  defp seat_type_chip(ix, assigns) do
    type = seat_type(assigns, ix)

    %{
      type: :button,
      props: %{
        id: :"seat_type_#{ix}",
        text: Map.fetch!(@seat_labels, type),
        fill_width: false,
        background: if(type == :human, do: :surface_raised, else: :primary),
        text_color: if(type == :human, do: :on_surface, else: :on_primary),
        on_tap: {self(), {:seat_type, ix}}
      },
      children: []
    }
  end

  defp coming_soon(mode) do
    %{
      type: :row,
      props: %{
        id: :"coming_soon_#{String.downcase(mode)}",
        background: :surface,
        padding: :space_md,
        corner_radius: :radius_md,
        gap: :space_sm
      },
      children: [
        %{type: :text, props: %{text: mode, text_color: :muted}, children: []},
        %{
          type: :text,
          props: %{text: "coming soon", text_size: :xs, text_color: :muted},
          children: []
        }
      ]
    }
  end
end
