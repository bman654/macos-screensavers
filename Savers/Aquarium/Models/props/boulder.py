"""A weathered boulder — the simplest possible prop, and the worked example.

Shows the whole contract: a `build(seed)` that returns a root object, geometry authored at
real scale in metres with the model sitting on z = 0, and placement data that lets the tank
scatter these without knowing what they are.
"""

import bpy

from saverlib import assign, rock, rock_material

from ._spec import Prop


def build(seed=0):
    root = bpy.data.objects.new("decor_boulder", None)
    bpy.context.collection.objects.link(root)

    # Angularity low: these have been rolled by surge long enough to lose their edges.
    body = rock("part_boulder", radius=0.26, angularity=0.28, seed=seed,
                lumpiness=0.40, flatten=0.30)
    body.parent = root
    assign(body, rock_material(
        f"boulder_{seed}", size=0.5,
        base=(0.088, 0.086, 0.080), secondary=(0.052, 0.055, 0.050),
        speckle=0.55, algae=0.45, seed=seed,
    ))
    return root


BOULDER = Prop(
    name="boulder",
    build=build,
    category="rock",
    # Measured off the built mesh at scale 1.0: 0.592 x 0.576 x 0.433 m, so the half-extent
    # is 0.296 and the circumscribed radius 0.41. Declared between the two: a boulder is
    # round enough that the circumscribed radius would waste a lot of seabed, and rock
    # meeting rock is the one overlap that reads as natural rather than as a mistake.
    # The previous 0.26 was under the half-extent, which let neighbours genuinely encroach.
    footprint=0.31,
    height=0.44,
    tilt_range=(-8.0, 8.0),
    scale_range=(0.55, 1.60),
    weight=2.4,
    seeds=4,
)
