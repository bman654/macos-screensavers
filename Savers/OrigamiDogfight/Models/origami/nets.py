"""Solid paper pieces, and the nets they would be cut from: the UVs of a model's `paper`.

A model whose paper the runtime replaces (a tank, a car, a hangar's team stripe) is built
from parts, each `(verts, faces, material)`. Every part in `paper` is unfolded into the net
it would be cut from, and the nets are laid out on one sheet, so a pattern on the runtime's
paper lands at one scale on every piece and is never mirrored or stretched by a fold.
Parts in any other material keep their authored colour and get a constant UV.
"""

import math
from collections import deque

import bmesh
from mathutils import Vector

from .mesh import flat_material, mesh_object, polygon_normal


def paper():
    """The material the runtime replaces with a side's (or a crane's) paper.

    Defined exactly as the planes define it, so a lineup can mix planes with anything else
    that carries paper; its colour only matters in the studio renders.
    """
    return flat_material("paper", "#f2efe6", roughness=0.9)


def convex(points, material):
    """The convex hull of `points`, with coplanar triangles merged into one panel each.

    One panel per flat region is what a fold makes, and it gives the net in `unfold` one
    piece of paper per panel rather than a fan of slivers.
    """
    bm = bmesh.new()
    for point in points:
        bm.verts.new(point)
    hull = bmesh.ops.convex_hull(bm, input=list(bm.verts), use_existing_faces=False)
    unused = set(hull["geom_interior"]) | set(hull["geom_unused"])
    bmesh.ops.delete(bm, geom=[v for v in unused if isinstance(v, bmesh.types.BMVert)],
                     context="VERTS")
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(0.05), use_dissolve_boundaries=False,
                             verts=list(bm.verts), edges=list(bm.edges))
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.verts.index_update()
    verts = [tuple(v.co) for v in bm.verts]
    faces = [[v.index for v in face.verts] for face in bm.faces]
    bm.free()
    return verts, faces, material


def _hinge(points, face, a, b, placed):
    """Lay `face` flat beside a neighbour already in the net, hinged about their shared edge
    a-b. Unfolding about an edge is a rotation, so the face keeps its handedness and the
    paper's pattern is never mirrored on it."""
    pa = points[a]
    edge = (points[b] - pa).normalized()
    flat_a, flat_b = Vector(placed[a]), Vector(placed[b])
    along2 = (flat_b - flat_a).normalized()
    side = Vector((-along2.y, along2.x))
    centre = sum((Vector(p) for p in placed.values()), Vector((0.0, 0.0))) / len(placed)
    if (centre - flat_a).dot(side) > 0:
        side = -side   # the neighbour lies on this side; the face goes on the other
    out = {}
    for i in face:
        offset = points[i] - pa
        along = offset.dot(edge)
        out[i] = tuple(flat_a + along2 * along + side * (offset - edge * along).length)
    return out


def unfold(verts, faces):
    """The net this piece would be cut from: one (s, t) per face corner.

    Rooted at the face that looks most nearly up, with the model's +X along the sheet's
    length (t) and its right (-Y) across it (s), so the net reads the way the model does
    from above. Every other face is hinged flat about an edge it shares with a face already
    placed, breadth first, which keeps the net compact.
    """
    points = [Vector(v) for v in verts]
    normals = [polygon_normal([verts[i] for i in face]) for face in faces]
    edges = {}
    for index, face in enumerate(faces):
        for a, b in zip(face, face[1:] + face[:1]):
            edges.setdefault(frozenset((a, b)), []).append(index)
    root = max(range(len(faces)), key=lambda k: normals[k].z)
    normal = normals[root]
    along = Vector((1.0, 0.0, 0.0)) - normal * normal.x
    if along.length < 1e-6:
        along = Vector((0.0, 1.0, 0.0)) - normal * normal.y
    along.normalize()
    across = along.cross(normal)
    origin = points[faces[root][0]]
    flat = {root: {i: ((points[i] - origin).dot(across), (points[i] - origin).dot(along))
                   for i in faces[root]}}
    queue = deque([root])
    while queue:
        parent = queue.popleft()
        face = faces[parent]
        for a, b in zip(face, face[1:] + face[:1]):
            for child in edges[frozenset((a, b))]:
                if child not in flat:
                    flat[child] = _hinge(points, faces[child], a, b, flat[parent])
                    queue.append(child)
    if len(flat) != len(faces):
        raise ValueError("a paper piece is not one connected surface")
    return [[flat[k][i] for i in faces[k]] for k in range(len(faces))]


