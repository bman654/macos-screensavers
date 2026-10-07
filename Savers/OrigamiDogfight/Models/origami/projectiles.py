"""Office-supply ammunition, with silhouettes that survive an overhead 10–20 px view.

Wire is a bright dielectric rather than a metal: SceneKit has no environment map to
reflect. The clip's gaps, staple's crown and tack's head are deliberately chunkier than
real stationery; a mathematically accurate hairline would disappear in the fight.
"""

import math
import os
import random

import bmesh
import numpy as np
from mathutils import Vector

from ._spec import Model
from .mesh import (
    TEXTURE_DIR,
    bmesh_object,
    flat_material,
    join,
    lined_paper_image,
    mesh_object,
    textured_material,
)


def _wire_material():
    return flat_material("wire", "#d5dfe8", roughness=0.28, specular=0.45)


def _arc(cx, cy, radius, start, stop, steps):
    return [
        (cx + radius * math.cos(angle), cy + radius * math.sin(angle), 0.0)
        for angle in (math.radians(start + (stop - start) * i / steps)
                      for i in range(steps + 1))
    ]


def _sweep(name, path, section, material, closed=False):
    """Sweep a cross-section in the normal/Z frame of a planar centreline.

    A rounded bend needs the average of its neighbouring tangents, not one segment's
    tangent, or the ring at the bend pinches one side and opens the other.
    """
    points = [Vector(p) for p in path]
    verts, faces = [], []
    for i, point in enumerate(points):
        before = points[i - 1] if i > 0 or closed else point
        after = points[(i + 1) % len(points)] if i + 1 < len(points) or closed else point
        tangent = (after - before).normalized()
        normal = Vector((-tangent.y, tangent.x, 0.0))
        verts.extend(point + normal * across + Vector((0.0, 0.0, up))
                     for across, up in section)
    count = len(section)
    for i in range(len(points) if closed else len(points) - 1):
        nxt = (i + 1) % len(points)
        for j in range(count):
            k = (j + 1) % count
            faces.append((i * count + j, i * count + k,
                          nxt * count + k, nxt * count + j))
    if not closed:
        faces.append(tuple(reversed(range(count))))
        faces.append(tuple((len(points) - 1) * count + j for j in range(count)))
    return mesh_object(name, verts, faces, [material])


def _tube(name, path, radius, material, sides=8):
    section = [(radius * math.cos(math.tau * j / sides),
                radius * math.sin(math.tau * j / sides)) for j in range(sides)]
    return _sweep(name, path, section, material)


def _lathe_x(name, profile, material, sides=16):
    """A low-poly solid of revolution, with its axis along the flight direction."""
    verts, rings, faces = [], [], []
    for x, radius in profile:
        if radius == 0.0:
            rings.append([len(verts)])
            verts.append((x, 0.0, 0.0))
        else:
            rings.append(list(range(len(verts), len(verts) + sides)))
            verts.extend((x, radius * math.cos(math.tau * j / sides),
                          radius * math.sin(math.tau * j / sides)) for j in range(sides))
    for left, right in zip(rings, rings[1:]):
        for j in range(sides):
            k = (j + 1) % sides
            if len(left) == 1:
                faces.append((left[0], right[k], right[j]))
            elif len(right) == 1:
                faces.append((left[j], left[k], right[0]))
            else:
                faces.append((left[j], left[k], right[k], right[j]))
    return mesh_object(name, verts, faces, [material])


def _crumple(size, seed, irregularity):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=2, radius=1.0)
    rng = random.Random(seed)
    for vert in bm.verts:
        vert.co *= rng.uniform(1.0 - irregularity, 1.0 + irregularity)
    # Author at the intended physical dimensions; the CLI later centres the exact bounds.
    for axis, span in enumerate(size):
        low = min(v.co[axis] for v in bm.verts)
        high = max(v.co[axis] for v in bm.verts)
        for vert in bm.verts:
            vert.co[axis] = ((vert.co[axis] - low) / (high - low) - 0.5) * span
    bm.normal_update()
    return bm


def _build_spitball():
    spit = flat_material("spit", "#ddd9c7", roughness=0.30, specular=0.5)
    bm = _crumple((0.010, 0.0092, 0.0081), seed=17, irregularity=0.17)
    return bmesh_object("spitball", bm, [spit]), {}


