"""Species definitions for the aquarium.

Each entry is pure data: profile control points in metres, colours in linear RGB, and
fin placements expressed as ranges of `t` along the body. Adding a species means adding
numbers here, not writing modelling code.

Profile control points are (t, half-extent) with t=0 at the nose and t=1 at the tail
base. Markings are placed explicitly in the same t coordinate. Where a value looks
arbitrary it was arrived at by rendering and adjusting.
"""


class Fin:
    def __init__(self, t0, t1, span, rake=0.0, curl=0.0, flare=0.0, sink=0.15,
                 samples_u=18, samples_v=10):
        self.t0 = t0
        self.t1 = t1
        self.span = span
        self.rake = rake
        self.curl = curl
        self.flare = flare
        self.sink = sink
        self.samples_u = samples_u
        self.samples_v = samples_v


class Species:
    def __init__(
        self,
        name,
        length,
        width,
        top,
        bottom,
        colors,
        fin_color,
        spine=0.0,
        exponent=2.4,
        bands=None,
        band_color=(0.95, 0.95, 0.93),
        band_softness=0.012,
        outline_color=(0.03, 0.02, 0.02),
        outline_width=0.018,
        mouth=None,
        scale_count=55.0,
        scale_depth=0.3,
        dorsal=None,
        anal=None,
        pectoral=None,
        pelvic=None,
        caudal=None,
        caudal_spread=0.85,
        caudal_color=None,
        eye=(0.13, 0.55, 0.055),
        eye_ring=None,
    ):
        self.name = name
        self.length = length
        self.width = width
        self.top = top
        self.bottom = bottom
        self.spine = spine
        self.exponent = exponent
        self.colors = colors                  # (belly, mid, back)
        self.fin_color = fin_color
        self.bands = bands                    # [(center, half_width)] in t
        self.band_color = band_color
        self.band_softness = band_softness
        self.outline_color = outline_color
        self.outline_width = outline_width
        self.mouth = mouth                    # ((cx, cy, cz), (rx, ry, rz)) in metres
        self.scale_count = scale_count
        self.scale_depth = scale_depth
        self.dorsal = dorsal
        self.anal = anal
        self.pectoral = pectoral
        self.pelvic = pelvic
        self.caudal = caudal
        self.caudal_spread = caudal_spread
        self.caudal_color = caudal_color or fin_color
        self.eye = eye                        # (t, height 0=flank 1=spine, radius/length)
        self.eye_ring = eye_ring


CLOWNFISH = Species(
    name="clownfish",
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


BLUE_TANG = Species(
    name="blue_tang",
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
    colors=((0.10, 0.35, 0.88), (0.06, 0.24, 0.78), (0.02, 0.09, 0.42)),
    fin_color=(0.06, 0.20, 0.62),
    caudal_color=(0.98, 0.76, 0.04),
    bands=[(0.86, 0.030)],
    band_color=(0.02, 0.02, 0.04),
    outline_width=0.0,
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


CATALOG = {s.name: s for s in (CLOWNFISH, BLUE_TANG)}
