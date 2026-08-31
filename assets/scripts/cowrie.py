"""cowrie_*.glb — cowrie shell variants (round 2, owner-ruled pool).

Sixteen variants via three methods:
- Method A (procedural): ovoid from a UV sphere, base flatten, lip
  bulges, boolean slit, subdivision.       -> cowrie_a1..a7
- Method B (metaball): overlapping metaballs form the humped dorsal
  body (asymmetry for free), converted to mesh, same base/slit pass.
                                            -> cowrie_b1..b3
- Method C (displacement-textured): method-A body plus a displace
  modifier (clouds / voronoi / wave bands / marble / stucci) for
  surface character.                        -> cowrie_c1..c6

Game pool (owner ruling, bead chopaat-cbr): the a- and c-families
except a2 — {a1, a3, a4, a5, a6, a7, c1, c2, c3, c4, c5, c6}. a2 and
the b-series stay as generator references only. Pool membership +
bounds live in assets/shell_pool.json (built by shell_pool.mjs); pool
members are normalized to a target extent in the 0.023-0.024 m window
because the tumble library bakes against one canonical proxy.

Readability is the point: the aperture (slit) face carries a distinct
dark `cowrie_aperture` material and sits between two lip bulges on a
flattened base, while the dorsal side is a smooth glossy ivory dome —
aperture-up vs aperture-down must be unmistakable from a 45° camera.

Orientation & origin: shell rests dome-up (aperture DOWN) in its
authored pose; length along glTF +X; origin at center of the resting
plane (center-bottom). Aperture-up is a 180° roll about X at runtime.

Budget per variant: 1k-3k tris, 2 materials (shell + aperture).

Run (writes all sixteen):
  blender --background --python assets/scripts/cowrie.py -- priv/assets
"""

import math
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402

MAX_TRIS = 3000
MIN_TRIS = 1000


def shell_materials():
    ivory = common.make_pbr_material(
        "cowrie_shell",
        base_color=(0.87, 0.80, 0.64),
        roughness=0.28,  # slightly glossy ivory
        clearcoat=0.5,
        sheen=0.1,
    )
    aperture = common.make_pbr_material(
        "cowrie_aperture",
        base_color=(0.20, 0.09, 0.07),  # dark warm interior — reads at a glance
        roughness=0.6,
    )
    return ivory, aperture


def shape_base_and_lips(obj, length, base_squash, lip_h, lip_c, lip_s):
    """Flatten the ventral (bottom) side and bulge the lips around the slit.

    base_squash: fraction of the lower hemisphere kept (0.2 = quite flat).
    lip_h: how far the lips bulge downward; lip_c: lip center offset from
    the midline (y); lip_s: lip gaussian width.
    """
    for v in obj.data.vertices:
        x, y, z = v.co
        if z < 0:
            z *= base_squash
            bulge = lip_h * math.exp(-(((abs(y) - lip_c) / lip_s) ** 2))
            bulge *= math.exp(-((x / (0.60 * length)) ** 2))
            z -= bulge
        v.co = (x, y, z)


def cut_slit(obj, length, slit_w, slit_depth, aperture_mat, wavy=0.0):
    """Boolean-subtract a slit box along X on the underside.

    The cutter carries the aperture material; the boolean modifier's
    TRANSFER material mode paints the cut faces with it.
    """
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, 0))
    cutter = bpy.context.active_object
    cutter.name = "slit_cutter"
    cutter.scale = (length * 0.47, slit_w / 2, slit_depth)
    bpy.ops.object.transform_apply(scale=True)
    cutter.location = (0, 0, -slit_depth * 0.55)
    if wavy:
        # a few loop cuts + sinusoidal y offsets -> toothed, organic slit
        sub = cutter.modifiers.new("subdiv", "SUBSURF")
        sub.subdivision_type = "SIMPLE"
        sub.levels = 3
        common.apply_all_modifiers(cutter)
        for v in cutter.data.vertices:
            x, y, z = v.co
            v.co = (x, y + wavy * math.sin(x / length * 34.0), z)
    cutter.data.materials.append(aperture_mat)

    boolean = obj.modifiers.new("slit", "BOOLEAN")
    boolean.operation = "DIFFERENCE"
    boolean.object = cutter
    boolean.solver = "EXACT"
    boolean.material_mode = "TRANSFER"
    common.apply_all_modifiers(obj)
    bpy.data.objects.remove(cutter, do_unlink=True)


