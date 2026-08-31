"""tumbles.glb — the cowrie tumble animation library (bead chopaat-5gx).

Baked rigid-body throws of SEVEN cowrie shells (RULESET.md Gujarat
variation: exactly 7 shells per throw, outcomes 0..7 apertures up).

Owner ruling baked into the design: throws use 7 DISTINCT shell models
drawn per game from the 12-member pool (assets/shell_pool.json), so
motion is baked ONCE against a canonical collision proxy targeting
slot nodes `shell_0`..`shell_6`; the visual mesh per slot is assigned
at runtime per game. Never per-variant animations.

Pipeline (all in this script, headless):
 1. Canonical proxy: convex hull of the shared ovoid cowrie form at
    the pool's canonical extents (dims = pool mean, largest extent
    inside the 0.023-0.024 m window), center-bottom origin, dome-up
    rest — same conventions as every pool member. The script ASSERTS
    the proxy is a fair stand-in (extent in window, per-axis dims
    within the pool min/max envelope) and records the check in the
    manifest.
 2. Per take: drop 7 proxies with randomized positions, impulses and
    spins (kinematic-release launch — Blender inherits velocity from
    the two keyframed kinematic frames) onto a ground plane at the
    board's center-plate scale (3x3 cells of 0.05 m = 0.15 m; board.py
    SQUARE). Simulate at 60 fps. ROUND 3 (bead chopaat-huv, owner
    ruling 2026-08-31): shells ENTER FROM OUT OF FRAME (top) at the
    ACTUAL game camera, both player counts. The sim itself is the
    UNCHANGED approved round-2 throw (drop heights/impulses/damping
    untouched — every honest high-energy variant was piloted and
    rejected: a real 0.7 m drop arrives at ~2-4 m/s and Bullet exposes
    no rolling friction, so shells roll off-plate >95% of attempts,
    while ballistics forbids a slow arrival from a high start). The
    entry is a BAKED PREPENDED SEGMENT built backward from each
    shell's launch state: constant tumble, ENTRY_V_FALL fall easing
    into the exact launch velocity over ENTRY_BRAKE_FRAMES (the splice
    is C1-continuous), walked upward until above the top frustum plane
    of BOTH game cameras (GAME_CAMERAS below) with margin. First-frame
    out-of-frame-ness is asserted per take here AND re-derived from
    the GLB binary by gate.mjs. NOTE: the sim runs on a clone of the
    proxy mesh shifted so the object origin sits at the volume
    centroid — Blender's Bullet integration treats the origin as the
    center of mass, and a center-bottom origin would make every shell
    bottom-heavy. Baked keyframes are re-based to the center-bottom
    frame afterwards (M_bottom = M_centroid @ T(0,0,-h)).
 3. Read back each proxy's final orientation IN-SCRIPT and classify
    aperture-up vs dome-up from the local up axis (authored Blender
    +Z == glTF +Y): world-z of local +Z >= +TOL -> dome-up, <= -TOL
    -> aperture-up, anything in the dead band (resting on its side /
    leaning) is ambiguous and the take is re-rolled with a new seed.
    Classification is asserted, never eyeballed.
 4. A take is ACCEPTED only if: every shell classifies unambiguously,
    the aperture-up count equals the take's target outcome, every
    shell rests inside the center plate, and it settles inside the
    duration band (trimmed to settle + tail, clamped to 1.5-2.5 s).
 5. Bake accepted takes as keyframes on seven nodes shell_0..shell_6
    (one NLA track per take, same track name on all seven objects) and
    export ONE tumbles.glb whose named glTF animations are the tracks:
    `throw_k{count}_v{take}`, >= TAKES_PER_OUTCOME takes per outcome
    0..7. build.sh then keyframe-decimates with `gltf-transform
    resample`.
 6. Write assets/tumble_manifest.json — the runtime contract: per
    animation the outcome count, take, duration, seed and per-slot
    final orientation, plus proxy fairness numbers and re-roll stats.
    gate.mjs cross-checks the manifest against the GLB (names, counts,
    durations, and re-derived final quaternions).

Run:
  blender --background --python assets/scripts/tumble.py -- <repo_root>
"""

