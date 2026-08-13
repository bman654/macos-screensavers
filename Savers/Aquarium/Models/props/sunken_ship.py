"""A small wooden sailing ship, wrecked and part-buried on the seabed.

The tank's showpiece, and the one prop where the interesting decision is what *not* to
build. An intact ship spends a lot of geometry on a shape everybody knows; a wreck is the
same silhouette with three cheap, unmistakable cues on top — lying over on one side,
broken open, encrusted — none of which survives being tidied up.

The hull is a parametric surface (`_hull_point`) and every plank on it is a
`hardsurface.plank` warped onto that surface, keeping its own seeded bow, cup and twist. A
hull of identical boards is the clearest tell that a wreck was generated, so every strake
gets its own seed and its own standoff.

The hole is also the passage, and its radius is the number the whole midsection is designed
around. A fish is 0.12 m tall in its worst dimension, so 0.13 m is plenty, and keeping the
figure that low is what lets the wreck keep its deck, its garboard and one continuous
starboard rail — without those it reads as two small boats sharing a keel rather than as
one broken hull. The route runs in low through the port side, *under* the surviving deck,
and out through the starboard breach, which the heel has stood on end so that it faces
nearly straight up. That radius also sets how deep the hull is, where the mast is stepped,
which frames are cut to floor timbers, which strakes survive and how far the deck's port
edge is torn back; each is commented where it is set.

Attitude is a rotation on one intermediate empty rather than baked into the vertices:
`wood_material` runs its grain along object X, so every mesh has to stay in ship coordinates
for the grain to run fore-and-aft whatever the export's join order turns out to be. The
seabed drifts belong to the floor, so their upright placement is pre-multiplied by the
inverse attitude and they hang off the same empty.
"""

import random
from math import cos, pi, radians, sin, tau

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

from saverlib import (
    IRON, RUST, Noise, Profile, SweptTube, assign, beveled_box, displace,
    metal_material, plank, revolve, rock, sand_material, shade_smooth, wood_material,
)

from ._spec import Passage, Prop


# -- the hull surface ----------------------------------------------------------------
#
# Three curves in metres define the boat; everything else — planking, frames, deck, transom
# — is placed by asking this surface for a point and a normal. The profiles are
# monotone-cubic: an overshooting spline through a half-beam point would give a negative
# width and an inside-out hull.

_HALF_BEAM = Profile([
    (-0.82, 0.172), (-0.62, 0.216), (-0.38, 0.250), (-0.10, 0.262), (0.18, 0.256),
    (0.44, 0.219), (0.66, 0.148), (0.82, 0.070), (0.93, 0.016),
])

_KEEL = Profile([
    (-0.82, 0.072), (-0.60, 0.018), (-0.20, 0.000), (0.16, 0.008), (0.48, 0.062),
    (0.74, 0.178), (0.93, 0.318),
])

# Deliberately deep for the beam. The hold has to fit a fish *under a deck* with clearance
# above and below, and depth is the only dimension that buys that: a shallower hull would
# have forced the deck off again.
_SHEER = Profile([
    (-0.82, 0.482), (-0.46, 0.442), (-0.06, 0.430), (0.34, 0.454), (0.66, 0.502),
    (0.86, 0.562), (0.93, 0.594),
])

# Section fullness: above 1 the sections are V-shaped (a fine entry at the bow), below 1
# they have flat floors (a full run aft). One number per station stops every frame being
# the same U.
_FULLNESS = Profile([
    (-0.82, 0.80), (-0.30, 0.78), (0.10, 0.95), (0.50, 1.35), (0.93, 1.90),
])

# Above this the topsides stand nearly vertical, which separates a boat from a bowl.
_TOPSIDE = 0.80

_X_FORE = 0.93
_STRAKES = 8
_PLANK_THICKNESS = 0.017
_DECK_DROP = 0.050          # deck below the sheer, so the hull keeps a real bulwark

# Where the swim route crosses, in stations, and how high it runs. Everything in the
# midsection — frames, deck beams, which strakes survive — is placed around these two.
_HOLD_X = -0.15
_HOLD_Z = 0.205


def _section(t, fullness):
    """Girth fraction at height fraction `t`, 0 at the keel and 1 at the sheer."""
    u = min(1.0, t / _TOPSIDE) ** fullness
    width = u * u * (3.0 - 2.0 * u)
    if t > _TOPSIDE:
        width += 0.06 * (t - _TOPSIDE) / (1.0 - _TOPSIDE)
    return width


