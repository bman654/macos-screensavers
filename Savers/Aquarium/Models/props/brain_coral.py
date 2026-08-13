"""A massive brain coral with its maze pattern built into the mesh."""

import random
from math import cos, exp, pi, radians, sin, tau

import bpy
from mathutils import Vector

from saverlib import Noise, assign, rock_material, shade_smooth

from ._spec import Prop


_RADIUS = 0.205
_HEIGHT = 0.220
_SEGMENTS = 288
_RINGS = 96
_RIDGE_SPACING = 0.013


def _line_offset(noise, line, across, z):
    return 0.0034 * noise.fbm(
        across / 0.052 + line * 2.73, z / 0.105, line * 5.17,
        octaves=2, gain=0.42, lacunarity=1.85)


def _ridge_value(point, noise, direction, connectors):
    x, y, z = point
    dx, dy = direction
    along = dx * x + dy * y
    across = -dy * x + dx * y
    shared = 0.023 * noise.fbm(
        across / 0.062, z / 0.125, 7.3,
        octaves=3, gain=0.40, lacunarity=1.85)

    nearest = round((along - shared) / _RIDGE_SPACING)
    distance = float("inf")
    for line in range(nearest - 2, nearest + 3):
        centre = line * _RIDGE_SPACING + shared
        centre += _line_offset(noise, line, across, z)
        distance = min(distance, abs(along - centre))

    # Short links between neighbours produce Y-junctions without singular points or
    # collapsing the spacing of the surrounding folds.
    for line, start, end, direction_sign in connectors:
        if not start <= across <= end:
            continue
        t = (across - start) / (end - start)
        t = t * t * (3.0 - 2.0 * t)
        target = line + direction_sign
        source_centre = line * _RIDGE_SPACING + _line_offset(noise, line, across, z)
        target_centre = target * _RIDGE_SPACING + _line_offset(noise, target, across, z)
        centre = shared + source_centre + (target_centre - source_centre) * t
        distance = min(distance, abs(along - centre))

    return exp(-((distance / 0.0045) ** 2))


def _build_mesh(seed):
    ridge_noise = Noise(seed * 1009 + 41)
    form_noise = Noise(seed * 1013 + 73)
    rng = random.Random(seed * 1019 + 97)
    heading = rng.uniform(0.0, tau)
    direction = (cos(heading), sin(heading))
    connectors = []
    for _ in range(7):
        start = rng.uniform(-0.165, 0.105)
        connectors.append((
            rng.randint(-11, 10),
            start,
            start + rng.uniform(0.040, 0.072),
            rng.choice((-1, 1)),
        ))

    vertices = [(0.0, 0.0, _HEIGHT)]
    ridge_values = [_ridge_value(vertices[0], ridge_noise, direction, connectors)]

    for ring in range(1, _RINGS + 1):
        theta = 0.5 * pi * ring / _RINGS
        s, c = sin(theta), cos(theta)
        lower_bulge = 1.0 + 0.045 * s ** 6
        for segment in range(_SEGMENTS):
            phi = tau * segment / _SEGMENTS
            radial = _RADIUS * s * lower_bulge
            x = radial * cos(phi)
            y = radial * sin(phi)
            z = _HEIGHT * c

            normal = Vector((x / (_RADIUS * _RADIUS),
                             y / (_RADIUS * _RADIUS),
                             z / (_HEIGHT * _HEIGHT)))
            normal.normalize()

            broad = form_noise.fbm(x / 0.12, y / 0.12, z / 0.10,
                                   octaves=2, gain=0.52)
            ridge = _ridge_value((x, y, z), ridge_noise, direction, connectors)
            relief = 0.0032 * broad + 0.0046 * ridge
            point = Vector((x, y, z)) + normal * relief
            if ring == _RINGS:
                point.z = 0.0
            vertices.append(tuple(point))
            ridge_values.append(ridge)

    faces = []
    first_ring = 1
    for segment in range(_SEGMENTS):
        nxt = (segment + 1) % _SEGMENTS
        faces.append((0, first_ring + segment, first_ring + nxt))

    for ring in range(_RINGS - 1):
        lower = 1 + ring * _SEGMENTS
        upper = lower + _SEGMENTS
        for segment in range(_SEGMENTS):
            nxt = (segment + 1) % _SEGMENTS
            faces.append((lower + segment, upper + segment,
                          upper + nxt, lower + nxt))

    bottom = len(vertices)
    vertices.append((0.0, 0.0, 0.0))
    ridge_values.append(0.0)
    edge = 1 + (_RINGS - 1) * _SEGMENTS
    for segment in range(_SEGMENTS):
        nxt = (segment + 1) % _SEGMENTS
        faces.append((bottom, edge + nxt, edge + segment))

    mesh = bpy.data.meshes.new("part_brain_coral")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    shade_smooth(mesh)

    ridge_attr = mesh.attributes.new(
        name="ridge_mask", type="FLOAT", domain="POINT")
    ridge_attr.data.foreach_set("value", ridge_values)

    coral = bpy.data.objects.new("part_brain_coral", mesh)
    bpy.context.collection.objects.link(coral)
    split = coral.modifiers.new("Floor Rim", "EDGE_SPLIT")
    split.split_angle = radians(38.0)
    split.use_edge_angle = True
    split.use_edge_sharp = False
    return coral


def _brain_coral_material(seed):
    material = rock_material(
        f"brain_coral_{seed}", size=0.42,
        base=(0.105, 0.058, 0.018), secondary=(0.225, 0.142, 0.045),
        speckle=0.04, roughness=0.84, algae=0.40, seed=seed,
    )
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    bsdf = next(node for node in nodes if node.type == "BSDF_PRINCIPLED")
    base_input = bsdf.inputs["Base Color"]
    substrate = base_input.links[0].from_socket
    links.remove(base_input.links[0])

    ridge = nodes.new("ShaderNodeAttribute")
    ridge.attribute_name = "ridge_mask"
    ridge.location = (250, 250)
    strength = nodes.new("ShaderNodeMath")
    strength.operation = "MULTIPLY"
    strength.inputs[1].default_value = 0.48
    strength.location = (420, 250)
    links.new(ridge.outputs["Fac"], strength.inputs[0])

    crest = nodes.new("ShaderNodeMixRGB")
    crest.blend_type = "MIX"
    crest.inputs[2].default_value = (0.455, 0.335, 0.145, 1.0)
    crest.location = (420, 80)
    links.new(strength.outputs["Value"], crest.inputs[0])
    links.new(substrate, crest.inputs[1])
    links.new(crest.outputs["Color"], base_input)

    # Fine stone bump competes with the millimetre-scale folds under underwater lighting.
    next(node for node in nodes if node.type == "BUMP").inputs["Strength"].default_value = 0.24
    return material


def build(seed=0):
    root = bpy.data.objects.new("decor_brain_coral", None)
    bpy.context.collection.objects.link(root)

    coral = _build_mesh(seed)
    coral.parent = root
    assign(coral, _brain_coral_material(seed))
    return root


BRAIN_CORAL = Prop(
    name="brain_coral",
    build=build,
    category="coral",
    footprint=0.22,
    height=0.23,
    tilt_range=(-3.0, 3.0),
    scale_range=(0.90, 1.02),
    weight=1.25,
    min_spacing=0.44,
    seeds=3,
)
