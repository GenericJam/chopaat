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
    * `"target_*"` — pick-to-move destination markers (bead chopaat-hre):
      while a pawn is `:selected`, every legal action it can absorb gets a
      flattened pawn-disc marker on its landing cell (`Rules.action_path/2`
      decides the landing), pickable, with the action encoded in the entity
      id (`decode_target/1`) so tapping a marker commits the action. Khadu
      landings glow red; ordinary landings glow the player tint. The
      selected pawn itself gets an emissive lift.

  A `:move` override (see `Chopaat.Scene.Move`) replaces one pawn's
  computed transform while its move animation is in flight.
  """

  alias Chopaat.Board
  alias Chopaat.Game
  alias Chopaat.Pawn
  alias Chopaat.Rules
  alias Chopaat.Scene.BoardMap
  alias Chopaat.Scene.Move
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
    * `:selected` — the current player's selected pawn index (pick-to-move):
      lifts that pawn emissively and adds the `"target_*"` markers.
    * `:move` — `%Chopaat.Scene.Move{}` in flight; overrides that entity's
      transform with `Move.transform/2` evaluated at `:move_now` ms.
  """
  @spec build(Game.t(), Setup.t(), keyword()) :: IR.t()
  def build(%Game{} = game, %Setup{} = setup, opts \\ []) do
    board = board_asset(game.num_players)
    shells_up = Keyword.get(opts, :shells_up)
    throw_animation = Keyword.get(opts, :throw_animation)
    selected = Keyword.get(opts, :selected)
    move = Keyword.get(opts, :move)
    move_now = Keyword.get(opts, :move_now, 0)

    IR.new(
      rig(game.num_players) ++
        [board_entity(board)] ++
        pawn_entities(game, setup, board, selected, move, move_now) ++
        target_entities(game, setup, board, selected, move) ++
        shell_entities(setup, board, shells_up, throw_animation) ++
        [tumbles_entity(board, throw_animation)]
    )
  end

  defp rig(num_players) do
    # Angled overhead framing; pulled back a step for the wider 6-arm board.
    # Tuned against the pool-emulator screenshot (evidence/): the whole
    # cross incl. base pads fits a 360x400 viewport.
    {height, dolly} = if num_players == 4, do: {1.05, 0.78}, else: {1.2, 0.9}

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

  defp pawn_entities(game, setup, board, selected, move, move_now) do
    for {player, pawns} <- Enum.sort(game.pawns),
        {pawn, ix} <- Enum.with_index(pawns) do
      id = "pawn_#{player}_#{ix}"
      selected? = player == game.turn and ix == selected
      tint = Setup.player(setup, player).tint

      %Entity{
        id: id,
        transform: pawn_pose(game, board, player, ix, pawn, move, move_now, id),
        pickable: true,
        data: %Model{
          asset: "pawn.glb",
          material: %Material{
            # Scoped to the body so the authored ivory accent band/tip stays
            # untinted (mob_scene3d name-scoped overrides; see chopaat-xix).
            scope: "pawn_body",
            base_color: tint,
            emissive: if(selected?, do: emissive(tint), else: nil)
          }
        }
      }
    end
  end

  defp pawn_pose(_game, _board, _player, _ix, _pawn, %Move{entity_id: id} = move, now, id) do
    Move.transform(move, now)
  end

  defp pawn_pose(game, board, player, ix, pawn, _move, _now, _id) do
    pawn_transform(game, board, player, ix, pawn)
  end

  # A dimmed-tint glow: bright enough to read as "picked" without blowing
  # out the tint under the sun light.
  defp emissive({r, g, b, _a}), do: {r * 0.5, g * 0.5, b * 0.5}

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

  # ── pick-to-move target markers ──────────────────────────────────────────

  # Marker look: the neutral pawn asset flattened to a disc on the landing
  # cell (no new asset, no new plugin surface), emissive so it reads on the
  # dark board. Pickable — tapping the marker IS committing the action.
  @marker_scale {1.1, 0.16, 1.1}
  @khadu_glow {0.55, 0.04, 0.04}

  defp target_entities(%Game{phase: :assigning} = game, setup, board, selected, nil = _move)
       when is_integer(selected) do
    tint = Setup.player(setup, game.turn).tint

    game
    |> Game.legal_actions()
    |> Enum.filter(&(action_pawn(&1) == selected))
    |> Enum.map(&{&1, List.last(Rules.action_path(game, &1))})
    |> Enum.reject(fn {_action, landing} -> is_nil(landing) end)
    |> Enum.uniq_by(fn {_action, landing} -> landing end)
    |> Enum.map(fn {action, landing} ->
      %Entity{
        id: target_id(action),
        transform: %Transform{
          position: landing_position(game, board, game.turn, landing),
          scale: @marker_scale
        },
        pickable: true,
        data: %Model{
          asset: "pawn.glb",
          material: %Material{base_color: tint, emissive: marker_glow(action, tint)}
        }
      }
    end)
  end

  defp target_entities(_game, _setup, _board, _selected, _move), do: []

  defp action_pawn({:assign, _i, ix}), do: ix
  defp action_pawn({:bonus_step, ix}), do: ix
  defp action_pawn({:khadu, _i, ix}), do: ix
  defp action_pawn(_action), do: nil

  defp marker_glow({:khadu, _i, _ix}, _tint), do: @khadu_glow
  defp marker_glow(_action, {r, g, b, _a}), do: {r * 0.6, g * 0.6, b * 0.6}

  defp landing_position(game, board, player, {:track, x}) do
    cell = Board.cell(game.board, player, x)
    BoardMap.position(board, Board.cell_name(cell))
  end

  defp landing_position(game, board, player, :home) do
    {cx, cy, cz} = BoardMap.position(board, "center_home")
    angle = 2.0 * :math.pi() * player / game.num_players

    {cx + @home_ring_radius * :math.sin(angle), cy, cz + @home_ring_radius * :math.cos(angle)}
  end

  @doc """
  The action a `"target_*"` marker entity id encodes, or `:error`.

      iex> Chopaat.Scene.decode_target("target_assign_1_2")
      {:ok, {:assign, 1, 2}}
      iex> Chopaat.Scene.decode_target("target_khadu_0_3")
      {:ok, {:khadu, 0, 3}}
      iex> Chopaat.Scene.decode_target("target_bonus_1")
      {:ok, {:bonus_step, 1}}
      iex> Chopaat.Scene.decode_target("pawn_0_1")
      :error
  """
  @spec decode_target(String.t()) :: {:ok, Rules.action()} | :error
  def decode_target("target_assign_" <> rest), do: decode_pair(rest, :assign)
  def decode_target("target_khadu_" <> rest), do: decode_pair(rest, :khadu)

  def decode_target("target_bonus_" <> rest) do
    case Integer.parse(rest) do
      {ix, ""} -> {:ok, {:bonus_step, ix}}
      _other -> :error
    end
  end

  def decode_target(_id), do: :error

  defp target_id({:assign, i, ix}), do: "target_assign_#{i}_#{ix}"
  defp target_id({:khadu, i, ix}), do: "target_khadu_#{i}_#{ix}"
  defp target_id({:bonus_step, ix}), do: "target_bonus_#{ix}"

  defp decode_pair(rest, tag) do
    with [a, b] <- String.split(rest, "_"),
         {i, ""} <- Integer.parse(a),
         {ix, ""} <- Integer.parse(b) do
      {:ok, {tag, i, ix}}
    else
      _other -> :error
    end
  end

  @doc """
  World positions for a move's traversed path (`Chopaat.Rules.action_path/2`
  output) — the `Chopaat.Scene.Move` waypoints.
  """
  @spec waypoints(Game.t(), non_neg_integer(), [Pawn.position()]) ::
          [{float(), float(), float()}]
  def waypoints(%Game{} = game, player, path) do
    board = board_asset(game.num_players)
    Enum.map(path, &landing_position(game, board, player, &1))
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
  # game's cosmetic shells performing the tumble) needs an IR surface the
  # plugin does not have: Model.asset is whole-instance (a changed asset
  # is a :replace_entity destroy+recreate, animations included) and
  # entities cannot parent to a named glTF node of another instance —
  # filed as mob_scene3d-kgd. v1 workaround (removal: chopaat-25o): the
  # canonical proxy hulls perform the flight; the real pool shells pose at
  # rest after settle (the visible swap above).
  defp tumbles_entity(board, throw_animation) do
    %Entity{
      id: "tumbles",
      transform: %Transform{position: BoardMap.position(board, "center_home")},
      visible: not is_nil(throw_animation),
      data: %Model{asset: "tumbles.glb", animation: throw_animation}
    }
  end
end
