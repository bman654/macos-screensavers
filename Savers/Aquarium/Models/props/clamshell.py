"""A giant clam whose upper valve gapes to release a slow seep of bubbles."""

import math

import bpy
from mathutils import Vector

from saverlib import shade_smooth

from ._spec import Emitter, Part, Phase, Prop


_WIDTH = 0.30
_DEPTH = 0.26
_HINGE_Y = 0.13
_HINGE_Z = 0.074
_RIBS = 9


def _set(node, socket, value):
    target = node.inputs.get(socket)
    if target is not None:
        target.default_value = value


def _seed_offset(seed):
    return (
        (seed * 12.9898) % 11.0,
        (seed * 78.233) % 13.0,
        (seed * 37.719) % 17.0,
    )


def _shell_exterior_material(name, seed):
    """Shell needs rib-aware staining; generic stone left the valleys uniformly porcelain."""
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nt = material.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coordinates = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Location"].default_value = _seed_offset(seed + 7)
    mapping.inputs["Scale"].default_value = (22.0, 22.0, 22.0)
    links.new(coordinates.outputs["Object"], mapping.inputs["Vector"])

    weather = nodes.new("ShaderNodeTexNoise")
    _set(weather, "Scale", 1.0)
    _set(weather, "Detail", 6.0)
    _set(weather, "Roughness", 0.72)
    _set(weather, "Distortion", 0.35)
    links.new(mapping.outputs["Vector"], weather.inputs["Vector"])

    limestone = nodes.new("ShaderNodeValToRGB")
    limestone.color_ramp.interpolation = "EASE"
    stops = limestone.color_ramp.elements
    stops[0].position = 0.20
    stops[0].color = (0.060, 0.050, 0.030, 1.0)
    stops[1].position = 0.82
    stops[1].color = (0.30, 0.245, 0.145, 1.0)
    stained = stops.new(0.48)
    stained.color = (0.135, 0.105, 0.055, 1.0)
    pale = stops.new(0.66)
    pale.color = (0.235, 0.195, 0.115, 1.0)
    links.new(weather.outputs["Fac"], limestone.inputs["Fac"])

    groove = nodes.new("ShaderNodeAttribute")
    groove.attribute_name = "groove"
    patch_mapping = nodes.new("ShaderNodeMapping")
    patch_mapping.inputs["Location"].default_value = _seed_offset(seed + 29)
    patch_mapping.inputs["Scale"].default_value = (12.0, 12.0, 12.0)
    links.new(coordinates.outputs["Object"], patch_mapping.inputs["Vector"])
    patches = nodes.new("ShaderNodeTexNoise")
    _set(patches, "Scale", 1.0)
    _set(patches, "Detail", 5.0)
    _set(patches, "Roughness", 0.65)
    links.new(patch_mapping.outputs["Vector"], patches.inputs["Vector"])

    patch_ramp = nodes.new("ShaderNodeValToRGB")
    patch_ramp.color_ramp.elements[0].position = 0.35
    patch_ramp.color_ramp.elements[1].position = 0.68
    links.new(patches.outputs["Fac"], patch_ramp.inputs["Fac"])
    algae_mask = nodes.new("ShaderNodeMath")
    algae_mask.operation = "MULTIPLY"
    links.new(groove.outputs["Fac"], algae_mask.inputs[0])
    links.new(patch_ramp.outputs["Color"], algae_mask.inputs[1])

    algae_tone = nodes.new("ShaderNodeValToRGB")
    algae_tone.color_ramp.elements[0].color = (0.018, 0.030, 0.009, 1.0)
    algae_tone.color_ramp.elements[1].color = (0.080, 0.092, 0.025, 1.0)
    links.new(patches.outputs["Fac"], algae_tone.inputs["Fac"])

    colour = nodes.new("ShaderNodeMixRGB")
    colour.blend_type = "MIX"
    colour.inputs[0].default_value = 0.0
    links.new(algae_mask.outputs["Value"], colour.inputs[0])
    links.new(limestone.outputs["Color"], colour.inputs[1])
    links.new(algae_tone.outputs["Color"], colour.inputs[2])

    roughness = nodes.new("ShaderNodeMapRange")
    roughness.clamp = True
    roughness.inputs["From Min"].default_value = 0.0
    roughness.inputs["From Max"].default_value = 1.0
    roughness.inputs["To Min"].default_value = 0.63
    roughness.inputs["To Max"].default_value = 0.92
    links.new(patches.outputs["Fac"], roughness.inputs["Value"])

    bump = nodes.new("ShaderNodeBump")
    _set(bump, "Strength", 0.32)
    _set(bump, "Distance", 0.0012)
    links.new(weather.outputs["Fac"], bump.inputs["Height"])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    links.new(colour.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(roughness.outputs["Result"], bsdf.inputs["Roughness"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    _set(bsdf, "Specular IOR Level", 0.28)

    output = nodes.new("ShaderNodeOutputMaterial")
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    return material


def _pearlescent_material(name, seed):
    """Smooth nacre needs angle-dependent colour and a wet highlight that stone cannot give."""
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nt = material.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coordinates = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Location"].default_value = _seed_offset(seed)
    mapping.inputs["Scale"].default_value = (38.0, 38.0, 38.0)
    links.new(coordinates.outputs["Object"], mapping.inputs["Vector"])

    noise = nodes.new("ShaderNodeTexNoise")
    _set(noise, "Scale", 1.0)
    _set(noise, "Detail", 5.0)
    _set(noise, "Roughness", 0.58)
    links.new(mapping.outputs["Vector"], noise.inputs["Vector"])

    # The colour has to live here, in the albedo, because the two nodes below that actually
    # make nacre look like nacre — Coat and Iridescence — do not survive the bake.
    # UsdPreviewSurface has no equivalent of either, so what reaches the tank is base colour,
    # roughness and normal alone. A ramp tuned to be the *pale substrate* under an
    # iridescent coat therefore arrives as the whole material, and pale plus 8-bit sRGB
    # encoding (linear 0.78 is already 230/255) baked the interior to near-white — a hard
    # bright band where the two valve interiors meet at the rim, which reads as a render
    # artifact rather than as shell.
    #
    # So: darker, and carrying its own hue shifts. Real mother-of-pearl is not white; it is
    # dun to sea-green to lilac to a cold blue, and painting that variation into the albedo
    # is the only way any of it reaches SceneKit.
    nacre = nodes.new("ShaderNodeValToRGB")
    stops = nacre.color_ramp.elements
    stops[0].position = 0.15
    stops[0].color = (0.32, 0.29, 0.26, 1.0)
    stops[1].position = 0.85
    stops[1].color = (0.44, 0.50, 0.57, 1.0)
    stops.new(0.40).color = (0.38, 0.46, 0.44, 1.0)
    stops.new(0.62).color = (0.51, 0.45, 0.50, 1.0)
    links.new(noise.outputs["Fac"], nacre.inputs["Fac"])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    links.new(nacre.outputs["Color"], bsdf.inputs["Base Color"])
    _set(bsdf, "Roughness", 0.24)
    _set(bsdf, "Specular IOR Level", 0.52)
    _set(bsdf, "Coat Weight", 0.34)
    _set(bsdf, "Coat Roughness", 0.10)
    _set(bsdf, "Iridescence Weight", 0.28)
    _set(bsdf, "Iridescence IOR", 1.34)

    bump = nodes.new("ShaderNodeBump")
    _set(bump, "Strength", 0.16)
    _set(bump, "Distance", 0.00035)
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    output = nodes.new("ShaderNodeOutputMaterial")
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    return material


def _mantle_material(name, seed):
    """Muted gold, brown and teal stay biological while a coat supplies the living sheen."""
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nt = material.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coordinates = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Location"].default_value = _seed_offset(seed + 41)
    mapping.inputs["Scale"].default_value = (34.0, 34.0, 34.0)
    links.new(coordinates.outputs["Object"], mapping.inputs["Vector"])

    blotches = nodes.new("ShaderNodeTexNoise")
    _set(blotches, "Scale", 1.0)
    _set(blotches, "Detail", 7.0)
    _set(blotches, "Roughness", 0.72)
    _set(blotches, "Distortion", 0.75)
    links.new(mapping.outputs["Vector"], blotches.inputs["Vector"])

    colour = nodes.new("ShaderNodeValToRGB")
    colour.color_ramp.interpolation = "EASE"
    stops = colour.color_ramp.elements
    stops[0].position = 0.16
    stops[0].color = (0.018, 0.010, 0.006, 1.0)
    stops[1].position = 0.84
    stops[1].color = (0.075, 0.105, 0.070, 1.0)
    gold = stops.new(0.39)
    gold.color = (0.120, 0.067, 0.018, 1.0)
    teal = stops.new(0.58)
    teal.color = (0.012, 0.083, 0.074, 1.0)
    blue = stops.new(0.70)
    blue.color = (0.010, 0.044, 0.082, 1.0)
    links.new(blotches.outputs["Fac"], colour.inputs["Fac"])

    fine_mapping = nodes.new("ShaderNodeMapping")
    fine_mapping.inputs["Location"].default_value = _seed_offset(seed + 67)
    fine_mapping.inputs["Scale"].default_value = (92.0, 92.0, 92.0)
    links.new(coordinates.outputs["Object"], fine_mapping.inputs["Vector"])
    freckles = nodes.new("ShaderNodeTexVoronoi")
    freckles.distance = "EUCLIDEAN"
    links.new(fine_mapping.outputs["Vector"], freckles.inputs["Vector"])

    bump = nodes.new("ShaderNodeBump")
    _set(bump, "Strength", 0.22)
    _set(bump, "Distance", 0.0007)
    links.new(freckles.outputs["Distance"], bump.inputs["Height"])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    links.new(colour.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    _set(bsdf, "Roughness", 0.36)
    _set(bsdf, "Specular IOR Level", 0.42)
    _set(bsdf, "Coat Weight", 0.22)
    _set(bsdf, "Coat Roughness", 0.16)
    _set(bsdf, "Iridescence Weight", 0.10)
    _set(bsdf, "Iridescence IOR", 1.32)
    _set(bsdf, "Subsurface Weight", 0.06)

    output = nodes.new("ShaderNodeOutputMaterial")
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    return material


def _rib_peak(s):
    phase = (s + 1.0) * 0.5 * (_RIBS - 1)
    return (0.5 + 0.5 * math.cos(math.tau * phase)) ** 3


def _groove_mask(s):
    phase = (s + 1.0) * 0.5 * (_RIBS - 1)
    return (0.5 - 0.5 * math.cos(math.tau * phase)) ** 5


def _rim(s):
    rib = _rib_peak(s)
    x = 0.5 * _WIDTH * s
    y = -0.120 + 0.105 * s * s - 0.010 * rib
    z = 0.0715 + 0.0055 * rib
    return x, y, z


def _surface_point(s, t, upper, inner):
    rib = _rib_peak(s)
    rim_x, rim_y, rim_z = _rim(s)
    hinge_x = 0.052 * s
    x = hinge_x + (rim_x - hinge_x) * t
    y = _HINGE_Y + (rim_y - _HINGE_Y) * t

    arch = math.sin(math.pi * t) ** 0.86
    edge_falloff = max(0.0, math.cos(0.5 * math.pi * s)) ** 0.65
    side_taper = 0.025 + 0.975 * edge_falloff
    growth = math.sin(math.tau * 12.0 * t + 0.35) * arch * side_taper
    base = _HINGE_Z + (rim_z - _HINGE_Z) * t

    if upper:
        outer = base + 0.0765 * arch * side_taper + 0.0052 * rib * arch * side_taper
        outer += 0.00115 * growth
        if inner:
            return Vector((x, y, base + 0.068 * arch * side_taper))
        return Vector((x, y, outer))

    outer = base - 0.0725 * arch * side_taper - 0.0048 * rib * arch * side_taper
    outer -= 0.00105 * growth
    if inner:
        return Vector((x, y, base - 0.063 * arch * side_taper))
    return Vector((x, y, outer))


def _valve(name, upper, exterior, interior, parent, hinge):
    across = 81
    radial = 97
    vertices = []
    groove_values = []
    outer = []
    inner = []

    for surface, is_inner in ((outer, False), (inner, True)):
        for i in range(across):
            s = -1.0 + 2.0 * i / (across - 1)
            row = []
            for j in range(radial):
                # Sharing both edge rows closes the shell cleanly without zero-area rim faces.
                if is_inner and j in (0, radial - 1):
                    row.append(outer[i][j])
                    continue
                t = j / (radial - 1)
                point = _surface_point(s, t, upper, is_inner)
                if hinge is not None:
                    point -= hinge
                row.append(len(vertices))
                vertices.append(tuple(point))
                groove_values.append(_groove_mask(s))
            surface.append(row)

    faces = []
    materials = []

    def add(face, material):
        faces.append(face)
        materials.append(material)

    for i in range(across - 1):
        for j in range(radial - 1):
            outside = (outer[i][j], outer[i + 1][j], outer[i + 1][j + 1], outer[i][j + 1])
            inside = (inner[i][j], inner[i + 1][j], inner[i + 1][j + 1], inner[i][j + 1])
            add(tuple(reversed(outside)) if upper else outside, 0)
            add(inside if upper else tuple(reversed(inside)), 1)

    for i in (0, across - 1):
        for j in range(radial - 1):
            quad = (outer[i][j], outer[i][j + 1], inner[i][j + 1], inner[i][j])
            add(tuple(reversed(quad)) if i == 0 else quad, 0)

    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    groove = mesh.attributes.new("groove", "FLOAT", "POINT")
    for datum, value in zip(groove.data, groove_values):
        datum.value = value
    mesh.materials.append(exterior)
    mesh.materials.append(interior)
    for polygon, material in zip(mesh.polygons, materials):
        polygon.material_index = material
    shade_smooth(mesh)

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = parent
    if hinge is not None:
        obj.location = hinge
    return obj


def _build_mantle(parent, material):
    across = 89
    inward = 10
    vertices = []
    top = []
    bottom = []

    for surface, underside in ((top, False), (bottom, True)):
        for i in range(across):
            t = i / (across - 1)
            s = -0.84 + 1.68 * t
            rim_x, rim_y, rim_z = _rim(s)
            row = []
            for j in range(inward):
                u = j / (inward - 1)
                dome = math.sin(math.pi * u)
                edge_taper = math.sin(math.pi * t) ** 0.45
                ripple = 0.0012 * math.sin(math.tau * 5.0 * t + 0.4) * dome
                x = rim_x * (1.0 - 0.10 * u)
                y = rim_y + 0.006 + 0.046 * u
                z = rim_z + 0.001 + 0.009 * dome * edge_taper + ripple
                if underside:
                    z -= 0.0012 + 0.0032 * dome * edge_taper
                row.append(len(vertices))
                vertices.append((x, y, z))
            surface.append(row)

    faces = []
    for i in range(across - 1):
        for j in range(inward - 1):
            faces.append((top[i][j], top[i + 1][j], top[i + 1][j + 1], top[i][j + 1]))
            faces.append((bottom[i][j + 1], bottom[i + 1][j + 1],
                          bottom[i + 1][j], bottom[i][j]))
    for i in range(across - 1):
        faces.append((top[i][0], bottom[i][0], bottom[i + 1][0], top[i + 1][0]))
        faces.append((top[i][-1], top[i + 1][-1], bottom[i + 1][-1], bottom[i][-1]))
    for i in (0, across - 1):
        for j in range(inward - 1):
            face = (top[i][j], top[i][j + 1], bottom[i][j + 1], bottom[i][j])
            faces.append(tuple(reversed(face)) if i == 0 else face)

    mesh = bpy.data.meshes.new("mantle_lip")
    mesh.from_pydata(vertices, [], faces)
    mesh.materials.append(material)
    shade_smooth(mesh)
    mantle = bpy.data.objects.new("mantle_lip", mesh)
    bpy.context.collection.objects.link(mantle)
    mantle.parent = parent
    smoothing = mantle.modifiers.new("Mantle smoothing", "SUBSURF")
    smoothing.levels = 1
    smoothing.render_levels = 1
    return mantle


def build(seed=0):
    root = bpy.data.objects.new("decor_clamshell", None)
    bpy.context.collection.objects.link(root)

    exterior = _shell_exterior_material(f"clamshell_exterior_{seed}", seed)
    interior = _pearlescent_material(f"clamshell_nacre_{seed}", seed)
    mantle_material = _mantle_material(f"clamshell_mantle_{seed}", seed)

    _valve("lower_valve", False, exterior, interior, root, None)

    # Subtracting this point from the mesh keeps the object's transform unscaled while making
    # its exported transform node the hinge itself, which is the condition SceneKit needs.
    hinge = Vector((0.0, _HINGE_Y, _HINGE_Z))
    upper = _valve("part_upper_valve", True, exterior, interior, root, hinge)

    _build_mantle(root, mantle_material)

    emitter = bpy.data.objects.new("emit_bubbles", None)
    bpy.context.collection.objects.link(emitter)
    emitter.empty_display_type = "SPHERE"
    emitter.empty_display_size = 0.008
    emitter.parent = upper
    emitter.location = (0.0, -0.120, 0.020)

    return root


CLAMSHELL = Prop(
    name="clamshell",
    build=build,
    category="decoration",
    # The open upper valve reaches y=0.164 m and z=0.259 m; placement must reserve the
    # animated sweep rather than only the compact closed silhouette.
    footprint=0.18,
    height=0.26,
    tilt_range=(-3.0, 3.0),
    scale_range=(0.90, 1.12),
    weight=0.85,
    max_per_scene=1,
    min_spacing=0.42,
    parts=(Part(node="part_upper_valve", axis=(1.0, 0.0, 0.0), open_degrees=-24.0),),
    emitters=(Emitter(
        node="emit_bubbles",
        rate=7.0,
        radius=0.009,
        size=(0.002, 0.0045),
        speed=0.065,
    ),),
    cycle=(
        Phase("idle", (9.0, 21.0)),
        Phase("move", 0.75, part="part_upper_valve", to=1.0, ease="easeOut"),
        Phase("emit", 3.6, emitter="emit_bubbles"),
        Phase("move", 2.1, part="part_upper_valve", to=0.0, ease="easeInOut"),
    ),
    seeds=3,
)
