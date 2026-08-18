"""The data shape a species is described in.

Each species is pure data: profile control points in metres, colours in linear RGB, and
fin placements expressed as ranges of `t` along the body. Adding a species means adding
numbers, not writing modelling code.

Profile control points are (t, half-extent) with t=0 at the nose and t=1 at the tail
base. Markings are placed explicitly in the same t coordinate. Where a value looks
arbitrary it was arrived at by rendering and adjusting.

**A body is stated one of two ways, and every species picks exactly one.** The usual one
is `width`/`top`/`bottom` lofted along a straight X axis, which suits any animal whose
outline is a depth above and below a straight backbone. The other is `path`/`radius`
swept along a curve, for an animal that doubles back on itself — a seahorse's head is
bent to a right angle and its tail curls through more than a full turn, neither of which
is a function of a monotone X. `t` then runs along the path's arc length rather than
along X, and markings placed by X stop meaning what they say; `saverlib.curved` spells
out which ones. Stating both or neither is an error rather than a precedence rule,
because the two describe the same thing and a species that gave both would be saying
something contradictory.

The numbers here are the animal's *shape*. How it moves is `pose`, `swim` and
`fin_rate` at the bottom, which the runtime reads out of the manifest — those three are
the difference between a fish and an animal that stands upright, holds its body rigid
and drives itself with one fin.

`colorways` is the one field that makes a species more than one animal on screen. A wild
seahorse's colour is a fact about the weed it is holding on to rather than about its
species — the same *Hippocampus kuda* is honey, lemon, cream or near-black — so one of
them in a tank is a lie the moment there are two. A colourway names a repaint: only the
colour fields differ, so every scheme shares one mesh and one normal map and costs a
single extra base-colour image. `Species.colorway(name)` hands back the repainted animal
as an ordinary `Species`, which is why nothing downstream of here knows about any of it.
"""

import copy


# Which fields a colourway may repaint. Everything here is skin, fin or marking colour;
# nothing here is shape. That line is the whole point of the list: two colourways of one
# animal have to be the same animal, or the mesh baked once and shared between them would
# be wrong for all but the first.
_COLORWAY_FIELDS = frozenset({
    "colors", "fin_color", "caudal_color", "fin_style", "caudal_style",
    "bands", "band_color", "outline_color", "stripes", "stripe_color",
    "diagonal_stripes", "spots", "patches", "rings", "split",
    "mouth_color", "eye_ring",
})


def _colour_leaves_only(base, painted, where):
    """Check that `painted` differs from `base` only under keys that name a colour.

    Naming a colour field is not enough on its own, because the colour fields are compound:
    `rings` also carries how deep its grooves cut, `spots` how many there are and how big,
    `patches` where they sit. Only the base-colour atlas is rebaked per scheme — the normal
    map, the roughness map and the mesh are the default's — so a scheme that quietly moved
    a saddle or deepened a ring would ship a colour that no longer lines up with the relief
    underneath it, and would render perfectly.
    """
    if isinstance(base, dict) and isinstance(painted, dict):
        for key in sorted(set(base) | set(painted)):
            if "color" in key:
                continue
            if key not in base or key not in painted:
                raise ValueError(
                    f"{where}: a colourway may not add or drop {key!r}; only colour differs"
                )
            _colour_leaves_only(base[key], painted[key], f"{where}.{key}")
        return
    if isinstance(base, (list, tuple)) and isinstance(painted, (list, tuple)):
        if len(base) != len(painted):
            raise ValueError(
                f"{where}: a colourway may not change how many entries there are "
                f"({len(base)} to {len(painted)}); only colour differs"
            )
        for index, (one, other) in enumerate(zip(base, painted)):
            _colour_leaves_only(one, other, f"{where}[{index}]")
        return
    if base != painted:
        raise ValueError(
            f"{where}: {base!r} became {painted!r}, and that is not a colour. Every scheme "
            f"shares one mesh and one normal map, so anything but colour would be wrong "
            f"for all of them but the one the model was baked from."
        )


