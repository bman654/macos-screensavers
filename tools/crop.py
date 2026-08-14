#!/usr/bin/env python3
"""Cut a region out of a render so it can be looked at at 1:1.

This repo's hardest-won rule is to look at the PNG at the size it will be seen, and its
second-hardest is that a full-frame screenshot of a 4K tank shown at 2000 px wide has already
thrown away the thing you are judging. A substrate is the worst case of both: whether a floor
reads as gravel or as coloured static is a question about texels, and it survives no downscale
at all.

Regions are given as fractions of the frame, never in pixels, for the same reason
`water-luminance.py` states its bands as multiples of the floor entry depth: the renders come
in several shapes and at 1x and 2x, and a crop in pixels silently samples somewhere else on
each of them.

    tools/crop.py /tmp/tank.png --out /tmp/crop.png --region 0.3,0.8,0.7,1.0
    tools/crop.py /tmp/tank.png --out /tmp/crop.png --near-floor
    tools/crop.py /tmp/tank.png --out /tmp/crop.png --band --scale 2

Requires the repository's own interpreter, which carries Pillow:

    uv venv --python 3.14.3 .venv
    uv pip install --python .venv/bin/python numpy scipy pillow
"""

import argparse
import sys

from PIL import Image

# Named regions, as (left, top, right, bottom) fractions of the frame. Both look at the bottom
# of the frame because that is where the substrate is, and they differ in how much water they
# keep above it: the band crop is for judging the cross-section against the surface it meets,
# and the near-floor crop is for judging the surface's own grain.
REGIONS = {
    "near-floor": (0.30, 0.80, 0.70, 1.00),
    "band": (0.25, 0.84, 0.75, 1.00),
    "left-floor": (0.00, 0.82, 0.34, 1.00),
}


def parse_region(text):
    parts = [float(value) for value in text.split(",")]
    if len(parts) != 4:
        raise ValueError("a region is four comma-separated fractions: left,top,right,bottom")
    left, top, right, bottom = parts
    if not (0 <= left < right <= 1 and 0 <= top < bottom <= 1):
        raise ValueError(f"region {text} is not an ordered box inside the frame")
    return left, top, right, bottom


def crop(path, out, region, scale):
    image = Image.open(path)
    width, height = image.size
    left, top, right, bottom = region
    box = (int(width * left), int(height * top), int(width * right), int(height * bottom))
    cut = image.crop(box)
    if scale != 1:
        # Nearest, not bicubic: this is for counting texels, and a smooth resample invents
        # gradients across exactly the edges being judged.
        cut = cut.resize((cut.width * scale, cut.height * scale), Image.NEAREST)
    cut.save(out)
    print(f"[crop] {out}  {cut.width}x{cut.height}  from {width}x{height} at {region}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--out", required=True)
    parser.add_argument("--region", help="left,top,right,bottom as fractions of the frame")
    for name in REGIONS:
        parser.add_argument(f"--{name}", action="store_true", help=f"the {name} region")
    parser.add_argument("--scale", type=int, default=1,
                        help="nearest-neighbour magnification, for counting texels")
    args = parser.parse_args()

    named = [name for name in REGIONS if getattr(args, name.replace("-", "_"))]
    if len(named) + bool(args.region) != 1:
        sys.exit("give exactly one of --region or a named region")
    region = parse_region(args.region) if args.region else REGIONS[named[0]]
    crop(args.input, args.out, region, max(1, args.scale))


if __name__ == "__main__":
    main()