import json
import math
import os
import random
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common  # noqa: E402

import bpy  # noqa: E402
from mathutils import Euler, Matrix, Quaternion, Vector  # noqa: E402

FPS = 60
SIM_FRAMES = 168  # 2.8 s ceiling; takes must settle well before this
TAIL_FRAMES = 24  # 0.4 s tail converged onto the final pose (see run_take)
MIN_FRAMES = 91  # 90 intervals @60 = 1.5 s — duration band floor
MAX_FRAMES = 151  # 150 intervals @60 = 2.5 s — duration band ceiling
SHELLS = 7  # RULESET.md: exactly 7 shells per throw
OUTCOMES = range(0, SHELLS + 1)  # 0..7 apertures up
TAKES_PER_OUTCOME = 4
MAX_ATTEMPTS_PER_TAKE = 120

PLATE = 0.15  # m — board center plate (3 x board.py SQUARE=0.05)
PLATE_KEEP = 0.060  # shells must REST with origin inside +/- this (x,y)
UP_TOL = 0.7  # |world-z of local +Z| must exceed this to classify
SETTLE_POS_TOL = 0.0025  # m — max drift from the final rest position

POOL_WINDOW = (0.023, 0.024)  # canonical extent window (shell_pool.json)

# Throw presentation v1 (bead chopaat-huv): shells enter from OUT OF
# FRAME (top) at the actual game camera. Framing copied from
# lib/chopaat/scene.ex rig/1 (READ-ONLY — the app lane owns that file;
# keep in sync). glTF world coords; the runtime places the tumbles
# scene origin at the board's center-plate top surface (center_home,
# glTF y = board.py SLAB_T + TILE_T).
GAME_CAMERAS = {
    "4p": {"position": (0.0, 1.05, 0.78), "pitch_deg": -52.0, "fov_y_deg": 45.0},
    "6p": {"position": (0.0, 1.20, 0.90), "pitch_deg": -52.0, "fov_y_deg": 45.0},
}
CENTER_HOME_Y = 0.011  # m — glTF y of center_home above board origin
ENTRY_TAN_MARGIN = 1.08  # entry start clears the top frustum plane by >= 8%
ENTRY_CLEARANCE = 0.03  # m — clearance below the origin for shell extent
ENTRY_V_FALL = 3.0  # m/s — entry fall speed above the brake window
ENTRY_BRAKE_FRAMES = 8  # frames easing entry speed into the launch speed


def blender_to_world(pos):
    """Blender sim coords -> glTF world (tumbles origin at center_home):
    (x, y, z) -> (x, CENTER_HOME_Y + z, -y)."""
    return (pos[0], CENTER_HOME_Y + pos[2], -pos[1])


def frustum_top_ratio(cam, world):
    """(y_cam / -z_cam, -z_cam) of a glTF world point in camera space.
    Out-of-frame-top iff y_cam > tan(fov_y/2) * -z_cam (for -z_cam > 0)."""
    th = math.radians(cam["pitch_deg"])
    up = (0.0, math.cos(th), math.sin(th))  # R_x(th) @ +Y
    back = (0.0, -math.sin(th), math.cos(th))  # R_x(th) @ +Z
    cx, cy, cz = cam["position"]
    v = (world[0] - cx, world[1] - cy, world[2] - cz)
    y_c = v[1] * up[1] + v[2] * up[2]
    z_c = v[1] * back[1] + v[2] * back[2]
    return y_c, -z_c


def out_of_frame_top(blender_pos, margin=1.0):
    """True iff the point (lowered by ENTRY_CLEARANCE for shell extent)
    is above the top frustum plane of EVERY game camera."""
    wx, wy, wz = blender_to_world(blender_pos)
    world = (wx, wy - ENTRY_CLEARANCE, wz)
    for cam in GAME_CAMERAS.values():
        y_c, depth = frustum_top_ratio(cam, world)
        tan_half = math.tan(math.radians(cam["fov_y_deg"]) / 2)
        if depth > 0 and y_c <= tan_half * depth * margin:
            return False
    return True


REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


# ---------------------------------------------------------------- proxy


def pool_dims():
    """Pool per-axis dims envelope + mean, in Blender axes (x=length,
    y=width, z=height). shell_pool.json records glTF dims [x, y, z] =
    [length, height, width] (glTF is Y-up)."""
    path = os.path.join(REPO, "assets", "shell_pool.json")
    with open(path) as f:
        members = json.load(f)["members"]
    dims = []
    for m in members.values():
        gx, gy, gz = m["dims_m"]
        dims.append((gx, gz, gy))  # glTF (x, up, z) -> Blender (x, y, z-up)
    n = len(dims)
    mean = tuple(sum(d[a] for d in dims) / n for a in range(3))
    lo = tuple(min(d[a] for d in dims) for a in range(3))
    hi = tuple(max(d[a] for d in dims) for a in range(3))
    return mean, lo, hi, n


def build_proxy_geometry(dims):
    """Convex hull of the shared cowrie ovoid at the canonical dims.

    Same form language as cowrie.py method A (ovoid, tapered anterior,
    flattened ventral base with lip bulges) but hulled — the slit is
    concave and contributes nothing to collision. Center-bottom origin,
    dome-up rest, length along +X.

    Returns plain-Python (verts, faces, dims_out) so the geometry
    survives the per-take `common.reset_scene()` factory resets (a
    factory reset wipes every datablock, fake-user or not); scenes
    rebuild the mesh with `from_pydata`.
    """
    import bmesh

    length, width, height = dims
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=16, radius=0.5)
    obj = bpy.context.active_object
    obj.name = "tumble_proxy"
    obj.scale = (length, width, height)
    bpy.ops.object.transform_apply(scale=True)

    taper = 0.24  # mid-pool anterior taper (cowrie.py a/c family)
    base_squash = 0.25
    lip_h = 0.0027
    slit_w = 0.0045
    for v in obj.data.vertices:
        x, y, z = v.co
        t = 1.0 - taper * max(0.0, x / (length / 2))
        y *= t
        z *= 1.0 - 0.35 * taper * max(0.0, x / (length / 2))
        if z < 0:
            z *= base_squash
            bulge = lip_h * math.exp(-(((abs(y) - slit_w * 1.6) / (slit_w * 1.2)) ** 2))
            bulge *= math.exp(-((x / (0.60 * length)) ** 2))
            z -= bulge
        else:
            # small flat crest cap: a perfectly smooth elastic dome rocks
            # dome-down forever in Bullet (contact islands defeat
            # deactivation); real cowries arrest the rock on the rough
            # dorsal surface. Collision-only detail — the visual pool
            # meshes keep their full domes — and the post-hull rescale
            # restores the exact canonical height.
            z = min(z, 0.93 * (height / 2))
        v.co = (x, y, z)

    bm = bmesh.new()
    bm.from_mesh(obj.data)
    res = bmesh.ops.convex_hull(bm, input=bm.verts)
    interior = [e for e in res["geom_interior"] if isinstance(e, bmesh.types.BMVert)]
    unused = [e for e in res["geom_unused"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.delete(bm, geom=interior + unused, context="VERTS")
    bm.to_mesh(obj.data)
    bm.free()

    common.decimate_to_budget(obj, 220)

    # rescale exactly to the canonical dims (hulling/decimation nudges them)
    for axis, target in enumerate(dims):
        vals = [v.co[axis] for v in obj.data.vertices]
        s = target / (max(vals) - min(vals))
        for v in obj.data.vertices:
            co = list(v.co)
            co[axis] *= s
            v.co = co

    # center-bottom origin: centered in x/y, resting plane at z=0
    xs = [v.co.x for v in obj.data.vertices]
    ys = [v.co.y for v in obj.data.vertices]
    zs = [v.co.z for v in obj.data.vertices]
    off = Vector(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, min(zs)))
    for v in obj.data.vertices:
        v.co -= off
    dims_out = (max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))

    verts = [tuple(v.co) for v in obj.data.vertices]
    faces = [tuple(p.vertices) for p in obj.data.polygons]
    return verts, faces, dims_out


