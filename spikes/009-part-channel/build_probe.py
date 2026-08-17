#!/usr/bin/env python3
"""Build, bake, and export joined fish probes carrying a vertex color data channel."""

import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

SPIKE_DIR = Path(__file__).resolve().parent
REPO_ROOT = SPIKE_DIR.parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "blender"))

from saverlib.bake import bake_atlas  # noqa: E402
from saverlib.body import Body, BodySpec  # noqa: E402
from saverlib.fins import build_fin  # noqa: E402

ATTRIBUTE_NAME = "displayColor"


def material(name, color, roughness):
    value = bpy.data.materials.new(name)
    value.use_nodes = True
    principled = value.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = (*color, 1.0)
    principled.inputs["Roughness"].default_value = roughness
    return value


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)
    for value in list(bpy.data.materials):
        if value.users == 0:
            bpy.data.materials.remove(value)


def build_fish():
    spec = BodySpec(
        length=0.42,
        width=[(0.0, 0.018), (0.12, 0.058), (0.42, 0.084), (0.72, 0.060), (1.0, 0.018)],
        top=[(0.0, 0.014), (0.15, 0.044), (0.42, 0.064), (0.75, 0.046), (1.0, 0.014)],
        bottom=[(0.0, 0.012), (0.15, 0.038), (0.42, 0.055), (0.75, 0.039), (1.0, 0.012)],
        exponent=2.3,
    )
    body_shape = Body(spec, rings=24, segments=18)
    body = body_shape.build("Body", subsurf=1)
    body.data.materials.append(material("BodyBlue", (0.045, 0.18, 0.52), 0.45))

    def root(u):
        t = 0.34 + 0.18 * u
        return Vector((body_shape.x(t), body_shape.half_width(t) * 0.93, -0.006 + 0.012 * u))

    def outward(_u):
        return Vector((-0.10, 1.0, 0.10))

    fin = build_fin(
        "PectoralLeft",
        root=root,
        out_dir=outward,
        span=[(0.0, 0.105), (0.5, 0.130), (1.0, 0.105)],
        rake=0.045,
        curl=0.008,
        samples_u=9,
        samples_v=7,
        thickness=0.003,
        subsurf=1,
    )
    fin.data.materials.append(material("FinOrange", (0.95, 0.20, 0.025), 0.35))
    return body, fin


def fin_fraction(coordinates):
    ys = [value.y for value in coordinates]
    low, high = min(ys), max(ys)
    width = max(high - low, 1e-9)
    return [(value - low) / width for value in ys]


def add_attribute(obj, domain, is_fin):
    mesh = obj.data
    attribute = mesh.color_attributes.new(
        name=ATTRIBUTE_NAME,
        type="FLOAT_COLOR",
        domain=domain,
    )
    fractions = fin_fraction([vertex.co for vertex in mesh.vertices]) if is_fin else None
    if domain == "POINT":
        for vertex in mesh.vertices:
            g = fractions[vertex.index] if is_fin else 0.0
            attribute.data[vertex.index].color = (1.0 if is_fin else 0.0, g, 0.0, 1.0)
    elif domain == "CORNER":
        for loop in mesh.loops:
            g = fractions[loop.vertex_index] if is_fin else 0.0
            attribute.data[loop.index].color = (1.0 if is_fin else 0.0, g, 0.0, 1.0)
    else:
        raise ValueError(domain)
    mesh.color_attributes.active_color = attribute
    mesh.color_attributes.render_color_index = mesh.color_attributes.find(ATTRIBUTE_NAME)
    mesh.update()


def apply_modifiers(obj):
    # Match build_fish._bake_modifiers: replace the source mesh from the evaluated graph.
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    old_mesh = obj.data
    baked_mesh = bpy.data.meshes.new_from_object(evaluated)
    obj.modifiers.clear()
    obj.data = baked_mesh
    if old_mesh.users == 0:
        bpy.data.meshes.remove(old_mesh)


def attribute_snapshot(obj):
    mesh = obj.data
    attribute = mesh.color_attributes.get(ATTRIBUTE_NAME)
    result = {
        "object": obj.name,
        "vertices": len(mesh.vertices),
        "loops": len(mesh.loops),
        "polygons": len(mesh.polygons),
    }
    if attribute is None:
        result["attribute"] = None
        return result
    values = [tuple(float(channel) for channel in item.color) for item in attribute.data]
    unique = sorted({tuple(round(channel, 6) for channel in value) for value in values})
    nonzero_r = sum(value[0] > 1e-6 for value in values)
    nonzero_g = sum(value[1] > 1e-6 for value in values)
    result["attribute"] = {
        "name": attribute.name,
        "data_type": attribute.data_type,
        "domain": attribute.domain,
        "count": len(values),
        "r_range": [min(value[0] for value in values), max(value[0] for value in values)],
        "g_range": [min(value[1] for value in values), max(value[1] for value in values)],
        "nonzero_r": nonzero_r,
        "nonzero_g": nonzero_g,
        "unique_count": len(unique),
        "first_values": unique[:8],
        "last_values": unique[-8:],
    }
    return result


