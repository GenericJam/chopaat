defmodule Chopaat.Scene.MoveTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.Scene.Move
  alias Mob.Scene3d.IR.Transform

  @from %Transform{position: {0.0, 0.0, 0.0}}
  @to %Transform{position: {0.3, 0.0, 0.0}}

  defp move(waypoints \\ [{0.1, 0.0, 0.0}, {0.2, 0.0, 0.0}, {0.3, 0.0, 0.0}]) do
    Move.new("pawn_0_0", @from, @to, waypoints, 1_000)
  end

  test "starts at the from pose and ends exactly at the to pose" do
    move = move()

    assert Move.transform(move, 1_000).position == @from.position
    assert Move.transform(move, 1_000 + move.duration_ms).position == @to.position
    assert Move.transform(move, 1_000 + move.duration_ms).rotation == @to.rotation
  end

  test "the landing waypoint is replaced by the settled pose position" do
    # Landing at a stack fan-out: waypoint says the bare cell, `to` carries
    # the offset — the move must land on `to`, not the bare cell.
    offset_to = %Transform{position: {0.312, 0.011, 0.0}}
    move = Move.new("pawn_0_0", @from, offset_to, [{0.1, 0.0, 0.0}, {0.3, 0.0, 0.0}], 0)

    assert Move.transform(move, move.duration_ms).position == offset_to.position
  end

  test "mid-segment the pawn lifts (the eased hop) and advances" do
    move = move()
    # Halfway through the first of three segments.
    t = 1_000 + div(move.duration_ms, 6)
    {x, y, _z} = Move.transform(move, t).position

    assert y > 0.005
    assert x > 0.0 and x < 0.1
  end

  test "done?/2 trips exactly at the duration; transform clamps beyond it" do
    move = move()

    refute Move.done?(move, 1_000 + move.duration_ms - 1)
    assert Move.done?(move, 1_000 + move.duration_ms)
    assert Move.transform(move, 1_000 + move.duration_ms * 2).position == @to.position
  end

  test "duration scales with the path length, clamped to a sane band" do
    short = Move.new("p", @from, @to, [{0.1, 0.0, 0.0}], 0)
    long = Move.new("p", @from, @to, List.duplicate({0.1, 0.0, 0.0}, 30), 0)

    assert short.duration_ms >= 250
    assert long.duration_ms <= 2_000
  end

  test "rotation nlerps from the tipped pose to upright across the move" do
    tipped = Transform.from_euler({90.0, 0.0, 0.0})
    move = Move.new("p", tipped, @to, [{0.1, 0.0, 0.0}, {0.2, 0.0, 0.0}], 0)

    assert Move.transform(move, 0).rotation == tipped.rotation

    {x, _y, _z, w} = Move.transform(move, div(move.duration_ms, 2)).rotation
    # Halfway between 90° about X and identity ≈ 45° about X.
    assert_in_delta x, :math.sin(:math.pi() / 8), 0.02
    assert_in_delta w, :math.cos(:math.pi() / 8), 0.02
  end
end
