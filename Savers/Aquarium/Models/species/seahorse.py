"""Common seahorse (Hippocampus kuda).

The one animal in the library whose body is a path rather than a profile. Everything else
here can be drawn as a depth above and below a straight backbone; a seahorse bends its
head to a right angle and then curls its tail through more than a full turn, and neither
of those is expressible as a half-height over a monotone X. So it states a `path` and a
`radius` instead of `top`/`bottom`/`width`, and `saverlib.curved` sweeps a section along
it — see that module for what a curved body gives up in exchange.

**The mesh is laid out lying down, and the tank stands it up.** Every fish here is built
nose at +X, back at +Z, and the tank's pivot turns that into its own axes; a seahorse gets
one extra quarter turn so its long axis ends up vertical. Reading the coordinates below
therefore means holding the mapping in your head:

| mesh | tank | on the animal |
| --- | --- | --- |
| +X | up | the head |
| -X | down | the tail |
| -Z | forward | where the snout points |
| +Z | backward | the back, and the dorsal fin |
| ±Y | across | the flanks |

That is why the head bends towards **-Z** and the tail curls the same way: both point
forward once the animal is standing, which is what a seahorse's snout and its curled tail
actually do. Bending either the other way builds a seahorse that faces backwards, and it
renders perfectly.

The body is **not** given `bands` or `stripes`. Those are placed by X, and on a curled
animal X is not a position along the body — the tail's tip is back under the chest. The
mottling is `spots` and `patches`, which are placed in object space and stay correct.
"""

import math

from ._spec import Fin, Species


def _smooth(controls, per_segment=9):
    """Catmull-Rom through `controls`, so the sweep follows a curve, not a polygon.

    The sweep resamples whatever it is handed by straight-line distance, so a dozen
    control points arrive as a dozen flat facets with visible creases at every one. This
    is only here to put enough points between them that the resampling has a curve to
    find.
    """
    if len(controls) < 4:
        raise ValueError("a Catmull-Rom needs at least four control points")

    def at(index):
        return controls[min(max(index, 0), len(controls) - 1)]

    points = []
    for index in range(len(controls) - 1):
        p0, p1, p2, p3 = at(index - 1), at(index), at(index + 1), at(index + 2)
        for step in range(per_segment):
            f = step / per_segment
            f2, f3 = f * f, f * f * f
            points.append(tuple(
                0.5 * ((2 * b)
                       + (-a + c) * f
                       + (2 * a - 5 * b + 4 * c - d) * f2
                       + (-a + 3 * b - 3 * c + d) * f3)
                for a, b, c, d in zip(p0, p1, p2, p3)
            ))
    points.append(tuple(controls[-1]))
    return points


def _curl(start, heading, turn, arc, taper, steps=60):
    """A spiral in the XZ plane, for the tail.

    Walks from `start` in direction `heading` (an angle, with 0 along +X and pi/2 along
    +Z), turning steadily through `turn` radians over `arc` metres of path. `taper`
    shrinks the step towards the tip, which is what makes the spiral close up rather than
    coil at a constant radius — a tail of constant curvature reads as a hook.
    """
    weights = [1.0 - (1.0 - taper) * i / (steps - 1) for i in range(steps)]
    scale = arc / sum(weights)
    x, y, z = start
    angle = heading
    points = []
    for step, weight in enumerate(weights):
        angle += turn / steps
        x += math.cos(angle) * weight * scale
        z += math.sin(angle) * weight * scale
        points.append((x, y, z))
    return points


def _arc_fractions(points, indices):
    """Where the named control points fall as fractions of the whole path's length.

    The radius profile is read by the sweep against arc length, but it is *authored*
    against anatomy — the widest point is the belly, not "t = 0.38". Deriving the one from
    the other here means moving a control point carries the thickness with it instead of
    silently sliding the belly into the tail.
    """
    cumulative = [0.0]
    for previous, current in zip(points, points[1:]):
        cumulative.append(cumulative[-1] + math.dist(previous, current))
    total = cumulative[-1]
    return {name: cumulative[index] / total for name, index in indices.items()}


