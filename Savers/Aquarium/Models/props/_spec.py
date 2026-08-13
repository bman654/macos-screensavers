"""The data shape a prop is described in.

A prop is anything in the tank that is not a fish: coral, a plant, a rock, a treasure
chest. Unlike a species, its geometry cannot be reduced to profile numbers — a chest and a
sea fan share nothing — so a prop pairs a `build` callable with the placement and
animation data the tank needs to use it.

Everything here except `build` ends up in the model's manifest, which is what lets the
saver place and animate a prop without knowing what it is. See `docs/decorations.md`.
"""


class Part:
    """A rigid piece that moves, and how far.

    `node` must name an object in the built model whose **origin is its pivot** — Blender
    writes an object's origin as its prim transform, so a lid hinges correctly if and only
    if its origin sits on the hinge line.
    """

    def __init__(self, node, axis=(1.0, 0.0, 0.0), open_degrees=60.0):
        self.node = node
        self.axis = axis
        self.open_degrees = open_degrees


class Emitter:
    """A bubble source, marked in the model by an empty named `emit_<something>`.

    Parenting the empty to a moving part is what makes bubbles leave from wherever that
    part currently is, rather than from a fixed point in space.
    """

    def __init__(self, node, rate=40.0, radius=0.012, size=(0.002, 0.005),
                 speed=0.09, continuous=False):
        self.node = node
        self.rate = rate
        self.radius = radius
        self.size = size
        self.speed = speed
        self.continuous = continuous


class Phase:
    """One step of an animation cycle.

    `duration` may be a number or a `(min, max)` range sampled per cycle. Ranges are not
    decoration: several chests on screen opening in lockstep is the most mechanical-looking
    failure available here.
    """

    def __init__(self, phase, duration, part=None, to=None, emitter=None, ease="easeInOut"):
        self.phase = phase
        self.duration = duration
        self.part = part
        self.to = to
        self.emitter = emitter
        self.ease = ease


class Prop:
    def __init__(
        self,
        name,
        build,
        category="decoration",
        footprint=0.20,
        height=0.20,
        yaw_range=(-180.0, 180.0),
        tilt_range=(0.0, 0.0),
        scale_range=(1.0, 1.0),
        weight=1.0,
        max_per_scene=None,
        min_spacing=None,
        parts=(),
        emitters=(),
        cycle=(),
        seeds=1,
    ):
        self.name = name
        self.build = build                    # build(seed) -> root object
        self.category = category              # decoration | coral | plant | rock
        self.footprint = footprint            # radius in metres
        self.height = height
        self.yaw_range = yaw_range
        self.tilt_range = tilt_range
        self.scale_range = scale_range
        self.weight = weight                  # bias in the random draw
        self.max_per_scene = max_per_scene    # cap the showpieces
        self.min_spacing = min_spacing        # centre-to-centre, defaults to 2x footprint
        self.parts = list(parts)
        self.emitters = list(emitters)
        self.cycle = list(cycle)
        self.seeds = seeds                    # how many distinct variants to export

    def manifest(self, asset):
        """The JSON the runtime reads. Mirrors `docs/decorations.md`."""
        data = {
            "name": self.name,
            "asset": asset,
            "category": self.category,
            "placement": {
                "anchor": "floor",
                "footprint": self.footprint,
                "height": self.height,
                "yawRange": list(self.yaw_range),
                "tiltRange": list(self.tilt_range),
                "scaleRange": list(self.scale_range),
                "weight": self.weight,
                "minSpacing": self.min_spacing
                if self.min_spacing is not None
                else self.footprint * 2.0,
            },
        }
        if self.max_per_scene is not None:
            data["placement"]["maxPerScene"] = self.max_per_scene
        if self.parts:
            data["parts"] = [
                {"node": p.node, "axis": list(p.axis), "openDegrees": p.open_degrees}
                for p in self.parts
            ]
        if self.emitters:
            data["emitters"] = [
                {
                    "node": e.node, "rate": e.rate, "radius": e.radius,
                    "size": list(e.size), "speed": e.speed,
                    **({"continuous": True} if e.continuous else {}),
                }
                for e in self.emitters
            ]
        if self.cycle:
            data["cycle"] = [
                {
                    "phase": p.phase, "duration": p.duration,
                    **({"part": p.part} if p.part else {}),
                    **({"to": p.to} if p.to is not None else {}),
                    **({"emitter": p.emitter} if p.emitter else {}),
                    **({"ease": p.ease} if p.part else {}),
                }
                for p in self.cycle
            ]
        return data
