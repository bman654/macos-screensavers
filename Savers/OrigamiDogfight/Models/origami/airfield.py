"""A team's hangar, at the end of the runway the runtime draws in front of it.

A Quonset hut folded from a sheet: a half-round roof of seven flat folds, open at the front
(+X), with ribs across it. From straight above it is a long grey arch whose folds shade in
bands, crossed by dark ribs, with the team's colour down the ridge: the top fold is the
material `paper`, which the runtime tints per team. Through the open end, under the
camera's tilt, a dark interior says it is open and something can come out of it.

The ridge stripe is cut at the ribs into six pieces, each its own net, so its sheet stays
the shape of a sheet of paper rather than a 6:1 ribbon the runtime would refuse.

Manifest addition: `opening` = {"centre": [x, y, z], "width", "height"} — the middle of the
open end on the floor, and its clear width and height, so the runtime can line the runway
up with the door and roll a plane or tank out of it.
"""

import math

from ._spec import Model
from .landmarks import window_material
from .mesh import flat_material
from .nets import paper, paper_meshes

_LENGTH = 14.0
_RADIUS = 5.0
_SHELL = 0.12            # the roof paper's thickness, shown at the open end
_FOLDS = 7
_RIB_PROUD, _RIB_HALF = 0.09, 0.14
_STRIPE = 3              # the fold on the ridge


def _arc(radius, x):
    """The arch's fold lines at `x`, from the left foot (+Y) over the top to the right."""
    return [(x, radius * math.cos(math.pi * i / _FOLDS), radius * math.sin(math.pi * i / _FOLDS))
            for i in range(_FOLDS + 1)]


def _band(x0, x1, radius, folds, material, outward=True):
    """The arch's folds `folds` as quads from x0 to x1, facing out of (or into) the arch."""
    a, b = _arc(radius, x0), _arc(radius, x1)
    verts, faces = [], []
    for i in folds:
        start = len(verts)
        verts += [a[i], a[i + 1], b[i + 1], b[i]]
        faces.append([start, start + 1, start + 2, start + 3] if outward
                     else [start + 3, start + 2, start + 1, start])
    return verts, faces, material


def _ring(x, inner, outer, material, facing):
    """The flat end of a curved band at `x`, between two radii, facing +X or -X."""
    a, b = _arc(inner, x), _arc(outer, x)
    verts, faces = [], []
    for i in range(_FOLDS):
        start = len(verts)
        verts += [a[i], b[i], b[i + 1], a[i + 1]]
        quad = [start, start + 1, start + 2, start + 3]
        faces.append(quad if facing > 0 else quad[::-1])
    return verts, faces, material


def _rib(x0, x1, material):
    """A fold rib standing proud of the roof all the way over it."""
    outer = _RADIUS + _RIB_PROUD
    top = _band(x0, x1, outer, range(_FOLDS), material)
    back = _ring(x0, _RADIUS, outer, material, -1)
    front = _ring(x1, _RADIUS, outer, material, 1)
    verts, faces = [], []
    for part_verts, part_faces, _ in (top, back, front):
        start = len(verts)
        verts += part_verts
        faces += [[start + i for i in face] for face in part_faces]
    return verts, faces, material


def _flat(points, material):
    return list(points), [list(range(len(points)))], material


def _build_hangar():
    roof = flat_material("paper_hangar_roof", "#c3c5bd")
    rib = flat_material("paper_hangar_rib", "#878a82")
    inside = flat_material("paper_hangar_inside", "#5b554c")
    floor = flat_material("paper_hangar_floor", "#8e8a80")
    wall = flat_material("paper_hangar_wall", "#e7dfcc")
    door = flat_material("paper_door", "#42372f")
    window = window_material()
    team = paper()

    back, front = -_LENGTH * 0.5, _LENGTH * 0.5
    inner = _RADIUS - _SHELL
    ribs = [back + _LENGTH * k / 6 for k in range(7)]
    parts = [_band(back, front, _RADIUS, [i for i in range(_FOLDS) if i != _STRIPE], roof)]
    # The team's stripe, cut at the ribs; the ribs cover the joins.
    for x0, x1 in zip(ribs, ribs[1:]):
        parts.append(_band(x0, x1, _RADIUS, [_STRIPE], team))
    parts += [
        _band(back, front, inner, range(_FOLDS), inside, outward=False),
        _ring(front, inner, _RADIUS, rib, 1),                      # the cut edge at the door
        _flat([(back + 0.01, inner, 0.01), (front, inner, 0.01),
               (front, -inner, 0.01), (back + 0.01, -inner, 0.01)][::-1], floor),
        # The back wall closes the arch to its outer edge; wound to face out, -X.
        _flat(_arc(_RADIUS, back)[::-1], wall),
    ]
    # Ribs: the end ones flush with the ends of the hangar, so its length is exactly 14 m.
    for k, x in enumerate(ribs):
        x0 = x if k == 0 else (x - 2 * _RIB_HALF if k == len(ribs) - 1 else x - _RIB_HALF)
        parts.append(_rib(x0, x0 + 2 * _RIB_HALF, rib))
    # A small door and a window in the back wall, on its outside.
    face = back - 0.02
    parts.append(_flat([(face, -1.6, 0.0), (face, -2.6, 0.0), (face, -2.6, 2.0),
                        (face, -1.6, 2.0)], door))
    parts.append(_flat([(face, 2.6, 1.6), (face, 1.6, 1.6), (face, 1.6, 2.5),
                        (face, 2.6, 2.5)], window))

    objects, aspect = paper_meshes({"hangar": parts}, gap=0.05)
    return objects["hangar"], {
        "sheetAspect": round(aspect, 6),
        "opening": {"centre": [front, 0.0, 0.0], "width": round(2 * inner, 6),
                    "height": round(inner, 6)},
    }


hangar = Model(name="hangar", kind="building", build=_build_hangar,
               summary="Quonset hangar of seven grey folds and dark ribs, open at the front, "
                       "with the team's colour down the ridge.")
