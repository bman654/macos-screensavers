"""Red lionfish (Pterois volitans).

The whole animal is its fins, so nearly all of the numbers below are in them.

**The spines are a comb in `span`, not thirteen objects.** A lionfish's dorsal is one
membrane with thirteen venomous spines standing far out of it, and that is precisely the
bannerfish's banner repeated: a spike in `span` on a continuous fin, cut back to a low
membrane between spikes. So this species adds no geometry the library did not already
have, and the same trick builds the pectoral fan's free rays. What it does cost is
samples: a spike only exists if `samples_u` puts several samples across it, which is why
the dorsal asks for 150 and the pectorals for 96 where an ordinary fin asks for 20.

**`samples_v` is not that knob and must not be raised with it.** Resolving a spike is
entirely a `samples_u` question; rows across the membrane only multiply the vertex count,
and this fish's two combs were two thirds of a 17k-vertex mesh — 2.5x any other fish in
the library, against a library that has a size budget — before they were cut back.

Each spike is written as three control points — shoulder, peak, shoulder — because the
profile interpolation is shape-preserving and will not overshoot into a spike on its own.
Widening the shoulders fills the notch between neighbouring spines; that is the knob to
reach for if the dorsal reads as a sail rather than as a rank of needles.
"""

from ._spec import Fin, Species

# Deep red on cream, and both numbers are the second attempt. Written pale these render as
# candy-cane pink under the tank's key; written as a near-black mahogany the animal comes
# out dusty rose and reads as washed out beside a library of saturated reef fish — put it
# in `tools/gallery.py` next to a flame angelfish and the difference is the whole story.
# What works is a bar that is genuinely *red* and a base that is held down far enough to
# keep the contrast. Named because the same two tones carry the bands, the fin margins and
# the eye ring, and a lionfish whose fins do not match its bars stops reading as one
# animal.
_MAROON = (0.235, 0.026, 0.014)
_MAROON_LIGHT = (0.360, 0.075, 0.040)
_CREAM = (0.735, 0.655, 0.550)
_CREAM_PALE = (0.865, 0.805, 0.705)


def _comb(peaks, base, half, start, end, tail=()):
    """A rank of spines as a `span` profile: `peaks` spikes evenly spaced over u.

    `base` is the membrane left between them and `half` each spike's half-width in u.
    Returns the (u, span) control points, shoulder-peak-shoulder per spike, preceded by a
    flat membrane and followed by `tail` — whatever the fin does after its last spine,
    which for the dorsal is a soft rayed lobe and for the pectoral fan is nothing.

    `tail` is a parameter rather than something a caller concatenates because the profile
    interpolation sorts its control points and then divides by the gap between neighbours:
    a tail that starts at or before the last shoulder is a division by zero several frames
    from here, with nothing naming the fin that caused it.
    """
    if len(peaks) < 2:
        raise ValueError("a comb needs at least two spines")
    step = (end - start) / (len(peaks) - 1)
    if half >= step * 0.5:
        raise ValueError("spine half-width overlaps its neighbour; the notch would fill")

    points = [(0.0, base)]
    for index, peak in enumerate(peaks):
        u = start + index * step
        points.extend(((u - half, base), (u, peak), (u + half, base)))
    points.extend(tail)
    return _rising(points)


def _splay(count, amount, half, start, end):
    """Alternating sideways lean for a comb's spines, as a `curl` profile over the same u.

    A rank of spines all in the fin's own plane reads as a hair comb from the side, which
    is the one angle the tank ever shows. Real ones fan out to alternate sides, so each
    spine's tip is pushed along the dorsal's curl axis and its neighbours are pushed the
    other way; the notches between them stay at zero so the membrane is only carried
    along rather than sheared. `amount` is the tip's offset in metres and wants to stay
    small — enough to break the comb, not enough to make the membrane zigzag.
    """
    step = (end - start) / (count - 1)
    if half >= step * 0.5:
        raise ValueError("splay half-width overlaps its neighbour")

    points = [(0.0, 0.0)]
    for index in range(count):
        u = start + index * step
        lean = amount if index % 2 == 0 else -amount
        points.extend(((u - half, 0.0), (u, lean), (u + half, 0.0)))
    points.append((1.0, 0.0))
    return _rising(points)


def _banded_rays(count, start, end, ray, notch):
    """Alternate a fin membrane's colour ray by ray, as `along_colors` stops.

    The fan is the same cream as the body it hangs in front of, so from the side it reads
    as a ribbed awning stuck to the flank rather than as a fin. Real ones are banded: each
    ray is dark and the membrane between it and its neighbour is pale. `along_colors` runs
    over the same u the span comb does, so a stop on each ray and each notch paints
    exactly the rays the comb built.

    Cheap in a way the body's bands are not — a colour stop here costs one ramp entry
    rather than four, so twenty-one of them fit where five body bands would not.
    """
    step = (end - start) / (count - 1)
    stops = []
    for index in range(count):
        u = start + index * step
        if index:
            stops.append((u - step * 0.5, notch))
        stops.append((u, ray))
    return _rising(stops)