def _hull_point(x, t, side):
    z0, z1 = _KEEL(x), _SHEER(x)
    return Vector((
        x,
        side * _HALF_BEAM(x) * _section(t, _FULLNESS(x)),
        z0 + (z1 - z0) * t,
    ))


def _hull_normal(x, t, side):
    """Outward unit normal, by finite difference of the surface."""
    along = _hull_point(x + 0.004, t, side) - _hull_point(x - 0.004, t, side)
    across = (_hull_point(x, min(1.0, t + 0.01), side)
              - _hull_point(x, max(0.0, t - 0.01), side))
    normal = across.cross(along) if side > 0 else along.cross(across)
    if normal.length < 1e-9:
        return Vector((0.0, side, 0.0))
    return normal.normalized()


def _strake_aft_end(t):
    """Where a strake stops aft, following the transom's rake so it tucks behind it."""
    return -0.855 - 0.085 * t


def _deck_z(x):
    return _SHEER(x) - _DECK_DROP


def _deck_half(x):
    z0, z1 = _KEEL(x), _SHEER(x)
    t = (_deck_z(x) - z0) / max(z1 - z0, 1e-6)
    return _HALF_BEAM(x) * _section(t, _FULLNESS(x))


# -- mesh plumbing -------------------------------------------------------------------


def _place(obj, matrix):
    """Bake a placement into the mesh, leaving the object's transform identity.

    Parts are authored at the origin and moved here rather than by setting `obj.location`,
    so the ship is one flat set of meshes in one space: nothing carries a transform that a
    join, an export or a material's object coordinates could disagree about.
    """
    obj.data.transform(matrix)
    return obj


def _mesh_object(name, bm, sharp_angle=38.0):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    shade_smooth(mesh)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    split = obj.modifiers.new("EdgeSplit", "EDGE_SPLIT")
    split.split_angle, split.use_edge_angle, split.use_edge_sharp = (
        radians(sharp_angle), True, False)
    return obj


# -- planking ------------------------------------------------------------------------


def _warped_plank(name, x0, x1, t0, t1, side, seed, standoff,
                  thickness=_PLANK_THICKNESS, bow=0.006, cup=0.06, twist=6.0,
                  flare=0.0, flare_at_fore=True):
    """One board bent onto the hull between two stations and two girth fractions.

    `plank` builds a flat board carrying seeded bow, cup, twist and grain in its Z; that Z
    becomes an offset along the hull normal here, so the warp survives being wrapped round
    a curved surface. Solidifying about the surface puts the inner face exactly on
    `_hull_point`, so the hold's usable volume is the profiles above and the passage
    clearances can be reasoned about from them. `flare` peels one end away from the hull —
    a sprung plank, which is what the edge of a hull breach looks like.
    """
    length = x1 - x0
    middle = 0.5 * (x0 + x1)
    girth = (_hull_point(middle, t1, side) - _hull_point(middle, t0, side)).length
    board = plank(
        name, length=length, width=girth, thickness=thickness,
        bow=bow, cup=cup, twist=twist, seed=seed, bevel=0.35,
        samples_u=max(6, int(length / 0.07) + 5), samples_v=4,
    )
    centre_t = 0.5 * (t0 + t1)
    span_t = t1 - t0
    for vert in board.data.vertices:
        u = min(1.0, max(0.0, vert.co.x / length + 0.5))
        t = min(1.0, max(0.0, centre_t + (vert.co.y / girth) * span_t))
        x = x0 + length * u
        ramp = u if flare_at_fore else 1.0 - u
        push = standoff + vert.co.z + flare * ramp * ramp
        vert.co = _hull_point(x, t, side) + _hull_normal(x, t, side) * push
    board.data.update()
    return board


# What is gone from each side: the span of stations missing from strake `k`, garboard
# (k = 0) excepted. The span must widen monotonically going up — a side crushed down from
# the deck flares open at the top, and, less obviously, a strake whose span is narrower
# than the one below leaves two board ends jutting into the opening, which is where the
# swim route runs. Getting that backwards cost half the clearance the first time.
def _breach(k, side):
    """The span of stations missing from strake `k`, or None if the strake survives.

    The garboard survives both sides, and so does the *starboard* sheer strake: one
    unbroken rail stem to stern is the cheapest thing that stops the two ends reading as
    two boats. The port rail goes — that is the side the route leaves by, and a heeled
    hull's low rail overhangs its own opening.
    """
    if k < 1 or (side > 0 and k >= _STRAKES - 1):
        return None
    aft, fore = (-0.26, -0.02) if side > 0 else (-0.28, -0.01)
    return aft - 0.022 * (k - 1), fore + 0.020 * (k - 1)



