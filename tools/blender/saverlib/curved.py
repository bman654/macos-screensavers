"""A body whose axis is a curve in space rather than a straight line along X.

`Body` lofts cross-sections along X and offsets them in Z, which covers every animal whose
outline can be drawn as a depth above and below a straight backbone — which is every fish
in the library but one. It cannot describe an animal that doubles back on itself: X is
strictly decreasing in `t` there, so a head bent to a right angle shears instead of
bending, and a tail that curls through a full turn cannot be stated at all.

A seahorse is both of those at once, so it is lofted along a path. The sweep itself is not
new — `SweptTube` already carries a superelliptical section along an arbitrary curve on a
parallel-transported frame, which is exactly the operation wanted — so this is an adapter
rather than a second modelling implementation: it presents the handful of queries `Body`
offers, so fins, eyes and the skin material attach to a curved body without any of them
knowing which kind of body they are on.

**What a curved body gives up.** Markings placed by nose-to-tail position — `bands`,
`stripes`, and anything using a marking's `t_range` — are measured from the object's X
coordinate, and on a curled body X is not a position along the animal. Those are silently
wrong here rather than refused, because the marking code has no way to know. Use `spots`
and `patches`, which are placed in object space and stay correct.
"""

from math import pi

from mathutils import Vector

from .curves import as_profile
from .tube import SweptTube


class CurvedBodySpec:
    """Parameters defining a body lofted along a path. Lengths are in metres.

    `path` is anything `SweptTube` accepts — a callable over 0..1 or a sequence of points —
    running from the nose to the tail tip. `radius` is the half-thickness along it, and
    `section` scales that independently across the body and through its depth, so a flank
    that is flatter than it is deep is a section rather than a second radius profile.

    `up` seeds the parallel-transported frame, and it is a real choice rather than a
    default worth taking on trust: it decides which way round the section's "up" ends up
    pointing, and the wrong one attaches the dorsal fin to the belly. `dorsal_at` names a
    `t` where the answer is obvious — anywhere along a straight stretch of back — and
    `CurvedBody` checks it there rather than letting it be discovered in a render.
    """

    def __init__(self, path, radius, section=(1.0, 1.0), exponent=2.4,
                 up=(0.0, -1.0, 0.0), dorsal_at=0.5, samples=400):
        self.path = path
        self.radius = as_profile(radius)
        self.section = (as_profile(section[0]), as_profile(section[1]))
        self.exponent = as_profile(exponent)
        self.up = tuple(up)
        self.dorsal_at = float(dorsal_at)
        self.samples = int(samples)


class CurvedBody:
    """A body swept along `spec.path`, answering the queries a fin root asks of a `Body`."""

    def __init__(self, spec, rings=80, segments=32):
        self.spec = spec
        self.tube = SweptTube(
            spec.path,
            spec.radius,
            rings=rings,
            segments=segments,
            section=spec.section,
            exponent=spec.exponent,
            rounded_caps=True,
            up=spec.up,
            sample_count=spec.samples,
        )

        # The section's "up" is the frame's binormal, and which way it points falls out of
        # the whole transported path rather than out of `up` alone. Getting it wrong puts
        # the dorsal fin on the belly and the eyes under the chin, and both render
        # perfectly — so it is checked here, against the one place the answer is known.
        binormal = self.tube.frame(spec.dorsal_at)[1]
        if binormal.z <= 0.0:
            raise ValueError(
                f"the section's up points away from +Z at t={spec.dorsal_at} "
                f"(binormal {tuple(round(v, 3) for v in binormal)}); the dorsal fin would "
                "attach to the belly. Negate CurvedBodySpec.up."
            )

    # -- surface queries, in object space -------------------------------------------

    def x(self, t):
        return self.tube.point(t).x

    def axis_point(self, t):
        return self.tube.point(t)

    def surface_point(self, t, theta):
        return self.tube.surface_point(t, theta)

    # -- mesh construction ----------------------------------------------------------

    def build(self, name="Body", subsurf=1):
        return self.tube.build(name, subsurf=subsurf)

    def bounds(self):
        """World-axis extents of the swept surface, sampled around every ring.

        `build_fish` needs a length and a depth for the skin material's countershading,
        and on a curved body neither is any single profile's peak — the animal's extent in
        X is a fact about the path, not about `radius`.
        """
        low = Vector((1e9, 1e9, 1e9))
        high = Vector((-1e9, -1e9, -1e9))
        for i in range(self.tube.rings):
            t = i / (self.tube.rings - 1)
            for j in range(12):
                point = self.surface_point(t, 2.0 * pi * j / 12)
                low = Vector((min(low.x, point.x), min(low.y, point.y),
                              min(low.z, point.z)))
                high = Vector((max(high.x, point.x), max(high.y, point.y),
                               max(high.z, point.z)))
        return low, high
