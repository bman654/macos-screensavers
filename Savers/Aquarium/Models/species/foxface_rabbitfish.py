"""Foxface rabbitfish (Siganus vulpinus)."""

from ._spec import Fin, Species

# The mask is the whole fish, so its two tones are named rather than repeated.
_INK = (0.020, 0.018, 0.022)
_CHALK = (0.900, 0.895, 0.850)

FOXFACE_RABBITFISH = Species(
    name="foxface_rabbitfish",
    body_length_m=0.24,
    school=(1, 2),
    depth_band=(0.35, 0.80),
    weight=0.6,
    length=0.155,
    # A deep compressed oval that runs forward into a long tapering snout: the profile
    # is still narrowing at t=0.16, which is where the "fox" face comes from.
    top=[(0.00, 0.0013), (0.06, 0.0048), (0.12, 0.0105), (0.19, 0.0200),
         (0.28, 0.0330), (0.40, 0.0412), (0.54, 0.0392), (0.70, 0.0288),
         (0.84, 0.0158), (0.94, 0.0086), (1.00, 0.0060)],
    bottom=[(0.00, 0.0013), (0.06, 0.0040), (0.13, 0.0092), (0.21, 0.0185),
            (0.31, 0.0305), (0.43, 0.0378), (0.59, 0.0330), (0.75, 0.0218),
            (0.88, 0.0118), (0.96, 0.0068), (1.00, 0.0054)],
    width=[(0.00, 0.0011), (0.07, 0.0034), (0.16, 0.0066), (0.30, 0.0098),
           (0.50, 0.0098), (0.70, 0.0074), (0.86, 0.0044), (1.00, 0.0026)],
    # The snout leaves the head below the body axis and angled down, which is what keeps
    # it reading as a muzzle rather than as a pointed nose.
    spine=[(0.00, -0.0110), (0.07, -0.0058), (0.18, -0.0010), (0.32, 0.0006),
           (1.00, 0.0)],
    exponent=2.9,
    # Warm golden yellow, held below primary so the studio key does not bleach it.
    colors=((0.630, 0.375, 0.010), (0.620, 0.330, 0.008), (0.560, 0.280, 0.005)),
    fin_color=(0.575, 0.320, 0.008),
    outline_width=0.0,
    # The mask, built as a union of ellipsoids: black first over the snout, eye and the
    # whole underside of the head, then the white forehead laid on top, whose lower rim
    # cuts the diagonal the two tones meet along.
    patches=[
        dict(center=(0.0670, 0.0, -0.0070), radii=(0.0210, 0.100, 0.0135),
             color=_INK, softness=0.16),
        dict(center=(0.0480, 0.0, -0.0050), radii=(0.0195, 0.100, 0.0250),
             color=_INK, softness=0.16),
        dict(center=(0.0350, 0.0, -0.0245), radii=(0.0235, 0.100, 0.0215),
             color=_INK, softness=0.18),
        dict(center=(0.0270, 0.0, -0.0325), radii=(0.0150, 0.100, 0.0120),
             color=_INK, softness=0.22),
        dict(center=(0.0300, 0.0, 0.0330), radii=(0.0215, 0.100, 0.0285),
             color=_CHALK, softness=0.12),
    ],
    mouth=((0.0728, 0.0, -0.0112), (0.0030, 0.0052, 0.0017)),
    scale_count=76.0,
    scale_depth=0.10,
    # One continuous spiny-then-soft dorsal running from the nape to the peduncle.
    dorsal=Fin(t0=0.25, t1=0.87,
               span=[(0.00, 0.004), (0.16, 0.0215), (0.40, 0.0250), (0.66, 0.0230),
                     (0.86, 0.0150), (1.00, 0.0035)],
               rake=0.003, sink=0.18, samples_u=28),
    anal=Fin(t0=0.50, t1=0.89,
             span=[(0.00, 0.004), (0.22, 0.0175), (0.55, 0.0195), (0.85, 0.0120),
                   (1.00, 0.0035)],
             rake=0.003, sink=0.20, samples_u=22),
    pectoral=Fin(t0=0.30, t1=0.43,
                 span=[(0.0, 0.005), (0.45, 0.0165), (1.0, 0.005)],
                 rake=0.005, curl=0.003, sink=0.28, samples_u=14, samples_v=12),
    pelvic=Fin(t0=0.37, t1=0.47,
               span=[(0.0, 0.0035), (0.5, 0.0110), (1.0, 0.0030)],
               rake=0.003, sink=0.32, samples_u=10),
    # Slightly forked to truncate: a shallow notch, not a crescent.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.0195), (0.35, 0.0158), (0.5, 0.0146), (0.65, 0.0158),
                     (1.0, 0.0195)],
               flare=[(0.0, 0.0), (1.0, 0.0250)],
               rake=0.002, samples_u=24, samples_v=14),
    caudal_spread=0.84,
    fin_style=dict(tip_color=(0.645, 0.400, 0.014), opacity=0.96),
    eye=(0.185, 0.44, 0.033),
)