def sheet(nets, gap=0.004):
    """Lay the nets out on one sheet, tallest first in rows, and scale it into [0, 1]².

    Returns (uvs, aspect): uvs[i] is nets[i] in sheet coordinates, aspect is the sheet's
    height / width — the shape the runtime makes its paper bitmap, so the pattern on it
    lands at one scale across every piece. `gap` is in the nets' own units (metres).
    """
    boxes = []
    for net in nets:
        s = [p[0] for face in net for p in face]
        t = [p[1] for face in net for p in face]
        boxes.append((min(s), min(t), max(s) - min(s), max(t) - min(t)))
    row_width = max(max(b[2] for b in boxes),
                    math.sqrt(sum((b[2] + gap) * (b[3] + gap) for b in boxes)))
    x = y = row = 0.0
    offsets = {}
    for i in sorted(range(len(nets)), key=lambda i: -boxes[i][3]):
        s0, t0, w, h = boxes[i]
        if x > 0.0 and x + w > row_width:
            x, y, row = 0.0, y + row + gap, 0.0
        offsets[i] = (x - s0, y - t0)
        x += w + gap
        row = max(row, h)
    width = max(offsets[i][0] + boxes[i][0] + boxes[i][2] for i in offsets)
    height = max(offsets[i][1] + boxes[i][1] + boxes[i][3] for i in offsets)

    def unit(value, span):
        return min(max(value / span, 0.0), 1.0)

    uvs = [[[(unit(s + offsets[i][0], width), unit(t + offsets[i][1], height))
             for s, t in face] for face in net] for i, net in enumerate(nets)]
    return uvs, height / width


def paper_meshes(groups, gap=0.004):
    """One mesh object per group of parts, every `paper` part UV-mapped from one shared sheet.

    `groups` is {object name: [part, ...]}, in the order the objects are made. Returns
    ({name: object}, sheet aspect); the aspect is None, and no object has UVs, when no part
    is paper. Parts are authored in the space their object will have, so a part that turns
    (a turret) is authored about its pivot and the caller places the object.
    """
    paper_parts = [(group, k) for group, parts in groups.items()
                   for k, part in enumerate(parts) if part[2].name == "paper"]
    sheet_uvs, aspect = {}, None
    if paper_parts:
        uvs, aspect = sheet([unfold(*groups[group][k][:2]) for group, k in paper_parts], gap)
        sheet_uvs = dict(zip(paper_parts, uvs))

    objects = {}
    for group, parts in groups.items():
        verts, faces, slots, corners, materials = [], [], [], [], []
        for k, (part_verts, part_faces, material) in enumerate(parts):
            if material not in materials:
                materials.append(material)
            start = len(verts)
            verts.extend(part_verts)
            faces.extend([start + i for i in face] for face in part_faces)
            slots.extend([materials.index(material)] * len(part_faces))
            # Only the paper is textured; anything else gets a constant, in-range UV.
            net = sheet_uvs.get((group, k))
            for f, face in enumerate(part_faces):
                corners.extend(net[f] if net else [(0.0, 0.0)] * len(face))
        objects[group] = mesh_object(group, verts, faces, materials, face_materials=slots,
                                     uvs=corners if paper_parts else None)
    return objects, aspect
