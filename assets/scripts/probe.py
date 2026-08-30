"""probe.glb — trivial beveled-cube probe asset for plugin spike / parity lanes.

A 0.1 m cube, lightly beveled, one neutral PBR material, origin at
center-bottom. Deliberately tiny so pipeline problems are never asset
problems.

Run:
  blender --background --python assets/scripts/probe.py -- priv/assets/probe.glb
"""

import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402


def build(out_path):
    common.reset_scene()

    bpy.ops.mesh.primitive_cube_add(size=0.1, location=(0, 0, 0.05))
    cube = bpy.context.active_object
    cube.name = "probe"

    bevel = cube.modifiers.new("bevel", "BEVEL")
    bevel.width = 0.008
    bevel.segments = 1
    common.apply_all_modifiers(cube)

    mat = common.make_pbr_material(
        "probe_neutral", base_color=(0.55, 0.58, 0.62), roughness=0.45
    )
    cube.data.materials.append(mat)

    common.report("probe")
    common.export_glb(out_path)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    build(argv[0] if argv else "/tmp/probe.glb")
