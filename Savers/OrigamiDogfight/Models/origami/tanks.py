"""Paper tanks: a folded hull on two pleated treads, and a turret that turns.

Seen from straight above at 40-80 px, a tank has to read as a tank, as *which* tank, and as
having a turret that is not part of the hull, because the runtime turns it to track a plane.
Hull and turret are the same paper in the same colour, so what separates them is geometry:

- two dark tread strips either side of a hull in the side's paper: the tank silhouette;
- the barrel standing well proud of the nose, so heading and aim both show;
- the turret as its own lit object. Its walls slope, so from above they make a band of
  different shades around it, and its roof is folded into facets, so no turret face is
  parallel to the deck and lit exactly as the deck is. On `tank` a dark ring outlines its
  foot; `tank_heavy`'s turret overhangs its collar, so a dark hatch on its cupola marks it.

The two designs differ in every one of those: `tank` is narrow, with a pointed nose, an
octagonal turret and one barrel; `tank_heavy` is a broad box on wide treads, with a
wedge-fronted turret, two long barrels, a cupola and engine louvres at the back.

Contract (docs/origami-plan.md, Asset contract): the root is an Empty named for the model
with two mesh children. `hull` is the body, its treads and the turret ring. `turret` carries
the barrels along +X, with its origin on its vertical rotation axis at the top of the ring it
sits on, so the runtime aims it by rotating that one node about its own z. Hull and turret
share the material `paper`, which the runtime replaces with the side's paper; their UVs are
the nets the pieces would be cut from, laid out on one sheet (`_unfold`, `_sheet`).

Manifest additions: `sheetAspect` (the sheet's height / width, as for a plane), and
`turret`: {"node": "turret", "pivot": [x, y, z], "muzzles": [[x, y, z], ...]} — the pivot is
the node's origin in model space after seating, the muzzles are barrel tips in the turret's
own space, where a pencil leaves the gun.
"""

import math
from collections import deque

import bmesh
from mathutils import Vector

from ._spec import Model
from .mesh import empty, flat_material, mesh_object, polygon_normal, wound_outward


def _paper():
    # The planes' paper, defined identically: the runtime replaces it, so its colour only
    # matters in the studio renders, and one definition lets a lineup mix planes and tanks.
    return flat_material("paper", "#f2efe6", roughness=0.9)


def _dark():
    # Dark kraft, warmer than the charcoal plane paper, so a tread never matches a side.
    return flat_material("paper_tread", "#3d3631", roughness=0.92)


# ---- parts: each is (verts, faces, material) ------------------------------------------

