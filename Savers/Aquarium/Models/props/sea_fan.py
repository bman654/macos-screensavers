"""A gorgonian sea fan — the prop `BranchSpec.planarity` was built for.

Everything else in the reef is a volume; this is a surface. The fan presents a broad lace
face across the current and nearly vanishes edge-on, so the whole model is one branching
structure confined to the XZ plane with only enough out-of-plane wander to keep it from
reading as cut cardboard.
"""

import math

import bpy

from saverlib import BranchSpec, assign, build_branching, rock, rock_material

from ._spec import Prop


# The plane the fan lives in. Y is its normal, so the broad face points at the tank's
# side views and the studio "front" view is the edge-on check that planarity worked.
_PLANE_NORMAL = (0.0, 1.0, 0.0)


def build(seed=0):
    root = bpy.data.objects.new("decor_sea_fan", None)
    bpy.context.collection.objects.link(root)

    # A gorgonian is dichotomous: one fork just short of every tip, ten orders deep, with
    # a three-centimetre internode everywhere in the colony. Spending the branch budget on
    # depth rather than on children per split is what makes the difference — a thousand
    # tubes buy ten generations here, where four children per split would buy five for
    # three times the geometry, and it is the generation count rather than the branch
    # count that stops this reading as a shrub.
    spec = BranchSpec(
        trunk_length=0.052,
        radius=0.0060,
        children_per_split=2,
        # Narrow forks. A gorgonian's daughters diverge by about 35 degrees in total, and
        # over ten generations a wider angle random-walks the headings past horizontal and
        # the fan turns into a tangle.
        split_angle=math.radians(18.0),
        split_angle_jitter=math.radians(6.0),
        # Near 1.0, which is what separates this from a tree. A tree's branches shorten
        # sharply at every fork, so it reads as a trunk carrying a canopy; a gorgonian's
        # internode barely changes, which is why the whole fan is one even lace mesh.
        length_decay=0.94,
        radius_decay=0.82,
        depth=9,
        curvature=0.02,
        droop=0.012,
        seed=seed * 977 + 4129,
        # Not 1.0: a perfectly planar fan reads as a flat decal the moment the camera
        # swings off-axis. A few degrees of wander gives it thickness without volume.
        planarity=0.95,
        split_positions=(0.93,),
        tip_radius_ratio=0.60,
        junction_overlap=1.0,
    )
    result = build_branching(
        spec,
        name="fan",
        plane_normal=_PLANE_NORMAL,
        rings=5,
        segments=6,
        subsurf=0,
    )
    # Fast join, no voxel weld. The thinnest twig is a millimetre across, so a weld voxel
    # small enough to keep it would have to be a few tenths of a millimetre over a
    # half-metre prop — a remesh at that resolution is unaffordable, and the intersecting
    # shells read as solid at any distance a screensaver ever sees this from.
    fan = result.join("sea_fan_branches")
    fan.parent = root

    # The encrusting foot the colony grows from. Without it the stem ends in a cut-off
    # rod, which is the one place the model would otherwise betray that it was swept.
    # Kept deliberately smooth and hard-flattened: a lumpy foot at this radius reads as a
    # pebble the fan happens to be standing next to rather than as tissue spread over rock.
    foot = rock("sea_fan_holdfast", radius=0.026, angularity=0.15, seed=seed,
                detail=3, lumpiness=0.28, flatten=0.80)
    foot.parent = root

    # `size` is far smaller than the fan because the material's features have to land on a
    # branch, not on the colony: at the fan's own half-metre the mineral fleck would be
    # tens of centimetres apart and no twig would ever carry one. At 25 mm the fleck falls
    # roughly at polyp spacing, which is exactly the detail a gorgonian shows.
    coral = rock_material(
        f"sea_fan_{seed}", size=0.025,
        base=(0.090, 0.005, 0.072), secondary=(0.275, 0.016, 0.125),
        speckle=0.85, roughness=0.62, algae=0.06, seed=seed,
    )
    assign(fan, coral)
    assign(foot, coral)
    return root


SEA_FAN = Prop(
    name="sea_fan",
    build=build,
    category="coral",
    # The mesh measures 0.50 x 0.03 x 0.35 m. `footprint` is the radius of the circle the
    # fan sweeps as the tank yaws it, not the thickness of the blade — placing on the
    # 3 cm figure would let the tank stand two fans inside one another.
    footprint=0.26,
    height=0.37,
    tilt_range=(-7.0, 7.0),
    scale_range=(0.65, 1.15),
    weight=1.2,
    max_per_scene=3,
    seeds=4,
)
