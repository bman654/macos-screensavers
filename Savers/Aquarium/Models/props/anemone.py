"""A bubble-tip sea anemone (*Entacmaea quadricolor*) — the clownfish's host.

The column is a lathe and is barely seen; the model is its crown. Nearly two hundred
swept tubes radiate from a domed oral disc, each one bulging into a rounded bulb before
its tip, because that bulb is what names the species and what separates it at a glance
from every other blob of soft tissue on a reef.

Two things here are not obvious:

* **Colour runs along each tentacle, not through object space.** A tan-to-magenta
  gradient has to know how far along its own tentacle a point is, and once every tube is
  joined into one mesh there is nothing in object space that answers that. Each tentacle
  therefore bakes its own normalized arc position into a per-vertex attribute, which
  survives the join and drives the ramp directly.
* **The material is local.** `surfaces.py` has stone, bone, wood, metal, sand and glass;
  an anemone is none of those. See `_tissue_material`.
"""

import math
import random

import bpy
from mathutils import Vector

from saverlib import BranchingResult, Profile, SweptTube, assign, displace, revolve

from ._spec import Prop

# Baked per-vertex, read by `_tissue_material`: 0 at a tentacle's root, 1 at its tip.
_ARC = "tentacle_t"

# The oral disc is deliberately small against the finished crown — roughly a third of
# it. A wide disc spreads the tentacle roots out into a shallow dish that reads as a
# dahlia; a narrow one makes them overlap, which is what hides the disc and gives the
# mounded silhouette the animal actually has.
_DISC_RADIUS = 0.040
_COLUMN_TOP = 0.066      # height of the oral disc's outer margin
_DOME = 0.012            # how far the disc's centre rises above that margin
_TENTACLES = 180

# A tentacle starts this far inside the disc. The disc is displaced after the attachment
# points are computed, so the burial has to exceed the displacement or roots pop out.
_BURIAL = 0.010


def build(seed=0):
    rng = random.Random(seed * 7717 + 3)

    root = bpy.data.objects.new("decor_anemone", None)
    bpy.context.collection.objects.link(root)

    material = _tissue_material(
        f"anemone_{seed}",
        # The stalk is deliberately dark. Lit tan reads as a bundle of bright sticks with
        # buds on them; keeping it low lets the bulbs be the only bright thing, which is
        # what makes the crown read as a mass rather than as a bouquet.
        base=(0.072, 0.038, 0.026),
        mid=(0.215, 0.070, 0.062),
        tip=(0.575, 0.060, 0.205),
        thickness=0.0040,
        seed=seed,
    )

    column = _build_column(seed)
    crown = _build_crown(rng)
    for part in (column, crown):
        assign(part, material)
        part.parent = root

    # `build_prop` frames and floors the model from world-space bounds, and a matrix is
    # only evaluated lazily — without this every part still reads as sitting at the origin.
    bpy.context.view_layer.update()
    return root


# -- geometry ------------------------------------------------------------------------


def _disc_height(radius):
    """Height of the oral disc at a given distance from the axis."""
    u = min(1.0, radius / _DISC_RADIUS)
    return _COLUMN_TOP + _DOME * (1.0 - u * u)


def _build_column(seed):
    """The foot: a squat, slightly waisted cylinder opening into the domed oral disc.

    The dome is sampled from `_disc_height` rather than written out as its own control
    points, so the lathe and the tentacle attachment points can never drift apart.
    """
    outline = [
        (0.042, 0.000),     # pedal disc, spread where it grips the rock
        (0.036, 0.010),
        (0.030, 0.028),
        (0.032, 0.046),
        (0.037, 0.058),
        (_DISC_RADIUS, _COLUMN_TOP),
    ] + [
        (_DISC_RADIUS * u, _disc_height(_DISC_RADIUS * u))
        for u in (0.82, 0.58, 0.30, 0.0)
    ]

    column = revolve("anemone_column", outline, segments=32, rings=22)
    # A lathe is perfectly circular from above, which no living column is. The noise is
    # kept small: it also moves the attachment surface out from under the tentacles.
    displace(column, strength=0.040, feature_size=0.70, octaves=3, seed=seed * 31 + 5)
    _bake_arc(column, [0.0] * len(column.data.vertices))
    return column


def _build_crown(rng):
    """Every tentacle, built and joined into one mesh."""
    tubes = []
    for index in range(_TENTACLES):
        tube = _build_tentacle(index, rng)
        obj = tube.build(f"anemone_tentacle_{index:03d}", subsurf=0)
        _bake_arc(obj, _arc_positions(tube, obj.data))
        tubes.append(tube)

    # `subsurf=0` above is what makes this cheap: with no modifier stack to evaluate,
    # joining is a straight mesh concatenation and the baked attribute passes through.
    return BranchingResult(tubes).join(name="anemone_crown", bake_modifiers=False)


