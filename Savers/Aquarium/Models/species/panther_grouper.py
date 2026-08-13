"""Panther / humpback grouper (Cromileptes altivelis), juvenile form."""

from ._spec import Fin, Species

_INK = (0.020, 0.020, 0.028)

PANTHER_GROUPER = Species(
    name="panther_grouper",
    body_length_m=0.35,
    school=(1, 1),
    depth_band=(0.50, 0.90),
    weight=0.3,
    length=0.160,
    # The silhouette is the species, and `spine` is what produces it. The axis plunges
    # under the head to its lowest point at t=0.11, then climbs 0.019 m to the hump —
    # more spine travel than any other fish here, and the reason the fish reads as
    # leaning forward. Two separate effects are stacked on it:
    #
    #   * the dished forehead. The spine drops as fast as the half-depth grows, so the
    #     dorsal line stays almost flat from t=0.04 to t=0.13 and then climbs 0.037 m in
    #     the next fifth of the body. That near-flat run is the scoop the eye sits in.
    #     Letting the dorsal line actually *dip* there overshoots into a bulbous,
    #     beluga-like snout; flat is as far as this goes.
    #   * the level belly. Because the spine carries all of the asymmetry, top and
    #     bottom stay near-equal, and the ventral line comes out almost straight while
    #     the dorsal line does all the climbing.
    spine=[(0.00, -0.0097), (0.04, -0.0125), (0.08, -0.0147), (0.13, -0.0161),
           (0.18, -0.0120), (0.24, -0.0047), (0.31, 0.0011), (0.40, 0.0026),
           (0.50, 0.0023), (0.64, 0.0014), (0.78, 0.0005), (1.00, 0.0)],
    top=[(0.00, 0.0030), (0.04, 0.0075), (0.08, 0.0101), (0.13, 0.0121),
         (0.18, 0.0180), (0.24, 0.0262), (0.31, 0.0315), (0.40, 0.0324),
         (0.50, 0.0309), (0.64, 0.0256), (0.78, 0.0175), (0.90, 0.0106),
         (1.00, 0.0061)],
    bottom=[(0.00, 0.0030), (0.04, 0.0075), (0.08, 0.0101), (0.13, 0.0121),
            (0.18, 0.0180), (0.24, 0.0261), (0.31, 0.0314), (0.40, 0.0324),
            (0.50, 0.0309), (0.64, 0.0256), (0.78, 0.0175), (0.90, 0.0106),
            (1.00, 0.0061)],
    # Groupers are thick through the shoulders, not plate-like: a generous width and an
    # almost-elliptical exponent keep the cross-section round.
    width=[(0.00, 0.0026), (0.04, 0.0064), (0.10, 0.0102), (0.20, 0.0136),
           (0.32, 0.0158), (0.44, 0.0158), (0.60, 0.0130), (0.76, 0.0086),
           (0.90, 0.0050), (1.00, 0.0028)],
    exponent=2.15,
    # Pale, faintly green-grey white; the back only barely darker, since the fish has to
    # read as white-with-dots rather than as a countershaded fish that happens to be spotty.
    colors=((0.82, 0.83, 0.80), (0.74, 0.78, 0.76), (0.52, 0.58, 0.58)),
    fin_color=(0.70, 0.74, 0.72),
    outline_width=0.0,
    # The identifying marking. A single scatter leaves the head bare — the head is thin,
    # so far fewer Voronoi cells intersect it than intersect the flank — so the face gets
    # its own denser draw confined to the front third.
    spots=[dict(color=_INK, count=16.0, size=0.30, coverage=0.90,
                softness=0.22, seed=2.0),
           dict(color=_INK, count=22.0, size=0.28, coverage=0.62,
                softness=0.22, seed=11.0, t_range=(0.0, 0.30))],
    fin_style=dict(tip_color=(0.78, 0.82, 0.80), opacity=0.94,
                   spots=dict(color=_INK, count=8.0, size=0.34, coverage=0.85,
                              softness=0.25, seed=5.0)),
    # Groupers have a big mouth, and on a head this pale it is the only thing besides
    # the eye that stops the face reading as a blank wedge.
    mouth=((0.0745, 0.0, -0.0115), (0.0070, 0.0112, 0.0040)),
    scale_count=78.0,
    scale_depth=0.09,
    # Long and low over the spiny section, then a rounded soft lobe. `sink` stays shallow:
    # on a back this deep a normal sink swallows the whole fin into the hump.
    dorsal=Fin(t0=0.26, t1=0.87,
               span=[(0.00, 0.005), (0.10, 0.0165), (0.35, 0.0175), (0.55, 0.0175),
                     (0.75, 0.0245), (0.92, 0.0180), (1.00, 0.006)],
               rake=0.003, sink=0.06, samples_u=26),
    anal=Fin(t0=0.58, t1=0.88,
             span=[(0.0, 0.005), (0.35, 0.0240), (0.70, 0.0220), (1.0, 0.005)],
             rake=0.003, sink=0.12, samples_u=18),
    # Large rounded paddles. Without `flare` the membrane can only extend, and a fin seen
    # nearly edge-on from the side then reads as a rectangular flag rather than a paddle.
    pectoral=Fin(t0=0.29, t1=0.44,
                 span=[(0.0, 0.006), (0.25, 0.0195), (0.50, 0.0250), (0.75, 0.0215),
                       (1.0, 0.008)],
                 flare=[(0.0, 0.0), (1.0, 0.0075)],
                 rake=0.008, curl=0.006, sink=0.30, samples_u=16, samples_v=12),
    pelvic=Fin(t0=0.34, t1=0.46,
               span=[(0.0, 0.005), (0.5, 0.0175), (1.0, 0.005)],
               rake=0.003, sink=0.35, samples_u=12),
    # Rounded, never forked. A three-point span gives a rhombus however wide the flare
    # is; the trailing edge only comes out as an arc if the span itself is one.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.00, 0.0135), (0.15, 0.0230), (0.32, 0.0288), (0.50, 0.0302),
                     (0.68, 0.0288), (0.85, 0.0230), (1.00, 0.0135)],
               flare=[(0.0, 0.0), (0.5, 0.0150), (1.0, 0.0300)],
               samples_u=26, samples_v=14),
    caudal_spread=0.85,
    # The eye is seated by `abs(y) * 0.62`, so on a head this narrow a radius much under
    # 0.027 is swallowed whole and the face renders blank. `height` is held down to 0.36
    # to keep the sphere from breaking the dorsal line of a head only 24 mm deep.
    eye=(0.105, 0.36, 0.028),
)
