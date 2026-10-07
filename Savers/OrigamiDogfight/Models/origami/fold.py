"""Fold a rectangular sheet of paper the way a hand folds it.

A paper plane is not modelled here; it is *folded*. A `Sheet` starts as one flat rectangle
and is cut into facets by every crease it receives. Each facet remembers two polygons:
where it lies now, and where it came from on the flat sheet. Folding moves the first and
never touches the second, so the sheet coordinates of every corner of the finished plane
are known exactly, and they are the plane's UVs. A lined-paper texture then runs across
the folds the way the rules on a real folded sheet do, with no unwrapping step that could
get it wrong.

The work happens in two stages, which is how planes are folded too:

1. **Flat folds** (`fold`, `crease`) while the paper lies on the table. A fold reflects
   everything on one side of a crease line across it, valley (onto the top) or mountain
   (underneath), and records the stacking order. Every crease splits the facets it crosses,
   so a facet is always a convex piece of paper that lies entirely on one side of every
   crease it has met.
2. **Opening** (`lift`, then `rotate`). The stack is given its real thickness, then hinged
   in 3D about crease lines: the keel halves up, the wings back out, the winglets up.
   Hinges are applied leaf first, each about its axis in the flat frame, which is exactly
   forward kinematics from the rest pose.

Coordinates are metres. The flat frame is the sheet lying face up: x across the width,
y along the length with the nose toward +y, z up out of the table.
"""

import math

_TOLERANCE = 1e-9   # metres; a vertex this close to a crease is on it
_MIN_AREA = 1e-10   # square metres; a sliver smaller than this is discarded


def _area(points):
    total = 0.0
    for i, (x0, y0) in enumerate(points):
        x1, y1 = points[(i + 1) % len(points)]
        total += x0 * y1 - x1 * y0
    return total * 0.5


def _lerp(a, b, t):
    return tuple(p + (q - p) * t for p, q in zip(a, b))


def rotate_point(point, a, b, degrees):
    """`point` (x, y, z) turned right-handedly about the axis a->b, which lies in z = 0."""
    ax, ay = a
    ux, uy = b[0] - ax, b[1] - ay
    length = math.hypot(ux, uy)
    ux, uy = ux / length, uy / length
    c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
    px, py, pz = point[0] - ax, point[1] - ay, point[2]
    # Rodrigues, with the axis k = (ux, uy, 0): p c + (k x p) s + k (k . p)(1 - c).
    dot = px * ux + py * uy
    cx, cy, cz = uy * pz, -ux * pz, ux * py - uy * px
    return (
        ax + px * c + cx * s + ux * dot * (1 - c),
        ay + py * c + cy * s + uy * dot * (1 - c),
        pz * c + cz * s,
    )


class Line:
    """A directed crease line through `a` and `b`, with a chosen inside.

    `inside` is any point strictly on the side that counts as inside — for a fold, a point
    on the paper that moves. Naming a point rather than a direction is deliberate: "the
    corner at (0, H) folds" cannot be got backwards, whereas a sign convention can.
    """

    def __init__(self, a, b, inside):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        if length < 1e-12:
            raise ValueError("a crease needs two distinct points")
        self.a = a
        self.dx, self.dy = dx / length, dy / length
        raw = self._raw(inside)
        if abs(raw) < 1e-12:
            raise ValueError(f"inside point {inside} lies on the crease {a}->{b}")
        self.sign = 1.0 if raw > 0 else -1.0

    def _raw(self, p):
        return self.dx * (p[1] - self.a[1]) - self.dy * (p[0] - self.a[0])

    def distance(self, p):
        """Signed distance, positive inside."""
        return self.sign * self._raw(p)

    def reflect(self, p):
        px, py = p[0] - self.a[0], p[1] - self.a[1]
        along = px * self.dx + py * self.dy
        return (self.a[0] + 2.0 * along * self.dx - px,
                self.a[1] + 2.0 * along * self.dy - py)


class Facet:
    """A convex piece of the sheet: where it is now (`flat`, later `points`) and where it
    came from (`sheet`), corner for corner."""

    __slots__ = ("flat", "sheet", "layer", "points", "centroid")

    def __init__(self, flat, sheet, layer):
        self.flat = flat
        self.sheet = sheet
        self.layer = layer
        self.points = None
        self.centroid = None


def _split(facet, line):
    """(inside piece, outside piece); either may be None."""
    d = [line.distance(p) for p in facet.flat]
    if all(v >= -_TOLERANCE for v in d):
        return facet, None
    if all(v <= _TOLERANCE for v in d):
        return None, facet
    inside, outside = [], []
    count = len(d)
    for i in range(count):
        j = (i + 1) % count
        corner = (facet.flat[i], facet.sheet[i])
        if d[i] >= -_TOLERANCE:
            inside.append(corner)
        if d[i] <= _TOLERANCE:
            outside.append(corner)
        if (d[i] > _TOLERANCE and d[j] < -_TOLERANCE) or (d[i] < -_TOLERANCE and d[j] > _TOLERANCE):
            t = d[i] / (d[i] - d[j])
            cut = (_lerp(facet.flat[i], facet.flat[j], t), _lerp(facet.sheet[i], facet.sheet[j], t))
            inside.append(cut)
            outside.append(cut)

    def piece(corners):
        flat = [c[0] for c in corners]
        if len(flat) < 3 or abs(_area(flat)) < _MIN_AREA:
            return None
        return Facet(flat, [c[1] for c in corners], facet.layer)

    return piece(inside), piece(outside)


