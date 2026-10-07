"""Build one origami model from the catalog, then render and/or export it.

Run through `tools/blender/run.sh`, which starts Blender headless:

    tools/blender/run.sh Savers/OrigamiDogfight/Models/build_model.py -- --model dart --render
    tools/blender/run.sh Savers/OrigamiDogfight/Models/build_model.py -- \\
        --model dart --export Savers/OrigamiDogfight/Assets/dart.usdz

`--render` writes a studio contact sheet to `build/origami-models/<name>/studio_sheet.png`.
`tools/build-origami-library.py` drives `--export` for every model.

Everything the asset contract promises is checked here, after the model is built and before
anything is written, so a model that bends the contract fails its own build rather than
arriving in the saver as a stand-in.
"""

import argparse
import json
import os
import sys

import bpy
from mathutils import Matrix, Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender"), _HERE]

from saverlib import studio  # noqa: E402
from origami import CATALOG  # noqa: E402

# Overhead is the in-game view, so it is in every sheet twice: straight down, and at the
# slight tilt the saver's camera actually has.
STUDIO_VIEWS = [
    ("three-quarter", -55.0, 28.0),
    ("side", -90.0, 0.0),
    ("front", 0.0, 6.0),
    ("overhead", -90.0, 89.5),
    ("game-tilt", -90.0, 72.0),
    ("below", -80.0, -40.0),
]


# Plausible largest dimension per kind, in metres. Each kind is authored at its own
# consistent scale — planes and their ammunition at desk size, scenery at landscape size,
# fire and smoke at the size of the plane they burn on — and the runtime rescales from the
# manifest bounds, so these only catch a model built in the wrong units.
_SIZE_RANGE = {
    "plane": (0.05, 0.5),
    "projectile": (0.002, 0.15),
    "tree": (0.5, 25.0),
    "rock": (0.2, 10.0),
    "house": (1.0, 25.0),
    "boat": (0.5, 12.0),
    "fire": (0.05, 1.0),
    "smoke": (0.02, 1.0),
}


class ContractError(RuntimeError):
    pass


def _meshes(root):
    if root.type == "MESH":
        return [root]
    return [obj for obj in root.children_recursive if obj.type == "MESH"]


def _apply_scales(root):
    """Bake every object's scale into its mesh; an Empty may not carry one at all.

    A scale left on a parent puts its children in a stretched space, and rotating them
    then shears rather than turns (next-session.md, traps). The fire's flames are scaled by
    the runtime about their own origins, so they must arrive at exactly unit scale.
    """
    objects = [root, *root.children_recursive]
    for obj in objects:
        if obj.type != "MESH" and any(abs(s - 1.0) > 1e-9 for s in obj.scale):
            raise ContractError(f"{obj.name}: an Empty carries scale {tuple(obj.scale)}")
    for obj in objects:
        if obj.type == "MESH" and any(abs(s - 1.0) > 1e-9 for s in obj.scale):
            obj.data.transform(Matrix.Diagonal((*obj.scale, 1.0)))
            obj.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()


def _seat(model, root):
    """Centre the model on the origin, standing on z = 0 if it is grounded.

    Exact vertex bounds, not `scene_bounds`, which is a superset for anything rotated and
    once exported a wreck hanging 0.65 m above the seabed (next-session.md, traps).
    """
    lo, hi = studio.world_mesh_bounds(_meshes(root))
    offset = Vector((
        (lo.x + hi.x) * 0.5,
        (lo.y + hi.y) * 0.5,
        lo.z if model.anchor == "ground" else (lo.z + hi.z) * 0.5,
    ))
    if root.type == "MESH":
        if root.location.length > 1e-9 or root.parent is not None:
            raise ContractError(f"{root.name}: a mesh root must sit at the origin")
        root.data.transform(Matrix.Translation(-offset))
    else:
        if root.location.length > 1e-9:
            raise ContractError(f"{root.name}: the root Empty must sit at the origin")
        for child in root.children:
            child.location -= offset
    bpy.context.view_layer.update()
    return studio.world_mesh_bounds(_meshes(root))


def _check_contract(model, root, extra, bounds):
    name = model.name
    if root.name != name:
        raise ContractError(f"root is named {root.name!r}, expected {name!r}")
    meshes = _meshes(root)
    if not meshes:
        raise ContractError(f"{name}: no geometry")
    for obj in meshes:
        if obj.modifiers:
            raise ContractError(f"{obj.name}: live modifiers would not export as built")
        if any(p.use_smooth for p in obj.data.polygons):
            raise ContractError(f"{obj.name}: smooth-shaded faces; the contract is flat")
        if not obj.data.materials or any(m is None for m in obj.data.materials):
            raise ContractError(f"{obj.name}: a face has no material")
    lo, hi = bounds
    size = hi - lo
    smallest, largest = _SIZE_RANGE[model.kind]
    if min(size) <= 0.0 or not smallest <= max(size) <= largest:
        raise ContractError(
            f"{name}: largest dimension {max(size):.4f} m is outside the "
            f"{smallest}-{largest} m expected of a {model.kind}"
        )

    if model.kind == "plane":
        if root.type != "MESH" or len(meshes) != 1:
            raise ContractError(f"{name}: a plane is one joined mesh")
        materials = [m.name for m in root.data.materials]
        if materials != ["paper"]:
            raise ContractError(f"{name}: a plane has one material named paper, got {materials}")
        layer = root.data.uv_layers.get("st")
        if layer is None:
            raise ContractError(f"{name}: a plane needs its sheet UVs in layer 'st'")
        coords = [c for loop in layer.data for c in loop.uv]
        if min(coords) < -1e-6 or max(coords) > 1.0 + 1e-6:
            raise ContractError(f"{name}: sheet UVs leave [0, 1]")
        if not extra.get("sheetAspect"):
            raise ContractError(f"{name}: a plane's manifest needs sheetAspect")
        if size.x <= max(size.y, size.z) * 0.4:
            raise ContractError(f"{name}: does not look nose-along-X: {tuple(size)}")

    if model.kind == "fire":
        flames = sorted(
            (obj for obj in root.children if obj.name.startswith("flame_")),
            key=lambda obj: int(obj.name.split("_")[1]),
        )
        names = [obj.name for obj in flames]
        if not 3 <= len(flames) <= 6 or names != [f"flame_{i}" for i in range(len(flames))]:
            raise ContractError(f"{name}: flames must be flame_0..flame_n (3-6), got {names}")
        for obj in flames:
            if obj.type != "MESH":
                raise ContractError(f"{obj.name}: a flame must be a mesh")
            local_min_z = min(v.co.z for v in obj.data.vertices)
            if abs(local_min_z) > 1e-3:
                raise ContractError(
                    f"{obj.name}: origin must be at the flame's base, lowest vertex at "
                    f"{local_min_z:+.4f} m in its own space"
                )


