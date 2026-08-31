defmodule Chopaat.Screens.Board2D do
  @moduledoc """
  The 2D board: a pure builder from `Chopaat.Session.observe/1` plain data
  to a Mob UI node tree (owner ruling, bead chopaat-u8x). Deliberately
  canvas-grade simple — a grid of tappable `:box` primitives, chosen over
  `Mob.Canvas` for verifiability: canvas draw ops carry no per-element tap
  targets, while boxes carry `on_tap` tags that `Mob.Test` (and a human
  with the debug overlay) can address by name. This is the always-playable
  fallback, the debugging surface, and the ground truth a human can verify
  at a glance.

  Layout (legibility first, RULESET.md addressing throughout):

    * 4 players — the cross as a cross: a 19×19 slot grid; arm t0 south,
      t1 east, t2 north, t3 west (counter-clockwise, matching the board's
      arm order), lane 0 on the counter-clockwise side per `Chopaat.Board`.
      The shared center is the middle 3×3 (each seat's home tally on the
      edge facing its arm); each seat's base pad sits in the corner beside
      its arm's lane 2.
    * 6 players — 60° arms cannot be boxed, so the six arms lay out flat
      as side-by-side strips (lanes 0/1/2 left to right, row 1 at the top
      nearest the center bar), the center home bar above, base pads below.
      Same cell addressing; legibility over geometric fidelity.

  Visual language echoes the 3D board (blue/ochre/gold on dark): safe
  cells safe-blue, gates ochre (solid while active, outlined once the
  owner holds a tod), center gold, each private middle lane washed with
  its owner's tint. Pawns are tinted discs with state glyphs — stack
  count, `▸` tipped (final stretch), `✕` jammed hard at the gate. The
  seven shells render as glyph discs flipped to the exact configuration
  the session drew (`{:throw_result, ...}` shells — identical outcome to
  the 3D tumble by construction, no animation needed).

  Interaction mirrors the 3D flow through tap tags handled by the owning
  screen: a cell holding the current player's pawn taps as
  `{:cell2d, cell_name}` (selection, stack-cycling), a base pad disc as
  `{:pawn2d, ix}`, and a highlighted legal-target cell as
  `{:action, action}` — the same message the HUD tray buttons emit, so
  khadu targets route through the existing confirm dialog unchanged.

  The debug toggle labels empty cells: the arm label (`t0`…) on each
  arm's middle-lane row 8, lane labels (`l0`/`l1`/`l2`) across row 7, and
  the row number everywhere else — enough to read any cell's
  `cell_t{track}_l{lane}_r{row}` address off the board directly (the ids
  on the boxes are exactly those names).
  """

  import Bitwise

  alias Chopaat.Board
  alias Chopaat.Setup

  # ── the 3D board's palette, gamma-encoded for the 2D (sRGB) plane ────────
  # Sources: assets/scripts/board.py material base colors.
  @tile Setup.argb({0.070, 0.063, 0.055, 1.0})
  @cloth Setup.argb({0.020, 0.018, 0.016, 1.0})
  @safe Setup.argb({0.035, 0.11, 0.30, 1.0})
  @gate Setup.argb({0.45, 0.23, 0.035, 1.0})
  @center Setup.argb({0.40, 0.28, 0.09, 1.0})
  @shell_up Setup.argb({0.85, 0.62, 0.08, 1.0})
  @target_glow Setup.argb({0.85, 0.62, 0.08, 1.0})
  @khadu_glow 0xFFCC2222
  @selected_ring 0xFFFFFFFF
  @muted 0xFF8A8578

  @doc """
  Whether the mob_scene3d native half is present. `:auto` (the default)
  probes `Mob.Scene3d.caps/0` — `{:error, :nif_not_loaded}` (host BEAM or
  a build without the plugin) and `{:error, _}` in general read as
  unsupported. Tests pin the answer via
  `Application.put_env(:chopaat, :scene3d_support, :supported |
  :unsupported)`.
  """
  @spec scene3d_supported?() :: boolean()
  def scene3d_supported? do
    case Application.get_env(:chopaat, :scene3d_support, :auto) do
      :supported -> true
      :unsupported -> false
      :auto -> match?({:ok, _}, Mob.Scene3d.caps())
    end
  end

  @doc """
  The board node tree for an observed session state.

  Options:

    * `:on` — the pid tap tags route to (required for interaction).
    * `:tints` — `%{seat => 0xAARRGGBB}` disc colors.
    * `:selected` — the current player's selected pawn index (or `nil`).
    * `:targets` — `[%{action: term, cell: String.t(), khadu: boolean}]`,
      the selected pawn's legal landings (deduped by cell).
    * `:last_throw` — `%{shells: [boolean], score: integer}` for the shell
      tray, or `nil` before the first throw.
    * `:shell_count` — tray size before the first throw (default 7).
    * `:debug` — render cell addresses (row numbers + arm/lane labels).
  """
  @spec render(map(), keyword()) :: map()
  def render(observed, opts \\ []) do
    board = struct!(Board, observed.board)

    ctx = %{
      on: Keyword.get(opts, :on),
      tints: Keyword.get(opts, :tints, %{}),
      selected: Keyword.get(opts, :selected),
      targets: Map.new(Keyword.get(opts, :targets, []), &{&1.cell, &1}),
      debug: Keyword.get(opts, :debug, false),
      observed: observed,
      board: board,
      gates: Map.new(0..(observed.num_players - 1), &{Board.cell(board, &1, board.gate), &1}),
      cell: if(observed.num_players == 4, do: 16, else: 13)
    }

    %{
      type: :column,
      props: %{id: :board2d, gap: :space_xs},
      children: [
        shell_tray(Keyword.get(opts, :shell_count, 7), Keyword.get(opts, :last_throw)),
        grid(observed, ctx)
      ]
    }
  end

  # ── the seven shells, flipped to the drawn configuration ────────────────

  defp shell_tray(shell_count, last_throw) do
    shells = if last_throw, do: last_throw.shells, else: List.duplicate(nil, shell_count)

    caption =
      case last_throw do
        nil -> "—"
        %{shells: shells, score: score} -> "#{Enum.count(shells, & &1)} up · #{score}"
      end

    %{
      type: :row,
      props: %{id: :shells2d, gap: :space_xs},
      children:
        Enum.with_index(shells, fn up, ix -> shell_glyph(ix, up) end) ++
          [
            %{
              type: :text,
              props: %{id: :shells2d_score, text: caption, text_size: :sm, text_color: @muted},
              children: []
            }
          ]
    }
  end

  # Aperture-up = filled gold disc; dome-down = hollow ring; nil (no throw
  # yet this session) = muted ring.
  defp shell_glyph(ix, up) do
    props =
      case up do
        true -> %{background: @shell_up}
        false -> %{border_color: @shell_up, border_width: 2}
        nil -> %{border_color: @muted, border_width: 1}
      end

    %{
      type: :box,
      props: Map.merge(%{id: :"shell2d_#{ix}", width: 18, height: 18, corner_radius: 9}, props),
      children: []
    }
  end

  # ── the grid ─────────────────────────────────────────────────────────────

  defp grid(observed, ctx) do
    slots = slots(observed.num_players)
    {cols, rows} = extent(observed.num_players)

    %{
      type: :column,
      props: %{id: :grid2d, gap: 1},
      children:
        for row <- 0..(rows - 1) do
          %{
            type: :row,
            props: %{gap: 1},
            children:
              for col <- 0..(cols - 1) do
                slot_node(Map.get(slots, {col, row}, :void), ctx)
              end
          }
        end
    }
  end

  defp extent(4), do: {19, 19}
  defp extent(6), do: {23, 11}

  # 4p: the cross. Arm a's outward unit vector o and its lane axis l
  # (pointing from lane 1 toward lane 0 — the counter-clockwise side).
  defp slots(4) do
    center = {9, 9}

    cells =
      for a <- 0..3, lane <- 0..2, row <- 1..8, into: %{} do
        {o, l} = axes4(a)
        {center |> add(mul(o, 1 + row)) |> add(mul(l, 1 - lane)), {:cell, a, lane, row}}
      end

    pads = for c <- 8..10, r <- 8..10, into: %{}, do: {{c, r}, :center_pad}

    seats =
      for s <- 0..3, into: %{} do
        {o, _l} = axes4(s)
        {add(center, o), {:center_seat, s}}
      end

    bases =
      for s <- 0..3, i <- 0..1, j <- 0..1, into: %{} do
        {o, l} = axes4(s)
        {center |> add(mul(o, 2 + j)) |> add(mul(l, -2 - i)), {:base, s, j * 2 + i}}
      end

    cells |> Map.merge(pads) |> Map.merge(seats) |> Map.merge(bases)
  end

  # 6p: six flat strips (4 columns each incl. a spacer), center bar on top,
  # base pads below.
  defp slots(6) do
    cells =
      for s <- 0..5, lane <- 0..2, row <- 1..8, into: %{} do
        {{s * 4 + lane, row}, {:cell, s, lane, row}}
      end

    bar =
      for s <- 0..5, c <- 0..2, into: %{} do
        {{s * 4 + c, 0}, if(c == 1, do: {:center_seat, s}, else: :center_pad)}
      end

    bases =
      for s <- 0..5, i <- 0..1, j <- 0..1, into: %{} do
        {{s * 4 + i, 9 + j}, {:base, s, j * 2 + i}}
      end

    cells |> Map.merge(bar) |> Map.merge(bases)
  end

  defp axes4(0), do: {{0, 1}, {1, 0}}
  defp axes4(1), do: {{1, 0}, {0, -1}}
  defp axes4(2), do: {{0, -1}, {-1, 0}}
  defp axes4(3), do: {{-1, 0}, {0, 1}}

  defp add({x, y}, {dx, dy}), do: {x + dx, y + dy}
  defp mul({x, y}, k), do: {x * k, y * k}

  # ── slots ────────────────────────────────────────────────────────────────

  defp slot_node(:void, ctx) do
    %{type: :box, props: %{width: ctx.cell, height: ctx.cell}, children: []}
  end

  defp slot_node(:center_pad, ctx) do
    %{
      type: :box,
      props: %{width: ctx.cell, height: ctx.cell, background: @center},
      children: []
    }
  end

  # A seat's home tally on the center: a tinted disc with the count of
  # pawns home; also the landing target for a finishing move.
  defp slot_node({:center_seat, seat}, ctx) do
    home = Enum.count(seat_data(ctx, seat).pawns, &(&1.state == :home))
    target = ctx.targets["center_home"]

    props =
      %{id: :"center2d_#{seat}", width: ctx.cell, height: ctx.cell, background: @center}
      |> put_target(ctx, if(seat == ctx.observed.turn, do: target))

    child =
      case home do
        0 -> []
        n -> [disc(ctx, :"home2d_#{seat}", seat, "#{n}", false)]
      end

    %{type: :box, props: Map.put(props, :align, :center), children: child}
  end

  defp slot_node({:base, seat, ix}, ctx) do
    pawn = Enum.at(seat_data(ctx, seat).pawns, ix)
    own = seat == ctx.observed.turn and ctx.observed.phase == :assigning

    props =
      %{id: :"base2d_#{seat}_#{ix}", width: ctx.cell, height: ctx.cell, background: @cloth}
      |> put_tap(ctx, if(own and pawn.state == :base, do: {:pawn2d, ix}))

    child =
      case pawn.state do
        :base -> [disc(ctx, :"pawn2d_#{seat}_#{ix}", seat, "", selected_base?(ctx, seat, ix))]
        _elsewhere -> []
      end

    %{type: :box, props: Map.put(props, :align, :center), children: child}
  end

  defp slot_node({:cell, track, lane, row}, ctx) do
    cell = {:cell, track, lane, row}
    name = Board.cell_name(cell)
    occupants = Map.get(ctx.observed.occupancy, name, [])
    target = ctx.targets[name]

    props =
      %{id: String.to_atom(name), width: ctx.cell, height: ctx.cell}
      |> Map.put(:background, cell_background(ctx, cell))
      |> put_gate_ring(ctx, cell)
      |> put_target(ctx, target)
      |> put_tap(ctx, cell_tap(ctx, name, occupants, target))
      |> Map.put(:align, :center)

    %{type: :box, props: props, children: cell_child(ctx, cell, occupants)}
  end

  defp cell_background(ctx, {:cell, track, _lane, _row} = cell) do
    cond do
      gate_active?(ctx, cell) -> @gate
      Board.safe?(cell) -> @safe
      home_lane?(cell) -> lane_wash(ctx, track)
      true -> @tile
    end
  end

  defp home_lane?({:cell, _track, 1, _row}), do: true
  defp home_lane?(_cell), do: false

  # The owner's tint at low alpha — every private middle lane reads as its
  # owner's at a glance.
  defp lane_wash(ctx, track) do
    Map.get(ctx.tints, track, @tile) |> band(0x00FFFFFF) |> bor(0x50000000)
  end

  defp gate_active?(ctx, cell) do
    case ctx.gates[cell] do
      nil -> false
      seat -> not seat_data(ctx, seat).tod
    end
  end

  # An open (tod-held) gate keeps its ochre ring so the gate stays legible.
  defp put_gate_ring(props, ctx, cell) do
    case {ctx.gates[cell], gate_active?(ctx, cell)} do
      {nil, _active} -> props
      {_seat, true} -> props
      {_seat, false} -> Map.merge(props, %{border_color: @gate, border_width: 2})
    end
  end

  # Target highlight wins the cell border: gold for ordinary landings,
  # red for a khadu (the destructive default).
  defp put_target(props, _ctx, nil), do: props

  defp put_target(props, ctx, %{action: action, khadu: khadu}) do
    color = if khadu, do: @khadu_glow, else: @target_glow

    props
    |> Map.merge(%{border_color: color, border_width: 2})
    |> put_tap(ctx, {:action, action})
  end

  # Tap priority: a target commits; otherwise an own-pawn cell selects.
  defp cell_tap(_ctx, _name, _occupants, %{action: _committing}), do: nil

  defp cell_tap(ctx, name, occupants, nil) do
    own = Enum.any?(occupants, &(&1.seat == ctx.observed.turn))

    case own and ctx.observed.phase == :assigning do
      true -> {:cell2d, name}
      false -> nil
    end
  end

  defp put_tap(props, _ctx, nil), do: props
  defp put_tap(props, %{on: nil}, _tag), do: props
  defp put_tap(props, _ctx, _tag) when is_map_key(props, :on_tap), do: props
  defp put_tap(props, ctx, tag), do: Map.put(props, :on_tap, {ctx.on, tag})

  defp cell_child(ctx, _cell, [head | _rest] = occupants) do
    %{seat: seat, pawn: ix} = head
    pawn = Enum.at(seat_data(ctx, seat).pawns, ix)

    [
      disc(
        ctx,
        :"pawn2d_#{seat}_#{ix}",
        seat,
        pawn_glyph(occupants, pawn),
        selected_here?(ctx, occupants)
      )
    ]
  end

  defp cell_child(ctx, {:cell, track, lane, row}, []) do
    case {ctx.debug, debug_label(ctx, track, lane, row)} do
      {true, label} when is_binary(label) ->
        [
          %{
            type: :text,
            props: %{text: label, text_size: 7, text_color: @muted},
            children: []
          }
        ]

      _plain ->
        []
    end
  end

  # Debug addressing: the arm label on each arm's outer middle-lane cell,
  # lane labels on row 7 of every lane, row numbers everywhere else.
  defp debug_label(_ctx, track, 1, 8), do: "t#{track}"
  defp debug_label(_ctx, _track, lane, 7), do: "l#{lane}"
  defp debug_label(_ctx, _track, _lane, row), do: "#{row}"

  # Glyph priority: stack count > tipped (final stretch) > jammed at gate.
  defp pawn_glyph([_one, _two | _more] = occupants, _pawn), do: "#{length(occupants)}"
  defp pawn_glyph(_lone, %{tipped: true}), do: "▸"
  defp pawn_glyph(_lone, %{jammed: true}), do: "✕"
  defp pawn_glyph(_lone, _pawn), do: ""

  defp selected_here?(%{selected: nil}, _occupants), do: false

  defp selected_here?(ctx, occupants) do
    Enum.any?(occupants, &(&1.seat == ctx.observed.turn and &1.pawn == ctx.selected))
  end

  defp selected_base?(ctx, seat, ix), do: seat == ctx.observed.turn and ix == ctx.selected

  defp disc(ctx, id, seat, glyph, selected?) do
    d = ctx.cell - 4

    props =
      %{
        id: id,
        width: d,
        height: d,
        corner_radius: div(d, 2),
        background: Map.get(ctx.tints, seat, @muted),
        align: :center
      }
      |> then(fn props ->
        case selected? do
          true -> Map.merge(props, %{border_color: @selected_ring, border_width: 2})
          false -> props
        end
      end)

    child =
      case glyph do
        "" ->
          []

        text ->
          [
            %{
              type: :text,
              props: %{text: text, text_size: 8, text_color: 0xFFFFFFFF, font_weight: "bold"},
              children: []
            }
          ]
      end

    %{type: :box, props: props, children: child}
  end

  defp seat_data(ctx, seat), do: Enum.at(ctx.observed.seats, seat)
end
