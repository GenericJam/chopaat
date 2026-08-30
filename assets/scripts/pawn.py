"""pawn.glb — turned-pawn game piece (lathe/spin profile + nose).

ONE mesh, ONE neutral near-white material. Per-player color arrives at
runtime via material tint (the scene IR's material_tint) — no baked
color variants.

Directional by design (RULESET.md status poses): a pawn is displayed
TIPPED ON ITS SIDE in the final stretch, and upside-down is reserved
for the future mad-pawn — so the silhouette must not be fully radially
symmetric. The head carries a protruding nose (+X) and the base a
matching notch, so upright / tipped / upside-down all read at a glance
from a 45-degree camera.

Height 0.048 m, base diameter 0.026 m; origin at center-bottom.
Budget: < 2k tris, 1 material.

Run:
  blender --background --python assets/scripts/pawn.py -- priv/assets/pawn.glb
"""

import math
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
import bmesh  # noqa: E402

# Lathe profile as (radius, z) pairs, bottom to top. Classic turned pawn:
# flared base, fillet, tapered stem, collar bead, spherical head, nub.
PROFILE = [
    (0.0000, 0.0000),
    (0.0130, 0.0000),
    (0.0130, 0.0030),
    (0.0115, 0.0055),
    (0.0080, 0.0075),
    (0.0058, 0.0100),
    (0.0046, 0.0140),
    (0.0042, 0.0180),
    (0.0044, 0.0220),
    (0.0052, 0.0250),
    (0.0072, 0.0268),  # collar bead
    (0.0074, 0.0282),
    (0.0058, 0.0295),
    (0.0062, 0.0310),  # head begins
    (0.0080, 0.0330),
    (0.0086, 0.0360),
    (0.0078, 0.0395),
    (0.0055, 0.0430),
    (0.0028, 0.0460),
    (0.0000, 0.0480),
]

SEGMENTS = 24


def build(out_path):
    common.reset_scene()

    bm = bmesh.new()
    profile_verts = [bm.verts.new((r, 0.0, z)) for r, z in PROFILE]
    profile_edges = [
        bm.edges.new((profile_verts[i], profile_verts[i + 1]))
        for i in range(len(profile_verts) - 1)
    ]
    bmesh.ops.spin(
        bm,
        geom=profile_verts + profile_edges,
        cent=(0, 0, 0),
        axis=(0, 0, 1),
        angle=math.tau,
        steps=SEGMENTS,
        use_merge=True,
        use_duplicate=False,
    )
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

    mesh = bpy.data.meshes.new("pawn")
    bm.to_mesh(mesh)
    bm.free()
    pawn = common.new_mesh_object("pawn", mesh)

    # directional nose on the head (+X): tipped vs upside-down must read
    # at a glance (see module docstring)
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=16, ring_count=10, radius=0.0038, location=(0.0082, 0, 0.0355)
    )
    nose = bpy.context.active_object
    nose.scale = (1.5, 0.75, 0.75)  # prow-like, points along +X
    bpy.ops.object.transform_apply(scale=True)

    common.select_only(pawn)
    nose.select_set(True)
    bpy.ops.object.join()
    pawn = bpy.context.active_object
    pawn.name = "pawn"

    common.shade_smooth(pawn, angle_deg=60.0)

    mat = common.make_pbr_material(
        "pawn_neutral",
        base_color=(0.92, 0.92, 0.92),  # near-white: runtime tint multiplies cleanly
        roughness=0.35,
        clearcoat=0.3,
    )
    pawn.data.materials.append(mat)

    tris = common.triangle_count(pawn)
    assert tris < 2000, f"pawn over budget: {tris} tris"
    common.report("pawn")
    common.export_glb(out_path)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    build(argv[0] if argv else "/tmp/pawn.glb")
