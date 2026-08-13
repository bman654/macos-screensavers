"""Towering giant kelp stipes with alternating blades and gas bladders."""

import math
import random

import bpy
from mathutils import Vector

from saverlib import Profile, SweptTube, assign

from ._spec import Prop


_MAX_HEIGHT = 2.85


def _living_material(name):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = (0.035, 0.045, 0.004, 1.0)
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()

    geometry = nodes.new("ShaderNodeNewGeometry")
    geometry.location = (-760, 120)
    separate = nodes.new("ShaderNodeSeparateXYZ")
    separate.location = (-570, 220)
    links.new(geometry.outputs["Position"], separate.inputs["Vector"])

    height = nodes.new("ShaderNodeMapRange")
    height.location = (-370, 260)
    height.clamp = True
    height.inputs["From Min"].default_value = 0.05
    height.inputs["From Max"].default_value = _MAX_HEIGHT
    links.new(separate.outputs["Z"], height.inputs["Value"])

    noise = nodes.new("ShaderNodeTexNoise")
    noise.location = (-570, -100)
    noise.inputs["Scale"].default_value = 5.5
    noise.inputs["Detail"].default_value = 5.0
    noise.inputs["Roughness"].default_value = 0.68
    links.new(geometry.outputs["Position"], noise.inputs["Vector"])

    variation = nodes.new("ShaderNodeMath")
    variation.location = (-360, -30)
    variation.operation = "MULTIPLY_ADD"
    variation.inputs[1].default_value = 0.18
    variation.inputs[2].default_value = -0.09
    links.new(noise.outputs["Fac"], variation.inputs[0])

    tone = nodes.new("ShaderNodeMath")
    tone.location = (-150, 190)
    tone.operation = "ADD"
    tone.use_clamp = True
    links.new(height.outputs["Result"], tone.inputs[0])
    links.new(variation.outputs[0], tone.inputs[1])

    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.location = (50, 190)
    elements = ramp.color_ramp.elements
    elements[0].position = 0.0
    elements[0].color = (0.012, 0.016, 0.002, 1.0)
    elements[1].position = 0.58
    elements[1].color = (0.032, 0.047, 0.004, 1.0)
    amber = elements.new(1.0)
    amber.color = (0.070, 0.074, 0.008, 1.0)
    links.new(tone.outputs[0], ramp.inputs["Fac"])

    roughness = nodes.new("ShaderNodeMapRange")
    roughness.location = (20, -100)
    roughness.inputs["From Min"].default_value = 0.0
    roughness.inputs["From Max"].default_value = 1.0
    roughness.inputs["To Min"].default_value = 0.31
    roughness.inputs["To Max"].default_value = 0.50
    links.new(noise.outputs["Fac"], roughness.inputs["Value"])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (340, 100)
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(roughness.outputs["Result"], bsdf.inputs["Roughness"])
    bsdf.inputs["Specular IOR Level"].default_value = 0.44
    bsdf.inputs["Transmission Weight"].default_value = 0.14
    bsdf.inputs["Subsurface Weight"].default_value = 0.065
    bsdf.inputs["Subsurface Radius"].default_value = (0.0035, 0.0018, 0.0009)
    bsdf.inputs["Coat Weight"].default_value = 0.08
    bsdf.inputs["Coat Roughness"].default_value = 0.24

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (590, 100)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    if hasattr(material, "use_raytrace_refraction"):
        material.use_raytrace_refraction = True
    return material


def _holdfast_material(name):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = (0.030, 0.018, 0.004, 1.0)
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.030, 0.018, 0.004, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.68
    bsdf.inputs["Specular IOR Level"].default_value = 0.24

    noise = nodes.new("ShaderNodeTexNoise")
    noise.location = (-420, -100)
    noise.inputs["Scale"].default_value = 38.0
    noise.inputs["Detail"].default_value = 5.0
    noise.inputs["Roughness"].default_value = 0.72

    bump = nodes.new("ShaderNodeBump")
    bump.location = (-120, -100)
    bump.inputs["Strength"].default_value = 0.34
    bump.inputs["Distance"].default_value = 0.0025
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return material


