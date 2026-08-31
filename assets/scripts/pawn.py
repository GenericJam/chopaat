"""pawn.glb — turned-wood chaupar pawn, two-tone (bead chopaat-xix).

OWNER RULING (2026-08-31): pawns must look authentic to traditional
Chopat pieces — two-tone painted turned wood. Reference research is in
decisions/2026-08-31-assets-round3.md: traditional chaupar/pachisi
pawns are lathe-turned "beehive" pieces (squat domed body, turned
collar bead, small dome cap), lacquered in the player color with a
contrasting natural-wood/ivory band — the Channapatna lac-turnery
look (body ~1" tall x 0.75" dia; we keep a slightly taller profile so
the tipped/upside-down status poses read from the game camera).

TWO named materials, both addressable by the runtime override path:
- `pawn_body`   — near-white neutral (runtime baseColorFactor override
                  carries the player color; the wood-grain baseColor
                  texture MULTIPLIES the factor, so grain survives the
                  tint), lacquer clearcoat.
- `pawn_accent` — ivory/natural collar band + tip finial, authored
                  color (must NOT take the player tint — see the
                  chopaat-xix note: today's plugin Material override
                  applies to every material instance of the model;
                  the name-scoped override is the follow-up).

Subtle wood grain rides in two small embedded textures (256x256):
baseColor grain (near-white, multiplies cleanly) and a roughness
grain. Cylindrical UVs (u = angle, v = height).

Directional by design (RULESET.md status poses): tipped-on-side =
final stretch, upside-down = reserved mad-pawn — the head keeps the
protruding +X nose so all three poses read at a glance from a
45-degree camera (the accent band is radially symmetric; the nose is
the direction cue).

Height 0.044 m, base diameter 0.026 m; origin at center-bottom.
Budget: < 3k tris, 2 materials, 2 textures (<= 256 px).

Run:
  blender --background --python assets/scripts/pawn.py -- priv/assets/pawn.glb
"""

import math
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
import bmesh  # noqa: E402
import numpy as np  # noqa: E402

# Lathe profile as (radius, z) pairs, bottom to top. Chaupar beehive
# (see module docstring): flared base with a turned foot ring, squat
# domed body, waist, collar bead (the accent band), short neck, dome
# head, tip finial (accent).
PROFILE = [
    (0.0000, 0.0000),
    (0.0125, 0.0000),
    (0.0130, 0.0016),  # foot ring
    (0.0127, 0.0036),
    (0.0114, 0.0050),
    (0.0104, 0.0058),  # base groove
    (0.0117, 0.0086),  # beehive body begins
    (0.0122, 0.0122),
    (0.0113, 0.0162),
    (0.0094, 0.0202),
    (0.0073, 0.0234),
    (0.0056, 0.0256),
    (0.0049, 0.0272),  # waist
    (0.0064, 0.0284),  # collar bead (ACCENT band)
    (0.0067, 0.0296),
    (0.0059, 0.0310),
    (0.0050, 0.0320),  # neck
    (0.0061, 0.0334),  # head dome
    (0.0071, 0.0354),
    (0.0069, 0.0380),
    (0.0054, 0.0406),
    (0.0032, 0.0428),  # tip finial (ACCENT)
    (0.0000, 0.0440),
]

HEIGHT = PROFILE[-1][1]
SEGMENTS = 28

# Accent zones by height (band = the collar bead, tip = the finial).
ACCENT_BAND = (0.0278, 0.0314)
ACCENT_TIP = 0.0416

TEX = 256


