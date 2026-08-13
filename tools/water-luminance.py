#!/usr/bin/env python3
"""Measure the substrate-versus-water-column luminance relationship in a tank render.

The tank's look is coherent only if the ground does not out-brighten the water it is seen
through: light reaching the seabed and light scattering in the water column come from one
budget. Judging that by eye is exactly where an author went wrong once, so this reads the
delivered PNG and reports the relationship as numbers.

The bands are stated as multiples of the tank's own floor entry depth, not in pixels, because
that is the one thing that fixes the floor's screen position: the seabed sits one half-height
below the eye at `Tank.floorEntryDepth`, so floor at depth d lands at NDC y = -entry / d with
the aspect ratio cancelling. A band stated as k x entry therefore lands at NDC y = -1/k in any
tank at any drawable shape — which is what keeps the numbers comparable now that the tank's
dimensions are drawn per launch and per style. Pass --entry-depth to have the bands *labelled*
in metres for a particular tank; it does not move them.

Every band is sampled from the central 40% of the width so that the camera's vignette does
not bias one band against another, and reported as a *median* so that a fish or a prop
crossing the band moves the number far less than it moves a mean.

    tools/water-luminance.py /tmp/base.png [more.png ...]
    tools/water-luminance.py --entry-depth 2.25 /tmp/aquarium.png
"""

import sys
import numpy as np
from PIL import Image
from scipy import ndimage

# Tank.reference: nearDepth 5.5 x 1.127. Only ever used to label the bands.
REFERENCE_ENTRY_DEPTH = 6.2

# (label, near, far), as multiples of the floor entry depth. The first is the band the
# coherence rule is stated against; the other two are there to show the floor rising toward
# the backdrop with distance rather than falling away from it.
FLOOR_BANDS = [("floor  1.05-1.29x entry", 1.048, 1.290),
               ("floor  1.61-2.10x entry", 1.613, 2.097),
               ("floor  2.90-4.19x entry", 2.903, 4.194)]
# Water bands are open water above the horizon; the horizon (floor at infinity) is NDC y = 0.
WATER_BANDS = [("water backdrop (just above horizon)", 0.02, 0.20),
               ("water upper column", 0.45, 0.90)]

CENTRAL_WIDTH = 0.40


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def band_rows(ndc_low, ndc_high, height):
    """NDC y runs +1 at the top row to -1 at the bottom row."""
    r0 = int(round((1 - ndc_high) / 2 * height))
    r1 = int(round((1 - ndc_low) / 2 * height))
    return max(0, min(r0, r1)), min(height, max(r0, r1))