def _build_tentacle(index, rng):
    """One tapering finger with a bulb near its tip.

    Attachment points come from a golden-angle spiral, which fills the disc at even
    density without the radial spokes that concentric whorls produce. Every position,
    angle, length and curl is then jittered: a crown whose tentacles agree on anything
    reads as a shuttlecock rather than as an animal.
    """
    u = (index + 0.5) / _TENTACLES
    # `sqrt` is the equal-area map, so density is even across the disc. Biasing outward
    # thins the centre, and a bald patch at the mouth is the one place the disc shows.
    radius = _DISC_RADIUS * math.sqrt(u) * rng.uniform(0.86, 1.12)
    radius = min(radius, _DISC_RADIUS * 1.02)
    azimuth = index * math.pi * (3.0 - math.sqrt(5.0)) + rng.uniform(-0.24, 0.24)

    outward = Vector((math.cos(azimuth), math.sin(azimuth), 0.0))
    sideways = Vector((0.0, 0.0, 1.0)).cross(outward)
    anchor = outward * radius + Vector((0.0, 0.0, _disc_height(radius)))

    # Splay grows with distance from the mouth: the centre of the crown stands up, the
    # margin lies over past horizontal and drapes down across the column, and that
    # spread is most of the silhouette.
    margin = radius / _DISC_RADIUS
    tilt = math.radians(9.0 + 68.0 * margin + rng.uniform(-11.0, 11.0))
    heading = outward * math.sin(tilt) + Vector((0.0, 0.0, math.cos(tilt)))

    length = rng.uniform(0.044, 0.078)
    curl = rng.uniform(0.20, 0.44)
    droop = rng.uniform(0.15, 0.35) + 0.45 * margin
    lean = rng.uniform(-0.32, 0.32)

    def path(t):
        return (
            anchor
            - heading * _BURIAL
            + heading * (length * t)
            + outward * (length * curl * t * t)
            + Vector((0.0, 0.0, -length * droop * t * t))
            + sideways * (length * lean * t * t)
        )

    # The bulb sits close to the end and the taper past it is short. Placing it further
    # down, or letting the terminal point run over the last quarter of the tentacle,
    # turns every tentacle into a cone with a lump on it — a pincushion, not a bubble tip.
    stalk = rng.uniform(0.0029, 0.0042)
    bulb_at = rng.uniform(0.84, 0.92)
    # A wide range on purpose: not every tentacle on a real colony is inflated, and a
    # crown where all 180 bulbs match reads as a manufactured part.
    bulb = rng.uniform(1.50, 2.65)
    return SweptTube(
        path,
        Profile([
            (0.00, stalk * 0.60),
            (0.14, stalk * 1.00),
            (0.55, stalk * 0.84),
            (bulb_at - 0.12, stalk * 0.80),
            (bulb_at, stalk * bulb),
            # Without this shoulder the fall-off from bulb to point is one straight cone
            # spanning a single ring, and every tentacle ends in a flat chisel facet.
            (bulb_at + (1.0 - bulb_at) * 0.45, stalk * bulb * 0.60),
            (1.00, stalk * 0.30),
        ]),
        # Rings are spread evenly over the whole tentacle but all the shape is in its
        # last quarter, so the count is set by the bulb rather than by the stalk: at 12
        # rings the spacing straddles the bulb's peak and every tip comes out chopped
        # flat. Segments pay for the cross-section, which at a 4 mm radius nobody sees,
        # so the budget goes to rings.
        rings=18,
        segments=7,
        # Flat where it is buried in the disc, rounded at the tip so the point is a point
        # rather than a cut-off stub.
        rounded_caps=(False, True),
        cap_rings=3,
    )


def _arc_positions(tube, mesh):
    """Normalized position along the tentacle for every vertex of its mesh.

    Measured by projecting onto the tube's own resampled path rather than by counting
    rings: the ring order is `tube.py`'s private business, and rounded caps add rings at
    one end only.
    """
    points = tube.points
    spans = len(points) - 1
    values = []
    for vertex in mesh.vertices:
        co = vertex.co
        best, nearest = 0.0, float("inf")
        for i in range(spans):
            start = points[i]
            edge = points[i + 1] - start
            offset = co - start
            step = min(1.0, max(0.0, offset.dot(edge) / edge.length_squared))
            distance = (offset - edge * step).length_squared
            if distance < nearest:
                nearest, best = distance, (i + step) / spans
        values.append(best)
    return values


def _bake_arc(obj, values):
    attribute = obj.data.attributes.new(_ARC, "FLOAT", "POINT")
    attribute.data.foreach_set("value", values)


# -- material ------------------------------------------------------------------------


