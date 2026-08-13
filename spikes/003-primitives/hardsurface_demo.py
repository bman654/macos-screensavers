"""Render labelled contact sheets of the hard-surface primitives and materials.

    tools/blender/run.sh spikes/003-primitives/hardsurface_demo.py -- --set all
    tools/blender/run.sh spikes/003-primitives/hardsurface_demo.py -- --only rock

Each scene is one function under test, built two or three times with different arguments
so the parameter range is visible in a single image rather than inferred from one sample.
Material scenes are rendered under studio light *and* under `studio.underwater_lights`,
because a material that survives a neutral three-point rig can still fall apart in the
blue-green light it will actually be seen in.
"""

import argparse
import os
import subprocess
import sys

import bpy
from mathutils import Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender")]

from saverlib import studio  # noqa: E402
from saverlib.materials import assign  # noqa: E402
from saverlib.hardsurface import (  # noqa: E402
    beveled_box, displace, plank, revolve, rock,
)
from saverlib.surfaces import (  # noqa: E402
    BRASS, COPPER, IRON, RUST, VERDIGRIS,
    bone_material, glass_material, metal_material, rock_material, sand_material,
    wood_material,
)

_FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"

# One stop under `studio.setup_render`'s default. These props are large, matte and
# presented broadside to the key light, where a fish is small, curved and saturated: at
# -1.15 the seabed measures sRGB 0x86, which is dry-beach pale, and every albedo has to be
# falsified downward to compensate. At -2.0 it measures 0x65, which is wet sand, and the
# material values stay physically sensible. Pass --exposure -1.15 to compare like for like
# with the fish renders.
DEMO_EXPOSURE = -2.0

# Scenes lay their samples out along Y, so the camera has to sit on the X axis to see
# the whole row. An orbit that looks down the row shows one sample and a lot of
# foreshortening, which costs a render pass to notice.
STUDIO_VIEWS = [("row", -6.0, 12.0), ("three-quarter", -38.0, 20.0)]
WATER_VIEWS = [("row", 8.0, 8.0), ("low", -24.0, -14.0)]
MESH_VIEWS = [("row", -6.0, 12.0), ("three-quarter", -38.0, 20.0),
              ("end-on", -88.0, 8.0), ("top", -4.0, 74.0)]

# Anything standing on a seabed has to be looked at from above it; the default low angle
# renders the underside of the floor.
GROUND_STUDIO_VIEWS = [("row", -6.0, 26.0), ("three-quarter", -40.0, 38.0)]
GROUND_WATER_VIEWS = [("grazing", 10.0, 14.0), ("three-quarter", -34.0, 30.0)]
GROUND_SCENES = {"sand", "tank"}


# -- outlines shared by several scenes ------------------------------------------------

JUG = [(0.0, 0.0), (0.085, 0.015), (0.115, 0.09), (0.10, 0.16),
       (0.045, 0.215), (0.052, 0.245), (0.048, 0.262)]
HELMET = [(0.0, 0.205), (0.06, 0.20), (0.105, 0.165), (0.125, 0.10),
          (0.122, 0.042), (0.140, 0.028), (0.138, 0.010), (0.115, 0.0)]
AMPHORA = [(0.0, 0.0), (0.028, 0.008), (0.090, 0.075), (0.105, 0.155),
           (0.058, 0.255), (0.034, 0.300), (0.050, 0.335)]
CHIMNEY = [(0.105, 0.0), (0.098, 0.055), (0.064, 0.062), (0.058, 0.185),
           (0.078, 0.196), (0.070, 0.265)]
BOTTLE = [(0.0, 0.0), (0.038, 0.008), (0.042, 0.100), (0.038, 0.145),
          (0.016, 0.190), (0.015, 0.238), (0.020, 0.250)]
BONE = [(0.0, 0.0), (0.046, 0.014), (0.050, 0.048), (0.022, 0.092),
        (0.020, 0.235), (0.050, 0.288), (0.044, 0.322), (0.0, 0.336)]


def _row(objects, pitch):
    """Lay objects out along Y so one render shows the whole parameter sweep."""
    span = (len(objects) - 1) * pitch
    for index, obj in enumerate(objects):
        obj.location.y = index * pitch - span * 0.5
    return objects


# -- primitive scenes -----------------------------------------------------------------


def scene_beveled_box():
    boxes = [
        beveled_box("box_sharp", size=(0.30, 0.20, 0.16), bevel=0.008, segments=1),
        beveled_box("box_broken", size=(0.30, 0.20, 0.16), bevel=0.05, segments=3),
        beveled_box("box_rolled", size=(0.30, 0.20, 0.16), bevel=0.20, segments=6),
    ]
    _row(boxes, 0.30)
    return "bevel 0.008/1seg, 0.05/3seg, 0.20/6seg"


