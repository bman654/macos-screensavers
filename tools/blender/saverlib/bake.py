"""Bake procedural materials into a single texture atlas for USD export."""

import os
import re

import bpy


DEFAULT_RESOLUTION = 2048
DEFAULT_MARGIN = 32
DEFAULT_UV_MARGIN = 0.02


def ensure_cycles(device_name=None):
    """Configure Cycles to use a Metal GPU and no CPU fallback.

    The requirement is never to bake on the CPU, not to bake on one particular machine's
    GPU, so any Metal device will do and `device_name` is only an override for a Mac with
    more than one. Pinning a device name here would make shared library code refuse to run
    on every machine but the one it was written on.
    """
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"

    addon = bpy.context.preferences.addons.get("cycles")
    if addon is None:
        try:
            bpy.ops.preferences.addon_enable(module="cycles")
        except Exception as exc:
            raise RuntimeError(f"Cycles could not be enabled: {exc}") from exc
        addon = bpy.context.preferences.addons.get("cycles")
    if addon is None:
        raise RuntimeError("Cycles could not be enabled; texture baking requires Cycles")

    preferences = addon.preferences
    try:
        preferences.compute_device_type = "METAL"
        preferences.get_devices()
    except Exception as exc:
        raise RuntimeError(f"Cycles could not enumerate Metal devices: {exc}") from exc

    devices = list(preferences.devices)
    metal = [device for device in devices if device.type == "METAL"]
    if device_name is not None:
        metal = [device for device in metal if device.name == device_name]
    target = next(iter(metal), None)
    if target is None:
        available = ", ".join(
            f"{device.name} ({device.type})" for device in devices
        ) or "none"
        wanted = f"'{device_name}'" if device_name else "any Metal GPU"
        raise RuntimeError(
            f"Cycles has no usable GPU ({wanted}); available devices: {available}. "
            f"Refusing to bake on CPU."
        )

    for device in devices:
        device.use = device == target
    scene.cycles.device = "GPU"
    scene.cycles.samples = 1
    scene.cycles.use_denoising = False
    return target.name


def bake_atlas(
    obj,
    output_dir,
    *,
    atlas_name=None,
    resolution=DEFAULT_RESOLUTION,
    margin=DEFAULT_MARGIN,
    uv_margin=DEFAULT_UV_MARGIN,
    device_name=None,
):
    """Bake a joined mesh's materials and replace them with one atlas material.

    Returns absolute paths keyed by ``base_color``, ``roughness``, and ``normal``.
    """
    _validate_inputs(obj, resolution, margin, uv_margin)
    ensure_cycles(device_name)

    output_dir = os.path.abspath(output_dir)
    os.makedirs(output_dir, exist_ok=True)
    atlas_name = _safe_name(atlas_name or obj.name)

    _activate(obj)
    _unwrap(obj, uv_margin)

    images = {
        "base_color": _new_image(
            f"{atlas_name}_base_color", resolution, "sRGB"
        ),
        "roughness": _new_image(
            f"{atlas_name}_roughness", resolution, "Non-Color"
        ),
        "normal": _new_image(
            f"{atlas_name}_normal", resolution, "Non-Color"
        ),
    }

    scene = bpy.context.scene
    scene.render.bake.margin = margin
    scene.render.bake.margin_type = "EXTEND"
    scene.render.bake.use_clear = True
    scene.render.bake.use_pass_direct = False
    scene.render.bake.use_pass_indirect = False
    scene.render.bake.use_pass_color = True
    scene.render.bake.normal_space = "TANGENT"

    materials = _source_materials(obj)
    _bake(obj, materials, images["base_color"], "DIFFUSE", margin)
    _bake(obj, materials, images["roughness"], "ROUGHNESS", margin)
    _bake(obj, materials, images["normal"], "NORMAL", margin)

    paths = {}
    for kind, image in images.items():
        path = os.path.join(output_dir, f"{atlas_name}_{kind}.png")
        image.filepath_raw = path
        image.file_format = "PNG"
        image.save()
        paths[kind] = path

    material = _atlas_material(atlas_name, images)
    obj.data.materials.clear()
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.material_index = 0

    return paths


def _validate_inputs(obj, resolution, margin, uv_margin):
    if obj is None or obj.type != "MESH":
        raise ValueError("bake_atlas requires one joined mesh object")
    if not obj.data.polygons:
        raise ValueError(f"'{obj.name}' has no faces to bake")
    if not obj.data.materials:
        raise ValueError(f"'{obj.name}' has no source materials to bake")
    # Unwrapping sees the base mesh but baking sees the evaluated one, so a modifier that
    # generates geometry — Solidify on every fin membrane, or Mirror — lays its new faces
    # on top of the source faces' UVs and the two overwrite each other in the atlas. There
    # is no error and no visual tell beyond shading that does not match the form, so this
    # is refused outright rather than warned about. Apply modifiers first.
    if obj.modifiers:
        names = ", ".join(modifier.name for modifier in obj.modifiers)
        raise ValueError(
            f"'{obj.name}' still has modifiers ({names}); apply them before baking or "
            f"generated geometry will share UVs with the faces it was generated from"
        )
    if resolution < 1:
        raise ValueError("resolution must be positive")
    if margin < 0:
        raise ValueError("margin cannot be negative")
    if not 0.0 <= uv_margin <= 1.0:
        raise ValueError("uv_margin must be between 0 and 1")