def _overlap(p, q, tolerance=1e-7):
    """Do two convex polygons share area (not merely an edge)? Separating axis test."""
    for poly in (p, q):
        for i in range(len(poly)):
            x0, y0 = poly[i]
            x1, y1 = poly[(i + 1) % len(poly)]
            nx, ny = y0 - y1, x1 - x0
            length = math.hypot(nx, ny)
            if length < 1e-15:
                continue
            nx, ny = nx / length, ny / length
            a = [x * nx + y * ny for x, y in p]
            b = [x * nx + y * ny for x, y in q]
            if max(a) <= min(b) + tolerance or max(b) <= min(a) + tolerance:
                return False
    return True


class Sheet:
    def __init__(self, width, height):
        self.width = width
        self.height = height
        corners = [(0.0, 0.0), (width, 0.0), (width, height), (0.0, height)]
        self.facets = [Facet(list(corners), list(corners), 0)]
        self.lifted = False

    @property
    def aspect(self):
        return self.height / self.width

    def mirror(self, p):
        """The point's twin across the sheet's long centre line."""
        return (self.width - p[0], p[1])

    # ---- flat stage -------------------------------------------------------------------

    def fold(self, a, b, move, within=(), mountain=False):
        """Fold the paper on `move`'s side of the crease a-b over it.

        Valley folds land on top of everything; mountain folds go underneath. `within`
        narrows what moves to the intersection of further (a, b, inside) half-planes, for a
        fold that only takes part of the paper on that side — the two flaps either side of
        a slit, say. Returns the number of facets that moved, and refuses to move none:
        a fold that misses the paper is a mistake in the numbers, not a no-op.
        """
        self._flat_only()
        crease = Line(a, b, move)
        bounds = [crease] + [Line(*w) for w in within]
        moving, staying = [], []
        for facet in self.facets:
            piece = facet
            for line in bounds:
                piece, rest = _split(piece, line)
                if rest is not None:
                    staying.append(rest)
                if piece is None:
                    break
            if piece is not None:
                moving.append(piece)
        if not moving:
            raise ValueError(f"fold {a}->{b} toward {move} moved no paper")

        everything = moving + staying
        top = max(f.layer for f in everything)
        bottom = min(f.layer for f in everything)
        highest = max(f.layer for f in moving)
        lowest = min(f.layer for f in moving)
        for facet in moving:
            facet.flat = [crease.reflect(p) for p in facet.flat]
            # A fold reverses the order of the layers it carries: what was on top of the
            # flap ends up at the bottom of it.
            if mountain:
                facet.layer = bottom - 1 - (facet.layer - lowest)
            else:
                facet.layer = top + 1 + (highest - facet.layer)
        self.facets = everything
        return len(moving)

    def fold_pair(self, a, b, move, within=(), mountain=False):
        """The same fold on the left, then mirrored onto the right."""
        self.fold(a, b, move, within, mountain)
        self.fold(self.mirror(a), self.mirror(b), self.mirror(move),
                  [tuple(self.mirror(p) for p in w) for w in within], mountain)

    def crease(self, a, b):
        """Split every facet along the line a-b without moving anything — a crease that a
        later hinge (or nothing at all) will use."""
        self._flat_only()
        dx, dy = b[0] - a[0], b[1] - a[1]
        line = Line(a, b, (a[0] - dy, a[1] + dx))
        pieces = []
        for facet in self.facets:
            inside, outside = _split(facet, line)
            pieces.extend(p for p in (inside, outside) if p is not None)
        self.facets = pieces

    def _flat_only(self):
        if self.lifted:
            raise RuntimeError("the sheet has been lifted; only hinges remain")

    # ---- opening ----------------------------------------------------------------------

    def lift(self, thickness):
        """Give the flat stack real thickness, and freeze the flat frame for selection.

        Layer numbers from folding are only an order — a flap folded last sits above
        everything even where nothing else is under it. Each facet is restacked to sit one
        sheet above the highest facet it actually overlaps, so a flap lies on the paper it
        was folded onto instead of hovering at the height of a stack somewhere else.
        """
        self._flat_only()
        ordered = sorted(self.facets, key=lambda f: f.layer)
        level = {}
        for index, facet in enumerate(ordered):
            below = [level[id(g)] for g in ordered[:index] if _overlap(facet.flat, g.flat)]
            level[id(facet)] = (max(below) + 1) if below else 0
        for facet in self.facets:
            z = level[id(facet)] * thickness
            facet.points = [(x, y, z) for x, y in facet.flat]
            n = len(facet.flat)
            facet.centroid = (sum(p[0] for p in facet.flat) / n, sum(p[1] for p in facet.flat) / n)
        self.lifted = True

    def rotate(self, select, a, b, degrees):
        """Hinge every facet `select` accepts about the axis a->b (flat frame, z = 0).

        Right-handed about a->b. Hinges must be applied leaf first: a wing about its crease
        before the keel half that carries it about the centre line.
        """
        if not self.lifted:
            raise RuntimeError("lift the sheet before hinging it")
        moved = 0
        for facet in self.facets:
            if select(facet):
                moved += 1
                facet.points = [rotate_point(p, a, b, degrees) for p in facet.points]
        if not moved:
            raise ValueError(f"hinge {a}->{b} selected no paper")
        return moved

    def transform(self, function):
        """Apply `function((x, y, z)) -> (x, y, z)` to every lifted point."""
        for facet in self.facets:
            facet.points = [function(p) for p in facet.points]

    def side(self, a, b, inside):
        """A facet selector: the facet's flat-frame centroid lies on `inside`'s side."""
        line = Line(a, b, inside)
        return lambda facet: line.distance(facet.centroid) > 0