def make_proxy_mesh(name, verts, faces, z_offset=0.0):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(x, y, z + z_offset) for x, y, z in verts], [], list(faces))
    mesh.update()
    return mesh


def volume_centroid_z(verts, faces):
    """Height of the volume centroid above the resting plane (z=0),
    via signed tetrahedra against the origin."""
    vol = 0.0
    mz = 0.0
    for face in faces:
        vs = [Vector(verts[i]) for i in face]
        for i in range(1, len(vs) - 1):
            a, b, c = vs[0], vs[i], vs[i + 1]
            v6 = a.dot(b.cross(c))  # 6 * signed tet volume
            vol += v6
            mz += v6 * (a.z + b.z + c.z) / 4.0
    assert abs(vol) > 1e-12, "degenerate proxy hull"
    return mz / vol


def verify_fair_stand_in(dims, lo, hi):
    """Assert the proxy is a fair stand-in for every pool member:
    extent inside the canonical window, per-axis dims inside the pool
    envelope (with epsilon for the envelope edges)."""
    eps = 1e-6
    extent = max(dims)
    assert POOL_WINDOW[0] - eps <= extent <= POOL_WINDOW[1] + eps, (
        f"proxy extent {extent:.6f} outside canonical window {POOL_WINDOW}"
    )
    for axis, name in enumerate("xyz"):
        assert lo[axis] - eps <= dims[axis] <= hi[axis] + eps, (
            f"proxy {name}-dim {dims[axis]:.6f} outside pool envelope "
            f"[{lo[axis]:.6f}, {hi[axis]:.6f}]"
        )
    return {
        "dims_m": [round(d, 6) for d in dims],
        "extent_m": round(extent, 6),
        "pool_window_m": list(POOL_WINDOW),
        "pool_dims_min_m": [round(d, 6) for d in lo],
        "pool_dims_max_m": [round(d, 6) for d in hi],
    }


# ------------------------------------------------------------------ sim


