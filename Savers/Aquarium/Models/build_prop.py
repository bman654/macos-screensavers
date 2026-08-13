"""Assemble a prop from its catalog entry, then render and/or export it.

The counterpart to `build_fish.py` for everything that is not a fish. Run through
`tools/blender/run.sh`, which puts `saverlib` on the path:

    tools/blender/run.sh Savers/Aquarium/Models/build_prop.py -- \
        --prop staghorn_coral --render --preview
    tools/blender/run.sh Savers/Aquarium/Models/build_prop.py -- \
        --prop treasure_chest --export Savers/Aquarium/Assets/treasure_chest.usdz --bake
"""

import argparse
import json
import math
import os
import sys
import time

import bpy

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender"), _HERE]

from saverlib import studio  # noqa: E402
from saverlib.bake import (  # noqa: E402
    DEFAULT_MARGIN,
    DEFAULT_RESOLUTION,
    DEFAULT_UV_MARGIN,
    bake_atlas,
    bake_atlas_objects,
)
from props import CATALOG  # noqa: E402


def _apply_scales():
    """Bake every object's scale into its mesh.

    A non-uniform scale left on a parent puts its children in a stretched space: their
    positions arrive in the wrong units and rotating them shears the mesh instead of
    turning it, which is fatal for anything with a hinge. See
    `spikes/004-articulated-decor/`.
    """
    objects = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objects:
        return
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.select_all(action="DESELECT")


def _bake_modifiers(obj):
    """Replace one mesh with its evaluated form before UV unwrapping.

    This deliberately mirrors the local helper in `build_fish.py` rather than importing a
    command-line model builder as a library. Joining keeps only the active object's modifier
    stack, while baking an unevaluated mesh assigns the modifier-generated faces overlapping
    UVs; evaluating first avoids both silent failures.
    """
    if not obj.modifiers:
        return
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    baked = bpy.data.meshes.new_from_object(evaluated)
    previous = obj.data
    obj.modifiers.clear()
    obj.data = baked
    if previous.users == 0:
        bpy.data.meshes.remove(previous)


def _mesh_objects(root):
    if root.type == "MESH":
        raise ValueError(
            f"prop root '{root.name}' must be an Empty so its geometry is not skipped"
        )
    return [obj for obj in root.children_recursive if obj.type == "MESH"]


def _join_static_parts(root, name):
    """Evaluate and join a static prop without importing from `build_fish.py`."""
    meshes = _mesh_objects(root)
    if not meshes:
        raise RuntimeError(f"building '{name}' produced no mesh")
    for obj in meshes:
        _bake_modifiers(obj)
    if len(meshes) == 1:
        return meshes[0]

    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    result = bpy.ops.object.join()
    if "FINISHED" not in result:
        raise RuntimeError(f"joining static prop '{name}' failed: {result}")
    joined = bpy.context.view_layer.objects.active
    joined.name = name
    return joined


def _pose(specs):
    """Rotate named parts before rendering, to inspect a bubbler's open pose.

    An articulated prop is authored closed, because closed is what the tank places, but
    closed is the pose in which its interesting geometry is invisible — a clam's mantle and
    nacre, a chest's hoard, a skeleton's raised jug. Every bubbler author needed this and
    each invented a different workaround, so it belongs here.

    Deliberately render-only: posing what gets exported would ship a chest frozen open.
    """
    for spec in specs:
        name, _, degrees = spec.partition("=")
        obj = bpy.context.scene.objects.get(name)
        if obj is None:
            raise SystemExit(
                f"--pose: no object named '{name}'. Moving parts are named part_<something>; "
                f"this prop has "
                f"{sorted(o.name for o in bpy.context.scene.objects if o.name.startswith('part_')) or 'none'}"
            )
        try:
            obj.rotation_euler.x = math.radians(float(degrees))
        except ValueError:
            raise SystemExit(f"--pose: '{spec}' is not <part>=<degrees>")


