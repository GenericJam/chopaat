"""Tumble-take previews — headless EEVEE mp4 renders for the batched
art-direction round (bead chopaat-5gx evidence: recordings for
animation, stills prove nothing about motion).

Round-trips the SHIPPED artifact: imports priv/assets/tumbles.glb,
swaps each slot's placeholder proxy mesh for a distinct pool shell
(exactly what the runtime does per game), solos one named animation's
NLA track, and renders the settle on a dark center-plate at the game's
45-degree camera. Writes tumble_<take>.mp4 per requested take.

Blender 5.x removed the FFMPEG movie render format, so frames render
to PNG in a temp dir and the system ffmpeg (brew, pinned in the README
table) assembles the mp4.

Run (defaults to one low, one mid, one high outcome):
  blender --background --python assets/scripts/tumble_preview.py -- \
      assets/contact_sheets priv/assets [throw_k4_v1 ...]
"""

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

FPS = 60
# one game's draw of 7 distinct shells from the 12-member pool
DRAW = ["cowrie_a1", "cowrie_a3", "cowrie_a5", "cowrie_a7",
        "cowrie_c1", "cowrie_c3", "cowrie_c5"]
DEFAULT_TAKES = ["throw_k0_v0", "throw_k4_v0", "throw_k7_v0"]
PLATE = 0.15


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


def build_set():
    """Dark center plate + table, sun/fill per the contact-sheet levels."""
    bpy.ops.mesh.primitive_plane_add(size=1.2, location=(0, 0, -0.003))
    table = bpy.context.active_object
    table.data.materials.append(
        common.make_pbr_material("table", (0.045, 0.04, 0.038), roughness=0.9, specular=0.2)
    )
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, -0.00125))
    plate = bpy.context.active_object
    plate.scale = (PLATE, PLATE, 0.0025)  # size=1 cube: dimension == scale
    bpy.ops.object.transform_apply(scale=True)
    plate.data.materials.append(
        common.make_pbr_material("plate", (0.40, 0.28, 0.09), roughness=0.35, metallic=0.4)
    )

    world = bpy.data.worlds.new("world")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.02, 0.02, 0.025, 1.0)
    bg.inputs["Strength"].default_value = 0.6

    sun_data = bpy.data.lights.new("sun", type="SUN")
    sun_data.energy = 2.4
    sun_data.angle = math.radians(12)
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (math.radians(40), math.radians(-15), math.radians(30))
    bpy.context.scene.collection.objects.link(sun)

    area_data = bpy.data.lights.new("fill", type="AREA")
    area_data.energy = 10.0
    area_data.size = 1.0
    fill = bpy.data.objects.new("fill", area_data)
    fill.location = (-0.25, -0.3, 0.45)
    fill.rotation_euler = (math.radians(35), 0, math.radians(-30))
    bpy.context.scene.collection.objects.link(fill)

    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("cam", cam_data)
    dist = 0.34
    cam.location = Vector((0, -dist * math.cos(math.radians(45)), dist * math.sin(math.radians(45))))
    cam.rotation_euler = (math.radians(45), 0, 0)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam


def solo_take(slots, take):
    ok = 0
    for obj in slots:
        ad = obj.animation_data
        if not ad:
            continue
        found = None
        for track in ad.nla_tracks:
            hit = track.name == take or any(s.name == take for s in track.strips)
            track.mute = not hit
            if hit:
                found = track
        assert found, f"{obj.name}: no NLA track for {take}"
        ad.action = None
        ok += 1
    assert ok == len(slots), f"only {ok}/{len(slots)} slots carry animation data"


def main(sheets_dir, assets_dir, takes):
    manifest_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "tumble_manifest.json")
    with open(manifest_path) as f:
        manifest = json.load(f)

    for take in takes:
        meta = manifest["animations"][take]
        scene = common.reset_scene()
        set_eevee()
        scene.render.fps = FPS
        scene.render.resolution_x = 720
        scene.render.resolution_y = 540
        scene.view_settings.view_transform = "Filmic"  # sheet-proven levels

        build_set()

        imported = import_glb(os.path.join(assets_dir, "tumbles.glb"))
        slots = sorted(
            (o for o in imported if o.name.startswith("shell_")), key=lambda o: o.name
        )
        assert len(slots) == 7, f"expected 7 slot nodes, found {len(slots)}"

        # runtime contract: assign this game's drawn pool meshes to slots
        for obj, variant in zip(slots, DRAW):
            members = import_glb(os.path.join(assets_dir, f"{variant}.glb"))
            mesh_obj = next(o for o in members if o.type == "MESH")
            obj.data = mesh_obj.data
            for o in members:
                bpy.data.objects.remove(o, do_unlink=True)

        solo_take(slots, take)

        scene.frame_start = 1
        scene.frame_end = int(round(meta["duration_s"] * FPS)) + 1
        out = os.path.join(sheets_dir, f"tumble_{take}.mp4")
        frames_dir = tempfile.mkdtemp(prefix="tumble_frames_")
        try:
            scene.render.image_settings.file_format = "PNG"
            scene.render.filepath = os.path.join(frames_dir, "f_")
            bpy.ops.render.render(animation=True)
            subprocess.run(
                ["ffmpeg", "-y", "-framerate", str(FPS),
                 "-pattern_type", "glob", "-i", os.path.join(frames_dir, "f_*.png"),
                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", out],
                check=True, capture_output=True,
            )
        finally:
            shutil.rmtree(frames_dir, ignore_errors=True)
        print(f"[preview] wrote {out} "
              f"({scene.frame_end} frames, outcome {meta['count']})")


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    sheets = argv[0] if argv else "assets/contact_sheets"
    assets = argv[1] if len(argv) > 1 else "priv/assets"
    main(sheets, assets, argv[2:] or DEFAULT_TAKES)