def scene_revolve():
    parts = [
        revolve("jug", JUG, cap_top=False, thickness=0.006),
        revolve("helmet", HELMET, cap_top=True),
        revolve("amphora", AMPHORA, cap_top=False, thickness=0.005),
        revolve("chimney", CHIMNEY, interpolation="linear", cap_top=False,
                thickness=0.008),
    ]
    _row(parts, 0.30)
    return "jug, helmet, amphora (smooth) + vent chimney (linear)"


def scene_plank():
    planks = [plank(f"plank_{s}", 0.70, 0.13, 0.020, seed=s) for s in range(4)]
    _row(planks, 0.155)
    return "same call, seeds 0-3: bow, cup and twist all seeded"


def scene_displace():
    parts = []
    for index, (strength, octaves) in enumerate(((0.0, 1), (0.05, 3), (0.14, 5))):
        box = beveled_box(f"crust_{index}", size=(0.24, 0.24, 0.24), bevel=0.06)
        if strength:
            displace(box, strength=strength, feature_size=0.45, octaves=octaves,
                     seed=4, subdivide=7)
        parts.append(box)
    _row(parts, 0.36)
    return "beveled box, subdivide=7: strength 0, 0.05/3oct, 0.14/5oct"


def scene_rock():
    rocks = [rock(f"rock_{i}", radius=0.13, angularity=a, seed=3, detail=4)
             for i, a in enumerate((0.0, 0.35, 0.7, 1.0))]
    _row(rocks, 0.30)
    return "angularity 0 (cobble) to 1 (shard), same seed"


# -- material scenes ------------------------------------------------------------------


def scene_wood():
    boards = _row([plank(f"board_{s}", 0.70, 0.14, 0.022, seed=s) for s in range(3)],
                  0.17)
    for board in boards:
        # A slight list, so the three boards are not all at exactly the same angle to the
        # key; steeper than this and the camera sees them edge-on and there is no grain
        # to look at at all.
        board.rotation_euler = (0.0, -0.10, 0.0)
    for board, (waterlog, algae) in zip(boards, ((0.05, 0.0), (0.55, 0.2), (0.95, 0.55))):
        assign(board, wood_material(f"wood_{waterlog}", size=0.7, waterlog=waterlog,
                                    plank_width=0.14, algae=algae, seed=int(waterlog * 9)))
    return "waterlog 0.05/0.55/0.95, algae 0/0.2/0.55"


def scene_metal():
    parts = _row([revolve(f"fitting_{i}", HELMET, cap_top=True) for i in range(4)], 0.30)
    settings = (
        ("polished brass", BRASS, 0.0, RUST, 0.0),
        ("brass fitting", BRASS, 0.35, RUST, 0.15),
        ("hull plate", IRON, 0.95, RUST, 0.30),
        ("bronze", COPPER, 0.70, VERDIGRIS, 0.25),
    )
    for obj, (label, base, corrosion, patina, algae) in zip(parts, settings):
        assign(obj, metal_material(label, size=0.28, base=base, corrosion=corrosion,
                                   patina=patina, algae=algae, seed=int(corrosion * 7)))
    return "brass 0.0 / brass 0.35 / iron+rust 0.95 / copper+verdigris 0.70"


def scene_bone():
    parts = _row([revolve(f"bone_{i}", BONE, segments=32) for i in range(3)], 0.16)
    for obj, (dirt, algae) in zip(parts, ((0.10, 0.0), (0.50, 0.15), (0.85, 0.45))):
        assign(obj, bone_material(f"bone_{dirt}", size=0.34, dirt=dirt, algae=algae,
                                  seed=int(dirt * 11)))
    return "dirt 0.10/0.50/0.85, algae 0/0.15/0.45"


def scene_rock_material():
    parts = _row([rock(f"stone_{i}", radius=0.14, angularity=a, seed=5 + i, detail=4)
                  for i, a in enumerate((0.1, 0.5, 0.9))], 0.32)
    settings = (
        ((0.030, 0.030, 0.032), (0.072, 0.070, 0.068), 0.20, 0.0),
        ((0.088, 0.078, 0.062), (0.205, 0.185, 0.155), 0.80, 0.20),
        ((0.044, 0.048, 0.044), (0.100, 0.104, 0.090), 0.45, 0.60),
    )
    for obj, (base, second, speckle, algae) in zip(parts, settings):
        assign(obj, rock_material(f"stone_{speckle}", size=0.28, base=base,
                                  secondary=second, speckle=speckle, algae=algae,
                                  seed=int(speckle * 13)))
    return "basalt / speckled granite / colonised, algae 0/0.2/0.6"


