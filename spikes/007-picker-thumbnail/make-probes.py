#!/usr/bin/env python3
"""Stamp out throwaway savers that answer, in one look at the picker, how Tahoe treats a
third-party saver's thumbnail resource.

Every probe is identical except for which thumbnail files it ships. Each probe's *live* drawing
is a different colour from its *thumbnail*, so the tile itself says which source the picker used
-- that is the only way to tell a static thumbnail from a live-rendered tile, and it is the first
thing that has to be established before shooting a real picture.

Run:  .venv/bin/python spikes/007-picker-thumbnail/make-probes.py --install
      .venv/bin/python spikes/007-picker-thumbnail/make-probes.py --uninstall
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
WORK = Path("/tmp/thumbprobe")
INSTALL_DIR = Path.home() / "Library" / "Screen Savers"

# Apple's own Random.saver ships exactly 90x58 and 180x116, and names neither in its Info.plist,
# so the size is as much a guess as the convention is. These probes bracket it.
FONT_PATH = "/System/Library/Fonts/Helvetica.ttc"

# The tile measures 108x71 points, so it is very nearly the 90x58 aspect Apple ships -- close
# enough that nothing is lost to letterboxing, and a ruler is the only way to see what the tile
# trims all round.
TILE_ASPECT = 108 / 71

# Bands of known inset, read back from the captured tile by colour. Each is 2% of the image
# height thick, outermost first.
RULER_BANDS = [
    (214, 32, 32),
    (232, 132, 16),
    (226, 210, 24),
    (36, 176, 60),
    (40, 96, 226),
]

# (probe, [(filename, width, height, rgb, caption, kind)], live rgb)
PROBES = [
    (
        "ThumbProbeA",
        [("thumbnail.png", 90, 58, (214, 32, 154), "A 90", "flat")],
        (12, 74, 40),
    ),
    (
        "ThumbProbeB",
        [
            ("thumbnail.png", 90, 58, (232, 120, 16), "B 90", "flat"),
            ("thumbnail@2x.png", 180, 116, (96, 40, 200), "B 180", "flat"),
        ],
        (12, 74, 40),
    ),
    (
        "ThumbProbeC",
        [("thumbnail.png", 640, 412, (16, 158, 190), "C 640", "flat")],
        (12, 74, 40),
    ),
    (
        "ThumbProbeD",
        [],
        (12, 74, 40),
    ),
    (
        # A ruler at the tile's own aspect, so whatever it loses is the tile trimming rather than
        # an aspect mismatch being cropped away.
        "ThumbProbeE",
        [("thumbnail.png", 1024, round(1024 / TILE_ASPECT), (250, 250, 250), "", "ruler")],
        (12, 74, 40),
    ),
    (
        # Only an @2x file. If this tile is the generic swirl, a saver must ship a 1x name.
        "ThumbProbeF",
        [("thumbnail@2x.png", 360, 237, (140, 200, 24), "F 2x", "flat")],
        (12, 74, 40),
    ),
]

VIEW_SOURCE = """import AppKit
import ScreenSaver

// A probe, not a saver: it draws one flat colour and its own name so that a picker tile which is
// rendering the view rather than reading a resource is unmistakable in a screenshot.
@objc({name}View)
final class {name}View: ScreenSaverView {{
    override init?(frame: NSRect, isPreview: Bool) {{
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 4.0
    }}

    @available(*, unavailable)
    required init?(coder: NSCoder) {{
        fatalError("init(coder:) is not used by the screensaver host")
    }}

    override func draw(_ rect: NSRect) {{
        NSColor(calibratedRed: {r}, green: {g}, blue: {b}, alpha: 1).setFill()
        bounds.fill()

        let text = "{label} LIVE" as NSString
        let size = max(8.0, bounds.height / 7.0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let measured = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: bounds.midX - measured.width / 2.0,
                y: bounds.midY - measured.height / 2.0
            ),
            withAttributes: attributes
        )
    }}

    override func animateOneFrame() {{
        needsDisplay = true
    }}