def build_sim_scene(proxy_geo, centroid_z, rng, target_up):
    """Fresh scene: passive ground at plate scale, 7 dynamic proxies
    with randomized start pose + kinematic-release launch (velocity &
    spin inherited from two keyframed frames). target_up[i] biases
    shell i's START face; physics decides the final face."""
    scene = common.reset_scene()
    scene.render.fps = FPS
    scene.frame_start = 1
    scene.frame_end = SIM_FRAMES

    bpy.ops.mesh.primitive_plane_add(size=PLATE * 4)
    ground = bpy.context.active_object
    ground.name = "ground"
    bpy.ops.rigidbody.object_add()
    ground.rigid_body.type = "PASSIVE"
    ground.rigid_body.friction = 0.75
    ground.rigid_body.restitution = 0.02
    # Bullet's default 0.04 m collision margin is LARGER than a 0.023 m
    # shell — at this scale it causes floating contacts and endless
    # micro-jitter (nothing ever settles). Use explicit tiny margins.
    ground.rigid_body.use_margin = True
    ground.rigid_body.collision_margin = 0.0004

    rbw = scene.rigidbody_world
    rbw.substeps_per_frame = 60  # cm-scale bodies need dense substeps
    rbw.solver_iterations = 30
    if hasattr(rbw, "use_split_impulse"):
        rbw.use_split_impulse = True  # kills penetration-correction bounce
    rbw.point_cache.frame_start = 1
    rbw.point_cache.frame_end = SIM_FRAMES

    # sim mesh: origin moved to the volume centroid (Bullet's CoM)
    verts, faces = proxy_geo
    sim_mesh = make_proxy_mesh("sim_proxy", verts, faces, z_offset=-centroid_z)

    shells = []
    placed = []
    for i in range(SHELLS):
        for _ in range(200):
            r = rng.uniform(0.004, 0.032)
            th = rng.uniform(0, math.tau)
            pos = Vector((r * math.cos(th), r * math.sin(th), rng.uniform(0.045, 0.075)))
            if all((pos - p).length > 0.020 for p in placed):
                break
        placed.append(pos)

        obj = bpy.data.objects.new(f"sim_shell_{i}", sim_mesh)
        scene.collection.objects.link(obj)
        obj.rotation_mode = "QUATERNION"

        # start face: dome-up identity, aperture-up = 180deg roll about X
        q = Quaternion((1, 0, 0), math.pi) if target_up[i] else Quaternion()
        jitter = Euler(
            (rng.uniform(-0.35, 0.35), rng.uniform(-0.35, 0.35), rng.uniform(0, math.tau)),
            "XYZ",
        ).to_quaternion()
        q0 = jitter @ q

        vel = Vector((rng.uniform(-0.14, 0.14), rng.uniform(-0.14, 0.14), rng.uniform(-0.7, -0.25)))
        angvel = Vector((rng.uniform(-6, 6), rng.uniform(-6, 6), rng.uniform(-6, 6)))

        common.select_only(obj)
        bpy.ops.rigidbody.object_add()
        rb = obj.rigid_body
        rb.type = "ACTIVE"
        rb.collision_shape = "CONVEX_HULL"
        rb.mass = 0.003  # ~3 g cowrie
        rb.friction = 0.7
        # near-zero restitution + strong damping: dome-down shells rock
        # on the curved hull and Bullet's margin/restitution feed the
        # wobble forever otherwise (measured: +/-14 deg at 2.8 s)
        rb.restitution = 0.04
        rb.linear_damping = 0.15
        rb.angular_damping = 0.45
        rb.use_margin = True
        rb.collision_margin = 0.0004  # see ground margin comment
        # NOTE: deactivation cannot end a take here — the kinematic-launch
        # keyframes make Blender treat the body as animated (re-activated
        # every frame), and dome-contact top-spin has no rolling friction
        # to kill it. Takes end via the settle window + tail convergence
        # in run_take instead. Kept enabled as belt-and-braces.
        rb.use_deactivation = True
        rb.deactivate_linear_velocity = 0.045
        rb.deactivate_angular_velocity = 12.0

        dt = 1.0 / FPS
        dq = Quaternion(angvel.normalized() if angvel.length else (0, 0, 1), angvel.length * dt)
        for frame, kin, loc, quat in (
            (1, True, pos, q0),
            (2, True, pos + vel * dt, dq @ q0),
            (3, False, pos + vel * dt, dq @ q0),
        ):
            scene.frame_set(frame)
            obj.location = loc
            obj.rotation_quaternion = quat
            rb.kinematic = kin
            obj.keyframe_insert("location", frame=frame)
            obj.keyframe_insert("rotation_quaternion", frame=frame)
            rb.keyframe_insert("kinematic", frame=frame)
        shells.append(obj)

    scene.frame_set(1)
    return scene, shells


def entry_from_launch(shell_samples):
    """The out-of-frame entry (chopaat-huv), built BACKWARD from the
    approved sim's launch state: constant tumble (the launch spin),
    ENTRY_V_FALL descent easing into the exact launch velocity over
    ENTRY_BRAKE_FRAMES — so the splice into the sim is C1-continuous —
    walked upward until the shell clears the top frustum plane of both
    game cameras with ENTRY_TAN_MARGIN. Returns frames spawn..pre-launch."""
    dt = 1.0 / FPS
    (p0, q0), (p1, q1) = shell_samples[0], shell_samples[1]
    v0 = (p1 - p0) / dt
    dq_inv = (q1 @ q0.inverted()).inverted()
    frames = []
    p, q = p0.copy(), q0.copy()
    tau = 0
    extra = 2  # frames past the margin so frames 1 AND 2 clear it
    while extra > 0:
        if tau >= ENTRY_BRAKE_FRAMES + 2 and out_of_frame_top(tuple(p), ENTRY_TAN_MARGIN):
            extra -= 1
        tau += 1
        assert tau < 150, f"entry failed to leave frame (at {tuple(p)})"
        t = min(tau / ENTRY_BRAKE_FRAMES, 1.0)
        w = t * t * (3 - 2 * t)  # smoothstep: v == launch v at the splice
        vz = v0.z + w * (-ENTRY_V_FALL - v0.z)
        p = p - Vector((v0.x, v0.y, vz)) * dt
        q = dq_inv @ q
        q.normalize()
        frames.append((p.copy(), q.copy()))
    frames.reverse()
    return frames