def _planking(rng, seed):
    boards = []
    for side in (1.0, -1.0):
        for k in range(_STRAKES):
            t0 = max(0.0, k / _STRAKES - 0.012)
            t1 = min(1.0, (k + 1) / _STRAKES + 0.012)
            aft = _strake_aft_end(0.5 * (t0 + t1))
            # Boards that have worked: some stand proud of their neighbours, some have
            # sunk in. A constant standoff gives a moulded shell with seams drawn on it.
            standoff = _PLANK_THICKNESS * 0.5 + rng.uniform(-0.005, 0.005)
            tag = "s" if side > 0 else "p"
            index = seed * 97 + k * 7 + (0 if side > 0 else 3)

            gap = _breach(k, side)
            if gap is None:
                boards.append(_warped_plank(
                    f"hull_{tag}{k}", aft, _X_FORE, t0, t1, side, index, standoff))
                continue

            # Ragged, but only ever outward: jitter that can shrink a span breaks the
            # monotonic flare above. The range has to exceed the step between strakes or
            # the board ends land on a clean diagonal and the hole reads as a staircase.
            ga = gap[0] - rng.uniform(0.0, 0.075)
            gb = gap[1] + rng.uniform(0.0, 0.075)
            # One board each side of the hole is left hanging: still fixed at its far end
            # and peeled off the hull at the broken end.
            sprung = k in (3, 6)
            if ga - aft > 0.10:
                boards.append(_warped_plank(
                    f"hull_{tag}{k}a", aft, ga, t0, t1, side, index, standoff,
                    twist=16.0 if sprung else 6.0,
                    flare=0.055 if sprung else 0.0, flare_at_fore=True))
            if _X_FORE - gb > 0.10:
                boards.append(_warped_plank(
                    f"hull_{tag}{k}b", gb, _X_FORE, t0, t1, side, index + 1, standoff,
                    twist=14.0 if sprung else 6.0,
                    flare=0.045 if sprung else 0.0, flare_at_fore=False))
    return boards


def _transom(seed):
    """Four boards closing the stern, raked aft so the hull does not end in a wall."""
    boards = []
    for i, t in enumerate((0.14, 0.36, 0.58, 0.82)):
        half = _HALF_BEAM(-0.82) * _section(t, _FULLNESS(-0.82))
        z = _KEEL(-0.82) + (_SHEER(-0.82) - _KEEL(-0.82)) * t
        board = plank(f"transom_{i}", length=2.0 * half + 0.02, width=0.112,
                      thickness=0.018, bow=0.010, cup=0.05, twist=5.0,
                      seed=seed * 61 + i, samples_u=8, samples_v=4)
        # Local X becomes athwartships, local Y becomes vertical, thickness fore-and-aft.
        upright = Euler((pi * 0.5, 0.0, pi * 0.5), "XYZ").to_matrix().to_4x4()
        _place(board, Matrix.Translation(Vector((-0.845 - 0.085 * t, 0.0, z)))
               @ Matrix.Rotation(radians(-14.0), 4, "Y") @ upright)
        boards.append(board)
    return boards


# -- frames, keel and deck -----------------------------------------------------------


def _frame(name, x, top=1.0):
    """One transverse rib, sheer to keel to sheer, set inside the planking.

    `top` cuts it short. Frames crossing the stove-in midsection survive only as floor
    timbers or broken stubs at the hole's edge — both what a crushed hull leaves and what
    keeps the swim route clear.
    """
    points = []
    for i in range(-14, 15):
        s = i / 14.0
        side = 1.0 if s >= 0.0 else -1.0
        t = abs(s) * top
        points.append(_hull_point(x, t, side) - _hull_normal(x, t, side) * 0.031)
    tube = SweptTube(
        points,
        Profile([(0.0, 0.013), (0.5, 0.019), (1.0, 0.013)]),
        rings=26, segments=7, section=(0.72, 1.0), exponent=3.0,
    )
    return tube.build(name, subsurf=0)


