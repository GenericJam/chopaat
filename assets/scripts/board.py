"""board.glb / board_6p.glb — Chopaat board, parametric over arm count.

Geometry per RULESET.md (authoritative, from the game owner):
- ARMS equal arms ("tracks") of 3 lanes x 8 rows around a shared center:
  a 3x3 square center for 4 players, a regular hexagonal center for 6
  (arms at 60 degrees).
- Lane 0 (left, shared), lane 1 (middle, private home lane), lane 2
  (right, shared). Lanes are labeled as seen FROM THE CENTER looking
  outward; lane 0 sits on the counter-clockwise side — required so that
  track N's lane 0 top crosses into track N+1's lane 2 top (RULESET.md
  "Movement path" step 3). Tracks are numbered counter-clockwise;
  player-relative track numbering is the rules engine's concern.
- Rows 1 (nearest center) to 8 (outer end).

Marked cells (visually distinct, own named nodes):
- Safe cells: row 5 on lanes 0 and 2 of every arm; row 6 on lane 1
  (the final-stretch threshold safe cell).  -> `board_safe` material.
- Gate cell: lane 2 row 5 (one per arm; it IS that lane-2 safe cell but
  blocks passage, so it gets a distinct marking) -> `board_gate`
  material + a raised rim frame.

Addressing — glTF nodes named for the rules engine:
- `cell_t{track}_l{lane}_r{row}` for all 24*ARMS cells,
- `base_t{track}_seat_{0..3}` for each player's four off-board pawn
  seats (base pad beside their arm's outer end, lane-2 side),
- `base_t{track}` at each pad center, `center_home` at the center.

Budget: < 20k tris, 4 materials.

Run:
  blender --background --python assets/scripts/board.py -- priv/assets/board.glb 4
  blender --background --python assets/scripts/board.py -- priv/assets/board_6p.glb 6
"""

import math
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

SQUARE = 0.05  # m per cell
SLAB_T = 0.008  # slab thickness
TILE_T = 0.003  # tile height above slab
GATE_EXTRA_T = 0.0035  # gate rim rises above its tile
TILE_INSET = 0.003  # gap around each tile (shows cloth base)
BEVEL = 0.0012
ROWS = 8

# material_index stash values (resolved after join)
MAT_TILE, MAT_SAFE, MAT_GATE = 0, 1, 2

SAFE_CELLS = {(0, 5), (2, 5), (1, 6)}  # (lane, row); RULESET.md "Safe cells"
GATE_CELL = (2, 5)  # RULESET.md "Gate"


def arm_angle(track, arms):
    """Outward direction of a track. Tracks numbered counter-clockwise;
    track 0 points toward the viewer (-Y in Blender, +Z in glTF)."""
    return math.radians(-90.0 + track * (360.0 / arms))


def center_radius(arms):
    """Distance from board center to where row 1 begins (flat-side apothem)."""
    if arms == 4:
        return 1.5 * SQUARE  # 3x3 square center
    # regular hexagon whose sides carry the 3-lane-wide (3*SQUARE) arms
    return (3 * SQUARE) * math.sqrt(3) / 2


def local_to_world(track, arms, lx, ly):
    """Rotate arm-local (outward=+X', lane0 side=+Y') into board space."""
    a = arm_angle(track, arms)
    return (lx * math.cos(a) - ly * math.sin(a),
            lx * math.sin(a) + ly * math.cos(a))


def cell_center(track, arms, lane, row):
    lx = center_radius(arms) + (row - 0.5) * SQUARE
    ly = (1 - lane) * SQUARE  # lane 0 -> +Y' (counter-clockwise side)
    return local_to_world(track, arms, lx, ly)


def base_seat_centers(track, arms):
    """Four pawn seats on a pad beside the arm's outer end, lane-2 side."""
    pad_lx = center_radius(arms) + (ROWS - 1.6) * SQUARE
    pad_ly = -(2.85) * SQUARE  # off-board, past lane 2
    seats = []
    for i in range(4):
        dx = (i % 2 - 0.5) * SQUARE * 0.95
        dy = (i // 2 - 0.5) * SQUARE * 0.95
        seats.append(local_to_world(track, arms, pad_lx + dx, pad_ly + dy))
    return local_to_world(track, arms, pad_lx, pad_ly), seats


def add_named_empty(name, location):
    empty = bpy.data.objects.new(name, None)
    empty.empty_display_size = 0.01
    empty.location = Vector(location)
    bpy.context.scene.collection.objects.link(empty)


def add_tile(x, y, size, name, mat_stash, height=TILE_T, z0=SLAB_T):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(x, y, z0 + height / 2))
    tile = bpy.context.active_object
    tile.name = name
    tile.scale = (size / 2 - TILE_INSET / 2, size / 2 - TILE_INSET / 2, height / 2)
    bpy.ops.object.transform_apply(scale=True)
    bevel = tile.modifiers.new("bevel", "BEVEL")
    bevel.width = BEVEL
    bevel.segments = 1
    common.apply_all_modifiers(tile)
    tile["mat_stash"] = mat_stash
    return tile


def add_gate_rim(x, y, size):
    """Raised rim frame marking the gate as a barrier."""
    inner = size / 2 - TILE_INSET / 2
    rim_w = 0.004
    parts = []
    for axis in (0, 1):
        for sign in (-1, 1):
            loc = [x, y, SLAB_T + TILE_T + GATE_EXTRA_T / 2]
            loc[axis] += sign * (inner - rim_w / 2)
            bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
            bar = bpy.context.active_object
            scale = [inner, inner, GATE_EXTRA_T / 2]
            scale[axis] = rim_w / 2
            bar.scale = scale
            bpy.ops.object.transform_apply(scale=True)
            bar["mat_stash"] = MAT_GATE
            parts.append(bar)
    return parts


