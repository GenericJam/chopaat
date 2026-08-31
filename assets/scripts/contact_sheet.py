"""Contact sheets — headless EEVEE renders for the batched art-direction round.

Outputs (to the directory given after `--`):
- shells_light.png / shells_dark.png: the full game pool (read from
  assets/shell_pool.json — owner-ruled membership), one row per
  variant, three poses per row (dome-up, aperture-up, side profile),
  labeled, 45-degree camera.
- board_light.png / board_dark.png: the (dark) board with pawns in all
  display poses and pool shells in the charkoni, from an elevated
  45-degree game camera, on light and dark table backgrounds.
- pawns_4p.png / pawns_6p.png (round 3, bead chopaat-xix): every
  palette color (assets/palettes.json) x three display poses (upright,
  tipped, upside-down) resting on the dark board — the palette
  legibility + two-tone judgment sheet. colorblind_sim.py derives the
  deuteranopia/protanopia variants from these.
- cloth_closeup.png (round 3, bead chopaat-a02): raking-light close-up
  of the cloth wrinkle normals — the shot that sells it.

Run (after the .glb assets + manifest exist):
  blender --background --python assets/scripts/contact_sheet.py -- \
      assets/contact_sheets priv/assets [shells|board|pawns|cloth ...]
"""

import json
import math
import os
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

_MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "shell_pool.json")
with open(_MANIFEST) as f:
    SHELLS = list(json.load(f)["members"].keys())
POSES = [("dome-up", (0, 0, 0)), ("aperture-up", (math.pi, 0, 0)),
         ("side", (math.pi / 2, 0, 0))]
PITCH_X = 0.055
PITCH_Y = 0.042


def set_eevee():
    render = bpy.context.scene.render
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            render.engine = engine
            return
        except Exception:
            continue
    raise RuntimeError("no EEVEE engine id accepted")


def import_glb(path):
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.context.scene.objects if o not in before]


def add_text(body, location, size, color=(0.1, 0.1, 0.1)):
    curve = bpy.data.curves.new("label", type="FONT")
    curve.body = body
    curve.size = size
    curve.align_x = "CENTER"
    obj = bpy.data.objects.new("label", curve)
    obj.location = location
    bpy.context.scene.collection.objects.link(obj)
    mat = bpy.data.materials.new("label_mat")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = 1.0
    obj.data.materials.append(mat)
    return obj


def add_ground(size, color):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, -0.0005))
    ground = bpy.context.active_object
    ground.name = "ground"
    mat = bpy.data.materials.new("ground_mat")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.95
    ground.data.materials.append(mat)
    return ground


def add_lights_and_world(bg_rgb, strength=1.0):
    world = bpy.data.worlds.new("world")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (*bg_rgb, 1.0)
    bg.inputs["Strength"].default_value = strength

    # Exposure tuned so albedo is judgeable: the round-1 sheet (sun 2.8 +
    # fill 30) over-exposed — a 0.07-linear tile rendered as mid-gray,
    # which made the round-2 dark board unjudgeable. Keep total
    # illuminance near 1 sun-equivalent instead of faking darker albedos.
    sun_data = bpy.data.lights.new("sun", type="SUN")
    sun_data.energy = 2.4
    sun_data.angle = math.radians(12)
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (math.radians(40), math.radians(-15), math.radians(30))
    bpy.context.scene.collection.objects.link(sun)

    area_data = bpy.data.lights.new("fill", type="AREA")
    area_data.energy = 10.0
    area_data.size = 1.5
    fill = bpy.data.objects.new("fill", area_data)
    fill.location = (-0.4, -0.5, 0.7)
    fill.rotation_euler = (math.radians(35), 0, math.radians(-30))
    bpy.context.scene.collection.objects.link(fill)


