"""A paper smock windmill whose sails turn.

From straight above, sails that turn about a level axis are a disc seen edge-on, so what
reads is everything else plus the sails' own width and shadow:

- a red-brown octagonal cap at the centre, unlike any house roof, with a nose jutting
  forward over the windshaft, which gives the mill a front, ringed by the cream tower
  flaring out below it;
- four large white sails, each pitched 28 degrees to the wind like a real sail, so the two
  lying level show from above as a long white bar with real width across the front of the
  mill, which lengthens and shortens as they turn, and whose cross-shaped shadow turns on
  the ground beside it.

Contract (docs/origami-plan.md, Asset contract): the root is the tower mesh, named
`windmill`, with one mesh child `blades` — stocks, sails, hub and windshaft — whose origin is
the hub. The sails face +X and turn about the node's own X axis; at zero they stand as a
"+". Manifest addition: `blades` = {"node": "blades", "hub", "axis": [1, 0, 0], "radius",
"turn"} — `radius` is how far from the axis the sails reach at any angle, `turn` the sign of
the turn about +X that the wind drives them in (counter-clockwise seen from in front, as
Dutch mills turn).
"""

import math

from ._spec import Model
from .landmarks import window_material
from .mesh import flat_material, join, mesh_object
from .nets import convex

_TOWER_BASE = 2.0        # circumradius of the octagon at the ground
_TOWER_TOP = 1.15        # ... and where the cap sits
_TOWER_HEIGHT = 6.0
_HUB = (2.5, 0.0, 7.0)
_STOCK = 4.5             # each stock reaches this far from the hub
_SAIL = (1.1, 4.45)      # the sail cloth's inner and outer ends, from the hub
_CHORD = 1.7
_PITCH = math.radians(28.0)
_STOCK_HALF = 0.09
_PHASE = math.pi / 8     # a flat face, not a corner, to the front


def _tower_radius(z):
    return _TOWER_BASE + (_TOWER_TOP - _TOWER_BASE) * z / _TOWER_HEIGHT


def _ngon(radius, z, count=8, phase=_PHASE, centre=(0.0, 0.0)):
    return [(centre[0] + radius * math.cos(phase + math.tau * k / count),
             centre[1] + radius * math.sin(phase + math.tau * k / count), z)
            for k in range(count)]


def _solid(name, points, material):
    verts, faces, _ = convex(points, material)
    return mesh_object(name, verts, faces, [material])


def _on_wall(name, angle, bottom, top, half_width, material):
    """A flat panel on the octagonal face that looks toward `angle`, standing a hair off the
    sloping wall it is drawn on."""
    c, s = math.cos(angle), math.sin(angle)
    apothem = math.cos(_PHASE)
    verts = []
    for z, side in ((bottom, -1), (bottom, 1), (top, 1), (top, -1)):
        out = _tower_radius(z) * apothem + 0.03
        across = side * half_width
        verts.append((out * c - across * s, out * s + across * c, z))
    return mesh_object(name, verts, [(0, 1, 2, 3)], [material])


def _tower():
    wall = flat_material("paper_windmill_wall", "#eee3c9")
    roof = flat_material("paper_windmill_roof", "#93402c")
    door = flat_material("paper_door", "#42372f")
    window = window_material()
    nose = _HUB[0] - 0.35
    objects = [
        _solid("windmill_tower", _ngon(_TOWER_BASE, 0.0) + _ngon(_TOWER_TOP, _TOWER_HEIGHT),
               wall),
        # An octagonal cap with a short skirt, and a nose that carries the windshaft forward.
        _solid("windmill_cap",
               _ngon(1.38, 5.95) + _ngon(1.38, 6.15) + [(0.0, 0.0, 8.5)]
               + [(nose, y, z) for y, z in ((0.42, 6.5), (-0.42, 6.5),
                                            (0.30, 7.35), (-0.30, 7.35))],
               roof),
        _on_wall("windmill_door", 0.0, 0.0, 1.75, 0.45, door),
        _on_wall("windmill_window_l", math.pi / 2, 3.3, 4.05, 0.32, window),
        _on_wall("windmill_window_r", -math.pi / 2, 3.3, 4.05, 0.32, window),
        _on_wall("windmill_window_back", math.pi, 3.3, 4.05, 0.32, window),
    ]
    return join(objects, "windmill")


