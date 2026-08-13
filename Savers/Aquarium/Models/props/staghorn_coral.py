"""Staghorn coral (*Acropora cervicornis*) — a dense forking thicket.

The tube primitive's own "staghorn" demo case is a bare winter tree: one split near the
tip, three generations, long internodes. Coral is the opposite shape. The numbers here
push density hard in the four directions that matter — depth, two splits per segment,
short internodes, and a radius that barely decays — because a branch that stays thick
relative to its length is the whole read. Copying the demo's numbers gives a shrub.
"""

import math

import bpy

from saverlib import BranchSpec, assign, build_branching, rock, rock_material

from ._spec import Prop

# Distance from the colony's holdfast to a growing tip, normalized over the generations,
# written per vertex so the material can pale the actively growing ends. Nothing in
# `surfaces.py` can express this: every one of its gradients is driven by world normal or
# object-space noise, and neither knows which end of a branch is the young one.
_TIPNESS = "tipness"


def build(seed=0):
    root = bpy.data.objects.new("decor_staghorn_coral", None)
    bpy.context.collection.objects.link(root)

    spec = BranchSpec(
        trunk_length=0.097,
        radius=0.019,
        children_per_split=2,
        split_angle=math.radians(36.0),
        split_angle_jitter=math.radians(11.0),
        # Barely decaying: Acropora branches stay chunky all the way out and never taper
        # to whips, which is what separates coral from a shrub at a glance.
        length_decay=0.84,
        radius_decay=0.80,
        depth=4,
        curvature=0.06,
        # Negative droop reaches for the surface. A colony is a candelabra, not a canopy:
        # every branch curves back toward vertical however far out it forks.
        droop=-0.20,
        seed=seed * 101 + 17,
        # The low split is what removes the bare trunk — branching starts almost at the
        # holdfast, and the second split keeps the internode between forks short.
        split_positions=(0.20, 0.76),
        alternating=True,
        tip_radius_ratio=0.92,
        junction_overlap=1.0,
    )
    # Junctions are left as intersecting shells rather than voxel-welded: a weld fine
    # enough for a 5 mm terminal radius would remesh the whole thicket and multiply the
    # triangle count of a prop that gets instanced across the tank.
    result = build_branching(spec, name="staghorn", rings=6, segments=8, subsurf=0)
    _mark_tipness(result.tubes, spec)
    body = result.join("staghorn_thicket")
    body.parent = root

    # A colony grows out of an encrusting base, and without one the primitive's rounded
    # start cap leaves the whole thicket balanced on a mushroom stalk touching the sand at
    # a single point. The base swallows that cap and gives the prop a flat bottom.
    holdfast = rock("staghorn_base", radius=0.042, angularity=0.34, seed=seed * 31 + 5,
                    lumpiness=0.38, flatten=0.90, detail=4)
    holdfast.parent = root

    # `size` is nominally the prop's diameter, but it is really the denominator for every
    # texture frequency, and the feature that has to read here is a corallite a few
    # millimetres across on a 3 cm branch — not mottling across a 30 cm colony.
    material = rock_material(
        f"staghorn_{seed}", size=0.09,
        base=(0.34, 0.22, 0.100), secondary=(0.64, 0.50, 0.290),
        speckle=0.85, roughness=0.70, algae=0.20, seed=seed,
    )
    _pale_tips(material, pale=(0.74, 0.66, 0.50), threshold=0.90)
    assign(body, material)
    # The holdfast carries no tipness, so it reads at the dark end of the same material —
    # which is what an encrusting base overgrown from below actually looks like.
    assign(holdfast, material)
    return root


def _mark_tipness(tubes, spec):
    """Write `_TIPNESS` per vertex: 0 at the holdfast, 1 at a growing tip.

    `build_branching` does not report which generation a tube came from, but it does not
    have to — a segment's radius is `spec.radius * radius_decay ** generation` by
    construction, so the generation is recoverable from the built geometry and stays
    correct if the spec is retuned.
    """
    for tube in tubes:
        generation = round(
            math.log(max(tube.radii) / spec.radius) / math.log(spec.radius_decay)
        )
        start = tube.points[0]
        chord = tube.points[-1] - start
        length = chord.length
        direction = chord / length

        mesh = tube.object.data
        attribute = mesh.attributes.new(_TIPNESS, "FLOAT", "POINT")
        span = spec.depth + 1
        attribute.data.foreach_set("value", [
            (generation + min(1.0, max(0.0, (v.co - start).dot(direction) / length))) / span
            for v in mesh.vertices
        ])


def _pale_tips(material, pale, threshold):
    """Fade a finished material toward `pale` where `_TIPNESS` is high.

    Spliced onto the end of the base-colour chain rather than written as a coral material
    from scratch, because everything else `rock_material` does — mineral speckle standing
    in for corallites, three-tone drift, algae on upward faces only — is already right.
    Going in last also means the pale tips override the algae, which is correct: the
    growing end of a branch is the one part of a colony nothing has colonised yet.
    """
    nt = material.node_tree
    bsdf = next(node for node in nt.nodes if node.type == "BSDF_PRINCIPLED")
    socket = bsdf.inputs["Base Color"]
    link = socket.links[0]
    substrate = link.from_socket
    nt.links.remove(link)

    attribute = nt.nodes.new("ShaderNodeAttribute")
    attribute.attribute_name = _TIPNESS
    attribute.location = (60, 320)

    # A narrow band high in the range: pale growth is the last centimetre or two of a
    # branch, and widening it turns the whole colony into bleached rubble.
    mask = nt.nodes.new("ShaderNodeMapRange")
    mask.location = (240, 320)
    mask.clamp = True
    nt.links.new(attribute.outputs["Fac"], mask.inputs["Value"])
    for name, value in (("From Min", threshold), ("From Max", 1.0),
                        ("To Min", 0.0), ("To Max", 1.0)):
        mask.inputs[name].default_value = value

    # `ShaderNodeMix` stacks four A/B socket pairs under the same names; indices are the
    # only unambiguous way to reach the colour pair.
    blend = nt.nodes.new("ShaderNodeMix")
    blend.location = (430, 300)
    blend.data_type = "RGBA"
    blend.clamp_factor = True
    nt.links.new(mask.outputs["Result"], blend.inputs[0])
    nt.links.new(substrate, blend.inputs[6])
    blend.inputs[7].default_value = (*pale, 1.0)
    nt.links.new(blend.outputs[2], socket)


STAGHORN_CORAL = Prop(
    name="staghorn_coral",
    build=build,
    category="coral",
    footprint=0.15,
    height=0.30,
    tilt_range=(-6.0, 6.0),
    scale_range=(0.70, 1.35),
    weight=2.0,
    seeds=4,
)