def run_take(proxy_geo, centroid_z, seed, target_count):
    """One sim attempt. Returns (samples, aperture_up, end_frame) on
    acceptance, else (None, reason, None)."""
    rng = random.Random(seed)
    target_up = [True] * target_count + [False] * (SHELLS - target_count)
    rng.shuffle(target_up)

    scene, shells = build_sim_scene(proxy_geo, centroid_z, rng, target_up)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    to_bottom = Matrix.Translation((0, 0, -centroid_z))

    samples = [[] for _ in range(SHELLS)]  # per shell: [(loc, quat), ...]
    for frame in range(1, SIM_FRAMES + 1):
        scene.frame_set(frame)
        for i, obj in enumerate(shells):
            m = obj.evaluated_get(depsgraph).matrix_world @ to_bottom
            loc = m.to_translation()
            quat = m.to_quaternion()
            if samples[i] and samples[i][-1][1].dot(quat) < 0:
                quat = -quat  # keep quaternions on one hemisphere
            samples[i].append((loc, quat))

    # Settle = the first frame from which every shell stays put: within
    # SETTLE_POS_TOL of its final position with its up-axis classification
    # stable and beyond tolerance. Bullet never brings the shells to
    # NUMERIC rest here (residual sub-mm / few-deg rocking and top-spin on
    # the dome contact point; Blender exposes no rolling friction, and
    # the animated-kinematic launch keeps bodies ineligible for sleep),
    # so the exported tail [settle, end] is smoothly converged onto the
    # final simulated pose below — bake cleanup bounded by the measured
    # wobble amplitude, not authored motion.
    def up_class(quat):
        up_z = (quat.to_matrix() @ Vector((0, 0, 1))).z
        if up_z >= UP_TOL:
            return "dome"
        if up_z <= -UP_TOL:
            return "aperture"
        return None

    final = [samples[i][SIM_FRAMES - 1] for i in range(SHELLS)]
    final_class = [up_class(q) for _, q in final]
    for i, cls in enumerate(final_class):
        loc, quat = final[i]
        up_z = (quat.to_matrix() @ Vector((0, 0, 1))).z
        if cls is None:
            return None, f"shell {i} ambiguous (up_z {up_z:+.3f})", None
        if abs(loc.x) > PLATE_KEEP or abs(loc.y) > PLATE_KEEP:
            return None, f"shell {i} rests off-plate ({loc.x:+.3f},{loc.y:+.3f})", None

    settle = SIM_FRAMES
    for f in range(SIM_FRAMES - 1, 0, -1):
        stable = all(
            (samples[i][f - 1][0] - final[i][0]).length <= SETTLE_POS_TOL
            and up_class(samples[i][f - 1][1]) == final_class[i]
            for i in range(SHELLS)
        )
        if not stable:
            break
        settle = f

    # out-of-frame entry (chopaat-huv): built per shell, padded to a
    # common length with an out-of-frame hold so all slots share one
    # frame range; the whole take (entry + sim) must fit the band
    entries = [entry_from_launch(samples[i]) for i in range(SHELLS)]
    n_entry = max(len(e) for e in entries)
    if n_entry + settle + TAIL_FRAMES > MAX_FRAMES:
        return None, f"not settled inside band (settle frame {settle} + entry {n_entry})", None
    end = max(settle + TAIL_FRAMES, MIN_FRAMES - n_entry)

    # converge the tail onto the final pose = the simulated pose at `end`
    out = []
    for i in range(SHELLS):
        seq = [(loc.copy(), quat.copy()) for loc, quat in samples[i][:end]]
        hold_loc, hold_quat = seq[end - 1]
        for f in range(settle - 1, end):
            t = (f - (settle - 1)) / max(end - settle, 1)
            w = t * t * (3 - 2 * t)  # smoothstep
            loc, quat = seq[f]
            seq[f] = (loc.lerp(hold_loc, w), quat.slerp(hold_quat, w))
        hold = entries[i][0]
        seq = [hold] * (n_entry - len(entries[i])) + entries[i] + seq
        out.append(seq)

    # honest-harness: the first frames of the assembled take must sit
    # above the top frustum plane of BOTH game cameras (gate.mjs
    # re-derives this from the exported GLB binary)
    for i in range(SHELLS):
        for f in (0, 1):
            loc = out[i][f][0]
            assert out_of_frame_top(tuple(loc)), (
                f"shell {i} frame {f + 1} in frame at a game camera: {tuple(loc)}"
            )

    aperture_up = [cls == "aperture" for cls in final_class]
    count = sum(aperture_up)
    if count != target_count:
        return None, f"outcome {count} != target {target_count}", None
    return out, aperture_up, n_entry + end