def finalize(obj, name, out_dir, target_extent=None):
    """Decimate to budget, normalize bounds, rest on z=0, smooth, export.

    target_extent: if set, uniformly scale the finished shell so its
    largest bounding-box dimension equals this value exactly. Pool
    members are normalized into the ~0.023-0.024 m window because the
    tumble library (chopaat-5gx) bakes motion against one canonical
    proxy — bounds consistency across the pool is a hard requirement.
    Decimation happens first so the collapse can't move the extremes
    afterwards.
    """
    tris = common.decimate_to_budget(obj, MAX_TRIS)

    if target_extent is not None:
        dims = []
        for axis in range(3):
            vals = [v.co[axis] for v in obj.data.vertices]
            dims.append(max(vals) - min(vals))
        s = target_extent / max(dims)
        obj.scale = (s, s, s)
        common.select_only(obj)
        bpy.ops.object.transform_apply(scale=True)

    # translate so the lowest point (lip contact) sits at z=0, centered in x/y
    zs = [v.co.z for v in obj.data.vertices]
    obj.location = (0, 0, -min(zs))
    common.select_only(obj)
    bpy.ops.object.transform_apply(location=True)

    common.shade_smooth(obj, angle_deg=45.0)
    assert MIN_TRIS <= tris <= MAX_TRIS, f"{name} out of budget: {tris} tris"
    obj.name = name
    common.report(name)
    common.export_glb(f"{out_dir}/{name}.glb")


def method_a(name, out_dir, length, width, height, taper, base_squash,
             slit_w, lip_h, wavy=0.0005, displace=None, target_extent=None):
    common.reset_scene()
    ivory, aperture = shell_materials()

    bpy.ops.mesh.primitive_uv_sphere_add(segments=40, ring_count=24, radius=0.5)
    obj = bpy.context.active_object
    obj.scale = (length, width, height)
    bpy.ops.object.transform_apply(scale=True)

    # taper the anterior (+X) end — cowries narrow toward one tip
    for v in obj.data.vertices:
        x, y, z = v.co
        t = 1.0 - taper * max(0.0, x / (length / 2))
        v.co = (x, y * t, z * (1.0 - 0.35 * taper * max(0.0, x / (length / 2))))

    shape_base_and_lips(
        obj, length, base_squash,
        lip_h=lip_h, lip_c=slit_w * 1.6, lip_s=slit_w * 1.2,
    )

    if displace:
        tex_type, size, strength = displace
        tex = bpy.data.textures.new("shell_disp", type=tex_type)
        tex.noise_scale = size
        mod = obj.modifiers.new("disp", "DISPLACE")
        mod.texture = tex
        mod.strength = strength
        mod.mid_level = 0.5
        common.apply_all_modifiers(obj)

    obj.data.materials.append(ivory)
    cut_slit(obj, length, slit_w, slit_depth=height * 0.55, aperture_mat=aperture,
             wavy=wavy)
    finalize(obj, name, out_dir, target_extent=target_extent)


def method_b(name, out_dir, length, width, height, hump_shift, hump_scale,
             base_squash, slit_w, lip_h):
    common.reset_scene()
    ivory, aperture = shell_materials()

    mball = bpy.data.metaballs.new("cowrie_mball")
    mball.resolution = 0.0011
    mobj = bpy.data.objects.new("cowrie_meta", mball)
    bpy.context.scene.collection.objects.link(mobj)

    # a chain of balls along X forms the body; an offset dorsal ball the hump
    r0 = width * 0.55
    for fx, fr in ((-0.30, 0.85), (-0.10, 1.0), (0.12, 0.92), (0.30, 0.7)):
        el = mball.elements.new(type="BALL")
        el.co = (fx * length, 0, 0)
        el.radius = r0 * fr
    hump = mball.elements.new(type="BALL")
    hump.co = (hump_shift * length, 0, height * 0.28)
    hump.radius = r0 * hump_scale

    common.select_only(mobj)
    bpy.ops.object.convert(target="MESH")
    obj = bpy.context.active_object
    # metaball resolution clamps coarse at this physical scale; refine
    sub = obj.modifiers.new("refine", "SUBSURF")
    sub.levels = 2
    common.apply_all_modifiers(obj)

    # normalize proportions to the requested bounding box
    xs = [v.co.x for v in obj.data.vertices]
    ys = [v.co.y for v in obj.data.vertices]
    zs = [v.co.z for v in obj.data.vertices]
    sx = length / (max(xs) - min(xs))
    sy = width / (max(ys) - min(ys))
    sz = height / (max(zs) - min(zs))
    cz = (max(zs) + min(zs)) / 2
    for v in obj.data.vertices:
        x, y, z = v.co
        v.co = (x * sx, y * sy, (z - cz) * sz)

    shape_base_and_lips(
        obj, length, base_squash,
        lip_h=lip_h, lip_c=slit_w * 1.6, lip_s=slit_w * 1.2,
    )
    obj.data.materials.append(ivory)
    cut_slit(obj, length, slit_w, slit_depth=height * 0.55, aperture_mat=aperture,
             wavy=0.0005)
    finalize(obj, name, out_dir)