# The head and trunk, nose first: down the snout, round the right-angle bend at the nape,
# and along the trunk to the vent. Blender metres, in the mesh axes the module docstring
# lays out. The control points are named by index rather than counted, because the radius
# profile below is pinned to them and an inserted point would otherwise slide the belly
# into the tail without changing a single number.
_TRUNK = [
    (0.0510, 0.0, -0.0432),   # 0  snout tip
    (0.0508, 0.0, -0.0366),
    (0.0503, 0.0, -0.0300),
    (0.0496, 0.0, -0.0236),   # 3  the snout is still a thin tube to here
    (0.0484, 0.0, -0.0176),
    (0.0464, 0.0, -0.0122),   # 5  the head swells, fast
    (0.0430, 0.0, -0.0076),
    (0.0384, 0.0, -0.0044),   # 7  the cheek, the deepest part of the head
    (0.0328, 0.0, -0.0028),
    (0.0268, 0.0, -0.0030),   # 9  the nape: a pinch, and the bend is finished
    (0.0202, 0.0, -0.0038),
    (0.0130, 0.0, -0.0054),   # 11 the chest
    (0.0048, 0.0, -0.0078),
    (-0.0038, 0.0, -0.0108),  # 13 the belly, at its deepest
    (-0.0122, 0.0, -0.0146),
    (-0.0198, 0.0, -0.0192),  # 15 the vent, where the tail takes over
]
_SNOUT_BASE, _HEAD, _NAPE, _CHEST, _BELLY, _VENT_POINT = 3, 7, 9, 11, 13, 15
_TRUNK_SMOOTH = 9

# The tail leaves the vent still heading down and forward, then turns through one and a
# quarter revolutions towards -Z, which is forwards once the animal is standing.
_HEAD_AND_TRUNK = _smooth(_TRUNK, per_segment=_TRUNK_SMOOTH)
_PATH = _HEAD_AND_TRUNK + _curl(
    start=_TRUNK[_VENT_POINT],
    heading=math.atan2(-0.0046, -0.0076),
    turn=1.25 * 2.0 * math.pi,
    arc=0.108,
    taper=0.30,
)

# Anatomy, as fractions of the path's length.
_AT = _arc_fractions(_PATH, {
    "snout_base": _SNOUT_BASE * _TRUNK_SMOOTH,
    "head": _HEAD * _TRUNK_SMOOTH,
    "nape": _NAPE * _TRUNK_SMOOTH,
    "chest": _CHEST * _TRUNK_SMOOTH,
    "belly": _BELLY * _TRUNK_SMOOTH,
    "vent": len(_HEAD_AND_TRUNK) - 1,
})
_VENT = _AT["vent"]


def _tail(fraction):
    """A fraction along the tail, as a fraction of the whole path."""
    return _VENT + (1.0 - _VENT) * fraction