def add_slab(arms):
    """Cross (or 6-armed star) outline, extruded and beveled."""
    half_w = 1.5 * SQUARE + 0.012  # arm half-width + cloth margin
    r0 = center_radius(arms)
    reach = r0 + ROWS * SQUARE + 0.012
    pts = []
    for track in range(arms):
        a = arm_angle(track, arms)
        # counter-clockwise outline: each arm contributes its right
        # shoulder, two outer corners, then its left shoulder
        for lx, ly in ((r0 * 0.99, -half_w), (reach, -half_w),
                       (reach, half_w), (r0 * 0.99, half_w)):
            x = lx * math.cos(a) - ly * math.sin(a)
            y = lx * math.sin(a) + ly * math.cos(a)
            pts.append((x, y))
    mesh = bpy.data.meshes.new("board_slab")
    n = len(pts)
    verts = [(x, y, 0.0) for x, y in pts] + [(x, y, SLAB_T) for x, y in pts]
    faces = [list(range(n - 1, -1, -1)), list(range(n, 2 * n))]
    faces += [[i, (i + 1) % n, n + (i + 1) % n, n + i] for i in range(n)]
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    slab = common.new_mesh_object("board_slab", mesh)
    bevel = slab.modifiers.new("bevel", "BEVEL")
    bevel.width = 0.003
    bevel.segments = 1
    common.apply_all_modifiers(slab)
    return slab


def build(out_path, arms):
    assert arms in (4, 6), "RULESET.md defines 4- and 6-player boards"
    common.reset_scene()

    cloth = common.make_pbr_material(
        "board_cloth", base_color=(0.36, 0.075, 0.06), roughness=0.9, sheen=0.4
    )
    tile_mat = common.make_pbr_material(
        "board_tile", base_color=(0.87, 0.80, 0.62), roughness=0.75
    )
    safe_mat = common.make_pbr_material(
        "board_safe", base_color=(0.10, 0.22, 0.38), roughness=0.7
    )
    gate_mat = common.make_pbr_material(
        "board_gate", base_color=(0.55, 0.28, 0.05), roughness=0.6
    )
    mats = [tile_mat, safe_mat, gate_mat]

    slab = add_slab(arms)
    slab.data.materials.append(cloth)

    tiles = []
    for track in range(arms):
        for lane in range(3):
            for row in range(1, ROWS + 1):
                x, y = cell_center(track, arms, lane, row)
                if (lane, row) == GATE_CELL:
                    stash = MAT_GATE
                elif (lane, row) in SAFE_CELLS:
                    stash = MAT_SAFE
                else:
                    stash = MAT_TILE
                tiles.append(
                    add_tile(x, y, SQUARE, f"tile_t{track}_l{lane}_r{row}", stash)
                )
                if (lane, row) == GATE_CELL:
                    tiles.extend(add_gate_rim(x, y, SQUARE))
                add_named_empty(f"cell_t{track}_l{lane}_r{row}",
                                (x, y, SLAB_T + TILE_T))

        # base pad: off-board slab + four seat discs
        (px, py), seats = base_seat_centers(track, arms)
        pad = add_tile(px, py, 2.55 * SQUARE, f"base_pad_t{track}", MAT_SAFE,
                       height=TILE_T * 0.8)
        tiles.append(pad)
        add_named_empty(f"base_t{track}", (px, py, SLAB_T + TILE_T * 0.8))
        for s, (sx, sy) in enumerate(seats):
            bpy.ops.mesh.primitive_cylinder_add(
                vertices=20, radius=SQUARE * 0.33, depth=TILE_T * 0.6,
                location=(sx, sy, SLAB_T + TILE_T * 0.8 + TILE_T * 0.3),
            )
            seat = bpy.context.active_object
            seat["mat_stash"] = MAT_TILE
            tiles.append(seat)
            add_named_empty(f"base_t{track}_seat_{s}",
                            (sx, sy, SLAB_T + TILE_T * 0.8 + TILE_T * 0.6))

    # center home: one raised tile (square for 4 arms, hexagon for 6)
    if arms == 4:
        tiles.append(add_tile(0, 0, 3 * SQUARE, "tile_center", MAT_SAFE))
    else:
        r_hex = center_radius(arms) * 2 / math.sqrt(3) - TILE_INSET / 2
        bpy.ops.mesh.primitive_cylinder_add(
            vertices=6, radius=r_hex, depth=TILE_T,
            location=(0, 0, SLAB_T + TILE_T / 2),
        )
        hexagon = bpy.context.active_object
        hexagon.rotation_euler = (0, 0, arm_angle(0, arms) + math.pi / 6)
        bpy.ops.object.transform_apply(rotation=True)
        hexagon["mat_stash"] = MAT_SAFE
        tiles.append(hexagon)
    add_named_empty("center_home", (0, 0, SLAB_T + TILE_T))

    # join tiles into one mesh; resolve stashed material indices
    for t in tiles:
        for m in mats:
            t.data.materials.append(m)
        idx = t["mat_stash"]
        for p in t.data.polygons:
            p.material_index = idx
    bpy.ops.object.select_all(action="DESELECT")
    for t in tiles:
        t.select_set(True)
    bpy.context.view_layer.objects.active = tiles[0]
    bpy.ops.object.join()
    joined = bpy.context.active_object
    joined.name = "board_tiles"
    del joined["mat_stash"]

    tris, mat_count = common.report(f"board_{arms}p")
    assert tris < 20000, f"board over budget: {tris} tris"
    assert mat_count <= 4, f"board over material budget: {mat_count}"
    common.export_glb(out_path)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    out = argv[0] if argv else "/tmp/board.glb"
    arms = int(argv[1]) if len(argv) > 1 else 4
    build(out, arms)
