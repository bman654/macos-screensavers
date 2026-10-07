"""Paper landmarks whose silhouettes and large folds survive the overhead camera."""

import math
import random

import bmesh

from ._spec import Model
from .mesh import bmesh_object, flat_material, join, mesh_object


def _paper_shell(name, vertices, faces, materials, face_materials=None,
                 thickness=0.025, edge_material=0):
    """Close a folded surface with a paper-thin reverse and exposed cut edges.

    Offsetting down rather than inflating each panel keeps adjoining folds hinged at
    exactly the same ridge. The thickness is a readability allowance, not a roof slab.
    Top faces must be wound upward; internal hinges get no extra edge face.
    """
    count = len(vertices)
    vertices = list(vertices) + [(x, y, z - thickness) for x, y, z in vertices]
    slots = list(face_materials) if face_materials is not None else [0] * len(faces)
    shell_faces = [tuple(face) for face in faces]
    shell_slots = list(slots)
    edges = {}
    for face, slot in zip(faces, slots):
        shell_faces.append(tuple(index + count for index in reversed(face)))
        shell_slots.append(slot)
        for a, b in zip(face, (*face[1:], face[0])):
            key = tuple(sorted((a, b)))
            edges.setdefault(key, []).append((a, b))
    for occurrences in edges.values():
        if len(occurrences) == 1:
            a, b = occurrences[0]
            shell_faces.append((b, a, a + count, b + count))
            shell_slots.append(edge_material)
    return mesh_object(name, vertices, shell_faces, materials, shell_slots)


def _boulder(name, seed, size, rings, colours):
    rng = random.Random(seed)
    bm = bmesh.new()
    for count, height, radius, offset in rings:
        phase = rng.uniform(-0.25, 0.25)
        for index in range(count):
            angle = math.tau * index / count + phase + rng.uniform(-0.13, 0.13)
            reach = radius * rng.uniform(0.82, 1.10)
            z = height + (rng.uniform(-0.10, 0.10) if height else 0.0)
            bm.verts.new((math.cos(angle) * reach + offset[0],
                          math.sin(angle) * reach + offset[1], z))
    hull = bmesh.ops.convex_hull(bm, input=list(bm.verts), use_existing_faces=False)
    unused = set(hull["geom_interior"]) | set(hull["geom_unused"])
    bmesh.ops.delete(bm, geom=[v for v in unused if isinstance(v, bmesh.types.BMVert)],
                     context="VERTS")
    # A flat base is shared by all seeded variants; exact extents make their scale explicit.
    lows = [min(vertex.co[axis] for vertex in bm.verts) for axis in range(3)]
    highs = [max(vertex.co[axis] for vertex in bm.verts) for axis in range(3)]
    for vertex in bm.verts:
        for axis in range(3):
            value = (vertex.co[axis] - lows[axis]) / (highs[axis] - lows[axis])
            vertex.co[axis] = (value - (0.5 if axis < 2 else 0.0)) * size[axis]
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.normal_update()
    materials = [flat_material(part, colour) for part, colour in colours]
    for face in bm.faces:
        face.material_index = 1 if face.normal.z > 0.65 else 0
    obj = bmesh_object(f"{name}_folds", bm, materials)
    return join([obj], name), {}


def _rock_a():
    return _boulder("rock_a", 2718, (2.0, 1.58, 1.02),
                    [(7, 0.0, 0.92, (0.0, 0.0)),
                     (6, 0.45, 0.94, (0.04, -0.05)),
                     (4, 0.98, 0.46, (-0.12, 0.07))],
                    [("paper_rock", "#939fab"), ("paper_rock_fold", "#aeb8c2")])


def _rock_b():
    return _boulder("rock_b", 1618, (1.55, 1.12, 0.46),
                    [(6, 0.0, 1.0, (0.0, 0.0)),
                     (5, 0.48, 0.87, (-0.10, 0.05)),
                     (3, 0.70, 0.45, (0.18, -0.08))],
                    [("paper_kraft", "#7a5a38"), ("paper_kraft_fold", "#a8845a")])


def _walls(name, length, width, eaves, material, ridge=None):
    x, y = length * 0.5, width * 0.5
    vertices = [(-x, -y, 0), (x, -y, 0), (x, y, 0), (-x, y, 0),
                (-x, -y, eaves), (x, -y, eaves), (x, y, eaves), (-x, y, eaves)]
    faces = [(3, 2, 1, 0), (0, 1, 5, 4), (1, 2, 6, 5),
             (2, 3, 7, 6), (3, 0, 4, 7)]
    if ridge is not None:
        vertices.extend([(-x, 0, ridge), (x, 0, ridge)])
        faces.extend([(5, 6, 9), (7, 4, 8)])
    return mesh_object(name, vertices, faces, [material])


def _front_face(name, x, y, bottom, width, height, material):
    # A tiny offset avoids coplanar depth fighting after export and runtime rescaling.
    vertices = [(x + 0.012, y - width * 0.5, bottom),
                (x + 0.012, y + width * 0.5, bottom),
                (x + 0.012, y + width * 0.5, bottom + height),
                (x + 0.012, y - width * 0.5, bottom + height)]
    return mesh_object(name, vertices, [(0, 1, 2, 3)], [material])