def _frames():
    # Only the frames the route passes are cut to floor timbers — a whole frame is the
    # tightest thing in the hold, sitting a plank's thickness inboard of the very surface
    # the clearance is measured from. The rest stay, and the ones left standing inside the
    # hole are the exposed ribs that say stove in rather than cut out.
    stations = [-0.74 + 0.125 * i for i in range(13)]
    return [_frame(f"rib_{i}", x, 0.08 if abs(x - _HOLD_X) < 0.18 else 1.0)
            for i, x in enumerate(stations)]


def _keel(seed):
    """Keel, sternpost and stem as one swept timber, because they are one piece of the
    boat and the corner where the keel turns up into the stem is the part that reads."""
    points = [Vector((-0.900, 0.0, 0.470)), Vector((-0.888, 0.0, 0.310)),
              Vector((-0.876, 0.0, 0.150))]
    for i in range(13):
        x = -0.840 + (0.720 + 0.840) * i / 12.0
        points.append(Vector((x, 0.0, _KEEL(x) - 0.048)))
    points += [Vector((0.860, 0.0, 0.205)), Vector((0.930, 0.0, 0.375)),
               Vector((0.968, 0.0, 0.540))]
    tube = SweptTube(
        points,
        Profile([(0.0, 0.040), (0.12, 0.056), (0.86, 0.056), (1.0, 0.036)]),
        rings=46, segments=10, section=(0.55, 1.0), exponent=3.4,
        up=(0.0, 1.0, 0.0),
    )
    return tube.build(f"keel_{seed}", subsurf=0)


def _runs(y, holes, x_lo, x_hi, half_width):
    """The stretches of one deck strip that are actually planked."""
    runs, start, x = [], None, x_lo
    while x <= x_hi:
        fits = _deck_half(x) >= abs(y) + half_width + 0.012
        blocked = any(a <= x <= b and c <= y <= d for a, b, c, d in holes)
        if fits and not blocked:
            start = x if start is None else start
        elif start is not None:
            runs.append((start, x))
            start = None
        x += 0.01
    if start is not None:
        runs.append((start, x_hi))
    return [run for run in runs if run[1] - run[0] > 0.11]


def _deck(rng, seed):
    """Partial decking: a hatch, a mast hole, and the whole midships gone.

    The gaps are the point — a dark opening under water is worth more than the planks that
    would have covered it, and the deck over the hold has to go or it roofs the swim route.
    """
    width, step = 0.062, 0.068
    holes = [
        # Only the *port* edge of the midships deck is torn away, with the rail it was
        # fastened to. The rest stays, and staying is the point: a fish crossing a
        # shadowed hold under a deck is the shot, where a hold open to the sky is just a
        # gap between two boats.
        # Staggered, not a straight line: the tear reaches further inboard away from the
        # route than across it, so the fish keeps its roof where it needs one and the
        # edge still looks torn rather than sawn.
        (-0.46, -0.24, -0.60, -0.07),
        (-0.24, 0.16, -0.60, -0.17),
        (-0.84, -0.68, -0.12, 0.12),    # cargo hatch
        (0.32, 0.48, -0.09, 0.09),      # mast partners
    ]
    # Sprung and missing deck planks. Free to add — a hole only ever removes geometry, so
    # none of these can foul the route — and a deck with no gaps in it reads as new.
    for _ in range(6):
        centre = rng.uniform(-0.80, 0.56)
        y = rng.uniform(-0.24, 0.24)
        span = rng.uniform(0.03, 0.09)
        holes.append((centre, centre + rng.uniform(0.10, 0.30), y - span, y + span))

    boards = []
    for k in range(8):
        y = (k - 3.5) * step
        for run, (x0, x1) in enumerate(_runs(y, holes, -0.84, 0.66, width * 0.5)):
            board = plank(
                f"deck_{k}_{run}", length=x1 - x0, width=width, thickness=0.014,
                bow=0.008, cup=0.06, twist=7.0, seed=seed * 313 + k * 11 + run,
                samples_u=max(6, int((x1 - x0) / 0.09) + 4), samples_v=3,
            )
            for vert in board.data.vertices:
                u = vert.co.x / (x1 - x0) + 0.5
                x = x0 + (x1 - x0) * u
                vert.co = Vector((x, y + vert.co.y, _deck_z(x) + vert.co.z))
            board.data.update()
            boards.append(board)

    # The two inside the hole carry the surviving midships deck, their port ends in
    # mid-air where the rail used to be. Their stations come from the route, not the deck
    # spacing: a beam over the hold is the one thing under the deck low enough to foul it.
    for i, x in enumerate((-0.74, 0.28, 0.54, -0.34, 0.02)):
        beam = beveled_box(f"deck_beam_{i}", bevel=0.18, segments=2,
                           size=(0.050, 2.0 * _deck_half(x) * 0.97, 0.048))
        _place(beam, Matrix.Translation(Vector((x, 0.0, _deck_z(x) - 0.032))))
        boards.append(beam)
    return boards


