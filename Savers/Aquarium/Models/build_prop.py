"""Assemble a prop from its catalog entry, then render and/or export it.

The counterpart to `build_fish.py` for everything that is not a fish. Run through
`tools/blender/run.sh`, which puts `saverlib` on the path:

    tools/blender/run.sh Savers/Aquarium/Models/build_prop.py -- \
        --prop staghorn_coral --render --preview
    tools/blender/run.sh Savers/Aquarium/Models/build_prop.py -- \
        --prop treasure_chest --export Savers/Aquarium/Assets/treasure_chest.usdz
"""

import argparse
import json
import os
import sys

import bpy

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender"), _HERE]

from saverlib import studio  # noqa: E402
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


def _drop_to_floor():
    """Seat the prop on z = 0 so the tank never has to guess where its bottom is."""
    lo, _ = studio.scene_bounds()
    if lo.z == 0.0:
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
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--samples", type=int, default=64)
    parser.add_argument("--exposure", type=float, default=-2.0,
                        help="the studio rig runs hot for large matte props")
    parser.add_argument("--save-blend", default=None)
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)

    prop = CATALOG[args.prop]

    studio.reset_scene()
    studio.setup_render(resolution=(900, 700), samples=args.samples,
                        exposure=args.exposure)
    prop.build(args.seed)
    _apply_scales()
    _drop_to_floor()

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
        bpy.ops.wm.usd_export(
            filepath=export_path,
            export_materials=True,
            export_textures_mode="NEW",
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
