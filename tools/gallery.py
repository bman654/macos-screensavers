#!/usr/bin/env python3
"""Tile many renders into one labelled review sheet.

`saverlib.studio.contact_sheet` shows one model from six angles. This shows many models
from one angle, which is the image you actually want when deciding whether a library of
fish reads as a library rather than as one fish recoloured.

    tools/gallery.py --out build/gallery/fish.png --columns 4 \\
        'build/fish/*/studio_00_side.png'

Labels default to the containing directory's name, which is how the build scripts lay
renders out. `path=label` overrides that for a single entry.
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys

_FONTS = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def _font():
    for path in _FONTS:
        if os.path.exists(path):
            return path
    return None


def _escape(text):
    """drawtext parses its own value, so colons and backslashes must be escaped."""
    return text.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’")


def collect(patterns):
    """Expand `path` or `path=label` arguments into (path, label) pairs, sorted."""
    entries = []
    for pattern in patterns:
        pattern, _, label = pattern.partition("=")
        matches = sorted(glob.glob(pattern)) or ([pattern] if os.path.exists(pattern) else [])
        if not matches:
            print(f"[gallery] no match: {pattern}", file=sys.stderr)
        for path in matches:
            entries.append((path, label or os.path.basename(os.path.dirname(path))))
    return entries


def build_sheet(entries, out_path, columns, cell, background="0x14161a", label_height=44):
    width, height = cell
    rows = (len(entries) + columns - 1) // columns
    font = _font()

    command = ["ffmpeg", "-y", "-loglevel", "error"]
    for path, _ in entries:
        command += ["-i", path]

    filters, layout = [], []
    for index, (_, label) in enumerate(entries):
        chain = (
            f"[{index}:v]scale={width}:{height - label_height}"
            f":force_original_aspect_ratio=decrease,"
            f"pad={width}:{height}:(ow-iw)/2:0:color={background}"
        )
        if font:
            chain += (
                f",drawtext=fontfile='{font}':text='{_escape(label)}'"
                f":fontcolor=0xd8dde5:fontsize=26:x=(w-text_w)/2:y=h-{label_height - 8}"
            )
        filters.append(f"{chain}[v{index}]")
        column, row = index % columns, index // columns
        layout.append(f"{column * width}_{row * height}")

    # xstack needs a full grid; pad the last row with copies of the background colour.
    blanks = rows * columns - len(entries)
    for extra in range(blanks):
        index = len(entries) + extra
        filters.append(
            f"color=c={background}:s={width}x{height}:d=1[v{index}]"
        )
        column, row = index % columns, index // columns
        layout.append(f"{column * width}_{row * height}")

    inputs = "".join(f"[v{i}]" for i in range(rows * columns))
    filters.append(
        f"{inputs}xstack=inputs={rows * columns}:layout={'|'.join(layout)}:fill={background}[out]"
    )

    command += [
        "-filter_complex", ";".join(filters),
        "-map", "[out]", "-frames:v", "1", out_path,
    ]
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    subprocess.run(command, check=True)
    return out_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", help="glob or path[=label]")
    parser.add_argument("--out", required=True)
    parser.add_argument("--columns", type=int, default=4)
    parser.add_argument("--cell", default="640x540", help="WxH per tile")
    args = parser.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("[gallery] ffmpeg not found")

    entries = collect(args.inputs)
    if not entries:
        sys.exit("[gallery] nothing to tile")

    width, height = (int(v) for v in args.cell.lower().split("x"))
    print(f"[gallery] {build_sheet(entries, args.out, args.columns, (width, height))}"
          f"  ({len(entries)} tiles)")


if __name__ == "__main__":
    main()
