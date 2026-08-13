"""A tall cluster of current-bent kelp blades rooted to the tank floor."""

import math
import random

import bpy
from mathutils import Vector

from saverlib import Profile, SweptTube, assign

from ._spec import Prop


def _kelp_material(name):
    """Thin living tissue needs transmission and vertical colour, neither available in rock."""
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = (0.075, 0.105, 0.015, 1.0)
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()

    geometry = nodes.new("ShaderNodeNewGeometry")
    geometry.location = (-700, 100)
    separate = nodes.new("ShaderNodeSeparateXYZ")
    separate.location = (-500, 180)
    links.new(geometry.outputs["Position"], separate.inputs["Vector"])

    height = nodes.new("ShaderNodeMapRange")
    height.location = (-300, 220)
    height.clamp = True
    height.inputs["From Min"].default_value = 0.0
    height.inputs["From Max"].default_value = 0.86
    links.new(separate.outputs["Z"], height.inputs["Value"])

    noise = nodes.new("ShaderNodeTexNoise")
    noise.location = (-500, -120)
    noise.inputs["Scale"].default_value = 7.0
    noise.inputs["Detail"].default_value = 4.0
    noise.inputs["Roughness"].default_value = 0.65
    links.new(geometry.outputs["Position"], noise.inputs["Vector"])

    variation = nodes.new("ShaderNodeMath")
    variation.location = (-280, 20)
    variation.operation = "MULTIPLY_ADD"
    variation.inputs[1].default_value = 0.14
    variation.inputs[2].default_value = -0.07
    links.new(noise.outputs["Fac"], variation.inputs[0])

    tone = nodes.new("ShaderNodeMath")
    tone.location = (-80, 180)
    tone.operation = "ADD"
    tone.use_clamp = True
    links.new(height.outputs["Result"], tone.inputs[0])
    links.new(variation.outputs[0], tone.inputs[1])

    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.location = (120, 180)
    elements = ramp.color_ramp.elements
    elements[0].position = 0.0
    elements[0].color = (0.025, 0.040, 0.005, 1.0)
    elements[1].position = 0.58
    elements[1].color = (0.095, 0.160, 0.018, 1.0)
    tip = elements.new(1.0)
    tip.color = (0.215, 0.145, 0.028, 1.0)
    links.new(tone.outputs[0], ramp.inputs["Fac"])

    roughness = nodes.new("ShaderNodeMapRange")
    roughness.location = (100, -100)
    roughness.inputs["From Min"].default_value = 0.0
    roughness.inputs["From Max"].default_value = 1.0
    roughness.inputs["To Min"].default_value = 0.27
    roughness.inputs["To Max"].default_value = 0.46
    links.new(noise.outputs["Fac"], roughness.inputs["Value"])

    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (390, 100)
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(roughness.outputs["Result"], bsdf.inputs["Roughness"])
    bsdf.inputs["Specular IOR Level"].default_value = 0.48
    bsdf.inputs["Transmission Weight"].default_value = 0.17
    bsdf.inputs["Subsurface Weight"].default_value = 0.08
    bsdf.inputs["Subsurface Radius"].default_value = (0.003, 0.0015, 0.0008)
    bsdf.inputs["Coat Weight"].default_value = 0.12
    bsdf.inputs["Coat Roughness"].default_value = 0.22

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (650, 100)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    if hasattr(material, "use_raytrace_refraction"):
        material.use_raytrace_refraction = True
    return material


