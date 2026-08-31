"""Chopaat app icon renders (bead chopaat-i8c, partial).

Renders the vermillion pawn from priv/assets/pawn.glb as two 1024x1024
sources for mob.icon:
  assets/icon/icon_source.png       opaque dark-cloth bg, pawn ~80% height
                                    (iOS + Android legacy)
  assets/icon/icon_adaptive_fg.png  transparent bg, pawn ~60% height
                                    (Android adaptive foreground; launcher
                                    masks eat ~1/3 of the canvas, so the
                                    subject stays inside the 66/108 zone)

Run:  blender --background --python assets/scripts/icon.py
"""
import bpy, math, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "icon")
os.makedirs(OUT, exist_ok=True)

VERMILLION = (0.6654, 0.1119, 0.0, 1.0)  # linear, from assets/palettes.json
CLOTH_BG = (0.008, 0.0065, 0.005, 1.0)    # warm near-black, matches board cloth

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def build(scale_frac, transparent):
    reset()
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_EEVEE"
    scn.render.resolution_x = scn.render.resolution_y = 1024
    scn.render.film_transparent = True  # generator flattens onto the cloth hex
    scn.view_settings.view_transform = "Standard"
    bpy.ops.import_scene.gltf(filepath=os.path.join(ROOT, "priv", "assets", "pawn.glb"))
    # Tint the body, keep authored ivory accent.
    for mat in bpy.data.materials:
        if mat.name.startswith("pawn_body"):
            bsdf = mat.node_tree.nodes.get("Principled BSDF")
            if bsdf:
                # The wood-grain texture feeds Base Color; unlink it so the
                # flat tint shows (icon reads better flat at small sizes).
                for link in list(mat.node_tree.links):
                    if link.to_node == bsdf and link.to_socket.name == "Base Color":
                        mat.node_tree.links.remove(link)
                bsdf.inputs["Base Color"].default_value = VERMILLION
    for o in bpy.data.objects:
        if o.type == "MESH":
            o.rotation_euler[2] += math.radians(140)
    objs = [o for o in bpy.data.objects if o.type == "MESH"]
    lo = min(min(o.bound_box[i][2] for i in range(8)) * o.scale[2] + o.location[2] for o in objs)
    hi = max(max(o.bound_box[i][2] for i in range(8)) * o.scale[2] + o.location[2] for o in objs)
    h = hi - lo
    # Camera: orthographic-ish hero 3/4, framed so pawn height = scale_frac of canvas.
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scn.collection.objects.link(cam)
    scn.camera = cam
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = h / scale_frac
    cam.location = (0.14, -0.22, (lo + hi) / 2 + 0.35 * h)
    cam.rotation_euler = (math.radians(72), 0, math.radians(32))
    # Track the pawn center.
    tgt = bpy.data.objects.new("tgt", None)
    scn.collection.objects.link(tgt)
    tgt.location = (0, 0, (lo + hi) / 2)
    con = cam.constraints.new("TRACK_TO")
    con.target = tgt
    # Lights: warm key + cool fill + rim, matching the contact-sheet mood.
    def lamp(name, kind, loc, energy, color=(1, 1, 1)):
        l = bpy.data.lights.new(name, kind)
        l.energy = energy
        l.color = color
        o = bpy.data.objects.new(name, l)
        o.location = loc
        scn.collection.objects.link(o)
        if kind == "SUN":
            o.rotation_euler = (math.radians(50), 0, math.radians(25))
        return o
    lamp("key", "SUN", (0, 0, 1), 1.4, (1.0, 0.95, 0.88))
    lamp("fill", "POINT", (-0.25, -0.3, 0.15), 18, (0.8, 0.85, 1.0))
    lamp("rim", "POINT", (0.15, 0.3, 0.25), 30)
    if False:  # background comes from the generator flatten (#231C15)
        # Dark cloth backdrop: a big shadow-catching plane behind/below.
        bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0, lo - 0.001))
        floor = bpy.context.object
        m = bpy.data.materials.new("bg")
        m.use_nodes = True
        b = m.node_tree.nodes["Principled BSDF"]
        b.inputs["Base Color"].default_value = CLOTH_BG
        b.inputs["Roughness"].default_value = 0.97
        floor.data.materials.append(m)
        scn.world = bpy.data.worlds.new("w")
        scn.world.use_nodes = True
        scn.world.node_tree.nodes["Background"].inputs[0].default_value = CLOTH_BG
    return scn

for name, frac, transparent in [("icon_source.png", 0.80, False), ("icon_adaptive_fg.png", 0.60, True)]:
    scn = build(frac, transparent)
    scn.render.filepath = os.path.join(OUT, name)
    bpy.ops.render.render(write_still=True)
    print("WROTE", scn.render.filepath)
