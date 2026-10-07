"""Render the review sheets that decide whether the library reads in the game.

A studio contact sheet (`build_model.py --render`) judges one mesh. These judge the set,
the way the saver will show it: from straight overhead, small, on a muted paper-green
ground with a sun casting shadows, every model of a family side by side.

    tools/blender/run.sh Savers/OrigamiDogfight/Models/review.py -- --sheet planes
    tools/blender/run.sh Savers/OrigamiDogfight/Models/review.py -- --sheet all

Writes into `build/origami-models/`:

- `planes_overhead.png` — the five planes nose-up at ~100 px each (top row: each scaled to
  the same size; bottom row: true relative size). The silhouette test.
  `planes_overhead_x4.png` is the same pixels enlarged for looking at, not resampled.
- `planes_overhead_lined_large.png` — a lined-notebook texture through the sheet UVs, large
  enough to see the rules cross the folds; `planes_overhead_lined.png` at game size.
- `<family>.png` (labelled studio lineup) and `<family>_overhead.png` (small, from above at
  the game's slight tilt; `_x4`/`_x6` enlarged) for planes, projectiles, scenery and fire.
"""

import argparse
import math
import os
import sys

import bpy
from mathutils import Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import build_model  # noqa: E402  (puts saverlib and origami on sys.path)
from origami import CATALOG  # noqa: E402
from origami.mesh import TEXTURE_DIR, flat_material, lined_paper_image, textured_material  # noqa: E402
from saverlib import studio  # noqa: E402

_OUT = os.path.join(build_model._REPO, "build", "origami-models")
GROUND = "#6f8a5e"

FAMILIES = {
    "planes": ("plane",),
    "projectiles": ("projectile",),
    "scenery": ("tree", "rock", "house", "boat"),
    "fire": ("fire", "smoke"),
}
_PLANE_ORDER = ["dart", "interceptor", "glider", "bomber", "stunt"]


def _names(family):
    kinds = FAMILIES[family]
    names = [name for name, model in CATALOG.items() if model.kind in kinds]
    order = {name: i for i, name in enumerate(_PLANE_ORDER)}
    return sorted(names, key=lambda n: (kinds.index(CATALOG[n].kind), order.get(n, 99), n))


def _fresh(resolution, samples=64, exposure=-1.0):
    studio.reset_scene()
    return studio.setup_render(resolution=resolution, samples=samples, exposure=exposure)


def _place(name):
    """Build one model into the current scene, contract-checked; returns (root, bounds).

    The root is renamed once built, so the same model can be placed again beside it.
    """
    root, _, bounds = build_model.build(CATALOG[name])
    root.name = f"review_{name}_{len(bpy.data.objects)}"
    return root, bounds


def _label(text, location, size, colour="#e8e4da"):
    curve = bpy.data.curves.new(f"label_{text}", type="FONT")
    curve.body = text
    curve.align_x = "CENTER"
    curve.size = size
    obj = bpy.data.objects.new(f"label_{text}", curve)
    obj.location = location
    obj.data.materials.append(flat_material(f"label_ink_{colour}", colour, emission=1.0))
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _ground(size, z=0.0):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0.0, 0.0, z))
    plane = bpy.context.active_object
    plane.name = "ground"
    plane.data.materials.append(flat_material("ground_paper", GROUND, roughness=0.95))
    return plane


def _sun(strength=4.0, elevation=58.0, azimuth=135.0, angle=2.0):
    data = bpy.data.lights.new("sun", type="SUN")
    data.energy = strength
    data.angle = math.radians(angle)
    sun = bpy.data.objects.new("sun", data)
    el, az = math.radians(elevation), math.radians(azimuth)
    direction = Vector((math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)))
    sun.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    bpy.context.scene.collection.objects.link(sun)
    world = bpy.data.worlds.new("sky")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.6, 0.65, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
    bpy.context.scene.world = world
    return sun


def _ortho_camera(centre, width):
    data = bpy.data.cameras.new("overhead")
    data.type = "ORTHO"
    data.ortho_scale = width
    data.clip_start = 0.01
    data.clip_end = 100.0
    camera = bpy.data.objects.new("overhead", data)
    camera.location = (centre[0], centre[1], 20.0)
    camera.rotation_euler = (0.0, 0.0, 0.0)   # straight down, +Y up the image
    bpy.context.scene.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    return camera


def _render(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print(f"[review] {path}")
    return path


def _enlarge(path, factor):
    """Nearest-neighbour enlargement, so a 100 px silhouette can be inspected as exactly
    the pixels the test produced."""
    image = bpy.data.images.load(path)
    width, height = image.size
    big = bpy.data.images.new(os.path.basename(path) + "_big", width * factor, height * factor)
    import numpy as np
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)
    pixels = pixels.repeat(factor, axis=0).repeat(factor, axis=1)
    big.pixels.foreach_set(pixels.ravel())
    out = path.replace(".png", f"_x{factor}.png")
    big.filepath_raw = out
    big.file_format = "PNG"
    big.save()
    print(f"[review] {out}")


def _planform(bounds):
    lo, hi = bounds
    return max(hi.x - lo.x, hi.y - lo.y)


def _nose_up(root, location, scale, altitude=0.0):
    """Turn a model so its nose (+X) points up the overhead image (+Y)."""
    root.rotation_euler = (0.0, 0.0, math.pi * 0.5)
    root.scale = (scale, scale, scale)
    root.location = (location[0], location[1], altitude)