def scene_glass():
    parts = _row([revolve(f"bottle_{i}", BOTTLE, cap_top=False, thickness=0.0035)
                  for i in range(3)], 0.12)
    settings = (
        ((0.105, 0.285, 0.155), 0.10, 0.0),
        ((0.105, 0.285, 0.155), 0.45, 0.25),
        ((0.155, 0.070, 0.020), 0.30, 0.10),
    )
    for obj, (tint, grime, algae) in zip(parts, settings):
        assign(obj, glass_material(f"glass_{grime}", size=0.25, tint=tint, grime=grime,
                                   algae=algae, seed=int(grime * 17)))
    return "green grime 0.10 / green grime 0.45+algae / brown bottle"


def scene_sand():
    floor = _ground(size=1.2, subdivisions=140, relief=0.012, seed=6)
    assign(floor, sand_material("seabed", size=1.2, ripple_spacing=0.07, algae=0.10))
    props = _row([rock("pebble_0", radius=0.05, angularity=0.15, seed=8, detail=3),
                  rock("pebble_1", radius=0.04, angularity=0.6, seed=9, detail=3)], 0.18)
    stone = rock_material("pebble_stone", size=0.09, algae=0.25)
    for obj in props:
        obj.location.z = 0.03
        assign(obj, stone)
    return "1.2 m seabed, ripple spacing 7 cm, two pebbles for scale"


def scene_tank():
    """Everything together, which is the only honest test of a set of materials."""
    floor = _ground(size=1.6, subdivisions=160, relief=0.014, seed=6)
    assign(floor, sand_material("seabed", size=1.6, ripple_spacing=0.075, algae=0.15))

    boards = _row([plank(f"hull_{s}", 0.62, 0.13, 0.020, seed=s) for s in range(3)], 0.14)
    hull = wood_material("hull", size=0.62, waterlog=0.85, plank_width=0.13, algae=0.45)
    for index, board in enumerate(boards):
        board.location.x = -0.32
        board.location.z = 0.055 + index * 0.004
        board.rotation_euler = (0.0, 0.10, 0.35)
        assign(board, hull)

    helmet = revolve("dive_helmet", HELMET, cap_top=True)
    helmet.location = Vector((0.20, -0.26, 0.02))
    assign(helmet, metal_material("helmet_brass", size=0.28, base=BRASS, corrosion=0.55,
                                  patina=VERDIGRIS, algae=0.35))

    jug = revolve("amphora", AMPHORA, cap_top=False, thickness=0.005)
    jug.location = Vector((0.26, 0.10, 0.01))
    jug.rotation_euler = (0.0, 1.15, 0.6)
    assign(jug, rock_material("terracotta", size=0.34, base=(0.105, 0.048, 0.024),
                              secondary=(0.185, 0.098, 0.055), speckle=0.2, algae=0.4))

    bottle = revolve("bottle", BOTTLE, cap_top=False, thickness=0.0035)
    bottle.location = Vector((-0.02, 0.30, 0.01))
    assign(bottle, glass_material("bottle", size=0.25, grime=0.35, algae=0.2))

    rib = revolve("rib", BONE, segments=32)
    rib.location = Vector((-0.05, -0.08, 0.03))
    rib.rotation_euler = (0.0, 1.45, 0.2)
    assign(rib, bone_material("rib", size=0.34, dirt=0.7, algae=0.3))

    boulder = rock("boulder", radius=0.15, angularity=0.55, seed=12, detail=4)
    boulder.location = Vector((-0.36, 0.34, 0.06))
    assign(boulder, rock_material("boulder", size=0.30, algae=0.55, seed=2))

    return "sand, waterlogged hull, brass helmet, amphora, bottle, bone, boulder"


def _ground(size, subdivisions, relief, seed):
    """A displaced plane. Sand is the one surface here that is mostly its material."""
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=subdivisions,
                                    y_subdivisions=subdivisions, size=size)
    floor = bpy.context.active_object
    floor.name = "seabed"
    for polygon in floor.data.polygons:
        polygon.use_smooth = True
    displace(floor, strength=relief, feature_size=0.35, octaves=4, seed=seed)
    return floor


PRIMITIVES = {
    "beveled_box": scene_beveled_box,
    "revolve": scene_revolve,
    "plank": scene_plank,
    "displace": scene_displace,
    "rock": scene_rock,
}

MATERIALS = {
    "wood": scene_wood,
    "metal": scene_metal,
    "bone": scene_bone,
    "rock_material": scene_rock_material,
    "glass": scene_glass,
    "sand": scene_sand,
    "tank": scene_tank,
}