def _convex(points, material):
    """The convex hull of `points`, with coplanar triangles merged into one panel each.

    One panel per flat region is what a fold makes, and it gives the net in `_unfold` one
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


def _ngon(count, radius, z, centre=(0.0, 0.0), phase=0.0):
    return [(centre[0] + radius * math.cos(phase + math.tau * k / count),
             centre[1] + radius * math.sin(phase + math.tau * k / count), z)
            for k in range(count)]


def _box(x0, x1, y0, y1, z0, z1):
    return [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]


def _barrel(x0, x1, y, z, radius, material):
    """A hexagonal paper tube along +X, a corner on top so its two upper faces catch the
    light differently and it reads as round from above."""
    ring = [(radius * math.cos(math.radians(90 + 60 * k)),
             radius * math.sin(math.radians(90 + 60 * k))) for k in range(6)]
    return _convex([(x, y + dy, z + dz) for x in (x0, x1) for dy, dz in ring], material)


def _mirrored(part):
    verts, faces, material = part
    return [(x, -y, z) for x, y, z in verts], [face[::-1] for face in faces], material


def _tread(inner, width, length, height, links, wheels, pleat, bulge, material):
    """The left track run (+Y) as a folded strip, lofted along X.

    Every station is a cross-section across the strip: inner bottom, outer bottom, outer
    waist, outer top, inner top. The top drops by `pleat` at every other station — pleats
    that read as track links from above — and the waist is pushed out at `wheels` stations,
    folding a vertical ridge into the side for each road wheel. The ends ramp up off the
    ground, the front a little higher, the way a track wraps its idler.
    """
    half, ramp = length * 0.5, length * 0.13
    count = 2 * links + 1
    run = [-half + ramp + i * (length - 2 * ramp) / (count - 1) for i in range(count)]
    hubs = {round(1 + i * (count - 3) / (wheels - 1)) for i in range(wheels)}
    # The waist crease runs end to end; a straight waist at an end would leave the cap a
    # pentagon with one corner on a straight edge, which triangulates to a zero-area sliver.
    crease = bulge * 0.3
    stations = [(-half, 0.30 * height, 0.78 * height, crease)]
    for i, x in enumerate(run):
        top = height - (pleat if i % 2 else 0.0)
        stations.append((x, 0.0, top, bulge if i in hubs else crease))
    stations.append((half, 0.36 * height, 0.86 * height, crease))

    outer = inner + width
    verts = []
    for x, low, top, out in stations:
        waist = low + (top - low) * 0.45
        verts += [(x, inner, low), (x, outer, low), (x, outer + out, waist),
                  (x, outer, top), (x, inner, top)]
    faces = [list(range(5)), [5 * (len(stations) - 1) + k for k in range(5)]]
    for i in range(len(stations) - 1):
        for k in range(5):
            j = (k + 1) % 5
            faces.append([5 * i + k, 5 * i + j, 5 * (i + 1) + j, 5 * (i + 1) + k])
    return verts, wound_outward(verts, faces), material


def _treads(**kwargs):
    left = _tread(**kwargs)
    return [left, _mirrored(left)]


# ---- the paper's UVs -------------------------------------------------------------------

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


def _unfold(verts, faces):
    """The net this convex piece would be cut from: one (s, t) per face corner.

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


def _sheet(nets, gap=0.004):
    """Lay the nets out on one sheet, tallest first in rows, and scale it into [0, 1]².

    Returns (uvs, aspect): uvs[i] is nets[i] in sheet coordinates, aspect is the sheet's
    height / width — the shape the runtime makes its paper bitmap, so the pattern on it
    lands at one scale across every piece.
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


# ---- assembly --------------------------------------------------------------------------

def _assemble(name, hull_parts, turret_parts, pivot, muzzles):
    """The root Empty with its `hull` and `turret` meshes; the turret's parts are authored
    about its pivot, the hull's in model space."""
    groups = {"hull": hull_parts, "turret": turret_parts}
    paper = [(group, k) for group, parts in groups.items()
             for k, part in enumerate(parts) if part[2].name == "paper"]
    uvs, aspect = _sheet([_unfold(*groups[group][k][:2]) for group, k in paper])
    sheet_uvs = dict(zip(paper, uvs))

    root = empty(name)
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
        obj = mesh_object(group, verts, faces, materials, face_materials=slots, uvs=corners)
        obj.parent = root
        if group == "turret":
            obj.location = pivot
    return root, {
        "sheetAspect": round(aspect, 6),
        "turret": {"node": "turret", "pivot": [round(v, 6) for v in pivot],
                   "muzzles": [[round(v, 6) for v in m] for m in muzzles]},
    }


# ---- the designs -----------------------------------------------------------------------

def _build_tank():
    paper, dark = _paper(), _dark()
    deck, ring_top, turret_x = 0.032, 0.0326, -0.006
    side = [
        (-0.036, 0.027, deck), (0.024, 0.027, deck),            # deck
        (-0.053, 0.034, 0.0225), (0.040, 0.034, 0.0225),        # shoulders over the treads
        (0.061, 0.019, 0.013),                                  # the pointed nose
        (-0.059, 0.030, 0.014),                                 # rear plate
        (-0.052, 0.028, 0.004), (0.050, 0.028, 0.004),          # belly
    ]
    hull = [
        _convex(side + [(x, -y, z) for x, y, z in side], paper),
        # The ring stands a little proud of the deck and wider than the turret: a dark
        # outline round its foot, whichever way it points.
        _convex(_ngon(16, 0.0245, deck - 0.001, (turret_x, 0.0))
                + _ngon(16, 0.0245, ring_top, (turret_x, 0.0)), dark),
        *_treads(inner=0.030, width=0.018, length=0.120, height=0.021, links=9, wheels=4,
                 pleat=0.0012, bulge=0.0018, material=dark),
    ]
    muzzle = (0.088, 0.0, 0.0068)
    turret = [
        # Octagonal walls sloping in to a low eight-facet roof.
        _convex(_ngon(8, 0.0205, 0.0, phase=math.pi / 8)
                + _ngon(8, 0.0135, 0.012, (-0.002, 0.0), phase=math.pi / 8)
                + [(-0.002, 0.0, 0.0158)], paper),
        _convex(_box(0.012, 0.0215, -0.0062, 0.0062, 0.0025, 0.0108), paper),   # mantlet
        _barrel(0.016, muzzle[0], muzzle[1], muzzle[2], 0.0026, paper),
    ]
    return _assemble("tank", hull, turret, (turret_x, 0.0, ring_top), [muzzle])


