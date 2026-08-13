"""Parametric fin surfaces.

A fin is a quad grid over (u, v): `u` runs along the root where the fin meets the body,
`v` runs outward to the trailing edge. That parametrization is why fins here attach
cleanly — the root is sampled from the body's own surface curve, so there is no gap to
hide and no intersection to clean up.

Shape comes from three functions of u: how far the fin extends (`span`), how far its
outer edge trails backwards (`rake`), and how much the membrane curves out of plane
(`curl`). A forked caudal fin is just a span with a notch in the middle.
"""

import bmesh
import bpy
from mathutils import Vector

from .body import shade_smooth
from .curves import as_profile


def build_fin(
    name,
    root,
    out_dir,
    span,
    rake=0.0,
    curl=0.0,
    flare=0.0,
    curl_axis=Vector((0.0, 1.0, 0.0)),
    samples_u=18,
    samples_v=12,
    thickness=0.0025,
    subsurf=2,
):
    """Build a fin membrane.

    `root(u)` returns the attachment point, `out_dir(u)` the outward direction, and
    `span`, `rake`, `curl` are Profiles (or constants) evaluated over u in [0, 1].

    `flare` is a Profile over v giving how much wider than its root the membrane grows,
    spread along the root's own direction. Without it a fin can only extend, never
    widen, which turns a tail fan into a spike no matter how the span is tuned.

    On a short root — a caudal fin, whose root is only the depth of the peduncle — the
    parameter names mislead, and this is worth reading before tuning a tail:

    * A lobe's *width* comes almost entirely from `flare`, not from `span`. `flare`
      spreads a whole range of u sideways as v grows, so a tall lobe is built out of
      many u samples fanned apart; `span` only decides how far each of them reaches.
    * A sharp spike in `span` therefore gives two needles, not two lobes: only the one
      or two u samples at the spike reach far, and there is nothing beside them to fill
      in. A flat span gives blunt paddles for the mirror-image reason.
    * What gives lobes that taper to points is a span that falls *monotonically* from
      each end of the root into the central notch. Every u then reaches slightly less
      than its neighbour towards the centre, and the outline is a curve rather than a
      step.

    In short: shape the silhouette with the slope of `span` across u, and set the tail's
    overall spread with `flare`. Tuning the peak value of `span` is the least effective
    of the three and is where a forked tail usually goes wrong.
    """
    span = as_profile(span)
    rake = as_profile(rake)
    curl = as_profile(curl)
    flare = as_profile(flare)
    curl_axis = Vector(curl_axis).normalized()

    root_start, root_end = Vector(root(0.0)), Vector(root(1.0))
    root_axis = root_end - root_start
    root_axis = root_axis.normalized() if root_axis.length > 1e-9 else Vector((0, 0, 1))

    bm = bmesh.new()
    grid = []
    for i in range(samples_u):
        u = i / (samples_u - 1)
        base = Vector(root(u))
        direction = Vector(out_dir(u)).normalized()
        reach = span(u)
        column = []
        for j in range(samples_v):
            v = j / (samples_v - 1)
            p = base + direction * (reach * v)
            p += root_axis * ((u - 0.5) * flare(v))
            p.x -= rake(u) * v * v          # quadratic so the root stays flush
            p += curl_axis * (curl(u) * v * v)
            column.append(bm.verts.new(p))
        grid.append(column)

    bm.verts.ensure_lookup_table()

    for i in range(samples_u - 1):
        for j in range(samples_v - 1):
            bm.faces.new(
                (grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1])
            )

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])

    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()

    shade_smooth(mesh)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    if thickness:
        solid = obj.modifiers.new("Solidify", "SOLIDIFY")
        solid.thickness = thickness
        solid.offset = 0.0
    if subsurf:
        mod = obj.modifiers.new("Subdivision", "SUBSURF")
        mod.levels = subsurf
        mod.render_levels = subsurf

    return obj


def dorsal_root(body, t0, t1, sink=0.15):
    """Attachment along the back. `sink` pulls the root inside the body so the fin
    emerges from the flesh instead of balancing on top of it."""

    def root(u):
        t = t0 + (t1 - t0) * u
        return Vector((body.x(t), 0.0, body.top_z(t) - body.spec.top(t) * sink))

    return root


def ventral_root(body, t0, t1, sink=0.15):
    def root(u):
        t = t0 + (t1 - t0) * u
        return Vector((body.x(t), 0.0, body.bottom_z(t) + body.spec.bottom(t) * sink))

    return root


def flank_root(body, t0, t1, theta, side=1.0, sink=0.25):
    """Attachment on the side of the body at cross-section angle `theta`."""

    def root(u):
        t = t0 + (t1 - t0) * u
        p = body.surface_point(t, theta)
        p.y = abs(p.y) * side * (1.0 - sink)
        return p

    return root


def caudal_root(body, t=1.0, spread=0.9):
    """Attachment across the peduncle, running from the top edge down to the bottom."""
    top = body.top_z(t) * spread
    bottom = body.bottom_z(t) * spread
    x = body.x(t)

    def root(u):
        return Vector((x, 0.0, top + (bottom - top) * u))

    return root
