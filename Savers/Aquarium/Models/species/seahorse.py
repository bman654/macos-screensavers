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

The plating is `rings`, which is the one marking placed along the body's own swept
coordinate rather than in object space, and the reason that coordinate exists at all. A
seahorse has no scales: it is a chain of bony rings, about eleven round the trunk and
three dozen down the tail, with four ridges running the length of it and a tubercle
wherever a ridge crosses a ring. Everything else here is a fish wearing a seahorse's
outline; this is what makes it a seahorse.
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
    (0.0512, 0.0, -0.0384),   # 0  snout tip
    (0.0509, 0.0, -0.0330),
    (0.0504, 0.0, -0.0276),
    (0.0497, 0.0, -0.0222),   # 3  the snout is still a thin tube to here
    (0.0486, 0.0, -0.0170),
    (0.0466, 0.0, -0.0120),   # 5  the head swells, fast
    (0.0432, 0.0, -0.0076),
    (0.0386, 0.0, -0.0044),   # 7  the cheek, the deepest part of the head
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


# Where the dark marks sit. This is shape rather than colour — every colourway paints the
# same saddles in its own tones — so it lives out here and each scheme only says what
# colour to paint them. Radii in metres; the Y radius is far past the body's half-width on
# purpose, because anything merely equal to it lands on one flank and fades to a smudge
# before it reaches the other.
_SADDLES = [
    ((0.0350, 0.0, -0.0020), (0.0058, 0.060, 0.0056), 0.30),   # behind the eye
    ((0.0150, 0.0, -0.0044), (0.0055, 0.060, 0.0064), 0.34),
    ((-0.0075, 0.0, -0.0122), (0.0055, 0.060, 0.0064), 0.34),
    ((0.0360, 0.0, 0.0055), (0.0056, 0.050, 0.0036), 0.26),    # the coronet
]

# The rings, less the two colours a scheme decides. `spacing` is why this is not just a
# count: the rings are nothing like evenly spread — a couple of wide plates over the head,
# eleven across the trunk, and the rest packed into the tail, which is what makes a tail
# read as a tail and not as a striped rope. The four ridges sit on the corners of the
# section rather than on its flats, which is where `ridge_offset`'s default puts them and
# where the exponent has already put a corner.
_PLATING = dict(
    count=50,
    spacing=[(0.0, 0.0), (_AT["snout_base"], 0.02), (_AT["nape"], 0.08),
             (_VENT, 0.30), (1.0, 1.0)],
    ridges=4,
    joint_width=0.40,
    keel_width=0.18,
    contrast=0.45,
    depth=1.0,
    keel_depth=1.0,
    tubercle=1.6,
)


def _look(belly, mid, back, dark, pale, fin, fin_tip):
    """One colourway, from the seven colours a seahorse's paint job actually needs.

    A wild seahorse's colour says more about the weed it is gripping than about its
    species: one *Hippocampus kuda* is honey, the next lemon, cream or near-black. So the
    animal is authored once and painted several times, and a scheme is these seven colours
    rather than a second copy of every marking. `dark` does all the work of shadow —
    mottle, saddles, ring joints, eye ring and the gape — and `pale` all the work of
    highlight, which is what keeps a scheme coherent instead of seven unrelated choices.
    """
    return dict(
        colors=(belly, mid, back),
        fin_color=fin,
        fin_style=dict(tip_color=fin_tip, opacity=0.88, ray_count=18.0,
                       ray_contrast=0.95),
        # Mottling and a scatter of lighter flecks, both placed in object space — a curled
        # animal has no nose-to-tail X for a band or a stripe to be placed against.
        spots=[
            dict(color=dark, count=26.0, size=0.44, coverage=0.62, softness=0.45,
                 seed=5.0),
            dict(color=pale, count=34.0, size=0.30, coverage=0.35, softness=0.55,
                 seed=17.0),
        ],
        patches=[dict(center=center, radii=radii, color=dark, softness=softness)
                 for center, radii, softness in _SADDLES],
        rings=dict(_PLATING, color=dark, keel_color=pale),
        mouth_color=tuple(channel * 0.55 for channel in dark),
        eye_ring=dict(color=dark, width=0.60, softness=0.28),
    )


