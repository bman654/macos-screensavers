"""Build, bake, and export one fish for SceneKit verification."""

import argparse
import os
import sys
import time

import bpy

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
_MODELS = os.path.join(_REPO, "Savers", "Aquarium", "Models")
sys.path[:0] = [os.path.join(_REPO, "tools", "blender"), _MODELS]

import build_fish  # noqa: E402
from saverlib import studio  # noqa: E402
from saverlib.bake import (  # noqa: E402
    DEFAULT_MARGIN,
    DEFAULT_RESOLUTION,
    DEFAULT_UV_MARGIN,
    bake_atlas,
)
from species import CATALOG  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--species", default="clownfish", choices=sorted(CATALOG))
    parser.add_argument("--export", required=True, help="write the baked fish to this .usdz")
    parser.add_argument("--textures", default=None, help="directory for baked atlas PNGs")
    parser.add_argument("--resolution", type=int, default=DEFAULT_RESOLUTION)
    parser.add_argument("--margin", type=int, default=DEFAULT_MARGIN)
    parser.add_argument("--uv-margin", type=float, default=DEFAULT_UV_MARGIN)
    parser.add_argument("--device", default=None,
                        help="exact Cycles device name; any Metal GPU by default")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)

    export_path = os.path.abspath(args.export)
    stem = os.path.splitext(os.path.basename(export_path))[0]
    texture_dir = os.path.abspath(
        args.textures or os.path.join(os.path.dirname(export_path), f"{stem}_textures")
    )
    os.makedirs(os.path.dirname(export_path), exist_ok=True)

    studio.reset_scene()
    spec = CATALOG[args.species]
    root = build_fish.build(spec)
    fish = build_fish.join_parts(root, f"fish_{spec.name}")
    if fish is None:
        raise RuntimeError(f"building '{spec.name}' produced no mesh")
    print(
        f"[bake_probe] joined '{fish.name}': {len(fish.data.vertices)} verts, "
        f"{len(fish.data.materials)} material slots"
    )

    started = time.monotonic()
    paths = bake_atlas(
        fish,
        texture_dir,
        atlas_name=spec.name,
        resolution=args.resolution,
        margin=args.margin,
        uv_margin=args.uv_margin,
        device_name=args.device,
    )
    elapsed = time.monotonic() - started
    for kind, path in paths.items():
        print(f"[bake_probe] {kind}: {path}")
    print(
        f"[bake_probe] baked {args.resolution}x{args.resolution}, "
        f"margin {args.margin}px in {elapsed:.1f}s"
    )

    bpy.ops.wm.usd_export(
        filepath=export_path,
        export_materials=True,
        # `export_textures` is a retained legacy alias that no longer drives anything;
        # this enum is the live control, so passing the bool reads as load-bearing while
        # doing nothing.
        export_textures_mode="NEW",
        overwrite_textures=True,
        evaluation_mode="RENDER",
        generate_preview_surface=True,
    )
    print(f"[bake_probe] exported: {export_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[bake_probe] error: {exc}", file=sys.stderr, flush=True)
        os._exit(1)