def _materials(root):
    return {m.name for obj in _meshes(root) for m in obj.data.materials}


def build(model):
    root, extra = model.build()
    if root is None:
        raise ContractError(f"{model.name}: build returned no root")
    bpy.context.view_layer.update()
    _apply_scales(root)
    bounds = _seat(model, root)
    _check_contract(model, root, extra, bounds)
    if model.kind == "fire":
        # Seating moves the flames after build() has described them; the manifest must say
        # where each flame's pivot is in the file, not where it was authored.
        nodes = {obj.name: obj for obj in root.children}
        for entry in extra.get("flames", []):
            if entry["node"] not in nodes:
                raise ContractError(f"{model.name}: manifest names missing node {entry['node']}")
            entry["base"] = [round(v, 6) for v in nodes[entry["node"]].location]
    return root, extra, bounds


def render_studio(root, out_dir, samples):
    lo, hi = studio.world_mesh_bounds(_meshes(root))
    radius = max((hi - lo).length * 0.5, 1e-3)
    studio.studio_lights(radius=radius * 4.0, target=(lo + hi) * 0.5)
    paths = studio.render_views(out_dir, views=STUDIO_VIEWS, prefix="studio", margin=1.15)
    sheet = studio.contact_sheet(paths, os.path.join(out_dir, "studio_sheet.png"), columns=3)
    print(f"[build_model] studio sheet: {sheet}")


def export(model, root, extra, bounds, export_path):
    export_path = os.path.abspath(export_path)
    os.makedirs(os.path.dirname(export_path), exist_ok=True)
    result = bpy.ops.wm.usd_export(
        filepath=export_path,
        export_materials=True,
        export_textures_mode="NEW",
        overwrite_textures=True,
        evaluation_mode="RENDER",
        generate_preview_surface=True,
        export_lights=False,
        export_cameras=False,
        convert_world_material=False,
        export_custom_properties=False,
        export_animation=False,
        # One prim per object: the Xform and its Mesh merge, so the runtime finds a
        # `flame_2` node that both carries the geometry and pivots about the flame's base.
        merge_parent_xform=True,
    )
    if "FINISHED" not in result:
        raise RuntimeError(f"USD export of {model.name} failed: {result}")
    manifest = model.manifest(os.path.basename(export_path), bounds, _materials(root), extra)
    manifest_path = os.path.splitext(export_path)[0] + ".json"
    with open(manifest_path, "w") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print(f"[build_model] exported: {export_path}")
    print(f"[build_model] manifest: {manifest_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=sorted(CATALOG))
    parser.add_argument("--list", action="store_true",
                        help="print the catalog as one JSON line and exit")
    parser.add_argument("--out", default=os.path.join(_REPO, "build", "origami-models"))
    parser.add_argument("--render", action="store_true", help="studio contact sheet")
    parser.add_argument("--export", default=None, help="write a .usdz (and .json) here")
    parser.add_argument("--samples", type=int, default=32)
    # The studio rig is tuned for dark fish; near-white paper clips without this.
    parser.add_argument("--exposure", type=float, default=-3.2)
    parser.add_argument("--save-blend", default=None, help="debugging only; never commit")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)
    if args.list:
        print("[build_model] catalog: "
              + json.dumps({name: model.kind for name, model in sorted(CATALOG.items())}))
        return
    if not args.model:
        parser.error("--model is required")

    model = CATALOG[args.model]
    studio.reset_scene()
    studio.setup_render(resolution=(720, 560), samples=args.samples, exposure=args.exposure)
    try:
        root, extra, bounds = build(model)
    except ContractError as exc:
        # "Error" in the output is what the library builder treats as a failure.
        print(f"[build_model] Error: contract: {exc}")
        raise SystemExit(1)
    lo, hi = bounds
    print(f"[build_model] {model.name}: {model.kind}, "
          f"{(hi - lo).x:.4f} x {(hi - lo).y:.4f} x {(hi - lo).z:.4f} m, "
          f"{sum(len(o.data.polygons) for o in _meshes(root))} faces, "
          f"materials {sorted(_materials(root))}")

    if args.export:
        export(model, root, extra, bounds, args.export)
    if args.render or not args.export:
        render_studio(root, os.path.join(args.out, model.name), args.samples)
    if args.save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))


if __name__ == "__main__":
    main()