def _rising(points):
    """Refuse control points that do not increase in u, naming the pair that does not.

    The interpolation sorts silently and then divides by the gap between neighbours, so a
    duplicated or out-of-order u is a division by zero raised from inside the curve code
    with nothing saying which fin of which species produced it.
    """
    for previous, current in zip(points, points[1:]):
        if current[0] <= previous[0]:
            raise ValueError(
                f"control points must increase in u: {previous[0]:.4f} "
                f"is followed by {current[0]:.4f}"
            )
    return points


# The dorsal's thirteen spines, stated once because the span comb and the splay that
# leans it have to agree on where they are; two copies of these numbers would drift.
_DORSAL_SPINES = 13
_DORSAL_START = 0.020
_DORSAL_END = 0.700
_DORSAL_HALF = 0.013

# The pectoral fan's eleven rays, shared by the span comb that builds them and the
# `along_colors` banding that colours them, for the same reason.
_PECTORAL_RAYS = 11
_PECTORAL_START = 0.050
_PECTORAL_END = 0.950


LIONFISH = Species(
    name="lionfish",
    body_length_m=0.33,
    # Solitary and territorial. It hovers rather than cruises, so it wants the open
    # midwater where its fan is seen side-on and not a lane down among the rock.
    school=(1, 1),
    depth_band=(0.25, 0.75),
    weight=0.45,
    length=0.145,
    # A big-headed oval that is deepest well forward, over the pectoral root, and then
    # falls away to a peduncle that stays thick rather than pinching — a lionfish's tail
    # base carries its banding and a narrow one reads as a different fish. The body is
    # only a third of what ends up on screen; the fins are the rest.
    top=[(0.00, 0.0026), (0.05, 0.0112), (0.12, 0.0208), (0.20, 0.0288),
         (0.30, 0.0322), (0.44, 0.0306), (0.60, 0.0240), (0.76, 0.0162),
         (0.90, 0.0104), (1.00, 0.0082)],
    bottom=[(0.00, 0.0024), (0.06, 0.0104), (0.14, 0.0198), (0.23, 0.0272),
            (0.34, 0.0290), (0.50, 0.0256), (0.66, 0.0190), (0.82, 0.0126),
            (0.93, 0.0090), (1.00, 0.0074)],
    width=[(0.00, 0.0018), (0.06, 0.0064), (0.14, 0.0110), (0.26, 0.0136),
           (0.42, 0.0130), (0.60, 0.0100), (0.78, 0.0064), (0.91, 0.0042),
           (1.00, 0.0032)],
    # A large terminal mouth on a nearly straight head profile: the snout drops only
    # slightly, unlike the grazers' muzzles.
    spine=[(0.00, -0.0050), (0.10, -0.0018), (0.25, 0.0), (1.00, 0.0)],
    exponent=2.6,
    colors=(_CREAM_PALE, _CREAM, (0.455, 0.375, 0.300)),
    fin_color=(0.720, 0.635, 0.555),
    # Fourteen bars wrapping the fish from the snout to the peduncle, alternating a wide
    # dark one with a narrow paler one. Hard-edged: this is the marking the fish is
    # recognised by, and softening it turns the animal brown at tank distance.
    #
    # **The two tones are also what makes fourteen bars possible at all.** Bands sharing a
    # colour are drawn by one ramp, a ramp holds 32 stops, and a band costs four — so
    # seven per colour is the ceiling and a single-tone lionfish is refused at build time.
    # Splitting the bars by width is the accurate way to buy the second ramp.
    bands=[(0.055, 0.020, _MAROON), (0.118, 0.011, _MAROON_LIGHT),
           (0.180, 0.020, _MAROON), (0.243, 0.011, _MAROON_LIGHT),
           (0.305, 0.019, _MAROON), (0.368, 0.011, _MAROON_LIGHT),
           (0.430, 0.019, _MAROON), (0.493, 0.010, _MAROON_LIGHT),
           (0.555, 0.018, _MAROON), (0.618, 0.010, _MAROON_LIGHT),
           (0.680, 0.017, _MAROON), (0.743, 0.010, _MAROON_LIGHT),
           (0.805, 0.015, _MAROON), (0.885, 0.009, _MAROON_LIGHT)],
    band_color=_MAROON,
    band_softness=0.006,
    # No outline. The bars are already the darkest thing on the fish and an outline only
    # doubles every one of the fourteen.
    outline_width=0.0,
    mouth=((0.0646, 0.0, -0.0100), (0.0040, 0.0068, 0.0026)),
    mouth_color=(0.190, 0.070, 0.055),
    scale_count=70.0,
    scale_depth=0.12,
    eye=(0.140, 0.62, 0.044),
    eye_ring=dict(color=_MAROON_LIGHT, width=0.50, softness=0.30),
    # Thirteen dorsal spines, longest at the third and fourth and shortening backwards,
    # then a short soft dorsal over the peduncle. The spines occupy u up to 0.70 and the
    # soft fin the remainder, which is why the comb stops there rather than at 1. The
    # `curl` leans alternate spines to alternate sides — see `_splay`.
    dorsal=Fin(
        t0=0.18, t1=0.92,
        span=_comb(
            peaks=[0.046, 0.064, 0.072, 0.072, 0.069, 0.065, 0.060,
                   0.056, 0.052, 0.048, 0.044, 0.039, 0.034],
            base=0.005, half=_DORSAL_HALF,
            start=_DORSAL_START, end=_DORSAL_END,
            tail=[(0.760, 0.010), (0.820, 0.018), (0.900, 0.016), (1.000, 0.004)],
        ),
        curl=_splay(_DORSAL_SPINES, 0.0045, _DORSAL_HALF,
                    _DORSAL_START, _DORSAL_END),
        rake=[(0.00, 0.005), (0.70, 0.006), (1.00, 0.009)],
        sink=0.16, samples_u=150, samples_v=7,
    ),
    # Three anal spines and a soft lobe behind them. The same comb, three teeth wide.
    anal=Fin(
        t0=0.62, t1=0.94,
        span=_comb(peaks=[0.032, 0.029, 0.026], base=0.006,
                   half=0.022, start=0.070, end=0.400,
                   tail=[(0.560, 0.021), (0.760, 0.017), (1.000, 0.004)]),
        rake=0.005, sink=0.20, samples_u=56, samples_v=8,
    ),
    # The fan, and the reason anyone recognises this animal. Eleven free rays reaching
    # well past the belly and the peduncle, spread fore and aft by `flare` — which is
    # what opens them into a fan rather than a bundle — and swept back by `rake` so the
    # fan clears the body's own outline from the side, which is the only angle the tank
    # shows. `curl` is kept small on purpose: paired fins have it multiplied by the side,
    # so a large value tips one fan up and the other down.
    pectoral=Fin(
        t0=0.24, t1=0.46,
        span=_comb(
            peaks=[0.056, 0.070, 0.081, 0.086, 0.087, 0.084,
                   0.078, 0.069, 0.059, 0.049, 0.039],
            base=0.013, half=0.028,
            start=_PECTORAL_START, end=_PECTORAL_END,
            tail=[(1.000, 0.013)],
        ),
        flare=[(0.0, 0.0), (0.35, 0.022), (1.0, 0.060)],
        rake=0.017, curl=0.003, sink=0.30, samples_u=96, samples_v=9,
        style=dict(opacity=0.80, ray_count=44.0, ray_contrast=0.55,
                   edge_color=_MAROON, edge_width=0.05,
                   along_colors=_banded_rays(
                       _PECTORAL_RAYS, _PECTORAL_START, _PECTORAL_END,
                       ray=_MAROON_LIGHT, notch=(0.830, 0.770, 0.680))),
    ),
    # Long pelvics hanging below the belly, a single broad blade rather than a comb.
    pelvic=Fin(t0=0.40, t1=0.54,
               span=[(0.00, 0.009), (0.35, 0.048), (0.70, 0.035), (1.00, 0.009)],
               rake=0.014, curl=0.0025, sink=0.34, samples_u=16, samples_v=10),
    # Rounded and large but unremarkable, which is correct: nothing about a lionfish's
    # tail is meant to compete with the front of it.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.034), (0.5, 0.042), (1.0, 0.034)],
               flare=[(0.0, 0.0), (1.0, 0.038)],
               rake=0.002, samples_u=22, samples_v=12),
    caudal_spread=0.86,
    # Translucent membranes with strong rays, so the fan reads as separate rays even
    # where the membrane between them survives. The maroon margin carries the body's
    # banding out into the fins without needing a marking of its own.
    fin_style=dict(tip_color=(0.400, 0.115, 0.075), opacity=0.80,
                   ray_count=44.0, ray_contrast=0.90,
                   edge_color=_MAROON, edge_width=0.07),
    caudal_style=dict(tip_color=(0.400, 0.115, 0.075), opacity=0.82,
                      ray_count=30.0, ray_contrast=0.75),
)