def planes_overhead(lined=False, pixels_per_unit=100, spacing=1.45):
    names = _names("planes")
    columns = len(names)
    width_units = columns * spacing
    resolution = (int(width_units * pixels_per_unit), int(2 * spacing * pixels_per_unit))
    _fresh(resolution, samples=32, exposure=-0.6)
    lined_material = None
    if lined:
        image = lined_paper_image("review_lined", os.path.join(TEXTURE_DIR, "review_lined.png"),
                                  size=(864, 1118))
        lined_material = textured_material("paper_lined_review", image)

    largest = None
    rows = []
    for row in range(2):
        placed = []
        for name in names:
            root, bounds = _place(name)
            placed.append((root, bounds))
        rows.append(placed)
        if largest is None:
            largest = max(_planform(b) for _, b in placed)
    for row, placed in enumerate(rows):
        y = (0.5 - row) * spacing
        for column, (root, bounds) in enumerate(placed):
            x = (column - (columns - 1) * 0.5) * spacing
            # Top row: every plane the same size on screen. Bottom: their true sizes.
            scale = 1.0 / _planform(bounds) if row == 0 else 1.0 / largest
            _nose_up(root, (x, y), scale, altitude=0.35)
            if lined_material is not None:
                root.data.materials[0] = lined_material
    _ground(width_units * 4.0)
    _sun()
    _ortho_camera((0.0, 0.0), width_units)
    name = "planes_overhead" + ("_lined" if lined else "") + ("_large" if pixels_per_unit > 100 else "")
    return _render(os.path.join(_OUT, f"{name}.png"))


def family_overhead(family, pixels_per_unit, spacing=1.5, altitude=0.0, tilt=0.0, suffix=""):
    """Every model of a family at the same on-screen size, from above, on the ground."""
    names = _names(family)
    columns = min(len(names), 9)
    rows = math.ceil(len(names) / columns)
    width_units = columns * spacing
    resolution = (int(width_units * pixels_per_unit), int(rows * spacing * pixels_per_unit))
    _fresh(resolution, samples=32, exposure=-0.6)
    for index, name in enumerate(names):
        root, bounds = _place(name)
        column, row = index % columns, index // columns
        x = (column - (columns - 1) * 0.5) * spacing
        y = ((rows - 1) * 0.5 - row) * spacing
        lo, hi = bounds
        scale = 1.0 / max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        root.rotation_euler = (0.0, 0.0, math.pi * 0.5)
        root.scale = (scale,) * 3
        root.location = (x, y, altitude)
    _ground(width_units * 4.0)
    _sun()
    camera = _ortho_camera((0.0, 0.0), width_units)
    if tilt:
        camera.rotation_euler = (math.radians(tilt), 0.0, 0.0)
        camera.location = (0.0, -20.0 * math.sin(math.radians(tilt)), 20.0 * math.cos(math.radians(tilt)))
    return _render(os.path.join(_OUT, f"{family}_overhead{suffix}.png"))


def family_studio(family, spacing=1.6):
    """A labelled three-quarter lineup under the studio rig: judge the models themselves."""
    names = _names(family)
    columns = min(len(names), 5)
    rows = math.ceil(len(names) / columns)
    _fresh((360 * columns, 330 * rows), samples=48, exposure=-3.0)
    for index, name in enumerate(names):
        root, bounds = _place(name)
        column, row = index % columns, index // columns
        lo, hi = bounds
        scale = 1.0 / max((hi - lo).length * 0.75, 1e-6)
        x = (column - (columns - 1) * 0.5) * spacing
        y = ((rows - 1) * 0.5 - row) * spacing * 1.1
        root.scale = (scale,) * 3
        root.location = (x, y, 0.0)
        root.rotation_euler = (0.0, 0.0, math.radians(-30.0))
        label = _label(name, (x, y - 0.62, 0.0), 0.16)
        label.rotation_euler = (math.radians(40.0), 0.0, 0.0)
    data = bpy.data.cameras.new("studio")
    data.type = "ORTHO"
    data.ortho_scale = columns * spacing * 1.02
    camera = bpy.data.objects.new("studio", data)
    camera.location = (0.0, -14.0, 11.7)
    camera.rotation_euler = (math.radians(50.0), 0.0, 0.0)
    bpy.context.scene.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    studio.studio_lights(radius=columns * spacing * 1.2)
    return _render(os.path.join(_OUT, f"{family}.png"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sheet", required=True,
                        choices=["planes", "projectiles", "scenery", "fire", "all"])
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)
    sheets = ["planes", "projectiles", "scenery", "fire"] if args.sheet == "all" else [args.sheet]

    for sheet in sheets:
        if not _names(sheet):
            print(f"[review] Warning: no {sheet} in the catalog yet")
            continue
        if sheet == "planes":
            _enlarge(planes_overhead(pixels_per_unit=100), 4)
            planes_overhead(lined=True, pixels_per_unit=320)
            _enlarge(planes_overhead(lined=True, pixels_per_unit=100), 4)
            family_studio("planes")
        elif sheet == "projectiles":
            family_studio("projectiles")
            _enlarge(family_overhead("projectiles", 18, altitude=0.4), 6)
        elif sheet == "scenery":
            family_studio("scenery")
            _enlarge(family_overhead("scenery", 32, tilt=12.0), 4)
            family_overhead("scenery", 120, tilt=12.0, suffix="_large")
        elif sheet == "fire":
            family_studio("fire")
            _enlarge(family_overhead("fire", 48, tilt=12.0), 4)
            family_overhead("fire", 160, tilt=12.0, suffix="_large")


if __name__ == "__main__":
    main()
