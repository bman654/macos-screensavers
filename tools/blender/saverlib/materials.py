"""Procedural materials for fish.

Everything is generated from shader nodes in object space rather than painted onto a UV
map. That keeps a species definition to a handful of numbers, lets one material serve a
whole school with per-object colour variation, and avoids shipping texture images.

Node socket names moved around in Blender 4.0 (Specular -> Specular IOR Level, and so on),
so inputs are set through `_set` which ignores names the current build does not have.
"""

import bpy


def _set(node, name, value):
    socket = node.inputs.get(name)
    if socket is not None:
        socket.default_value = value


_BLACK = (0.0, 0.0, 0.0, 1.0)
_WHITE = (1.0, 1.0, 1.0, 1.0)


def _mask_stops(intervals, fade, epsilon=1e-3):
    """ColorRamp stops for a 0/1 mask that is 1 inside each interval.

    Positions must be strictly increasing and inside 0..1 or the ramp silently reorders
    itself, so overlapping intervals are collapsed rather than trusted.
    """
    stops = [(0.0, _BLACK)]
    for start, end in sorted(intervals):
        stops.extend([
            (start - fade, _BLACK),
            (start, _WHITE),
            (end, _WHITE),
            (end + fade, _BLACK),
        ])
    stops.append((1.0, _BLACK))

    cleaned = []
    for position, color in stops:
        position = min(1.0, max(0.0, position))
        if cleaned and position <= cleaned[-1][0] + epsilon:
            continue
        cleaned.append((position, color))
    return cleaned


def _band_stops(bands, softness):
    return _mask_stops([(c - hw, c + hw) for c, hw in bands], softness)


def _outline_stops(bands, softness, width):
    intervals = []
    for center, half_width in bands:
        intervals.append((center - half_width - softness - width, center - half_width - softness))
        intervals.append((center + half_width + softness, center + half_width + softness + width))
    return _mask_stops(intervals, softness * 0.5)


def _ramp(node, stops):
    """Overwrite a ColorRamp's elements with (position, rgba) stops."""
    elements = node.color_ramp.elements
    while len(elements) > 1:
        elements.remove(elements[-1])
    elements[0].position, elements[0].color = stops[0]
    for position, color in stops[1:]:
        element = elements.new(position)
        element.color = color


def _add_mouth(nt, coord, base_color, mouth, color, softness=0.25):
    """Darken an ellipsoidal patch of object space to suggest a mouth.

    `mouth` is (center, radii) in object units. This is a shading trick, not geometry —
    at the size a fish occupies on screen a modelled mouth cavity is never visible, but
    a head with no mouth at all reads as unfinished from every angle.
    """
    center, radii = mouth
    nodes, links = nt.nodes, nt.links

    offset = nodes.new("ShaderNodeVectorMath")
    offset.location = (-1000, -900)
    offset.operation = "SUBTRACT"
    offset.inputs[1].default_value = center
    links.new(coord.outputs["Object"], offset.inputs[0])

    normalize = nodes.new("ShaderNodeVectorMath")
    normalize.location = (-820, -900)
    normalize.operation = "DIVIDE"
    normalize.inputs[1].default_value = radii
    links.new(offset.outputs["Vector"], normalize.inputs[0])

    distance = nodes.new("ShaderNodeVectorMath")
    distance.location = (-640, -900)
    distance.operation = "LENGTH"
    links.new(normalize.outputs["Vector"], distance.inputs[0])

    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.location = (-460, -900)
    _ramp(ramp, [(0.0, _WHITE), (max(0.0, 1.0 - softness), _WHITE), (1.0, _BLACK)])
    links.new(distance.outputs["Value"], ramp.inputs["Fac"])

    mix = nodes.new("ShaderNodeMix")
    mix.location = (200, -160)
    mix.data_type = "RGBA"
    mix.blend_type = "MIX"
    links.new(ramp.outputs["Color"], mix.inputs["Factor"])
    links.new(base_color, mix.inputs[6])
    mix.inputs[7].default_value = (*color, 1.0)
    return mix.outputs[2]