    override var hasConfigureSheet: Bool {{ false }}
    override var configureSheet: NSWindow? {{ nil }}
}}
"""


def draw_ruler(path: Path, width: int, height: int, rgb: tuple) -> None:
    """Concentric bands of known inset. Whichever colour survives at the tile's edge is how much
    of a thumbnail the picker trims, which is the difference between a composed frame and a
    frame with its subject shaved off."""
    image = Image.new("RGB", (width, height), rgb)
    draw = ImageDraw.Draw(image)
    step = height * 0.02
    for index, colour in enumerate(RULER_BANDS):
        inset = index * step
        draw.rectangle(
            [inset, inset, width - 1 - inset, height - 1 - inset],
            outline=colour,
            width=max(1, round(step)),
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def draw_thumbnail(path: Path, width: int, height: int, rgb: tuple, caption: str) -> None:
    """A flat field plus two shape probes: an edge frame (is the tile cropping?) and a true
    circle (is it stretching non-uniformly?). The field is left flat on purpose -- its colour is
    what names the file the picker actually loaded, and any texture over it muddies that under
    the picker's own downscale. Upscaling shows up in the letterforms instead."""
    image = Image.new("RGB", (width, height), rgb)
    draw = ImageDraw.Draw(image)

    stroke = max(1, round(min(width, height) / 40))
    draw.rectangle([0, 0, width - 1, height - 1], outline=(255, 255, 255), width=stroke)

    diameter = min(width, height) - 4 * stroke
    left = (width - diameter) / 2
    top = (height - diameter) / 2
    draw.ellipse([left, top, left + diameter, top + diameter], outline=(255, 255, 255), width=stroke)

    try:
        font = ImageFont.truetype(FONT_PATH, max(9, round(height / 3.2)))
    except OSError:
        font = ImageFont.load_default()
    box = draw.textbbox((0, 0), caption, font=font)
    draw.text(
        ((width - (box[2] - box[0])) / 2 - box[0], (height - (box[3] - box[1])) / 2 - box[1]),
        caption,
        font=font,
        fill=(255, 255, 255),
        stroke_width=max(1, stroke // 2),
        stroke_fill=(0, 0, 0),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def stage(name: str, thumbnails: list, live: tuple) -> Path:
    directory = WORK / name
    if directory.exists():
        shutil.rmtree(directory)
    (directory / "Sources").mkdir(parents=True)

    source = VIEW_SOURCE.format(
        name=name,
        label=name[-1],
        r=round(live[0] / 255, 4),
        g=round(live[1] / 255, 4),
        b=round(live[2] / 255, 4),
    )
    (directory / "Sources" / f"{name}View.swift").write_text(source)

    # build-saver.sh dittos Assets/ straight into Contents/Resources, which is where the
    # convention wants thumbnail.png to land, so no build change is needed to run the experiment.
    for filename, width, height, rgb, caption, kind in thumbnails:
        target = directory / "Assets" / filename
        if kind == "ruler":
            draw_ruler(target, width, height, rgb)
        else:
            draw_thumbnail(target, width, height, rgb, caption)

    return directory


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="install the probes into the picker")
    parser.add_argument("--uninstall", action="store_true", help="remove the probes and stop")
    arguments = parser.parse_args()

    if arguments.uninstall:
        for name, _, _ in PROBES:
            bundle = INSTALL_DIR / f"{name}.saver"
            if bundle.exists():
                shutil.rmtree(bundle)
                print(f"removed {bundle}")
        shutil.rmtree(WORK, ignore_errors=True)
        subprocess.run(["killall", "legacyScreenSaver"], check=False, capture_output=True)
        return 0

    WORK.mkdir(parents=True, exist_ok=True)
    for name, thumbnails, live in PROBES:
        directory = stage(name, thumbnails, live)
        command = [str(ROOT / "tools" / "build-saver.sh"), str(directory), "--out", str(WORK / "build")]
        if arguments.install:
            command.append("--install")
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            sys.stderr.write(result.stdout + result.stderr)
            return 1
        print(f"{name}: {result.stdout.strip().splitlines()[-1]}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
