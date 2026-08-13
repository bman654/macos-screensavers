"""Male lyretail anthias (Pseudanthias squamipinnis)."""

from ._spec import Fin, Species

LYRETAIL_ANTHIAS = Species(
    name="lyretail_anthias",
    length=0.086,
    # An elegant perch-like oval: moderately deep, laterally compressed, and smoothly
    # tapered into a narrow peduncle rather than carrying the depth of a tang to the tail.
    top=[(0.00, 0.0034), (0.07, 0.0118), (0.19, 0.0182), (0.35, 0.0206),
         (0.52, 0.0195), (0.70, 0.0146), (0.87, 0.0081), (1.00, 0.0046)],
    bottom=[(0.00, 0.0036), (0.08, 0.0104), (0.22, 0.0163), (0.40, 0.0178),
            (0.58, 0.0156), (0.75, 0.0105), (0.90, 0.0061), (1.00, 0.0042)],
    width=[(0.00, 0.0024), (0.09, 0.0061), (0.27, 0.0086), (0.48, 0.0089),
           (0.68, 0.0071), (0.84, 0.0045), (1.00, 0.0023)],
    spine=[(0.00, -0.0021), (0.22, 0.0005), (1.00, 0.0)],
    exponent=2.6,
    # Warm coral-orange below, saturated fuchsia through the flank, and violet-magenta
    # over the back. Countershading carries the look; anthias have no hard body pattern.
    colors=((0.96, 0.27, 0.050), (0.56, 0.024, 0.32), (0.22, 0.008, 0.37)),
    fin_color=(0.52, 0.018, 0.34),
    patches=[
        # Four overlapping ellipses approximate the male's eye-to-cheek slash. Patches
        # cannot rotate, so their descending centres provide the diagonal gesture.
        dict(center=(0.0280, 0.0, 0.0070), radii=(0.0055, 0.100, 0.0032),
             color=(0.20, 0.006, 0.32), softness=0.32),
        dict(center=(0.0250, 0.0, 0.0047), radii=(0.0055, 0.100, 0.0032),
             color=(0.20, 0.006, 0.32), softness=0.32),
        dict(center=(0.0220, 0.0, 0.0024), radii=(0.0053, 0.100, 0.0030),
             color=(0.20, 0.006, 0.32), softness=0.34),
        dict(center=(0.0190, 0.0, 0.0001), radii=(0.0050, 0.100, 0.0028),
             color=(0.20, 0.006, 0.32), softness=0.36),
    ],
    fin_style=dict(tip_color=(0.25, 0.010, 0.34), edge_color=(0.98, 0.56, 0.055),
                   edge_width=0.075, opacity=0.88),
    mouth=((0.0405, 0.0, -0.0048), (0.0032, 0.0055, 0.0018)),
    scale_count=68.0,
    scale_depth=0.10,
    # A narrow spike near the leading edge is the male's elongated third dorsal spine.
    dorsal=Fin(t0=0.13, t1=0.82,
               span=[(0.00, 0.0035), (0.105, 0.0090), (0.125, 0.0320), (0.145, 0.0095),
                     (0.38, 0.0118), (0.66, 0.0128), (0.88, 0.0100), (1.00, 0.0030)],
               rake=[(0.00, 0.002), (0.105, 0.003), (0.125, 0.020), (0.145, 0.003),
                     (1.00, 0.004)],
               sink=0.21, samples_u=64, samples_v=18),
    anal=Fin(t0=0.48, t1=0.86,
             span=[(0.0, 0.0030), (0.30, 0.0090), (0.62, 0.0108), (0.84, 0.0082),
                   (1.0, 0.0026)],
             rake=0.004, sink=0.24, samples_u=20),
    pectoral=Fin(t0=0.27, t1=0.40,
                 span=[(0.0, 0.0030), (0.45, 0.0120), (1.0, 0.0030)],
                 rake=0.0045, curl=0.0028, sink=0.31, samples_u=14, samples_v=12),
    pelvic=Fin(t0=0.34, t1=0.45,
               span=[(0.0, 0.0025), (0.48, 0.0078), (1.0, 0.0022)],
               rake=0.003, sink=0.36, samples_u=12),
    # The endpoint reaches are filaments; the rapid falloff toward u=0.18/0.82 leaves a
    # deep central fork, while flare opens the two lobes vertically into a lyre silhouette.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.00, 0.0410), (0.07, 0.0360), (0.17, 0.0210), (0.30, 0.0110),
                     (0.50, 0.0070), (0.70, 0.0110), (0.83, 0.0210), (0.93, 0.0360),
                     (1.00, 0.0410)],
               flare=[(0.0, 0.0), (0.45, 0.0140), (1.0, 0.0280)],
               rake=0.0015, samples_u=42, samples_v=18),
    caudal_spread=0.88,
    eye=(0.125, 0.44, 0.055),
    eye_ring=(0.20, 0.015, 0.24),
)