def join(body, fin, active):
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    fin.select_set(True)
    bpy.context.view_layer.objects.active = active
    result = bpy.ops.object.join()
    if "FINISHED" not in result:
        raise RuntimeError(f"join failed: {result}")
    active.name = "JoinedFish"
    active.data.name = "JoinedFishMesh"
    return active


def export_usdz(obj, path):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    # Match Savers/Aquarium/Models/build_fish.py exactly. export_mesh_colors defaults true.
    result = bpy.ops.wm.usd_export(
        filepath=str(path),
        export_materials=True,
        export_textures_mode="NEW",
        overwrite_textures=True,
        evaluation_mode="RENDER",
        generate_preview_surface=True,
    )
    if "FINISHED" not in result:
        raise RuntimeError(f"USDZ export failed: {result}")


def add_uv_fallback(obj):
    mesh = obj.data
    attribute = mesh.color_attributes[ATTRIBUTE_NAME]
    atlas = mesh.uv_layers.active
    channel = mesh.uv_layers.new(name="st1")
    for loop in mesh.loops:
        color_index = loop.vertex_index if attribute.domain == "POINT" else loop.index
        color = attribute.data[color_index].color
        channel.data[loop.index].uv = (color[0], 1.0 - color[1])
    mesh.uv_layers.active = atlas
    atlas.active_render = True
    mesh.update()
    return {
        "layers": [layer.name for layer in mesh.uv_layers],
        "active": mesh.uv_layers.active.name,
        "render": next(layer.name for layer in mesh.uv_layers if layer.active_render),
        "channel_count": len(channel.data),
        "u_range": [min(item.uv.x for item in channel.data), max(item.uv.x for item in channel.data)],
        "v_range": [min(item.uv.y for item in channel.data), max(item.uv.y for item in channel.data)],
    }


def run_variant(output_root, name, domain, body_has_attribute, active_name, add_uv=False):
    print(f"PROBE_VARIANT_BEGIN {name}")
    reset_scene()
    body, fin = build_fish()
    if body_has_attribute:
        add_attribute(body, domain, is_fin=False)
    add_attribute(fin, domain, is_fin=True)

    report = {
        "variant": name,
        "domain": domain,
        "body_has_attribute_before_join": body_has_attribute,
        "active_object_at_join": active_name,
        "before_modifiers": [attribute_snapshot(body), attribute_snapshot(fin)],
    }
    apply_modifiers(body)
    apply_modifiers(fin)
    report["after_modifiers"] = [attribute_snapshot(body), attribute_snapshot(fin)]

    active = body if active_name == "body" else fin
    joined = join(body, fin, active)
    report["after_join"] = attribute_snapshot(joined)

    variant_dir = output_root / name
    variant_dir.mkdir(parents=True, exist_ok=True)
    if add_uv:
        joined.data.uv_layers.new(name="st1")
        report["uv_layers_before_bake"] = [layer.name for layer in joined.data.uv_layers]
    bake_atlas(
        joined,
        str(variant_dir / "textures"),
        atlas_name=name,
        resolution=256,
        margin=32,
        uv_margin=0.02,
    )
    report["after_bake"] = attribute_snapshot(joined)
    if add_uv:
        report["uv_layers_immediately_after_bake"] = [layer.name for layer in joined.data.uv_layers]
        report["uv_fallback_after_bake"] = add_uv_fallback(joined)

    usdz_path = variant_dir / f"{name}.usdz"
    export_usdz(joined, usdz_path)
    report["usdz"] = str(usdz_path)
    with (variant_dir / "blender-report.json").open("w") as handle:
        json.dump(report, handle, indent=2)
    print("PROBE_REPORT " + json.dumps(report, sort_keys=True))
    print(f"PROBE_VARIANT_END {name}")


def main():
    output_root = SPIKE_DIR / "output"
    output_root.mkdir(parents=True, exist_ok=True)
    variants = [
        ("point_complete", "POINT", True, "body"),
        ("point_missing_active_body", "POINT", False, "body"),
        ("point_missing_active_fin", "POINT", False, "fin"),
        ("corner_complete", "CORNER", True, "body"),
        ("uv_fallback", "POINT", True, "body", True),
    ]
    requested = set(sys.argv[sys.argv.index("--") + 1:]) if "--" in sys.argv else set()
    for variant in variants:
        if not requested or variant[0] in requested:
            run_variant(output_root, *variant)


if __name__ == "__main__":
    main()
