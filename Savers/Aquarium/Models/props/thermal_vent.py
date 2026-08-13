"""A black-smoker chimney cluster with a continuously bubbling mouth."""

import math
import random

import bpy
from mathutils import Matrix, Vector

from saverlib import assign, displace, revolve, rock, rock_material

from ._spec import Emitter, Prop


def _move_mesh(obj, offset):
    # Baking placement into each mesh keeps every exported object at unit scale and makes
    # the emitter's coordinates independent of inherited transforms.
    obj.data.transform(Matrix.Translation(Vector(offset)))
    obj.data.update()


def _sit_on_floor(obj, x=0.0, y=0.0):
    bottom = min(vertex.co.z for vertex in obj.data.vertices)
    _move_mesh(obj, (x, y, -bottom))


def _lean_mesh(obj, base_z, top_z, lean):
    span = max(top_z - base_z, 1e-6)
    for vertex in obj.data.vertices:
        t = min(1.0, max(0.0, (vertex.co.z - base_z) / span))
        bend = t * t * (3.0 - 2.0 * t)
        vertex.co.x += lean[0] * bend
        vertex.co.y += lean[1] * bend
    obj.data.update()


def _chimney(root, name, origin, height, base_radius, mouth_radius, lean, seed, material):
    base_z = 0.025
    shoulder = base_z + height * 0.20
    top_z = base_z + height
    outline = [
        (base_radius * 1.18, base_z),
        (base_radius * 1.30, base_z + height * 0.07),
        (base_radius, shoulder),
        (base_radius * 0.72, base_z + height * 0.45),
        (mouth_radius * 0.92, base_z + height * 0.72),
        (mouth_radius * 1.12, top_z - height * 0.055),
        (mouth_radius, top_z),
    ]
    chimney = revolve(
        name,
        outline,
        segments=30,
        rings=34,
        cap_bottom=True,
        cap_top=False,
        thickness=max(0.005, mouth_radius * 0.22),
        sharp_angle=58.0,
    )
    _lean_mesh(chimney, base_z, top_z, lean)
    displace(
        chimney,
        strength=0.075,
        feature_size=0.16,
        octaves=5,
        seed=seed,
        subdivide=1,
    )
    _move_mesh(chimney, (origin[0], origin[1], 0.0))
    chimney.parent = root
    assign(chimney, material)

    mouth = Vector((origin[0] + lean[0], origin[1] + lean[1], top_z))
    return chimney, mouth, mouth_radius


def _mouth_rim(root, name, mouth, radius, seed, material):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=radius * 0.78,
        minor_radius=max(0.0045, radius * 0.20),
        major_segments=24,
        minor_segments=8,
        location=mouth,
    )
    rim = bpy.context.object
    rim.name = name
    displace(rim, strength=0.10, feature_size=0.30, octaves=4, seed=seed)
    rim.parent = root
    assign(rim, material)
    return rim


def _nodule(root, name, centre, radius, seed, material):
    nodule = rock(
        name,
        radius=radius,
        angularity=0.16,
        seed=seed,
        detail=2,
        lumpiness=0.58,
        flatten=0.08,
        grain=0.08,
    )
    _move_mesh(nodule, centre)
    nodule.parent = root
    assign(nodule, material)