# -- spars ---------------------------------------------------------------------------


def _spar(name, length, base_radius, top_radius, seed, segments=12, rings=5,
          splinter=0.08, spikes=3):
    """A mast or yard snapped off, with a torn end rather than a sawn one.

    The break is why this is not a `revolve`: a flat circular top makes a broken mast look
    like a bollard. The longest splinter stays close to the break's own depth — a taller
    spike reads as a needle, which was the first version's worst feature.
    """
    rng = random.Random(seed * 5417 + 89)
    noise = Noise(seed * 331 + 17)
    bm = bmesh.new()
    columns = []
    for i in range(rings + 1):
        f = i / rings
        radius = base_radius + (top_radius - base_radius) * f
        ring = []
        for j in range(segments):
            angle = tau * j / segments
            wobble = 1.0 + 0.055 * noise.fbm(cos(angle) * 2.0, sin(angle) * 2.0,
                                             f * 3.0, octaves=2)
            ring.append(bm.verts.new((radius * wobble * cos(angle),
                                      radius * wobble * sin(angle), length * f)))
        columns.append(ring)

    for j, vert in enumerate(columns[-1]):
        a = tau * j / segments
        vert.co.z += splinter * noise.fbm(cos(a) * 1.7, sin(a) * 1.7, 9.0, octaves=2)
    for _ in range(spikes):
        columns[-1][rng.randrange(segments)].co.z += splinter * rng.uniform(0.5, 1.1)

    for lower, upper in zip(columns, columns[1:]):
        for j in range(segments):
            n = (j + 1) % segments
            bm.faces.new((lower[j], lower[n], upper[n], upper[j]))
    for ring, z, upward in ((columns[0], 0.0, False),
                            (columns[-1], length - splinter * 0.6, True)):
        hub = bm.verts.new((0.0, 0.0, z))
        for j in range(segments):
            n = (j + 1) % segments
            bm.faces.new((hub, ring[n], ring[j]) if upward else (hub, ring[j], ring[n]))
    return _mesh_object(name, bm, sharp_angle=44.0)


# -- anchor chain --------------------------------------------------------------------


def _chain(name, points, link_major=0.032, link_minor=0.0072, spacing=0.044,
           major_segments=10, minor_segments=6):
    """Oval links threaded along a path, built into one mesh.

    Real links rather than a swept tube: a tube along the same path reads as rope, and the
    alternating quarter-turn between links is the whole cue that says chain.
    """
    lengths = [0.0]
    for a, b in zip(points, points[1:]):
        lengths.append(lengths[-1] + (b - a).length)
    total = lengths[-1]

    def at(distance):
        distance = min(max(distance, 0.0), total)
        for i in range(len(lengths) - 1):
            if lengths[i] <= distance <= lengths[i + 1]:
                span = max(lengths[i + 1] - lengths[i], 1e-9)
                return points[i].lerp(points[i + 1], (distance - lengths[i]) / span)
        return points[-1]

    bm = bmesh.new()
    count = max(2, int(total / spacing))
    for index in range(count):
        distance = (index + 0.5) * total / count
        centre = at(distance)
        tangent = at(distance + 0.01) - at(distance - 0.01)
        tangent = tangent.normalized() if tangent.length > 1e-9 else Vector((0, 0, -1))
        reference = Vector((0.0, 0.0, 1.0))
        if abs(tangent.dot(reference)) > 0.95:
            reference = Vector((1.0, 0.0, 0.0))
        plane = tangent.cross(reference).normalized()
        if index % 2:
            plane = tangent.cross(plane).normalized()
        side = plane.cross(tangent).normalized()

        rings = []
        for j in range(major_segments):
            angle = tau * j / major_segments
            span = link_minor * 2.1
            local = tangent * (link_major * cos(angle)) + side * (span * sin(angle))
            derivative = (tangent * (-link_major * sin(angle))
                          + side * (span * cos(angle))).normalized()
            outward = derivative.cross(plane).normalized()
            rings.append([
                bm.verts.new(centre + local
                             + outward * (link_minor * cos(tau * m / minor_segments))
                             + plane * (link_minor * sin(tau * m / minor_segments)))
                for m in range(minor_segments)])
        for a in range(major_segments):
            b = (a + 1) % major_segments
            for m in range(minor_segments):
                n = (m + 1) % minor_segments
                bm.faces.new((rings[a][m], rings[a][n], rings[b][n], rings[b][m]))
    return _mesh_object(name, bm, sharp_angle=60.0)