SEAHORSE = Species(
    name="seahorse",
    body_length_m=0.16,
    # Seahorses are found in ones and twos, holding station on something rather than
    # travelling. They belong low, among the plants they grip — but not far back: at the
    # rear of the tank the depth fog takes the amber out of a small animal and leaves a
    # pale grey comma, and this one is too slow to swim forward out of it.
    school=(1, 2),
    depth_band=(0.30, 0.75),
    weight=0.35,
    pose="upright",
    swim=0.0,
    fin_rate=4.5,
    length=0.115,
    path=_PATH,
    # Thin at the snout, swelling through the head and the pot belly, then tapering the
    # whole length of the tail to a point.
    radius=[
        (0.000, 0.0016),
        (_AT["snout_base"] * 0.5, 0.0021),
        (_AT["snout_base"], 0.0026),
        (_AT["head"], 0.0104),
        (_AT["nape"], 0.0082),
        (_AT["chest"], 0.0098),
        (_AT["belly"], 0.0106),
        (_VENT, 0.0066),
        (_tail(0.20), 0.0050),
        (_tail(0.44), 0.0036),
        (_tail(0.68), 0.0024),
        (_tail(0.87), 0.0014),
        (1.000, 0.0007),
    ],
    # Narrower across than through: a seahorse is a slab-sided animal, and the trunk is
    # the most compressed part of it.
    section=([(0.0, 0.95), (_AT["head"], 0.80), (_AT["belly"], 0.74), (1.0, 0.86)],
             1.0),
    # The bony rings. A seahorse has no scales — it is plated, and the plates give it a
    # section that is closer to a rounded square than to an oval, most obviously along the
    # tail. Past about 4 the section reads as a rectangle and catches light wrongly, so
    # this stops short of it.
    exponent=[(0.0, 2.3), (_AT["head"], 2.8), (_AT["belly"], 3.4),
              (_VENT, 3.6), (1.0, 3.6)],
    # The frame's up is checked against +Z at a point on the straight part of the trunk,
    # where the answer is not in doubt. See `CurvedBodySpec`.
    body_up=(0.0, -1.0, 0.0),
    dorsal_at=_AT["belly"],
    # Amber and honey, darkening over the back. Seahorses take the colour of what they are
    # holding on to, and a warm one reads against blue water where a grey-brown does not.
    colors=((0.735, 0.455, 0.080), (0.585, 0.320, 0.052), (0.360, 0.180, 0.034)),
    fin_color=(0.585, 0.410, 0.145),
    # No bands and no stripes — see the module docstring. Mottling and a few darker
    # saddles, both placed in object space.
    spots=[
        dict(color=(0.250, 0.130, 0.030), count=26.0, size=0.44, coverage=0.62,
             softness=0.45, seed=5.0),
        dict(color=(0.760, 0.560, 0.180), count=34.0, size=0.30, coverage=0.35,
             softness=0.55, seed=17.0),
    ],
    patches=[
        # The dark blotch behind the eye and two saddles over the trunk. The Y radius is
        # far past the body's half-width on purpose: anything merely equal to it lands on
        # one flank and fades to a smudge before it reaches the other.
        dict(center=(0.0350, 0.0, -0.0020), radii=(0.0058, 0.060, 0.0056),
             color=(0.230, 0.115, 0.026), softness=0.30),
        dict(center=(0.0150, 0.0, -0.0044), radii=(0.0055, 0.060, 0.0064),
             color=(0.250, 0.135, 0.032), softness=0.34),
        dict(center=(-0.0075, 0.0, -0.0122), radii=(0.0055, 0.060, 0.0064),
             color=(0.250, 0.135, 0.032), softness=0.34),
        # The crown of bony spines on top of the head, which is the coronet.
        dict(center=(0.0360, 0.0, 0.0055), radii=(0.0056, 0.050, 0.0036),
             color=(0.300, 0.170, 0.045), softness=0.26),
    ],
    # The tubular snout ends in a small round mouth rather than a gape.
    mouth=((0.0510, 0.0, -0.0430), (0.0013, 0.0022, 0.0013)),
    mouth_color=(0.155, 0.070, 0.030),
    # Plated, not scaled: enough relief to break up the specular, no scale pattern.
    scale_count=26.0,
    scale_depth=0.06,
    eye=(_AT["head"] * 1.02, 0.34, 0.038),
    eye_ring=dict(color=(0.290, 0.150, 0.035), width=0.60, softness=0.28),
    # The dorsal fin, and the whole of the animal's propulsion: a small fan on the back
    # over the trunk-to-tail junction, which in life beats fast enough to blur. It is the
    # part the shader ripples — see `SwimDeformation.swift`.
    dorsal=Fin(t0=_AT["chest"] * 1.02, t1=_VENT * 1.03,
               span=[(0.00, 0.0032), (0.20, 0.0134), (0.50, 0.0158),
                     (0.80, 0.0126), (1.00, 0.0030)],
               rake=0.0018, sink=0.24, samples_u=30, samples_v=10,
               ripples=True),
    # Small pectorals just behind the gill plate, which steer. They beat on the same
    # channel every other fish's do.
    pectoral=Fin(t0=_AT["head"] * 1.10, t1=_AT["nape"],
                 span=[(0.0, 0.0022), (0.45, 0.0082), (1.0, 0.0022)],
                 rake=0.0022, curl=0.0014, sink=0.30, samples_u=12, samples_v=10),
    # A seahorse has neither a caudal nor a pelvic fin. The tail is a gripping limb, not
    # a paddle, and leaving them off is most of why the silhouette reads correctly.
    caudal=None,
    pelvic=None,
    anal=None,
    fin_style=dict(tip_color=(0.760, 0.590, 0.250), opacity=0.70,
                   ray_count=22.0, ray_contrast=0.75),
)
