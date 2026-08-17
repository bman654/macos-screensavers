#!/usr/bin/env python3
"""Measure the SceneKit baseline-versus-st1 shader render."""

import json
from pathlib import Path

from PIL import Image, ImageChops

SPIKE_DIR = Path(__file__).resolve().parent
RENDER_DIR = SPIKE_DIR / "output" / "uv_fallback" / "scenekit"


def foreground_box(image):
    background = image.getpixel((0, 0))
    mask = Image.new("1", image.size)
    source = image.load()
    target = mask.load()
    for y in range(image.height):
        for x in range(image.width):
            target[x, y] = max(abs(source[x, y][i] - background[i]) for i in range(3)) > 8
    return mask.getbbox(), sum(mask.get_flattened_data())


def matching_box(image, predicate):
    points = [
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if predicate(image.getpixel((x, y)))
    ]
    if not points:
        return None
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return (min(xs), min(ys), max(xs) + 1, max(ys) + 1)


def main():
    baseline = Image.open(RENDER_DIR / "baseline.png").convert("RGB")
    displaced = Image.open(RENDER_DIR / "texcoord1-displaced.png").convert("RGB")
    color_displaced = Image.open(RENDER_DIR / "color-displaced.png").convert("RGB")
    difference = ImageChops.difference(baseline, displaced)
    mask = difference.convert("L").point(lambda value: 255 if value > 8 else 0)
    changed_box = mask.getbbox()
    changed_pixels = sum(value != 0 for value in mask.get_flattened_data())
    baseline_box, baseline_pixels = foreground_box(baseline)
    displaced_box, displaced_pixels = foreground_box(displaced)
    color_box, color_pixels = foreground_box(color_displaced)
    orange = lambda pixel: pixel[0] > pixel[2] + 50 and pixel[0] > pixel[1] + 50
    baseline_fin_box = matching_box(baseline, orange)
    displaced_fin_box = matching_box(displaced, orange)
    # The body top lies above y=255; the moving fin begins below it. This count catches any
    # unintended body deformation away from the root/occlusion boundary.
    upper_changed = sum(
        mask.getpixel((x, y)) != 0
        for y in range(0, 255)
        for x in range(mask.width)
    )
    report = {
        "image_size": list(baseline.size),
        "baseline_foreground_box": list(baseline_box),
        "displaced_foreground_box": list(displaced_box),
        "baseline_foreground_pixels": baseline_pixels,
        "displaced_foreground_pixels": displaced_pixels,
        "baseline_fin_box": list(baseline_fin_box),
        "displaced_fin_box": list(displaced_fin_box),
        "absent_color_foreground_box": list(color_box),
        "absent_color_foreground_pixels": color_pixels,
        "changed_pixels": changed_pixels,
        "changed_box": list(changed_box),
        "changed_pixels_above_y255": upper_changed,
    }
    output = SPIKE_DIR / "output" / "render-report.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
