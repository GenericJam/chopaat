defmodule Chopaat.Support.DualDrive do
  @moduledoc """
  The two-plane bridge (bead chopaat-85o owner note; reusable for the
  chopaat-4nn acceptance suites): drive a game through the UI, assert
  through the machine API. On one session, `drive_ui/2` delivers a tap
  (or any screen message) and pumps the resulting session event batch
  into the view; `assert_api/1` then requires the screen's rendered
  state to equal `Chopaat.MachinePlay.observe/1` — the API is the oracle
  for UI-driven games, so any divergence is a presentation bug by
  construction.

  What "rendered state equals observe" means here, strongest first:

    1. The adopted snapshot: `assigns.observed` equals the API
       observation, compared in wire space (both sides through a JSON
       round trip, so a non-serializable leak also fails).
    2. The rendered tree (2D board — the ground-truth surface): every
       occupied cell shows the top occupant's tinted disc (stack count
       when 2+), every base/home pawn appears on its pad/tally and
       nowhere else, and the HUD phase header matches the phase.

  `assert_api/1` requires a settled view (no tumble or move performance
  in flight) — in 2D presentation is instant so every event batch
  settles immediately; a 3D caller pumps its `{:animation_done, _}`
  first.
  """

  import ExUnit.Assertions

  alias Chopaat.MachinePlay
  alias Mob.ScreenCase

  @doc """
  Sends `message` to the screen, pumps every queued session event into
  the view (the event batch), asserts the API oracle, returns the view.
  """
  def drive_ui(view, message) do
    view = view |> ScreenCase.render_info(message) |> pump()
    assert_api(view)
  end

  @doc "Pumps queued `{:chopaat_session, ...}` events into the view."
  def pump(view) do
    receive do
      {:chopaat_session, _session, _seq, _event} = message ->
        pump(ScreenCase.render_info(view, message))
    after
      0 -> view
    end
  end

  @doc """
  Asserts the screen's rendered state equals `MachinePlay.observe/1` on
  the screen's own session. Returns the view for piping.
  """
  def assert_api(view) do
    assigns = ScreenCase.assigns(view)

    assert assigns.throw == nil and assigns.move == nil,
           "assert_api needs a settled view — a tumble or move performance is in flight"

    observed = MachinePlay.observe(assigns.session)
    assert wire(assigns.observed) == wire(observed)

    # The tree checks compare the board when it is on screen; overlays
    # (handoff prompt, game-over report) replace it by design and the
    # snapshot equality above still holds through them.
    if ScreenCase.find(view, :column, id: :board2d) != nil do
      assert_rendered(view, observed, assigns)
    end

    view
  end

  defp wire(data), do: data |> JSON.encode!() |> JSON.decode!()

  # ── the rendered 2D tree against the observation ─────────────────────────

  defp assert_rendered(view, observed, assigns) do
    for {cell, occupants} <- observed.occupancy do
      assert_cell(view, assigns, cell, occupants)
    end

    for seat <- observed.seats do
      assert_pads(view, assigns, seat)
      assert_home_tally(view, seat)
    end

    assert_phase_header(view, observed)
  end

  # The top occupant's disc renders on its cell, tinted for its seat,
  # with the stack count when 2+ share the cell.
  defp assert_cell(view, assigns, cell, [%{seat: seat, pawn: ix} | _rest] = occupants) do
    node = ScreenCase.find(view, :box, id: String.to_atom(cell))
    assert node, "occupied cell #{cell} is not rendered"

    disc = ScreenCase.find(node, :box, id: :"pawn2d_#{seat}_#{ix}")
    assert disc, "cell #{cell}: no disc for seat #{seat} pawn #{ix}"
    assert disc.props.background == Map.fetch!(assigns.tints, seat)

    case occupants do
      [_lone] -> :ok
      stack -> assert ScreenCase.find(disc, :text, text: "#{length(stack)}")
    end
  end

  # Base pads carry a disc exactly for pawns the API says are in base.
  defp assert_pads(view, assigns, seat) do
    for %{pawn: ix, state: state} <- seat.pawns do
      pad = ScreenCase.find(view, :box, id: :"base2d_#{seat.seat}_#{ix}")
      assert pad, "base pad #{seat.seat}/#{ix} is not rendered"
      disc = ScreenCase.find(pad, :box, id: :"pawn2d_#{seat.seat}_#{ix}")

      case state do
        :base ->
          assert disc, "pawn #{seat.seat}/#{ix} is in base but not on its pad"
          assert disc.props.background == Map.fetch!(assigns.tints, seat.seat)

        _on_board_or_home ->
          assert disc == nil, "pawn #{seat.seat}/#{ix} is #{state} but renders on its pad"
      end
    end
  end

  # The center tally disc counts the seat's home pawns (absent at zero).
  defp assert_home_tally(view, seat) do
    home = Enum.count(seat.pawns, &(&1.state == :home))
    tally = ScreenCase.find(view, :box, id: :"center2d_#{seat.seat}")
    assert tally, "center tally for seat #{seat.seat} is not rendered"

    case home do
      0 -> assert ScreenCase.find(tally, :text) == nil
      n -> assert ScreenCase.find(tally, :text, text: "#{n}")
    end
  end

  defp assert_phase_header(view, observed) do
    label =
      case observed.phase do
        :rolling -> "Collect rolls"
        :assigning -> "Assign moves"
        :finished -> "Game over"
      end

    assert ScreenCase.text(view) =~ label
  end
end
