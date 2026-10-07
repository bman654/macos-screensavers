"""Mesh and material primitives every origami model is built from.

Two rules from the asset contract are enforced here rather than trusted to each model:

- **Flat shading.** `finish()` gives every face its own vertices. A flat-shaded Blender mesh
  exports per-face normals, but anything downstream that regenerates normals by averaging
  (ModelIO does when a file has none) would smooth shared vertices back into a soap
  carving. Unshared vertices make flat the only answer any importer can reach.
- **Flat colour.** `flat_material()` is a bare Principled BSDF with a constant base colour,
  which is exactly what `UsdPreviewSurface` can carry. No procedural node survives the
  export (spikes/001), so none is ever authored.

Colours are written as sRGB hex, the way a paper colour is chosen, and converted to the
linear value Blender's base colour expects.
"""

import os

import bmesh
import bpy
import numpy as np
from mathutils import Vector

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), *[".."] * 4))
# Images a model packages into its .usdz are written here first; the exporter copies them.
TEXTURE_DIR = os.path.join(_REPO, "build", "origami-models", "_textures")


def srgb(hex_colour):
    """'#c8102e' -> linear (r, g, b)."""
    value = hex_colour.lstrip("#")
    channels = [int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(
        c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels
    )


def flat_material(name, colour, roughness=0.85, metallic=0.0, specular=0.35, emission=0.0):
    """One constant-colour material, shared by name across a build.

    `colour` is an sRGB hex string or a linear (r, g, b) tuple. Paper is matte, so the
    default roughness is high; anything that should glint (wire, wet spit) asks for less.
    `emission` > 0 makes the surface glow in its own colour at that strength — it exports as
    `UsdPreviewSurface.emissiveColor`, so a fire stays bright in a shadow.

    Avoid `metallic` for anything that must read at a glance: PBR metal needs a lighting
    environment to reflect, and without one it collapses to dark wet stone
    (next-session.md, traps). A bright, low-roughness dielectric reads as silver anywhere.
    """
    linear = srgb(colour) if isinstance(colour, str) else tuple(colour)
    definition = repr(tuple(round(v, 6) for v in (*linear, roughness, metallic, specular,
                                                  emission)))
    material = bpy.data.materials.get(name)
    if material is not None:
        # Sharing by name is what keeps one draw call per part; sharing a name between two
        # different colours would silently paint the second model in the first one's. Each
        # file is built in a fresh scene, so this only bites where models meet — a review
        # lineup, which is exactly where a wrong colour would be believed.
        if material.get("origami_definition") != definition:
            raise ValueError(f"material {name!r} is already defined differently; "
                             f"give this colour its own name")
        return material
    material = bpy.data.materials.new(name)
    material["origami_definition"] = definition
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*linear, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = specular
    if emission > 0.0:
        bsdf.inputs["Emission Color"].default_value = (*linear, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission
    material.diffuse_color = (*linear, 1.0)
    return material


def textured_material(name, image, roughness=0.9):
    """A base colour read from `image` through the mesh's own UVs.

    Only for a model whose look genuinely is a picture (lined paper); the image is a file
    on disk so the USD exporter can package it into the `.usdz`.
    """
    material = bpy.data.materials.get(name)
    if material is not None:
        return material
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = nodes["Principled BSDF"]
    texture = nodes.new("ShaderNodeTexImage")
    texture.image = image
    texture.interpolation = "Linear"
    uv = nodes.new("ShaderNodeUVMap")
    uv.uv_map = "st"
    links.new(uv.outputs["UV"], texture.inputs["Vector"])
    links.new(texture.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = roughness
    return material


def mesh_object(name, verts, faces, materials, face_materials=None, uvs=None,
                collection=None):
    """Make a mesh object from raw lists and finish it.

    `verts` are (x, y, z); `faces` index into them; `face_materials` gives each face an
    index into `materials` (default 0); `uvs`, if given, is one (u, v) per face corner in
    face order and lands in a layer named `st`, which is what the USD exporter and
    SceneKit both call the primary texture coordinate.
    """
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in verts], [], [tuple(f) for f in faces])
    mesh.validate(clean_customdata=False)
    for material in materials:
        mesh.materials.append(material)
    if face_materials is not None:
        if len(face_materials) != len(mesh.polygons):
            raise ValueError(
                f"{name}: {len(face_materials)} face materials for {len(mesh.polygons)} faces"
            )
        mesh.polygons.foreach_set("material_index", list(face_materials))
    if uvs is not None:
        layer = mesh.uv_layers.new(name="st")
        if len(uvs) != len(mesh.loops):
            raise ValueError(f"{name}: {len(uvs)} uvs for {len(mesh.loops)} face corners")
        layer.data.foreach_set("uv", [c for uv in uvs for c in uv])
    obj = bpy.data.objects.new(name, mesh)
    (collection or bpy.context.scene.collection).objects.link(obj)
    finish(obj)
    return obj


# A polygon whose corners stray further than this fraction of its size from its own plane
# is split into triangles. A warped quad carries one normal for two differently facing
# halves; the importer triangulates it and lights both halves as one, which is exactly the
# smoothing that flat shading exists to avoid.
_PLANAR_TOLERANCE = 1e-4


def _warped(face):
    if len(face.verts) <= 3:
        return False
    centre = face.calc_center_median()
    normal = face.normal
    size = max((v.co - centre).length for v in face.verts)
    return any(abs((v.co - centre).dot(normal)) > _PLANAR_TOLERANCE * size for v in face.verts)


def finish(obj):
    """Split warped polygons, unshare every vertex and mark every face flat. See the
    module docstring."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.normal_update()
    warped = [face for face in bm.faces if _warped(face)]
    if warped:
        bmesh.ops.triangulate(bm, faces=warped)
    bmesh.ops.split_edges(bm, edges=list(bm.edges))
    for face in bm.faces:
        face.smooth = False
    bm.normal_update()
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


def bmesh_object(name, bm, materials, collection=None):
    """Turn a finished bmesh into a flat-shaded object; frees the bmesh."""
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    for material in materials:
        mesh.materials.append(material)
    obj = bpy.data.objects.new(name, mesh)
    (collection or bpy.context.scene.collection).objects.link(obj)
    finish(obj)
    return obj


def join(objects, name):
    """Join meshes into one object named `name`, with every transform applied.

    One mesh per model is one draw call per material, and leaves no part transform for an
    importer to interpret.
    """
    if not objects:
        raise ValueError(f"{name}: nothing to join")
    for obj in objects:
        obj.data.transform(obj.matrix_world)
        obj.matrix_world.identity()
    if len(objects) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for obj in objects:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = objects[0]
        result = bpy.ops.object.join()
        if "FINISHED" not in result:
            raise RuntimeError(f"joining {name} failed: {result}")
    joined = bpy.context.view_layer.objects.active if len(objects) > 1 else objects[0]
    joined.name = name
    joined.data.name = name
    finish(joined)
    return joined


def empty(name, collection=None):
    obj = bpy.data.objects.new(name, None)
    obj.empty_display_type = "PLAIN_AXES"
    (collection or bpy.context.scene.collection).objects.link(obj)
    return obj


def lined_paper_image(name, path, size=(512, 662), rule_every=0.0255, header=0.12,
                      margin=0.15, paper="#f6f3ea", rule="#8fb3d9", margin_rule="#d9737a"):
    """A sheet of US-ruled notebook paper as an image, written to `path`.

    Rules run across the width (constant v), with a wider unruled header at the top
    (v near 1) and a red margin near the left (u = `margin`). Both are deliberately
    asymmetric, so a render shows at a glance which way up and which way round the UVs
    landed. Spacing is in sheet fractions of the height: 0.0255 x 0.279 m = 7.1 mm,
    the real college-ruled pitch.
    """
    width, height = size
    pixels = np.empty((height, width, 4), dtype=np.float32)
    pixels[:, :] = (*srgb(paper), 1.0)
    rule_rgb = np.array((*srgb(rule), 1.0), dtype=np.float32)
    margin_rgb = np.array((*srgb(margin_rule), 1.0), dtype=np.float32)
    thickness = max(1, round(height * 0.0022))
    v = 0.04
    while v < 1.0 - header:
        row = int(round(v * (height - 1)))
        pixels[row:row + thickness, :] = rule_rgb
        v += rule_every
    column = int(round(margin * (width - 1)))
    pixels[:, column:column + thickness] = margin_rgb

    image = bpy.data.images.new(name, width=width, height=height, alpha=False)
    # Blender's image rows run bottom-up, which is also UV's v direction: row 0 is v = 0.
    image.pixels.foreach_set(pixels.ravel())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    return image


def wound_outward(verts, faces):
    """`faces`, each rewound so its normal points out of the closed solid they bound.

    A solid lofted or listed by hand is easy to wind inconsistently, and the export keeps
    whatever winding it is given: a flat normal facing inward is lit from the wrong side.
    """
    bm = bmesh.new()
    corners = [bm.verts.new(v) for v in verts]
    for face in faces:
        bm.faces.new([corners[i] for i in face])
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.verts.index_update()
    wound = [[v.index for v in face.verts] for face in bm.faces]
    bm.free()
    return wound


def polygon_normal(points):
    """Newell's method: robust for any planar polygon, including slivers."""
    normal = Vector((0.0, 0.0, 0.0))
    count = len(points)
    for i in range(count):
        a, b = Vector(points[i]), Vector(points[(i + 1) % count])
        normal.x += (a.y - b.y) * (a.z + b.z)
        normal.y += (a.z - b.z) * (a.x + b.x)
        normal.z += (a.x - b.x) * (a.y + b.y)
    return normal.normalized() if normal.length > 1e-15 else normal