# -- assembly ------------------------------------------------------------------------


def _fittings(rng, seed):
    """Rudder, pintles, capstan and bowsprit — the pieces that say ship, not box."""
    timber, iron = [], []

    blade = plank("rudder", length=0.190, width=0.320, thickness=0.032, bow=0.012,
                  cup=0.05, twist=5.0, seed=seed * 17 + 5, samples_u=6, samples_v=5)
    stand = Euler((pi * 0.5, 0.0, 0.0), "XYZ").to_matrix().to_4x4()
    _place(blade, Matrix.Translation(Vector((-0.940, 0.0, 0.220)))
           @ Matrix.Rotation(radians(rng.uniform(14.0, 30.0)), 4, "Z")
           @ Matrix.Rotation(radians(12.0), 4, "Y") @ stand)
    timber.append(blade)

    for i, z in enumerate((0.125, 0.310)):
        pintle = beveled_box(f"pintle_{i}", size=(0.105, 0.052, 0.024), bevel=0.22,
                             segments=2)
        _place(pintle, Matrix.Translation(Vector((-0.905, 0.0, z))))
        iron.append(pintle)

    # Aft of the hatch and well clear of the hold: the swim route runs at x = -0.15.
    capstan = revolve("capstan", [(0.062, 0.0), (0.048, 0.048), (0.046, 0.128),
                                  (0.068, 0.156), (0.060, 0.172)],
                      segments=20, rings=6, interpolation="linear")
    _place(capstan, Matrix.Translation(Vector((-0.615, 0.0, _deck_z(-0.615) - 0.010))))
    iron.append(capstan)

    bowsprit = _spar("bowsprit", 0.270, 0.033, 0.026, seed * 3 + 2,
                     segments=10, rings=4, splinter=0.050, spikes=2)
    _place(bowsprit, Matrix.Translation(Vector((0.872, 0.0, 0.530)))
           @ Matrix.Rotation(radians(68.0), 4, "Y"))
    timber.append(bowsprit)
    return timber, iron


def _seabed(attitude, floor, rng, seed):
    """The sand the bow has ploughed into, and the spar lying beside the wreck.

    Both belong to the floor, so they are built upright and pre-multiplied by the inverse
    attitude before being hung off the heeled empty. The prop cannot be sunk into the tank
    floor — the build seats its lowest vertex on z = 0 — so burial has to be geometry that
    rises over the hull.
    """
    inverse = attitude.inverted().to_4x4()
    parts = []

    def drift(name, radius, spread, top, at):
        """A sand drift whose *top* is placed, not its size.

        Guessing a mound's height from its radius, after `rock`'s seeded axis jitter, is
        how the bow ends up either uncovered or swallowed whole; what matters is where the
        sand finishes relative to the hull, so the lump is stretched to span floor..top.

        Everything else here fights the same failure: a smooth ellipsoid reads as an egg,
        not as sand. The plan shape is stretched along a seeded heading and squeezed across
        it, the way current-scoured sand piles; the fbm displacement then breaks the
        outline so the edge laps unevenly against the hull. Both run *before* the vertical
        fit, so the fit still lands the surface where the hull needs it.
        """
        index = len(parts)
        lump = rock(name, radius=radius, angularity=0.0, seed=seed * 41 + index,
                    detail=5, lumpiness=0.26, flatten=1.0, grain=0.05)
        lump.data.transform(
            Matrix.Rotation(rng.uniform(0.0, tau), 4, "Z")
            @ Matrix.Diagonal((spread * 1.30, spread * 0.78, 1.0, 1.0)))
        # Broad and low-frequency. A feature size near the icosphere's own edge length
        # crumples the surface into facets and the drift turns into torn foil — the
        # asymmetry has to come from the plan stretch above, not from fine noise.
        displace(lump, strength=0.15, feature_size=0.70, octaves=2,
                 seed=seed * 41 + index + 500)
        heights = [vert.co.z for vert in lump.data.vertices]
        span = max(max(heights) - min(heights), 1e-6)
        lump.data.transform(Matrix.Diagonal((1.0, 1.0, (top - floor) / span, 1.0)))
        low = min(vert.co.z for vert in lump.data.vertices)
        anchor = attitude @ Vector(at)
        _place(lump, inverse @ Matrix.Translation(
            Vector((anchor.x, anchor.y, floor - low))))
        parts.append((lump, "sand"))

    # Bow-first into the seabed: the sand has to close over the stem or the wreck reads as
    # parked rather than driven in. Centred well back from the stem, because anything that
    # reaches past the hull is paid for twice — in the footprint and again in the spacing.
    drift("sand_mound", 0.42, 0.98, 0.190, (0.80, 0.0, 0.20))
    # A second lick of sand where the low side meets the floor, forward of amidships: the
    # bow-down trim is what puts that stretch of bilge on the bottom, and it is also the
    # only place it can go — the route leaves over the port bilge, and a seeded lump
    # anywhere near there fouled the exit on one seed in three.
    drift("sand_bilge", 0.24, 1.00, floor + 0.085, (0.30, -0.30, 0.10))

    spar = _spar(f"fallen_spar_{seed}", 0.700, 0.034, 0.024, seed * 7 + 11,
                 segments=10, rings=5, splinter=0.070, spikes=3)
    lie = (Matrix.Rotation(radians(rng.uniform(26.0, 54.0)), 4, "Z")
           @ Matrix.Rotation(radians(93.0), 4, "Y"))
    rested = [lie @ vert.co for vert in spar.data.vertices]
    anchor = attitude @ Vector((-0.46, 0.26, 0.10))
    _place(spar, inverse @ Matrix.Translation(Vector((
        anchor.x, anchor.y, floor + 0.028 - min(p.z for p in rested)))) @ lie)
    parts.append((spar, "timber"))
    return parts