def _drop_to_floor():
    """Seat the prop on z = 0 so the tank never has to guess where its bottom is.

    Exact bounds, not `scene_bounds`: this number is the model's contract with the tank, and
    a bounding-box approximation is a superset for anything rotated. A listing wreck was
    exported floating 0.65 m over the seabed because of it.
    """
    lo, _ = studio.world_mesh_bounds()
    if abs(lo.z) < 1e-6:
        return
    for obj in bpy.context.scene.objects:
        if obj.parent is None:
            obj.location.z -= lo.z


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prop", required=True, choices=sorted(CATALOG))
    parser.add_argument("--out", default=os.path.join(_REPO, "build", "props"))
    parser.add_argument("--render", action="store_true", help="studio turntable")
    parser.add_argument("--preview", action="store_true", help="underwater lighting")
    parser.add_argument("--export", default=None, help="write a .usdz to this path")
    parser.add_argument("--bake", action="store_true",
                        help="bake procedural materials before export")
    parser.add_argument("--textures", default=None,
                        help="directory for baked atlas PNGs; defaults beside the export")
    parser.add_argument("--resolution", type=int, default=DEFAULT_RESOLUTION)
    parser.add_argument("--margin", type=int, default=DEFAULT_MARGIN)
    parser.add_argument("--uv-margin", type=float, default=DEFAULT_UV_MARGIN)
    parser.add_argument("--device", default=None,
                        help="exact Cycles device name; any Metal GPU by default")
    parser.add_argument("--pose", action="append", default=[], metavar="PART=DEGREES",
                        help="rotate a moving part before rendering, e.g. part_lid=-80; "
                             "repeatable, and refused with --export")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--samples", type=int, default=64)
    parser.add_argument("--exposure", type=float, default=-2.0,
                        help="the studio rig runs hot for large matte props")
    parser.add_argument("--save-blend", default=None)
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)
    if args.bake and not args.export:
        parser.error("--bake requires --export")
    if args.pose and args.export:
        parser.error("--pose is for looking at a prop, not for shipping one: exporting a "
                     "posed model would put a chest in the tank frozen open")

    prop = CATALOG[args.prop]

    studio.reset_scene()
    studio.setup_render(resolution=(900, 700), samples=args.samples,
                        exposure=args.exposure)
    root = prop.build(args.seed)
    if root is None:
        raise RuntimeError(f"building '{prop.name}' produced no root object")
    _apply_scales()
    _drop_to_floor()
    # After the drop, so the posed render still shows the prop seated where the tank will
    # seat it rather than floating on its own swung-open bounding box.
    _pose(args.pose)

    out_dir = os.path.join(args.out, prop.name)
    os.makedirs(out_dir, exist_ok=True)
    radius = max(prop.footprint, prop.height) * 2.0

    if args.render or not (args.preview or args.export):
        studio.studio_lights(radius=radius)
        paths = studio.render_views(out_dir, prefix="studio")
        print(f"[build_prop] studio sheet: "
              f"{studio.contact_sheet(paths, os.path.join(out_dir, 'studio_sheet.png'))}")

    if args.preview:
        for light in [o for o in bpy.context.scene.objects if o.type == "LIGHT"]:
            bpy.data.objects.remove(light, do_unlink=True)
        studio.underwater_lights(radius=radius)
        views = [("side", -90.0, 4.0), ("three-quarter", -58.0, 14.0), ("low", -70.0, -4.0)]
        paths = studio.render_views(out_dir, views=views, prefix="water")
        print(f"[build_prop] underwater sheet: "
              f"{studio.contact_sheet(paths, os.path.join(out_dir, 'water_sheet.png'), columns=3)}")

    if args.export:
        export_path = os.path.abspath(args.export)
        os.makedirs(os.path.dirname(export_path), exist_ok=True)

        if args.bake:
            stem = os.path.splitext(os.path.basename(export_path))[0]
            texture_dir = os.path.abspath(
                args.textures
                or os.path.join(os.path.dirname(export_path), f"{stem}_textures")
            )
            started = time.monotonic()
            if prop.parts:
                meshes = _mesh_objects(root)
                for obj in meshes:
                    _bake_modifiers(obj)
                _drop_to_floor()
                paths = bake_atlas_objects(
                    meshes,
                    texture_dir,
                    atlas_name=prop.name,
                    resolution=args.resolution,
                    margin=args.margin,
                    uv_margin=args.uv_margin,
                    device_name=args.device,
                )
            else:
                joined = _join_static_parts(root, f"prop_{prop.name}")
                _drop_to_floor()
                paths = bake_atlas(
                    joined,
                    texture_dir,
                    atlas_name=prop.name,
                    resolution=args.resolution,
                    margin=args.margin,
                    uv_margin=args.uv_margin,
                    device_name=args.device,
                )
            for kind, path in paths.items():
                print(f"[build_prop] {kind}: {path}")
            print(
                f"[build_prop] baked {args.resolution}x{args.resolution}, "
                f"margin {args.margin}px in {time.monotonic() - started:.1f}s"
            )

        bpy.ops.wm.usd_export(
            filepath=export_path,
            export_materials=True,
            export_textures_mode="NEW",
            overwrite_textures=True,
            evaluation_mode="RENDER",
            generate_preview_surface=True,
        )
        manifest_path = os.path.splitext(export_path)[0] + ".json"
        with open(manifest_path, "w") as handle:
            json.dump(prop.manifest(os.path.basename(export_path)), handle, indent=2)
            handle.write("\n")
        print(f"[build_prop] exported: {export_path}")
        print(f"[build_prop] manifest: {manifest_path}")

    if args.save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))


if __name__ == "__main__":
    main()
