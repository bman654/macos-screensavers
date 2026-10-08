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
- `tanks_overhead.png` — every tank straight down at game size (40-80 px), at true relative
  size, in two sides' colours with the turret at two angles; `_x4` enlarged, `_large` at
  four times the pixels. `tanks_turret.png` — each tank large with its turret at 0, 45 and
  90 degrees about a pin marking the pivot: the turret must turn about the pin.
- `pencil_pitch.png` — the pencil at game size climbing toward the camera and falling back,
  since that is how a tank's shot is seen; `_x6` enlarged.
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
    "tanks": ("tank",),
    "v3": ("bird", "crate", "parachute", "landmark", "animal", "vehicle", "building"),
}
# Team papers from the runtime's palette (`PaperPalette.plain`), for tinting a tank's paper.
SIDES = {"red": "#e0332e", "blue": "#2e6bdb"}
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

    Every object in it is renamed once built, so the same model can be placed again beside
    it.
    """
    root, _, bounds = build_model.build(CATALOG[name])
    # Every object, not only the root: a second tank built beside the first would otherwise
    # find `turret` taken, be handed `turret.001`, and fail its own contract.
    prefix = f"review_{len(bpy.data.objects)}_"
    for obj in [root, *root.children_recursive]:
        obj.name = prefix + obj.name
    return root, bounds


def _child(root, name):
    return next(obj for obj in root.children_recursive if obj.name.endswith("_" + name))


def _tint(root, colour):
    """Paint the paper the runtime would replace, the way a side's plain paper looks."""
    team = flat_material(f"side_{colour}", colour, roughness=0.9)
    for obj in [root, *root.children_recursive]:
        if obj.type == "MESH":
            for slot in obj.material_slots:
                if slot.material is not None and slot.material.name == "paper":
                    slot.material = team


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


def family_studio(family, spacing=1.6, out=None):
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
    return _render(os.path.join(_OUT, out or f"{family}.png"))


def tanks_overhead(pixels_per_metre=380, spacing=0.26, suffix=""):
    """Both tanks straight down at true relative size, nose up the image: per row a tank in
    two sides' colours, its turret straight ahead and turned."""
    names = _names("tanks")
    cells = [(colour, angle) for colour in SIDES.values() for angle in (0.0, 60.0)]
    width, height = len(cells) * spacing, len(names) * spacing
    _fresh((round(width * pixels_per_metre), round(height * pixels_per_metre)),
           samples=32, exposure=-0.6)
    for row, name in enumerate(names):
        for column, (colour, angle) in enumerate(cells):
            root, _ = _place(name)
            _tint(root, colour)
            _child(root, "turret").rotation_euler.z = math.radians(angle)
            root.rotation_euler = (0.0, 0.0, math.pi * 0.5)
            root.location = ((column - (len(cells) - 1) * 0.5) * spacing,
                             ((len(names) - 1) * 0.5 - row) * spacing, 0.0)
    _ground(width * 4.0)
    _sun()
    _ortho_camera((0.0, 0.0), width)
    return _render(os.path.join(_OUT, f"tanks_overhead{suffix}.png"))


def tanks_turret(pixels_per_metre=1400, spacing=0.26):
    """Each tank with its turret at 0, 45 and 90 degrees; a pin stands on the pivot."""
    names = _names("tanks")
    angles = (0.0, 45.0, 90.0)
    width, height = len(angles) * spacing, len(names) * spacing
    _fresh((round(width * pixels_per_metre), round(height * pixels_per_metre)),
           samples=32, exposure=-0.6)
    pin = flat_material("review_pin", "#ffe14d", emission=2.0)
    for row, name in enumerate(names):
        for column, angle in enumerate(angles):
            root, _ = _place(name)
            _tint(root, SIDES["red"])
            turret = _child(root, "turret")
            turret.rotation_euler.z = math.radians(angle)
            root.rotation_euler = (0.0, 0.0, math.pi * 0.5)
            root.location = ((column - (len(angles) - 1) * 0.5) * spacing,
                             ((len(names) - 1) * 0.5 - row) * spacing, 0.0)
            bpy.context.view_layer.update()
            pivot = turret.matrix_world.translation
            bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.0016, depth=0.05,
                                                location=(pivot.x, pivot.y, pivot.z + 0.025))
            bpy.context.active_object.data.materials.append(pin)
    _ground(width * 4.0)
    _sun()
    _ortho_camera((0.0, 0.0), width)
    return _render(os.path.join(_OUT, "tanks_turret.png"))


