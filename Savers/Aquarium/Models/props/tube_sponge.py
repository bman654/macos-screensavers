"""A vivid orange cluster of upright tube sponges."""

import math
import random

import bpy
from mathutils import Matrix, Vector

from saverlib import assign, displace, revolve, rock, rock_material

from ._spec import Prop


def _bend_and_place(obj, height, position, lean, lean_degrees, bend, bend_angle):
    bend_direction = Vector((math.cos(bend_angle), math.sin(bend_angle), 0.0))
    sway_direction = Vector((-bend_direction.y, bend_direction.x, 0.0))
    lean_direction = Vector((math.cos(lean), math.sin(lean), 0.0))
    lean_axis = Vector((-lean_direction.y, lean_direction.x, 0.0))
    rotation = Matrix.Rotation(math.radians(lean_degrees), 4, lean_axis)
    offset = Vector((*position, 0.0))

    for vertex in obj.data.vertices:
        t = max(0.0, min(1.0, vertex.co.z / height))
        angle = math.atan2(vertex.co.y, vertex.co.x)
        # Subtle lobes and an uneven mouth remove the machined circularity that would turn
        # an otherwise organic silhouette into a bundle of manufactured pipes.
        radial = 1.0 + 0.032 * math.sin(3.0 * angle + bend_angle)
        radial += 0.016 * math.sin(5.0 * angle - 1.7 * bend_angle)
        vertex.co.x *= radial
        vertex.co.y *= radial
        vertex.co.z += 0.0018 * math.sin(3.0 * angle + bend_angle) * t ** 7
        # A slow change at the buried foot keeps the clump fused to its base instead of
        # opening a visible crease where a bent wall meets the encrusting sponge.
        vertex.co += bend_direction * (height * bend * t * t)
        vertex.co += sway_direction * (height * bend * 0.34 * math.sin(math.pi * t) * t)
        vertex.co = rotation @ vertex.co + offset
    obj.data.update()


def _flatten_base(base, height, dome):
    low = min(vertex.co.z for vertex in base.data.vertices)
    high = max(vertex.co.z for vertex in base.data.vertices)
    radius = max(math.hypot(vertex.co.x, vertex.co.y) for vertex in base.data.vertices)
    span = max(high - low, 1e-6)
    for vertex in base.data.vertices:
        distance = math.hypot(vertex.co.x, vertex.co.y)
        centre = max(0.0, 1.0 - (distance / max(radius * 1.05, 1e-6)) ** 2)
        vertex.co.z = (vertex.co.z - low) * height / span + dome * centre * centre
    base.data.update()


def _evaluated_geometry(objects):
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    vertices = polygons = 0
    for obj in objects:
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        vertices += len(mesh.vertices)
        polygons += len(mesh.polygons)
        evaluated.to_mesh_clear()
    return vertices, polygons