# --------------------------------------------------------------- export


def action_fcurves(action, obj):
    """New-style (slotted, Blender 4.4+) or legacy fcurve container for
    an action, plus the slot to pin on the NLA strip (None on legacy)."""
    if hasattr(action, "slots"):
        slot = action.slots.new(id_type="OBJECT", name=obj.name)
        layer = action.layers.new("layer")
        strip = layer.strips.new(type="KEYFRAME")
        return strip.channelbag(slot, ensure=True).fcurves, slot
    return action.fcurves, None


def build_export_scene(proxy_geo, takes):
    """Seven slot nodes shell_0..shell_6 (placeholder proxy mesh, swapped
    for a pool shell at runtime), one NLA track per take with the same
    name on all seven objects -> exporter merges each track name into
    one named glTF animation."""
    scene = common.reset_scene()
    scene.render.fps = FPS

    verts, faces = proxy_geo
    proxy_mesh = make_proxy_mesh("tumble_proxy", verts, faces)
    mat = common.make_pbr_material("tumble_proxy", base_color=(0.75, 0.70, 0.60), roughness=0.5)
    proxy_mesh.materials.append(mat)

    slots = []
    for i in range(SHELLS):
        obj = bpy.data.objects.new(f"shell_{i}", proxy_mesh)
        scene.collection.objects.link(obj)
        obj.rotation_mode = "QUATERNION"
        obj.animation_data_create()
        slots.append(obj)

    max_end = 1
    for name, take in takes.items():
        for i, obj in enumerate(slots):
            action = bpy.data.actions.new(f"{name}_shell_{i}")
            fcurves, slot = action_fcurves(action, obj)
            curves = [fcurves.new("location", index=a) for a in range(3)]
            curves += [fcurves.new("rotation_quaternion", index=a) for a in range(4)]
            n = len(take["samples"][i])
            for c in curves:
                c.keyframe_points.add(n)
            for f, (loc, quat) in enumerate(take["samples"][i]):
                vals = (*loc, *quat)
                for c, v in zip(curves, vals):
                    kp = c.keyframe_points[f]
                    kp.co = (f + 1, v)
                    kp.interpolation = "LINEAR"
            for c in curves:
                c.update()
            track = obj.animation_data.nla_tracks.new()
            track.name = name
            strip = track.strips.new(name, 1, action)
            strip.name = name
            if slot is not None:
                strip.action_slot = slot
            max_end = max(max_end, len(take["samples"][i]))

    scene.frame_start = 1
    scene.frame_end = max_end
    return scene


def export_glb(filepath):
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=filepath,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_animations=True,
        export_animation_mode="NLA_TRACKS",
        export_optimize_animation_size=True,
        export_extras=True,
    )
    print(f"[export] wrote {filepath}")


