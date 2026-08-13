"""Longfin bannerfish / pennant coralfish (Heniochus acuminatus)."""

from ._spec import Fin, Species

_INK = (0.02, 0.02, 0.04)
_YELLOW = (0.95, 0.70, 0.03)
_YELLOW_TIP = (0.98, 0.78, 0.05)
_FIN_WHITE = (0.88, 0.88, 0.84)
_FIN_WHITE_TIP = (0.97, 0.97, 0.94)

BANNERFISH = Species(
    name="bannerfish",
    body_length_m=0.20,
    school=(1, 2),
    depth_band=(0.20, 0.65),
    weight=0.8,
    length=0.115,
    # A tall disc, deeper than it is long once the fins are counted, drawn out to a
    # short pointed snout.
    top=[(0.00, 0.0026), (0.05, 0.0130), (0.13, 0.0300), (0.26, 0.0400),
         (0.44, 0.0420), (0.64, 0.0330), (0.82, 0.0175), (0.93, 0.0085),
         (1.00, 0.0058)],
    bottom=[(0.00, 0.0026), (0.06, 0.0125), (0.15, 0.0285), (0.30, 0.0385),
            (0.48, 0.0380), (0.68, 0.0285), (0.84, 0.0150), (0.94, 0.0075),
            (1.00, 0.0055)],
    width=[(0.00, 0.0016), (0.06, 0.0050), (0.16, 0.0082), (0.32, 0.0095),
           (0.52, 0.0086), (0.72, 0.0058), (0.88, 0.0034), (1.00, 0.0022)],
    spine=[(0.00, -0.0085), (0.08, -0.0028), (0.20, 0.0010), (1.00, 0.0)],
    exponent=3.0,
    # White, with only enough countershading to keep the back from going flat.
    colors=((0.92, 0.92, 0.89), (0.86, 0.86, 0.83), (0.70, 0.71, 0.73)),
    fin_color=(0.88, 0.88, 0.84),
    caudal_color=_YELLOW,
    # Two broad black bands on white, plus the dark bar over the eye. No outline: the
    # bands are already the darkest thing on the fish and an outline only doubles them.
    bands=[(0.105, 0.030), (0.350, 0.078), (0.700, 0.090)],
    band_color=_INK,
    band_softness=0.010,
    outline_width=0.0,
    # The default for the white fins. The pectorals, pelvics and the rear half of the
    # dorsal each override it below; see `Fin.style`.
    fin_style=dict(tip_color=(0.97, 0.97, 0.94), opacity=0.96),
    caudal_style=dict(tip_color=(0.98, 0.78, 0.05), opacity=0.97),
    mouth=((0.0540, 0.0, -0.0090), (0.0030, 0.0060, 0.0018)),
    scale_count=76.0,
    scale_depth=0.10,
    # The banner: one enormously elongated spine partway along the dorsal, carried
    # backwards by a matching spike in `rake` so the filament arcs up and then trails
    # well past the tail. The rest of the profile is an ordinary low soft dorsal.
    #
    # Spinous dorsal and pennant white, soft dorsal yellow — one membrane, so it has to
    # be a `u` ramp rather than two fins. The stops are placed to leave the banner well
    # clear of the yellow: the filament is the spike at u=0.21 and the transition does
    # not begin until u=0.46, so nothing stains the pennant. Note the matched `span` and
    # `rake` spikes at that same u, which are what make the filament; moving either one
    # without the other unhooks the banner from its own base.
    dorsal=Fin(t0=0.16, t1=0.92,
               span=[(0.00, 0.004), (0.08, 0.010), (0.16, 0.028), (0.21, 0.074),
                     (0.26, 0.029), (0.34, 0.021), (0.50, 0.026), (0.72, 0.023),
                     (0.90, 0.013), (1.00, 0.004)],
               rake=[(0.00, 0.002), (0.14, 0.004), (0.21, 0.155), (0.29, 0.010),
                     (1.00, 0.004)],
               sink=0.16, samples_u=64, samples_v=12,
               style=dict(opacity=0.96,
                          along_colors=[(0.00, _FIN_WHITE, _FIN_WHITE_TIP),
                                        (0.46, _FIN_WHITE, _FIN_WHITE_TIP),
                                        (0.56, _YELLOW, _YELLOW_TIP),
                                        (1.00, _YELLOW, _YELLOW_TIP)])),
    anal=Fin(t0=0.50, t1=0.90,
             span=[(0.00, 0.004), (0.22, 0.0175), (0.55, 0.0215), (0.85, 0.0140),
                   (1.00, 0.0035)],
             rake=0.003, sink=0.18, samples_u=22),
    pectoral=Fin(t0=0.27, t1=0.40,
                 span=[(0.0, 0.0045), (0.45, 0.0150), (1.0, 0.0045)],
                 rake=0.005, curl=0.003, sink=0.28, samples_u=12,
                 color=_YELLOW,
                 style=dict(tip_color=_YELLOW_TIP, opacity=0.90)),
    # Long black pelvics, hanging below the belly under the second black band. They are
    # a big part of this fish's silhouette from the side and their colour is the whole
    # reason they can exist here at all: sharing the white fins' material made them a
    # pale smear against a white belly, so the fin was previously left off entirely.
    pelvic=Fin(t0=0.31, t1=0.44,
               span=[(0.00, 0.0045), (0.40, 0.0235), (1.00, 0.0040)],
               rake=0.007, curl=0.0018, sink=0.34, samples_u=14, samples_v=12,
               color=_INK,
               style=dict(tip_color=(0.05, 0.05, 0.08), opacity=0.97)),
    # Moderately forked.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.0190), (0.30, 0.0145), (0.50, 0.0125),
                     (0.70, 0.0145), (1.0, 0.0190)],
               flare=[(0.0, 0.0), (1.0, 0.0240)],
               rake=0.0015, samples_u=24, samples_v=14),
    caudal_spread=0.85,
    eye=(0.115, 0.60, 0.042),
)
