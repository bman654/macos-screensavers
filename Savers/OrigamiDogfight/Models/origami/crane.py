"""The paper crane: the classic orizuru, wings spread, as a flock crosses the fight.

Seen from straight above at about 80 px, a crane has to read as a bird and not as one more
paper plane. What carries it is the four-pointed outline only an orizuru has: a thin neck
and head reaching forward, a thin tail reaching back, and two long triangular wings out to
the sides. Neck and tail are raised only about 30 degrees, rather than the steep points of a
crane on a shelf, so from above they keep most of their length. The tail is a little broader
than the neck, and the neck ends in a reverse-folded head, so the two ends differ.

Contract (docs/origami-plan.md, Asset contract): the root is the body mesh, named `crane`,
with two mesh children `wing_l` (+Y) and `wing_r` (-Y). Each wing's origin is on its hinge
line along X, the wing's root edge lies on that line, and the runtime flaps it by turning
the node about its own X axis; at zero both wings are level. Everything is the material
`paper`, which the runtime replaces per crane, and the UVs are the crane seen from above on a
square sheet (`sheetAspect` 1), the way an orizuru is folded from a square.

Manifest additions: `sheetAspect`, and `wings` = {"axis": [1, 0, 0], "nodes": [{"node":
"wing_l", "pivot", "lift": 1}, {"node": "wing_r", "pivot", "lift": -1}], "range": [down, up]}
— `lift` is the sign of a turn about the node's +X that raises that wing, `range` how far
in degrees a wing may swing either way before it would meet the body.
"""

from ._spec import Model
from .mesh import mesh_object
from .nets import convex, paper

# Half the spine's width: each wing hinges this far either side of the centre line, so a
# narrow ridge of back shows between the wings from above.
_SPINE = 0.004
_ROOT = 0.026        # the wing root runs from -_ROOT to +_ROOT along X
_SPAN_OUT = 0.086    # tip's reach beyond the hinge
_RANGE = (-35, 60)   # degrees of lift; past these a wing would fold into the body


def _blade(stations, tip):
    """A tapering spike of folded paper, lofted through vertical diamond sections.

    Each station is (point, half width, rise above, drop below); the spike closes at `tip`.
    A diamond rather than a flat blade keeps the neck a few pixels wide from above while it
    still looks like a pressed point from the side.
    """
    verts = []
    for (x, y, z), half, rise, drop in stations:
        verts += [(x, y + half, z), (x, y, z + rise), (x, y - half, z), (x, y, z - drop)]
    faces = []
    for ring in range(len(stations) - 1):
        a, b = ring * 4, ring * 4 + 4
        for k in range(4):
            j = (k + 1) % 4
            faces.append((a + k, b + k, b + j, a + j))
    end = len(verts)
    verts.append(tip)
    last = (len(stations) - 1) * 4
    for k in range(4):
        faces.append((last + k, end, last + (k + 1) % 4))
    return verts, faces


def _wing(side):
    """One wing in its own space: origin mid-root, root edge on the X axis, reaching toward
    `side` (+1 left, -1 right). A low tent rises inboard so the wing is three facets that
    each catch the sun differently, the way a pressed paper wing never quite lies flat."""
    front, back = (_ROOT, 0.0, 0.0), (-_ROOT, 0.0, 0.0)
    tip = (-0.020, side * _SPAN_OUT, 0.0)
    peak = (0.0, side * 0.026, 0.005)
    faces = [(back, front, peak), (front, tip, peak), (peak, tip, back)]
    if side < 0:
        faces = [face[::-1] for face in faces]   # mirrored, wound to face up again
    verts = [p for face in faces for p in face]
    return verts, [(3 * i, 3 * i + 1, 3 * i + 2) for i in range(len(faces))]


def _sheet_uvs(verts, offset, size):
    """The crane from above on a square sheet `size` across: u across (right is +u, as on
    every other sheet here), v along the body, nose toward v = 1."""
    return [(0.5 - (y + offset[1]) / size, 0.5 + (x + offset[0]) / size) for x, y, _ in verts]


def _build_crane():
    material = paper()
    body_verts, body_faces = [], []

    def add(verts, faces):
        start = len(body_verts)
        body_verts.extend(verts)
        body_faces.extend([start + i for i in face] for face in faces)

    # The body: a diamond keel under a spine, its upper edges the two wing hinges.
    keel = [(_ROOT, 0.0, 0.003), (-_ROOT, 0.0, 0.003),
            (_ROOT, _SPINE, 0.0), (-_ROOT, _SPINE, 0.0),
            (_ROOT, -_SPINE, 0.0), (-_ROOT, -_SPINE, 0.0),
            (0.0, 0.0, -0.022), (0.034, 0.0, -0.008), (-0.034, 0.0, -0.008)]
    add(*convex(keel, material)[:2])
    # Neck rising forward from inside the body, then the head folded down to the beak.
    add(*_blade([((0.018, 0.0, -0.012), 0.0045, 0.004, 0.007),
                 ((0.080, 0.0, 0.026), 0.0020, 0.0015, 0.0025)],
                tip=(0.095, 0.0, 0.015)))
    # The tail: broader at the root than the neck, one long taper to its point.
    add(*_blade([((-0.018, 0.0, -0.012), 0.0060, 0.004, 0.007),
                 ((-0.060, 0.0, 0.012), 0.0035, 0.002, 0.003)],
                tip=(-0.092, 0.0, 0.028)))

    wings = {"wing_l": (_wing(1.0), (0.0, _SPINE, 0.0)),
             "wing_r": (_wing(-1.0), (0.0, -_SPINE, 0.0))}
    xs = [p[0] for p in body_verts] + [p[0] + o[0] for (v, _), o in wings.values() for p in v]
    ys = [p[1] for p in body_verts] + [p[1] + o[1] for (v, _), o in wings.values() for p in v]
    # Centred on the plan's middle and a hair larger than it, so no corner sits on the edge.
    middle = ((max(xs) + min(xs)) * 0.5, (max(ys) + min(ys)) * 0.5)
    size = max(max(xs) - min(xs), max(ys) - min(ys)) * 1.02

    def uvs(verts, faces, origin):
        corners = _sheet_uvs(verts, (origin[0] - middle[0], origin[1] - middle[1]), size)
        return [corners[i] for face in faces for i in face]

    root = mesh_object("crane", body_verts, body_faces, [material],
                       uvs=uvs(body_verts, body_faces, (0.0, 0.0)))
    for name, ((verts, faces), origin) in wings.items():
        wing = mesh_object(name, verts, faces, [material], uvs=uvs(verts, faces, origin))
        wing.parent = root
        wing.location = origin
    return root, {
        "sheetAspect": 1.0,
        "wings": {
            "axis": [1, 0, 0],
            "nodes": [{"node": "wing_l", "pivot": [0.0, _SPINE, 0.0], "lift": 1},
                      {"node": "wing_r", "pivot": [0.0, -_SPINE, 0.0], "lift": -1}],
            "range": list(_RANGE),
        },
    }


crane = Model(name="crane", kind="bird", build=_build_crane,
              summary="Classic orizuru, wings spread: neck and head forward, tail back, "
                      "two long folded triangular wings that flap about their root edges.")
