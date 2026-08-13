"""Emperor angelfish (Pomacanthus imperator), adult colouration."""

from ._spec import Fin, Species

_INK = (0.020, 0.018, 0.040)
_ELECTRIC = (0.075, 0.330, 0.680)
_YELLOW = (0.980, 0.720, 0.050)

EMPEROR_ANGELFISH = Species(
    name="emperor_angelfish",
    body_length_m=0.40,
    school=(1, 1),
    depth_band=(0.55, 0.95),
    weight=0.35,
    length=0.155,
    # Deep oval, but a thick one: an angelfish is a slab, not the disc a tang is.
    top=[(0.00, 0.0090), (0.05, 0.0272), (0.14, 0.0400), (0.28, 0.0476),
         (0.45, 0.0488), (0.62, 0.0415), (0.80, 0.0255), (0.92, 0.0144),
         (1.00, 0.0086)],
    bottom=[(0.00, 0.0092), (0.07, 0.0262), (0.20, 0.0384), (0.38, 0.0452),
            (0.55, 0.0415), (0.74, 0.0258), (0.90, 0.0134), (1.00, 0.0076)],
    width=[(0.00, 0.0052), (0.10, 0.0118), (0.28, 0.0152), (0.50, 0.0148),
           (0.76, 0.0086), (1.00, 0.0038)],
    spine=[(0.00, -0.0060), (0.26, 0.0015), (1.00, 0.0)],
    exponent=2.6,
    # Deep blue-purple ground. Kept well below a saturated primary for the same reason
    # the tang is: the studio key drives the blue channel past its own clip long before
    # red and green get there, and a clipped blue reads as washed-out grey.
    colors=((0.085, 0.055, 0.200), (0.050, 0.035, 0.155), (0.020, 0.016, 0.080)),
    fin_color=(0.040, 0.030, 0.135),
    caudal_color=_YELLOW,
    # The ruling this species exists to exercise: ~26 fine yellow lines sweeping up and
    # back across the flank, starting behind the head so they never cross the eye mask.
    # A positive angle is the one that rises towards the tail, which is the direction
    # this fish's stripes run; negative mirrors them and reads as the wrong animal.
    diagonal_stripes=dict(color=_YELLOW, angle=25.0, spacing=0.031, width=0.30,
                          softness=0.22, t_range=(0.24, 1.0)),
    # The face mask: a broad dark bar down through the eye, edged in electric blue.
    bands=[(0.145, 0.042)],
    band_color=_INK,
    band_softness=0.010,
    outline_color=_ELECTRIC,
    outline_width=0.008,
    patches=[
        # Pectoral base: a blue-edged blue-black blotch, drawn as a halo with the dark
        # centre laid over it.
        dict(center=(0.0372, 0.0, -0.0035), radii=(0.0100, 0.150, 0.0178),
             color=(0.050, 0.200, 0.440), softness=0.16),
        dict(center=(0.0372, 0.0, -0.0035), radii=(0.0086, 0.150, 0.0156),
             color=(0.014, 0.016, 0.042), softness=0.16),
        # The mouth, as a patch rather than via `mouth`: the mouth mask has a fixed
        # dark-red colour that a species cannot override, and this one is nearly white.
        dict(center=(0.0738, 0.0, -0.0110), radii=(0.0050, 0.150, 0.0036),
             color=(0.720, 0.740, 0.730), softness=0.40),
    ],
    scale_count=78.0,
    scale_depth=0.12,
    # Dark blue fins with a bright blue margin; the tail is the one yellow thing on the
    # fish that is not a stripe.
    fin_style=dict(tip_color=(0.016, 0.014, 0.070), edge_color=(0.055, 0.230, 0.500),
                   edge_width=0.075, opacity=0.95),
    caudal_style=dict(tip_color=(0.990, 0.600, 0.020), edge_color=(0.990, 0.880, 0.450),
                      edge_width=0.06, opacity=0.98),
    dorsal=Fin(t0=0.18, t1=0.93,
               span=[(0.00, 0.004), (0.12, 0.0150), (0.40, 0.0200), (0.68, 0.0265),
                     (0.86, 0.0240), (1.00, 0.007)],
               rake=0.004, sink=0.22, samples_u=28),
    anal=Fin(t0=0.44, t1=0.93,
             span=[(0.00, 0.005), (0.32, 0.0205), (0.70, 0.0235), (1.00, 0.006)],
             rake=0.004, sink=0.22, samples_u=22),
    pectoral=Fin(t0=0.32, t1=0.44,
                 span=[(0.0, 0.006), (0.45, 0.0185), (1.0, 0.006)],
                 rake=0.005, curl=0.003, sink=0.30, samples_u=14, samples_v=12),
    pelvic=Fin(t0=0.42, t1=0.50,
               span=[(0.0, 0.005), (0.35, 0.0165), (1.0, 0.004)],
               rake=0.006, sink=0.36, samples_u=12),
    # Rounded, almost truncate paddle.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.0180), (0.5, 0.0265), (1.0, 0.0180)],
               flare=[(0.0, 0.0), (0.5, 0.0155), (1.0, 0.0320)],
               samples_u=24, samples_v=14),
    caudal_spread=0.80,
    eye=(0.140, 0.47, 0.038),
)