def _build_tank_heavy():
    paper, dark = _paper(), _dark()
    deck, ring_top, turret_x = 0.040, 0.043, -0.002
    side = [
        (-0.052, 0.034, deck), (0.040, 0.034, deck),            # deck
        (-0.072, 0.041, 0.030), (0.064, 0.041, 0.030),          # fenders over the treads
        (0.075, 0.039, 0.022),                                  # a blunt, full-width front
        (-0.075, 0.038, 0.020),                                 # rear plate
        (-0.068, 0.034, 0.005), (0.068, 0.034, 0.005),          # belly
    ]
    hull = [
        _convex(side + [(x, -y, z) for x, y, z in side], paper),
        # A raised collar: the turret rides above the deck, so it clears the louvres as it
        # turns and stands visibly apart from the hull it overhangs.
        _convex(_ngon(16, 0.026, deck - 0.001, (turret_x, 0.0))
                + _ngon(16, 0.026, ring_top, (turret_x, 0.0)), dark),
        *[_convex(_box(x, x + 0.0035, -0.026, 0.026, deck - 0.001, deck + 0.0012), dark)
          for x in (-0.0505, -0.0440, -0.0375)],                # engine louvres
        *_treads(inner=0.035, width=0.027, length=0.152, height=0.028, links=11, wheels=6,
                 pleat=0.0015, bulge=0.0020, material=dark),
    ]
    muzzles = [(0.118, 0.0085, 0.0085), (0.118, -0.0085, 0.0085)]
    wedge = [(0.030, 0.0), (0.018, 0.027), (-0.031, 0.027), (-0.036, 0.020),
             (-0.036, -0.020), (-0.031, -0.027), (0.018, -0.027)]
    cupola = (-0.015, 0.011)
    turret = [
        # Wedge-fronted walls sloping well in to a hipped roof: from above, a band of wall
        # round a roof whose facets are tilted enough to be lit unlike the deck.
        _convex([(x, y, 0.0) for x, y in wedge]
                + [(x * 0.80, y * 0.72, 0.015) for x, y in wedge]
                + [(0.010, 0.0, 0.0205), (-0.020, 0.0, 0.0205)], paper),
        _convex(_box(0.019, 0.031, -0.015, 0.015, 0.003, 0.014), paper),        # mantlet
        _convex(_ngon(8, 0.0075, 0.012, cupola, math.pi / 8)
                + _ngon(8, 0.0060, 0.0235, cupola, math.pi / 8), paper),
        # The cupola's dark hatch: an off-centre dot that turns with the turret.
        _convex(_ngon(8, 0.0046, 0.0230, cupola, math.pi / 8)
                + _ngon(8, 0.0046, 0.0241, cupola, math.pi / 8), dark),
        *[_barrel(0.024, x, y, z, 0.0027, paper) for x, y, z in muzzles],
    ]
    return _assemble("tank_heavy", hull, turret, (turret_x, 0.0, ring_top), muzzles)


tank = Model(name="tank", kind="tank", build=_build_tank,
             summary="Narrow pointed hull on pleated treads; octagonal turret, one barrel.")
tank_heavy = Model(name="tank_heavy", kind="tank", build=_build_tank_heavy,
                   summary="Broad boxy hull on wide treads; wedge turret, cupola, twin barrels.")