# -- rendering ------------------------------------------------------------------------


def _label(path, caption, out_dir):
    """Burn a caption into a render, so a contact sheet is self-describing.

    Falls back to the unlabelled image if ffmpeg cannot do it, for the same reason
    `studio.contact_sheet` does: the render is the real output and a missing caption is
    not a reason to fail a build. The caption goes through a file rather than the filter
    string because drawtext treats ':' and ',' as syntax.
    """
    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(out_dir, os.path.basename(path))
    text_path = target + ".txt"
    with open(text_path, "w") as handle:
        handle.write(caption + "\n")
    draw = (f"drawtext=fontfile={_FONT}:textfile={text_path}:x=10:y=8:fontsize=17:"
            "fontcolor=0xF2F2F2:box=1:boxcolor=0x000000B4:boxborderw=6")
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path,
                        "-vf", draw, target], check=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        print(f"[demo] label skipped: {exc}")
        return path
    finally:
        os.remove(text_path)
    return target


def _light(kind, margin=2.2):
    for light in [o for o in bpy.context.scene.objects if o.type == "LIGHT"]:
        bpy.data.objects.remove(light, do_unlink=True)
    lo, hi = studio.scene_bounds()
    centre = (lo + hi) * 0.5
    # Rig radius follows the subject: `studio._rig` scales energy by radius squared, so a
    # rig sized for a fish blows a half-metre prop to white and the material reads broken.
    radius = max((hi - lo).length * 0.5, 1e-3) * margin
    (studio.studio_lights if kind == "studio" else studio.underwater_lights)(
        radius=radius, target=centre)


def _view_name(path):
    return os.path.splitext(os.path.basename(path))[0].split("_", 2)[-1]


def render_scene(name, builder, out_dir, samples, mesh_only=False,
                 exposure=DEMO_EXPOSURE):
    studio.reset_scene()
    studio.setup_render(resolution=(900, 700), samples=samples, exposure=exposure)
    note = builder() or ""
    # Object matrices are lazy: without this, `scene_bounds` still sees every object at
    # the origin and frames the shot for one sample instead of the whole row.
    bpy.context.view_layer.update()

    os.makedirs(out_dir, exist_ok=True)
    label_dir = os.path.join(out_dir, "labelled")
    rendered = []

    if mesh_only:
        passes = [("studio", MESH_VIEWS)]
    elif name in GROUND_SCENES:
        passes = [("studio", GROUND_STUDIO_VIEWS), ("water", GROUND_WATER_VIEWS)]
    else:
        passes = [("studio", STUDIO_VIEWS), ("water", WATER_VIEWS)]

    for kind, views in passes:
        _light(kind)
        # `render_views` frames the bounding *sphere*, and a row of samples is wide and
        # flat, so the default margin leaves most of the frame empty.
        for path in studio.render_views(out_dir, views=views, margin=1.15,
                                        prefix=f"{name}_{kind}"):
            caption = f"{name} — {note}  [{_view_name(path)}, {kind}]"
            rendered.append(_label(path, caption, label_dir))

    sheet = studio.contact_sheet(rendered, os.path.join(out_dir, f"{name}_sheet.png"),
                                 columns=2)
    print(f"[demo] {name}: {sheet}")
    return sheet


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", dest="group", default="all",
                        choices=["all", "primitives", "materials"])
    parser.add_argument("--only", default=None, help="render a single scene by name")
    parser.add_argument("--out", default=os.path.join(_REPO, "build", "hardsurface"))
    parser.add_argument("--samples", type=int, default=64)
    parser.add_argument("--exposure", type=float, default=DEMO_EXPOSURE,
                        help=f"default {DEMO_EXPOSURE}; pass -1.15 to match the rest of "
                             "the repo")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)

    scenes = {}
    if args.group in ("all", "primitives"):
        scenes.update({k: (v, True) for k, v in PRIMITIVES.items()})
    if args.group in ("all", "materials"):
        scenes.update({k: (v, False) for k, v in MATERIALS.items()})
    if args.only:
        chosen = {**{k: (v, True) for k, v in PRIMITIVES.items()},
                  **{k: (v, False) for k, v in MATERIALS.items()}}
        if args.only not in chosen:
            raise SystemExit(f"unknown scene '{args.only}'; have {sorted(chosen)}")
        scenes = {args.only: chosen[args.only]}

    for name, (builder, mesh_only) in scenes.items():
        render_scene(name, builder, args.out, args.samples, mesh_only=mesh_only,
                     exposure=args.exposure)


if __name__ == "__main__":
    main()
