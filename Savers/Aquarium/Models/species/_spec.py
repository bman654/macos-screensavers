"""The data shape a species is described in.

Each species is pure data: profile control points in metres, colours in linear RGB, and
fin placements expressed as ranges of `t` along the body. Adding a species means adding
numbers, not writing modelling code.

Profile control points are (t, half-extent) with t=0 at the nose and t=1 at the tail
base. Markings are placed explicitly in the same t coordinate. Where a value looks
arbitrary it was arrived at by rendering and adjusting.
"""


class Fin:
    """One fin's shape, and optionally its own colour and styling.

    Shape is `span`/`rake`/`curl`/`flare` over u along the root; see
    `saverlib.fins.build_fin`, which documents which of them actually controls what on a
    short root.

    `color` and `style` override the species-level `fin_color`/`fin_style` — or
    `caudal_color`/`caudal_style` for the caudal — for this fin alone. Both default to
    the species value, and `style` **replaces** it rather than merging into it, the same
    way `caudal_style` always has: a fin that names a style states the whole style, so
    reading a species file never means holding two dicts in your head at once.

    This exists because fins are not interchangeable. A bannerfish's rear dorsal is
    yellow while its banner is white, a flame angelfish's pectorals stay orange while
    its dorsal and anal go purple-black, and a damselfish's pectorals are nearly clear
    while nothing else is. Every one of those is one fin differing from its neighbours.

    Fins sharing a colour and style share one material, so giving four fins the same
    override still costs one `fin_material`.
    """

    def __init__(self, t0, t1, span, rake=0.0, curl=0.0, flare=0.0, sink=0.15,
                 samples_u=18, samples_v=10, color=None, style=None):
        self.t0 = t0
        self.t1 = t1
        self.span = span
        self.rake = rake
        self.curl = curl
        self.flare = flare
        self.sink = sink
        self.samples_u = samples_u
        self.samples_v = samples_v
        self.color = color
        self.style = style


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
        mouth_color=(0.10, 0.035, 0.025),
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
        # The mouth's own colour. The default is a dark red gape, which is right on a
        # clownfish and wrong on anything whose lips are pale or whose skin is not warm:
        # left unsettable it rendered as a pink smear on an emperor angelfish and on a
        # moray, and both were driven to cover it with a `patches` entry instead.
        self.mouth_color = mouth_color
        self.scale_count = scale_count
        self.scale_depth = scale_depth
        self.dorsal = dorsal
        self.anal = anal
        self.pectoral = pectoral
        self.pelvic = pelvic
        self.caudal = caudal
        self.caudal_spread = caudal_spread
        self.caudal_color = caudal_color or fin_color
        # Extra keyword arguments for `fin_material`: tip_color, along_colors,
        # edge_color, edge_width, opacity, spots, ray_count, ray_contrast. The tail
        # inherits the body fins' styling unless it asks for its own, since a fish whose
        # fins are edged usually has an edged tail too. Either can be overridden on a
        # single fin with `Fin(color=..., style=...)`.
        self.fin_style = fin_style
        self.caudal_style = fin_style if caudal_style is None else caudal_style
        self.eye = eye                        # (t, height 0=flank 1=spine, radius/length)
        # A ring of skin round the eye socket: an RGB colour, or a dict adding `width`
        # (ring thickness as a fraction of the eye's radius, default 0.55) and
        # `softness`. Its position and size come from `eye` — a species never restates
        # them. Off unless asked for.
        self.eye_ring = eye_ring
