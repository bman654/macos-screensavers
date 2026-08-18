"""The materials a fish is made of: skin, fin membrane, eye.

Each one assembles shader nodes rather than sampling a painted texture, so a species is a
handful of numbers and no marking ships as an image authored by hand. The marking
vocabulary those numbers are spent on — bands, stripes, spots, patches, bony rings, an eye
ring, a two-tone split — lives in `markings.py`, along with the node helpers both modules
use; this file is what turns those masks into a shaded surface.

Almost all of it is placed in object space. The exceptions read a UV, and they read it
through `markings._uv`, which names the layer: a bake replaces the render layer with the
atlas's own, so a material that asks for "the UV" paints something different into the
atlas than it drew in the viewport. `bake.py`'s docstring has the full story and what it
already cost.

`_ramp` and `_set` are re-exported here deliberately: `surfaces.py` imports them from
this module and they are the two helpers every material in the package needs.
"""

from math import pi

import bpy

from .markings import (  # noqa: F401  (_ramp/_set are re-exported for surfaces.py)
    _BLACK, _WHITE, _Flank, _add_bands, _add_diagonals, _add_eye_ring, _add_patches,
    _add_rings, _add_split, _add_spots, _add_stripes, _as_dicts, _fields, _mask_stops,
    _math, _mix_color, _patch_mask, _ramp, _ramp_node, _set, _spot_mask, _uv,
)

# The UV layer every authored coordinate is written into: the fin grid's (along, out),
# and a swept body's (along, around). One layer, because Blender's join merges layers by
# name and a second one would leave each material reading whichever the join happened to
# mark for render. `build_fish.py` writes it; the default is here so the two cannot drift.
AUTHORED_UV = "UVMap"


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
    rings=None,
    uv_layer=AUTHORED_UV,
    split=None,
    mouth=None,
    mouth_color=(0.10, 0.035, 0.025),
    eye_ring=None,
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

    `rings` comes after even those, because it is not paint. A bony ring's joint is a
    crease in the animal, and a crease crosses whatever happens to be painted over it —
    which is also why it is the one marking that returns a height as well as a colour.
    It needs `uv_layer` to exist on the mesh, which today means a swept body; see
    `_add_rings`.

    `mouth` and `eye_ring` are drawn last of all, on the same reasoning as `patches` but
    stronger: they belong to a feature that exists at a fixed place on the head, so
    nothing scattered over the flank may cross them.
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
    ring_height = None
    if rings:
        base_color, ring_height = _add_rings(
            nt, _uv(nt, uv_layer, (-1200, -2100)), base_color, rings
        )
    if mouth:
        center, radii = mouth
        mask = _patch_mask(nt, coord, center, radii, location=(-1000, -680))
        base_color = _mix_color(nt, base_color, mask, mouth_color, flank.slot())
    if eye_ring:
        base_color = _add_eye_ring(nt, flank, base_color, eye_ring, body_length)

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
    surface_normal = bump.outputs["Normal"]

    if ring_height is not None:
        # Chained rather than summed into the scale height: the two reliefs are at
        # different depths and in different units — one is a Voronoi distance, the other a
        # signed ridge field — and adding them would make either one's depth a function of
        # the other's. `rings.depth` and its siblings are the weights within the ring
        # relief; this is how deep the whole of it cuts.
        ring_bump = nodes.new("ShaderNodeBump")
        ring_bump.location = (-360, -420)
        _set(ring_bump, "Strength", 1.0)
        _set(ring_bump, "Distance", body_length * 0.010)
        links.new(ring_height, ring_bump.inputs["Height"])
        links.new(surface_normal, ring_bump.inputs["Normal"])
        surface_normal = ring_bump.outputs["Normal"]

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
    links.new(surface_normal, bsdf.inputs["Normal"])

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (460, 60)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    return mat


