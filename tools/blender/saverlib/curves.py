"""Shape-defining curves for parametric organic models.

Body and fin outlines are specified as a handful of control points and interpolated.
The interpolant is monotone cubic (Fritsch-Carlson PCHIP) rather than Catmull-Rom
because these curves are almost always half-widths and half-heights: a spline that
overshoots between control points produces a negative radius and an inside-out mesh.
PCHIP cannot overshoot.
"""

from math import cos, sin, copysign, pi


class Profile:
    """A 1-D curve through control points, evaluated by monotone cubic interpolation."""

    def __init__(self, points):
        pts = sorted(points, key=lambda p: p[0])
        if len(pts) < 2:
            raise ValueError("a Profile needs at least two control points")
        self.xs = [float(p[0]) for p in pts]
        self.ys = [float(p[1]) for p in pts]
        self._slopes = _pchip_slopes(self.xs, self.ys)

    def __call__(self, x):
        xs, ys, m = self.xs, self.ys, self._slopes
        if x <= xs[0]:
            return ys[0]
        if x >= xs[-1]:
            return ys[-1]

        i = _bracket(xs, x)
        h = xs[i + 1] - xs[i]
        t = (x - xs[i]) / h
        t2 = t * t
        t3 = t2 * t

        # Hermite basis
        h00 = 2 * t3 - 3 * t2 + 1
        h10 = t3 - 2 * t2 + t
        h01 = -2 * t3 + 3 * t2
        h11 = t3 - t2
        return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]

    def scaled(self, factor):
        return Profile([(x, y * factor) for x, y in zip(self.xs, self.ys)])

    @property
    def peak(self):
        return max(self.ys)


def as_profile(value):
    """Accept a Profile, a control-point list, or a constant."""
    if isinstance(value, Profile):
        return value
    if isinstance(value, (int, float)):
        return Profile([(0.0, float(value)), (1.0, float(value))])
    return Profile(value)


def _bracket(xs, x):
    lo, hi = 0, len(xs) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if xs[mid] > x:
            hi = mid
        else:
            lo = mid
    return lo


def _pchip_slopes(xs, ys):
    n = len(xs)
    h = [xs[i + 1] - xs[i] for i in range(n - 1)]
    delta = [(ys[i + 1] - ys[i]) / h[i] for i in range(n - 1)]

    m = [0.0] * n
    m[0] = delta[0]
    m[-1] = delta[-1]
    for i in range(1, n - 1):
        if delta[i - 1] * delta[i] <= 0.0:
            # Local extremum: flatten so the curve cannot overshoot past it.
            m[i] = 0.0
        else:
            w1 = 2 * h[i] + h[i - 1]
            w2 = h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
    return m


def superellipse(theta, half_width, half_up, half_down, exponent=2.4):
    """A cross-section point at angle `theta`, with independent up/down radii.

    `exponent` = 2 is a plain ellipse. Fish are laterally compressed with noticeably
    flat flanks, which a higher exponent captures; 2.2-2.8 is the useful range.
    Above ~4 the section reads as a rectangle and catches light wrongly.
    """
    c, s = cos(theta), sin(theta)
    e = 2.0 / exponent
    y = half_width * copysign(abs(c) ** e, c)
    half_vertical = half_up if s >= 0.0 else half_down
    z = half_vertical * copysign(abs(s) ** e, s)
    return y, z


def ring_angles(segments):
    """Cross-section angles, starting at the flank so seams land where they show least."""
    return [2.0 * pi * i / segments for i in range(segments)]


def smoothstep(edge0, edge1, x):
    if edge1 == edge0:
        return 0.0 if x < edge0 else 1.0
    t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)
