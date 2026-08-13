"""Render proof sheets for swept tubes and deterministic branching structures."""

import argparse
import math
import os
import subprocess
import sys

import bpy
from mathutils import Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "blender"))

from saverlib import studio  # noqa: E402
from saverlib.tube import BranchSpec, SweptTube, build_branching  # noqa: E402


CASES = ("curved", "section", "staghorn", "sea_fan", "kelp")


def _material(name, color, roughness=0.5):
    material = bpy.data.materials.new(name)
    material.diffuse_color = (*color, 1.0)
    material.use_nodes = True
    principled = next(
        node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"
    )
    principled.inputs["Base Color"].default_value = (*color, 1.0)
    principled.inputs["Roughness"].default_value = roughness
    return material


def _assign(objects, material):
    for obj in objects:
        obj.data.materials.append(material)


def _curved_tube():
    def path(t):
        centered = t - 0.5
        return Vector((
            0.62 * math.sin(2.0 * math.pi * centered),
            0.34 * math.sin(4.0 * math.pi * centered),
            3.2 * centered,
        ))

    tube = SweptTube(
        path,
        radius=[(0.0, 0.24), (0.42, 0.19), (0.76, 0.13), (1.0, 0.055)],
        rings=72,
        segments=20,
        section=(1.0, 0.78),
        rounded_caps=True,
        cap_rings=5,
    )
    obj = tube.build("Inflection_Tube", subsurf=1)
    _assign([obj], _material("Warm coral", (0.68, 0.18, 0.105), 0.42))
    return [obj]


def _noncircular_tube():
    def path(t):
        return Vector((
            0.22 * math.sin(2.0 * math.pi * t),
            0.10 * math.sin(math.pi * t),
            3.0 * (t - 0.5),
        ))

    tube = SweptTube(
        path,
        radius=[(0.0, 0.27), (0.72, 0.23), (1.0, 0.10)],
        rings=64,
        segments=20,
        section=(1.75, 0.32),
        exponent=3.2,
        twist=math.radians(105.0),
        rounded_caps=True,
        cap_rings=5,
    )
    obj = tube.build("Flattened_Superellipse", subsurf=1)
    _assign([obj], _material("Kelp gold", (0.40, 0.52, 0.075), 0.46))
    return [obj]


def _staghorn():
    result = build_branching(
        BranchSpec(
            trunk_length=2.15,
            radius=0.19,
            children_per_split=2,
            split_angle=math.radians(31.0),
            split_angle_jitter=math.radians(5.0),
            length_decay=0.66,
            radius_decay=0.62,
            depth=3,
            curvature=0.055,
            droop=-0.025,
            seed=731,
            planarity=0.12,
            split_positions=(0.88,),
            tip_radius_ratio=0.88,
            junction_overlap=1.05,
        ),
        name="Staghorn",
        rings=18,
        segments=14,
        subsurf=1,
    )
    obj = result.join("Staghorn_Coral", weld_voxel_size=0.010)
    _assign([obj], _material("Staghorn ochre", (0.72, 0.31, 0.12), 0.56))
    return [obj]


def _sea_fan():
    result = build_branching(
        BranchSpec(
            trunk_length=2.1,
            radius=0.105,
            children_per_split=2,
            split_angle=math.radians(37.0),
            split_angle_jitter=math.radians(4.0),
            length_decay=0.68,
            radius_decay=0.66,
            depth=4,
            curvature=0.07,
            droop=0.018,
            seed=4129,
            planarity=0.97,
            split_positions=(0.86,),
            tip_radius_ratio=0.68,
            junction_overlap=1.1,
            section=(1.0, 0.88),
        ),
        name="SeaFan",
        rings=16,
        segments=12,
        subsurf=1,
    )
    obj = result.join("Sea_Fan", weld_voxel_size=0.005)
    _assign([obj], _material("Gorgonian violet", (0.43, 0.10, 0.31), 0.5))
    return [obj]


def _kelp():
    result = build_branching(
        BranchSpec(
            trunk_length=2.8,
            radius=0.13,
            children_per_split=1,
            split_angle=math.radians(57.0),
            split_angle_jitter=math.radians(4.0),
            length_decay=0.44,
            radius_decay=0.48,
            depth=1,
            curvature=0.055,
            droop=0.10,
            seed=909,
            planarity=1.0,
            split_positions=(0.20, 0.36, 0.52, 0.68, 0.84),
            alternating=True,
            tip_radius_ratio=0.58,
            junction_overlap=1.0,
            section=(1.0, 0.76),
        ),
        name="Kelp",
        rings=22,
        segments=12,
        subsurf=1,
    )
    obj = result.join("Alternating_Kelp", weld_voxel_size=0.008)
    _assign([obj], _material("Kelp green", (0.20, 0.43, 0.085), 0.48))
    return [obj]


BUILDERS = {
    "curved": _curved_tube,
    "section": _noncircular_tube,
    "staghorn": _staghorn,
    "sea_fan": _sea_fan,
    "kelp": _kelp,
}


def _add_sheet_label(path, label):
    temp = f"{path}.labelled.png"
    font = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
    command = [
        "ffmpeg", "-y", "-loglevel", "error", "-i", path,
        "-vf", (
            f"drawtext=fontfile='{font}':text='{label}':fontcolor=white:fontsize=34:"
            "x=24:y=24:box=1:boxcolor=black@0.72:boxborderw=12"
        ),
        "-frames:v", "1", temp,
    ]
    try:
        subprocess.run(command, check=True)
        os.replace(temp, path)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        if os.path.exists(temp):
            os.remove(temp)
        print(f"[tube_demo] image label skipped: {exc}")


def render_case(case, out_dir, samples):
    studio.reset_scene()
    studio.setup_render(resolution=(780, 620), samples=samples, exposure=-1.0)
    BUILDERS[case]()

    low, high = studio.scene_bounds()
    center = (low + high) * 0.5
    radius = max((high - low).length * 0.58, 0.5)
    studio.studio_lights(radius=radius, target=center)

    case_dir = os.path.join(out_dir, case)
    paths = studio.render_views(case_dir, margin=1.23, prefix=case)
    sheet = os.path.join(out_dir, f"{case}_contact.png")
    studio.contact_sheet(paths, sheet, columns=3)
    _add_sheet_label(sheet, case.replace("_", " ").title())
    print(f"[tube_demo] rendered {case}: {sheet}")
    return sheet


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", choices=("all",) + CASES, default="all")
    parser.add_argument("--out", default=os.path.join(_REPO, "build", "tube-demo"))
    parser.add_argument("--samples", type=int, default=48)
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    cases = CASES if args.case == "all" else (args.case,)
    for case in cases:
        render_case(case, args.out, args.samples)


if __name__ == "__main__":
    main()