def _build_paper_ball():
    image = lined_paper_image(
        "paper_ball_rules", os.path.join(TEXTURE_DIR, "paper_ball_rules.png"),
        size=(128, 128), rule_every=0.17, header=0.08, margin=0.17,
        paper="#f8f7f1", rule="#3d83b5", margin_rule="#c97278",
    )
    # Real hairline rules average to cream at projectile scale. Sparse, bold fragments
    # retain a blue paper cue after minification; no extra texture or shader is needed.
    pixels = np.empty(128 * 128 * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    pixels = pixels.reshape(128, 128, 4)
    rule_rows = np.flatnonzero(np.linalg.norm(pixels[:, 64, :3] - pixels[0, 64, :3],
                                             axis=1) > 0.02)
    for row in rule_rows:
        pixels[row:min(row + 4, 128)] = pixels[row].copy()
    image.pixels.foreach_set(pixels.ravel())
    image.save()
    paper = textured_material("paper", image)
    bm = _crumple((0.050, 0.047, 0.045), seed=83, irregularity=0.24)
    verts, faces, uvs = [], [], []
    rng = random.Random(210)
    for face in bm.faces:
        points = [v.co.copy() for v in face.verts]
        centre = sum(points, Vector()) / len(points)
        along = (points[1] - points[0]).normalized()
        across = face.normal.cross(along).normalized()
        angle = rng.uniform(0.0, math.tau)
        c, s = math.cos(angle), math.sin(angle)
        local = []
        for point in points:
            delta = point - centre
            x, y = delta.dot(along), delta.dot(across)
            local.append((c * x - s * y, s * x + c * y))
        largest = max(abs(v) for pair in local for v in pair)
        footprint = rng.uniform(0.12, 0.23)
        # Separate islands let rules change direction at every crushed fold, without
        # extending outside the sheet or forcing a texture seam through a single facet.
        offset = (rng.uniform(0.26, 0.74), rng.uniform(0.26, 0.74))
        uvs.extend((offset[0] + x / largest * footprint,
                    offset[1] + y / largest * footprint) for x, y in local)
        start = len(verts)
        verts.extend(points)
        faces.append(tuple(range(start, start + len(points))))
    bm.free()
    return mesh_object("paper_ball", verts, faces, [paper], uvs=uvs), {}


def _build_paper_clip():
    # One continuous gem wire: large right bend, offset left bend, smaller right bend.
    # Its two open ends matter: a pair of closed ovals reads as a chain link instead.
    path = [(-0.0068, -0.0056, 0.0)]
    path.extend(_arc(0.0106, 0.0, 0.0056, -90.0, 90.0, 14))
    path.extend(_arc(-0.0105, 0.0017, 0.0039, 90.0, 270.0, 12))
    path.extend(_arc(0.0085, 0.0, 0.0022, -90.0, 90.0, 10))
    path.append((-0.0065, 0.0022, 0.0))
    return _tube("paper_clip", path, 0.00095, _wire_material()), {}


def _build_staple():
    path = [(-0.0045, -0.0059, 0.0)]
    path.extend(_arc(0.0026, -0.0050, 0.0009, -90.0, 0.0, 3))
    path.extend(_arc(0.0026, 0.0050, 0.0009, 0.0, 90.0, 3))
    path.append((-0.0045, 0.0059, 0.0))
    # A staple is pressed rectangular wire, unlike the round wire of the gem clip.
    section = [(0.0008, -0.0006), (0.0008, 0.0006),
               (-0.0008, 0.0006), (-0.0008, -0.0006)]
    return _sweep("staple", path, section, _wire_material()), {}


def _build_thumbtack():
    head_material = flat_material("tack_head", "#368da9", roughness=0.4)
    head = _lathe_x("tack_head", [
        (-0.0060, 0.0), (-0.0056, 0.0033), (-0.0047, 0.0058),
        (-0.0033, 0.0065), (-0.0021, 0.0065), (-0.0016, 0.0058),
        (-0.0016, 0.0),
    ], head_material)
    pin = _lathe_x("tack_pin", [
        (-0.0018, 0.0), (-0.0018, 0.00085),
        (0.0065, 0.00085), (0.0088, 0.0),
    ], _wire_material(), sides=8)
    return join([head, pin], "thumbtack"), {}


def _build_rubber_band():
    # A slightly wider-than-real loop leaves a full row of hole at 10 px; a 10 mm
    # width becomes only two pixel rows, both partially occupied by the band itself.
    path = _arc(0.0164, 0.0, 0.00525, -90.0, 90.0, 14)
    path.extend(_arc(-0.0164, 0.0, 0.00525, 90.0, 270.0, 14))
    section = [(0.00085, -0.00045), (0.00085, 0.00045),
               (-0.00085, 0.00045), (-0.00085, -0.00045)]
    rubber = flat_material("rubber", "#b74c43", roughness=0.78)
    return _sweep("rubber_band", path, section, rubber, closed=True), {}


def _build_eraser():
    outline = [(-0.0060, -0.0024), (-0.0048, -0.0038), (0.0043, -0.0034),
               (0.0060, -0.0021), (0.0060, 0.0021), (0.0044, 0.0034),
               (-0.0049, 0.0038), (-0.0060, 0.0025)]
    verts = [(x, y, -0.0022) for x, y in outline]
    top = [(x * 0.88 - 0.00025, y * 0.9,
            0.0034 - (x + 0.0060) * 0.20) for x, y in outline]
    verts.extend(top)
    verts.append((-0.0016, 0.0005, 0.0029))
    faces = [tuple(reversed(range(8)))]
    for i in range(8):
        nxt = (i + 1) % 8
        faces.append((i, nxt, nxt + 8, i + 8))
        faces.append((i + 8, nxt + 8, 16))
    eraser_material = flat_material("eraser", "#e99aa8", roughness=0.88)
    return mesh_object("eraser", verts, faces, [eraser_material]), {}


spitball = Model(name="spitball", kind="projectile", build=_build_spitball,
                 summary="A small irregular wet off-white spitball.")
paper_ball = Model(name="paper_ball", kind="projectile", build=_build_paper_ball,
                   summary="Crumpled lined paper, with rule fragments turning at its facets.")
paper_clip = Model(name="paper_clip", kind="projectile", build=_build_paper_clip,
                   summary="A silver gem clip with one wire winding into two nested loops.")
staple = Model(name="staple", kind="projectile", build=_build_staple,
               summary="A silver U with its crown forward and two open legs trailing.")
thumbtack = Model(name="thumbtack", kind="projectile", build=_build_thumbtack,
                  summary="A chunky blue domed tack head flying silver-pin-first.")
rubber_band = Model(name="rubber_band", kind="projectile", build=_build_rubber_band,
                    summary="A stretched red rubber loop with a flat rectangular band.")
eraser = Model(name="eraser", kind="projectile", build=_build_eraser,
               summary="A faceted pink-pearl eraser crumb, broken into a chunky wedge.")
