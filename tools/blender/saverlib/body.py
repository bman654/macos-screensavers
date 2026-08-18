"""Lofted body meshes built from cross-section profiles.

A body is described by half-width, half-height-above-spine and half-height-below-spine
as functions of `t`, the normalized distance from nose (t=0) to tail base (t=1). The
mesh is a loft of superelliptical cross-sections through those profiles, capped at both
ends with a pole vertex.

Keeping the profiles queryable after the mesh is built is the point of the `Body` class:
fins have to attach exactly to the surface, and re-deriving the surface position from the
generated mesh would mean searching vertices instead of just evaluating the curve.
"""

import bmesh
import bpy
from math import cos, pi
from mathutils import Vector

from .curves import as_profile, ring_angles, superellipse


class BodySpec:
    """Parameters defining a lofted body. All lengths are in Blender units (metres)."""

    def __init__(
        self,
        length,
        width,
        top,
        bottom,
        spine=0.0,
        exponent=2.4,
    ):
        self.length = float(length)
        self.width = as_profile(width)
        self.top = as_profile(top)
        self.bottom = as_profile(bottom)
        self.spine = as_profile(spine)
        self.exponent = as_profile(exponent)


class Body:
    def __init__(self, spec, rings=80, segments=32):
        self.spec = spec
        self.rings = rings
        self.segments = segments

    # -- surface queries, in object space -------------------------------------------

    def x(self, t):
        """Nose sits at +X/2, tail base at -X/2, so the model straddles the origin."""
        return self.spec.length * (0.5 - t)

    def half_width(self, t):
        return self.spec.width(t)

    def top_z(self, t):
        return self.spec.spine(t) + self.spec.top(t)

    def bottom_z(self, t):
        return self.spec.spine(t) - self.spec.bottom(t)

    def axis_point(self, t):
        """The centreline point a cross-section is built around.

        Named so that a fin root can be written as "the surface, pulled some fraction of
        the way back towards the axis" without knowing which kind of body it is on — see
        `fins.dorsal_root`. For a lofted body the axis is a straight line in X offset by
        `spine`; for a `CurvedBody` it is an arbitrary curve, and that is the whole of the
        difference the fin attachment code has to care about.
        """
        return Vector((self.x(t), 0.0, self.spec.spine(t)))

    def surface_point(self, t, theta):
        y, z = superellipse(
            theta,
            self.spec.width(t),
            self.spec.top(t),
            self.spec.bottom(t),
            self.spec.exponent(t),
        )
        return Vector((self.x(t), y, self.spec.spine(t) + z))

    # -- mesh construction ----------------------------------------------------------

    def _ring_ts(self):
        """Cosine spacing, which concentrates rings at nose and tail.

        Both ends curve hard over a short distance while the midbody is nearly straight,
        so uniform spacing wastes geometry in the middle and faceting shows on the head.
        """
        n = self.rings
        return [0.5 * (1.0 - cos(pi * i / (n - 1))) for i in range(n)]

    def build(self, name="Body", subsurf=2):
        ts = self._ring_ts()
        angles = ring_angles(self.segments)

        bm = bmesh.new()

        nose = bm.verts.new((self.x(0.0), 0.0, self.spec.spine(0.0)))
        tail = bm.verts.new((self.x(1.0), 0.0, self.spec.spine(1.0)))

        ring_verts = []
        for t in ts[1:-1]:
            ring = [bm.verts.new(self.surface_point(t, a)) for a in angles]
            ring_verts.append(ring)

        bm.verts.ensure_lookup_table()

        for a, b in zip(ring_verts, ring_verts[1:]):
            for i in range(self.segments):
                j = (i + 1) % self.segments
                bm.faces.new((a[i], a[j], b[j], b[i]))

        for i in range(self.segments):
            j = (i + 1) % self.segments
            bm.faces.new((nose, ring_verts[0][j], ring_verts[0][i]))
            bm.faces.new((tail, ring_verts[-1][i], ring_verts[-1][j]))

        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])

        mesh = bpy.data.meshes.new(name)
        bm.to_mesh(mesh)
        bm.free()

        shade_smooth(mesh)
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.collection.objects.link(obj)

        if subsurf:
            mod = obj.modifiers.new("Subdivision", "SUBSURF")
            mod.levels = subsurf
            mod.render_levels = subsurf

        return obj


def shade_smooth(mesh):
    """Set smooth shading without going through an operator.

    `bpy.ops.object.shade_smooth()` needs a selected active object in a valid context,
    which is fragile in background mode; writing the flag directly always works.
    """
    mesh.polygons.foreach_set("use_smooth", [True] * len(mesh.polygons))
    mesh.update()