def _checked_colorways(colorways, species):
    """Validate `Species.colorways` at construction, where the name is still to hand."""
    if not colorways:
        return {}
    checked = {}
    for name, overrides in colorways.items():
        if not isinstance(overrides, dict):
            raise ValueError(f"colourway {name!r} must be a dict of field overrides")
        unknown = sorted(set(overrides) - _COLORWAY_FIELDS)
        if unknown:
            raise ValueError(
                f"colourway {name!r} would change {unknown}, which is not colour. A "
                f"colourway may only repaint {sorted(_COLORWAY_FIELDS)}."
            )
        for field, value in overrides.items():
            base = getattr(species, field)
            if base is None and value is not None:
                raise ValueError(
                    f"colourway {name!r} adds {field!r}, which the species does not have. "
                    f"A marking that only some schemes carry is a difference in the mesh's "
                    f"relief, not in its colour."
                )
            if "color" not in field:
                _colour_leaves_only(base, value, f"colourway {name!r}: {field}")
        checked[str(name)] = dict(overrides)
    return checked


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
                 samples_u=18, samples_v=10, color=None, style=None, ripples=False):
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
        # Whether this fin undulates on its own, rather than only riding the body's
        # wave. Only the dorsal honours it, and only one species asks: a seahorse does
        # not swim with its body at all, so its dorsal fin is the whole of its
        # propulsion and has to be seen to beat. See `_RIPPLE_ID` in `build_fish.py`.
        self.ripples = ripples