# ----------------------------------------------------------------- main


def main(out_repo):
    mean, lo, hi, n_members = pool_dims()
    common.reset_scene()
    verts, faces, dims = build_proxy_geometry(mean)
    proxy_geo = (verts, faces)
    fairness = verify_fair_stand_in(dims, lo, hi)
    fairness["hull_tris"] = sum(len(f) - 2 for f in faces)
    centroid_z = volume_centroid_z(verts, faces)
    fairness["centroid_z_m"] = round(centroid_z, 6)
    print(f"[proxy] dims {fairness['dims_m']} extent {fairness['extent_m']} "
          f"centroid_z {centroid_z:.5f} ({n_members} pool members)")

    takes = {}
    manifest_anims = {}
    stats = {"sims_total": 0, "rerolls": 0, "reroll_reasons": {}}
    for count in OUTCOMES:
        accepted = 0
        attempt = 0
        while accepted < TAKES_PER_OUTCOME:
            assert attempt < MAX_ATTEMPTS_PER_TAKE * TAKES_PER_OUTCOME, (
                f"outcome {count}: exhausted attempts ({attempt})"
            )
            seed = count * 100_000 + attempt
            attempt += 1
            stats["sims_total"] += 1
            samples, result, end = run_take(proxy_geo, centroid_z, seed, count)
            if samples is None:
                stats["rerolls"] += 1
                key = result.split(" (")[0]
                stats["reroll_reasons"][key] = stats["reroll_reasons"].get(key, 0) + 1
                print(f"[reroll] k{count} seed {seed}: {result}")
                continue
            name = f"throw_k{count}_v{accepted}"
            takes[name] = {"samples": samples}
            manifest_anims[name] = {
                "count": count,
                "take": accepted,
                "seed": seed,
                "duration_s": round((end - 1) / FPS, 4),
                "aperture_up": result,
            }
            accepted += 1
            print(f"[take] {name} seed {seed} frames {end} "
                  f"up={''.join('1' if u else '0' for u in result)}")

    build_export_scene(proxy_geo, takes)
    out_glb = os.path.join(out_repo, "priv", "assets", "tumbles.glb")
    export_glb(out_glb)

    manifest = {
        "version": 1,
        "file": "priv/assets/tumbles.glb",
        "generator": "assets/scripts/tumble.py",
        "contract": (
            "Runtime: place the tumbles scene with its origin at the board "
            "center-plate top surface, assign each game's 7 drawn pool shell "
            "meshes to slot nodes shell_0..shell_6 (all share the "
            "center-bottom-origin, dome-up-rest convention), play the named "
            "animation for the rolled outcome. aperture_up[i] == true means "
            "slot i ends aperture-up: the node's local +Y (glTF) points "
            "world-DOWN (|dot| >= 0.7); dome-up points world-up. After "
            "settle, scene readback must match aperture_up."
        ),
        "slots": [f"shell_{i}" for i in range(SHELLS)],
        "entry": {
            "style": "out_of_frame_top",
            "cameras": GAME_CAMERAS,
            "center_home_y_m": CENTER_HOME_Y,
            "clearance_m": ENTRY_CLEARANCE,
            "bake_tan_margin": ENTRY_TAN_MARGIN,
            "fall_speed_mps": ENTRY_V_FALL,
            "brake_frames": ENTRY_BRAKE_FRAMES,
        },
        "fps": FPS,
        "duration_band_s": [MIN_FRAMES / FPS, MAX_FRAMES / FPS],
        "up_axis_tolerance": UP_TOL,
        "takes_per_outcome": TAKES_PER_OUTCOME,
        "proxy": fairness,
        "animations": manifest_anims,
        "stats": stats,
    }
    out_manifest = os.path.join(out_repo, "assets", "tumble_manifest.json")
    with open(out_manifest, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"[manifest] wrote {out_manifest} — {len(manifest_anims)} animations, "
          f"{stats['sims_total']} sims, {stats['rerolls']} re-rolls")


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    main(argv[0] if argv else REPO)