def fish_material(
    name,
    belly,
    mid,
    back,
    body_height=0.1,
    body_length=1.0,
    scale_count=55.0,
    scale_depth=0.2,
    bands=None,
    band_color=(0.94, 0.94, 0.92),
    band_softness=0.012,
    outline_color=(0.02, 0.02, 0.03),
    outline_width=0.018,
    mouth=None,
    mouth_color=(0.10, 0.035, 0.025),
    roughness=0.44,
    roughness_variation=0.16,
    mottle=0.12,
    coat=0.03,
    iridescence=0.18,
):
    """Countershaded, scaled, optionally banded skin.

    `body_height` is the half-height of the body in object units; the countershading
    gradient is normalized against it so the same numbers work at any fish size.

    `bands` places markings explicitly as (center, half_width) pairs in normalized body
    position, 0 at the nose and 1 at the tail base. A periodic texture was tried first
    and is the wrong model: real markings sit at particular places on the animal and do
    not repeat, and getting three bars in the right spots by tuning a frequency is
    guesswork. Each band is drawn with a darker outline, as most banded reef fish have.
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coord = nodes.new("ShaderNodeTexCoord")
    coord.location = (-1200, 0)

    separate = nodes.new("ShaderNodeSeparateXYZ")
    separate.location = (-1000, 200)
    links.new(coord.outputs["Object"], separate.inputs["Vector"])

    # Normalize object-space Z into 0..1 across the body's vertical extent.
    height_map = nodes.new("ShaderNodeMapRange")
    height_map.location = (-820, 200)
    _set(height_map, "From Min", -body_height)
    _set(height_map, "From Max", body_height)
    links.new(separate.outputs["Z"], height_map.inputs["Value"])

    shading = nodes.new("ShaderNodeValToRGB")
    shading.location = (-620, 240)
    _ramp(
        shading,
        [
            (0.0, (*belly, 1.0)),
            (0.42, (*mid, 1.0)),
            (1.0, (*back, 1.0)),
        ],
    )
    shading.color_ramp.interpolation = "EASE"
    links.new(height_map.outputs["Result"], shading.inputs["Fac"])

    base_color = shading.outputs["Color"]

    if bands:
        # Object X maps to normalized nose->tail position; see Body.x().
        position = nodes.new("ShaderNodeMapRange")
        position.location = (-820, -160)
        _set(position, "From Min", body_length * 0.5)
        _set(position, "From Max", -body_length * 0.5)
        links.new(separate.outputs["X"], position.inputs["Value"])

        # Warp the coordinate slightly so band edges are organic rather than ruler-straight.
        noise = nodes.new("ShaderNodeTexNoise")
        noise.location = (-1000, -640)
        _set(noise, "Scale", 3.0 / max(body_length, 1e-6))
        _set(noise, "Detail", 2.0)
        links.new(coord.outputs["Object"], noise.inputs["Vector"])

        wobble = nodes.new("ShaderNodeMath")
        wobble.location = (-800, -640)
        wobble.operation = "MULTIPLY_ADD"
        wobble.inputs[1].default_value = 0.05
        wobble.inputs[2].default_value = -0.025
        links.new(noise.outputs["Fac"], wobble.inputs[0])

        warped = nodes.new("ShaderNodeMath")
        warped.location = (-620, -400)
        warped.operation = "ADD"
        links.new(position.outputs["Result"], warped.inputs[0])
        links.new(wobble.outputs["Value"], warped.inputs[1])

        band_ramp = nodes.new("ShaderNodeValToRGB")
        band_ramp.location = (-420, -200)
        _ramp(band_ramp, _band_stops(bands, band_softness))
        links.new(warped.outputs["Value"], band_ramp.inputs["Fac"])

        banded = nodes.new("ShaderNodeMix")
        banded.location = (-200, -40)
        banded.data_type = "RGBA"
        banded.blend_type = "MIX"
        links.new(band_ramp.outputs["Color"], banded.inputs["Factor"])
        links.new(base_color, banded.inputs[6])
        banded.inputs[7].default_value = (*band_color, 1.0)
        base_color = banded.outputs[2]

        if outline_width > 0.0:
            outline_ramp = nodes.new("ShaderNodeValToRGB")
            outline_ramp.location = (-420, -560)
            _ramp(outline_ramp, _outline_stops(bands, band_softness, outline_width))
            links.new(warped.outputs["Value"], outline_ramp.inputs["Fac"])

            outlined = nodes.new("ShaderNodeMix")
            outlined.location = (0, -120)
            outlined.data_type = "RGBA"
            outlined.blend_type = "MIX"
            links.new(outline_ramp.outputs["Color"], outlined.inputs["Factor"])
            links.new(base_color, outlined.inputs[6])
            outlined.inputs[7].default_value = (*outline_color, 1.0)
            base_color = outlined.outputs[2]

    if mouth:
        base_color = _add_mouth(nt, coord, base_color, mouth, mouth_color)

    if mottle > 0.0:
        # Low-frequency tonal drift. A perfectly even albedo is one of the strongest
        # cues that a surface is moulded plastic rather than a living animal.
        mottle_noise = nodes.new("ShaderNodeTexNoise")
        mottle_noise.location = (-1000, -1180)
        _set(mottle_noise, "Scale", 7.0 / max(body_length, 1e-6))
        _set(mottle_noise, "Detail", 6.0)
        _set(mottle_noise, "Roughness", 0.6)
        links.new(coord.outputs["Object"], mottle_noise.inputs["Vector"])

        mottle_mix = nodes.new("ShaderNodeMix")
        mottle_mix.location = (320, -300)
        mottle_mix.data_type = "RGBA"
        mottle_mix.blend_type = "MULTIPLY"
        links.new(mottle_noise.outputs["Fac"], mottle_mix.inputs["Factor"])
        links.new(base_color, mottle_mix.inputs[6])
        shade = 1.0 - mottle
        mottle_mix.inputs[7].default_value = (shade, shade * 0.97, shade * 0.94, 1.0)
        base_color = mottle_mix.outputs[2]

    # Scales: Voronoi cells stretched along the body, driving a bump rather than colour.
    # `scale_count` is how many scales run nose to tail, converted to a cell frequency
    # here. Specifying the frequency directly meant cells sized in absolute metres, which
    # on a 10cm fish produced 5mm cells that read as low-poly faceting, not scales.
    frequency = scale_count / max(body_length, 1e-6)
    scale_map = nodes.new("ShaderNodeMapping")
    scale_map.location = (-1000, -420)
    scale_map.inputs["Scale"].default_value = (frequency * 0.55, frequency, frequency)
    links.new(coord.outputs["Object"], scale_map.inputs["Vector"])

    voronoi = nodes.new("ShaderNodeTexVoronoi")
    voronoi.location = (-800, -420)
    voronoi.feature = "F1"
    voronoi.distance = "EUCLIDEAN"
    _set(voronoi, "Scale", 1.0)
    _set(voronoi, "Randomness", 0.55)
    links.new(scale_map.outputs["Vector"], voronoi.inputs["Vector"])

    bump = nodes.new("ShaderNodeBump")
    bump.location = (-560, -420)
    _set(bump, "Strength", scale_depth)
    _set(bump, "Distance", body_length * 0.02)
    links.new(voronoi.outputs["Distance"], bump.inputs["Height"])

    # Iridescence: a grazing-angle sheen only. The Facing output covers everything
    # pointing at the camera, which washes the whole animal out; Fresnel confines the
    # sheen to the silhouette edge where it actually reads as wet.
    fresnel = nodes.new("ShaderNodeLayerWeight")
    fresnel.location = (-560, 460)
    _set(fresnel, "Blend", 0.42)

    sheen = nodes.new("ShaderNodeMix")
    sheen.location = (200, 260)
    sheen.data_type = "RGBA"
    sheen.blend_type = "SCREEN"
    links.new(fresnel.outputs["Fresnel"], sheen.inputs["Factor"])
    links.new(base_color, sheen.inputs[6])
    sheen.inputs[7].default_value = (0.35 * iridescence, 0.55 * iridescence, 0.75 * iridescence, 1.0)

    # Roughness breakup. A single constant roughness gives one clean specular lobe over
    # the whole animal, which is exactly what moulded plastic looks like. Varying it with
    # noise, and roughening the grooves between scales, scatters the highlight into
    # something that reads as wet skin.
    rough_noise = nodes.new("ShaderNodeTexNoise")
    rough_noise.location = (-1000, -1500)
    _set(rough_noise, "Scale", 22.0 / max(body_length, 1e-6))
    _set(rough_noise, "Detail", 5.0)
    links.new(coord.outputs["Object"], rough_noise.inputs["Vector"])

    rough_range = nodes.new("ShaderNodeMapRange")
    rough_range.location = (-800, -1500)
    _set(rough_range, "To Min", max(0.05, roughness - roughness_variation))
    _set(rough_range, "To Max", min(0.95, roughness + roughness_variation))
    links.new(rough_noise.outputs["Fac"], rough_range.inputs["Value"])

    groove = nodes.new("ShaderNodeMapRange")
    groove.location = (-800, -1700)
    _set(groove, "To Min", 0.10)
    _set(groove, "To Max", 0.0)
    links.new(voronoi.outputs["Distance"], groove.inputs["Value"])

    rough_total = nodes.new("ShaderNodeMath")
    rough_total.location = (-600, -1600)
    rough_total.operation = "ADD"
    rough_total.use_clamp = True
    links.new(rough_range.outputs["Result"], rough_total.inputs[0])
    links.new(groove.outputs["Result"], rough_total.inputs[1])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (620, 60)
    _set(bsdf, "Specular IOR Level", 0.42)
    # A coat is a clear lacquer layer; on a fish it is the single biggest contributor to
    # a plastic look, so it is only a trace here rather than a proper wet layer.
    _set(bsdf, "Coat Weight", coat)
    _set(bsdf, "Coat Roughness", 0.28)
    links.new(rough_total.outputs["Value"], bsdf.inputs["Roughness"])
    # Subsurface radius is in metres. Left at a human-skin default it exceeded the whole
    # animal, bleeding light through the body and desaturating it to salmon; tie it to
    # the model's own size so a fish stays the colour it was given.
    _set(bsdf, "Subsurface Weight", 0.10)
    _set(bsdf, "Subsurface Radius",
         (body_length * 0.020, body_length * 0.012, body_length * 0.008))
    links.new(sheen.outputs[2], bsdf.inputs["Base Color"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (460, 60)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    return mat


def fin_material(name, color, opacity=0.65, ray_count=26.0, ray_contrast=0.5,
                 roughness=0.52):
    """Translucent membrane with the striations of fin rays."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.blend_method = "BLEND"
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coord = nodes.new("ShaderNodeTexCoord")
    coord.location = (-900, 0)

    rays = nodes.new("ShaderNodeTexWave")
    rays.location = (-700, -60)
    rays.wave_type = "BANDS"
    rays.bands_direction = "Z"
    rays.wave_profile = "SIN"
    _set(rays, "Scale", ray_count)
    _set(rays, "Distortion", 1.2)
    links.new(coord.outputs["Object"], rays.inputs["Vector"])

    ray_ramp = nodes.new("ShaderNodeValToRGB")
    ray_ramp.location = (-500, -60)
    lo = 0.55 - 0.25 * ray_contrast
    _ramp(ray_ramp, [(0.0, (lo, lo, lo, 1)), (1.0, (1, 1, 1, 1))])
    links.new(rays.outputs["Fac"], ray_ramp.inputs["Fac"])

    tint = nodes.new("ShaderNodeMix")
    tint.location = (-260, 40)
    tint.data_type = "RGBA"
    tint.blend_type = "MULTIPLY"
    tint.inputs["Factor"].default_value = 1.0
    tint.inputs[6].default_value = (*color, 1.0)
    links.new(ray_ramp.outputs["Color"], tint.inputs[7])

    # Fade the trailing edge out so fins do not end on a hard line.
    fade = nodes.new("ShaderNodeLayerWeight")
    fade.location = (-500, 260)
    _set(fade, "Blend", 0.25)

    alpha = nodes.new("ShaderNodeMath")
    alpha.location = (-260, 300)
    alpha.operation = "MULTIPLY"
    alpha.inputs[1].default_value = opacity
    links.new(ray_ramp.outputs["Color"], alpha.inputs[0])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (60, 60)
    _set(bsdf, "Roughness", roughness)
    _set(bsdf, "Specular IOR Level", 0.35)
    _set(bsdf, "Transmission Weight", 0.25)
    _set(bsdf, "IOR", 1.33)
    links.new(tint.outputs[2], bsdf.inputs["Base Color"])
    links.new(alpha.outputs["Value"], bsdf.inputs["Alpha"])

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (380, 60)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    return mat


def eye_material(name, iris=(0.012, 0.010, 0.014)):
    """A near-black eye with one tight catchlight.

    A broad coat layer turns the sphere into a grey bead under studio light, because the
    whole rig reflects off it; keeping the coat modest and roughness very low confines
    the reflection to a small highlight, which is what reads as a wet eye.
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    _set(bsdf, "Base Color", (*iris, 1.0))
    _set(bsdf, "Roughness", 0.06)
    _set(bsdf, "Specular IOR Level", 0.40)
    _set(bsdf, "Coat Weight", 0.35)
    _set(bsdf, "Coat Roughness", 0.03)
    return mat


def assign(obj, material):
    obj.data.materials.clear()
    obj.data.materials.append(material)