class Species:
    def __init__(
        self,
        name,
        length,
        colors,
        fin_color,
        width=None,
        top=None,
        bottom=None,
        path=None,
        radius=None,
        section=(1.0, 1.0),
        body_up=(0.0, -1.0, 0.0),
        dorsal_at=0.5,
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
        rings=None,
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
        body_length_m=0.15,
        school=(1, 3),
        depth_band=(0.0, 1.0),
        weight=1.0,
        pose="level",
        swim=1.0,
        fin_rate=1.0,
        colorways=None,
    ):
        lofted = width is not None and top is not None and bottom is not None
        swept = path is not None and radius is not None
        if lofted == swept:
            raise ValueError(
                "a species states its body either as width/top/bottom lofted along X, or "
                "as path/radius swept along a curve — not both and not neither"
            )
        if body_length_m <= 0.0:
            raise ValueError("body_length_m must be positive")
        if (len(school) != 2 or not all(isinstance(value, int) for value in school)
                or school[0] < 1 or school[1] < school[0]):
            raise ValueError("school must be two integers with 1 <= min <= max")
        if (len(depth_band) != 2 or not 0.0 <= depth_band[0] <= depth_band[1] <= 1.0):
            raise ValueError("depth_band must satisfy 0 <= near <= far <= 1")
        if weight <= 0.0:
            raise ValueError("weight must be positive")
        if pose not in {"level", "upright"}:
            raise ValueError("pose must be 'level' or 'upright'")
        if swim < 0.0:
            raise ValueError("swim must be non-negative")
        if fin_rate <= 0.0:
            raise ValueError("fin_rate must be positive")

        self.name = name
        self.length = length
        # A curled animal cannot be described as a depth above and below a straight
        # backbone — see `saverlib.curved`. `is_swept` is what `build_fish` branches on,
        # and it is derived rather than declared so the two halves cannot disagree.
        self.is_swept = swept
        self.path = path
        self.radius = radius
        self.section = section
        self.body_up = body_up
        self.dorsal_at = dorsal_at
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
        # A plated animal's bony rings, ridges and tubercles. Unlike every other marking
        # this one is placed in the body's own (along, around) coordinate rather than in
        # object space, so it is available only to a swept body — which is checked here
        # rather than rendering as a stripeless animal with no explanation.
        if rings is not None and not swept:
            raise ValueError(
                "rings are placed along the body's own swept coordinate, which only a "
                "path/radius body writes; a lofted body has no such coordinate"
            )
        self.rings = rings                    # dict: count/spacing/ridges/depth/colour
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
        self._caudal_inherits_color = caudal_color is None
        # Extra keyword arguments for `fin_material`: tip_color, along_colors,
        # edge_color, edge_width, opacity, spots, ray_count, ray_contrast. The tail
        # inherits the body fins' styling unless it asks for its own, since a fish whose
        # fins are edged usually has an edged tail too. Either can be overridden on a
        # single fin with `Fin(color=..., style=...)`.
        self.fin_style = fin_style
        self.caudal_style = fin_style if caudal_style is None else caudal_style
        self._caudal_inherits_style = caudal_style is None
        self.eye = eye                        # (t, height 0=flank 1=spine, radius/length)
        # A ring of skin round the eye socket: an RGB colour, or a dict adding `width`
        # (ring thickness as a fraction of the eye's radius, default 0.55) and
        # `softness`. Its position and size come from `eye` — a species never restates
        # them. Off unless asked for.
        self.eye_ring = eye_ring
        # Nominal adult size for population art direction, not model-space geometry.
        self.body_length_m = body_length_m
        self.school = tuple(school)             # inclusive individuals per populated group
        self.depth_band = tuple(depth_band)     # near/far fractions of the tank depth
        self.weight = weight                    # bias in the random species draw
        self.pose = pose
        self.swim = swim
        self.fin_rate = fin_rate
        # Last, because a colourway is checked against the values it is repainting.
        self.colorways = _checked_colorways(colorways, self)

    def colorway(self, name):
        """This species repainted, as a species in its own right.

        A colourway states only the fields it changes, so a scheme reads as the handful
        of colours that differ rather than as a second copy of the animal — and a change
        to the shape reaches every scheme without being restated. The result is a real
        `Species`, so everything downstream of here is unaware that colourways exist.
        """
        if name not in self.colorways:
            raise KeyError(
                f"{self.name} has no colourway {name!r}; it has "
                f"{sorted(self.colorways) or 'none'}"
            )
        painted = copy.copy(self)
        for field, value in self.colorways[name].items():
            setattr(painted, field, value)
        # The caudal's colour and style were resolved from the body fins' at construction
        # if they were not stated, and a repaint of `fin_color` has to carry them with it —
        # otherwise a blue fish keeps a red tail and nothing says why.
        if self._caudal_inherits_color:
            painted.caudal_color = painted.fin_color
        if self._caudal_inherits_style:
            painted.caudal_style = painted.fin_style
        # A repaint is one look of one animal, not a species of its own: leaving the
        # colourways on the copy would let `colorway()` be called on a result and quietly
        # compose two schemes.
        painted.colorways = {}
        return painted

    def manifest(self, asset):
        """The JSON the runtime reads for sizing, population, and species-specific motion.

        Motion keys are omitted at their defaults. This keeps every existing manifest stable
        while an older runtime naturally gets the same level pose and normal animation rates.
        """
        fish = {
            "bodyLength": self.body_length_m,
            "school": list(self.school),
            "depthBand": list(self.depth_band),
            "weight": self.weight,
        }
        if self.pose != "level":
            fish["pose"] = self.pose
        if self.swim != 1.0:
            fish["swim"] = self.swim
        if self.fin_rate != 1.0:
            fish["finRate"] = self.fin_rate
        if self.colorways:
            # The runtime picks one of these per individual and swaps in the base-colour
            # atlas baked for it; the first is the one already inside the `.usdz`, so a
            # runtime that ignores the key still draws a fish that was actually authored.
            fish["colorways"] = list(self.colorways)
        return {
            "name": self.name,
            "asset": asset,
            "category": "fish",
            "fish": fish,
        }