def sample(rgb, ndc_low, ndc_high):
    height, width, _ = rgb.shape
    r0, r1 = band_rows(ndc_low, ndc_high, height)
    c0 = int(width * (0.5 - CENTRAL_WIDTH / 2))
    c1 = int(width * (0.5 + CENTRAL_WIDTH / 2))
    patch = rgb[r0:r1, c0:c1].reshape(-1, 3)
    lin = srgb_to_linear(patch)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722])
    # The median pixel of the band, not the mean of the channels, so the reported colour is
    # a colour that actually occurs there rather than a blend of sand and whatever crossed it.
    mid = np.argsort(lum)[len(lum) // 2]
    colour = patch[mid]
    mx, mn = colour.max(), colour.min()
    saturation = 0 if mx == 0 else (mx - mn) / mx
    return dict(luminance=float(np.median(lum)), colour=colour,
                saturation=float(saturation), rows=(r0, r1))


def fish_flanks(rgb):
    """Colour still carried by the fish crossing the open water.

    A tank exists to show off vivid fish, and the failure this catches is specific: a hard key
    from straight overhead lights a fish's *back*, while the flank — the whole visible surface,
    and the only part carrying the markings — goes unlit and grey. It is invisible in the
    lighting parameters and obvious once the same seed is compared between two looks.

    Fish are found as the pixels in the open water that differ from their own row's water
    colour, rather than by hue or by saturation: a *washed-out* fish must stay in the sample or
    the measurement congratulates itself by discarding its own failure case. Marine snow is
    excluded as the one thing that is both brighter than the water and near-neutral, because its
    density is deliberately different in each look and it would otherwise drag the looks apart
    for a reason that has nothing to do with fish.
    """
    height, width, _ = rgb.shape
    r0, r1 = band_rows(0.05, 0.95, height)
    # Central only, for the same reason every luminance band is: the vignette darkens the frame
    # edges by up to 23%, and a row's own median cannot describe both its middle and its corners.
    # Left to the full width, the two darkened edges are the largest "not water" regions in the
    # frame by a distance, and being water they carry no chroma at all — they decided the
    # statistic outright once the size ceiling was widened enough to admit them.
    c0, c1 = int(width * 0.2), int(width * 0.8)
    band = rgb[r0:r1, c0:c1]
    water = np.median(band, axis=1, keepdims=True)          # per-row water colour
    delta = np.abs(band - water).max(axis=2)

    mx, mn = band.max(axis=2), band.min(axis=2)
    saturation = np.where(mx == 0, 0, (mx - mn) / np.maximum(mx, 1e-6))
    lum = band @ np.array([0.2126, 0.7152, 0.0722])
    water_lum = (water @ np.array([0.2126, 0.7152, 0.0722]))
    snow = (saturation < 0.15) & (lum > water_lum)

    mask = (delta > 0.05) & ~snow

    # Keep only fish-sized blobs. The band above the horizon is not fish alone — a wreck's mast
    # and the tall rock pillars reach well into it, and as large low-chroma regions they swamp
    # the statistic and make a look seem as though its fish had gone grey.
    #
    # Sized as a fraction of the frame rather than in pixels, because a tank's on-screen fish
    # size is a property of the tank: props hold their angular size while fish keep their real
    # metres, so a close-in tank's fish are three times the fraction of the frame that the
    # reference tank's are. A fixed pixel window calibrated on one tank silently discards the
    # subject of another — which is exactly what a fixed 6000 px ceiling did to the aquarium's
    # tangs, leaving the statistic to be decided by whatever small far fish were left.
    #
    # The ceiling alone cannot separate a near fish from a pillar, so the second rule does it by
    # attachment instead of by size: everything standing on the floor enters the band from below
    # and is therefore clipped by the band's bottom row, and a fish almost never is. It costs the
    # occasional fish swimming right at the horizon, which is the cheap direction to be wrong in.
    labels, count = ndimage.label(mask)
    if count == 0:
        return None
    sizes = np.bincount(labels.ravel())
    area = band.shape[0] * band.shape[1]
    keep = np.zeros(sizes.shape, dtype=bool)
    keep[1:] = (sizes[1:] >= area * 0.0001) & (sizes[1:] <= area * 0.08)
    keep[np.unique(labels[-1])] = False
    mask = keep[labels]
    if mask.sum() < 200:
        return None

    # Distance in *chromaticity* from the water the fish is swimming in, not saturation.
    # Saturation answers the wrong question here: a tang washed toward the tank's own blue is
    # still a saturated blue and scores well, while having lost precisely the thing being
    # measured. Chromaticity is normalised by brightness, so a fish that is merely darker than
    # the water scores zero and only a fish holding a colour of its own scores at all.
    def chromaticity(a):
        total = np.maximum(a.sum(axis=-1, keepdims=True), 1e-6)
        return (a / total)[..., :2]

    distance = np.linalg.norm(chromaticity(band) - chromaticity(water), axis=2)[mask]
    return dict(pixels=int(mask.sum()), median=float(np.median(distance)),
                vivid=float((distance > 0.08).mean()))


def report(path, entry_depth):
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    print(f"\n{path}   {rgb.shape[1]}x{rgb.shape[0]}")
    print(f"  {'band':<38} {'Y(lin)':>8} {'sat':>6}  sRGB")

    results = {}
    for label, near, far in FLOOR_BANDS:
        s = sample(rgb, -1 / near, -1 / far)
        results[label] = s
        metres = f"({near * entry_depth:.1f}-{far * entry_depth:.1f}m)"
        print(f"  {label + ' ' + metres:<38} {s['luminance']:8.4f} {s['saturation']:6.2f}  "
              f"{tuple(round(float(c), 3) for c in s['colour'])}")
    for label, lo, hi in WATER_BANDS:
        s = sample(rgb, lo, hi)
        results[label] = s
        print(f"  {label:<38} {s['luminance']:8.4f} {s['saturation']:6.2f}  "
              f"{tuple(round(float(c), 3) for c in s['colour'])}")

    near = results[FLOOR_BANDS[0][0]]["luminance"]
    backdrop = results["water backdrop (just above horizon)"]["luminance"]
    ratio = near / backdrop if backdrop > 0 else float("inf")
    verdict = "OK" if ratio <= 1.0 else "INCOHERENT — ground out-brightens its own water"
    print(f"  near floor / water backdrop = {ratio:5.2f}   {verdict}")

    if flanks := fish_flanks(rgb):
        print(f"  fish flanks: median chroma-vs-water {flanks['median']:.3f}, "
              f"{flanks['vivid'] * 100:4.1f}% holding own colour, {flanks['pixels']} px")
    return ratio


if __name__ == "__main__":
    args = sys.argv[1:]
    entry_depth = REFERENCE_ENTRY_DEPTH
    if "--entry-depth" in args:
        index = args.index("--entry-depth")
        entry_depth = float(args[index + 1])
        del args[index:index + 2]
    if not args:
        sys.exit(__doc__)
    for path in args:
        report(path, entry_depth)
