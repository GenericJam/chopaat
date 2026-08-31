defmodule Chopaat.SceneTest do
  @moduledoc false

  use ExUnit.Case, async: true

  doctest Chopaat.Scene

  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Scene
  alias Chopaat.Scene.BoardMap
  alias Chopaat.Scene.Move
  alias Chopaat.Setup
  alias Chopaat.Support.Craft
  alias Chopaat.Support.Fixtures
  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Animation, Entity, Model, Transform}

  defp scene(game, opts \\ []) do
    Scene.build(game, Setup.new(game.num_players, seed: 5), opts)
  end

  test "a fresh 4-player scene validates: board, 16 tinted pawns, 7 shells, tumbles" do
    setup = Setup.new(4, seed: 5)
    ir = Scene.build(Game.new(4), setup)

    assert IR.validate(ir) == :ok
    assert {:ok, %Entity{data: %Model{asset: "board.glb"}}} = IR.fetch(ir, "board")

    pawns = for {"pawn_" <> _rest, entity} <- ir.entities, do: entity
    assert Enum.count(pawns) == 16
    assert Enum.all?(pawns, & &1.pickable)

    # Each player's pawns wear that player's tint.
    for player <- 0..3 do
      {:ok, entity} = IR.fetch(ir, "pawn_#{player}_0")
      assert entity.data.material.base_color == Setup.player(setup, player).tint
    end

    # Shells: the setup's cosmetic set, visible at rest on the center plate.
    for ix <- 0..6 do
      {:ok, entity} = IR.fetch(ir, "shell_#{ix}")
      assert entity.data.asset == "#{Enum.at(setup.shells, ix)}.glb"
      assert entity.visible
    end

    {:ok, tumbles} = IR.fetch(ir, "tumbles")
    refute tumbles.visible
    assert tumbles.data.asset == "tumbles.glb"
  end

  test "a 6-player scene uses the 6-arm board and 24 pawns" do
    ir = scene(Game.new(6))

    assert IR.validate(ir) == :ok
    assert {:ok, %Entity{data: %Model{asset: "board_6p.glb"}}} = IR.fetch(ir, "board")
    assert Enum.count(ir.entities, fn {id, _e} -> String.starts_with?(id, "pawn_") end) == 24
  end

  test "base pawns sit on their arm's seat nodes" do
    ir = scene(Game.new(4))

    {:ok, entity} = IR.fetch(ir, "pawn_2_3")
    assert entity.transform.position == BoardMap.position("board.glb", "base_t2_seat_3")
  end

  test "engine position drives placement through the board's named nodes" do
    game = Craft.game() |> Craft.pawns(0, [54, :base, :base, :base])
    ir = scene(game)

    # Lap 54 for player 0 is the gate cell {:cell, 3, 2, 5}.
    cell_name = Board.cell_name(Board.cell(game.board, 0, 54))
    assert cell_name == "cell_t3_l2_r5"

    {:ok, entity} = IR.fetch(ir, "pawn_0_0")
    assert entity.transform.position == BoardMap.position("board.glb", cell_name)
    # Upright: identity rotation outside the final stretch.
    assert entity.transform.rotation == {0.0, 0.0, 0.0, 1.0}
  end

  test "a pawn in the final stretch is tipped on its side (RULESET.md visual note)" do
    ir = scene(Fixtures.near_finish())

    {:ok, tipped} = IR.fetch(ir, "pawn_0_0")
    {x, _y, _z, w} = tipped.transform.rotation
    # 90° about X: quaternion {sin 45°, 0, 0, cos 45°}.
    assert_in_delta x, 0.7071, 0.001
    assert_in_delta w, 0.7071, 0.001

    {:ok, upright} = IR.fetch(ir, "pawn_0_1")
    assert upright.transform.rotation == {0.0, 0.0, 0.0, 1.0}
  end

  test "stacked pawns fan out instead of z-fighting" do
    game = Craft.game() |> Craft.pawns(0, [20, 20, :base, :base])
    ir = scene(game)

    {:ok, a} = IR.fetch(ir, "pawn_0_0")
    {:ok, b} = IR.fetch(ir, "pawn_0_1")

    refute a.transform.position == b.transform.position
  end

  test "home pawns ring the center plate" do
    ir = scene(Fixtures.near_finish())
    {cx, cy, cz} = BoardMap.position("board.glb", "center_home")

    {:ok, home} = IR.fetch(ir, "pawn_0_2")
    {x, y, z} = home.transform.position

    assert y == cy
    assert_in_delta :math.sqrt((x - cx) * (x - cx) + (z - cz) * (z - cz)), 0.032, 0.001
  end

  test "settled shells pose to the drawn configuration (aperture-up rolls 180° about X)" do
    shells_up = [true, false, false, false, false, false, true]
    ir = scene(Game.new(4), shells_up: shells_up)

    for {up?, ix} <- Enum.with_index(shells_up) do
      {:ok, entity} = IR.fetch(ir, "shell_#{ix}")
      {x, _y, _z, w} = entity.transform.rotation

      case up? do
        # 180° about X composed with the yaw scatter: w ≈ 0 with |x| large.
        true -> assert abs(x) > 0.5 and abs(w) < 0.5
        false -> assert abs(x) < 0.01
      end
    end
  end

  test "an in-flight throw shows the tumble animation and hides the static shells" do
    animation = %Animation{name: "throw_k3_v1", play_id: "t1"}
    ir = scene(Game.new(4), throw_animation: animation)

    {:ok, tumbles} = IR.fetch(ir, "tumbles")
    assert tumbles.visible
    assert tumbles.data.animation == animation
    assert tumbles.transform.position == BoardMap.position("board.glb", "center_home")

    {:ok, shell} = IR.fetch(ir, "shell_0")
    refute shell.visible

    assert IR.validate(ir) == :ok
  end

  describe "pick-to-move (bead chopaat-hre)" do
    test "a selected pawn glows; unselected pawns keep the plain tint" do
      game = Fixtures.simple_move([4])
      ir = scene(game, selected: 0)

      {:ok, selected} = IR.fetch(ir, "pawn_0_0")
      assert {_r, _g, _b} = selected.data.material.emissive

      {:ok, other} = IR.fetch(ir, "pawn_0_1")
      assert other.data.material.emissive == nil
      # Same index on another player never lights up.
      {:ok, foreign} = IR.fetch(ir, "pawn_1_0")
      assert foreign.data.material.emissive == nil

      assert IR.validate(ir) == :ok
    end

    test "selection grows pickable target markers on every legal landing" do
      game = Fixtures.simple_move([4])
      ir = scene(game, selected: 0)

      # Pawn 0 at lap 20 with a 4 pending: one landing at lap 24.
      {:ok, marker} = IR.fetch(ir, "target_assign_0_0")
      assert marker.pickable

      cell_name = Board.cell_name(Board.cell(game.board, 0, 24))
      assert marker.transform.position == BoardMap.position("board.glb", cell_name)
      # Flattened pawn disc, not a second pawn.
      {_sx, sy, _sz} = marker.transform.scale
      assert sy < 0.5

      assert IR.validate(ir) == :ok
    end

    test "target ids decode back to the actions they encode" do
      game = Fixtures.simple_move([4])
      ir = scene(game, selected: 0)

      for {"target_" <> _ = id, _entity} <- ir.entities do
        assert {:ok, action} = Scene.decode_target(id)
        assert action in Game.legal_actions(game)
      end
    end

    test "khadu targets glow red (destructive), ordinary targets tint" do
      ir = scene(Fixtures.gate_jam([7]), selected: 0)

      {:ok, marker} = IR.fetch(ir, "target_khadu_0_0")
      assert marker.pickable
      {r, g, b} = marker.data.material.emissive
      assert r > g and r > b
    end

    test "a base pawn's unlock marker sits on the launch square" do
      game = Craft.game() |> Craft.assigning([25])
      ir = scene(game, selected: 2)

      {:ok, marker} = IR.fetch(ir, "target_assign_0_2")
      launch = Board.cell_name(Board.cell(game.board, 0, 0))
      assert marker.transform.position == BoardMap.position("board.glb", launch)
    end

    test "no selection, no markers; other pawns' actions don't leak in" do
      game = Fixtures.simple_move([4])

      targets = fn ir -> Enum.filter(ir.entities, fn {id, _} -> id =~ ~r/^target_/ end) end

      assert targets.(scene(game)) == []
      # Pawn 1 is in base with no entry score pending: nothing to offer.
      assert targets.(scene(game, selected: 1)) == []
    end

    test "duplicate landings collapse to one marker" do
      game = Craft.game() |> Craft.pawns(0, [20, :base, :base, :base]) |> Craft.assigning([3, 3])
      ir = scene(game, selected: 0)

      markers = for {"target_" <> _ = id, _e} <- ir.entities, do: id
      assert match?([_lone], markers)
    end
  end

  describe "move override (bead chopaat-hre)" do
    test "an in-flight move replaces that pawn's transform, others untouched" do
      game = Fixtures.simple_move([4])
      still = scene(game)

      move =
        Move.new(
          "pawn_0_0",
          %Transform{position: {0.0, 0.0, 0.0}},
          %Transform{position: {0.1, 0.0, 0.0}},
          [{0.1, 0.0, 0.0}],
          0
        )

      mid = div(move.duration_ms, 2)
      ir = scene(game, move: move, move_now: mid)

      {:ok, moving} = IR.fetch(ir, "pawn_0_0")
      assert moving.transform == Move.transform(move, mid)

      {:ok, bystander} = IR.fetch(ir, "pawn_1_0")
      {:ok, was} = IR.fetch(still, "pawn_1_0")
      assert bystander.transform == was.transform

      # No target markers while a move performs.
      refute Enum.any?(ir.entities, fn {id, _} -> String.starts_with?(id, "target_") end)
      assert IR.validate(ir) == :ok
    end

    test "waypoints map the rules path onto board cell positions" do
      game = Fixtures.simple_move([4])
      path = Chopaat.Rules.action_path(game, {:assign, 0, 0})

      positions = Scene.waypoints(game, 0, path)

      assert Enum.count(positions) == 4

      expected =
        for {:track, x} <- path do
          BoardMap.position("board.glb", Board.cell_name(Board.cell(game.board, 0, x)))
        end

      assert positions == expected
    end
  end

  describe "camera orbit (bead chopaat-4g7)" do
    # Rotates a vector by a {x, y, z, w} quaternion (v' = q v q⁻¹).
    defp rotate({qx, qy, qz, qw}, {vx, vy, vz}) do
      {tx, ty, tz} = {2 * (qy * vz - qz * vy), 2 * (qz * vx - qx * vz), 2 * (qx * vy - qy * vx)}

      {
        vx + qw * tx + qy * tz - qz * ty,
        vy + qw * ty + qz * tx - qx * tz,
        vz + qw * tz + qx * ty - qy * tx
      }
    end

    defp camera(ir) do
      {:ok, entity} = IR.fetch(ir, "camera")
      entity.transform
    end

    test "the default yaw 0 is exactly the original tuned rig" do
      %Transform{} = transform = camera(scene(Game.new(4)))

      assert transform.position == {0.0, 1.05, 0.78}
      assert transform.rotation == Transform.from_euler({-52.0, 0.0, 0.0}).rotation
    end

    test "yaw 90 (4p seat 1) moves the camera to that seat's side, same framing" do
      %Transform{position: {x, y, z}} = camera(scene(Game.new(4), camera_yaw: 90.0))

      assert_in_delta x, 0.78, 1.0e-9
      assert_in_delta y, 1.05, 1.0e-9
      assert_in_delta z, 0.0, 1.0e-9
    end

    test "every seat yaw preserves the tuned elevation, distance and pitch — no roll" do
      for {players, height, dolly} <- [{4, 1.05, 0.78}, {6, 1.2, 0.9}],
          seat <- 0..(players - 1) do
        yaw = Chopaat.Scene.Orbit.seat_yaw(players, seat)

        %Transform{position: {x, y, z}, rotation: rotation} =
          camera(scene(Game.new(players), camera_yaw: yaw))

        # Same circle: tuned height, tuned distance from the board axis.
        assert_in_delta y, height, 1.0e-9
        assert_in_delta :math.sqrt(x * x + z * z), dolly, 1.0e-9

        # The camera looks at the board center at the tuned -52° pitch:
        # forward's horizontal part points from the camera to the axis,
        # its vertical part is -sin(52°), and up has no sideways lean.
        {fx, fy, fz} = rotate(rotation, {0.0, 0.0, -1.0})
        assert_in_delta fy, -:math.sin(52.0 * :math.pi() / 180.0), 1.0e-9
        horizontal = :math.sqrt(fx * fx + fz * fz)
        assert_in_delta fx / horizontal, -x / dolly, 1.0e-9
        assert_in_delta fz / horizontal, -z / dolly, 1.0e-9

        # No roll: the camera's right axis stays level.
        {_rx, ry, _rz} = rotate(rotation, {1.0, 0.0, 0.0})
        assert_in_delta ry, 0.0, 1.0e-9
      end
    end
  end
end