def _house_a():
    wall = flat_material("paper_wall_cream", "#f0dfb9")
    roof = flat_material("paper_roof_red", "#c8402e")
    edge = flat_material("paper_roof_edge", "#ecd4b9")
    door = flat_material("paper_door", "#42372f")
    objects = [_walls("house_a_walls", 5.8, 4.2, 2.365, wall, ridge=3.765)]
    vertices = [(-3.2, -2.4, 2.20), (3.2, -2.4, 2.20),
                (-3.2, 0, 3.80), (3.2, 0, 3.80),
                (-3.2, 2.4, 2.20), (3.2, 2.4, 2.20)]
    objects.append(_paper_shell("house_a_roof", vertices, [(0, 1, 3, 2), (2, 3, 5, 4)],
                                [roof, edge], thickness=0.035, edge_material=1))
    objects.append(_front_face("house_a_door", 2.9, -0.45, 0, 0.86, 1.42, door))
    objects.append(_front_face("house_a_window", 2.9, 1.03, 0.88, 0.64, 0.68, door))
    return join(objects, "house_a"), {}


def _house_b():
    wall = flat_material("paper_wall_ochre", "#d6ad50")
    roof = flat_material("paper_roof_blue", "#286f9e")
    hip = flat_material("paper_roof_blue_hip", "#4787af")
    edge = flat_material("paper_roof_edge", "#ecd4b9")
    door = flat_material("paper_door", "#42372f")
    objects = [_walls("house_b_walls", 4.6, 4.6, 2.8, wall)]
    vertices = [(-2.54, -2.6, 2.64), (2.54, -2.6, 2.64),
                (2.54, 2.6, 2.64), (-2.54, 2.6, 2.64),
                (-0.50, 0, 4.30), (0.50, 0, 4.30)]
    objects.append(_paper_shell("house_b_roof", vertices,
                                [(0, 1, 5, 4), (1, 2, 5), (2, 3, 4, 5), (3, 0, 4)],
                                [roof, hip, edge], [0, 1, 0, 1],
                                thickness=0.035, edge_material=2))
    objects.append(_front_face("house_b_door", 2.3, 0, 0, 0.9, 1.63, door))
    objects.append(_front_face("house_b_window_left", 2.3, 1.42, 1.15, 0.61, 0.77, door))
    objects.append(_front_face("house_b_window_right", 2.3, -1.42, 1.15, 0.61, 0.77, door))
    return join(objects, "house_b"), {}


def _boat():
    hull = flat_material("paper_hull", "#e7e4da")
    inner = flat_material("paper_hull_inner", "#b6b6ae")
    rim = flat_material("paper_rim", "#f5f2e9")
    peak = flat_material("paper_peak", "#f7f3e7")
    reverse = flat_material("paper_peak_reverse", "#d9d6cc")
    fold = flat_material("paper_peak_fold", "#c4c3ba")

    # Six rim corners give the hat-boat pointed ends without a canoe's smooth hull.
    outer = [(-2.0, 0, 0.85), (-1.32, -0.86, 0.76), (1.32, -0.86, 0.76),
             (2.0, 0, 0.85), (1.32, 0.86, 0.76), (-1.32, 0.86, 0.76)]
    bottom = [(-1.08, -0.28, 0), (1.08, -0.28, 0),
              (1.08, 0.28, 0), (-1.08, 0.28, 0)]
    vertices = outer + bottom
    outside_faces = [(9, 8, 7, 6), (6, 7, 2, 1), (8, 9, 5, 4),
                     (7, 3, 2), (7, 8, 3), (8, 4, 3),
                     (9, 0, 5), (9, 6, 0), (6, 1, 0)]
    objects = [mesh_object("paper_boat_hull", vertices, outside_faces, [hull])]

    # Matching the end panels' slope makes each rim quad planar, without thinning the
    # bright outline that carries the silhouette at a single pixel wide.
    rim_corner_height = 0.85 - 0.09 * 0.74 / 0.86
    inside_rim = [(-1.87, 0, 0.85), (-1.24, -0.74, rim_corner_height),
                  (1.24, -0.74, rim_corner_height), (1.87, 0, 0.85),
                  (1.24, 0.74, rim_corner_height), (-1.24, 0.74, rim_corner_height)]
    vertices = outer + inside_rim
    rim_faces = [(i, (i + 1) % 6, (i + 1) % 6 + 6, i + 6) for i in range(6)]
    objects.append(mesh_object("paper_boat_rim", vertices, rim_faces, [rim]))
    floor = [(-1.02, -0.22, 0.18), (1.02, -0.22, 0.18),
             (1.02, 0.22, 0.18), (-1.02, 0.22, 0.18)]
    vertices = inside_rim + floor
    inside_faces = [tuple(reversed(face)) for face in outside_faces]
    objects.append(mesh_object("paper_boat_inside", vertices, inside_faces, [inner]))

    # The central mountain is integral folded paper, not a mast and a separate cloth sail.
    # Its deliberately splayed sides expose a broad light/dark fold to the overhead camera.
    vertices = [(-1.34, -0.34, 0.40), (1.34, -0.34, 0.40),
                (1.34, 0.34, 0.40), (-1.34, 0.34, 0.40), (0, 0, 1.87)]
    objects.append(_paper_shell("paper_boat_peak", vertices,
                                [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)],
                                [peak, reverse, fold], [1, 2, 0, 2], thickness=0.020))
    return join(objects, "paper_boat"), {}


rock_a = Model("rock_a", "rock", _rock_a,
               "Cool-grey folded boulder with a broad irregular shoulder and raised crown.")
rock_b = Model("rock_b", "rock", _rock_b,
               "Low, asymmetric kraft-paper slab; flatter and warmer than rock_a.")
house_a = Model("house_a", "house", _house_a,
                "Cream paper house under a long vermilion sheet folded at one gable ridge.")
house_b = Model("house_b", "house", _house_b,
                "Taller ochre house with a square blue hip roof and four large fold panels.")
paper_boat = Model("paper_boat", "boat", _boat,
                   "Classic white hat-boat: pointed hull, open wells and a triangular paper peak.")