def _waypoint(name, location, parent):
    empty = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(empty)
    empty.parent = parent
    empty.location = location
    return empty


def build(seed=0):
    root = bpy.data.objects.new("decor_sunken_ship", None)
    bpy.context.collection.objects.link(root)
    rng = random.Random(seed * 7717 + 331)

    # Heeled to port so the starboard flank faces up into the light, and down by the head
    # so the bow can be buried. A wreck sitting level looks parked.
    heel = radians(rng.uniform(30.0, 37.0))
    trim = radians(rng.uniform(8.0, 12.0))
    attitude = Euler((heel, trim, 0.0), "XYZ").to_matrix()

    frame = bpy.data.objects.new("wreck_attitude", None)
    bpy.context.collection.objects.link(frame)
    frame.parent = root
    frame.rotation_euler = Euler((heel, trim, 0.0), "XYZ")

    timber = _planking(rng, seed) + _transom(seed) + _deck(rng, seed) + _frames()
    timber.append(_keel(seed))
    iron = []

    # Stepped forward of the hole, both because that is where the deck still is and
    # because a mast through the middle of the hold would block the swim route.
    mast = _spar(f"mast_stump_{seed}", 0.680, 0.058, 0.044, seed * 13 + 1,
                 segments=12, rings=5, splinter=0.095, spikes=3)
    _place(mast, Matrix.Translation(Vector((0.400, 0.0, _KEEL(0.40) + 0.030)))
           @ Matrix.Rotation(radians(-6.0), 4, "Y"))
    timber.append(mast)

    fittings_timber, fittings_iron = _fittings(rng, seed)
    timber += fittings_timber
    iron += fittings_iron

    floor = min((attitude @ vert.co).z
                for obj in timber + iron for vert in obj.data.vertices) - 0.016

    # The chain has to sag along *world* down while living in ship coordinates.
    down = attitude.inverted() @ Vector((0.0, 0.0, -1.0))
    anchor = _hull_point(0.56, 1.0, 1.0) + _hull_normal(0.56, 1.0, 1.0) * 0.020
    drop = (attitude @ anchor).z - floor
    outward = attitude @ _hull_normal(0.56, 0.75, 1.0)
    outward = Vector((outward.x, outward.y, 0.0))
    outward = (attitude.inverted() @ outward.normalized()) if outward.length > 1e-6 \
        else Vector((0.0, 1.0, 0.0))
    landing = anchor + down * drop
    path = [anchor.lerp(landing, i / 8.0) + outward * (0.055 * sin(pi * i / 8.0))
            for i in range(9)]
    path += [landing + outward * 0.12, landing + outward * 0.26]
    iron.append(_chain(f"anchor_chain_{seed}", path))

    seabed = _seabed(attitude, floor, rng, seed)

    # Waterlogged and colonised, but neither to the limit: `waterlog` past ~0.8 takes the
    # timber to near-black and `algae` past ~0.4 covers what is left, and together they
    # give a uniform mint-green shell with no wood in it. That reads worse than a lighter
    # wreck, because the biofilm's value is the *contrast* between furred upper faces and
    # bare undersides — `_biofilm` keys it off the world normal, so the heel decides.
    hull_wood = wood_material(
        f"ship_timber_{seed}", size=1.8, grain_spacing=0.0042, plank_width=0.0,
        waterlog=0.78, roughness=0.72, algae=0.34, seed=seed * 5 + 1,
    )
    ship_iron = metal_material(
        f"ship_iron_{seed}", size=0.28, base=IRON, corrosion=0.93, patina=RUST,
        roughness=0.55, algae=0.45, seed=seed * 5 + 2,
    )
    seabed_sand = sand_material(
        # Close to the library default on purpose: these drifts sit on the tank's own
        # seabed, so matching it matters more than how they look against a contact
        # sheet's black background, where any broad surface square-on to the overhead
        # key looks a stop hotter than it will in the scene.
        f"ship_sand_{seed}", size=0.9, base=(0.076, 0.061, 0.041),
        ripple_spacing=0.055, shell=0.30, algae=0.22, seed=seed * 5 + 3,
    )

    for obj in timber:
        assign(obj, hull_wood)
    for obj in iron:
        assign(obj, ship_iron)
    for obj, kind in seabed:
        assign(obj, seabed_sand if kind == "sand" else hull_wood)

    for obj in timber + iron + [part for part, _ in seabed]:
        obj.parent = frame

    # Centre on X and Y; the build script only seats the model on z = 0. Without this the
    # sand drifts pull the geometry off to one side of the placement point and the
    # footprint has to cover a circle the wreck is not in the middle of.
    corners = [attitude @ vert.co
               for obj in timber + iron + [part for part, _ in seabed]
               for vert in obj.data.vertices]
    centre = Vector((0.5 * (min(p.x for p in corners) + max(p.x for p in corners)),
                     0.5 * (min(p.y for p in corners) + max(p.y for p in corners)), 0.0))
    frame.location = -centre

    # The swim route. Ship-space points rotated into world and hung straight off the root:
    # the route is a fact about the hull, but "far enough above the seabed to be swimmable"
    # is a fact about the world, which is why the port approach is lifted so far up the
    # ship's Z — on the low side, level with the hold means level with the sand.
    for name, point in (("swim_port_approach", (_HOLD_X, -0.46, 0.40)),
                        ("swim_breach_port", (_HOLD_X, -0.20, 0.215)),
                        ("swim_hold", (_HOLD_X, 0.0, _HOLD_Z)),
                        ("swim_breach_star", (_HOLD_X, 0.20, _HOLD_Z)),
                        ("swim_star_approach", (_HOLD_X, 0.48, 0.24))):
        _waypoint(name, attitude @ Vector(point) - centre, root)

    bpy.context.view_layer.update()
    return root