def pencil_pitch(pixels_per_unit=18, spacing=1.5):
    """The pencil at game size as a tank's shot is seen: level, climbing toward the camera
    at 45 and 75 degrees, then falling back eraser-up at 75 and 45."""
    pitches = (0.0, 45.0, 75.0, -75.0, -45.0)
    width = len(pitches) * spacing
    _fresh((round(width * pixels_per_unit), round(spacing * pixels_per_unit)),
           samples=32, exposure=-0.6)
    for column, pitch in enumerate(pitches):
        root, bounds = _place("pencil")
        lo, hi = bounds
        root.scale = (1.0 / max(hi - lo),) * 3
        # Pitched about the pencil's own left (+pitch lifts the nose), then turned nose-up
        # the image: XYZ order applies the Y turn before the Z one.
        root.rotation_euler = (0.0, math.radians(-pitch), math.pi * 0.5)
        root.location = ((column - (len(pitches) - 1) * 0.5) * spacing, 0.0, 0.4)
    _ground(width * 4.0)
    _sun()
    _ortho_camera((0.0, 0.0), width)
    return _render(os.path.join(_OUT, "pencil_pitch.png"))


# ---- v3: the new models at the size the game draws them --------------------------------

# A 16:9 frame shows 4.6 m of the world across 2056 px (ViewRig.arenaArea), and the runtime
# draws landscape props at a fiftieth of their authored size (Scenery.dioramaScale).
# Desk-sized models (crane, crate, parachute) are shown at their authored size, as the planes
# are drawn at about theirs.
GAME_PX_PER_METRE = 2056 / 4.6
DIORAMA = 0.02
CRANE_PAPERS = ("#ee9aae", "#7fb3dc")


def _pose(root, location, scale=1.0, yaw=90.0):
    """Nose up the image by default: +X to +Y."""
    root.rotation_euler = (0.0, 0.0, math.radians(yaw))
    root.scale = (scale,) * 3
    root.location = location


def v3_overhead(pixels_per_metre=GAME_PX_PER_METRE, tilt=0.0, suffix=""):
    """Every v3 model from above at its in-game size on the game's ground under its sun.

    Top row, in the air: two cranes, wings level and lifted 40 degrees; a crate under its
    parachute; a crate that has landed. Bottom row, on the ground: the windmill with its
    sails at 0 and 45 degrees, a few sheep, two cars in two sides' papers, a hangar in a
    side's paper with its open end up the image.
    """
    width, height = 1.56, 0.62
    _fresh((round(width * pixels_per_metre), round(height * pixels_per_metre)),
           samples=48, exposure=-0.6)
    top, bottom = 0.15, -0.14
    for x, lift, paper in ((-0.62, 0.0, CRANE_PAPERS[0]), (-0.38, 40.0, CRANE_PAPERS[1])):
        root, _ = _place("crane")
        _tint(root, paper)
        _child(root, "wing_l").rotation_euler.x = math.radians(lift)
        _child(root, "wing_r").rotation_euler.x = math.radians(-lift)
        _pose(root, (x, top, 0.35), yaw=100.0)
    crate, crate_bounds = _place("supply_crate")
    _pose(crate, (-0.12, top, 0.22), yaw=15.0)
    chute, _ = _place("parachute")
    _pose(chute, (-0.12, top, 0.22 + crate_bounds[1].z), yaw=15.0)
    landed, _ = _place("supply_crate")
    _pose(landed, (0.06, top, 0.0), yaw=-20.0)
    for x, angle in ((0.26, 0.0), (0.48, 45.0)):
        mill, _ = _place("windmill")
        _child(mill, "blades").rotation_euler.x = math.radians(angle)
        _pose(mill, (x, top, 0.0), scale=DIORAMA, yaw=60.0)
    for dx, dy, yaw in ((-0.03, 0.0, 70.0), (0.0, 0.03, 140.0), (0.035, -0.01, 20.0),
                        (0.01, -0.035, -100.0)):
        sheep, _ = _place("sheep")
        _pose(sheep, (-0.58 + dx, bottom + dy, 0.0), scale=DIORAMA, yaw=yaw)
    for x, colour, yaw in ((-0.36, SIDES["red"], 90.0), (-0.22, SIDES["blue"], 30.0)):
        car, _ = _place("car")
        _tint(car, colour)
        _pose(car, (x, bottom, 0.0), scale=DIORAMA, yaw=yaw)
    hangar, _ = _place("hangar")
    _tint(hangar, SIDES["red"])
    _pose(hangar, (0.05, bottom, 0.0), scale=DIORAMA)
    hangar_b, _ = _place("hangar")
    _tint(hangar_b, SIDES["blue"])
    _pose(hangar_b, (0.38, bottom, 0.0), scale=DIORAMA, yaw=-30.0)
    _ground(width * 4.0)
    _sun()
    camera = _ortho_camera((0.0, 0.0), width)
    if tilt:
        # The game's camera leans toward the top of the screen; tilting the view about X
        # shows the faces that look down the image, as the game does.
        camera.rotation_euler = (math.radians(tilt), 0.0, 0.0)
        camera.location = (0.0, -20.0 * math.sin(math.radians(tilt)),
                           20.0 * math.cos(math.radians(tilt)))
    return _render(os.path.join(_OUT, f"v3_overhead{suffix}.png"))


