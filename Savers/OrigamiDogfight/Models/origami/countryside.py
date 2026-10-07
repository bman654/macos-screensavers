"""Life on the landscape: sheep in the fields and little cars on the roads.

Both are drawn at landscape scale, so a sheep is about a dozen pixels and a car three times
that. What survives is colour and outline:

- `sheep`: a white puff of overlapping faceted wool lumps with a dark head and ears just
  in front of it, so from above it is a white blob with a dark "T" at one end, which says
  which way it is facing as it wanders.
- `car`: a chamfered body and roof in the material `paper`, which the runtime tints, under
  a dark glass cabin whose windscreen slopes far enough to show from above as a band ahead
  of the roof; the long bonnet and short boot point it along +X. Tyres stand just proud of
  the body. Its paper is UV-mapped as nets on one sheet, like a tank's (`nets.py`).
"""

import math
import random

from ._spec import Model
from .mesh import flat_material, join, mesh_object
from .nets import convex, paper, paper_meshes


def _solid(name, points, material):
    verts, faces, _ = convex(points, material)
    return mesh_object(name, verts, faces, [material])


def _lump(centre, radii, seed, count=18):
    """A faceted wool lump: points spread evenly over an ellipsoid, each nudged so the
    folds are irregular, and wrapped in their convex hull."""
    rng = random.Random(seed)
    golden = math.pi * (3.0 - math.sqrt(5.0))
    points = []
    for i in range(count):
        z = 1.0 - 2.0 * (i + 0.5) / count
        r = math.sqrt(1.0 - z * z)
        angle = golden * i + rng.uniform(-0.2, 0.2)
        reach = rng.uniform(0.88, 1.08)
        points.append((centre[0] + radii[0] * r * math.cos(angle) * reach,
                       centre[1] + radii[1] * r * math.sin(angle) * reach,
                       centre[2] + radii[2] * z * reach))
    return points


def _build_sheep():
    wool = flat_material("paper_wool", "#f3efe6", roughness=0.95)
    dark = flat_material("paper_sheep_dark", "#2f2a27")
    objects = []
    lumps = [((-0.05, 0.0, 0.62), (0.50, 0.36, 0.27)),     # the barrel of the body
             ((-0.32, 0.0, 0.66), (0.27, 0.31, 0.25)),     # rump
             ((0.20, 0.0, 0.67), (0.27, 0.32, 0.25)),      # shoulders
             ((-0.12, 0.11, 0.80), (0.26, 0.18, 0.14)),    # the fleece's crown, left
             ((0.04, -0.10, 0.79), (0.24, 0.18, 0.14)),    # ... and right
             ((-0.60, 0.0, 0.70), (0.08, 0.07, 0.07))]     # tail
    for i, (centre, radii) in enumerate(lumps):
        objects.append(_solid(f"sheep_wool_{i}", _lump(centre, radii, seed=31 + i), wool))
    # A long dark face, wider at the brow, drooping to the muzzle.
    head = [(0.40, y, z) for y in (-0.11, 0.11) for z in (0.62, 0.86)] + \
           [(0.76, y, z) for y in (-0.065, 0.065) for z in (0.50, 0.64)]
    objects.append(_solid("sheep_head", head, dark))
    for side in (1, -1):
        ear = [(0.55, side * 0.09, 0.82), (0.45, side * 0.09, 0.82),
               (0.50, side * 0.09, 0.78), (0.50, side * 0.31, 0.76),
               (0.49, side * 0.31, 0.79)]
        objects.append(_solid(f"sheep_ear_{side}", ear, dark))
        for x in (0.26, -0.33):
            leg = [(x + dx, side * 0.16 + dy, z) for dx in (-0.045, 0.045)
                   for dy in (-0.045, 0.045) for z in (0.0, 0.48)]
            objects.append(_solid(f"sheep_leg_{side}_{x}", leg, dark))
    return join(objects, "sheep"), {}


def _box(x0, x1, y0, y1, z0, z1):
    return [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]


def _wheel(x, y, radius, width, material):
    """An octagonal tyre on an axle along Y, a flat on the ground."""
    ring = [(radius * math.cos(math.pi / 8 + math.tau * k / 8),
             radius * math.sin(math.pi / 8 + math.tau * k / 8)) for k in range(8)]
    return convex([(x + dx, y + dy, radius + dz) for dx, dz in ring
                   for dy in (-width * 0.5, width * 0.5)], material)


def _build_car():
    body, tyre = paper(), flat_material("paper_tyre", "#2b2826")
    glass = flat_material("paper_windscreen", "#3c4b58", roughness=0.6)
    parts = [
        # The lower body: a chamfered box, the bonnet sloping a little toward the nose.
        convex([(x, y, 0.24) for x in (-1.92, 1.92) for y in (-0.80, 0.80)]
               + [(x, y, z) for x, z in ((2.02, 0.58), (-2.0, 0.62)) for y in (-0.86, 0.86)]
               + [(x, y, z) for x, z in ((1.88, 0.80), (-1.90, 0.86)) for y in (-0.80, 0.80)],
               body),
        # The cabin: glass all round, raked hard at the front, short and steep behind.
        convex([(x, y, 0.82) for x in (-1.40, 0.70) for y in (-0.76, 0.76)]
               + [(x, y, 1.40) for x in (-1.18, 0.05) for y in (-0.64, 0.64)], glass),
        # The roof: a lid of body paper just overhanging the glass.
        convex(_box(-1.22, 0.09, -0.67, 0.67, 1.38, 1.44), body),
    ]
    for x in (1.30, -1.30):
        for y in (0.79, -0.79):
            parts.append(_wheel(x, y, 0.34, 0.24, tyre))
    objects, aspect = paper_meshes({"car": parts}, gap=0.05)
    return objects["car"], {"sheetAspect": round(aspect, 6)}


sheep = Model(name="sheep", kind="animal", build=_build_sheep,
              summary="White puff of faceted wool lumps on four dark legs, with a long dark "
                      "face and ears sticking out sideways.")
car = Model(name="car", kind="vehicle", build=_build_car,
            summary="Little folded hatchback: tinted chamfered body and roof, dark raked "
                    "glass cabin, four octagonal tyres.")