def _tissue_material(name, base, mid, tip, thickness, seed=0):
    """Soft, wet, faintly translucent animal tissue with a tip colour.

    Local to this prop because `surfaces.py` deliberately carries no soft-tissue
    material, and none of the six it does carry can be bent into one: they are all built
    around mineral speckle, grain or corrosion, they are all opaque, and every one of
    them ends in `_biofilm`, which is exactly wrong here — an anemone stings and sloughs
    its own overgrowth, and a slick of algae over the crown would be the one thing that
    says "rock painted pink".

    What it needs that they do not have: a base-to-tip colour ramp driven by the baked
    arc attribute, subsurface scattering at a radius set by the tentacle's *thickness*
    rather than its length, and a low roughness with a trace of clear coat, because the
    single strongest cue that this is flesh and not stone is that it is wet.
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coord = nodes.new("ShaderNodeTexCoord")
    coord.location = (-1100, -260)

    arc = nodes.new("ShaderNodeAttribute")
    arc.location = (-1100, 200)
    arc.attribute_name = _ARC

    # The tip colour is confined to the bulb and beyond. Spreading it further down turns
    # the animal into one flat magenta mop and loses the contrast that is the point.
    gradient = nodes.new("ShaderNodeValToRGB")
    gradient.location = (-900, 200)
    _stops(gradient, [
        (0.00, base), (0.52, base), (0.74, mid), (0.88, tip), (1.00, tip),
    ])
    gradient.color_ramp.interpolation = "EASE"
    links.new(arc.outputs["Fac"], gradient.inputs["Fac"])

    # Tonal drift, for the usual reason: an even albedo is what moulded plastic looks
    # like. Object-space here is right — the blotching belongs to the animal, not to a
    # position along a tentacle.
    mottle = nodes.new("ShaderNodeTexNoise")
    mottle.location = (-1100, -520)
    mottle.inputs["Scale"].default_value = 34.0
    mottle.inputs["Detail"].default_value = 5.0
    mottle.inputs["Roughness"].default_value = 0.6
    links.new(coord.outputs["Object"], mottle.inputs["Vector"])

    shade = nodes.new("ShaderNodeMix")
    shade.location = (-600, 60)
    shade.data_type = "RGBA"
    shade.blend_type = "MULTIPLY"
    shade.inputs[0].default_value = 0.22
    links.new(gradient.outputs["Color"], shade.inputs[6])
    links.new(mottle.outputs["Fac"], shade.inputs[7])

    # Fine relief. Anemone tissue is not smooth rubber; it is finely pebbled, and the
    # bump is what stops the highlight sliding over it as one unbroken sheet.
    pebble = nodes.new("ShaderNodeTexNoise")
    pebble.location = (-1100, -800)
    pebble.inputs["Scale"].default_value = 190.0 + (seed % 7) * 11.0
    pebble.inputs["Detail"].default_value = 4.0
    links.new(coord.outputs["Object"], pebble.inputs["Vector"])

    bump = nodes.new("ShaderNodeBump")
    bump.location = (-600, -800)
    bump.inputs["Strength"].default_value = 0.22
    bump.inputs["Distance"].default_value = thickness * 0.10
    links.new(pebble.outputs["Fac"], bump.inputs["Height"])

    rough = nodes.new("ShaderNodeMapRange")
    rough.location = (-600, -520)
    rough.inputs["To Min"].default_value = 0.22
    rough.inputs["To Max"].default_value = 0.40
    links.new(mottle.outputs["Fac"], rough.inputs["Value"])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (-260, 0)
    links.new(shade.outputs[2], bsdf.inputs["Base Color"])
    links.new(rough.outputs["Result"], bsdf.inputs["Roughness"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Specular IOR Level"].default_value = 0.48
    bsdf.inputs["Coat Weight"].default_value = 0.06
    bsdf.inputs["Coat Roughness"].default_value = 0.14
    # The radius is set from the tentacle's thickness, not its length: light crosses a
    # 4 mm finger, and a radius scaled to the 60 mm it is long would bleed straight
    # through and leave a uniform pastel worm.
    bsdf.inputs["Subsurface Weight"].default_value = 0.45
    bsdf.inputs["Subsurface Radius"].default_value = (
        thickness * 1.05, thickness * 0.62, thickness * 0.48,
    )

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (40, 0)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    return mat


def _stops(node, stops):
    elements = node.color_ramp.elements
    while len(elements) > 1:
        elements.remove(elements[-1])
    elements[0].position, elements[0].color = stops[0][0], (*stops[0][1], 1.0)
    for position, color in stops[1:]:
        elements.new(position).color = (*color, 1.0)


ANEMONE = Prop(
    name="anemone",
    build=build,
    category="coral",
    footprint=0.14,
    height=0.13,
    tilt_range=(-7.0, 7.0),
    scale_range=(0.70, 1.30),
    weight=1.1,
    max_per_scene=3,
    # Anemones clear the substrate around themselves with their own stinging cells, so
    # two of them never sit shoulder to shoulder the way a stand of coral does.
    min_spacing=0.46,
    seeds=3,
)