def settle_on_ground(root, clearance=0.0003):
    """Drop/lift a (possibly rotated) imported object so it rests on z=0."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    min_z = None
    for obj in [root] + list(root.children_recursive):
        if obj.type != "MESH":
            continue
        eval_obj = obj.evaluated_get(depsgraph)
        mesh = eval_obj.to_mesh()
        mw = eval_obj.matrix_world
        for v in mesh.vertices:
            z = (mw @ v.co).z
            min_z = z if min_z is None else min(min_z, z)
        eval_obj.to_mesh_clear()
    if min_z is not None:
        root.location.z += clearance - min_z


def look_at(cam, target):
    direction = Vector(target) - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def render(filepath, res_x, res_y):
    scene = bpy.context.scene
    # AgX (the default) heavily desaturates and Standard clips the
    # near-white shells; Filmic keeps albedo judgeable on these sheets.
    scene.view_settings.view_transform = "Filmic"
    scene.render.resolution_x = res_x
    scene.render.resolution_y = res_y
    scene.render.filepath = filepath
    scene.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(write_still=True)
    print(f"[render] wrote {filepath}")


def build_shell_sheet(assets_dir, out_path, light):
    common.reset_scene()
    set_eevee()

    n_rows = len(SHELLS)
    grid_w = (len(POSES) - 1) * PITCH_X
    grid_h = (n_rows - 1) * PITCH_Y

    for row, name in enumerate(SHELLS):
        y = grid_h / 2 - row * PITCH_Y
        label = add_text(name, (-grid_w / 2 - PITCH_X * 0.75, y - 0.004, 0.0002),
                         0.009,
                         color=(0.1, 0.1, 0.1) if light else (0.85, 0.85, 0.85))
        label.data.align_x = "RIGHT"
        for col, (_, rot) in enumerate(POSES):
            objs = import_glb(f"{assets_dir}/{name}.glb")
            for o in objs:
                if o.parent is None:
                    o.location = (col * PITCH_X - grid_w / 2, y, 0.02)
                    o.rotation_mode = "XYZ"
                    o.rotation_euler = rot
                    bpy.context.view_layer.update()
                    settle_on_ground(o)
    for col, (pose_name, _) in enumerate(POSES):
        add_text(pose_name,
                 (col * PITCH_X - grid_w / 2, grid_h / 2 + PITCH_Y * 0.8, 0.0002),
                 0.009, color=(0.1, 0.1, 0.1) if light else (0.85, 0.85, 0.85))

    add_ground(3.0, (0.66, 0.65, 0.63) if light else (0.10, 0.10, 0.11))
    add_lights_and_world((0.9, 0.9, 0.9) if light else (0.03, 0.03, 0.035),
                         strength=0.55 if light else 0.3)

    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    # foreshortening: the 45-degree view compresses grid Y by cos(45)
    cam_data.ortho_scale = max(
        grid_w + 3.6 * PITCH_X,
        (grid_h + 2.6 * PITCH_Y) * math.cos(math.radians(45)) * 1.12,
    )
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    center = (-0.014, -0.004, 0)
    dist = 1.0
    cam.location = (center[0], center[1] - dist * math.cos(math.radians(45)),
                    dist * math.sin(math.radians(45)))
    look_at(cam, center)

    render(out_path, 1800, 2600)  # 12 pool rows — keep per-row pixel density


def build_board_sheet(assets_dir, out_path, light):
    common.reset_scene()
    set_eevee()

    import_glb(f"{assets_dir}/board.glb")

    # pawns on cells via the board's named empties, in the poses the
    # ruleset displays: upright, TIPPED (final stretch status), and
    # upside-down (reserved for the future mad-pawn) — the owner must be
    # able to tell them apart at a glance from this camera.
    def cell_pos(name):
        obj = bpy.data.objects[name]
        return obj.matrix_world.translation

    poses = [
        ("cell_t0_l0_r5", (0, 0, 0)),                     # upright on a safe cell
        ("cell_t0_l2_r5", (0, 0, math.radians(90))),      # upright at the gate
        ("cell_t3_l1_r6", (0, math.radians(90), 0)),      # tipped on its side
        ("cell_t2_l1_r3", (0, math.radians(180), 0)),     # upside-down (mad-pawn)
        ("base_t1_seat_0", (0, 0, 0)),                    # in a base seat
    ]
    for cell, rot in poses:
        objs = import_glb(f"{assets_dir}/pawn.glb")
        for o in objs:
            if o.parent is None:
                o.location = cell_pos(cell)
                o.rotation_mode = "XYZ"
                o.rotation_euler = rot
                if rot != (0, 0, 0):
                    o.location.z += 0.02
                    bpy.context.view_layer.update()
                    settle_on_ground(o, clearance=cell_pos(cell).z)

    # 7 shells (one full throw) scattered in the charkoni, mixed
    # orientations, drawn from across the game pool (variation is the
    # feature — no two shells alike)
    for i, (dx, dy, flip) in enumerate([
        (-0.03, 0.02, 0), (0.01, 0.03, 1), (0.035, -0.01, 0),
        (-0.01, -0.03, 1), (0.03, 0.035, 0), (-0.04, -0.01, 0),
        (0.0, -0.005, 1),
    ]):
        shell = SHELLS[(i * 2) % len(SHELLS)]
        objs = import_glb(f"{assets_dir}/{shell}.glb")
        for o in objs:
            if o.parent is None:
                o.location = (dx, dy, 0.011)
                o.rotation_mode = "XYZ"
                o.rotation_euler = (math.pi * flip, 0, i * 1.1)

    add_ground(4.0, (0.64, 0.62, 0.59) if light else (0.09, 0.09, 0.10))
    add_lights_and_world((0.9, 0.9, 0.9) if light else (0.03, 0.03, 0.035),
                         strength=0.55 if light else 0.3)

    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 40
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    dist = 1.35
    cam.location = (0, -dist * math.cos(math.radians(45)),
                    dist * math.sin(math.radians(45)))
    look_at(cam, (0, 0.05, 0))

    render(out_path, 2000, 1500)


def _pawn_grain_images():
    """The grain images arrive with the first pawn.glb import (packed);
    key them by base name so per-color materials can re-wire them."""
    imgs = {}
    for img in bpy.data.images:
        base = img.name.split(".")[0]
        if base.startswith("pawn_grain_"):
            imgs[base] = img
    return imgs


def _tinted_pawn_materials(tint_linear, name, grain):
    """Recreate the pawn materials with the player tint on pawn_body —
    the same factor-x-texture semantics as the runtime baseColorFactor
    override (chopaat-xix: the override must scope to pawn_body only;
    pawn_accent keeps its authored ivory)."""

    def build(mat_name, color):
        mat = bpy.data.materials.new(mat_name)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Roughness"].default_value = 0.38
        if "Coat Weight" in bsdf.inputs:
            bsdf.inputs["Coat Weight"].default_value = 0.35
        links = mat.node_tree.links
        tex_b = mat.node_tree.nodes.new("ShaderNodeTexImage")
        tex_b.image = grain["pawn_grain_basecolor"]
        mix = mat.node_tree.nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MULTIPLY"
        mix.inputs["Factor"].default_value = 1.0
        mix.inputs["A"].default_value = (*color, 1.0)
        links.new(tex_b.outputs["Color"], mix.inputs["B"])
        links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
        tex_r = mat.node_tree.nodes.new("ShaderNodeTexImage")
        tex_r.image = grain["pawn_grain_roughness"]
        links.new(tex_r.outputs["Color"], bsdf.inputs["Roughness"])
        return mat

    body = build(f"pawn_body_{name}", tuple(tint_linear[:3]))
    accent = build(f"pawn_accent_{name}", (0.82, 0.72, 0.52))
    return body, accent


PAWN_POSES = [("upright", (0, 0, 0)), ("tipped", (0, math.pi / 2, 0)),
              ("upside-down", (0, math.pi, 0))]


def build_pawn_sheet(assets_dir, out_path, arms):
    """Palette x pose grid resting on the dark board (chopaat-xix)."""
    palettes_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "palettes.json")
    with open(palettes_path) as f:
        palette = json.load(f)[f"players_{arms}"]

    common.reset_scene()
    set_eevee()
    board = "board.glb" if arms == 4 else "board_6p.glb"
    import_glb(f"{assets_dir}/{board}")

    # grid over the track-0 ARM (not the gold center): the ruling is
    # "verified against the dark cloth"
    pitch_x = 0.055
    pitch_y = 0.052
    r0 = 1.5 * 0.05 if arms == 4 else (3 * 0.05) * math.sqrt(3) / 2
    y_top = -(r0 + 0.075)
    grid_w = (len(PAWN_POSES) - 1) * pitch_x
    grid_h = (len(palette) - 1) * pitch_y
    tile_top = 0.0112  # slab + tile height (board.py SLAB_T + TILE_T)

    for row, entry in enumerate(palette):
        y = y_top - row * pitch_y
        label = add_text(entry["name"],
                         (grid_w / 2 + 1.3 * pitch_x, y - 0.005, tile_top + 0.003),
                         0.011, color=(0.85, 0.85, 0.85))
        label.data.align_x = "LEFT"
        grain = None
        for col, (_, rot) in enumerate(PAWN_POSES):
            objs = import_glb(f"{assets_dir}/pawn.glb")
            if grain is None:
                grain = _pawn_grain_images()
                body, accent = _tinted_pawn_materials(
                    entry["linear_rgba"], entry["name"], grain
                )
            for o in objs:
                if o.parent is not None or o.type != "MESH":
                    continue
                o.data = o.data.copy()
                for slot in o.material_slots:
                    if slot.material.name.startswith("pawn_body"):
                        slot.material = body
                    elif slot.material.name.startswith("pawn_accent"):
                        slot.material = accent
                o.location = (col * pitch_x - grid_w / 2, y, tile_top)
                o.rotation_mode = "XYZ"
                o.rotation_euler = rot
                if rot != (0, 0, 0):
                    o.location = (o.location.x, y, tile_top + 0.03)
                    bpy.context.view_layer.update()
                    settle_on_ground(o, clearance=tile_top + 0.0003)
    for col, (pose_name, _) in enumerate(PAWN_POSES):
        add_text(pose_name,
                 (col * pitch_x - grid_w / 2, y_top + pitch_y * 1.45,
                  tile_top + 0.003),
                 0.010, color=(0.85, 0.85, 0.85))

    add_ground(4.0, (0.09, 0.09, 0.10))
    add_lights_and_world((0.03, 0.03, 0.035), strength=0.3)

    cy = y_top - grid_h / 2
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = max(
        grid_w + 4.6 * pitch_x,
        (grid_h + 3.2 * pitch_y) * math.cos(math.radians(45)) * 1.30,
    )
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    dist = 1.2
    cam.location = (0, cy - dist * math.cos(math.radians(45)),
                    dist * math.sin(math.radians(45)))
    look_at(cam, (0, cy, tile_top))

    render(out_path, 2000, 1600 if arms == 4 else 2000)


def build_cloth_closeup(assets_dir, out_path):
    """THE selling shot (chopaat-a02): raking light across the cloth so
    the baked wrinkle normals catch it; arm edge + play field in frame."""
    common.reset_scene()
    set_eevee()
    import_glb(f"{assets_dir}/board.glb")
    add_ground(3.0, (0.09, 0.09, 0.10))

    world = bpy.data.worlds.new("world")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.03, 0.03, 0.035, 1.0)
    bg.inputs["Strength"].default_value = 0.25

    # raking key: ~9 degrees elevation across the arm, warm; faint fill
    sun_data = bpy.data.lights.new("rake", type="SUN")
    sun_data.energy = 3.2
    sun_data.angle = math.radians(2)
    sun_data.color = (1.0, 0.92, 0.8)
    sun = bpy.data.objects.new("rake", sun_data)
    sun.rotation_euler = (math.radians(81), 0, math.radians(115))
    bpy.context.scene.collection.objects.link(sun)
    fill_data = bpy.data.lights.new("fill", type="AREA")
    fill_data.energy = 2.0
    fill_data.size = 1.0
    fill = bpy.data.objects.new("fill", fill_data)
    fill.location = (-0.3, -0.4, 0.5)
    fill.rotation_euler = (math.radians(35), 0, math.radians(-30))
    bpy.context.scene.collection.objects.link(fill)

    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 60
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    # low across the track-0 arm's cloth margin toward the gold center
    cam.location = (0.21, -0.44, 0.085)
    look_at(cam, (0.015, -0.10, 0.008))

    render(out_path, 1800, 1100)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    out_dir = argv[0] if argv else "/tmp"
    assets_dir = argv[1] if len(argv) > 1 else "priv/assets"
    which = set(argv[2:])
    if not which or "shells" in which:
        build_shell_sheet(assets_dir, f"{out_dir}/shells_light.png", light=True)
        build_shell_sheet(assets_dir, f"{out_dir}/shells_dark.png", light=False)
    if not which or "board" in which:
        build_board_sheet(assets_dir, f"{out_dir}/board_light.png", light=True)
        build_board_sheet(assets_dir, f"{out_dir}/board_dark.png", light=False)
    if not which or "pawns" in which:
        build_pawn_sheet(assets_dir, f"{out_dir}/pawns_4p.png", 4)
        build_pawn_sheet(assets_dir, f"{out_dir}/pawns_6p.png", 6)
    if not which or "cloth" in which:
        build_cloth_closeup(assets_dir, f"{out_dir}/cloth_closeup.png")
