"""Tumble ENTRY acceptance renders (bead chopaat-huv) — frame strips
from the ACTUAL game camera proving shells enter from out of frame
(top) and land on the center plate.

For each player count (the two rigs in lib/chopaat/scene.ex rig/1,
mirrored in tumble.py GAME_CAMERAS): import the real board + the
SHIPPED tumbles.glb, swap pool meshes onto the slots exactly as the
runtime does, park the tumbles origin on the board's center_home node,
then render one take per outcome (throw_k{0..7}_v0) at a handful of
entry-to-settle frames. The grid (8 outcomes x N frames) is assembled
into assets/contact_sheets/tumble_entry_{4p,6p}.png — frame 1 must
show NO shells (they are above the frustum); the following columns
show them entering from the top edge. This render IS the acceptance
for the entry half of chopaat-huv (gate.mjs asserts the same thing
analytically for every take).

Run:
  blender --background --python assets/scripts/tumble_entry.py -- \
      assets/contact_sheets priv/assets
"""

import json
import math
import os
import sys
import tempfile

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
import numpy as np  # noqa: E402

FPS = 60
# one game's draw of 7 distinct shells (tumble_preview.py convention)
DRAW = ["cowrie_a1", "cowrie_a3", "cowrie_a5", "cowrie_a7",
        "cowrie_c1", "cowrie_c3", "cowrie_c5"]
# game rigs — lib/chopaat/scene.ex rig/1 (READ-ONLY; keep in sync)
RIGS = {"4p": {"board": "board.glb", "cam_pos": (0.0, 1.05, 0.78)},
        "6p": {"board": "board_6p.glb", "cam_pos": (0.0, 1.20, 0.90)}}
PITCH_DEG = -52.0
FOV_Y_DEG = 45.0
TILE_W, TILE_H = 360, 400  # the game viewport aspect (rig comment)
STRIP_FRAMES = [1, 7, 13, 19, 31, None]  # None -> the take's final frame


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


def add_lights():
    world = bpy.data.worlds.new("world")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.03, 0.03, 0.035, 1.0)
    bg.inputs["Strength"].default_value = 0.35

    sun_data = bpy.data.lights.new("sun", type="SUN")
    sun_data.energy = 2.4
    sun_data.angle = math.radians(12)
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (math.radians(40), math.radians(-15), math.radians(30))
    bpy.context.scene.collection.objects.link(sun)

    fill_data = bpy.data.lights.new("fill", type="AREA")
    fill_data.energy = 10.0
    fill_data.size = 1.5
    fill = bpy.data.objects.new("fill", fill_data)
    fill.location = (-0.4, -0.5, 0.7)
    fill.rotation_euler = (math.radians(35), 0, math.radians(-30))
    bpy.context.scene.collection.objects.link(fill)


def game_camera(cam_pos_gltf):
    """The scene.ex rig camera in Blender coords: glTF (x, y, z) ->
    Blender (x, -z, y); pitch -52 deg about X -> Blender euler x = 38 deg."""
    cam_data = bpy.data.cameras.new("game_cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(FOV_Y_DEG)
    cam_data.clip_start = 0.05
    cam_data.clip_end = 10.0
    cam = bpy.data.objects.new("game_cam", cam_data)
    gx, gy, gz = cam_pos_gltf
    cam.location = (gx, -gz, gy)
    cam.rotation_euler = (math.radians(90.0 + PITCH_DEG), 0, 0)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    return cam


def solo_take(slots, take):
    for obj in slots:
        ad = obj.animation_data
        assert ad, f"{obj.name}: no animation data"
        found = False
        for track in ad.nla_tracks:
            hit = track.name == take or any(s.name == take for s in track.strips)
            track.mute = not hit
            found = found or hit
        assert found, f"{obj.name}: no NLA track for {take}"
        ad.action = None


def load_pixels(path):
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4)


def save_pixels(path, arr):
    h, w = arr.shape[:2]
    img = bpy.data.images.new("strip", w, h, alpha=True)
    img.pixels.foreach_set(arr.astype(np.float32).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    print(f"[strip] wrote {path}")


def build_strip(sheets_dir, assets_dir, label, rig, manifest):
    common.reset_scene()
    set_eevee()
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.resolution_x = TILE_W
    scene.render.resolution_y = TILE_H
    scene.view_settings.view_transform = "Filmic"

    import_glb(os.path.join(assets_dir, rig["board"]))
    add_lights()
    game_camera(rig["cam_pos"])

    imported = import_glb(os.path.join(assets_dir, "tumbles.glb"))
    slots = sorted(
        (o for o in imported if o.name.startswith("shell_")), key=lambda o: o.name
    )
    assert len(slots) == 7, f"expected 7 slot nodes, found {len(slots)}"

    # runtime contract: pool meshes onto the slots, origin at center_home
    for obj, variant in zip(slots, DRAW):
        members = import_glb(os.path.join(assets_dir, f"{variant}.glb"))
        mesh_obj = next(o for o in members if o.type == "MESH")
        obj.data = mesh_obj.data
        for o in members:
            bpy.data.objects.remove(o, do_unlink=True)
    anchor = bpy.data.objects.new("tumbles_anchor", None)
    anchor.location = bpy.data.objects["center_home"].matrix_world.translation
    scene.collection.objects.link(anchor)
    for obj in slots:
        obj.parent = anchor

    takes = [f"throw_k{k}_v0" for k in range(8)]
    frames_dir = tempfile.mkdtemp(prefix="tumble_entry_")
    rows = []
    for take in takes:
        solo_take(slots, take)
        end = int(round(manifest["animations"][take]["duration_s"] * FPS)) + 1
        tiles = []
        for frame in STRIP_FRAMES:
            f = end if frame is None else min(frame, end)
            scene.frame_set(f)
            out = os.path.join(frames_dir, f"{label}_{take}_f{f}.png")
            scene.render.filepath = out
            bpy.ops.render.render(write_still=True)
            tiles.append(load_pixels(out))
        rows.append(np.concatenate(tiles, axis=1))
    # image row 0 is the BOTTOM: reverse so outcome 0 reads at the top
    grid = np.concatenate(list(reversed(rows)), axis=0)
    save_pixels(os.path.join(sheets_dir, f"tumble_entry_{label}.png"), grid)


def main(sheets_dir, assets_dir):
    manifest_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "tumble_manifest.json")
    with open(manifest_path) as f:
        manifest = json.load(f)
    for label, rig in RIGS.items():
        build_strip(sheets_dir, assets_dir, label, rig, manifest)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    main(argv[0] if argv else "assets/contact_sheets",
         argv[1] if len(argv) > 1 else "priv/assets")
