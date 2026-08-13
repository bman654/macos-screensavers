"""Procedural materials for non-organic props: wood, metal, bone, stone, glass, sand.

Same approach as `materials.py` — everything is generated from shader nodes in object
space, so a prop is a handful of numbers rather than a texture set — and the same lesson
applies with more force here than it did on a fish: *an even albedo with one constant
roughness is what moulded plastic looks like*. Every material below therefore carries at
least three sources of variation: a low-frequency tonal drift, a high-frequency breakup,
and a roughness that is never a single number.

These props are all meant to have been underwater for a long time, so each material takes
an `algae` amount and none of them is ever seen clean.

Note the two different answers to "what size is a texture feature?". Wood grain and
seabed ripples have a real physical size (millimetres, centimetres) that does not depend
on how big the prop is, so they are specified in metres and the model must be built at
real scale. Rock mottling and biofilm patches are specified as counts across the model's
own `size`, because the same function has to serve a 2 cm pebble and a 2 m boulder and
both have to read as stone on a screen where the prop is 200 pixels tall. Getting this
backwards is the units trap from the fish spike, in both directions.
"""

import bpy

# Deliberately shared rather than re-implemented: these are the two node helpers that
# every material in this package needs, and a second private copy would drift.
from .materials import _ramp, _set

# Metal starting points, so callers name a colour instead of inventing one.
BRASS = (0.62, 0.42, 0.13)
COPPER = (0.55, 0.28, 0.14)
STEEL = (0.40, 0.42, 0.45)
IRON = (0.26, 0.25, 0.24)

# Corrosion products. These are linear values and look darker written down than they
# render: anything lighter than this reads as terracotta and mint rather than as rust
# and verdigris once a key light is on it.
RUST = (0.135, 0.048, 0.016)
VERDIGRIS = (0.048, 0.145, 0.115)
TARNISH = (0.055, 0.046, 0.032)


# -- node plumbing -------------------------------------------------------------------
#
# `ShaderNodeMix` has four A/B socket pairs stacked in one node (float, vector, colour,
# rotation) and they all share the names "A" and "B", so a name lookup returns whichever
# comes first. Indices are the only unambiguous way to address them; these wrappers keep
# the magic numbers in one place instead of scattered through six materials.

_MIX_FLOAT_A, _MIX_FLOAT_B = 2, 3
_MIX_COLOR_A, _MIX_COLOR_B = 6, 7
_MIX_OUT_FLOAT, _MIX_OUT_COLOR = 0, 2