def _along_stops(entries, color, tip_color):
    """Split `along_colors` into the root ramp and the tip ramp it implies.

    An entry is `(u, color)` or `(u, color, tip_color)`. Omitting the entry's tip colour
    falls back to the material's own `tip_color`, and to the entry's colour when there
    isn't one — exactly the rule the constant case already follows.
    """
    root, tip, previous = [], [], None
    for entry in entries:
        u = float(entry[0])
        if not 0.0 <= u <= 1.0:
            raise ValueError(f"along_colors: u must be in 0..1, got {u}")
        if previous is not None and u <= previous:
            raise ValueError("along_colors: positions must strictly increase along the "
                             f"root, got {u} after {previous}")
        previous = u
        base = tuple(entry[1])
        end = tuple(entry[2]) if len(entry) > 2 else (tuple(tip_color) if tip_color
                                                     else base)
        root.append((u, (*base, 1.0)))
        tip.append((u, (*end, 1.0)))
    if not root:
        raise ValueError("along_colors: needs at least one (u, color) stop")
    return root, tip


def fin_material(name, color, tip_color=None, along_colors=None, edge_color=None,
                 edge_width=0.10, opacity=0.92, spots=None, ray_count=26.0,
                 ray_contrast=0.5, roughness=0.52, translucency=0.08,
                 uv_layer=AUTHORED_UV):
    """A fin membrane: root-to-tip gradient, bright margin, fin rays, optional spots.

    Colour is driven by the fin's own UV, whose V runs 0 at the root to 1 at the
    trailing edge and whose U runs along the attachment. Object space cannot do this
    job: a fin's outward direction differs per fin (up for the dorsal, down for the
    anal, backwards for the caudal, sideways for the paired fins) and the parts are
    later joined into one mesh, so there is no per-fin origin left to measure from. The
    UV is written by the same grid that builds the membrane, travels through solidify
    and subdivision, and survives the join because every part writes into one layer.

    So `color` is the membrane at the root, `tip_color` at the trailing edge, and
    `along_colors` optionally makes both of those a function of U instead of constants:
    a list of `(u, color)` or `(u, color, tip_color)` stops, interpolated linearly, held
    flat outside the first and last stop. Put two stops close together for a hard
    transition and far apart for a wash — the same explicit-placement idea the body
    markings use, rather than a blend the caller has to tune backwards into.

    That is what a single continuous fin spanning a two-tone body needs: one dorsal
    running the length of a royal gramma has to be violet where the body is violet and
    gold where the body is gold, and it is one fin, so it cannot be two materials.

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

    coordinate = _uv(nt, uv_layer, (-1100, 0))

    uv = nodes.new("ShaderNodeSeparateXYZ")
    uv.location = (-920, 0)
    links.new(coordinate, uv.inputs["Vector"])
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
    links.new(coordinate, rays.inputs["Vector"])

    lo = 1.0 - 0.35 * ray_contrast
    ray_shade = _ramp_node(nt, rays.outputs["Fac"],
                           [(0.0, (lo, lo, lo, 1.0)), (1.0, _WHITE)], (-540, -220))

    if along_colors:
        root_stops, tip_stops = _along_stops(along_colors, color, tip_color)
        root_color = _ramp_node(nt, along, root_stops, (-740, 380))
        tip_at_u = _ramp_node(nt, along, tip_stops, (-740, 180))
        # The constant case is a ColorRamp on V with EASE interpolation, so the U-varying
        # case reproduces that curve as an explicit factor rather than blending linearly
        # and quietly giving the two paths different gradients.
        reach = _ramp_node(nt, out, [(0.0, _BLACK), (1.0, _WHITE)], (-740, -20),
                           interpolation="EASE")
        blend = nodes.new("ShaderNodeMix")
        blend.location = (-540, 160)
        blend.data_type = "RGBA"
        blend.blend_type = "MIX"
        links.new(reach, blend.inputs["Factor"])
        links.new(root_color, blend.inputs[6])
        links.new(tip_at_u, blend.inputs[7])
        membrane = blend.outputs[2]
    else:
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
            mask = _spot_mask(nt, coordinate, float(p["count"]), p["size"],
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
