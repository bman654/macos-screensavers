"""Small paper woodland, designed for silhouettes seen almost straight down.

The pine's nested star skirts, the round tree's broad irregular crown, the poplar's
single narrow spindle and the bush's three low lobes use different fold structures;
colour is a second cue, not the only way to tell them apart. Dimensions are metres.
"""

import math

import bmesh

from ._spec import Model
from .mesh import bmesh_object, flat_material, join, mesh_object


_TRUNK_COLOUR = "#98663f"


def _trunk(name, height, radius):
    material = flat_material("paper_trunk", _TRUNK_COLOUR)
    verts = []
    for z, taper in ((0.0, 1.0), (height, 0.78)):
        for i in range(6):
            angle = math.tau * i / 6
            verts.append((radius * taper * math.cos(angle),
                          radius * taper * math.sin(angle), z))
    faces = [(i, (i + 1) % 6, (i + 1) % 6 + 6, i + 6) for i in range(6)]
    faces.extend([tuple(reversed(range(6))), tuple(range(6, 12))])
    return mesh_object(name, verts, faces, [material])


def _pine_tier(name, radius, base, height, phase, material):
    # Raised valleys pull the skirt inward as well as upward, making genuine pleats
    # rather than a flat star cut-out. Broad folds survive a 20-pixel crown.
    pleats = 8
    verts = [(0.0, 0.0, base + height), (0.0, 0.0, base + 0.38)]
    for i in range(pleats * 2):
        valley = i % 2
        angle = phase + math.tau * i / (pleats * 2)
        r = radius * (0.64 if valley else 1.0)
        z = base + (0.32 if valley else 0.0)
        verts.append((r * math.cos(angle), r * math.sin(angle), z))
    faces = []
    for i in range(pleats * 2):
        a, b = 2 + i, 2 + (i + 1) % (pleats * 2)
        faces.extend([(0, a, b), (1, b, a)])
    return mesh_object(name, verts, faces, [material])


def _faceted_crown(name, width, depth, base, height, centre, phase, material, mound=False):
    bm = bmesh.new()
    if mound:
        bmesh.ops.create_icosphere(bm, subdivisions=1, radius=1.0)
    else:
        # A low-point hull gives irregular, broad creases without the central pole
        # fan of a regular sphere, so this crown does not become another radial star.
        count = 22
        golden_angle = math.pi * (3.0 - math.sqrt(5.0))
        for i in range(count):
            z = 1.0 - 2.0 * (i + 0.5) / count
            r = math.sqrt(1.0 - z * z)
            angle = golden_angle * i
            bm.verts.new((r * math.cos(angle), r * math.sin(angle), z))
    c, s = math.cos(phase), math.sin(phase)
    for vertex in bm.verts:
        x, y, z = vertex.co
        if mound:
            radius = 1.0 + 0.10 * math.sin(3.0 * math.atan2(y, x) + 2.4 * z)
            vertex.co = ((x * c - y * s) * radius,
                         (x * s + y * c) * radius,
                         z + 0.07 * math.sin(4.0 * x + 3.0 * y))
        else:
            # Perturb all three axes: moving only x/y would leave the overhead cap
            # nearly horizontal, averaging its facets into a smooth blob at 20 px.
            radius = 1.0 + 0.16 * math.sin(4.8 * x + 2.1 * y + 3.8 * z)
            vertex.co = ((x * c - y * s) * radius,
                         (x * s + y * c) * radius, z * radius)
    if not mound:
        bmesh.ops.convex_hull(bm, input=list(bm.verts), use_existing_faces=False)
        unused = [vertex for vertex in bm.verts if not vertex.link_faces]
        if unused:
            bmesh.ops.delete(bm, geom=unused, context="VERTS")
    lo = [min(v.co[axis] for v in bm.verts) for axis in range(3)]
    hi = [max(v.co[axis] for v in bm.verts) for axis in range(3)]
    for vertex in bm.verts:
        x, y, z = [(vertex.co[axis] - lo[axis]) / (hi[axis] - lo[axis])
                   for axis in range(3)]
        # A shrub is a mound resting on a broad folded base, not a ball balanced on
        # one point. Truncating its lower portion also steepens the visible top folds.
        if mound:
            z = max(0.0, (z - 0.30) / 0.70)
        vertex.co = (centre[0] + (x - 0.5) * width,
                     centre[1] + (y - 0.5) * depth,
                     base + z * height)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    return bmesh_object(name, bm, [material])


