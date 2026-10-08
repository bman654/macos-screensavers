"""Folded-paper fire with six independent base pivots, and a reusable smoke puff.

The fire's warm layers spread outward as they get shorter: its overhead silhouette is
red around orange around yellow, while the tallest yellow tongue supplies the height.
The centre crease and the last, bent-back tip are geometry, not a colour gradient.
"""

import math

import bmesh
import bpy

from ._spec import Model
from .mesh import bmesh_object, empty, flat_material, join, mesh_object


def _tongue(name, height, width, material, curl):
    # Each station is a crease across the sheet. A point at the bottom makes the pivot
    # an actual contact with the ground even when the whole tongue leans outward.
    stations = (
        (0.14, 0.50, 0.025, -0.06),
        (0.37, 1.00, 0.040, -0.12),
        (0.64, 0.80, 0.045, 0.10),
        (0.83, 0.38, 0.080, 0.28),
    )
    verts = [(0.0, 0.0, 0.0)]
    faces = []
    previous = None
    for along, breadth, bend, sideways in stations:
        half_width = width * 0.5 * breadth
        fold_depth = half_width * 0.65
        spine_x = height * bend
        spine_y = width * sideways * curl
        z = height * along
        left = len(verts)
        verts.extend((
            (spine_x - fold_depth * 0.5, spine_y - half_width, z),
            (spine_x + fold_depth * 0.5, spine_y, z),
            (spine_x - fold_depth * 0.5, spine_y + half_width, z),
        ))
        centre, right = left + 1, left + 2
        if previous is None:
            faces.extend(((0, left, centre), (0, centre, right)))
        else:
            old_left, old_centre, old_right = previous
            faces.extend((
                (old_left, left, centre), (old_left, centre, old_centre),
                (old_centre, centre, right), (old_centre, right, old_right),
            ))
        previous = left, centre, right

    # The last fold hooks back toward the centre of the fire, rather than ending in a
    # straight spear. Opposite curls keep the six tongues from reading as a tidy plant.
    tip = len(verts)
    verts.append((height * 0.010, width * 0.43 * curl, height))
    left, centre, right = previous
    faces.extend(((left, tip, centre), (centre, tip, right)))
    return mesh_object(name, verts, faces, [material])


def _build_fire():
    root = empty("fire")
    materials = {
        "red": flat_material("flame_red", "#ef3e24", emission=0.8),
        "orange": flat_material("flame_orange", "#ff861c", emission=1.0),
        "yellow": flat_material("flame_yellow", "#ffdc4b", emission=1.2),
    }
    # Colour, azimuth, local height, sheet width, lean, tip curl. The outer tongues are
    # low enough not to hide the hotter layers overhead. The bases meet at one point so
    # the paper spreads into a single fire, not six detached petals.
    tongues = (
        ("red", 0.0, 0.174, 0.081, 34.0, 0.8),
        ("red", 120.0, 0.164, 0.082, 37.0, -0.8),
        ("red", 240.0, 0.181, 0.079, 32.0, 0.7),
        ("orange", 65.0, 0.205, 0.072, 17.0, -0.9),
        ("orange", 245.0, 0.218, 0.070, 15.0, 0.9),
        ("yellow", 165.0, 0.250, 0.071, 3.0, -0.7),
    )
    flames = []
    for index, (colour, azimuth, height, width, lean, curl) in enumerate(tongues):
        obj = _tongue(f"flame_{index}", height, width, materials[colour], curl)
        obj.parent = root
        obj.rotation_euler = (0.0, math.radians(lean), math.radians(azimuth))
        flames.append((obj, height, colour))

    bpy.context.view_layer.update()
    points = [obj.matrix_world @ vertex.co for obj, _, _ in flames
              for vertex in obj.data.vertices]
    middle_x = (min(p.x for p in points) + max(p.x for p in points)) * 0.5
    middle_y = (min(p.y for p in points) + max(p.y for p in points)) * 0.5
    # Seating happens after build() returns, too late to change the extra manifest fields.
    # Centre the children here, never the Empty, so the driver's seating must be a no-op.
    for obj, _, _ in flames:
        obj.location.x -= middle_x
        obj.location.y -= middle_y
    bpy.context.view_layer.update()
    points = [obj.matrix_world @ vertex.co for obj, _, _ in flames
              for vertex in obj.data.vertices]
    assert abs(min(p.x for p in points) + max(p.x for p in points)) < 1e-7
    assert abs(min(p.y for p in points) + max(p.y for p in points)) < 1e-7
    assert abs(min(p.z for p in points)) < 1e-7
    assert root.location.length == 0.0 and tuple(root.scale) == (1.0, 1.0, 1.0)
    assert all(tuple(obj.scale) == (1.0, 1.0, 1.0) for obj, _, _ in flames)
    return root, {
        "flames": [
            {"node": obj.name, "base": [round(v, 6) for v in obj.location],
             "height": height, "colour": colour}
            for obj, height, colour in flames
        ],
    }


def _build_smoke_puff():
    paper = flat_material("paper_smoke", "#aaa69d", roughness=0.95)
    lumps = (
        ((-0.027, -0.007, -0.003), (0.037, 0.036, 0.039)),
        ((0.019, 0.008, 0.013), (0.040, 0.035, 0.041)),
        ((0.002, -0.018, -0.024), (0.035, 0.033, 0.031)),
    )
    parts = []
    for index, (centre, radii) in enumerate(lumps):
        bm = bmesh.new()
        bmesh.ops.create_icosphere(bm, subdivisions=2, radius=1.0)
        for vertex in bm.verts:
            x, y, z = vertex.co
            # A small, deterministic crumple breaks the regular gemstone outline without
            # turning a low-poly cloud into a ragged collection of disconnected shards.
            crease = 1.0 + 0.065 * math.sin(x * 5.0 + y * 3.0 + z * 4.0 + index)
            vertex.co = tuple(centre[axis] + value * radii[axis] * crease
                              for axis, value in enumerate((x, y, z)))
        parts.append(bmesh_object(f"smoke_lump_{index}", bm, [paper]))
    return join(parts, "smoke_puff"), {}


fire = Model(
    name="fire", kind="fire", build=_build_fire,
    summary="Six folded, hooked flame tongues: red outside, orange inside, a yellow core.",
    tags=("folded-paper", "emissive", "independent-flames"),
)
smoke_puff = Model(
    name="smoke_puff", kind="smoke", build=_build_smoke_puff,
    summary="Three crumpled, faceted warm-grey paper clouds joined into one puff.",
    tags=("folded-paper", "smoke"),
)
