"""Headless render harness for inspecting generated models.

The whole point of authoring models as code is being able to look at the result and
adjust, so this module optimizes for a fast, honest look at a mesh: neutral studio
lighting that shows form, auto-framed orbit views that show silhouette from every side,
and a contact sheet so a whole turntable can be reviewed as one image.

`underwater_lights` renders the same model under the conditions it will actually be
seen in, which flatters a model far more than studio light does — use studio light to
judge the mesh and underwater light to judge the look.
"""

import math
import os
import subprocess

import bpy
from mathutils import Vector


def reset_scene():
    """Empty the file completely, including orphaned datablocks from a previous build."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for collection in (
        bpy.data.meshes,
        bpy.data.materials,
        bpy.data.objects,
        bpy.data.cameras,
        bpy.data.lights,
        bpy.data.worlds,
    ):
        for datablock in list(collection):
            collection.remove(datablock)


def setup_render(resolution=(900, 700), samples=64, transparent=False, exposure=-1.15,
                 view_transform="Standard"):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x, scene.render.resolution_y = resolution
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = transparent

    eevee = scene.eevee
    for attr, value in (
        ("taa_render_samples", samples),
        ("use_raytracing", True),
        ("use_shadows", True),
        ("use_bloom", True),
    ):
        if hasattr(eevee, attr):
            setattr(eevee, attr, value)

    # Default to Standard, not AgX. AgX desaturates as values rise, which turned a
    # saturated orange fish into pale salmon and reads as a material bug when it is
    # really a tone curve. More to the point, SceneKit tone-maps close to linear->sRGB,
    # so Standard previews the colour the screensaver will actually show. Pass
    # view_transform="AgX" when judging highlight roll-off instead of albedo.
    scene.view_settings.view_transform = view_transform
    if view_transform == "AgX":
        _try_enum(scene.view_settings, "look", ["AgX - Punchy", "AgX - High Contrast"])
    scene.view_settings.exposure = exposure
    return scene


def _try_enum(struct, attr, candidates):
    """Set the first candidate the current Blender build accepts.

    Enum identifiers for view-transform looks have been renamed between releases, and a
    missing look is a cosmetic loss, not a reason to fail a build.
    """
    for value in candidates:
        try:
            setattr(struct, attr, value)
            return value
        except TypeError:
            continue
    return None


def _world(name="World"):
    world = bpy.data.worlds.new(name)
    bpy.context.scene.world = world
    world.use_nodes = True
    return world


def gradient_world(top=(0.16, 0.17, 0.19), bottom=(0.03, 0.03, 0.035), strength=1.0):
    world = _world("Studio")
    nt = world.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    coord = nodes.new("ShaderNodeTexCoord")
    separate = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord.outputs["Generated"], separate.inputs["Vector"])

    ramp = nodes.new("ShaderNodeValToRGB")
    elements = ramp.color_ramp.elements
    elements[0].position, elements[0].color = 0.35, (*bottom, 1.0)
    elements[1].position, elements[1].color = 0.75, (*top, 1.0)
    links.new(separate.outputs["Z"], ramp.inputs["Fac"])

    background = nodes.new("ShaderNodeBackground")
    background.inputs["Strength"].default_value = strength
    links.new(ramp.outputs["Color"], background.inputs["Color"])

    output = nodes.new("ShaderNodeOutputWorld")
    links.new(background.outputs["Background"], output.inputs["Surface"])
    return world


def _area_light(name, location, energy, size, target=Vector((0, 0, 0)), color=(1, 1, 1)):
    data = bpy.data.lights.new(name, type="AREA")
    data.energy = energy
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    obj.location = location
    bpy.context.collection.objects.link(obj)
    _aim(obj, target)
    return obj


def _aim(obj, target):
    direction = Vector(target) - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def _rig(target, radius, lights):
    """Place lights on a sphere of `radius` around the subject.

    Light energy and size are quoted for radius=1 and scaled here: irradiance falls off
    with distance squared, so a fixed wattage aimed at a 10cm model from 40cm blows the
    render out and AgX desaturates the highlights to white — which reads as a bad
    material rather than as bad exposure.
    """
    placed = []
    for name, offset, energy, size, color in lights:
        placed.append(_area_light(
            name,
            Vector(target) + Vector(offset) * radius,
            energy * radius * radius,
            size * radius,
            target,
            color,
        ))
    return placed


def studio_lights(radius=1.4, target=Vector((0, 0, 0))):
    """Three-point setup: key from front-left-above, fill from right, rim from behind."""
    gradient_world()
    return _rig(target, radius, [
        ("Key",  (0.7, -1.0, 0.9),  250, 1.4, (1.0, 0.99, 0.97)),
        ("Fill", (-0.9, -0.7, 0.1),  60, 2.1, (0.82, 0.88, 1.0)),
        ("Rim",  (-0.6, 1.2, 0.7),  170, 1.1, (0.85, 0.93, 1.0)),
    ])


def underwater_lights(radius=1.4, target=Vector((0, 0, 0))):
    """Overhead shafts through blue-green water, which is how the model will actually
    be seen. Use this to judge the look; use studio light to judge the mesh."""
    gradient_world(top=(0.05, 0.16, 0.20), bottom=(0.01, 0.03, 0.05), strength=1.2)
    return _rig(target, radius, [
        ("Sun",     (0.25, -0.35, 1.6), 320, 1.7, (1.0, 0.97, 0.85)),
        ("Ambient", (-1.0, -0.5, 0.2),   50, 2.8, (0.40, 0.75, 0.95)),
        ("Bounce",  (0.2, 0.9, -0.8),    32, 2.1, (0.25, 0.50, 0.60)),
    ])


def scene_bounds(objects=None):
    objects = objects or [o for o in bpy.context.scene.objects if o.type == "MESH"]
    lo = Vector((float("inf"),) * 3)
    hi = Vector((float("-inf"),) * 3)
    for obj in objects:
        for corner in obj.bound_box:
            p = obj.matrix_world @ Vector(corner)
            lo = Vector((min(lo[i], p[i]) for i in range(3)))
            hi = Vector((max(hi[i], p[i]) for i in range(3)))
    return lo, hi


def make_camera(lens=85.0):
    data = bpy.data.cameras.new("Camera")
    data.lens = lens
    obj = bpy.data.objects.new("Camera", data)
    bpy.context.collection.objects.link(obj)
    bpy.context.scene.camera = obj
    return obj


def frame_orbit(camera, azimuth_deg, elevation_deg, center, radius, margin=1.30):
    """Place the camera on an orbit far enough out to fit `radius` in frame."""
    scene = bpy.context.scene
    sensor = camera.data.sensor_width
    aspect = scene.render.resolution_y / scene.render.resolution_x
    half_fov = math.atan((sensor * 0.5) / camera.data.lens)
    if aspect > 1.0:
        half_fov = math.atan(math.tan(half_fov) / aspect)
    distance = (radius * margin) / math.tan(half_fov)

    az = math.radians(azimuth_deg)
    el = math.radians(elevation_deg)
    offset = Vector((
        math.cos(el) * math.cos(az),
        math.cos(el) * math.sin(az),
        math.sin(el),
    )) * distance
    camera.location = Vector(center) + offset
    _aim(camera, center)


DEFAULT_VIEWS = [
    ("side", -90.0, 0.0),
    ("three-quarter", -55.0, 12.0),
    ("front", 0.0, 6.0),
    ("top", -90.0, 72.0),
    ("rear-quarter", -140.0, 14.0),
    ("below", -80.0, -40.0),
]


def render_views(out_dir, views=None, lens=85.0, margin=1.30, prefix="view"):
    """Render each named view and return the paths written, in order."""
    views = views or DEFAULT_VIEWS
    os.makedirs(out_dir, exist_ok=True)

    lo, hi = scene_bounds()
    center = (lo + hi) * 0.5
    radius = max((hi - lo).length * 0.5, 1e-4)

    camera = bpy.context.scene.camera or make_camera(lens)
    paths = []
    for index, (name, azimuth, elevation) in enumerate(views):
        frame_orbit(camera, azimuth, elevation, center, radius, margin)
        path = os.path.join(out_dir, f"{prefix}_{index:02d}_{name}.png")
        bpy.context.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        paths.append(path)
    return paths


def contact_sheet(paths, out_path, columns=3, label=True):
    """Tile renders into a single image so a whole turntable is one look.

    Returns None if ffmpeg is unavailable rather than failing the build — the
    individual renders are still on disk and remain the real output.
    """
    if not paths:
        return None
    rows = math.ceil(len(paths) / columns)
    listing = "\n".join(f"file '{os.path.abspath(p)}'" for p in paths)
    manifest = out_path + ".txt"
    with open(manifest, "w") as handle:
        handle.write(listing + "\n")

    command = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "concat", "-safe", "0", "-r", "1", "-i", manifest,
        "-frames:v", "1",
        "-filter_complex", f"tile={columns}x{rows}:padding=8:margin=8:color=0x111214",
        out_path,
    ]
    try:
        subprocess.run(command, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        print(f"[studio] contact sheet skipped: {exc}")
        return None
    finally:
        os.remove(manifest)
    return out_path