def _material(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.node_tree.nodes.clear()
    return mat, mat.node_tree


def _new(nt, kind, loc):
    node = nt.nodes.new(kind)
    node.location = loc
    return node


def _rgba(color):
    return (color[0], color[1], color[2], 1.0)


def _mix_rgb(nt, loc, factor, a, b, blend="MIX"):
    """Mix two colours; `a` and `b` may each be a socket or an RGB tuple."""
    node = _new(nt, "ShaderNodeMix", loc)
    node.data_type = "RGBA"
    node.blend_type = blend
    node.clamp_factor = True
    _connect(nt, factor, node.inputs[0], scalar=True)
    for value, index in ((a, _MIX_COLOR_A), (b, _MIX_COLOR_B)):
        _connect(nt, value, node.inputs[index])
    return node.outputs[_MIX_OUT_COLOR]


def _mix_value(nt, loc, factor, a, b):
    node = _new(nt, "ShaderNodeMix", loc)
    node.data_type = "FLOAT"
    node.clamp_factor = True
    _connect(nt, factor, node.inputs[0], scalar=True)
    for value, index in ((a, _MIX_FLOAT_A), (b, _MIX_FLOAT_B)):
        _connect(nt, value, node.inputs[index], scalar=True)
    return node.outputs[_MIX_OUT_FLOAT]


def _connect(nt, value, socket, scalar=False):
    if hasattr(value, "is_linked"):
        nt.links.new(value, socket)
    elif scalar:
        socket.default_value = value
    else:
        socket.default_value = _rgba(value)


def _math(nt, loc, operation, a, b=None, clamp=False):
    node = _new(nt, "ShaderNodeMath", loc)
    node.operation = operation
    node.use_clamp = clamp
    _connect(nt, a, node.inputs[0], scalar=True)
    if b is not None:
        _connect(nt, b, node.inputs[1], scalar=True)
    return node.outputs["Value"]


def _range(nt, loc, value, from_min, from_max, to_min, to_max):
    node = _new(nt, "ShaderNodeMapRange", loc)
    node.clamp = True
    _connect(nt, value, node.inputs["Value"], scalar=True)
    for socket, amount in (("From Min", from_min), ("From Max", from_max),
                           ("To Min", to_min), ("To Max", to_max)):
        _set(node, socket, amount)
    return node.outputs["Result"]


def _mapped(nt, loc, coord, scale, offset=(0.0, 0.0, 0.0)):
    """Object coordinates scaled per axis, with a seed offset.

    Frequency goes here rather than into the texture's own Scale input because a stretched
    scale (long grain, flattened ripples) needs three different numbers, and because an
    offset is the only way to make two textures with the same frequency differ.
    """
    node = _new(nt, "ShaderNodeMapping", loc)
    node.inputs["Location"].default_value = offset
    node.inputs["Scale"].default_value = scale
    nt.links.new(coord.outputs["Object"], node.inputs["Vector"])
    return node.outputs["Vector"]


def _noise(nt, loc, vector, detail=6.0, roughness=0.5, distortion=0.0, scale=1.0):
    node = _new(nt, "ShaderNodeTexNoise", loc)
    _set(node, "Scale", scale)
    _set(node, "Detail", detail)
    _set(node, "Roughness", roughness)
    _set(node, "Distortion", distortion)
    nt.links.new(vector, node.inputs["Vector"])
    return node


def _voronoi(nt, loc, vector, randomness=0.85, feature="F1"):
    node = _new(nt, "ShaderNodeTexVoronoi", loc)
    node.feature = feature
    _set(node, "Scale", 1.0)
    _set(node, "Randomness", randomness)
    nt.links.new(vector, node.inputs["Vector"])
    return node


def _seed_offset(seed):
    """Turn an integer seed into a texture-space offset."""
    return ((seed * 12.9898) % 97.0, (seed * 78.233) % 89.0, (seed * 37.719) % 83.0)


def _add(nt, loc, a, b):
    return _math(nt, loc, "ADD", a, b)


def _principled(nt, base_color, roughness, height=None, bump_distance=0.002,
                bump_strength=0.6, metallic=0.0, specular=0.5, extras=None):
    """Wire a Principled BSDF and the material output.

    `extras` values may be a socket, a number or a tuple, so a caller can either drive an
    input procedurally or set it flat without caring which.
    """
    bsdf = _new(nt, "ShaderNodeBsdfPrincipled", (620, 0))
    _connect(nt, base_color, bsdf.inputs["Base Color"])
    _connect(nt, roughness, bsdf.inputs["Roughness"], scalar=True)
    _connect(nt, metallic, bsdf.inputs["Metallic"], scalar=True)
    _connect(nt, specular, bsdf.inputs["Specular IOR Level"], scalar=True)
    for name, value in (extras or {}).items():
        socket = bsdf.inputs.get(name)
        if socket is None:
            continue
        if hasattr(value, "is_linked"):
            nt.links.new(value, socket)
        else:
            socket.default_value = value

    if height is not None:
        bump = _new(nt, "ShaderNodeBump", (420, -420))
        _set(bump, "Strength", bump_strength)
        _set(bump, "Distance", bump_distance)
        nt.links.new(height, bump.inputs["Height"])
        nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    output = _new(nt, "ShaderNodeOutputMaterial", (860, 0))
    nt.links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    return bsdf


# -- biofilm -------------------------------------------------------------------------


def _biofilm(nt, coord, color, roughness, height, amount, size, seed=0,
             dark=(0.035, 0.075, 0.030), pale=(0.115, 0.130, 0.055)):
    """Layer algae and settled silt over whatever the substrate is.

    One shared helper called from every material, rather than a per-material
    implementation or a standalone "algae material", for three reasons:

    * biofilm is substrate-independent — the same slick of diatoms and filamentous green
      grows on oak, brass, bone and glass — so one implementation means one place to tune
      how colonised the whole tank looks, and every prop stays consistent with the rest;
    * it has to be the *last* thing in a material's colour chain and must also override
      roughness and contribute its own bump. A wrapper applied to a finished material
      would have to unpick and re-plumb links it does not own, which the node API makes
      both verbose and fragile;
    * doing it with geometry instead — a second shell mesh per prop — would multiply the
      poly budget of every object in the tank for something the camera never sees the
      silhouette of.

    The mask is driven by the *world* normal's Z, so growth lands on upward faces and
    undersides stay bare. That is the single cue that makes overgrowth look grown rather
    than painted, and it needs no per-object tuning to work.
    """
    if amount <= 0.0:
        return color, roughness, height

    geometry = _new(nt, "ShaderNodeNewGeometry", (-1500, -1150))
    axis = _new(nt, "ShaderNodeSeparateXYZ", (-1320, -1150))
    nt.links.new(geometry.outputs["Normal"], axis.inputs["Vector"])
    up = _range(nt, (-1140, -1150), axis.outputs["Z"], -0.35, 0.75, 0.0, 1.0)

    frequency = 4.5 / max(size, 1e-6)
    patch_uv = _mapped(nt, (-1500, -1400), coord, (frequency,) * 3, _seed_offset(seed + 7))
    patches = _noise(nt, (-1320, -1400), patch_uv, detail=6.0, roughness=0.62)

    # Slide the threshold rather than fading the whole layer up: real colonisation
    # spreads outward from patches, it does not appear everywhere at once and get greener.
    centre = 0.74 - 0.52 * amount
    coverage = _range(nt, (-1140, -1400), patches.outputs["Fac"],
                      centre - 0.16, centre + 0.16, 0.0, 1.0)

    mask = _math(nt, (-940, -1250), "MULTIPLY", up, coverage)
    mask = _math(nt, (-760, -1250), "MULTIPLY", mask, min(1.0, amount * 1.8), clamp=True)

    fuzz_uv = _mapped(nt, (-1500, -1650), coord, (26.0 / max(size, 1e-6),) * 3,
                      _seed_offset(seed + 23))
    fuzz = _noise(nt, (-1320, -1650), fuzz_uv, detail=7.0, roughness=0.75)

    tint = _mix_rgb(nt, (-560, -1400), patches.outputs["Fac"], dark, pale)
    color = _mix_rgb(nt, (-360, -1250), mask, color, tint)
    roughness = _mix_value(nt, (-360, -1450), mask, roughness, 0.94)

    relief = _math(nt, (-940, -1650), "MULTIPLY", fuzz.outputs["Fac"], mask)
    height = relief if height is None else _add(nt, (-760, -1650), height, relief)
    return color, roughness, height


# -- materials -----------------------------------------------------------------------


def wood_material(name, size=0.6, light=(0.128, 0.070, 0.028), dark=(0.040, 0.019, 0.007),
                  grain_spacing=0.005, plank_width=0.11, waterlog=0.45, roughness=0.60,
                  algae=0.0, seed=0):
    """Sawn timber, optionally waterlogged.

    `grain_spacing` is the distance between grain lines *in metres* — wood grain is a
    physical size, not a fraction of the board, so a 3 m keel and a 20 cm chest slat show
    the same grain and the model has to be built at real scale for it to look right.
    Grain runs along object X, which is the long axis of `hardsurface.plank`.

    `plank_width` darkens a band at every multiple of itself across object Y, so a hull
    built as one mesh still reads as separate boards, and a single plank gets darkened
    edges. Set it to 0 to disable.

    `waterlog` (0-1) takes the timber from freshly sawn to a drowned wreck: darker,
    greyer, matte, and with the grain contrast lifted, because water swells the soft
    early wood and leaves the hard rings standing proud.
    """
    mat, nt = _material(name)
    coord = _new(nt, "ShaderNodeTexCoord", (-1700, 0))

    drowned = (0.030, 0.028, 0.026)
    light = _blend(light, drowned, waterlog * 0.86)
    dark = _blend(dark, drowned, waterlog * 0.86)

    # Grain: noise stretched hard along the board so it streaks instead of blotching.
    span = max(grain_spacing, 1e-5)
    grain_uv = _mapped(nt, (-1500, 200), coord,
                       (1.0 / (span * 240.0), 1.0 / span, 1.0 / span), _seed_offset(seed))
    grain = _noise(nt, (-1320, 200), grain_uv, detail=8.0, roughness=0.70, distortion=0.6)

    grain_ramp = _new(nt, "ShaderNodeValToRGB", (-1120, 200))
    _ramp(grain_ramp, [
        (0.00, _rgba(dark)),
        (0.42, _rgba(_blend(dark, light, 0.55))),
        (0.60, _rgba(light)),
        (1.00, _rgba(_blend(light, (1.0, 1.0, 1.0), 0.10))),
    ])
    nt.links.new(grain.outputs["Fac"], grain_ramp.inputs["Fac"])
    color = grain_ramp.outputs["Color"]

    # Broad tonal drift, so two boards cut from the same material are not the same board.
    blotch_uv = _mapped(nt, (-1500, -150), coord, (3.0 / max(size, 1e-6),) * 3,
                        _seed_offset(seed + 3))
    blotch = _noise(nt, (-1320, -150), blotch_uv, detail=4.0, roughness=0.55)
    shade = 1.0 - 0.30 - 0.18 * waterlog
    color = _mix_rgb(nt, (-900, -60), blotch.outputs["Fac"], color,
                     (shade, shade * 0.97, shade * 0.93), blend="MULTIPLY")

    if plank_width > 0.0:
        axis = _new(nt, "ShaderNodeSeparateXYZ", (-1500, -420))
        nt.links.new(coord.outputs["Object"], axis.inputs["Vector"])
        # Half a period of phase, so the dark seam lands on the board's edges rather
        # than down the middle of a board centred on the origin.
        across = _math(nt, (-1320, -420), "DIVIDE", axis.outputs["Y"], plank_width)
        offset = _math(nt, (-1240, -500), "ADD", across, 0.5)
        cycle = _math(nt, (-1140, -420), "FRACT", offset)

        seam = _new(nt, "ShaderNodeValToRGB", (-960, -420))
        _ramp(seam, [(0.00, (0, 0, 0, 1)), (0.10, (1, 1, 1, 1)),
                     (0.90, (1, 1, 1, 1)), (1.00, (0, 0, 0, 1))])
        nt.links.new(cycle, seam.inputs["Fac"])
        edge_shade = 0.30 + 0.25 * (1.0 - waterlog)
        color = _mix_rgb(nt, (-700, -300), seam.outputs["Color"],
                         (edge_shade, edge_shade * 0.92, edge_shade * 0.86), color)

    rough = _range(nt, (-900, -700), grain.outputs["Fac"], 0.0, 1.0,
                   min(0.97, roughness + 0.22 * waterlog + 0.10),
                   max(0.10, roughness - 0.14 + 0.18 * waterlog))
    height = grain.outputs["Fac"]

    color, rough, height = _biofilm(nt, coord, color, rough, height, algae, size, seed)
    _principled(nt, color, rough, height, bump_distance=grain_spacing * 0.30,
                bump_strength=0.5, specular=0.5 - 0.25 * waterlog)
    return mat


def metal_material(name, size=0.3, base=BRASS, corrosion=0.35, patina=RUST,
                   roughness=0.18, algae=0.0, seed=0):
    """One function from polished brass to a rusted-through hull plate.

    `corrosion` (0-1) does three things together, because they always happen together:
    it dulls and darkens the clean metal (tarnish), it grows patches of `patina` that
    are not metal at all, and it pits the surface underneath them. At 0 this is a
    freshly polished fitting; at 0.3 a chest's brass corners; at 1 there is no bare metal
    left.

    `patina` chooses the corrosion product — `RUST` for iron, `VERDIGRIS` for copper and
    bronze, `TARNISH` for silver — and `base` the alloy (`BRASS`, `COPPER`, `STEEL`,
    `IRON`). The combination is the caller's, because a bronze cannon goes green and an
    iron anchor goes orange and nothing in the geometry knows which it is.
    """
    corrosion = min(1.0, max(0.0, float(corrosion)))
    mat, nt = _material(name)
    coord = _new(nt, "ShaderNodeTexCoord", (-1700, 0))

    clean = _blend(base, TARNISH, 0.55 * corrosion)
    clean_rough = min(0.92, roughness + 0.45 * corrosion)

    patch_uv = _mapped(nt, (-1500, 200), coord, (5.5 / max(size, 1e-6),) * 3,
                       _seed_offset(seed + 5))
    patches = _noise(nt, (-1320, 200), patch_uv, detail=7.0, roughness=0.65,
                     distortion=0.4)
    centre = 0.80 - 0.62 * corrosion
    eaten = _range(nt, (-1120, 200), patches.outputs["Fac"],
                   centre - 0.13, centre + 0.13, 0.0, 1.0)

    # Corrosion is never one colour: rust runs from near-black in the pits to bright
    # orange where it is flaking off, and a single flat brown is the plastic look again.
    grit_uv = _mapped(nt, (-1500, -150), coord, (19.0 / max(size, 1e-6),) * 3,
                      _seed_offset(seed + 11))
    grit = _noise(nt, (-1320, -150), grit_uv, detail=8.0, roughness=0.72)
    # Keep both ends close to the patina's own colour. Mixing far toward cream to get
    # "bright flaking rust" pulls the average up until the whole plate reads as pink
    # putty — the variation has to come from tone, not from a second hue.
    patina_color = _mix_rgb(nt, (-1120, -150), grit.outputs["Fac"],
                            _blend(patina, (0.0, 0.0, 0.0), 0.70),
                            _blend(patina, (1.0, 0.86, 0.60), 0.14))

    color = _mix_rgb(nt, (-700, 100), eaten, clean, patina_color)

    # Streaks running down from the patches: corrosion bleeds with gravity, and this is
    # what separates a corroded object from an object with brown spots on it.
    bleed_uv = _mapped(nt, (-1500, -420), coord,
                       (7.0 / max(size, 1e-6), 7.0 / max(size, 1e-6),
                        1.6 / max(size, 1e-6)), _seed_offset(seed + 17))
    bleed = _noise(nt, (-1320, -420), bleed_uv, detail=5.0, roughness=0.6)
    streak = _range(nt, (-1120, -420), bleed.outputs["Fac"],
                    0.62 - 0.30 * corrosion, 0.86 - 0.30 * corrosion, 0.0, 0.55)
    color = _mix_rgb(nt, (-500, 40), streak, color,
                     _blend(patina, (0.0, 0.0, 0.0), 0.35))

    metallic = _mix_value(nt, (-500, -220), eaten, 1.0, 0.08)
    # Corrosion products are not just rough metal, they are chalk: leaving the dielectric
    # specular at a polished 0.55 lays a white sheen over every bump on the rusted areas
    # and desaturates a brown plate into pink putty.
    specular = _mix_value(nt, (-320, -220), eaten, 0.55, 0.10)
    rough = _mix_value(nt, (-500, -400), eaten, clean_rough, 0.86)
    rough = _mix_value(nt, (-320, -400), streak, rough, 0.80)

    pits = _voronoi(nt, (-1120, -700), _mapped(
        nt, (-1320, -700), coord, (34.0 / max(size, 1e-6),) * 3, _seed_offset(seed + 29)))
    pit_depth = _math(nt, (-900, -700), "MULTIPLY", pits.outputs["Distance"], eaten)
    height = _add(nt, (-700, -760), pit_depth,
                  _math(nt, (-900, -900), "MULTIPLY", grit.outputs["Fac"], 0.35))

    color, rough, height = _biofilm(nt, coord, color, rough, height, algae, size, seed)
    _principled(nt, color, rough, height, bump_distance=size * 0.010,
                bump_strength=0.30 + 0.35 * corrosion, metallic=metallic,
                specular=specular)
    return mat


def bone_material(name, size=0.2, base=(0.128, 0.113, 0.082), dirt=0.45,
                  translucency=0.22, algae=0.0, seed=0):
    """Old bone: porous, faintly translucent, and never clinical white.

    `dirt` (0-1) settles brown into the crevices and blotches the surface; at 0 this is
    a museum specimen, at 1 something that has been lying on the seabed. `translucency`
    is the subsurface weight — bone passes a little light at its thin edges, and that is
    most of what separates it from painted plaster.

    The subsurface radius is derived from `size` and kept deliberately small. This is the
    fish spike's units trap in a new place: `size` is a prop's *length*, but light
    scatters across its *thickness*, and a rib is far longer than it is thick. A radius
    that looks modest against the length bleeds straight through the bone and turns it
    into a pastel blob.
    """
    mat, nt = _material(name)
    coord = _new(nt, "ShaderNodeTexCoord", (-1700, 0))

    stain = (0.105, 0.070, 0.034)
    blotch_uv = _mapped(nt, (-1500, 200), coord, (4.0 / max(size, 1e-6),) * 3,
                        _seed_offset(seed + 2))
    blotch = _noise(nt, (-1320, 200), blotch_uv, detail=5.0, roughness=0.6)
    # Deliberately a narrow band: staining is patchy, so some of the bone has to stay
    # clean and some has to go fully brown. A wide band averages to a uniform tea colour.
    tone = _range(nt, (-1120, 200), blotch.outputs["Fac"], 0.34, 0.66, 0.0,
                  0.25 + 0.72 * dirt)
    color = _mix_rgb(nt, (-900, 200), tone, base, stain)

    # Porosity: fine cells that darken and roughen, which is what stops bone reading as
    # smooth ceramic. Cell count is relative to the prop so a rib and a skull match.
    pores = _voronoi(nt, (-1120, -200), _mapped(
        nt, (-1320, -200), coord, (46.0 / max(size, 1e-6),) * 3, _seed_offset(seed + 13)))
    pore_dark = _range(nt, (-900, -200), pores.outputs["Distance"], 0.0, 0.30,
                       0.55 * dirt + 0.15, 0.0)
    color = _mix_rgb(nt, (-700, 100), pore_dark, color, _blend(stain, (0, 0, 0), 0.4))

    grime_uv = _mapped(nt, (-1500, -520), coord, (16.0 / max(size, 1e-6),) * 3,
                       _seed_offset(seed + 19))
    grime = _noise(nt, (-1320, -520), grime_uv, detail=7.0, roughness=0.7)
    rough = _range(nt, (-1120, -520), grime.outputs["Fac"], 0.0, 1.0,
                   0.38 + 0.20 * dirt, 0.72 + 0.18 * dirt)

    height = _add(nt, (-900, -700), pores.outputs["Distance"],
                  _math(nt, (-1120, -900), "MULTIPLY", grime.outputs["Fac"], 0.4))

    color, rough, height = _biofilm(nt, coord, color, rough, height, algae, size, seed)
    _principled(nt, color, rough, height, bump_distance=size * 0.004, bump_strength=0.55,
                specular=0.35, extras={
                    "Subsurface Weight": translucency,
                    "Subsurface Radius": (size * 0.011, size * 0.007, size * 0.0045),
                })
    return mat


def rock_material(name, size=0.3, base=(0.052, 0.050, 0.047),
                  secondary=(0.118, 0.107, 0.092), speckle=0.55, roughness=0.80,
                  algae=0.0, seed=0):
    """Stone: three tones, mineral speckle, and roughness that is never constant.

    All texture frequencies are counts across `size` (the prop's approximate diameter in
    metres) rather than absolute distances. Physically that is wrong — granite speckle is
    two millimetres across on a pebble and on a cliff — but a pebble carrying physically
    correct speckle is a grey blur at screen size, and a boulder carrying pebble-sized
    speckle is a low-poly facet field. Relative wins because the same call has to serve
    gravel and a reef wall.

    `speckle` (0-1) is how much mineral fleck shows; drop it toward 0 for mudstone or
    something water-polished, raise it for granite.
    """
    mat, nt = _material(name)
    coord = _new(nt, "ShaderNodeTexCoord", (-1700, 0))

    broad_uv = _mapped(nt, (-1500, 250), coord, (2.2 / max(size, 1e-6),) * 3,
                       _seed_offset(seed + 1))
    broad = _noise(nt, (-1320, 250), broad_uv, detail=4.0, roughness=0.55,
                   distortion=0.3)
    color = _mix_rgb(nt, (-1100, 250), _range(
        nt, (-1300, 420), broad.outputs["Fac"], 0.30, 0.72, 0.0, 1.0), base, secondary)

    mid_uv = _mapped(nt, (-1500, 0), coord, (8.0 / max(size, 1e-6),) * 3,
                     _seed_offset(seed + 6))
    mid = _noise(nt, (-1320, 0), mid_uv, detail=7.0, roughness=0.68)
    # A wide from-range on purpose: a narrow one turns the noise into a hard-edged
    # splatter that reads as paint rather than as a change of mineral.
    color = _mix_rgb(nt, (-900, 120), _range(
        nt, (-1120, 0), mid.outputs["Fac"], 0.20, 0.95, 0.0, 0.60),
        color, _blend(base, (0.0, 0.0, 0.0), 0.45))

    crystals = _voronoi(nt, (-1120, -320), _mapped(
        nt, (-1320, -320), coord, (30.0 / max(size, 1e-6),) * 3, _seed_offset(seed + 8)),
        randomness=0.95)
    # Only the very centre of each cell flecks, so the specks stay specks; widen this
    # and half the surface turns pale and the stone reads as concrete.
    fleck = _range(nt, (-900, -320), crystals.outputs["Distance"], 0.0, 0.07,
                   0.60 * speckle, 0.0)
    color = _mix_rgb(nt, (-700, 60), fleck, color,
                     _blend(secondary, (1.0, 0.96, 0.90), 0.35))

    fine_uv = _mapped(nt, (-1500, -620), coord, (60.0 / max(size, 1e-6),) * 3,
                      _seed_offset(seed + 14))
    fine = _noise(nt, (-1320, -620), fine_uv, detail=8.0, roughness=0.75)
    rough = _range(nt, (-1120, -620), fine.outputs["Fac"], 0.0, 1.0,
                   max(0.25, roughness - 0.20), min(0.99, roughness + 0.14))
    # Wet stone is darker and shinier in the hollows where water sits.
    rough = _mix_value(nt, (-700, -620), fleck, rough, max(0.20, roughness - 0.35))

    height = _add(nt, (-700, -860),
                  _math(nt, (-900, -800), "MULTIPLY", crystals.outputs["Distance"], 0.8),
                  _math(nt, (-900, -960), "MULTIPLY", fine.outputs["Fac"], 0.5))

    color, rough, height = _biofilm(nt, coord, color, rough, height, algae, size, seed)
    _principled(nt, color, rough, height, bump_distance=size * 0.012,
                bump_strength=0.55, specular=0.35)
    return mat


def sand_material(name, size=1.0, base=(0.082, 0.066, 0.045), dark=(0.030, 0.024, 0.016),
                  ripple_spacing=0.07, shell=0.35, roughness=0.86, algae=0.0, seed=0):
    """Seabed: ripples, shell fragments, and settled detritus.

    `ripple_spacing` is in metres and is absolute on purpose — a ripple field is set by
    the water, not by how much seabed the scene contains, so it stays the same whether
    the floor is one metre or twenty. Ripples run along object X, so rotate the object to
    aim them.

    `shell` (0-1) is how many pale fragments are mixed into the grain; without something
    lighter than the sand in it, a flat tan floor is the most plastic-looking surface in
    the tank.

    The default tones are those of *wet* sand, which is far darker than the dry beach
    colour the name suggests — and a seabed is a large surface facing straight into the
    key light, so anything lighter clips to white and loses its ripples entirely.
    """
    mat, nt = _material(name)
    coord = _new(nt, "ShaderNodeTexCoord", (-1700, 0))

    # Ripples are noise stretched along X, not a Wave texture. A wave gives perfectly
    # straight, perfectly evenly spaced bands, and a seabed built from one reads as
    # corduroy; real ripple marks wander, fork and vary in spacing, which is exactly what
    # an anisotropic noise does for free.
    span = max(ripple_spacing, 1e-4)
    ripple_uv = _mapped(nt, (-1500, 250), coord,
                        (1.0 / (span * 9.0), 1.0 / span, 1.0 / span),
                        _seed_offset(seed + 4))
    ripples = _noise(nt, (-1320, 250), ripple_uv, detail=4.0, roughness=0.45,
                     distortion=0.35)

    # Troughs collect the dark, fine stuff; crests are washed pale. Colouring the ripple
    # as well as bumping it is what keeps it visible in flat overhead light.
    color = _mix_rgb(nt, (-1100, 250), _range(
        nt, (-1300, 60), ripples.outputs["Fac"], 0.30, 0.72, 0.0, 1.0), dark, base)

    drift_uv = _mapped(nt, (-1500, -180), coord, (2.5 / max(size, 1e-6),) * 3,
                       _seed_offset(seed + 9))
    drift = _noise(nt, (-1320, -180), drift_uv, detail=5.0, roughness=0.6)
    color = _mix_rgb(nt, (-900, 120), _range(
        nt, (-1120, -180), drift.outputs["Fac"], 0.30, 0.80, 0.0, 0.45),
        color, _blend(dark, (0.0, 0.0, 0.0), 0.30))

    grains = _voronoi(nt, (-1120, -480), _mapped(
        nt, (-1320, -480), coord, (1.0 / (span * 0.06),) * 3, _seed_offset(seed + 21)),
        randomness=1.0)
    fragments = _range(nt, (-900, -480), grains.outputs["Distance"], 0.0, 0.35,
                       0.45 * shell, 0.0)
    color = _mix_rgb(nt, (-700, 40), fragments, color, (0.24, 0.220, 0.180))

    rough = _range(nt, (-700, -640), grains.outputs["Distance"], 0.0, 0.4,
                   min(0.99, roughness + 0.10), max(0.30, roughness - 0.16))

    height = _add(nt, (-700, -900), ripples.outputs["Fac"],
                  _math(nt, (-900, -980), "MULTIPLY", grains.outputs["Distance"], 0.6))

    color, rough, height = _biofilm(nt, coord, color, rough, height, algae, size, seed)
    _principled(nt, color, rough, height, bump_distance=span * 0.10, bump_strength=0.62,
                specular=0.30)
    return mat


def glass_material(name, size=0.15, tint=(0.105, 0.285, 0.155), roughness=0.05,
                   grime=0.30, waviness=0.35, algae=0.0, seed=0):
    """Bottle glass and helmet faceplates.

    `tint` is the colour of the glass itself — old bottle glass is never clear, it is the
    green or brown of whatever iron was in the sand. `waviness` (0-1) adds a very slight
    broad bump: hand-blown glass is not optically flat, and the wobble it puts into the
    reflection is most of what says "old bottle" rather than "CG sphere".

    `grime` (0-1) is the film of silt that stops transmission in patches; unlike `algae`
    it is grey-brown and covers all faces, not just the ones pointing up.
    """
    mat, nt = _material(name)
    coord = _new(nt, "ShaderNodeTexCoord", (-1700, 0))

    dirt_uv = _mapped(nt, (-1500, 200), coord, (6.0 / max(size, 1e-6),) * 3,
                      _seed_offset(seed + 15))
    dirt = _noise(nt, (-1320, 200), dirt_uv, detail=6.0, roughness=0.65)
    filthy = _range(nt, (-1120, 200), dirt.outputs["Fac"],
                    0.72 - 0.55 * grime, 0.95 - 0.55 * grime, 0.0, 1.0)

    color = _mix_rgb(nt, (-700, 200), filthy, tint, (0.075, 0.068, 0.052))
    rough = _mix_value(nt, (-700, 0), filthy, roughness, 0.62)
    transmission = _mix_value(nt, (-700, -160), filthy, 0.95, 0.15)

    wave_uv = _mapped(nt, (-1500, -420), coord, (3.0 / max(size, 1e-6),) * 3,
                      _seed_offset(seed + 27))
    wave = _noise(nt, (-1320, -420), wave_uv, detail=3.0, roughness=0.5)
    height = _math(nt, (-1120, -420), "MULTIPLY", wave.outputs["Fac"], waviness)

    color, rough, height = _biofilm(nt, coord, color, rough, height, algae, size, seed)
    _principled(nt, color, rough, height, bump_distance=size * 0.010, bump_strength=0.35,
                specular=0.6,
                extras={"Transmission Weight": transmission, "IOR": 1.48})
    # EEVEE Next only refracts through a raytraced pass, and only when the material opts
    # in; without this the bottle renders as a tinted opaque solid.
    if hasattr(mat, "use_raytrace_refraction"):
        mat.use_raytrace_refraction = True
    return mat


def _blend(a, b, t):
    """Linear blend of two RGB tuples, done in Python so it costs nothing at render."""
    t = min(1.0, max(0.0, float(t)))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
