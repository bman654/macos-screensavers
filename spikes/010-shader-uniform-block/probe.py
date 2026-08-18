#!/usr/bin/env python3
"""Patches one probe into the aquarium's real geometry shader modifier, or puts it back.

    spikes/010-shader-uniform-block/probe.py array|helper|six|eight|restore

The probes are deliberately applied to the *shipping* modifier rather than to a standalone
scene: what is being measured is how SceneKit binds a real material's custom-argument block,
and a probe with its own material would not reproduce the material-to-material difference
that is the whole finding. `restore` puts the two files back from the snapshot taken by the
first `apply`, so run it before doing anything else with the tree.
"""
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCES = ROOT / "Savers/Aquarium/Sources"
SWIM = SOURCES / "SwimDeformation.swift"
SCHOOL = SOURCES / "School.swift"
SNAPSHOT = HERE / "snapshot"

# The three insertion points, quoted from the shipping sources.
ARG_ANCHOR = "float spineZ;\n\\(spineArguments)\n"
BODY_ANCHOR = ("float tailward = clamp((bodyMinX + bodyLength - _geometry.position.x)"
               " / bodyLength, 0.0, 1.0);\n")
SET_ANCHOR = '                material.setValue(NSNumber(value: 0.0), forKey: "finAmplitude")\n'


def snapshot():
    SNAPSHOT.mkdir(exist_ok=True)
    for path in (SWIM, SCHOOL):
        target = SNAPSHOT / path.name
        if not target.exists():
            shutil.copy(path, target)


def restore():
    for path in (SWIM, SCHOOL):
        target = SNAPSHOT / path.name
        if target.exists():
            shutil.copy(target, path)


def apply(name):
    snapshot()
    restore()
    swim = SWIM.read_text()
    school = SCHOOL.read_text()

    if name == "array":
        swim = swim.replace(ARG_ANCHOR, ARG_ANCHOR + "float probeArray[4];\n")
        swim = swim.replace(BODY_ANCHOR,
                            BODY_ANCHOR + "_geometry.position.y += probeArray[0];\n")
    elif name == "helper":
        swim = swim.replace(ARG_ANCHOR,
                            ARG_ANCHOR + "float3 probeHelper(float4 c) { return c.xyz; }\n")
        swim = swim.replace(BODY_ANCHOR,
                            BODY_ANCHOR + "_geometry.position.y += probeHelper(float4(0.0)).x;\n")
    elif name in ("six", "eight"):
        extra = 3 if name == "six" else 5
        swim = swim.replace(
            ARG_ANCHOR,
            ARG_ANCHOR + "".join(f"float4x4 probe{i};\n" for i in range(extra)))
        # Only the six-matrix probe reads one, and it reads the fourth — the first matrix that
        # straddles byte 256 of the block.
        if name == "six":
            swim = swim.replace(BODY_ANCHOR,
                                BODY_ANCHOR + "_geometry.position.xyz += probe0[0].xyz;\n")
        # Written as all-zero matrices, so that a correct read is a no-op and anything visible
        # is the block being read wrongly rather than an argument nobody set.
        school = school.replace(SET_ANCHOR, SET_ANCHOR + "".join(
            f'                material.setValue(NSValue(scnMatrix4: SCNMatrix4()), '
            f'forKey: "probe{i}")\n' for i in range(extra)))
    else:
        sys.exit(f"unknown probe: {name}")

    SWIM.write_text(swim)
    SCHOOL.write_text(school)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if sys.argv[1] == "restore":
        restore()
    else:
        apply(sys.argv[1])
    print(f"probe: {sys.argv[1]}")