def _sail_frame(k):
    """Blade k's radial direction, and its trailing direction across the sail.

    A positive turn about +X moves a point at u toward X x u; the sail cloth lies on the
    other, trailing side of its stock, and slopes back from it (toward -X) by the pitch, so
    a wind from the front pushes every sail the way the mill turns.
    """
    angle = math.tau * k / 4
    u = (0.0, -math.sin(angle), math.cos(angle))
    lead = (0.0, -u[2], u[1])                       # X x u
    trail = (-math.sin(_PITCH), -lead[1] * math.cos(_PITCH), -lead[2] * math.cos(_PITCH))
    return u, lead, trail


def _point(*terms):
    return tuple(sum(scale * vector[i] for scale, vector in terms) for i in range(3))


def _blades():
    """Everything that turns, authored about the hub: windshaft, hub, two stocks, four
    sails and the bars across them."""
    sail = flat_material("paper_windmill_sail", "#f6f2e8", roughness=0.9)
    spar = flat_material("paper_windmill_spar", "#5a4030")
    h = _STOCK_HALF
    objects = [
        _solid("windmill_shaft",
               [(x, y, z) for x in (-0.9, 0.0) for y, z in
                [(p[0], p[1]) for p in _ngon(0.18, 0.0)]], spar),
        _solid("windmill_hub",
               [(x, y, z) for x in (-0.10, 0.22) for y, z in
                [(p[0], p[1]) for p in _ngon(0.32, 0.0)]] + [(0.30, 0.0, 0.0)], spar),
        _solid("windmill_stock_v", [(x, y, z) for x in (-0.08, 0.08) for y in (-h, h)
                                    for z in (-_STOCK, _STOCK)], spar),
        _solid("windmill_stock_h", [(x, y, z) for x in (-0.08, 0.08) for y in (-_STOCK, _STOCK)
                                    for z in (-h, h)], spar),
    ]
    inner, outer = _SAIL
    for k in range(4):
        u, lead, trail = _sail_frame(k)
        root = (-h, lead)                           # the sail starts at the stock's edge
        corners = [_point((inner, u), root), _point((outer, u), root),
                   _point((outer, u), root, (_CHORD, trail)),
                   _point((inner, u), root, (_CHORD, trail))]
        objects.append(mesh_object(f"windmill_sail_{k}", corners, [(0, 1, 2, 3)], [sail]))
        # Bars across the cloth, standing a little proud of its front face, as on a real sail.
        normal = (u[1] * trail[2] - u[2] * trail[1],
                  u[2] * trail[0] - u[0] * trail[2],
                  u[0] * trail[1] - u[1] * trail[0])
        if normal[0] < 0:
            normal = tuple(-c for c in normal)
        for b, r in enumerate((1.8, 2.8, 3.8)):
            near, far = r - 0.06, r + 0.06
            bar = [_point((near, u), root, (0.04, normal)),
                   _point((far, u), root, (0.04, normal)),
                   _point((far, u), root, (_CHORD, trail), (0.04, normal)),
                   _point((near, u), root, (_CHORD, trail), (0.04, normal))]
            objects.append(mesh_object(f"windmill_bar_{k}_{b}", bar, [(0, 1, 2, 3)], [spar]))
    return join(objects, "blades")


def _build_windmill():
    root = _tower()
    blades = _blades()
    reach = max(math.hypot(v.co.y, v.co.z) for v in blades.data.vertices)
    blades.parent = root
    blades.location = _HUB
    return root, {
        "blades": {"node": "blades", "hub": list(_HUB), "axis": [1, 0, 0],
                   "radius": round(reach, 6), "turn": 1},
    }


windmill = Model(name="windmill", kind="landmark", build=_build_windmill,
                 summary="Cream octagonal smock mill under a red-brown cap with a nose, "
                         "four big pitched white sails that turn about the hub.")
