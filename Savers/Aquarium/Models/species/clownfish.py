"""Ocellaris clownfish — the reference species the pipeline was tuned against."""

from ._spec import Fin, Species

CLOWNFISH = Species(
    name="clownfish",
    body_length_m=0.09,
    school=(2, 4),
    # Strongly site-attached to a host anemone; keep its lane among the reef props.
    # Pairing it to the anemone prop belongs in fish placement/AI, not the model catalog.
    depth_band=(0.35, 0.75),
    weight=1.3,
    length=0.095,
    # Stocky and egg-shaped: depth is over half the body length, and the snout is blunt.
    top=[(0.00, 0.0060), (0.06, 0.0195), (0.16, 0.0250), (0.30, 0.0268),
         (0.50, 0.0242), (0.72, 0.0158), (0.88, 0.0098), (1.00, 0.0068)],
    bottom=[(0.00, 0.0062), (0.08, 0.0180), (0.20, 0.0225), (0.36, 0.0248),
            (0.56, 0.0212), (0.76, 0.0128), (0.90, 0.0082), (1.00, 0.0060)],
    width=[(0.00, 0.0042), (0.08, 0.0110), (0.22, 0.0145), (0.38, 0.0152),
           (0.58, 0.0128), (0.80, 0.0072), (1.00, 0.0036)],
    spine=[(0.00, -0.0030), (0.22, 0.0005), (1.00, 0.0)],
    exponent=2.5,
    colors=((1.00, 0.45, 0.06), (0.95, 0.26, 0.02), (0.55, 0.11, 0.01)),
    fin_color=(0.95, 0.35, 0.05),
    bands=[(0.22, 0.040), (0.50, 0.050), (0.83, 0.032)],
    band_softness=0.010,
    outline_width=0.020,
    mouth=((0.0435, 0.0, -0.0075), (0.0050, 0.0090, 0.0032)),
    scale_count=52.0,
    scale_depth=0.18,
    # Spiny front section, a notch, then a taller soft rear lobe.
    dorsal=Fin(t0=0.15, t1=0.80,
               span=[(0.00, 0.004), (0.10, 0.0125), (0.30, 0.0130), (0.52, 0.0100),
                     (0.70, 0.0165), (0.90, 0.0130), (1.00, 0.004)],
               rake=0.003, sink=0.22, samples_u=26),
    anal=Fin(t0=0.55, t1=0.86,
             span=[(0.0, 0.004), (0.5, 0.0125), (1.0, 0.0035)],
             rake=0.003, sink=0.25),
    pectoral=Fin(t0=0.29, t1=0.43,
                 span=[(0.0, 0.006), (0.45, 0.0175), (1.0, 0.006)],
                 rake=0.005, curl=0.0035, sink=0.30, samples_u=14, samples_v=12),
    pelvic=Fin(t0=0.38, t1=0.48,
               span=[(0.0, 0.004), (0.5, 0.0115), (1.0, 0.0035)],
               rake=0.003, sink=0.38, samples_u=10),
    # Rounded paddle: it has to widen as it extends, which is what flare does.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.0125), (0.5, 0.0205), (1.0, 0.0125)],
               flare=[(0.0, 0.0), (0.5, 0.0110), (1.0, 0.0240)],
               samples_u=24, samples_v=14),
    caudal_spread=0.75,
    eye=(0.135, 0.42, 0.048),
)