def v3_motion(pixels_per_metre=3 * GAME_PX_PER_METRE):
    """The parts that move, larger: the crane's wings from -30 to +55 degrees of lift and
    the windmill's sails a quarter turn in steps, each beside a pin on its pivot."""
    lifts, sails = (-30.0, 0.0, 30.0, 55.0), (0.0, 22.5, 45.0, 67.5)
    width, height = 1.0, 0.6
    _fresh((round(width * pixels_per_metre), round(height * pixels_per_metre)),
           samples=48, exposure=-0.6)
    pin = flat_material("review_pin", "#ffe14d", emission=2.0)

    def mark(node):
        bpy.context.view_layer.update()
        p = node.matrix_world.translation
        bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.0015, depth=0.06,
                                            location=(p.x, p.y, p.z + 0.03))
        bpy.context.active_object.data.materials.append(pin)

    for k, lift in enumerate(lifts):
        root, _ = _place("crane")
        _child(root, "wing_l").rotation_euler.x = math.radians(lift)
        _child(root, "wing_r").rotation_euler.x = math.radians(-lift)
        # Turned to face the camera, a little from above, so the lift shows as an angle:
        # nose toward the lens, up the image, left wing to the right.
        root.rotation_euler = (0.0, math.radians(-70.0), math.radians(-90.0))
        root.location = (-0.375 + 0.25 * k, 0.15, 0.3)
        mark(_child(root, "wing_l"))
    for k, angle in enumerate(sails):
        mill, _ = _place("windmill")
        _child(mill, "blades").rotation_euler.x = math.radians(angle)
        mill.rotation_euler = (0.0, math.radians(-70.0), math.radians(-90.0))
        mill.scale = (DIORAMA,) * 3
        mill.location = (-0.375 + 0.25 * k, -0.25, 0.12)
        mark(_child(mill, "blades"))
    _ground(width * 4.0)
    _sun()
    _ortho_camera((0.0, 0.0), width)
    return _render(os.path.join(_OUT, "v3_motion.png"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sheet", required=True,
                        choices=[*FAMILIES, "all"])
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)
    sheets = list(FAMILIES) if args.sheet == "all" else [args.sheet]

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
            if "pencil" in CATALOG:
                _enlarge(pencil_pitch(), 6)
        elif sheet == "scenery":
            family_studio("scenery")
            _enlarge(family_overhead("scenery", 32, tilt=12.0), 4)
            family_overhead("scenery", 120, tilt=12.0, suffix="_large")
        elif sheet == "fire":
            family_studio("fire")
            _enlarge(family_overhead("fire", 48, tilt=12.0), 4)
            family_overhead("fire", 160, tilt=12.0, suffix="_large")
        elif sheet == "v3":
            family_studio("v3", out="v3_studio.png")
            _enlarge(v3_overhead(), 4)
            v3_overhead(tilt=11.0, suffix="_tilt")
            v3_overhead(pixels_per_metre=4 * GAME_PX_PER_METRE, suffix="_large")
            v3_motion()
        elif sheet == "tanks":
            family_studio("tanks")
            _enlarge(tanks_overhead(), 4)
            tanks_overhead(pixels_per_metre=1520, suffix="_large")
            tanks_turret()


if __name__ == "__main__":
    main()