def _holdfast(root, material, rng):
    core_lean = Vector((rng.uniform(-0.010, 0.010), rng.uniform(-0.010, 0.010), 0.0))

    def core_path(t):
        return Vector((0.0, 0.0, 0.004 + 0.094 * t)) + core_lean * t * t

    core = SweptTube(
        core_path,
        radius=Profile([(0.0, 0.046), (0.38, 0.037), (1.0, 0.020)]),
        rings=14,
        segments=10,
        section=(1.0, 0.90),
        rounded_caps=False,
    ).build("giant_kelp_holdfast_core", subsurf=1)
    core.parent = root
    assign(core, material)

    count = rng.randint(12, 14)
    phase = rng.uniform(0.0, 2.0 * math.pi)
    for index in range(count):
        angle = phase + 2.0 * math.pi * index / count + rng.uniform(-0.20, 0.20)
        radial = Vector((math.cos(angle), math.sin(angle), 0.0))
        tangent = Vector((-math.sin(angle), math.cos(angle), 0.0))
        reach = rng.uniform(0.075, 0.130)
        curl = rng.uniform(-0.034, 0.034)
        start = radial * rng.uniform(0.004, 0.020)
        start.z = rng.uniform(0.066, 0.105)

        def path(t, radial=radial, tangent=tangent, reach=reach, curl=curl, start=start):
            return (
                start
                + radial * (reach * t)
                + tangent * (curl * math.sin(math.pi * t))
                + Vector((0.0, 0.0, -(start.z - 0.004) * t ** 0.72
                          + 0.010 * math.sin(math.pi * t)))
            )

        hapteron = SweptTube(
            path,
            radius=Profile([(0.0, rng.uniform(0.008, 0.012)),
                            (0.58, rng.uniform(0.005, 0.007)),
                            (1.0, 0.0022)]),
            rings=15,
            segments=8,
            section=(1.0, 0.78),
            rounded_caps=(False, True),
            cap_rings=2,
        ).build(f"giant_kelp_hapteron_{index + 1:02d}", subsurf=1)
        hapteron.parent = root
        assign(hapteron, material)


def _stipe(root, material, rng, index, count, top_z, current, cross_current):
    angle = 2.0 * math.pi * index / count + rng.uniform(-0.28, 0.28)
    base_radius = rng.uniform(0.006, 0.025)
    base = Vector((math.cos(angle) * base_radius, math.sin(angle) * base_radius,
                   rng.uniform(0.064, 0.078)))
    splay = Vector((math.cos(angle), math.sin(angle), 0.0)) * rng.uniform(0.050, 0.130)
    shared_lean = current * rng.uniform(0.34, 0.48)
    side_bow = cross_current * rng.uniform(-0.050, 0.050)

    def path(t):
        eased = t * t * (3.0 - 2.0 * t)
        return (
            base
            + Vector((0.0, 0.0, (top_z - base.z) * t))
            + shared_lean * t ** 1.65
            + splay * t ** 1.35
            + side_bow * math.sin(math.pi * t) * eased
        )

    tube = SweptTube(
        path,
        radius=Profile([(0.0, rng.uniform(0.0090, 0.0115)),
                        (0.45, rng.uniform(0.0070, 0.0085)),
                        (1.0, rng.uniform(0.0046, 0.0058))]),
        rings=42,
        segments=8,
        rounded_caps=(False, True),
        cap_rings=2,
    )
    obj = tube.build(f"giant_kelp_stipe_{index + 1:02d}", subsurf=1)
    obj.parent = root
    assign(obj, material)
    return tube


def _pneumatocyst(root, material, start, axis, length, radius, name):
    axis = axis.normalized()
    reference = Vector((0.0, 0.0, 1.0))
    if abs(axis.dot(reference)) > 0.94:
        reference = Vector((0.0, 1.0, 0.0))
    side = axis.cross(reference).normalized()
    up = axis.cross(side).normalized()

    segments = 8
    ring_count = 6
    vertices = [start]
    for ring in range(1, ring_count):
        t = ring / ring_count
        swelling = math.sin(math.pi * t) ** 0.68
        swelling *= 0.72 + 0.44 * t
        centre = start + axis * (length * t)
        for segment in range(segments):
            angle = 2.0 * math.pi * segment / segments
            vertices.append(
                centre + (side * math.cos(angle) + up * math.sin(angle))
                * (radius * swelling)
            )
    vertices.append(start + axis * length)

    faces = []
    first_ring = 1
    for segment in range(segments):
        following = (segment + 1) % segments
        faces.append((0, first_ring + following, first_ring + segment))
    for ring in range(ring_count - 2):
        lower = 1 + ring * segments
        upper = lower + segments
        for segment in range(segments):
            following = (segment + 1) % segments
            faces.append((lower + segment, lower + following,
                          upper + following, upper + segment))
    tip = len(vertices) - 1
    last_ring = tip - segments
    for segment in range(segments):
        following = (segment + 1) % segments
        faces.append((last_ring + segment, last_ring + following, tip))

    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = root
    assign(obj, material)
    return start + axis * (length * 0.88)


