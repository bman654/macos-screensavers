"""Palette surgeonfish (Paracanthurus hepatus)."""

from ._spec import Fin, Species

BLUE_TANG = Species(
    name="blue_tang",
    body_length_m=0.25,
    school=(2, 5),
    depth_band=(0.15, 0.65),
    weight=0.9,
    length=0.125,
    # Near-circular disc, extremely compressed laterally.
    top=[(0.00, 0.0050), (0.05, 0.0225), (0.15, 0.0345), (0.32, 0.0400),
         (0.52, 0.0362), (0.74, 0.0208), (0.90, 0.0110), (1.00, 0.0070)],
    bottom=[(0.00, 0.0052), (0.07, 0.0215), (0.20, 0.0320), (0.38, 0.0370),
            (0.58, 0.0308), (0.78, 0.0165), (0.92, 0.0092), (1.00, 0.0062)],
    width=[(0.00, 0.0032), (0.10, 0.0088), (0.30, 0.0112), (0.52, 0.0098),
           (0.78, 0.0056), (1.00, 0.0028)],
    spine=[(0.00, -0.0045), (0.26, 0.0010), (1.00, 0.0)],
    exponent=2.8,
    # Royal blue, deliberately well short of a saturated primary. The studio key drives
    # irradiance past 2, so any blue albedo much above 0.4 clips its own channel while
    # red and green keep climbing — which is exactly how a royal blue fish turns pale
    # sky blue in a render that has nothing else wrong with it.
    colors=((0.045, 0.145, 0.40), (0.020, 0.075, 0.30), (0.004, 0.020, 0.105)),
    fin_color=(0.030, 0.100, 0.345),
    caudal_color=(0.98, 0.76, 0.04),
    bands=[(0.87, 0.026)],
    band_color=(0.02, 0.02, 0.04),
    outline_width=0.0,
    # The palette marking: a black band along the back from the eye, a riser at the
    # peduncle end and a return along the lower flank, which together enclose the bare
    # blue oval the fish is named for. Ellipsoids taper at their ends, which is what
    # gives the marking its drawn-with-a-brush taper without any extra machinery.
    patches=[
        dict(center=(0.0380, 0.0, 0.0150), radii=(0.0135, 0.100, 0.0170),
             color=(0.015, 0.015, 0.03), softness=0.30),
        dict(center=(-0.0020, 0.0, 0.0245), radii=(0.0470, 0.100, 0.0130),
             color=(0.015, 0.015, 0.03), softness=0.30),
        dict(center=(-0.0300, 0.0, 0.0020), radii=(0.0110, 0.100, 0.0290),
             color=(0.015, 0.015, 0.03), softness=0.30),
        dict(center=(-0.0140, 0.0, -0.0195), radii=(0.0355, 0.100, 0.0115),
             color=(0.015, 0.015, 0.03), softness=0.30),
    ],
    # Royal blue fins darkening to a near-black margin, and a yellow tail whose rays are
    # what makes the fan read as a fan at all once the fin is nearly opaque.
    fin_style=dict(tip_color=(0.014, 0.048, 0.21), edge_color=(0.02, 0.02, 0.05),
                   edge_width=0.09, opacity=0.96),
    caudal_style=dict(tip_color=(0.99, 0.62, 0.02), edge_color=(0.05, 0.04, 0.02),
                      edge_width=0.07, opacity=0.98),
    mouth=((0.0580, 0.0, -0.0105), (0.0045, 0.0070, 0.0028)),
    scale_count=72.0,
    scale_depth=0.13,
    dorsal=Fin(t0=0.12, t1=0.84,
               span=[(0.00, 0.005), (0.25, 0.0175), (0.60, 0.0165), (0.90, 0.0125),
                     (1.00, 0.004)],
               rake=0.004, sink=0.22, samples_u=22),
    anal=Fin(t0=0.40, t1=0.86,
             span=[(0.0, 0.005), (0.45, 0.0165), (1.0, 0.004)],
             rake=0.004, sink=0.22, samples_u=18),
    pectoral=Fin(t0=0.32, t1=0.44,
                 span=[(0.0, 0.005), (0.5, 0.0145), (1.0, 0.005)],
                 rake=0.005, curl=0.003, sink=0.30, samples_u=12),
    # Crescent tail: long tips, deeply cut centre.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.0215), (0.30, 0.0120), (0.5, 0.0080), (0.70, 0.0120),
                     (1.0, 0.0215)],
               flare=[(0.0, 0.0), (1.0, 0.0240)],
               rake=0.002, samples_u=24, samples_v=14),
    caudal_spread=0.9,
    eye=(0.115, 0.45, 0.046),
)
