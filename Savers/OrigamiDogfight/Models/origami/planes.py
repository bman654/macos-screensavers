"""The five paper planes, each folded from one sheet of US letter.

Every design is a fold sequence a person could follow, written against the sheet lying face
up with its top edge (the nose) toward +y. The numbers that matter for the game are the
plan-view silhouettes, because the saver looks straight down at 60-120 px per plane:

- dart          long thin triangle, sharp point, straight trailing edge
- interceptor   bare needle for its front half, swept wings behind, a notch in the tail
- stunt         wide true delta, its tips turned up into winglets
- glider        a sailplane cross: blunt rolled nose, wide straight wing, boom, tailplane
- bomber        squat blunt wedge: a flat hammer nose, chamfered shoulders, stubby flared wings

Every plane is one mesh with one material, `paper`, and the sheet's own coordinates as its
UVs (see `fold.py`). The runtime replaces the material, so its colour here only matters for
the studio renders.
"""

import math

from ._spec import Model
from .fold import Sheet, rotate_point
from .mesh import flat_material, mesh_object, polygon_normal

LETTER = (0.2159, 0.2794)   # width, height in metres
# Thicker than real paper (0.1 mm), so stacked layers stay apart in a depth buffer at
# whatever scale the saver draws them. Half a millimetre on a 28 cm plane is invisible.
THICKNESS = 0.0004


def _tan(degrees):
    return math.tan(math.radians(degrees))


def _noseward(a, b):
    return (a, b) if a[1] <= b[1] else (b, a)


def _open(sheet, wing, dihedral, splay, winglet=None, winglet_angle=0.0):
    """Fold the sheet in half along its centre line and open it into a plane.

    `wing` is the left wing crease (the right is its mirror); paper outboard of it is wing,
    paper between it and the centre line is keel. `splay` opens the keel into a V, so its
    two halves are not coplanar; `dihedral` lifts each wing above horizontal. A `winglet`
    crease turns the paper outboard of it up by `winglet_angle` relative to the wing.

    The flaps from the flat stage end up on top of the wings and inside the keel, which is
    how a real plane comes out when it is folded in half with its flaps inside.
    """
    width, height = sheet.width, sheet.height
    centre = width * 0.5
    sheet.crease((centre, 0.0), (centre, height))
    for line in [wing] + ([winglet] if winglet else []):
        sheet.crease(*line)
        sheet.crease(sheet.mirror(line[0]), sheet.mirror(line[1]))
    sheet.lift(THICKNESS)

    keel_axis = ((centre, 0.0), (centre, height))
    for sign, mirror in ((1.0, lambda p: p), (-1.0, sheet.mirror)):
        def in_half(facet, sign=sign):
            return (facet.centroid[0] - centre) * sign < 0

        far = mirror((-1.0, height * 0.5))   # well outboard of any crease on this side
        if winglet:
            a, b = _noseward(mirror(winglet[0]), mirror(winglet[1]))
            outboard = sheet.side(a, b, far)
            sheet.rotate(lambda f, h=in_half, o=outboard: h(f) and o(f), a, b,
                         sign * winglet_angle)
        a, b = _noseward(mirror(wing[0]), mirror(wing[1]))
        outboard = sheet.side(a, b, far)
        sheet.rotate(lambda f, h=in_half, o=outboard: h(f) and o(f), a, b,
                     -sign * (90.0 - splay - dihedral))
        sheet.rotate(in_half, *keel_axis, sign * (90.0 - splay))

    # Level the plane on its wing roots. A keel that deepens toward the tail (the dart's)
    # leaves the root line pitched, and the plane flies with its wings level, not its keel.
    tail, nose = _noseward(*wing)
    tail3 = rotate_point((*tail, 0.0), *keel_axis, 90.0 - splay)
    nose3 = rotate_point((*nose, 0.0), *keel_axis, 90.0 - splay)
    pitch = math.atan2(nose3[2] - tail3[2], nose3[1] - tail3[1])
    c, s = math.cos(-pitch), math.sin(-pitch)
    sheet.transform(lambda p: (p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c))


