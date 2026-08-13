"""Does an articulated hierarchy survive Blender -> USD -> SceneKit?

Builds a two-part hinged prop (base + lid whose origin sits on the hinge line) plus an
empty marking a bubble emission point parented to the lid, and exports it. The question
is whether SceneKit receives addressable child nodes with usable pivots, which decides
whether animated decorations can be driven by rotating named nodes.

`--object-scale` reproduces the failure: leaving a non-uniform scale on a parent object
means children live in a stretched space, and rotating them shears instead of turning.
"""

import os
import sys

import bpy
from mathutils import Matrix, Vector

_REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender")]

from saverlib import studio  # noqa: E402

argv = sys.argv[sys.argv.index("--") + 1:]
out = os.path.abspath(argv[0])
use_object_scale = "--object-scale" in argv


def box(name, size, center):
    """A box whose dimensions live in the mesh, not in the object's scale."""
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    obj = bpy.context.active_object
    obj.name = name
    if use_object_scale:
        obj.scale = Vector(size)
        obj.location = Vector(center)
    else:
        obj.data.transform(Matrix.Diagonal(Vector(size).to_4d()))
        obj.data.transform(Matrix.Translation(Vector(center)))
    return obj


studio.reset_scene()

root = bpy.data.objects.new("decor_probe", None)
bpy.context.collection.objects.link(root)

base = box("part_base", (0.20, 0.14, 0.10), (0.0, 0.0, 0.05))
base.parent = root

# The lid's origin is the hinge. Blender writes an object's origin as the prim's
# transform, so a correct origin here is what makes a plain node rotation act as a hinge
# on the other side, with no pivot metadata to carry across.
hinge = Vector((0.0, 0.07, 0.10))
lid = box("part_lid", (0.20, 0.14, 0.03), (0.0, -0.07, 0.015))
lid.location = hinge
lid.parent = base
lid.matrix_parent_inverse = base.matrix_world.inverted()

emitter = bpy.data.objects.new("emit_bubbles", None)
emitter.empty_display_type = "PLAIN_AXES"
bpy.context.collection.objects.link(emitter)
emitter.location = Vector((0.0, -0.04, 0.02))
emitter.parent = lid
emitter.matrix_parent_inverse = lid.matrix_world.inverted()

bpy.ops.wm.usd_export(
    filepath=out,
    export_materials=True,
    evaluation_mode="RENDER",
    generate_preview_surface=True,
)
print(f"[hinge_probe] exported: {out}  (object_scale={use_object_scale})")