# The schemes, in the order the runtime draws from. Amber is first because it is what the
# `.usdz` itself is baked in, so a build or a runtime that knows nothing about colourways
# still shows the animal this species was art-directed as.
_COLORWAYS = {
    # Honey over a dark back: the textbook *kuda*, and a warm animal reads against blue
    # water where a grey-brown one does not.
    "amber": _look(
        belly=(0.735, 0.455, 0.080), mid=(0.585, 0.320, 0.052),
        back=(0.360, 0.180, 0.034), dark=(0.250, 0.130, 0.030),
        pale=(0.780, 0.585, 0.215), fin=(0.585, 0.410, 0.145),
        fin_tip=(0.700, 0.520, 0.200)),
    # The bright yellow that a well-fed captive one turns, and the loudest of these.
    "lemon": _look(
        belly=(0.900, 0.720, 0.110), mid=(0.820, 0.560, 0.060),
        back=(0.560, 0.330, 0.040), dark=(0.300, 0.165, 0.030),
        pale=(0.940, 0.800, 0.300), fin=(0.800, 0.600, 0.150),
        fin_tip=(0.900, 0.740, 0.260)),
    # *H. reidi* in its red form, which is nearly the colour of the gorgonian it holds.
    "crimson": _look(
        belly=(0.640, 0.180, 0.075), mid=(0.480, 0.095, 0.045),
        back=(0.280, 0.045, 0.030), dark=(0.170, 0.028, 0.022),
        pale=(0.780, 0.360, 0.180), fin=(0.480, 0.140, 0.080),
        fin_tip=(0.660, 0.300, 0.150)),
    # Cream, with the mottle showing as grey rather than as brown. The palest scheme that
    # still survives the tank's depth fog, which takes the colour out of a small animal.
    "ivory": _look(
        belly=(0.880, 0.845, 0.760), mid=(0.760, 0.700, 0.590),
        back=(0.520, 0.460, 0.370), dark=(0.300, 0.255, 0.195),
        pale=(0.930, 0.900, 0.830), fin=(0.760, 0.715, 0.620),
        fin_tip=(0.880, 0.845, 0.760)),
    # Mossy green over brown: the camouflaged one, which is what most wild seahorses are
    # and what makes a pair of them look like two animals rather than two copies.
    "jade": _look(
        belly=(0.430, 0.470, 0.190), mid=(0.300, 0.340, 0.130),
        back=(0.165, 0.195, 0.075), dark=(0.110, 0.125, 0.050),
        pale=(0.560, 0.590, 0.260), fin=(0.310, 0.350, 0.150),
        fin_tip=(0.470, 0.500, 0.220)),
    # Dusky purple, again *reidi*. Rare enough in life to be worth having and common
    # enough not to be a fantasy.
    "plum": _look(
        belly=(0.470, 0.230, 0.360), mid=(0.330, 0.140, 0.250),
        back=(0.190, 0.070, 0.145), dark=(0.115, 0.040, 0.090),
        pale=(0.610, 0.360, 0.480), fin=(0.340, 0.165, 0.270),
        fin_tip=(0.500, 0.270, 0.400)),
}


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
    # whole length of the tail to a point. The stop just past `snout_base` is what makes
    # the jaw an angle rather than a cone: without it the profile reads the snout and the
    # cheek as one smooth swell and the animal ends up muzzled like an eel.
    radius=[
        (0.000, 0.0014),
        (_AT["snout_base"] * 0.5, 0.0019),
        (_AT["snout_base"], 0.0024),
        (_AT["snout_base"] * 1.45, 0.0052),
        (_AT["head"], 0.0094),
        (_AT["nape"], 0.0078),
        (_AT["chest"], 0.0096),
        (_AT["belly"], 0.0106),
        (_VENT, 0.0064),
        (_tail(0.20), 0.0048),
        (_tail(0.44), 0.0034),
        (_tail(0.68), 0.0023),
        (_tail(0.87), 0.0014),
        (1.000, 0.0007),
    ],
    # Narrower across than through, and not symmetric about the path: a seahorse carries a
    # crown of bone over the back of its head and a pot belly under its trunk, and neither
    # is a radius — a radius would put the crown on the throat too. So the section reaches
    # further up than down over the head and the other way over the trunk. "Up" here is the
    # frame's binormal, which is the top of the snout at the nose and the animal's back
    # behind the bend; see the module docstring's axis table.
    section=(
        [(0.0, 0.95), (_AT["snout_base"], 0.86), (_AT["head"], 0.76),
         (_AT["nape"], 0.74), (_AT["belly"], 0.72), (_VENT, 0.80), (1.0, 0.90)],
        [(0.0, 1.00), (_AT["snout_base"], 1.00), (_AT["head"], 1.12),
         (_AT["head"] * 1.16, 1.22), (_AT["nape"], 1.04), (_AT["chest"], 0.96),
         (_AT["belly"], 0.92), (_VENT, 0.98), (1.0, 1.00)],
        [(0.0, 1.00), (_AT["snout_base"], 0.96), (_AT["head"], 0.90),
         (_AT["nape"], 1.02), (_AT["chest"], 1.16), (_AT["belly"], 1.24),
         (_VENT, 1.02), (1.0, 1.00)],
    ),
    # A seahorse has no scales — it is plated, and the plates give it a section that is
    # closer to a rounded square than to an oval, most obviously along the tail and behind
    # the jaw. Past about 4 the section reads as a rectangle and catches light wrongly, so
    # this stops short of it.
    exponent=[(0.0, 2.2), (_AT["snout_base"], 2.6), (_AT["head"], 3.5),
              (_AT["nape"], 3.5), (_AT["belly"], 3.6), (_VENT, 3.8), (1.0, 3.8)],
    # The frame's up is checked against +Z at a point on the straight part of the trunk,
    # where the answer is not in doubt. See `CurvedBodySpec`.
    body_up=(0.0, -1.0, 0.0),
    dorsal_at=_AT["belly"],
    # The paint job. Amber is the species' own look; the rest of the table is the same
    # animal repainted, and the runtime picks one per individual — see `_look` and
    # `Species.colorways`.
    **_COLORWAYS["amber"],
    colorways=_COLORWAYS,
    # The tubular snout ends in a small round mouth rather than a gape.
    mouth=((0.0512, 0.0, -0.0382), (0.0013, 0.0022, 0.0013)),
    # Plated, not scaled. The rings carry the whole of this animal's relief, so the scale
    # field is left as barely more than a texture break on the specular.
    scale_count=26.0,
    scale_depth=0.03,
    eye=(_AT["head"] * 1.02, 0.34, 0.032),
    # The dorsal fin, and the whole of the animal's propulsion: a small fan on the back
    # over the trunk-to-tail junction, which in life beats fast enough to blur. It is the
    # part the shader ripples — see `SwimDeformation.swift`.
    dorsal=Fin(t0=_AT["belly"] * 0.97, t1=_VENT * 1.03,
               span=[(0.00, 0.0024), (0.25, 0.0080), (0.58, 0.0092),
                     (0.86, 0.0068), (1.00, 0.0018)],
               rake=0.0018, sink=0.24, samples_u=26, samples_v=10,
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
)