def _plane_object(name, sheet):
    """The opened sheet as one mesh in Blender's axes, UVs = sheet coordinates.

    Flat frame -> Blender: the nose (+y) becomes +X, the plane's left (-x, seen from above)
    becomes +Y, up stays +Z. Each facet's winding is chosen so its normal faces up, or
    outboard for a near-vertical keel or winglet face: paper is two-sided and the runtime
    draws it so, but a renderer that does not flip back-face normals should still light
    the top of a wing as the top.
    """
    centre = sheet.width * 0.5
    verts, faces, uvs = [], [], []
    for facet in sheet.facets:
        points = [(y, centre - x, z) for x, y, z in facet.points]
        coords = [(sx / sheet.width, sy / sheet.height) for sx, sy in facet.sheet]
        normal = polygon_normal(points)
        middle_y = sum(p[1] for p in points) / len(points)
        if abs(normal.z) >= 0.3:
            backwards = normal.z < 0
        else:
            backwards = normal.y * (1.0 if middle_y >= 0 else -1.0) < 0
        if backwards:
            points.reverse()
            coords.reverse()
        start = len(verts)
        verts.extend(points)
        faces.append(list(range(start, start + len(points))))
        uvs.extend(coords)
    paper = flat_material("paper", "#f2efe6", roughness=0.9)
    return mesh_object(name, verts, faces, [paper], uvs=uvs)


def _plane(name, fold_sequence, summary):
    def build():
        sheet = Sheet(*LETTER)
        fold_sequence(sheet)
        obj = _plane_object(name, sheet)
        return obj, {
            "sheetAspect": round(sheet.aspect, 6),
            "sheet": {"width": sheet.width, "height": sheet.height},
        }

    return Model(name=name, kind="plane", build=build, summary=summary)


# ---- the designs ----------------------------------------------------------------------

def _nose_to_centre(sheet, times):
    """The opening every dart shares: corners to the centre line, then the new edges to
    the centre line again, `times` in all. Each pass halves the nose angle."""
    width, height = sheet.width, sheet.height
    centre = width * 0.5
    sheet.fold_pair((0.0, height - centre), (centre, height), move=(0.0, height))
    half_angle = 45.0
    for _ in range(times - 1):
        half_angle *= 0.5
        reach = centre / _tan(half_angle)
        end = (0.0, height - reach) if reach < height else (centre - height * _tan(half_angle), 0.0)
        sheet.fold_pair((centre, height), end, move=(0.0, height * 0.5))
    return half_angle


def _fold_dart(sheet):
    width, height = sheet.width, sheet.height
    centre = width * 0.5
    edge = _nose_to_centre(sheet, 2)
    # Fold the outer edge down to the keel line: the wing crease bisects the nose angle,
    # so the keel is a long triangle deepest at the tail.
    keel = height * _tan(edge * 0.5)
    _open(sheet, wing=((centre, height), (centre - keel, 0.0)), dihedral=7.0, splay=7.0)


def _fold_interceptor(sheet):
    width, height = sheet.width, sheet.height
    centre = width * 0.5
    edge = _nose_to_centre(sheet, 2)
    # Split tail: a slit up the centre line, and the paper either side of it folded up onto
    # the top along a steep crease, leaving a deep swallow-tail notch in the trailing edge.
    notch_width, notch_depth = 0.045, 0.090
    sheet.fold_pair((centre - notch_width, 0.0), (centre, notch_depth),
                    move=(centre - 0.002, 0.0005),
                    within=[((centre, 0.0), (centre, height), (0.0, 0.0))])
    # The wing crease leaves the outer edge well back from the nose, so the front of the
    # plane is all keel — a bare needle from above — and the wings sweep out behind it.
    leading = height * 0.58
    on_edge = (centre - (height - leading) * _tan(edge), leading)
    _open(sheet, wing=(on_edge, (centre - 0.008, 0.0)), dihedral=4.0, splay=9.0)


