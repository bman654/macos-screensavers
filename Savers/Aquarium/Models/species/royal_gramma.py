"""Royal gramma (Gramma loreto)."""

from ._spec import Fin, Species


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
    fin_color=(0.23, 0.006, 0.29),
    caudal_color=(0.78, 0.38, 0.012),
    split=dict(color=(0.78, 0.38, 0.012), t=0.50, hardness=0.84),
    # One thin, rising rule is confined to the eye region; the large spacing prevents a
    # second repeat from entering the restricted patch of flank.
    diagonal_stripes=dict(color=(0.012, 0.006, 0.018), angle=-12.0, spacing=0.130,
                          width=0.09, softness=0.22,
                          t_range=(0.015, 0.27), h_range=(0.64, 0.96)),
    fin_style=dict(tip_color=(0.14, 0.004, 0.23), opacity=0.93,
                   spots=dict(color=(0.012, 0.006, 0.018), count=3.0, size=0.20,
                              coverage=0.24, softness=0.32, seed=0.0)),
    caudal_style=dict(tip_color=(0.92, 0.52, 0.018), opacity=0.97),
    mouth=((0.0274, 0.0, -0.0047), (0.0038, 0.0066, 0.0021)),
    scale_count=58.0,
    scale_depth=0.11,
    dorsal=Fin(t0=0.10, t1=0.87,
               span=[(0.00, 0.0025), (0.10, 0.0074), (0.38, 0.0078),
                     (0.70, 0.0070), (0.92, 0.0052), (1.00, 0.0022)],
               rake=0.0024, sink=0.24, samples_u=28),
    anal=Fin(t0=0.50, t1=0.87,
             span=[(0.0, 0.0024), (0.35, 0.0068), (0.75, 0.0060), (1.0, 0.0020)],
             rake=0.0025, sink=0.26, samples_u=16),
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
