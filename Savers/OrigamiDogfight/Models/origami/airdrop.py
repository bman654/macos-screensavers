"""A supply drop: a folded paper crate under a tissue-paper parachute.

Both are desk-sized, like the planes that race for the crate. From straight above the
canopy hides the crate as it falls, so the canopy has to say "parachute" by itself: eight
gores of alternating pale tissue, each creased down its middle, read as a striped umbrella
rather than one more white blob. The crate is seen once it lands, and peeks out under the
camera's tilt while it falls: a kraft box whose lid carries crossed tape straps and a
raised white star, the mark of a supply drop.

`parachute` hangs from its origin: the lowest point of the model is the knot where its
strings meet, on the canopy's axis, so the runtime ties it to the middle of the crate's lid
(the top of the crate's bounds) and nothing else needs to be said in the manifest.
"""

import math

from ._spec import Model
from .mesh import flat_material, join, mesh_object
from .nets import convex

_CRATE_HALF = 0.024      # the box's half width
_LID_HALF = 0.0255       # the lid overhangs the box all round
_LID_TOP = 0.040


def _box(x0, x1, y0, y1, z0, z1):
    return [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]


def _solid(name, points, material):
    verts, faces, _ = convex(points, material)
    return mesh_object(name, verts, faces, [material])


def _star(name, centre_z, outer, inner, rise, material):
    """A five-pointed paper star folded up to a peak: ridges to the points, valleys between
    them, so each arm is two facets lit differently. One point faces +X."""
    rim = []
    for k in range(10):
        angle = math.tau * k / 10
        radius = outer if k % 2 == 0 else inner
        rim.append((radius * math.cos(angle), radius * math.sin(angle), centre_z))
    verts = rim + [(0.0, 0.0, centre_z + rise)]
    faces = [(k, (k + 1) % 10, 10) for k in range(10)]
    return mesh_object(name, verts, faces, [material])


def _build_crate():
    kraft = flat_material("paper_crate", "#b98a55")
    lid = flat_material("paper_crate_lid", "#cda26a")
    strap = flat_material("paper_crate_strap", "#7c5330")
    star = flat_material("paper_crate_star", "#f7f3ea")
    b, top = _CRATE_HALF, _LID_TOP
    objects = [
        _solid("crate_box", _box(-b, b, -b, b, 0.0, 0.032), kraft),
        _solid("crate_lid", _box(-_LID_HALF, _LID_HALF, -_LID_HALF, _LID_HALF, 0.0285, top),
               lid),
    ]
    # Two tapes crossing over the lid and down every side: each a band over the lid and a
    # band round the box below it, standing a hair proud of the paper they wrap.
    band, proud = 0.0036, 0.0007
    for axis in (0, 1):
        for reach, z0, z1 in ((_LID_HALF + proud, 0.0280, top + proud),
                              (b + proud, 0.0, 0.0290)):
            x = (-reach, reach) if axis == 0 else (-band, band)
            y = (-band, band) if axis == 0 else (-reach, reach)
            objects.append(_solid(f"crate_strap_{axis}_{len(objects)}",
                                  _box(*x, *y, z0, z1), strap))
    objects.append(_star("crate_star", top + proud + 0.0002, 0.0165, 0.0068, 0.0035, star))
    return join(objects, "supply_crate"), {}


# ---- parachute -------------------------------------------------------------------------

_GORES = 8
_HEM_RADIUS = 0.056
_HEM_Z = 0.090
# (radius at a seam, height) from the hem up; the gore's middle bulges out past its seams.
_RINGS = ((_HEM_RADIUS, _HEM_Z), (0.047, 0.117), (0.025, 0.134))
_APEX_Z = 0.140
_BULGE = 1.07
_SCALLOP = 0.006         # how far the hem rises between two strings


def _canopy(white, stripe):
    """Eight gores, each two facets per band either side of a crease down its middle."""
    verts, faces, slots = [], [], []
    apex = 0
    verts.append((0.0, 0.0, _APEX_Z))

    def ring_point(angle, radius, z):
        return (radius * math.cos(angle), radius * math.sin(angle), z)

    # Index rows: for each ring, 2 * _GORES points alternating seam, gore middle.
    rows = []
    for level, (radius, z) in enumerate(_RINGS):
        row = []
        for k in range(2 * _GORES):
            angle = math.tau * k / (2 * _GORES)
            if k % 2 == 0:
                point = ring_point(angle, radius, z)
            else:
                lift = _SCALLOP if level == 0 else 0.0
                bulge = 0.98 if level == 0 else _BULGE
                point = ring_point(angle, radius * bulge, z + lift)
            row.append(len(verts))
            verts.append(point)
        rows.append(row)
    count = 2 * _GORES
    for level in range(len(rows) - 1):
        low, high = rows[level], rows[level + 1]
        for k in range(count):
            j = (k + 1) % count
            faces.append((low[k], low[j], high[j], high[k]))
            slots.append((k // 2) % 2)
    crown = rows[-1]
    for k in range(count):
        faces.append((crown[k], crown[(k + 1) % count], apex))
        slots.append((k // 2) % 2)
    return mesh_object("parachute_canopy", verts, faces, [white, stripe], slots)


def _string(name, anchor, width, material):
    """A thin three-sided line from a seam of the hem to the knot at the origin."""
    direction = [-c for c in anchor]
    length = math.sqrt(sum(c * c for c in direction))
    d = [c / length for c in direction]
    # Two directions across the line: one horizontal, one completing the frame.
    side = (-d[1], d[0], 0.0)
    norm = math.hypot(side[0], side[1])
    side = (side[0] / norm, side[1] / norm, 0.0)
    other = (d[1] * side[2] - d[2] * side[1], d[2] * side[0] - d[0] * side[2],
             d[0] * side[1] - d[1] * side[0])
    top = []
    for k in range(3):
        angle = math.tau * k / 3
        c, s = math.cos(angle) * width, math.sin(angle) * width
        top.append(tuple(anchor[i] + side[i] * c + other[i] * s for i in range(3)))
    verts = top + [(0.0, 0.0, 0.0)]
    faces = [(k, (k + 1) % 3, 3) for k in range(3)] + [(2, 1, 0)]
    return mesh_object(name, verts, faces, [material])


def _build_parachute():
    white = flat_material("paper_canopy", "#f6f2e9", roughness=0.95)
    stripe = flat_material("paper_canopy_stripe", "#f5c7a2", roughness=0.95)
    string = flat_material("string", "#ddd6c6", roughness=0.9)
    objects = [_canopy(white, stripe)]
    for k in range(_GORES):
        angle = math.tau * k / _GORES
        # Tied a little inside the hem, so the line meets the paper rather than its edge.
        anchor = (_HEM_RADIUS * 0.985 * math.cos(angle), _HEM_RADIUS * 0.985 * math.sin(angle),
                  _HEM_Z + 0.001)
        objects.append(_string(f"parachute_string_{k}", anchor, 0.0004, string))
    return join(objects, "parachute"), {}


supply_crate = Model(name="supply_crate", kind="crate", build=_build_crate,
                     summary="Kraft paper box with a lighter lid, crossed tape straps and a "
                             "raised folded white star.")
parachute = Model(name="parachute", kind="parachute", build=_build_parachute,
                  summary="Tissue canopy of eight creased gores, white and pale peach, on "
                          "eight strings that meet at the knot it hangs from.")