def _tuck(sheet, depth, times, y0, y1):
    """Fold both side strips of the band y0..y1 in over themselves, `times` times.

    The band is freed by a slit in from each edge at y0 and y1 (a band at the sheet's own
    edge needs only one): this is the one design here that needs scissors, as paper gliders
    with a tail usually do. Nothing outside the band moves.
    """
    for step in range(1, times + 1):
        line = depth * step
        band = [((0.0, y0), (1.0, y0), (0.0, y1 if y1 > y0 else y0 + 1.0)),
                ((0.0, y1), (1.0, y1), (0.0, y0))]
        sheet.fold_pair((line, 0.0), (line, 1.0), move=(line - depth * 0.5, (y0 + y1) * 0.5),
                        within=band)


def _fold_glider(sheet):
    width, height = sheet.width, sheet.height
    centre = width * 0.5
    # The top edge rolled down three times: a blunt, heavy nose.
    top = height
    roll = 0.016
    for _ in range(3):
        top -= roll
        sheet.fold((0.0, top), (width, top), move=(centre, top + roll * 0.5))
    # Seen from above, a sailplane: a short nose, a wide straight wing, a narrow boom and a
    # tailplane, each band of the sheet tucked in from the sides by a different amount.
    nose, chord, tailplane = 0.046, 0.056, 0.036
    wing_front = top - nose
    wing_back = wing_front - chord
    _tuck(sheet, 0.035, 2, wing_front, top)          # nose
    _tuck(sheet, 0.039, 2, tailplane, wing_back)     # boom
    _tuck(sheet, 0.031, 2, 0.0, tailplane)           # tailplane
    keel = 0.010
    _open(sheet, wing=((centre - keel, 0.0), (centre - keel, top)), dihedral=7.0, splay=6.0)


def _fold_bomber(sheet):
    width, height = sheet.width, sheet.height
    centre = width * 0.5
    sheet.fold_pair((0.0, height - centre), (centre, height), move=(0.0, height))
    # The nose triangle folded straight back down: a flat hammer front the full width.
    top = height - centre
    sheet.fold((0.0, top), (width, top), move=(centre, height))
    # Small shoulders keep the hammer wide: from above the bomber is the one blunt block
    # in the set. Bigger shoulders turn it into a pentagon that the stunt's delta shares.
    shoulder = 0.040
    sheet.fold_pair((0.0, top - shoulder), (shoulder, top), move=(0.001, top - 0.001))
    # A fat keel, deeper at the nose, so the stubby wings flare out toward the tail.
    _open(sheet, wing=((centre - 0.040, top), (centre - 0.018, 0.0)), dihedral=2.0, splay=10.0)


def _fold_stunt(sheet):
    width, height = sheet.width, sheet.height
    centre = width * 0.5
    top = height * 0.5
    sheet.fold((0.0, top), (width, top), move=(centre, height))
    # Each top corner folded down along the line from the apex to the trailing corner, so
    # the leading edges run all the way back to the wing tips: a true delta. The two flaps
    # cross over each other at the centre line, and fold with it.
    sheet.fold_pair((0.0, 0.0), (centre, top), move=(0.0, top))
    # Winglets canted rather than upright: an upright fin is invisible from overhead and
    # clips the delta's tips into a pentagon; canted, the triangle survives and the tips read
    # as differently lit facets with their own shadows.
    keel = 0.010
    tip = 0.040
    _open(sheet, wing=((centre - keel, 0.0), (centre - keel, top)), dihedral=3.0, splay=6.0,
          winglet=((tip, 0.0), (tip, top)), winglet_angle=58.0)


dart = _plane("dart", _fold_dart,
              "The classic dart: nose folded to the centre twice, keel deepest at the tail.")
interceptor = _plane("interceptor", _fold_interceptor,
                     "A needle front of bare keel, swept wings behind, a notched split tail.")
glider = _plane("glider", _fold_glider,
                "A sailplane from above: rolled blunt nose, wide straight wing, boom, tailplane.")
bomber = _plane("bomber", _fold_bomber,
                "Bulldog/hammer nose folded flat, chamfered shoulders, fat keel, stubby wings.")
stunt = _plane("stunt", _fold_stunt,
               "A wide true delta on a half-folded sheet, with upturned winglets.")
