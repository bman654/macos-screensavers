#!/usr/bin/env python3
"""Build the complete Origami Dogfight model library.

    tools/build-origami-library.py              # every model, into Savers/OrigamiDogfight/Assets
    tools/build-origami-library.py --only dart  # just one (repeatable)

Each model is built headlessly by `Savers/OrigamiDogfight/Models/build_model.py`, which
checks the asset contract inside Blender before writing anything. This script checks it
again from the outside, on the files the saver will actually load: the archive is a USDZ,
`usdcat` can load it, every mesh carries per-face normals, the manifest says what the
contract says it must, and a plane's sheet UVs and a fire's flames are really in the file.
Nothing is installed unless every selected model passes.

No textures are baked: every model is flat colour except the crumpled paper ball, whose
lined paper is a small image packaged with it.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

_REPO = Path(__file__).resolve().parents[1]
_MODELS = _REPO / "Savers" / "OrigamiDogfight" / "Models"
_ASSETS = _REPO / "Savers" / "OrigamiDogfight" / "Assets"
_RUN_BLENDER = _REPO / "tools" / "blender" / "run.sh"
_BUILD_MODEL = _MODELS / "build_model.py"
_ERROR = re.compile(r"Error|Traceback")
# Flat-shaded paper is a few kilobytes a model; the whole library was about half a megabyte
# when it was first built. The budget is generous headroom over that, not a target, and a
# model that breaks it has almost certainly grown a texture or a dense mesh by accident.
_BUDGET_BYTES = 3_000_000
_KINDS = ("plane", "projectile", "tree", "rock", "house", "boat", "fire", "smoke")


class BuildFailure(RuntimeError):
    pass


def _blender(arguments, name):
    result = subprocess.run(
        [os.fspath(_RUN_BLENDER), os.fspath(_BUILD_MODEL), "--", *arguments],
        cwd=_REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    output = result.stdout or ""
    errors = [line for line in output.splitlines() if _ERROR.search(line)]
    if result.returncode or errors:
        detail = f"exit status {result.returncode}"
        if errors:
            detail += f", error output: {' | '.join(errors)}"
        raise BuildFailure(f"{name} failed ({detail})\n{output}")
    return output


def _catalog():
    output = _blender(["--list"], "listing the catalog")
    for line in output.splitlines():
        if line.startswith("[build_model] catalog: "):
            return json.loads(line.split(": ", 1)[1])
    raise BuildFailure(f"build_model.py --list printed no catalog:\n{output}")


def _usda(asset):
    check = subprocess.run(["usdcat", "--loadOnly", os.fspath(asset)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if check.returncode:
        raise BuildFailure(f"usdcat could not load {asset.name}:\n{check.stdout}")
    text = subprocess.run(["usdcat", os.fspath(asset)],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if text.returncode:
        raise BuildFailure(f"usdcat could not print {asset.name}:\n{text.stdout}")
    return text.stdout


def _meshes(usda):
    """{mesh prim name: its body text} for every Mesh prim in a flattened layer."""
    meshes = {}
    for match in re.finditer(r'def Mesh "([^"]+)"', usda):
        start = match.end()
        following = re.search(r'\n\s*def (?:Mesh|Xform|Scope) "', usda[start:])
        meshes[match.group(1)] = usda[start:start + following.start() if following else None]
    return meshes


def _validate(name, kind, asset, manifest_path):
    if not asset.is_file() or asset.stat().st_size == 0:
        raise BuildFailure(f"{name} produced no USDZ")
    if not zipfile.is_zipfile(asset):
        raise BuildFailure(f"{asset.name} is not a USDZ archive")
    with zipfile.ZipFile(asset) as archive:
        members = archive.namelist()

    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise BuildFailure(f"could not read {manifest_path.name}: {exc}") from exc
    for field in ("name", "kind", "asset", "bounds", "anchor", "materials"):
        if field not in manifest:
            raise BuildFailure(f"{manifest_path.name} has no {field!r}")
    if manifest["name"] != name or manifest["asset"] != f"{name}.usdz":
        raise BuildFailure(f"{manifest_path.name} describes {manifest['name']!r} / "
                           f"{manifest['asset']!r}, expected {name!r}")
    if manifest["kind"] != kind or kind not in _KINDS:
        raise BuildFailure(f"{manifest_path.name} kind {manifest['kind']!r}, expected {kind!r}")
    lo, hi = manifest["bounds"].get("min"), manifest["bounds"].get("max")
    if not (isinstance(lo, list) and isinstance(hi, list) and len(lo) == len(hi) == 3
            and all(a < b for a, b in zip(lo, hi))):
        raise BuildFailure(f"{manifest_path.name} bounds are not a min < max box: "
                           f"{manifest['bounds']}")
    if manifest["anchor"] == "ground" and abs(lo[2]) > 1e-5:
        raise BuildFailure(f"{name} is grounded but its lowest point is z = {lo[2]}")

    usda = _usda(asset)
    meshes = _meshes(usda)
    if not meshes:
        raise BuildFailure(f"{asset.name} contains no Mesh prim")
    for mesh, body in meshes.items():
        # Flat shading travels as one normal per face corner. Without authored normals an
        # importer would invent smooth ones.
        if "normal3f[] normals" not in body or 'interpolation = "faceVarying"' not in body:
            raise BuildFailure(f"{asset.name}: mesh {mesh!r} has no per-corner normals")
    for material in manifest["materials"]:
        if f'def Material "{material}"' not in usda:
            raise BuildFailure(f"{asset.name} lacks the manifest's material {material!r}")

    if kind == "plane":
        if manifest["materials"] != ["paper"]:
            raise BuildFailure(f"{name}: a plane has exactly one material, paper")
        if not manifest.get("sheetAspect", 0) > 0:
            raise BuildFailure(f"{name}: a plane's manifest needs sheetAspect")
        if list(meshes) != [name]:
            raise BuildFailure(f"{name}: a plane is one mesh named {name!r}, got {list(meshes)}")
        uv = re.search(r"texCoord2f\[\] primvars:st = \[(.*?)\]", meshes[name], re.DOTALL)
        if uv is None:
            raise BuildFailure(f"{name}: no primvars:st sheet UVs")
        values = [float(v) for v in re.findall(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", uv.group(1))]
        if min(values) < -1e-6 or max(values) > 1 + 1e-6:
            raise BuildFailure(f"{name}: sheet UVs leave [0, 1]")
    if kind == "fire":
        flames = [entry["node"] for entry in manifest.get("flames", [])]
        expected = [f"flame_{i}" for i in range(len(flames))]
        if not 3 <= len(flames) <= 6 or flames != expected:
            raise BuildFailure(f"{name}: manifest flames {flames}")
        missing = [flame for flame in flames if flame not in meshes]
        if missing:
            raise BuildFailure(f"{asset.name} has no Mesh prim for {missing}")
    textures = [m for m in members if m.lower().endswith((".png", ".jpg", ".jpeg"))]
    if re.search(r"asset inputs:file", usda) and not textures:
        raise BuildFailure(f"{asset.name} references a texture it does not contain")
    return asset.stat().st_size + manifest_path.stat().st_size


def _build_one(name, kind, staging):
    asset = staging / f"{name}.usdz"
    _blender(["--model", name, "--export", os.fspath(asset)], name)
    size = _validate(name, kind, asset, staging / f"{name}.json")
    return name, size


def _human(size):
    return f"{size / 1_000:.1f} KB" if size < 1_000_000 else f"{size / 1_000_000:.2f} MB"


def _installed_size(names):
    return sum((_ASSETS / f"{n}{ext}").stat().st_size
               for n in names for ext in (".usdz", ".json")
               if (_ASSETS / f"{n}{ext}").is_file())


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--only", action="append", default=[], metavar="NAME",
                        help="build only this model; repeatable")
    parser.add_argument("--jobs", type=int, default=4,
                        help="Blender processes at once (models are independent)")
    args = parser.parse_args()

    try:
        catalog = _catalog()
    except BuildFailure as exc:
        parser.exit(1, f"build-origami-library: {exc}\n")
    unknown = sorted(set(args.only) - set(catalog))
    if unknown:
        parser.error(f"unknown model(s): {', '.join(unknown)}")
    selected = [n for n in sorted(catalog) if not args.only or n in args.only]
    full_build = len(selected) == len(catalog)

    _ASSETS.mkdir(parents=True, exist_ok=True)
    (_REPO / "build").mkdir(exist_ok=True)
    sizes = {}
    try:
        with tempfile.TemporaryDirectory(prefix="origami-library-", dir=_REPO / "build") as temp:
            staging = Path(temp)
            with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
                futures = [pool.submit(_build_one, n, catalog[n], staging) for n in selected]
                for future in futures:
                    name, size = future.result()
                    sizes[name] = size
                    print(f"[{catalog[name]}] {name}: {_human(size)}")

            others = [n for n in catalog if n not in sizes]
            projected = sum(sizes.values()) + _installed_size(others)
            if projected > _BUDGET_BYTES:
                raise BuildFailure(f"the library would weigh {_human(projected)}, over the "
                                   f"{_human(_BUDGET_BYTES)} budget")

            for name in selected:
                os.replace(staging / f"{name}.usdz", _ASSETS / f"{name}.usdz")
                os.replace(staging / f"{name}.json", _ASSETS / f"{name}.json")
    except BuildFailure as exc:
        parser.exit(1, f"build-origami-library: {exc}\n")

    if full_build:
        # A renamed or removed model leaves its old files behind; after a whole library
        # lands, anything the catalog no longer names is an orphan the saver would load.
        for path in list(_ASSETS.glob("*.usdz")) + list(_ASSETS.glob("*.json")):
            if path.stem not in catalog and path.name != "index.json":
                print(f"removing orphaned {path.name}")
                path.unlink()

    present = [n for n in sorted(catalog)
               if (_ASSETS / f"{n}.usdz").is_file() and (_ASSETS / f"{n}.json").is_file()]
    if len(present) == len(catalog):
        (_ASSETS / "index.json").write_text(
            json.dumps({"models": [f"{n}.json" for n in present]}, indent=2) + "\n")
        print(f"index: {_ASSETS / 'index.json'} ({len(present)} models)")
    else:
        missing = sorted(set(catalog) - set(present))
        print(f"index.json unchanged: the library is incomplete (missing {', '.join(missing)})")

    print("\nModel sizes (usdz + manifest)")
    for kind in _KINDS:
        for name in sorted(n for n in sizes if catalog[n] == kind):
            print(f"  {kind:<11} {name:<14} {_human(sizes[name]):>10}")
    total = _installed_size(catalog) + sum(
        p.stat().st_size for p in [_ASSETS / "index.json"] if p.is_file())
    print(f"library: {_human(total)} / {_human(_BUDGET_BYTES)} budget, "
          f"{len(present)} of {len(catalog)} models in {_ASSETS}")


if __name__ == "__main__":
    sys.exit(main())
