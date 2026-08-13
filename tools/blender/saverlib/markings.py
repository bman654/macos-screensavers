"""The marking vocabulary a fish's skin is painted with, and the shader-node plumbing
underneath it.

Split out of `materials.py`, which had grown past the point where one file was still
comfortable to work in. The seam is the natural one: this module knows how to turn a
handful of numbers into a mask over a body, and `materials.py` knows how to assemble
those masks — plus countershading, scales, roughness and a BSDF — into a material.
Nothing here creates a material or reaches for one.

The low-level node helpers (`_set`, `_ramp`, `_math`, `_mix_color`, ...) live here rather
than in `materials.py` so the dependency runs one way: markings never import materials.
They stay importable from `materials` as well, which is where `surfaces.py` gets them.

Everything is generated from shader nodes in object space rather than painted onto a UV
map. That keeps a species definition to a handful of numbers, lets one material serve a
whole school with per-object colour variation, and avoids shipping texture images.

The vocabulary — bands, stripes, diagonal stripes, spots, patches, an eye ring and a
two-tone split — is picked from and placed explicitly by a species. Explicit placement
rather than a tuned periodic frequency is the load-bearing decision here: real markings
sit at particular places on an animal and do not repeat, so landing three bars correctly
by adjusting a wave frequency is guesswork. The one marking that is genuinely periodic on
the animal, the angelfish's diagonal ruling, is the one marking specified by spacing.

Node socket names moved around in Blender 4.0 (Specular -> Specular IOR Level, and so
on), so inputs are set through `_set` which ignores names the current build does not
have.
"""

from math import cos, radians, sin

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


# Blender's ColorBand is a fixed-size array of 32 elements and `elements.new()` silently
# fails past it, so a ramp that overflows draws a mangled pattern rather than raising.
MAX_RAMP_STOPS = 32


def _ramp(node, stops):
    """Overwrite a ColorRamp's elements with (position, rgba) stops.

    At most `MAX_RAMP_STOPS` of them: see the ceiling arithmetic in `_mask_stops`.
    """
    if len(stops) > MAX_RAMP_STOPS:
        raise ValueError(
            f"a ColorRamp holds at most {MAX_RAMP_STOPS} stops and this one needs "
            f"{len(stops)}. A marking spends 4 stops per interval plus 2, and "
            f"`outline_width` turns every band into two intervals — so one ramp holds "
            f"about 7 plain bands or 3 outlined ones. Split the marking into two "
            f"entries with different colours (each colour is drawn by its own ramp), "
            f"or drop the outline and paint the dark edge as a wider band underneath."
        )
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

    `fade` is spent *outside* the interval, not inside it: the mask is fully on across
    the whole stated interval and then falls off over `fade` at each end. So a marking
    covers more of the body than its stated width, and the softer it is the more. For a
    proportional fade — `diagonal_stripes`, whose `softness` is a fraction of its own
    width — that means the coloured fraction is `width * (1 + softness * 2)`.

    Ceiling: this emits `4 * len(intervals) + 2` stops before collisions are cleaned up,
    against Blender's hard limit of `MAX_RAMP_STOPS` (32) elements per ramp. That is
    about 7 intervals. `_outline_stops` emits two intervals per band, so an outlined
    marking runs out at about 3 bands. Overflow raises from `_ramp`.
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

    **A positive angle rises towards the tail**; a negative one falls towards the tail.
    This is stated because it is not derivable from the phase expression below without
    getting the nose->tail sense of `t` right, and both signs render perfectly — the
    only symptom of the wrong one is a fish whose ruling runs the wrong way, which is
    easy to look straight past. `marking_swatches.py` carries a +40/-40 pair.

    `width` is the fraction of each repeat the stripe covers, but the `softness` fade is
    spent outside that interval (see `_mask_stops`), so the fraction actually carrying
    colour is `width * (1 + softness * 2)`. At the default softness of 0.18 a nominal
    width of 0.48 covers 0.65 of every repeat, which is a coloured fish with dark
    pinstripes rather than the reverse.
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


def _add_eye_ring(nt, flank, base_color, params, body_length):
    """An annulus of skin around the eye socket — a lid ring, not part of the eyeball.

    Built as a large patch with a smaller one subtracted from it, and placed on the
    centreline with a Y radius large enough to be a pure (x, z) annulus, so the one mask
    lands on both flanks. `radius` is the eye's own radius: the ring starts where the
    eyeball ends and reaches `radius * (1 + width)`.

    A ring is worth having as its own marking rather than two hand-placed `patches`
    because the eye's position is already a species field — the caller can derive the
    whole thing from `Species.eye` and never repeat those numbers.
    """
    p = _fields(params, ("center", "radius", "color"),
                dict(width=0.55, softness=0.45), "eye_ring")
    radius = float(p["radius"])
    outer = radius * (1.0 + max(float(p["width"]), 1e-3))
    center = (float(p["center"][0]), 0.0, float(p["center"][2]))
    span = (outer, body_length, outer)

    disc = _patch_mask(nt, flank.coord, center, span, float(p["softness"]),
                       (-1000, -1400))
    # The hole is the eyeball's own footprint, kept hard-edged: a soft inner edge leaves
    # a wash of ring colour across the eye rather than a ring around it.
    hole = _patch_mask(nt, flank.coord, center, (radius, body_length, radius), 0.12,
                       (-1000, -1620))
    mask = _math(nt, "SUBTRACT", disc, hole, (-420, -1500), clamp=True)
    return _mix_color(nt, base_color, mask, p["color"], flank.slot())


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