def build(seed=0):
    rng = random.Random(seed * 1009 + 47)
    root = bpy.data.objects.new("decor_tube_sponge", None)
    bpy.context.collection.objects.link(root)

    exterior = rock_material(
        f"tube_sponge_orange_{seed}", size=0.075,
        base=(0.54, 0.055, 0.006), secondary=(0.92, 0.20, 0.018),
        speckle=0.82, roughness=0.88, algae=0.04, seed=seed * 17 + 3,
    )
    interior = rock_material(
        f"tube_sponge_cavity_{seed}", size=0.055,
        base=(0.018, 0.0015, 0.0004), secondary=(0.055, 0.0045, 0.0008),
        speckle=0.48, roughness=0.96, algae=0.0, seed=seed * 17 + 11,
    )

    base = rock(
        "sponge_encrusting_base", radius=0.112, angularity=0.08,
        seed=seed * 31 + 5, detail=3, lumpiness=0.24, flatten=0.85, grain=0.035,
    )
    _flatten_base(base, 0.043, 0.018)
    base.parent = root
    assign(base, exterior)
    geometry = [base]

    count = rng.randint(5, 7)
    sites = [(0.0, 0.0)]
    phase = rng.uniform(0.0, math.tau)
    for index in range(1, count):
        angle = phase + math.tau * (index - 1) / (count - 1) + rng.uniform(-0.22, 0.22)
        radius = rng.uniform(0.044, 0.073)
        sites.append((radius * math.cos(angle), radius * math.sin(angle)))

    heights = [rng.uniform(0.245, 0.32)]
    heights.extend(rng.uniform(0.105, 0.255) for _ in range(count - 1))
    tubes = []
    for index, ((x, y), height) in enumerate(zip(sites, heights)):
        radius = rng.uniform(0.023, 0.027) + 0.016 * (height - 0.10)
        wall = min(rng.uniform(0.0050, 0.0070), radius * 0.28)

        lobe = rock(
            f"sponge_root_{index + 1:02d}", radius=radius * 1.55, angularity=0.04,
            seed=seed * 313 + index * 43 + 29, detail=2, lumpiness=0.18,
            flatten=0.90, grain=0.025,
        )
        _flatten_base(lobe, 0.025, 0.011)
        for vertex in lobe.data.vertices:
            vertex.co.x += x
            vertex.co.y += y
            vertex.co.z += 0.020
        lobe.data.update()
        lobe.parent = root
        assign(lobe, exterior)
        geometry.append(lobe)

        tube = revolve(
            f"sponge_tube_{index + 1:02d}",
            outline=[
                (radius * 0.94, 0.018),
                (radius * 0.88, height * 0.14),
                (radius * 0.91, height * 0.48),
                (radius * 0.98, height * 0.78),
                (radius * 1.18, height),
            ],
            segments=32, rings=22, interpolation="smooth",
            cap_bottom=True, cap_top=False, thickness=wall,
            sharp_angle=58.0,
        )
        assign(tube, exterior)
        # The tiny relief breaks the lathe-perfect silhouette; the rock shader supplies the
        # finer pores that are too small to justify geometry at screensaver distance.
        displace(
            tube, strength=0.0080, feature_size=0.045, octaves=4,
            seed=seed * 211 + index * 37 + 19,
        )
        lean = (math.atan2(y, x) + rng.uniform(-0.45, 0.45)
                if index else rng.uniform(0.0, math.tau))
        lean_degrees = rng.uniform(10.0, 17.0)
        bend = rng.uniform(0.080, 0.140)
        bend_angle = rng.uniform(0.0, math.tau)
        _bend_and_place(
            tube, height, (x, y), lean, lean_degrees, bend, bend_angle,
        )
        tube.parent = root
        solidify = tube.modifiers.get("Solidify")
        solidify.material_offset = 0
        solidify.material_offset_rim = 0
        tubes.append(tube)

        # A short recessed liner guarantees that the osculum stays dark under the tank's
        # broad fill light; shading alone cannot keep the bottom cap from glowing orange.
        cavity = revolve(
            f"sponge_cavity_{index + 1:02d}",
            outline=[
                (max(0.003, radius * 0.92 - wall - 0.0012), height * 0.55),
                (max(0.003, radius * 0.98 - wall - 0.0012), height * 0.78),
                (max(0.003, radius * 1.18 - wall - 0.0012), height - 0.0030),
            ],
            segments=32, rings=10, interpolation="smooth",
            cap_bottom=True, cap_top=False, sharp_angle=58.0,
        )
        assign(cavity, interior)
        _bend_and_place(
            cavity, height, (x, y), lean, lean_degrees, bend, bend_angle,
        )
        cavity.parent = root
        geometry.append(cavity)

    vertices, polygons = _evaluated_geometry([*geometry, *tubes])
    print(f"[tube_sponge] tubes={count} verts={vertices} polys={polygons}")
    return root


TUBE_SPONGE = Prop(
    name="tube_sponge",
    build=build,
    category="coral",
    footprint=0.15,
    height=0.35,
    tilt_range=(-5.0, 5.0),
    scale_range=(0.78, 1.28),
    weight=1.5,
    max_per_scene=4,
    seeds=4,
)
