"""Royal gramma (Gramma loreto)."""

from ._spec import Fin, Species

_VIOLET = (0.23, 0.006, 0.29)
_VIOLET_TIP = (0.14, 0.004, 0.23)
_GOLD = (0.78, 0.38, 0.012)
_GOLD_TIP = (0.92, 0.52, 0.018)
_FLECK = (0.012, 0.006, 0.018)
# Where the body's two tones meet, and how far the blend runs either side of it. The
# fins have to change colour over the same interval or the fish reads as a violet fish
# wearing gold fins rather than as one animal.
_SPLIT_T = 0.50
_SPLIT_SPOTS = dict(color=_FLECK, count=3.0, size=0.20, coverage=0.24, softness=0.32,
                    seed=0.0)


def _at(fin_t0, fin_t1, body_t):
    """The fin's own u at a given body t — what the `along_colors` stops are placed in."""
    return (body_t - fin_t0) / (fin_t1 - fin_t0)


ROYAL_GRAMMA = Species(
    name="royal_gramma",
    length=0.060,
    # Slender basslet body: low-backed and much rounder in section than a disc fish.
    top=[(0.00, 0.0038), (0.07, 0.0074), (0.19, 0.0104), (0.38, 0.0112),
         (0.58, 0.0104), (0.76, 0.0076), (0.91, 0.0046), (1.00, 0.0034)],
    bottom=[(0.00, 0.0040), (0.08, 0.0068), (0.22, 0.0092), (0.42, 0.0098),
            (0.62, 0.0088), (0.79, 0.0063), (0.92, 0.0041), (1.00, 0.0032)],
    width=[(0.00, 0.0028), (0.08, 0.0061), (0.23, 0.0079), (0.45, 0.0081),
           (0.65, 0.0069), (0.82, 0.0047), (1.00, 0.0024)],
    spine=[(0.00, -0.0015), (0.20, 0.0003), (1.00, 0.0)],
    exponent=2.25,
    # Restrained linear values keep the studio key from bleaching violet into hot pink.
    colors=((0.32, 0.020, 0.32), (0.245, 0.006, 0.31), (0.10, 0.002, 0.22)),
    fin_color=_VIOLET,
    caudal_color=_GOLD,
    split=dict(color=_GOLD, t=_SPLIT_T, hardness=0.84),
    # One thin rule confined to the eye region; the large spacing prevents a second
    # repeat from entering the restricted patch of flank. The angle is positive because
    # this fish's oblique eye rule runs up and back from the snout, and a positive angle
    # is the one that rises towards the tail.
    diagonal_stripes=dict(color=_FLECK, angle=12.0, spacing=0.130,
                          width=0.09, softness=0.22,
                          t_range=(0.015, 0.27), h_range=(0.64, 0.96)),
    fin_style=dict(tip_color=_VIOLET_TIP, opacity=0.93, spots=_SPLIT_SPOTS),
    caudal_style=dict(tip_color=_GOLD_TIP, opacity=0.97),
    mouth=((0.0274, 0.0, -0.0047), (0.0038, 0.0066, 0.0021)),
    scale_count=58.0,
    scale_depth=0.11,
    # The dorsal runs the whole length of the fish, across the split, so it has to carry
    # both tones itself: it is one membrane and cannot be two materials. The stops are
    # placed at the body t where the split's own blend starts and ends, converted into
    # the fin's u, so the fin changes colour exactly where the flank under it does.
    dorsal=Fin(t0=0.10, t1=0.87,
               span=[(0.00, 0.0025), (0.10, 0.0074), (0.38, 0.0078),
                     (0.70, 0.0070), (0.92, 0.0052), (1.00, 0.0022)],
               rake=0.0024, sink=0.24, samples_u=28,
               style=dict(opacity=0.93, spots=_SPLIT_SPOTS,
                          along_colors=[(0.0, _VIOLET, _VIOLET_TIP),
                                        (_at(0.10, 0.87, _SPLIT_T - 0.055),
                                         _VIOLET, _VIOLET_TIP),
                                        (_at(0.10, 0.87, _SPLIT_T + 0.055),
                                         _GOLD, _GOLD_TIP),
                                        (1.0, _GOLD, _GOLD_TIP)])),
    # The anal begins at the split and is gold for its whole length.
    anal=Fin(t0=0.50, t1=0.87,
             span=[(0.0, 0.0024), (0.35, 0.0068), (0.75, 0.0060), (1.0, 0.0020)],
             rake=0.0025, sink=0.26, samples_u=16,
             color=_GOLD, style=dict(tip_color=_GOLD_TIP, opacity=0.93)),
    pectoral=Fin(t0=0.27, t1=0.40,
                 span=[(0.0, 0.0023), (0.45, 0.0090), (1.0, 0.0022)],
                 rake=0.0032, curl=0.0023, sink=0.32, samples_u=12, samples_v=10),
    # Long magenta pelvics are characteristic even though they are subtle in side view.
    pelvic=Fin(t0=0.32, t1=0.45,
               span=[(0.0, 0.0020), (0.42, 0.0130), (1.0, 0.0018)],
               rake=0.0050, curl=0.0015, sink=0.36, samples_u=12, samples_v=12),
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.0090), (0.25, 0.0093), (0.50, 0.0096),
                     (0.75, 0.0093), (1.0, 0.0090)],
               flare=[(0.0, 0.0), (0.55, 0.0060), (1.0, 0.0125)],
               rake=0.0010, samples_u=22, samples_v=14),
    caudal_spread=0.80,
    eye=(0.120, 0.40, 0.048),
)
