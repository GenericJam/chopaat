"""Contact sheets — headless EEVEE renders for the batched art-direction round.

Outputs (to the directory given after `--`):
- shells_light.png / shells_dark.png: the full game pool (read from
  assets/shell_pool.json — owner-ruled membership), one row per
  variant, three poses per row (dome-up, aperture-up, side profile),
  labeled, 45-degree camera.
- board_light.png / board_dark.png: the (dark) board with pawns in all
  display poses and pool shells in the charkoni, from an elevated
  45-degree game camera, on light and dark table backgrounds.

Run (after the .glb assets + manifest exist):
  blender --background --python assets/scripts/contact_sheet.py -- \
      assets/contact_sheets priv/assets
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
