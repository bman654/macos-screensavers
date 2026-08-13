"""Banggai cardinalfish (Pterapogon kauderni)."""

from ._spec import Fin, Species

_INK = (0.020, 0.020, 0.026)
_FLECK = (0.96, 0.97, 0.98)

BANGGAI_CARDINALFISH = Species(
    name="banggai_cardinalfish",
    length=0.078,
    # Deep and knife-thin, with a big blunt head. The body is deliberately understated:
    # on this fish the silhouette is carried by the fins, and a deeper body would eat the
    # gap the trailing dorsal and anal points need in order to read.
    top=[(0.00, 0.0044), (0.06, 0.0142), (0.16, 0.0192), (0.30, 0.0210),
         (0.50, 0.0184), (0.72, 0.0112), (0.88, 0.0064), (1.00, 0.0043)],
    bottom=[(0.00, 0.0046), (0.08, 0.0146), (0.22, 0.0194), (0.38, 0.0200),
            (0.58, 0.0156), (0.78, 0.0094), (0.92, 0.0056), (1.00, 0.0041)],
    width=[(0.00, 0.0026), (0.10, 0.0062), (0.30, 0.0078), (0.52, 0.0068),
           (0.78, 0.0040), (1.00, 0.0020)],
    spine=[(0.00, -0.0030), (0.24, 0.0008), (1.00, 0.0)],
    exponent=2.8,
    # Silver rather than white: the flecks are the brightest thing on the animal and have
    # to out-read the ground they sit on, so the ground stops well short of paper white.
    colors=((0.66, 0.69, 0.72), (0.46, 0.50, 0.55), (0.20, 0.23, 0.28)),
    fin_color=(0.075, 0.085, 0.105),
    # The three bars are the identity: through the eye, over the pectoral base, and at
    # the second dorsal's origin. No outline — the bars are already the darkest value on
    # the fish, and an outline only muddies their edges.
    bands=[(0.126, 0.038), (0.335, 0.032), (0.530, 0.034)],
    band_color=_INK,
    band_softness=0.008,
    outline_width=0.0,
    # The signature: white flecks scattered over the rear of the body, compositing above
    # the bars so they read across the black as well as across the silver.
    spots=dict(color=_FLECK, count=33.0, size=0.23, coverage=0.62, softness=0.26,
               seed=4.0, t_range=(0.24, 1.0)),
    fin_style=dict(tip_color=(0.030, 0.035, 0.045), edge_color=(0.70, 0.74, 0.78),
                   edge_width=0.055, opacity=0.95,
                   spots=dict(color=_FLECK, count=9.0, size=0.20, coverage=0.45,
                              seed=2.0)),
    mouth=((0.0342, 0.0, -0.0062), (0.0042, 0.0072, 0.0026)),
    scale_count=40.0,
    scale_depth=0.14,
    # One fin standing in for two: a spiny front lobe, a deep notch, then a taller soft
    # lobe drawn out to a trailing point. The notch has to reach nearly to the back or
    # the two dorsals read as one long fin with a dent in it.
    dorsal=Fin(t0=0.16, t1=0.86,
               span=[(0.00, 0.004), (0.07, 0.0175), (0.18, 0.0215), (0.30, 0.0175),
                     (0.38, 0.0035), (0.45, 0.0075), (0.58, 0.0215), (0.72, 0.0285),
                     (0.86, 0.0315), (0.95, 0.0195), (1.00, 0.0045)],
               rake=0.010, sink=0.20, samples_u=40, samples_v=12),
    # The anal mirrors the rear dorsal, so its peak sits late too rather than mid-fin.
    anal=Fin(t0=0.50, t1=0.88,
             span=[(0.0, 0.004), (0.18, 0.0180), (0.44, 0.0250), (0.68, 0.0275),
                   (0.88, 0.0165), (1.0, 0.004)],
             rake=0.009, sink=0.22, samples_u=26, samples_v=12),
    pectoral=Fin(t0=0.30, t1=0.42,
                 span=[(0.0, 0.005), (0.45, 0.0150), (1.0, 0.005)],
                 rake=0.005, curl=0.003, sink=0.30, samples_u=14, samples_v=12),
    # Long trailing pelvics, held back under the belly.
    pelvic=Fin(t0=0.38, t1=0.48,
               span=[(0.0, 0.004), (0.4, 0.0165), (1.0, 0.004)],
               rake=0.008, sink=0.36, samples_u=12),
    # Deeply forked: the centre is cut nearly to the peduncle and the lobes run out
    # almost as far as the body is deep.
    # Span falls monotonically from each end into the cut, which is what makes a lobe
    # taper to a point. Holding it flat near the end instead squares the lobe off into a
    # paddle, and spiking it at one sample gives a needle: the root is only millimetres
    # long, so a lobe's width comes from flare spreading a *range* of u, not from span.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.00, 0.0345), (0.10, 0.0310), (0.22, 0.0240), (0.34, 0.0150),
                     (0.46, 0.0060), (0.50, 0.0048), (0.54, 0.0060), (0.66, 0.0150),
                     (0.78, 0.0240), (0.90, 0.0310), (1.00, 0.0345)],
               flare=[(0.0, 0.0), (1.0, 0.0260)],
               rake=0.002, samples_u=34, samples_v=16),
    caudal_spread=0.85,
    eye=(0.128, 0.46, 0.062),
)