SUNKEN_SHIP = Prop(
    name="sunken_ship",
    build=build,
    category="decoration",
    # The hull is about 1.9 m stem to rudder and 0.52 m in the beam, but what the tank has
    # to find room for is the wreck *plus* its scour: measured over five seeds it spans up
    # to 2.45 x 1.40 m and stands 0.86 m, so the circle it sweeps as the tank yaws it has
    # a 1.37 m radius. `footprint` is that circle, not the hull's own half-length.
    footprint=1.42,
    height=0.90,
    # Already lying over by thirty degrees, so the tank's own tilt is only meant to break
    # up the seating. Stacking a second large tilt on top puts the keel in the air.
    tilt_range=(-3.0, 3.0),
    scale_range=(0.92, 1.10),
    weight=6.0,
    max_per_scene=1,
    min_spacing=2.95,
    # Sampling the route against every evaluated vertex puts the tightest clearance at
    # 0.143 m over five seeds. What binds it is exactly the structure kept for the sake of
    # the silhouette — the surviving garboard, the unbroken starboard rail, the floor
    # timbers under the hold — which is the trade working as intended. Declared under it,
    # and comfortably over the 0.12 m a fish measures in its worst dimension.
    passages=(Passage(("swim_port_approach", "swim_breach_port", "swim_hold",
                       "swim_breach_star", "swim_star_approach"), radius=0.13),),
    seeds=3,
)
