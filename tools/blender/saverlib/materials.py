"""Procedural materials for fish.

Everything is generated from shader nodes in object space rather than painted onto a UV
map. That keeps a species definition to a handful of numbers, lets one material serve a
whole school with per-object colour variation, and avoids shipping texture images.

`fish_material` carries a vocabulary of markings — bands, stripes, diagonal stripes,
spots, patches and a two-tone split — that a species picks from and places explicitly.
Explicit placement rather than a tuned periodic frequency is the load-bearing decision
here: real markings sit at particular places on an animal and do not repeat, so landing
three bars correctly by adjusting a wave frequency is guesswork. The one marking that is
genuinely periodic on the animal, the angelfish's diagonal ruling, is the one marking
specified by spacing.

Node socket names moved around in Blender 4.0 (Specular -> Specular IOR Level, and so on),
so inputs are set through `_set` which ignores names the current build does not have.
"""

from math import cos, pi, radians, sin

import bpy


def _set(node, name, value):
    socket = node.inputs.get(name)
    if socket is not None:
        socket.default_value = value


_BLACK = (0.0, 0.0, 0.0, 1.0)
_WHITE = (1.0, 1.0, 1.0, 1.0)


# -- generic node helpers ------------------------------------------------------------


def _link_or_set(nt, socket, value):
    if isinstance(value, bpy.types.NodeSocket):
        nt.links.new(value, socket)
    elif value is not None:
        socket.default_value = value


def _math(nt, operation, a, b=None, location=(0, 0), clamp=False):
    node = nt.nodes.new("ShaderNodeMath")
    node.operation = operation
    node.location = location
    node.use_clamp = clamp
    _link_or_set(nt, node.inputs[0], a)
    _link_or_set(nt, node.inputs[1], b)
    return node.outputs[0]


def _ramp(node, stops):
    """Overwrite a ColorRamp's elements with (position, rgba) stops."""
    elements = node.color_ramp.elements
    while len(elements) > 1:
        elements.remove(elements[-1])
    elements[0].position, elements[0].color = stops[0]
    for position, color in stops[1:]:
        element = elements.new(position)
        element.color = color


def _ramp_node(nt, fac, stops, location=(0, 0), interpolation="LINEAR"):
    node = nt.nodes.new("ShaderNodeValToRGB")
    node.location = location
    _ramp(node, stops)
    node.color_ramp.interpolation = interpolation
    nt.links.new(fac, node.inputs["Fac"])
    return node.outputs["Color"]


def _mix_color(nt, base_color, factor, color, location=(0, 0), blend="MIX"):
    """Lay a flat colour over `base_color` wherever `factor` is 1."""
    mix = nt.nodes.new("ShaderNodeMix")
    mix.location = location
    mix.data_type = "RGBA"
    mix.blend_type = blend
    nt.links.new(factor, mix.inputs["Factor"])
    nt.links.new(base_color, mix.inputs[6])
    mix.inputs[7].default_value = (*color, 1.0)
    return mix.outputs[2]