# Pool members (owner ruling, bead chopaat-cbr: {a1,a3,a4,a5,a6,a7,c1..c6};
# a2 + b-series dropped from the pool but kept as generator references)
# carry a target_extent inside the canonical 0.023-0.024 m window; see
# assets/shell_pool.json (regenerated by shell_pool.mjs) for the manifest
# the tumble/runtime lanes consume.
VARIANTS = [
    # --- Method A: procedural ovoid ---
    ("a1", lambda out: method_a("cowrie_a1", out, length=0.022, width=0.016,
        height=0.012, taper=0.25, base_squash=0.25, slit_w=0.0042, lip_h=0.0026,
        target_extent=0.0233)),
    ("a2", lambda out: method_a("cowrie_a2", out, length=0.026, width=0.014,
        height=0.011, taper=0.35, base_squash=0.22, slit_w=0.0036, lip_h=0.0022)),
    ("a3", lambda out: method_a("cowrie_a3", out, length=0.020, width=0.017,
        height=0.014, taper=0.15, base_squash=0.30, slit_w=0.0046, lip_h=0.0028,
        target_extent=0.0230)),
    ("a4", lambda out: method_a("cowrie_a4", out, length=0.023, width=0.016,
        height=0.012, taper=0.28, base_squash=0.20, slit_w=0.0056, lip_h=0.0032,
        wavy=0.0010, target_extent=0.0236)),
    ("a5", lambda out: method_a("cowrie_a5", out, length=0.021, width=0.018,
        height=0.015, taper=0.12, base_squash=0.32, slit_w=0.0050, lip_h=0.0030,
        target_extent=0.0231)),
    ("a6", lambda out: method_a("cowrie_a6", out, length=0.027, width=0.014,
        height=0.011, taper=0.40, base_squash=0.20, slit_w=0.0034, lip_h=0.0020,
        wavy=0.0012, target_extent=0.0239)),
    ("a7", lambda out: method_a("cowrie_a7", out, length=0.023, width=0.017,
        height=0.013, taper=0.20, base_squash=0.26, slit_w=0.0060, lip_h=0.0034,
        wavy=0.0008, target_extent=0.0235)),
    # --- Method B: metaball body (dropped from the game pool; kept as
    # generator references per the owner ruling) ---
    ("b1", lambda out: method_b("cowrie_b1", out, length=0.022, width=0.016,
        height=0.013, hump_shift=-0.05, hump_scale=0.75, base_squash=0.25,
        slit_w=0.0042, lip_h=0.0026)),
    ("b2", lambda out: method_b("cowrie_b2", out, length=0.024, width=0.015,
        height=0.014, hump_shift=-0.16, hump_scale=0.9, base_squash=0.22,
        slit_w=0.0038, lip_h=0.0024)),
    ("b3", lambda out: method_b("cowrie_b3", out, length=0.027, width=0.014,
        height=0.012, hump_shift=0.05, hump_scale=0.6, base_squash=0.26,
        slit_w=0.0036, lip_h=0.0022)),
    # --- Method C: displacement-textured ---
    ("c1", lambda out: method_a("cowrie_c1", out, length=0.022, width=0.016,
        height=0.012, taper=0.25, base_squash=0.25, slit_w=0.0042, lip_h=0.0026,
        displace=("CLOUDS", 0.006, 0.0018), target_extent=0.0234)),
    ("c2", lambda out: method_a("cowrie_c2", out, length=0.023, width=0.015,
        height=0.013, taper=0.30, base_squash=0.24, slit_w=0.0038, lip_h=0.0024,
        displace=("VORONOI", 0.004, 0.0014), target_extent=0.0237)),
    ("c3", lambda out: method_a("cowrie_c3", out, length=0.024, width=0.016,
        height=0.012, taper=0.22, base_squash=0.24, slit_w=0.0042, lip_h=0.0026,
        displace=("WOOD", 0.008, 0.0022), target_extent=0.0240)),
    ("c4", lambda out: method_a("cowrie_c4", out, length=0.022, width=0.016,
        height=0.013, taper=0.24, base_squash=0.25, slit_w=0.0044, lip_h=0.0028,
        displace=("MARBLE", 0.005, 0.0016), target_extent=0.0232)),
    ("c5", lambda out: method_a("cowrie_c5", out, length=0.024, width=0.015,
        height=0.012, taper=0.32, base_squash=0.22, slit_w=0.0040, lip_h=0.0024,
        displace=("STUCCI", 0.003, 0.0012), target_extent=0.0238)),
    ("c6", lambda out: method_a("cowrie_c6", out, length=0.023, width=0.016,
        height=0.014, taper=0.18, base_squash=0.28, slit_w=0.0048, lip_h=0.0030,
        wavy=0.0010, displace=("CLOUDS", 0.010, 0.0022), target_extent=0.0234)),
]


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    out_dir = argv[0] if argv else "/tmp"
    only = set(argv[1:])  # optional: build a subset, e.g. `-- priv/assets a1 b2`
    for key, fn in VARIANTS:
        if only and key not in only:
            continue
        fn(out_dir)
