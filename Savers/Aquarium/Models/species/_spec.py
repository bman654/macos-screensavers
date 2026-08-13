"""The data shape a species is described in.

Each species is pure data: profile control points in metres, colours in linear RGB, and
fin placements expressed as ranges of `t` along the body. Adding a species means adding
numbers, not writing modelling code.

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
        stripes=None,
        stripe_color=(0.95, 0.95, 0.93),
        stripe_softness=0.015,
        diagonal_stripes=None,
        spots=None,
        patches=None,
        split=None,
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
        fin_style=None,
        caudal_style=None,
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
        self.bands = bands                    # [(center, half_width[, color])] in t
        self.band_color = band_color
        self.band_softness = band_softness
        self.outline_color = outline_color
        self.outline_width = outline_width
        # Markings beyond bands. Every one of these is off unless a species asks for it,
        # and each is placed explicitly rather than by tuning a repeat frequency; see
        # saverlib.materials.fish_material for the parameters each one takes.
        self.stripes = stripes                # [(height, half_width[, color])], 0=belly
        self.stripe_color = stripe_color
        self.stripe_softness = stripe_softness
        self.diagonal_stripes = diagonal_stripes  # dict or [dict]: angle/spacing/colour
        self.spots = spots                    # dict or [dict]: count/size/colour
        self.patches = patches                # [dict]: centre/radii/colour in metres
        self.split = split                    # dict: t/colour/hardness
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
        # Extra keyword arguments for `fin_material`: tip_color, edge_color, edge_width,
        # opacity, spots. The tail inherits the body fins' styling unless it asks for
        # its own, since a fish whose fins are edged usually has an edged tail too.
        self.fin_style = fin_style
        self.caudal_style = fin_style if caudal_style is None else caudal_style
        self.eye = eye                        # (t, height 0=flank 1=spine, radius/length)
        self.eye_ring = eye_ring