def build(seed=0):
    rng = random.Random(seed)

    root = bpy.data.objects.new("decor_thermal_vent", None)
    bpy.context.collection.objects.link(root)

    dark = rock_material(
        f"vent_sulphide_{seed}",
        size=0.52,
        base=(0.0020, 0.0022, 0.0021),
        secondary=(0.0075, 0.0068, 0.0058),
        speckle=0.10,
        roughness=0.91,
        algae=0.05,
        seed=seed,
    )
    mound_material = rock_material(
        f"vent_mound_{seed}",
        size=0.38,
        base=(0.0030, 0.0028, 0.0025),
        secondary=(0.012, 0.009, 0.006),
        speckle=0.12,
        roughness=0.93,
        algae=0.12,
        seed=seed + 101,
    )
    crust = rock_material(
        f"vent_crust_{seed}",
        size=0.16,
        base=(0.085, 0.070, 0.050),
        secondary=(0.175, 0.125, 0.062),
        speckle=0.78,
        roughness=0.94,
        algae=0.03,
        seed=seed + 211,
    )
    mouth_stain = rock_material(
        f"vent_mouth_{seed}",
        size=0.08,
        base=(0.145, 0.042, 0.008),
        secondary=(0.290, 0.115, 0.018),
        speckle=0.65,
        roughness=0.88,
        algae=0.0,
        seed=seed + 307,
    )

    # Two overlapping mineral masses avoid the hemispherical pedestal that makes clustered
    # chimneys look like pipes inserted into one tidy rock.
    mound = rock(
        "mineral_mound",
        radius=0.160,
        angularity=0.52,
        seed=seed + 17,
        detail=5,
        lumpiness=0.58,
        flatten=0.82,
        grain=0.13,
    )
    _sit_on_floor(mound, -0.015, 0.0)
    mound.parent = root
    assign(mound, mound_material)

    shoulder = rock(
        "mineral_mound_lobe",
        radius=0.080,
        angularity=0.46,
        seed=seed + 29,
        detail=4,
        lumpiness=0.60,
        flatten=0.78,
        grain=0.12,
    )
    _sit_on_floor(shoulder, 0.125, 0.035)
    shoulder.parent = root
    assign(shoulder, dark)

    specs = (
        ("chimney_main", (-0.035, 0.020), 0.505, 0.063, 0.033),
        ("chimney_west", (-0.145, -0.065), 0.365, 0.052, 0.027),
        ("chimney_east", (0.115, 0.055), 0.285, 0.047, 0.025),
        ("chimney_front", (0.035, -0.130), 0.215, 0.041, 0.022),
    )
    chimneys = []
    for index, (name, origin, height, base_radius, mouth_radius) in enumerate(specs):
        angle = rng.uniform(0.0, math.tau)
        lean_amount = rng.uniform(0.012, 0.028) * (0.75 if index else 1.0)
        lean = (math.cos(angle) * lean_amount, math.sin(angle) * lean_amount)
        chimney, mouth, radius = _chimney(
            root,
            name,
            origin,
            height,
            base_radius,
            mouth_radius,
            lean,
            seed * 1009 + index * 43 + 71,
            dark,
        )
        _mouth_rim(
            root,
            f"{name}_mineral_lip",
            mouth,
            radius,
            seed * 1013 + index * 47 + 83,
            mouth_stain,
        )
        chimneys.append((origin, height, base_radius, mouth, radius, lean))

    # Accretion grows preferentially where fresh sulphides settle: around the bases and
    # mouths. Leaving the mid-shafts sparser preserves the stepped silhouette.
    for index in range(30):
        chimney_index = rng.choices((0, 1, 2, 3), weights=(11, 8, 6, 5), k=1)[0]
        origin, height, base_radius, _, mouth_radius, lean = chimneys[chimney_index]
        near_mouth = rng.random() > 0.58
        t = rng.uniform(0.86, 0.97) if near_mouth else rng.uniform(0.08, 0.30)
        z = 0.025 + height * t
        bend = t * t * (3.0 - 2.0 * t)
        centre_x = origin[0] + lean[0] * bend
        centre_y = origin[1] + lean[1] * bend
        tube_radius = base_radius + (mouth_radius - base_radius) * t
        theta = rng.uniform(0.0, math.tau)
        nodule_radius = rng.uniform(0.007, 0.012) if near_mouth else rng.uniform(0.010, 0.018)
        centre = (
            centre_x + math.cos(theta) * (tube_radius - nodule_radius * 0.40),
            centre_y + math.sin(theta) * (tube_radius - nodule_radius * 0.40),
            z,
        )
        _nodule(
            root,
            f"mineral_accretion_{index:02d}",
            centre,
            nodule_radius,
            seed * 2029 + index * 53 + 97,
            crust if near_mouth and rng.random() < 0.65 else dark,
        )

    emitter = bpy.data.objects.new("emit_vent", None)
    bpy.context.collection.objects.link(emitter)
    emitter.empty_display_type = "SPHERE"
    emitter.empty_display_size = 0.012
    emitter.location = chimneys[0][3] + Vector((0.0, 0.0, 0.006))
    emitter.parent = root

    return root


THERMAL_VENT = Prop(
    name="thermal_vent",
    build=build,
    category="decoration",
    footprint=0.27,
    height=0.55,
    tilt_range=(-3.0, 3.0),
    scale_range=(0.88, 1.12),
    weight=0.65,
    max_per_scene=2,
    min_spacing=0.62,
    emitters=(
        Emitter(
            "emit_vent",
            rate=24.0,
            radius=0.010,
            size=(0.0015, 0.0038),
            speed=0.065,
            continuous=True,
        ),
    ),
    seeds=3,
)