def _blade(root, material, rng, stipe, stipe_index, blade_index, attachment_t,
           current, phase):
    attachment = stipe.point(attachment_t)
    tangent = stipe.tangent(attachment_t)
    side_angle = phase + math.pi * blade_index + rng.uniform(-0.30, 0.30)
    radial = Vector((math.cos(side_angle), math.sin(side_angle), 0.0))
    outward = (radial * 0.72 + current * 0.28).normalized()
    stipe_radius = stipe.radius_at(attachment_t)
    cyst_axis = (outward * 0.86 + tangent * 0.14).normalized()
    cyst_length = rng.uniform(0.026, 0.038)
    cyst_radius = rng.uniform(0.0105, 0.0140)
    cyst_start = attachment + outward * (stipe_radius * 0.72)
    blade_base = _pneumatocyst(
        root,
        material,
        cyst_start,
        cyst_axis,
        cyst_length,
        cyst_radius,
        f"giant_kelp_bladder_{stipe_index + 1:02d}_{blade_index + 1:02d}",
    )

    tip_scale = 0.50 + 0.50 * min(1.0, (1.0 - attachment_t) / 0.12)
    length = rng.uniform(0.34, 0.50) * (0.90 + 0.14 * attachment_t) * tip_scale
    lateral = Vector((-outward.y, outward.x, 0.0))
    wave = rng.uniform(-0.030, 0.030)
    droop = rng.uniform(0.24, 0.42)

    def path(t):
        return (
            blade_base
            + cyst_axis * (length * 0.58 * t)
            + current * (length * 0.38 * t ** 1.45)
            + tangent * (length * 0.20 * math.sin(math.pi * t))
            - Vector((0.0, 0.0, length * droop * t * t))
            + lateral * (length * wave * math.sin(2.0 * math.pi * t))
        )

    half_width = rng.uniform(0.034, 0.051)
    ripple_count = rng.uniform(2.4, 3.5)
    ripple_phase = rng.uniform(0.0, 2.0 * math.pi)
    width = []
    for step in range(16):
        t = step / 15.0
        root_flare = 0.20 + 0.80 * min(1.0, t / 0.20)
        tip_taper = max(0.11, 1.0 - t ** 3.2)
        ripple = 1.0 + rng.uniform(0.10, 0.16) * math.sin(
            2.0 * math.pi * ripple_count * t + ripple_phase
        )
        width.append((t, half_width * root_flare * tip_taper * ripple))

    start_twist = math.radians(rng.uniform(-24.0, 24.0))
    total_twist = math.radians(rng.uniform(55.0, 135.0)) * rng.choice((-1.0, 1.0))
    twist = Profile([
        (0.0, start_twist),
        (0.35, start_twist + total_twist * 0.22),
        (0.72, start_twist + total_twist * 0.70),
        (1.0, start_twist + total_twist),
    ])
    thickness = Profile([(0.0, 0.0015), (0.72, 0.00115), (1.0, 0.00055)])
    blade = SweptTube(
        path,
        radius=1.0,
        rings=16,
        segments=6,
        section=(Profile(width), thickness),
        exponent=3.5,
        rounded_caps=False,
        twist=twist,
    ).build(f"giant_kelp_blade_{stipe_index + 1:02d}_{blade_index + 1:02d}",
            subsurf=1)
    blade.parent = root
    assign(blade, material)


def _attachment_positions(rng, top_z):
    positions = []
    z = rng.uniform(0.18, 0.26)
    while z < top_z - 0.07:
        positions.append(z / top_z)
        density = min(1.0, max(0.0, (z - 0.24) / 1.20))
        spacing = rng.uniform(0.16, 0.20) * (1.0 - density) + rng.uniform(0.11, 0.14) * density
        z += spacing

    apex = 1.0 - rng.uniform(0.010, 0.020) / top_z
    if not positions or apex - positions[-1] > 0.035:
        positions.append(apex)
    else:
        positions[-1] = apex
    return positions


def build(seed=0):
    rng = random.Random(seed)
    root = bpy.data.objects.new("decor_giant_kelp", None)
    bpy.context.collection.objects.link(root)
    living = _living_material(f"giant_kelp_living_{seed}")
    holdfast = _holdfast_material(f"giant_kelp_holdfast_{seed}")

    _holdfast(root, holdfast, rng)

    current_angle = rng.uniform(-math.pi, math.pi)
    current = Vector((math.cos(current_angle), math.sin(current_angle), 0.0))
    cross_current = Vector((-current.y, current.x, 0.0))
    stipe_count = rng.randint(4, 6)
    tallest = rng.uniform(2.55, 2.82)
    tallest_index = rng.randrange(stipe_count)

    for index in range(stipe_count):
        top_z = tallest if index == tallest_index else tallest * rng.uniform(0.70, 0.94)
        stipe = _stipe(root, living, rng, index, stipe_count, top_z, current, cross_current)
        phase = current_angle + rng.uniform(-0.65, 0.65)
        for blade_index, attachment_t in enumerate(_attachment_positions(rng, top_z)):
            _blade(root, living, rng, stipe, index, blade_index, attachment_t, current, phase)
    return root


GIANT_KELP = Prop(
    name="giant_kelp",
    build=build,
    category="plant",
    footprint=0.85,
    height=_MAX_HEIGHT,
    tilt_range=(-1.5, 1.5),
    scale_range=(0.90, 1.05),
    weight=0.55,
    max_per_scene=2,
    min_spacing=1.25,
    seeds=3,
)
