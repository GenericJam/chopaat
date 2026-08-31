"""Shared helpers for chopaat headless-Blender asset scripts.

Conventions (see assets/scripts/README.md):
- Model in Blender's native Z-up; the glTF exporter converts to
  right-handed Y-up (+Y up, +Z toward viewer, meters).
- Origin at logical center-bottom: geometry sits on Blender z=0,
  centered in x/y.
- Export .glb with embedded buffers, one file per asset.

Tested with Blender 5.2.1 LTS.
"""

import math

import bpy


def reset_scene():
    """Wipe the default scene down to nothing."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    return scene


def make_pbr_material(
    name,
    base_color,
    roughness=0.5,
    metallic=0.0,
    sheen=0.0,
    clearcoat=0.0,
    specular=None,
):
    """Create a simple Principled BSDF material (glTF-exportable PBR).

    specular: optional Specular IOR Level override (0..1, default 0.5).
    Needed for very dark rough surfaces (cloth): at a 45-degree camera
    the default broad specular lobe out-shines a ~0.02 albedo and the
    surface renders mid-gray. Exports via KHR_materials_specular.
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*base_color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    # Sheen / clearcoat input names vary across Blender majors; set if present.
    for key, val in (("Sheen Weight", sheen), ("Coat Weight", clearcoat)):
        if key in bsdf.inputs and val:
            bsdf.inputs[key].default_value = val
    if specular is not None:
        for key in ("Specular IOR Level", "Specular"):
            if key in bsdf.inputs:
                bsdf.inputs[key].default_value = specular
                break
    return mat


def link_object(obj, name=None):
    if name:
        obj.name = name
    if obj.name not in bpy.context.scene.collection.objects:
        bpy.context.scene.collection.objects.link(obj)
    return obj


def new_mesh_object(name, mesh):
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def select_only(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def apply_all_modifiers(obj):
    select_only(obj)
    for mod in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)


def shade_smooth(obj, angle_deg=40.0):
    select_only(obj)
    bpy.ops.object.shade_smooth()
    try:
        bpy.ops.object.shade_auto_smooth(angle=math.radians(angle_deg))
    except Exception:
        # Older API: fall back to plain smooth shading.
        pass


def triangle_count(obj):
    """Triangle count of evaluated (modifiers applied) mesh."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    eval_obj = obj.evaluated_get(depsgraph)
    mesh = eval_obj.to_mesh()
    tris = sum(len(p.vertices) - 2 for p in mesh.polygons)
    eval_obj.to_mesh_clear()
    return tris


def scene_triangle_count():
    return sum(
        triangle_count(o) for o in bpy.context.scene.objects if o.type == "MESH"
    )


def decimate_to_budget(obj, max_tris):
    """Decimate (collapse) obj until under max_tris."""
    tris = triangle_count(obj)
    if tris <= max_tris:
        return tris
    mod = obj.modifiers.new("budget_decimate", "DECIMATE")
    mod.ratio = max_tris / tris * 0.97
    apply_all_modifiers(obj)
    return triangle_count(obj)


def export_glb(filepath, export_tangents=False):
    """Export the whole current scene as a single .glb (embedded buffers, Y-up).

    export_tangents: emit TANGENT attributes — set by assets that ship a
    normal map, so renderers need not synthesize tangent frames."""
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=filepath,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_animations=False,
        export_tangents=export_tangents,
        export_extras=True,
    )
    print(f"[export] wrote {filepath}")


def report(name, extra=""):
    tris = scene_triangle_count()
    mats = len({m for o in bpy.context.scene.objects if o.type == "MESH" for m in o.data.materials if m})
    print(f"[report] {name}: {tris} tris, {mats} materials {extra}")
    return tris, mats