def _mask_stops(intervals, fade, epsilon=1e-3):
    """ColorRamp stops for a 0/1 mask that is 1 inside each interval.

    Positions must be strictly increasing and inside 0..1 or the ramp silently reorders
    itself. Where two stops collide — because an interval runs off the end of the range
    and clamps, or because two intervals overlap — the "on" stop wins, which is what the
    union of a set of intervals means.
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
            if color == _WHITE:
                cleaned[-1] = (cleaned[-1][0], _WHITE)
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


# -- marking parameter handling ------------------------------------------------------


def _as_dicts(value):
    return [value] if isinstance(value, dict) else list(value)


def _fields(params, required, defaults, what):
    """Validate one marking dict and fill in its defaults.

    An unknown key is an error rather than a shrug. A misspelled key otherwise renders
    perfectly and draws nothing, which is the most expensive failure mode in a pipeline
    whose only feedback is looking at the picture.
    """
    unknown = sorted(set(params) - set(required) - set(defaults))
    if unknown:
        raise ValueError(f"{what}: unknown key(s) {unknown}; "
                         f"expected {sorted(set(required) | set(defaults))}")
    missing = sorted(k for k in required if k not in params)
    if missing:
        raise ValueError(f"{what}: missing key(s) {missing}")
    values = dict(defaults)
    values.update(params)
    return values


def _colored_groups(entries, default_color):
    """Group (position, half_width[, color]) entries by colour, keeping order.

    One ramp serves every entry of a colour, so the common case — a whole marking in one
    colour — costs the same two nodes it always did, and a per-entry colour costs two
    more only when it is actually used.
    """
    groups = []
    for entry in entries:
        position, half_width = float(entry[0]), float(entry[1])
        color = tuple(entry[2]) if len(entry) > 2 else tuple(default_color)
        for existing, members in groups:
            if existing == color:
                members.append((position, half_width))
                break
        else:
            groups.append((color, [(position, half_width)]))
    return groups


# -- body coordinates ----------------------------------------------------------------


class _Flank:
    """The object-space coordinates every body marking is placed in.

    `t` runs 0 at the nose to 1 at the tail base, `h` runs 0 at the belly to 1 at the
    back, and both are warped by one shared noise field so marking edges are organic
    rather than ruler-straight. Sharing a single warp matters where two markings meet:
    they wobble together instead of shearing past each other.

    `height` is the same vertical coordinate unwarped, which is what countershading
    wants — a wobbling belly-to-back gradient reads as a dirty render, not as an animal.
    """

    def __init__(self, nt, coord, body_length, body_height, warp=0.05):
        self.nt = nt
        self.coord = coord
        self.length = body_length
        self._column = 0

        nodes, links = nt.nodes, nt.links
        separate = nodes.new("ShaderNodeSeparateXYZ")
        separate.location = (-1000, 200)
        links.new(coord.outputs["Object"], separate.inputs["Vector"])
        self.object = coord.outputs["Object"]

        height = nodes.new("ShaderNodeMapRange")
        height.location = (-820, 200)
        _set(height, "From Min", -body_height)
        _set(height, "From Max", body_height)
        links.new(separate.outputs["Z"], height.inputs["Value"])
        self.height = height.outputs["Result"]

        # Object X maps to normalized nose->tail position; see Body.x().
        position = nodes.new("ShaderNodeMapRange")
        position.location = (-820, -160)
        _set(position, "From Min", body_length * 0.5)
        _set(position, "From Max", -body_length * 0.5)
        links.new(separate.outputs["X"], position.inputs["Value"])

        noise = nodes.new("ShaderNodeTexNoise")
        noise.location = (-1000, -640)
        _set(noise, "Scale", 3.0 / max(body_length, 1e-6))
        _set(noise, "Detail", 2.0)
        links.new(coord.outputs["Object"], noise.inputs["Vector"])

        wobble = nodes.new("ShaderNodeMath")
        wobble.location = (-800, -640)
        wobble.operation = "MULTIPLY_ADD"
        wobble.inputs[1].default_value = warp
        wobble.inputs[2].default_value = -0.5 * warp
        links.new(noise.outputs["Fac"], wobble.inputs[0])

        self.t = _math(nt, "ADD", position.outputs["Result"], wobble.outputs["Value"],
                       (-620, -400))
        self.h = _math(nt, "ADD", self.height, wobble.outputs["Value"], (-620, 60))
        # Height expressed in body lengths, so an angle in the (t, z) plane is the angle
        # the stripe actually makes on screen rather than one distorted by body depth.
        self.z_norm = _math(nt, "MULTIPLY", separate.outputs["Z"],
                            1.0 / max(body_length, 1e-6), (-820, -60))

    def slot(self, row=-40):
        """Node position for the next marking layer.

        Positions only matter when someone opens the generated .blend by hand, but a
        stack of ten mix nodes at the same coordinate is unreadable when they do.
        """
        self._column += 1
        return (-200 + 180 * self._column, row)


def _confine(nt, flank, mask, t_range=None, h_range=None, fade=0.04, location=(-400, -1000)):
    """Restrict a mask to a span of body position and/or body height."""
    for value, span in ((flank.t, t_range), (flank.h, h_range)):
        if not span:
            continue
        limit = _ramp_node(nt, value, _mask_stops([tuple(span)], fade), location)
        mask = _math(nt, "MULTIPLY", mask, limit, (location[0] + 180, location[1]))
        location = (location[0], location[1] - 200)
    return mask


# -- markings ------------------------------------------------------------------------


def _add_bands(nt, flank, base_color, bands, color, softness, outline_color, outline_width):
    """Vertical bars placed by nose->tail position, each with a darker outline."""
    for group_color, members in _colored_groups(bands, color):
        mask = _ramp_node(nt, flank.t, _band_stops(members, softness), (-420, -200))
        base_color = _mix_color(nt, base_color, mask, group_color, flank.slot())

    if outline_width > 0.0:
        plain = [(float(b[0]), float(b[1])) for b in bands]
        mask = _ramp_node(nt, flank.t, _outline_stops(plain, softness, outline_width),
                          (-420, -560))
        base_color = _mix_color(nt, base_color, mask, outline_color, flank.slot())
    return base_color


def _add_stripes(nt, flank, base_color, stripes, color, softness):
    """Longitudinal stripes placed by body height, 0 at the belly and 1 at the back."""
    for group_color, members in _colored_groups(stripes, color):
        mask = _ramp_node(nt, flank.h, _band_stops(members, softness), (-420, 120))
        base_color = _mix_color(nt, base_color, mask, group_color, flank.slot())
    return base_color


def _add_diagonals(nt, flank, base_color, entries):
    """Parallel stripes ruled across the flank at an angle — the emperor angelfish.

    Angle is measured from the long axis, so 0 rules the body into longitudinal stripes
    and 90 into vertical bars. Spacing and the stripe's own width are in body lengths,
    which keeps a ruling looking the same on a 6cm fish and a 30cm one.
    """
    for params in _as_dicts(entries):
        p = _fields(params, ("color",),
                    dict(angle=25.0, spacing=0.075, width=0.45, softness=0.18,
                         t_range=None, h_range=None),
                    "diagonal_stripes")
        theta = radians(p["angle"])
        spacing = max(float(p["spacing"]), 1e-4)

        along = _math(nt, "MULTIPLY", flank.t, sin(theta), (-620, -760))
        across = _math(nt, "MULTIPLY", flank.z_norm, cos(theta), (-620, -860))
        phase = _math(nt, "ADD", along, across, (-440, -800))
        # WRAP turns the ruling coordinate into one sawtooth per stripe, so a single
        # ramp draws every stripe: the periodicity is in the coordinate, not the ramp.
        cell = nt.nodes.new("ShaderNodeMath")
        cell.location = (-260, -800)
        cell.operation = "WRAP"
        nt.links.new(phase, cell.inputs[0])
        cell.inputs[1].default_value = spacing
        cell.inputs[2].default_value = 0.0
        repeat = _math(nt, "DIVIDE", cell.outputs[0], spacing, (-80, -800))

        half = 0.5 * min(max(float(p["width"]), 0.02), 0.96)
        mask = _ramp_node(nt, repeat, _mask_stops([(0.5 - half, 0.5 + half)],
                                                  half * float(p["softness"]) * 2.0),
                          (100, -800))
        mask = _confine(nt, flank, mask, p["t_range"], p["h_range"], location=(280, -800))
        base_color = _mix_color(nt, base_color, mask, p["color"], flank.slot())
    return base_color


def _spot_mask(nt, vector, cells, size, coverage, softness, seed, location=(-800, -1900)):
    """A mask of round dots — one per Voronoi cell that survives the coverage draw.

    `cells` is cells per unit of the incoming coordinate, `size` the dot radius as a
    fraction of a cell. Scaling all three axes equally is what keeps a dot round; the
    scale texture stretches its cells along the body deliberately, dots must not.
    """
    x, y = location
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.location = (x, y)
    mapping.inputs["Scale"].default_value = (cells, cells, cells)
    # Seeding by translation keeps the pattern deterministic and gives every species its
    # own draw from the same texture.
    mapping.inputs["Location"].default_value = (seed * 13.37, seed * 7.71, seed * 3.13)
    nt.links.new(vector, mapping.inputs["Vector"])

    voronoi = nt.nodes.new("ShaderNodeTexVoronoi")
    voronoi.location = (x + 180, y)
    voronoi.feature = "F1"
    voronoi.distance = "EUCLIDEAN"
    _set(voronoi, "Scale", 1.0)
    _set(voronoi, "Randomness", 1.0)
    nt.links.new(mapping.outputs["Vector"], voronoi.inputs["Vector"])

    radius = max(min(float(size), 0.7), 0.02)
    edge = max(radius * (1.0 - min(max(float(softness), 0.0), 1.0)), 1e-3)
    dot = _ramp_node(nt, voronoi.outputs["Distance"],
                     [(0.0, _WHITE), (edge, _WHITE), (radius, _BLACK), (1.0, _BLACK)],
                     (x + 360, y))

    if coverage >= 1.0:
        return dot
    # The cell colour is a per-cell random; thresholding it thins the pattern out
    # without moving the dots that remain.
    keep = _ramp_node(nt, voronoi.outputs["Color"],
                      _mask_stops([(0.0, float(coverage))], 1e-3), (x + 360, y - 220))
    return _math(nt, "MULTIPLY", dot, keep, (x + 540, y - 110))


def _add_spots(nt, flank, base_color, entries):
    for params in _as_dicts(entries):
        p = _fields(params, ("color",),
                    dict(count=16.0, size=0.34, coverage=0.75, softness=0.35, seed=0.0,
                         t_range=None, h_range=None),
                    "spots")
        mask = _spot_mask(nt, flank.object, float(p["count"]) / max(flank.length, 1e-6),
                          p["size"], p["coverage"], p["softness"], float(p["seed"]))
        mask = _confine(nt, flank, mask, p["t_range"], p["h_range"], location=(-100, -1900))
        base_color = _mix_color(nt, base_color, mask, p["color"], flank.slot())
    return base_color


def _patch_mask(nt, coord, center, radii, softness=0.25, location=(-1000, -900)):
    """A soft-edged mask over an ellipsoidal region of object space.

    Everything placed this way — a mouth, a face mask, a saddle, the tang's paisley — is
    a shading trick rather than geometry. At the size a fish occupies on screen a
    modelled feature is never visible, but a face with nothing on it reads as unfinished
    from every angle.

    The distance is measured in all three axes, so to put the same blotch on both flanks
    give the Y radius something like ten times the body's half-width. Merely exceeding
    the half-width is not enough: the flank's own Y offset still eats into the distance
    budget, and the mark fades to a smudge well inside its stated X and Z extent.
    """
    x, y = location
    nodes, links = nt.nodes, nt.links

    offset = nodes.new("ShaderNodeVectorMath")
    offset.location = (x, y)
    offset.operation = "SUBTRACT"
    offset.inputs[1].default_value = center
    links.new(coord.outputs["Object"], offset.inputs[0])

    normalize = nodes.new("ShaderNodeVectorMath")
    normalize.location = (x + 180, y)
    normalize.operation = "DIVIDE"
    normalize.inputs[1].default_value = radii
    links.new(offset.outputs["Vector"], normalize.inputs[0])

    distance = nodes.new("ShaderNodeVectorMath")
    distance.location = (x + 360, y)
    distance.operation = "LENGTH"
    links.new(normalize.outputs["Vector"], distance.inputs[0])

    mask = _ramp_node(nt, distance.outputs["Value"],
                      [(0.0, _WHITE), (max(0.0, 1.0 - softness), _WHITE), (1.0, _BLACK)],
                      (x + 540, y))
    return mask


def _add_patches(nt, flank, base_color, entries):
    row = -900
    for params in _as_dicts(entries):
        p = _fields(params, ("center", "radii", "color"), dict(softness=0.25), "patches")
        mask = _patch_mask(nt, flank.coord, p["center"], p["radii"], p["softness"],
                           (-1000, row))
        base_color = _mix_color(nt, base_color, mask, p["color"], flank.slot())
        row -= 220
    return base_color


def _add_split(nt, flank, base_color, params):
    """A two-tone body: everything behind `t` takes the second colour.

    `hardness` 1 is a knife edge and 0 blends the two tones across most of the body,
    which is the difference between a gramma and a hawkfish.
    """
    p = _fields(params, ("color",), dict(t=0.5, hardness=0.6), "split")
    fade = (1.0 - min(max(float(p["hardness"]), 0.0), 1.0)) * 0.35
    center = float(p["t"])
    stops = [(max(0.0, min(center - fade, 0.998)), _BLACK),
             (min(1.0, max(center + fade, 0.999)), _WHITE)]
    mask = _ramp_node(nt, flank.t, stops, (-420, 320), interpolation="EASE")
    return _mix_color(nt, base_color, mask, p["color"], flank.slot())


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
    stripes=None,
    stripe_color=(0.94, 0.94, 0.92),
    stripe_softness=0.015,
    diagonal_stripes=None,
    spots=None,
    patches=None,
    split=None,
    mouth=None,
    mouth_color=(0.10, 0.035, 0.025),
    roughness=0.44,
    roughness_variation=0.16,
    mottle=0.12,
    coat=0.03,
    iridescence=0.18,
):
    """Countershaded, scaled skin carrying any combination of markings.

    `body_height` is the half-height of the body in object units; the countershading
    gradient is normalized against it so the same numbers work at any fish size.

    Markings compose in this order, and the order is a design decision rather than the
    order they happened to be written in:

    * `split` first, because a two-tone body is not a marking laid on the skin — it is
      what the skin is behind that point, and everything else has to be able to sit on
      top of it.
    * `stripes`, then `bands`, because where a fish carries both the vertical bar is the
      dominant marking and crosses the longitudinal stripe, not the other way round.
    * `diagonal_stripes` next: a ruling covers the body it rules, but is itself
      interrupted by the deliberate marks below.
    * `spots` next, since dots sit on top of whatever field they are scattered over —
      the Banggai cardinal's white flecks fall across its black bars.
    * `patches` last, because they are placed by hand for a reason: a face mask or a
      saddle is meant to cover whatever is underneath it.
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coord = nodes.new("ShaderNodeTexCoord")
    coord.location = (-1200, 0)
    flank = _Flank(nt, coord, body_length, body_height)

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
    links.new(flank.height, shading.inputs["Fac"])

    base_color = shading.outputs["Color"]

    if split:
        base_color = _add_split(nt, flank, base_color, split)
    if stripes:
        base_color = _add_stripes(nt, flank, base_color, stripes, stripe_color,
                                  stripe_softness)
    if bands:
        base_color = _add_bands(nt, flank, base_color, bands, band_color, band_softness,
                                outline_color, outline_width)
    if diagonal_stripes:
        base_color = _add_diagonals(nt, flank, base_color, diagonal_stripes)
    if spots:
        base_color = _add_spots(nt, flank, base_color, spots)
    if patches:
        base_color = _add_patches(nt, flank, base_color, patches)
    if mouth:
        center, radii = mouth
        mask = _patch_mask(nt, coord, center, radii, location=(-1000, -680))
        base_color = _mix_color(nt, base_color, mask, mouth_color, flank.slot())

    if mottle > 0.0:
        # Low-frequency tonal drift. A perfectly even albedo is one of the strongest
        # cues that a surface is moulded plastic rather than a living animal.
        mottle_noise = nodes.new("ShaderNodeTexNoise")
        mottle_noise.location = (-1000, -1180)
        _set(mottle_noise, "Scale", 7.0 / max(body_length, 1e-6))
        _set(mottle_noise, "Detail", 6.0)
        _set(mottle_noise, "Roughness", 0.6)
        links.new(coord.outputs["Object"], mottle_noise.inputs["Vector"])

        shade = 1.0 - mottle
        base_color = _mix_color(nt, base_color, mottle_noise.outputs["Fac"],
                                (shade, shade * 0.97, shade * 0.94), (320, -300),
                                blend="MULTIPLY")

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

    sheen = _mix_color(nt, base_color, fresnel.outputs["Fresnel"],
                       (0.35 * iridescence, 0.55 * iridescence, 0.75 * iridescence),
                       (200, 260), blend="SCREEN")

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

    rough_total = _math(nt, "ADD", rough_range.outputs["Result"], groove.outputs["Result"],
                        (-600, -1600), clamp=True)

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (620, 60)
    _set(bsdf, "Specular IOR Level", 0.42)
    # A coat is a clear lacquer layer; on a fish it is the single biggest contributor to
    # a plastic look, so it is only a trace here rather than a proper wet layer.
    _set(bsdf, "Coat Weight", coat)
    _set(bsdf, "Coat Roughness", 0.28)
    links.new(rough_total, bsdf.inputs["Roughness"])
    # Subsurface radius is in metres. Left at a human-skin default it exceeded the whole
    # animal, bleeding light through the body and desaturating it to salmon; tie it to
    # the model's own size so a fish stays the colour it was given.
    _set(bsdf, "Subsurface Weight", 0.10)
    _set(bsdf, "Subsurface Radius",
         (body_length * 0.020, body_length * 0.012, body_length * 0.008))
    links.new(sheen, bsdf.inputs["Base Color"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (460, 60)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    return mat


def fin_material(name, color, tip_color=None, edge_color=None, edge_width=0.10,
                 opacity=0.92, spots=None, ray_count=26.0, ray_contrast=0.5,
                 roughness=0.52, translucency=0.08):
    """A fin membrane: root-to-tip gradient, bright margin, fin rays, optional spots.

    Colour is driven by the fin's own UV, whose V runs 0 at the root to 1 at the
    trailing edge and whose U runs along the attachment. Object space cannot do this
    job: a fin's outward direction differs per fin (up for the dorsal, down for the
    anal, backwards for the caudal, sideways for the paired fins) and the parts are
    later joined into one mesh, so there is no per-fin origin left to measure from. The
    UV is written by the same grid that builds the membrane, travels through solidify
    and subdivision, and survives the join because every part writes into one layer.

    Fins were previously pale and half transparent, which made a tall dorsal disappear
    against the body. A reef fish's fins are part of the animal: mostly opaque, with the
    membrane thinning only at the very edge.
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.blend_method = "BLEND"
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coord = nodes.new("ShaderNodeTexCoord")
    coord.location = (-1100, 0)

    uv = nodes.new("ShaderNodeSeparateXYZ")
    uv.location = (-920, 0)
    links.new(coord.outputs["UV"], uv.inputs["Vector"])
    along, out = uv.outputs["X"], uv.outputs["Y"]

    # Rays run root to tip, so they are bands across U. The wave texture's scale is in
    # cycles per 2*pi/20 of input, and U spans exactly 0..1, so convert from a ray count.
    rays = nodes.new("ShaderNodeTexWave")
    rays.location = (-740, -220)
    rays.wave_type = "BANDS"
    rays.bands_direction = "X"
    rays.wave_profile = "SIN"
    _set(rays, "Scale", ray_count * pi / 20.0)
    _set(rays, "Distortion", 0.8)
    _set(rays, "Detail", 1.0)
    links.new(coord.outputs["UV"], rays.inputs["Vector"])

    lo = 1.0 - 0.35 * ray_contrast
    ray_shade = _ramp_node(nt, rays.outputs["Fac"],
                           [(0.0, (lo, lo, lo, 1.0)), (1.0, _WHITE)], (-540, -220))

    membrane = _ramp_node(nt, out,
                          [(0.0, (*color, 1.0)),
                           (1.0, (*(tip_color or color), 1.0))],
                          (-540, 160), interpolation="EASE")

    base_color = nodes.new("ShaderNodeMix")
    base_color.location = (-300, 60)
    base_color.data_type = "RGBA"
    base_color.blend_type = "MULTIPLY"
    base_color.inputs["Factor"].default_value = 1.0
    links.new(membrane, base_color.inputs[6])
    links.new(ray_shade, base_color.inputs[7])
    color_out = base_color.outputs[2]

    if edge_color and edge_width > 0.0:
        width = min(max(float(edge_width), 0.01), 0.9)
        margin = _ramp_node(nt, out, _mask_stops([(1.0 - width, 1.0)], width * 0.35),
                            (-540, -520))
        color_out = _mix_color(nt, color_out, margin, edge_color, (-120, 60))

    if spots:
        for params in _as_dicts(spots):
            p = _fields(params, ("color",),
                        dict(count=7.0, size=0.34, coverage=0.8, softness=0.4, seed=0.0),
                        "fin spots")
            mask = _spot_mask(nt, coord.outputs["UV"], float(p["count"]), p["size"],
                              p["coverage"], p["softness"], float(p["seed"]),
                              location=(-900, -900))
            color_out = _mix_color(nt, color_out, mask, p["color"], (60, 60))

    # Opaque membrane that thins only over the last tenth, so the trailing edge softens
    # into the water instead of ending on a cut line.
    thinning = _ramp_node(nt, out,
                          [(0.0, _WHITE), (0.90, _WHITE), (1.0, (0.25, 0.25, 0.25, 1.0))],
                          (-540, -760))
    alpha = _math(nt, "MULTIPLY", thinning, opacity, (-300, -760))
    alpha = _math(nt, "MULTIPLY", alpha, ray_shade, (-120, -760), clamp=True)

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (300, 60)
    _set(bsdf, "Roughness", roughness)
    _set(bsdf, "Specular IOR Level", 0.35)
    _set(bsdf, "Transmission Weight", translucency)
    _set(bsdf, "IOR", 1.33)
    links.new(color_out, bsdf.inputs["Base Color"])
    links.new(alpha, bsdf.inputs["Alpha"])

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (620, 60)
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