def _build_pine():
    leaf = flat_material("paper_pine_leaf", "#2b6b42")
    objects = [_trunk("pine_trunk", height=1.6, radius=0.26)]
    # Successive skirts leave an exposed band when viewed straight down. Slightly
    # staggered creases keep the four folded sheets legible as layers, not one cone.
    tiers = [
        (2.75, 1.15, 2.70, 0.0),
        (2.12, 2.95, 2.55, 0.08),
        (1.52, 4.65, 2.35, 0.02),
        (0.96, 6.00, 2.00, 0.10),
    ]
    for i, (radius, base, height, phase) in enumerate(tiers):
        objects.append(_pine_tier(f"pine_tier_{i}", radius, base, height, phase, leaf))
    return join(objects, "tree_pine"), {}


def _build_round():
    leaf = flat_material("paper_round_leaf", "#5b9f43")
    objects = [
        _trunk("round_trunk", height=2.0, radius=0.32),
        _faceted_crown("round_crown", width=5.2, depth=4.8, base=1.45,
                       height=4.55, centre=(0.0, 0.0), phase=0.29, material=leaf),
    ]
    return join(objects, "tree_round"), {}


def _build_tall():
    leaf = flat_material("paper_poplar_leaf", "#287d70")
    pleats = 5
    sides = pleats * 2
    phase = math.radians(18.0)
    rings = [(1.10, 0.43), (2.35, 1.08), (4.25, 1.25),
             (6.55, 1.00), (8.65, 0.48)]
    verts = []
    for z, radius in rings:
        for i in range(sides):
            angle = phase + math.tau * i / sides
            r = radius * (0.67 if i % 2 else 1.0)
            verts.append((r * math.cos(angle), r * math.sin(angle) * 0.90, z))
    faces = [tuple(reversed(range(sides)))]
    # Each tapered band has planar quads. Their full-length ridges read as one
    # accordion-folded spindle, unlike the pine's separate horizontal sheets.
    for ring in range(len(rings) - 1):
        lower, upper = ring * sides, (ring + 1) * sides
        for i in range(sides):
            following = (i + 1) % sides
            faces.append((lower + i, lower + following, upper + following, upper + i))
    tip = len(verts)
    verts.append((0.0, 0.0, 10.0))
    last = (len(rings) - 1) * sides
    for i in range(sides):
        faces.append((last + i, last + (i + 1) % sides, tip))
    objects = [
        _trunk("poplar_trunk", height=1.65, radius=0.21),
        mesh_object("poplar_crown", verts, faces, [leaf]),
    ]
    return join(objects, "tree_tall"), {}


def _build_bush():
    leaf = flat_material("paper_bush_leaf", "#85953e")
    # Overlapping coarse lobes give the shrub a scalloped footprint without spending
    # geometry on individual leaves. There is no trunk to suggest a miniature tree.
    lobes = [
        (2.65, 2.30, 1.50, (-0.35, 0.18), 0.10),
        (1.80, 1.65, 1.10, (0.96, -0.24), 0.62),
        (1.60, 1.45, 0.92, (-0.45, -0.90), -0.30),
    ]
    objects = [
        _faceted_crown(f"bush_lobe_{i}", width, depth, 0.0, height, centre,
                       phase, material=leaf, mound=True)
        for i, (width, depth, height, centre, phase) in enumerate(lobes)
    ]
    return join(objects, "bush"), {}


tree_pine = Model(name="tree_pine", kind="tree", build=_build_pine,
                  summary="Four deep-green folded star skirts on a short kraft-paper trunk.")
tree_round = Model(name="tree_round", kind="tree", build=_build_round,
                   summary="A broad irregular leaf-green polyhedral crown on a hexagonal trunk.")
tree_tall = Model(name="tree_tall", kind="tree", build=_build_tall,
                  summary="A slim blue-green five-pleat poplar spindle, ten metres tall.")
bush = Model(name="bush", kind="tree", build=_build_bush,
             summary="Three overlapping low olive-paper mounds, with no trunk.")