def _blade(root, material, rng, index, count):
    angle = 2.0 * math.pi * index / count + rng.uniform(-0.28, 0.28)
    base_radius = rng.uniform(0.010, 0.030)
    base = Vector((math.cos(angle) * base_radius, math.sin(angle) * base_radius, 0.008))
    height = rng.uniform(0.57, 0.86)
    lean_angle = angle + rng.uniform(-1.0, 1.0)
    lean = Vector((math.cos(lean_angle), math.sin(lean_angle), 0.0)) * rng.uniform(0.11, 0.23)
    cross = Vector((-lean.y, lean.x, 0.0)).normalized()
    sway = cross * rng.uniform(-0.060, 0.060)
    bow = Vector((rng.uniform(-0.030, 0.030), rng.uniform(-0.030, 0.030), 0.0))

    def path(t):
        eased = t * t * (3.0 - 2.0 * t)
        return base + Vector((0.0, 0.0, height * t)) + lean * (t ** 1.55) + (
            sway * math.sin(math.pi * t) + bow * math.sin(2.0 * math.pi * t)
        ) * eased

    half_width = rng.uniform(0.021, 0.038)
    ripple_count = rng.uniform(4.2, 6.2)
    ripple_phase = rng.uniform(0.0, 2.0 * math.pi)
    ripple_amount = rng.uniform(0.15, 0.22)
    width = []
    for step in range(33):
        t = step / 32.0
        root_flare = 0.48 + 0.52 * min(1.0, t / 0.14)
        tip_taper = 1.0 - 0.78 * t ** 3.1
        ripple = 1.0 + ripple_amount * math.sin(2.0 * math.pi * ripple_count * t + ripple_phase)
        width.append((t, half_width * root_flare * tip_taper * ripple))

    total_twist = math.radians(rng.uniform(145.0, 285.0)) * rng.choice((-1.0, 1.0))
    start_twist = rng.uniform(-math.pi, math.pi)
    twist = Profile([
        (0.0, start_twist),
        (0.30, start_twist + total_twist * 0.24),
        (0.68, start_twist + total_twist * 0.72),
        (1.0, start_twist + total_twist),
    ])
    thickness = Profile([(0.0, 0.0017), (0.72, 0.00135), (1.0, 0.00065)])
    blade = SweptTube(
        path,
        radius=1.0,
        rings=64,
        segments=8,
        section=(Profile(width), thickness),
        exponent=3.4,
        rounded_caps=False,
        twist=twist,
    ).build(f"kelp_blade_{index + 1:02d}", subsurf=1)
    blade.parent = root
    assign(blade, material)


def _holdfast(root, material, rng):
    # Exposed radial fingers make the cluster look attached rather than planted through the floor.
    for index in range(7):
        angle = 2.0 * math.pi * index / 7.0 + rng.uniform(-0.18, 0.18)
        reach = rng.uniform(0.045, 0.075)
        side = rng.uniform(-0.012, 0.012)

        def path(t, angle=angle, reach=reach, side=side):
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            tangent = Vector((-math.sin(angle), math.cos(angle), 0.0))
            return radial * (reach * t) + tangent * (side * math.sin(math.pi * t)) + Vector((
                0.0, 0.0, 0.014 * (1.0 - t) + 0.003 * math.sin(math.pi * t)
            ))

        finger = SweptTube(
            path,
            radius=Profile([(0.0, 0.009), (0.62, 0.006), (1.0, 0.0025)]),
            rings=18,
            segments=8,
            section=(1.0, 0.72),
            rounded_caps=(False, True),
            cap_rings=3,
        ).build(f"kelp_holdfast_{index + 1:02d}", subsurf=1)
        finger.parent = root
        assign(finger, material)


def build(seed=0):
    rng = random.Random(seed)
    root = bpy.data.objects.new("decor_kelp", None)
    bpy.context.collection.objects.link(root)
    material = _kelp_material(f"kelp_{seed}")

    _holdfast(root, material, rng)
    blade_count = rng.randint(5, 7)
    for index in range(blade_count):
        _blade(root, material, rng, index, blade_count)
    return root


KELP = Prop(
    name="kelp",
    build=build,
    category="plant",
    footprint=0.25,
    height=0.86,
    tilt_range=(-3.0, 3.0),
    scale_range=(0.82, 1.12),
    weight=1.25,
    min_spacing=0.42,
    seeds=4,
)
