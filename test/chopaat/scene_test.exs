defmodule Chopaat.SceneTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Scene
  alias Chopaat.Scene.BoardMap
  alias Chopaat.Setup
  alias Chopaat.Support.Craft
  alias Chopaat.Support.Fixtures
  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Animation, Entity, Model}

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
end