def _safe_name(name):
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", name).strip("._")
    return cleaned or "atlas"


def _activate(obj):
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def _unwrap(obj, island_margin):
    while obj.data.uv_layers:
        obj.data.uv_layers.remove(obj.data.uv_layers[0])
    obj.data.uv_layers.new(name="AtlasUV")

    bpy.ops.object.mode_set(mode="EDIT")
    try:
        bpy.ops.mesh.select_all(action="SELECT")
        result = bpy.ops.uv.smart_project(
            angle_limit=1.151917,
            margin_method="SCALED",
            rotate_method="AXIS_ALIGNED_Y",
            island_margin=island_margin,
            area_weight=0.0,
            correct_aspect=True,
            # Scaling the packed layout to fill 0..1 would push the outermost islands
            # flush against the UV border, where the bake margin's dilation gets clipped
            # by the image edge — cancelling the margin exactly where seams show.
            scale_to_bounds=False,
        )
        if "FINISHED" not in result:
            raise RuntimeError(f"Smart UV Project failed: {result}")
    finally:
        bpy.ops.object.mode_set(mode="OBJECT")


def _new_image(name, resolution, color_space):
    previous = bpy.data.images.get(name)
    if previous is not None:
        bpy.data.images.remove(previous)
    image = bpy.data.images.new(
        name=name,
        width=resolution,
        height=resolution,
        alpha=False,
        float_buffer=False,
    )
    image.colorspace_settings.name = color_space
    return image


def _source_materials(obj):
    materials = []
    for slot in obj.material_slots:
        material = slot.material
        if material is None:
            raise ValueError(f"'{obj.name}' has an empty material slot")
        if not material.use_nodes or material.node_tree is None:
            raise ValueError(f"material '{material.name}' does not use nodes")
        materials.append(material)
    return list(dict.fromkeys(materials))


def _select_bake_target(materials, image):
    """Point every source material's active node at `image`, which is how the bake
    operator is told where to write. Returns the nodes so they can be taken back out."""
    targets = []
    for material in materials:
        nodes = material.node_tree.nodes
        for node in nodes:
            node.select = False
        target = nodes.new("ShaderNodeTexImage")
        target.name = f"__bake_target_{image.name}"
        target.label = image.name
        target.image = image
        target.select = True
        nodes.active = target
        targets.append((material, target))
    return targets


def _bake(obj, materials, image, bake_type, margin):
    targets = _select_bake_target(materials, image)
    try:
        _activate(obj)
        result = bpy.ops.object.bake(
            type=bake_type,
            margin=margin,
            margin_type="EXTEND",
            use_clear=True,
            normal_space="TANGENT",
            target="IMAGE_TEXTURES",
        )
        if "FINISHED" not in result:
            raise RuntimeError(f"{bake_type} bake failed: {result}")
    finally:
        # Left in place these accumulate on every bake, and any material shared with
        # another object would carry a stale active image node into that object's bake.
        for material, target in targets:
            material.node_tree.nodes.remove(target)


def _atlas_material(atlas_name, images):
    material = bpy.data.materials.new(f"{atlas_name}_atlas")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (600, 0)
    principled = nodes.new("ShaderNodeBsdfPrincipled")
    principled.location = (320, 0)
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])

    base = nodes.new("ShaderNodeTexImage")
    base.name = "Base Color Atlas"
    base.location = (-420, 180)
    base.image = images["base_color"]
    links.new(base.outputs["Color"], principled.inputs["Base Color"])

    roughness = nodes.new("ShaderNodeTexImage")
    roughness.name = "Roughness Atlas"
    roughness.location = (-420, -40)
    roughness.image = images["roughness"]
    links.new(roughness.outputs["Color"], principled.inputs["Roughness"])

    normal_texture = nodes.new("ShaderNodeTexImage")
    normal_texture.name = "Normal Atlas"
    normal_texture.location = (-420, -260)
    normal_texture.image = images["normal"]
    normal = nodes.new("ShaderNodeNormalMap")
    normal.location = (-40, -220)
    normal.space = "TANGENT"
    links.new(normal_texture.outputs["Color"], normal.inputs["Color"])
    links.new(normal.outputs["Normal"], principled.inputs["Normal"])

    return material