def _grain_fields(rng):
    """Vertical wood-grain streaks (u = around the turning axis, so
    streaks run along v like turned + lacquered wood): smooth 1-D noise
    per column with a slight wobble along v. Returns (base, streak)
    float arrays in [0, 1]."""
    coarse = rng.standard_normal(TEX // 8)
    fine = rng.standard_normal(TEX // 2)

    def smooth1d(src):
        x = np.linspace(0, len(src) - 1, TEX)
        i0 = np.floor(x).astype(int) % len(src)
        i1 = (i0 + 1) % len(src)
        t = x - np.floor(x)
        t = t * t * (3 - 2 * t)
        return src[i0] * (1 - t) + src[i1] * t

    col = 0.7 * smooth1d(coarse) + 0.3 * smooth1d(fine)  # per-u streaks
    wob = 0.15 * smooth1d(rng.standard_normal(TEX // 8))  # per-v drift
    grain = col[None, :] + wob[:, None]
    grain = (grain - grain.min()) / (grain.max() - grain.min())
    mottle = smooth1d(rng.standard_normal(TEX // 16))[:, None] * 0.5 + 0.5
    return grain, mottle


def srgb_encode(linear):
    """Linear -> sRGB-encoded. bpy byte images tagged sRGB store the
    ENCODED values in their float pixel view, so color images must be
    written pre-encoded (Non-Color images are written raw)."""
    linear = np.clip(linear, 0.0, 1.0)
    return np.where(
        linear <= 0.0031308,
        12.92 * linear,
        1.055 * np.power(linear, 1.0 / 2.4) - 0.055,
    )


def _write_image(name, rgba, colorspace):
    """rgba: (TEX, TEX, 4) float array, row 0 = image bottom."""
    img = bpy.data.images.new(name, TEX, TEX, alpha=True)
    img.colorspace_settings.name = colorspace
    img.pixels.foreach_set(rgba.astype(np.float32).ravel())
    img.pack()
    return img


def make_grain_images(seed=7):
    rng = np.random.default_rng(seed)
    grain, mottle = _grain_fields(rng)

    # baseColor grain: near-white with faint warm streaks; MULTIPLIES the
    # runtime baseColorFactor tint, so keep it close to 1.0 (linear).
    base = np.empty((TEX, TEX, 4), dtype=np.float32)
    lum = 0.97 - 0.09 * grain - 0.02 * (1 - mottle)
    base[..., 0] = srgb_encode(lum)
    base[..., 1] = srgb_encode(lum * (1.0 - 0.015 * grain))
    base[..., 2] = srgb_encode(lum * (1.0 - 0.045 * grain))
    base[..., 3] = 1.0
    base_img = _write_image("pawn_grain_basecolor", base, "sRGB")

    # roughness grain: lacquer sheen broken by the turning marks.
    rough = np.empty((TEX, TEX, 4), dtype=np.float32)
    rough[..., :3] = (0.30 + 0.16 * grain + 0.04 * (1 - mottle))[..., None]
    rough[..., 3] = 1.0
    rough_img = _write_image("pawn_grain_roughness", rough, "Non-Color")
    return base_img, rough_img


def make_material(name, base_color, base_img, rough_img):
    mat = common.make_pbr_material(name, base_color=base_color, clearcoat=0.35)
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes["Principled BSDF"]

    tex_b = nodes.new("ShaderNodeTexImage")
    tex_b.image = base_img
    # keep the authored factor: factor x texture == glTF baseColorFactor
    # x baseColorTexture (the exporter folds a Multiply of the flat RGB
    # into the factor)
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.inputs["Factor"].default_value = 1.0
    mix.inputs["A"].default_value = (*base_color, 1.0)
    links.new(tex_b.outputs["Color"], mix.inputs["B"])
    links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])

    tex_r = nodes.new("ShaderNodeTexImage")
    tex_r.image = rough_img
    links.new(tex_r.outputs["Color"], bsdf.inputs["Roughness"])
    return mat


def cylindrical_uv(obj):
    """u = angle around Z (seam-corrected per face), v = z / HEIGHT."""
    mesh = obj.data
    # the joined nose sphere ships its own UV layer — drop everything so
    # ours is the only one (and exports as TEXCOORD_0)
    for layer in list(mesh.uv_layers):
        mesh.uv_layers.remove(layer)
    uv = mesh.uv_layers.new(name="UVMap")
    for poly in mesh.polygons:
        us = []
        for li in poly.loop_indices:
            co = mesh.vertices[mesh.loops[li].vertex_index].co
            us.append(math.atan2(co.y, co.x) / math.tau + 0.5)
        if max(us) - min(us) > 0.5:  # seam face: unwrap across 1.0
            us = [u + 1.0 if u < 0.5 else u for u in us]
        for li, u in zip(poly.loop_indices, us):
            co = mesh.vertices[mesh.loops[li].vertex_index].co
            uv.data[li].uv = (u, co.z / HEIGHT)


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
        segments=16, ring_count=10, radius=0.0036, location=(0.0068, 0, 0.0352)
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
    cylindrical_uv(pawn)

    base_img, rough_img = make_grain_images()
    body = make_material(
        "pawn_body",
        # near-white: the runtime baseColorFactor override replaces this
        # with the player color; grain texture multiplies underneath
        base_color=(0.92, 0.92, 0.92),
        base_img=base_img,
        rough_img=rough_img,
    )
    accent = make_material(
        "pawn_accent",
        base_color=(0.82, 0.72, 0.52),  # natural wood / ivory band
        base_img=base_img,
        rough_img=rough_img,
    )
    pawn.data.materials.append(body)
    pawn.data.materials.append(accent)

    for poly in pawn.data.polygons:
        z = poly.center.z
        band = ACCENT_BAND[0] <= z <= ACCENT_BAND[1]
        # the nose sits in the tip's z-range on +X — keep it body-colored
        tip = z >= ACCENT_TIP and abs(poly.center.x) < 0.005
        poly.material_index = 1 if (band or tip) else 0

    tris = common.triangle_count(pawn)
    assert tris < 3000, f"pawn over budget: {tris} tris"
    common.report("pawn")
    common.export_glb(out_path)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    build(argv[0] if argv else "/tmp/pawn.glb")
