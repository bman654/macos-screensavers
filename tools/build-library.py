#!/usr/bin/env python3
"""Build the complete baked Aquarium model library."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


_REPO = Path(__file__).resolve().parents[1]
_MODELS = _REPO / "Savers" / "Aquarium" / "Models"
_ASSETS = _REPO / "Savers" / "Aquarium" / "Assets"
_RUN_BLENDER = _REPO / "tools" / "blender" / "run.sh"
_ERROR = re.compile(r"Error|Traceback")
_BUDGET_BYTES = 40_000_000

# USD validation runs outside Blender, so importing `build_fish.py` would also import `bpy`.
# Keep these coupled explicitly to build_fish.py's `_NO_PART` and `_PECTORAL_IDS` instead.
_FISH_PART_IDS = (0.0, 0.25, 0.35)
_PART_ID_TOLERANCE = 1e-3
_USD_NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"

_FISH_RESOLUTION = 256
_PROP_RESOLUTION = 256
_RESOLUTION_BY_NAME = {
    # These articulated/showpiece decorations carry readable authored detail at close range.
    "clamshell": 512,
    "diving_suit": 512,
    # Fifty moving meshes need 1024 pixels for disjoint bake tiles at a 32px gutter.
    "skeleton_with_jug": 1024,
    "treasure_chest": 512,
    # The wreck is the library's largest focal model and the only 2048 atlas.
    "sunken_ship": 2048,
}

# Several branching and organic props are authored densely enough for close-up stills. Their
# shipping meshes need only preserve a tank-scale silhouette; their surface detail is baked.
_DECIMATE_RATIO = {
    "anemone": 0.25,
    "brain_coral": 0.25,
    "diving_suit": 0.40,
    "giant_kelp": 0.20,
    "kelp": 0.30,
    "rock_pillars": 0.50,
    "sea_fan": 0.20,
    "staghorn_coral": 0.25,
    "thermal_vent": 0.20,
    "tube_sponge": 0.40,
}

_STATIC_PROP_BUILDER = r'''import argparse
import json
import os
from pathlib import Path
import sys
import time

import bpy

parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True)
parser.add_argument("--prop", required=True)
parser.add_argument("--export", required=True)
parser.add_argument("--textures", required=True)
parser.add_argument("--resolution", type=int, required=True)
parser.add_argument("--ratio", type=float, required=True)
argv = sys.argv[sys.argv.index("--") + 1:]
args = parser.parse_args(argv)
repo = Path(args.repo)
models = repo / "Savers" / "Aquarium" / "Models"
sys.path[:0] = [os.fspath(repo / "tools" / "blender"), os.fspath(models)]

from saverlib import studio
from saverlib.bake import bake_atlas
import build_prop
from props import CATALOG

prop = CATALOG[args.prop]
if prop.parts:
    raise RuntimeError(f"generic decimation cannot alter articulated prop {prop.name!r}")
studio.reset_scene()
studio.setup_render(resolution=(900, 700), samples=1, exposure=-2.0)
root = prop.build(0)
if root is None:
    raise RuntimeError(f"building {prop.name!r} produced no root object")
build_prop._apply_scales()
build_prop._drop_to_floor()
joined = build_prop._join_static_parts(root, f"prop_{prop.name}")
build_prop._drop_to_floor()
joined.data.calc_loop_triangles()
before = len(joined.data.loop_triangles)
modifier = joined.modifiers.new(name="ShippingDecimate", type="DECIMATE")
modifier.decimate_type = "COLLAPSE"
modifier.ratio = args.ratio
bpy.ops.object.select_all(action="DESELECT")
joined.select_set(True)
bpy.context.view_layer.objects.active = joined
result = bpy.ops.object.modifier_apply(modifier=modifier.name)
if "FINISHED" not in result:
    raise RuntimeError(f"decimating {prop.name!r} failed: {result}")
joined.data.calc_loop_triangles()
after = len(joined.data.loop_triangles)
print(f"[build_prop] shipping mesh: {before} -> {after} triangles")

started = time.monotonic()
paths = bake_atlas(
    joined,
    os.path.abspath(args.textures),
    atlas_name=prop.name,
    resolution=args.resolution,
)
for kind, path in paths.items():
    print(f"[build_prop] {kind}: {path}")
print(f"[build_prop] baked {args.resolution}x{args.resolution} in "
      f"{time.monotonic() - started:.1f}s")

export_path = os.path.abspath(args.export)
os.makedirs(os.path.dirname(export_path), exist_ok=True)
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
'''


class BuildFailure(RuntimeError):
    pass


def _catalog(group):
    directory = _MODELS / group
    return sorted(
        path.stem
        for path in directory.glob("*.py")
        if not path.name.startswith("_") and path.name != "__init__.py"
    )


def _resolution(name, category):
    default = _FISH_RESOLUTION if category == "fish" else _PROP_RESOLUTION
    return _RESOLUTION_BY_NAME.get(name, default)


def _run(command, name):
    result = subprocess.run(
        command,
        cwd=_REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    output = result.stdout or ""
    errors = [line for line in output.splitlines() if _ERROR.search(line)]
    if result.returncode or errors:
        sys.stderr.write(output)
        detail = f"exit status {result.returncode}"
        if errors:
            detail += f", error output: {' | '.join(errors)}"
        raise BuildFailure(f"{name} failed ({detail})")

    for line in output.splitlines():
        if line.startswith("[build_") or line.startswith("Warning:"):
            print(f"    {line}")


def _validate_outputs(name, category, asset, manifest):
    if not asset.is_file() or asset.stat().st_size == 0:
        raise BuildFailure(f"{name} produced no USDZ")
    if not zipfile.is_zipfile(asset):
        raise BuildFailure(f"{asset} is not a USDZ archive")
    with zipfile.ZipFile(asset) as archive:
        members = archive.namelist()
    for texture in ("base_color", "roughness", "normal"):
        if not any(member.endswith(f"_{texture}.png") for member in members):
            raise BuildFailure(f"{asset} has no baked {texture} texture")

    try:
        data = json.loads(manifest.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise BuildFailure(f"could not read {manifest}: {exc}") from exc
    if data.get("name") != name:
        raise BuildFailure(f"{manifest} names {data.get('name')!r}, expected {name!r}")
    if data.get("asset") != f"{name}.usdz":
        raise BuildFailure(f"{manifest} does not refer to {name}.usdz")
    if category == "fish" and data.get("category") != "fish":
        raise BuildFailure(f"{manifest} is not a fish manifest")
    if category == "prop" and data.get("category") == "fish":
        raise BuildFailure(f"{manifest} is not a prop manifest")

    # Fish need the full USDA text to inspect their second UV set. Props retain the cheaper
    # load-only check and are deliberately outside the part-channel contract.
    command = ["usdcat", os.fspath(asset)] if category == "fish" else [
        "usdcat", "--loadOnly", os.fspath(asset)
    ]
    check = subprocess.run(
        command,
        cwd=_REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if check.returncode:
        raise BuildFailure(f"usdcat could not load {asset}:\n{check.stdout}")

    if category == "fish":
        declaration = re.search(
            r"\bprimvars:st1\s*=\s*\[(.*?)\]", check.stdout, re.DOTALL
        )
        if declaration is None:
            raise BuildFailure(f"{asset} does not declare primvars:st1")
        u_values = [
            float(value)
            for value in re.findall(rf"\(\s*({_USD_NUMBER})\s*,", declaration.group(1))
        ]
        if not u_values:
            raise BuildFailure(f"{asset} declares primvars:st1 without readable UV values")
        if any(abs(value - 1.0) <= _PART_ID_TOLERANCE for value in u_values):
            raise BuildFailure(
                f"{asset} primvars:st1 contains reserved U=1.0 (missing-channel white fill)"
            )
        unexpected = sorted({
            value for value in u_values
            if not any(abs(value - expected) <= _PART_ID_TOLERANCE
                       for expected in _FISH_PART_IDS)
        })
        if unexpected:
            samples = ", ".join(f"{value:.6g}" for value in unexpected[:8])
            raise BuildFailure(
                f"{asset} primvars:st1 has unexpected U value(s): {samples}; "
                f"expected only {_FISH_PART_IDS} within {_PART_ID_TOLERANCE:g}"
            )
        present = sorted({
            min(_FISH_PART_IDS, key=lambda expected: abs(value - expected))
            for value in u_values
        })
        print(f"    [validate] primvars:st1 U ids {present}; no reserved white fill")


def _build_one(name, category, staging):
    resolution = _resolution(name, category)
    asset = staging / f"{name}.usdz"
    manifest = staging / f"{name}.json"
    textures = staging / f"{name}_textures"
    if category == "fish":
        command = [
            os.fspath(_RUN_BLENDER),
            os.fspath(_MODELS / "build_fish.py"),
            "--",
            "--species",
            name,
            "--export",
            os.fspath(asset),
            "--bake",
            "--textures",
            os.fspath(textures),
            "--resolution",
            str(resolution),
        ]
    elif name in _DECIMATE_RATIO:
        script = staging / "_build_static_prop.py"
        if not script.exists():
            script.write_text(_STATIC_PROP_BUILDER)
        command = [
            os.fspath(_RUN_BLENDER),
            os.fspath(script),
            "--",
            "--repo",
            os.fspath(_REPO),
            "--prop",
            name,
            "--export",
            os.fspath(asset),
            "--textures",
            os.fspath(textures),
            "--resolution",
            str(resolution),
            "--ratio",
            str(_DECIMATE_RATIO[name]),
        ]
    else:
        command = [
            os.fspath(_RUN_BLENDER),
            os.fspath(_MODELS / "build_prop.py"),
            "--",
            "--prop",
            name,
            "--export",
            os.fspath(asset),
            "--bake",
            "--textures",
            os.fspath(textures),
            "--resolution",
            str(resolution),
            "--seed",
            "0",
        ]
    print(f"[{category}] {name} ({resolution}x{resolution})")
    _run(command, name)
    _validate_outputs(name, category, asset, manifest)
    return asset.stat().st_size


def _human_size(size):
    if size < 1_000_000:
        return f"{size / 1_000:.1f} KB"
    return f"{size / 1_000_000:.2f} MB"


def _write_index(all_names):
    available = [
        name
        for name in all_names
        if (_ASSETS / f"{name}.usdz").is_file()
        and (_ASSETS / f"{name}.json").is_file()
    ]
    if len(available) != len(all_names):
        missing = sorted(set(all_names) - set(available))
        print(
            "index.json unchanged: a partial build cannot describe an incomplete library "
            f"(missing {', '.join(missing)})"
        )
        return False
    (_ASSETS / "index.json").write_text(
        json.dumps({"models": [f"{name}.json" for name in available]}) + "\n"
    )
    return True


def _library_size(all_names):
    paths = [
        _ASSETS / filename
        for name in all_names
        for filename in (f"{name}.usdz", f"{name}.json")
    ]
    paths.append(_ASSETS / "index.json")
    return sum(path.stat().st_size for path in paths if path.is_file())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="NAME",
        help="build only this model; repeatable",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        choices=(1,),
        default=1,
        help="Blender/Cycles builds are intentionally serial (only 1 is supported)",
    )
    args = parser.parse_args()

    fish = _catalog("species")
    props = _catalog("props")
    categories = {**{name: "fish" for name in fish}, **{name: "prop" for name in props}}
    all_names = sorted(categories)
    unknown = sorted(set(args.only) - set(all_names))
    if unknown:
        parser.error(f"unknown model(s): {', '.join(unknown)}")
    selected = [name for name in all_names if not args.only or name in set(args.only)]
    full_build = len(selected) == len(all_names)

    _ASSETS.mkdir(parents=True, exist_ok=True)
    build_root = _REPO / "build"
    build_root.mkdir(parents=True, exist_ok=True)
    sizes = {}
    try:
        with tempfile.TemporaryDirectory(prefix="aquarium-library-", dir=build_root) as temp:
            staging = Path(temp)
            for name in selected:
                sizes[name] = _build_one(name, categories[name], staging)
                print(f"    package: {_human_size(sizes[name])}")

            staged_total = sum(
                path.stat().st_size
                for path in staging.iterdir()
                if path.suffix in (".usdz", ".json")
            )
            if full_build and staged_total > _BUDGET_BYTES:
                raise BuildFailure(
                    f"staged library is {_human_size(staged_total)}, over the "
                    f"{_human_size(_BUDGET_BYTES)} budget"
                )

            for name in selected:
                os.replace(staging / f"{name}.usdz", _ASSETS / f"{name}.usdz")
                os.replace(staging / f"{name}.json", _ASSETS / f"{name}.json")
                shutil.rmtree(_ASSETS / f"{name}_textures", ignore_errors=True)
    except BuildFailure as exc:
        parser.exit(1, f"build-library: {exc}\n")

    wrote_index = _write_index(all_names)
    print("\nModel sizes")
    for name in selected:
        print(f"  {name:<28} {_human_size(sizes[name]):>10}")
    built_total = sum(sizes.values())
    print(f"  {'built USDZ total':<28} {_human_size(built_total):>10}")
    library_total = _library_size(all_names)
    print(f"  {'library with manifests':<28} {_human_size(library_total):>10}")
    if wrote_index:
        print(f"index: {_ASSETS / 'index.json'}")
    print(f"budget: {_human_size(library_total)} / {_human_size(_BUDGET_BYTES)}")


if __name__ == "__main__":
    main()
