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

Budget: < 20k tris, 5 materials (cloth, tile, safe, gate, center).

Palette (round 2, owner ruling in bead chopaat-cbr): dark cloth/
tabletop ground; tiles a dark warm taupe that still reads as a grid;
safe = blue, gate = ochre + raised rim (both brightened to hold
contrast on the dark ground); center = subtle brass/gold inlay so
'home' reads at a glance. Ivory shells / near-white pawns pop.

Run:
  blender --background --python assets/scripts/board.py -- priv/assets/board.glb 4
  blender --background --python assets/scripts/board.py -- priv/assets/board_6p.glb 6
"""

import math
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
import numpy as np  # noqa: E402
from mathutils import Vector  # noqa: E402

SQUARE = 0.05  # m per cell
SLAB_T = 0.008  # slab thickness
TILE_T = 0.003  # tile height above slab
GATE_EXTRA_T = 0.0035  # gate rim rises above its tile
TILE_INSET = 0.003  # gap around each tile (shows cloth base)
BEVEL = 0.0012
ROWS = 8

# material_index stash values (resolved after join)
MAT_TILE, MAT_SAFE, MAT_GATE, MAT_CENTER = 0, 1, 2, 3

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


def add_rim(x, y, size, mat_stash, rise=GATE_EXTRA_T):
    """Raised rim frame: gate barrier (ochre) or center inlay (gold)."""
    inner = size / 2 - TILE_INSET / 2
    rim_w = 0.004
    parts = []
    for axis in (0, 1):
        for sign in (-1, 1):
            loc = [x, y, SLAB_T + TILE_T + rise / 2]
            loc[axis] += sign * (inner - rim_w / 2)
            bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
            bar = bpy.context.active_object
            scale = [inner, inner, rise / 2]
            scale[axis] = rim_w / 2
            bar.scale = scale
            bpy.ops.object.transform_apply(scale=True)
            bar["mat_stash"] = mat_stash
            parts.append(bar)
    return parts


def slab_outline(arms):
    """Counter-clockwise outline of the cloth slab (cross / 6-armed star):
    each arm contributes its right shoulder, two outer corners, then its
    left shoulder."""
    half_w = 1.5 * SQUARE + 0.012  # arm half-width + cloth margin
    r0 = center_radius(arms)
    reach = r0 + ROWS * SQUARE + 0.012
    pts = []
    for track in range(arms):
        a = arm_angle(track, arms)
        for lx, ly in ((r0 * 0.99, -half_w), (reach, -half_w),
                       (reach, half_w), (r0 * 0.99, half_w)):
            x = lx * math.cos(a) - ly * math.sin(a)
            y = lx * math.sin(a) + ly * math.cos(a)
            pts.append((x, y))
    return pts


# ------------------------------------------------------------- cloth skin
# Bead chopaat-a02, owner ruling 2026-08-31: the board is cloth — skin it
# to look like cloth; "wrinkles in the cloth would really sell it".
# Approach (decisions/2026-08-31-assets-round3.md): geometry unchanged;
# a baked wrinkle NORMAL MAP does the work, plus a thread-scale woven
# baseColor+roughness tile. The wrinkle height field is a scripted
# sculpt — anisotropic fold ridges + low-frequency billow, amplitude
# masked strong near the outline edges / arm shoulders and gentle under
# the play field (the markings are separate rigid tile meshes, so they
# stay crisply legible by construction; the mask keeps the cloth they
# rest on visually flat). Chosen over a Blender cloth sim for headless
# determinism and direct control of the amplitude constraints.
#
# Textures embed in the .glb. Two UV layers, no extensions:
#   TEXCOORD_0 "UVMap"  — planar 0..1 over the slab bbox (wrinkle normal)
#   TEXCOORD_1 "weave"  — planar * repeat, REPEAT sampler (weave tile)

NORMAL_TEX = 1024
WEAVE_TEX = 256
WEAVE_THREADS = 24  # threads per tile: 2 mm pitch — thread-scale, subtle
WEAVE_TILE_M = 0.048  # world size of one weave tile
WRINKLE_AMP = 0.0068  # m — peak fold height driving the baked normals
EDGE_FALLOFF = 0.035  # m — fold amplitude decay away from the outline
FIELD_FLOOR = 0.28  # residual fold amplitude under the play field
RIDGES = 26


def srgb_encode(linear):
    """Linear -> sRGB-encoded. bpy byte images tagged sRGB hold ENCODED
    values in their float pixel view, so color images are written
    pre-encoded (Non-Color images are written raw)."""
    linear = np.clip(linear, 0.0, 1.0)
    return np.where(
        linear <= 0.0031308,
        12.92 * linear,
        1.055 * np.power(linear, 1.0 / 2.4) - 0.055,
    )


def _write_image(name, rgb, colorspace, size):
    rgba = np.empty((size, size, 4), dtype=np.float32)
    rgba[..., :3] = rgb
    rgba[..., 3] = 1.0
    img = bpy.data.images.new(name, size, size, alpha=True)
    img.colorspace_settings.name = colorspace
    img.pixels.foreach_set(rgba.ravel())
    img.pack()
    return img


def _point_in_poly(px, py, pts):
    inside = np.zeros(px.shape, dtype=bool)
    n = len(pts)
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        cond = (y1 > py) != (y2 > py)
        xint = (x2 - x1) * (py - y1) / ((y2 - y1) + 1e-30) + x1
        inside ^= cond & (px < xint)
    return inside


def _edge_distance(px, py, pts):
    d = np.full(px.shape, np.inf, dtype=np.float32)
    for i in range(len(pts)):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % len(pts)]
        abx, aby = bx - ax, by - ay
        t = np.clip(((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby), 0.0, 1.0)
        d = np.minimum(d, np.hypot(px - ax - t * abx, py - ay - t * aby))
    return d


def _smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def _smooth_noise(rng, n_src, n_out):
    """2-D value noise: random n_src grid, smoothstep-bilinear upsample."""
    src = rng.standard_normal((n_src, n_src)).astype(np.float32)
    x = np.linspace(0, n_src - 1 - 1e-6, n_out, dtype=np.float32)
    i0 = np.floor(x).astype(int)
    t = _smoothstep(x - i0)
    i1 = np.minimum(i0 + 1, n_src - 1)
    rows = src[i0][:, i0] * np.outer(1 - t, 1 - t)
    rows += src[i0][:, i1] * np.outer(1 - t, t)
    rows += src[i1][:, i0] * np.outer(t, 1 - t)
    rows += src[i1][:, i1] * np.outer(t, t)
    return rows


def _play_field_factor(X, Y, arms, soft=0.012):
    """1.0 on the open cloth, FIELD_FLOOR under the play field (arm cell
    rectangles + center), smooth transition."""
    r0 = center_radius(arms)
    play = _smoothstep((r0 * 1.12 - np.hypot(X, Y)) / soft)  # center
    for track in range(arms):
        a = arm_angle(track, arms)
        lx = X * math.cos(a) + Y * math.sin(a)
        ly = -X * math.sin(a) + Y * math.cos(a)
        box = (
            _smoothstep((lx - r0) / soft)
            * _smoothstep((r0 + ROWS * SQUARE - lx) / soft)
            * _smoothstep((1.5 * SQUARE + 0.004 - np.abs(ly)) / soft)
        )
        play = np.maximum(play, box)
    return 1.0 - (1.0 - FIELD_FLOOR) * play


def _scalar_in_poly(x, y, pts):
    inside = False
    n = len(pts)
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / ((y2 - y1) + 1e-30) + x1:
            inside = not inside
    return inside


def cloth_height_field(arms, pts, span):
    """The scripted sculpt: fold ridges + billow, edge/shoulder-weighted.
    Returns (H, inside) on the NORMAL_TEX grid over [-span, span]^2."""
    rng = np.random.default_rng(arms * 101 + 7)
    axis = np.linspace(-span, span, NORMAL_TEX, dtype=np.float32)
    X, Y = np.meshgrid(axis, axis)  # row index -> y (image bottom row = -span)

    inside = _point_in_poly(X, Y, pts)
    edge_d = _edge_distance(X, Y, pts)

    # amplitude mask: strong near edges, boosted at the arm shoulders
    # ("between arms" — the cloth bunches at the crotch), gentle under
    # the play field
    amp = 0.40 + 0.60 * np.exp(-edge_d / EDGE_FALLOFF)
    half_w = 1.5 * SQUARE + 0.012
    r0 = center_radius(arms)
    for track in range(arms):
        a = arm_angle(track, arms)
        for side in (-1, 1):
            cx = r0 * 0.99 * math.cos(a) - side * half_w * math.sin(a)
            cy = r0 * 0.99 * math.sin(a) + side * half_w * math.cos(a)
            amp += 0.40 * np.exp(-(((X - cx) ** 2 + (Y - cy) ** 2) / 0.05**2))
    amp = np.minimum(amp, 1.6) * _play_field_factor(X, Y, arms)

    # fold ridges: anisotropic ripples seeded near the outline
    ridges = np.zeros_like(X)
    accepted = 0
    while accepted < RIDGES:
        cx, cy = rng.uniform(-span, span, 2)
        if not _scalar_in_poly(cx, cy, pts):
            continue
        accepted += 1
        theta = rng.uniform(0, math.tau)
        length = rng.uniform(0.05, 0.17)
        width = rng.uniform(0.009, 0.022)
        h = rng.uniform(0.5, 1.0) * rng.choice((-1.0, 1.0))
        s = (X - cx) * math.cos(theta) + (Y - cy) * math.sin(theta)
        t = -(X - cx) * math.sin(theta) + (Y - cy) * math.cos(theta)
        ridges += h * np.exp(-((t / width) ** 2)) * np.exp(-((s / length) ** 4))

    billow = _smooth_noise(rng, 11, NORMAL_TEX)
    H = WRINKLE_AMP * amp * (0.62 * ridges + 0.55 * billow)
    H *= inside
    return H, inside


def make_cloth_images(arms, span):
    """Bake the wrinkle normal map + the woven baseColor/roughness tile."""
    pts = slab_outline(arms)
    H, inside = cloth_height_field(arms, pts, span)

    step = 2 * span / (NORMAL_TEX - 1)
    gy, gx = np.gradient(H, step)  # np.gradient: (d/drow=d/dy, d/dcol=d/dx)
    inv = 1.0 / np.sqrt(gx * gx + gy * gy + 1.0)
    normal = np.empty((NORMAL_TEX, NORMAL_TEX, 3), dtype=np.float32)
    normal[..., 0] = 0.5 - 0.5 * gx * inv
    normal[..., 1] = 0.5 - 0.5 * gy * inv
    normal[..., 2] = 0.5 + 0.5 * inv
    normal_img = _write_image(f"cloth_wrinkle_normal_{arms}p", normal, "Non-Color", NORMAL_TEX)

    # plain weave tile: alternating warp/weft threads, |sin| profile
    rng = np.random.default_rng(42)
    threads = WEAVE_THREADS
    px = np.arange(WEAVE_TEX, dtype=np.float32)
    u, v = np.meshgrid(px, px)
    fu = u * threads / WEAVE_TEX
    fv = v * threads / WEAVE_TEX
    warp = np.abs(np.sin(math.pi * fu)) ** 0.8  # vertical threads
    weft = np.abs(np.sin(math.pi * fv)) ** 0.8  # horizontal threads
    over = (np.floor(fu).astype(int) + np.floor(fv).astype(int)) % 2 == 0
    height = np.where(over, warp, weft)
    # per-thread luminance jitter so the weave doesn't read as a grid
    jit_u = 1.0 + 0.05 * rng.standard_normal(threads)[np.floor(fu).astype(int) % threads]
    jit_v = 1.0 + 0.05 * rng.standard_normal(threads)[np.floor(fv).astype(int) % threads]
    jitter = np.where(over, jit_u, jit_v)

    base = np.empty((WEAVE_TEX, WEAVE_TEX, 3), dtype=np.float32)
    cloth = np.array([0.020, 0.018, 0.016], dtype=np.float32)  # approved dark
    shade = (0.76 + 0.38 * height) * jitter
    for c in range(3):
        base[..., c] = srgb_encode(cloth[c] * shade)
    base_img = _write_image("cloth_weave_basecolor", base, "sRGB", WEAVE_TEX)

    rough = np.clip(0.96 - 0.07 * height, 0.0, 1.0)[..., None]
    rough_img = _write_image("cloth_weave_roughness", rough, "Non-Color", WEAVE_TEX)

    repeat = 2 * span / WEAVE_TILE_M
    return {"normal": normal_img, "base": base_img, "rough": rough_img,
            "repeat": repeat}


def slab_uv_layers(slab, span, repeat):
    """TEXCOORD_0 planar 0..1 (wrinkle normal), TEXCOORD_1 planar*repeat
    (weave tile, REPEAT wrap)."""
    mesh = slab.data
    for layer in list(mesh.uv_layers):
        mesh.uv_layers.remove(layer)
    uv0 = mesh.uv_layers.new(name="UVMap")
    uv1 = mesh.uv_layers.new(name="weave")
    for loop in mesh.loops:
        co = mesh.vertices[loop.vertex_index].co
        u = (co.x + span) / (2 * span)
        v = (co.y + span) / (2 * span)
        uv0.data[loop.index].uv = (u, v)
        uv1.data[loop.index].uv = (u * repeat, v * repeat)


def dress_cloth_material(mat, imgs):
    """Wire the baked images into the cloth Principled BSDF."""
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes["Principled BSDF"]

    def image_node(img, uv_name):
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = img
        uv = nodes.new("ShaderNodeUVMap")
        uv.uv_map = uv_name
        links.new(uv.outputs["UV"], tex.inputs["Vector"])
        return tex

    base = image_node(imgs["base"], "weave")
    links.new(base.outputs["Color"], bsdf.inputs["Base Color"])
    rough = image_node(imgs["rough"], "weave")
    links.new(rough.outputs["Color"], bsdf.inputs["Roughness"])

    norm_tex = image_node(imgs["normal"], "UVMap")
    norm_map = nodes.new("ShaderNodeNormalMap")
    norm_map.uv_map = "UVMap"
    links.new(norm_tex.outputs["Color"], norm_map.inputs["Color"])
    links.new(norm_map.outputs["Normal"], bsdf.inputs["Normal"])


def add_slab(arms):
    """Cloth slab from the outline, extruded and beveled."""
    pts = slab_outline(arms)
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

    # Dark scheme (owner ruling, bead chopaat-cbr): dark cloth/tabletop
    # feel — NOT madder red, NOT dusty rose. Ivory shells and near-white
    # pawns must pop against it; safe (blue) and gate (ochre) markings
    # keep contrast against the dark ground.
    # Albedos are deliberately deep: Filmic + the sheet/game key light
    # lift linear albedo hard (0.165 linear renders as mid-gray), so a
    # "dark table" read needs cloth ~0.02 and tiles ~0.07 linear.
    # NO sheen on the cloth: Blender's glTF exporter collapses any
    # nonzero Sheen Weight into sheenColorFactor [1,1,1] (full white
    # sheen), which re-imports as a grazing-angle lobe that out-shines
    # the 0.02 albedo and renders the slab LIGHTER than the tiles,
    # killing the dark-table read. High roughness + low specular carry
    # the felt look instead.
    cloth = common.make_pbr_material(
        "board_cloth", base_color=(0.020, 0.018, 0.016), roughness=0.92,
        specular=0.05
    )
    tile_mat = common.make_pbr_material(
        "board_tile", base_color=(0.070, 0.063, 0.055), roughness=0.8,
        specular=0.15
    )
    safe_mat = common.make_pbr_material(
        "board_safe", base_color=(0.035, 0.11, 0.30), roughness=0.55
    )
    gate_mat = common.make_pbr_material(
        "board_gate", base_color=(0.45, 0.23, 0.035), roughness=0.5
    )
    # Center 'home' treatment (asset-lane discretion within the dark
    # scheme): a subtle brass/gold inlay — lighter warm inset plate plus
    # a slim raised rim — distinct from safe-blue and gate-ochre so home
    # reads at a glance.
    center_mat = common.make_pbr_material(
        "board_center", base_color=(0.40, 0.28, 0.09), roughness=0.35, metallic=0.4
    )
    mats = [tile_mat, safe_mat, gate_mat, center_mat]

    slab = add_slab(arms)
    slab.data.materials.append(cloth)

    # cloth skin (bead chopaat-a02): woven tile + baked wrinkle normals
    span = center_radius(arms) + ROWS * SQUARE + 0.012 + 0.01
    imgs = make_cloth_images(arms, span)
    slab_uv_layers(slab, span, imgs["repeat"])
    dress_cloth_material(cloth, imgs)
    # normal-mapped mesh ships TANGENTs; MikkTSpace needs tris/quads,
    # and the slab outline caps are n-gons — triangulate first
    slab.modifiers.new("triangulate", "TRIANGULATE")
    common.apply_all_modifiers(slab)

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
                    tiles.extend(add_rim(x, y, SQUARE, MAT_GATE))
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

    # center home: one raised gold-inlay tile (square for 4 arms, hexagon
    # for 6) with a slim raised rim on the 4p square / an inner inlay
    # step on the 6p hexagon — 'home' must read at a glance (owner ruling)
    if arms == 4:
        tiles.append(add_tile(0, 0, 3 * SQUARE, "tile_center", MAT_CENTER))
        tiles.extend(add_rim(0, 0, 3 * SQUARE, MAT_CENTER,
                             rise=GATE_EXTRA_T * 0.7))
    else:
        r_hex = center_radius(arms) * 2 / math.sqrt(3) - TILE_INSET / 2
        for radius, z0, depth in (
            (r_hex, SLAB_T, TILE_T),                       # inlay plate
            (r_hex * 0.9, SLAB_T + TILE_T, GATE_EXTRA_T * 0.7),  # inner step
        ):
            bpy.ops.mesh.primitive_cylinder_add(
                vertices=6, radius=radius, depth=depth,
                location=(0, 0, z0 + depth / 2),
            )
            hexagon = bpy.context.active_object
            hexagon.rotation_euler = (0, 0, arm_angle(0, arms) + math.pi / 6)
            bpy.ops.object.transform_apply(rotation=True)
            hexagon["mat_stash"] = MAT_CENTER
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
    # quiet the exporter's tangent pass (export_tangents is scene-wide)
    joined.modifiers.new("triangulate", "TRIANGULATE")
    common.apply_all_modifiers(joined)

    tris, mat_count = common.report(f"board_{arms}p")
    assert tris < 20000, f"board over budget: {tris} tris"
    assert mat_count <= 5, f"board over material budget: {mat_count}"
    common.export_glb(out_path, export_tangents=True)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    out = argv[0] if argv else "/tmp/board.glb"
    arms = int(argv[1]) if len(argv) > 1 else 4
    build(out, arms)
