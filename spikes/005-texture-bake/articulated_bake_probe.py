"""Prove an articulated prop bakes into one shared atlas without being joined.

A hinged model cannot be joined, because its parts have to move independently as named
nodes. This builds the two-part probe from spike 004, bakes both meshes into a single
atlas, and exports — so `HingeProbe.swift` can confirm the hierarchy, the pivot and the
textures all survived together.
"""

import os
import sys
import time

import bpy
from mathutils import Matrix, Vector

REPO = "/Users/brandon/dev/general/macos-screensavers"
sys.path.insert(0, os.path.join(REPO, "tools", "blender"))
from saverlib import studio
from saverlib.bake import bake_atlas_objects

out = "/tmp/articulated_baked.usdz"
textures = "/tmp/articulated_baked_textures"
studio.reset_scene()


def box(name, size, center):
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    obj = bpy.context.active_object
    obj.name = name
    obj.data.transform(Matrix.Diagonal(Vector(size).to_4d()))
    obj.data.transform(Matrix.Translation(Vector(center)))
    return obj


def material(name, dark, bright):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = next(node for node in nodes if node.type == "BSDF_PRINCIPLED")
    tex = nodes.new("ShaderNodeTexNoise")
    tex.inputs["Scale"].default_value = 11.0
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*dark, 1.0)
    ramp.color_ramp.elements[1].color = (*bright, 1.0)
    links.new(tex.outputs["Fac"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.55
    return mat


root = bpy.data.objects.new("decor_probe", None)
bpy.context.collection.objects.link(root)
base = box("part_base", (0.20, 0.14, 0.10), (0.0, 0.0, 0.05))
base.parent = root
base.data.materials.append(material("base_blue", (0.015, 0.03, 0.22), (0.05, 0.35, 0.95)))
hinge = Vector((0.0, 0.07, 0.10))
lid = box("part_lid", (0.20, 0.14, 0.03), (0.0, -0.07, 0.015))
lid.location = hinge
lid.parent = base
lid.matrix_parent_inverse = base.matrix_world.inverted()
lid.data.materials.append(material("lid_gold", (0.25, 0.035, 0.005), (1.0, 0.55, 0.02)))
emitter = bpy.data.objects.new("emit_bubbles", None)
bpy.context.collection.objects.link(emitter)
emitter.location = Vector((0.0, -0.04, 0.02))
emitter.parent = lid
emitter.matrix_parent_inverse = lid.matrix_world.inverted()

started = time.monotonic()
paths = bake_atlas_objects([base, lid], textures, atlas_name="articulated_probe", resolution=512, margin=16)
print(f"[artic_bake_probe] bake seconds: {time.monotonic() - started:.2f}")
for kind, path in paths.items():
    print(f"[artic_bake_probe] {kind}: {path}")

bpy.ops.wm.usd_export(
    filepath=out,
    export_materials=True,
    export_textures_mode="NEW",
    overwrite_textures=True,
    evaluation_mode="RENDER",
    generate_preview_surface=True,
)
print(f"[artic_bake_probe] exported: {out}")
