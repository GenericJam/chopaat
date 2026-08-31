defmodule Chopaat.Scene do
  @moduledoc """
  Pure builder: `Chopaat.Game` + `Chopaat.Setup` → `Mob.Scene3d.IR`.

  Placement pipeline: engine lap position → `Chopaat.Board.cell/3` →
  `Chopaat.Board.cell_name/1` → `Chopaat.Scene.BoardMap.position/2` (the
  named node translations extracted from the board `.glb`s — see
  `mix chopaat.gen.cells`). The scene is data in the screen's assigns; the
  `Mob.Scene3d.Viewport` component diffs successive builds, so entity ids
  here are stable across frames by construction.

  Composition:

    * `"board"` — `board.glb` / `board_6p.glb` by player count.
    * `"pawn_{player}_{ix}"` — `pawn.glb` instanced per pawn,
      `material_tint` per player, pickable (pick handling is chopaat-hre).
      Base pawns sit on their arm's seat nodes; home pawns ring the center;
      a pawn in its own final stretch is shown tipped on its side
      (RULESET.md finishing visual note) and stands back up after a khadu.
    * `"shell_{0..6}"` — the game's cosmetic shell set (`Chopaat.Setup`)
      resting on the center plate, posed to the last settled configuration
      (aperture-up = 180° roll about X, the authoring contract).
    * `"tumbles"` — the baked tumble library, visible only while a throw
      is in flight; `Chopaat.Throws` supplies its `%Animation{}` state.
  """

  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Pawn
  alias Chopaat.Scene.BoardMap
  alias Chopaat.Setup
  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Camera, Entity, Light, Material, Model, Transform}

  # Same-cell pawns fan out sideways so a stack reads as a stack.
  @stack_step 0.012
  # A tipped pawn rotates onto its side around X; its origin (bottom
  # center) then needs roughly a body radius of lift to rest on the cell.
  @tipped_lift 0.011
  @shell_ring_radius 0.045
  @home_ring_radius 0.032

  @doc "The board asset for a player count."
  @spec board_asset(pos_integer()) :: String.t()
  def board_asset(4), do: "board.glb"
  def board_asset(6), do: "board_6p.glb"

  @doc """
  Build the scene IR.

  Options:

    * `:shells_up` — the last settled shell configuration (list of up
      booleans) posed onto the static shells; `nil` shows the authored
      dome-up rest.
    * `:throw_animation` — the in-flight `%Mob.Scene3d.IR.Animation{}`
      from `Chopaat.Throws`; while set, the tumble entity plays it and the
      static shells hide.
  """
  @spec build(Game.t(), Setup.t(), keyword()) :: IR.t()
  def build(%Game{} = game, %Setup{} = setup, opts \\ []) do
    board = board_asset(game.num_players)
    shells_up = Keyword.get(opts, :shells_up)
    throw_animation = Keyword.get(opts, :throw_animation)

    IR.new(
      rig(game.num_players) ++
        [board_entity(board)] ++
        pawn_entities(game, setup, board) ++
        shell_entities(setup, board, shells_up, throw_animation) ++
        [tumbles_entity(board, throw_animation)]
    )
  end

  defp rig(num_players) do
    # Angled overhead framing; pulled back a step for the wider 6-arm board.
    {height, dolly} = if num_players == 4, do: {0.72, 0.58}, else: {0.86, 0.70}

    [
      %Entity{
        id: "camera",
        transform: Transform.from_euler({-52.0, 0.0, 0.0}, position: {0.0, height, dolly}),
        data: %Camera{fov_y: 45.0, near: 0.05, far: 10.0}
      },
      %Entity{
        id: "sun",
        transform: Transform.from_euler({-65.0, 30.0, 0.0}),
        data: %Light{type: :directional, intensity: 100_000.0}
      }
    ]
  end

  defp board_entity(board), do: %Entity{id: "board", data: %Model{asset: board}}

  # ── pawns ────────────────────────────────────────────────────────────────

  defp pawn_entities(game, setup, board) do
    for {player, pawns} <- Enum.sort(game.pawns),
        {pawn, ix} <- Enum.with_index(pawns) do
      %Entity{
        id: "pawn_#{player}_#{ix}",
        transform: pawn_transform(game, board, player, ix, pawn),
        pickable: true,
        data: %Model{
          asset: "pawn.glb",
          material: %Material{base_color: Setup.player(setup, player).tint}
        }
      }
    end
  end

  defp pawn_transform(_game, board, player, ix, %Pawn{pos: :base}) do
    %Transform{position: BoardMap.position(board, "base_t#{player}_seat_#{ix}")}
  end

  defp pawn_transform(game, board, player, _ix, %Pawn{pos: :home}) do
    {cx, cy, cz} = BoardMap.position(board, "center_home")
    angle = 2.0 * :math.pi() * player / game.num_players

    %Transform{
      position:
        {cx + @home_ring_radius * :math.sin(angle), cy, cz + @home_ring_radius * :math.cos(angle)}
    }
  end

  defp pawn_transform(game, board, player, ix, %Pawn{pos: {:track, x}}) do
    cell = Board.cell(game.board, player, x)
    {px, py, pz} = BoardMap.position(board, Board.cell_name(cell))
    {px, pz} = stack_offset({px, pz}, game, cell, player, ix)

    case final_stretch?(game, x) do
      true ->
        Transform.from_euler({90.0, 0.0, 0.0}, position: {px, py + @tipped_lift, pz})

      false ->
        %Transform{position: {px, py, pz}}
    end
  end

  # RULESET.md finishing visual note: tipped only inside the private final
  # stretch (past the bottom middle-lane connector). Positions past the
  # connector are reachable only by pawns actually finishing — wrap-mode
  # pawns skip the passage — so position alone decides the pose.
  defp final_stretch?(game, x), do: x > game.board.connector

  defp stack_offset({px, pz}, game, cell, player, ix) do
    stacked =
      for {owner, pawns} <- game.pawns,
          {%Pawn{pos: {:track, pos}}, pawn_ix} <- Enum.with_index(pawns),
          Board.cell(game.board, owner, pos) == cell,
          do: {owner, pawn_ix}

    case stacked do
      [_lone] ->
        {px, pz}

      stack ->
        slot = Enum.find_index(Enum.sort(stack), &(&1 == {player, ix}))
        {px + (slot - (length(stack) - 1) / 2) * @stack_step, pz}
    end
  end

  # ── shells ───────────────────────────────────────────────────────────────

  defp shell_entities(setup, board, shells_up, throw_animation) do
    center = BoardMap.position(board, "center_home")

    for {shell, ix} <- Enum.with_index(setup.shells) do
      %Entity{
        id: "shell_#{ix}",
        transform: shell_transform(center, ix, shells_up),
        visible: is_nil(throw_animation),
        data: %Model{asset: "#{shell}.glb"}
      }
    end
  end

  defp shell_transform({cx, cy, cz}, ix, shells_up) do
    angle = 2.0 * :math.pi() * ix / 7.0

    position =
      {cx + @shell_ring_radius * :math.sin(angle), cy, cz + @shell_ring_radius * :math.cos(angle)}

    # Authored resting dome-up; aperture-up is a 180° roll about X
    # (assets/scripts/README.md → Cowrie orientation contract). A scatter
    # of yaw keeps the ring from reading as a dial.
    aperture_up? = is_list(shells_up) and Enum.at(shells_up, ix, false)
    yaw = ix * 51.4

    case aperture_up? do
      true -> Transform.from_euler({180.0, yaw, 0.0}, position: position)
      false -> Transform.from_euler({0.0, yaw, 0.0}, position: position)
    end
  end

  # The tumble library's origin sits at the center-plate top surface
  # (assets/tumble_manifest.json contract). Slot-mesh substitution (the
  # game's cosmetic shells performing the tumble) is plugin integration —
  # chopaat-hre; until then the entity plays the baked proxy shells.
  defp tumbles_entity(board, throw_animation) do
    %Entity{
      id: "tumbles",
      transform: %Transform{position: BoardMap.position(board, "center_home")},
      visible: not is_nil(throw_animation),
      data: %Model{asset: "tumbles.glb", animation: throw_animation}
    }
  end
end
