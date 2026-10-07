"""What a model promises the runtime, independent of how it is built.

`docs/origami-plan.md` "Asset contract" is the binding version of this; the code here is
what enforces it. A model is a name, a kind and a build function. The build function makes
the geometry at real size in Blender's axes (nose / front toward +X, up +Z, left +Y) and
returns the root object plus any manifest fields only it can know; `build_model.py` does the
rest — seating, measuring, exporting — the same way for every model, so no model can get the
contract subtly different from its neighbours.
"""

from dataclasses import dataclass, field
from typing import Callable

KINDS = ("plane", "projectile", "tree", "rock", "house", "boat", "fire", "smoke", "tank",
         "bird", "crate", "parachute", "landmark", "animal", "vehicle", "building")

# Things that stand on the landscape are seated on z = 0. Everything else flies, or is
# placed by the simulation at an arbitrary height, and is centred on its own bounding box
# so that a rotation about the node's origin turns it about its middle. A crate falls but
# lands, so it is seated like a prop; a parachute is seated the same way because its lowest
# point is where it hangs from — the knot of its strings, on its axis — and that is the
# point the runtime ties to the crate's lid.
GROUNDED = frozenset({"tree", "rock", "house", "boat", "fire", "tank",
                      "crate", "parachute", "landmark", "animal", "vehicle", "building"})


@dataclass(frozen=True)
class Model:
    name: str
    kind: str
    # () -> (root object, extra manifest fields). The root is a mesh object or an Empty
    # named `name`; its children, if any, are the parts the runtime addresses by name (a
    # fire's `flame_<n>`, a tank's `turret`, a crane's `wing_l`, a windmill's `blades`).
    build: Callable[[], tuple]
    summary: str = ""
    # Review-sheet hints only; never read by the runtime.
    tags: tuple = field(default_factory=tuple)

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f"{self.name}: kind {self.kind!r} is not one of {KINDS}")

    @property
    def anchor(self):
        return "ground" if self.kind in GROUNDED else "center"

    def manifest(self, asset, bounds, materials, extra):
        lo, hi = bounds
        data = {
            "name": self.name,
            "kind": self.kind,
            "asset": asset,
            # Metres, in the authored Blender axes: +X nose / front, +Z up, +Y left.
            "bounds": {
                "min": [round(v, 6) for v in lo],
                "max": [round(v, 6) for v in hi],
            },
            # "ground": the model stands on z = 0 and is centred on the origin in x and y.
            # "center": the bounding box is centred on the origin in all three axes.
            "anchor": self.anchor,
            "materials": sorted(materials),
        }
        data.update(extra)
        return data
