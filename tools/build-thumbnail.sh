#!/usr/bin/env bash
# Render the Aquarium's picker tile.
#
# The tile in System Settings is a static image, not a live view, so a saver with no thumbnail
# resource gets a generic blue swirl no matter how good it looks running. This script is where
# the chosen frame is recorded, in the same spirit as the model scripts: the picture is a render
# of the saver, not a painting of it, so re-running this reproduces it.
#
# The frame below was chosen by looking at every candidate at 108x71 -- the size the picker
# actually draws -- and it is the aquarium look rather than the default shallowReef because at
# that size the reef's teal-on-grey reads as a smudge while the tank's bright gravel and its
# pink and orange fish survive the downscale.
#
# Re-running does not reproduce the committed PNG bit for bit: the layout, gravel and lighting
# are all pinned by the seed, but the fish are where the clock put them, so about 0.3% of pixels
# move. Any run gives the same tank.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Savers/Aquarium/Thumbnail"

STYLE=aquarium
SEED=5
SECONDS_IN=6

# The tile measures 108x71 points. Rendering at 10x leaves room for a larger tile in a future
# release and costs a few hundred kilobytes.
WIDTH=1080
HEIGHT=710

mkdir -p "$OUT"

echo "Rendering $STYLE seed $SEED at ${WIDTH}x${HEIGHT}..."
AQUARIUM_STYLE="$STYLE" AQUARIUM_SEED="$SEED" AQUARIUM_SHOW_SEED=0 \
    "$ROOT/tools/run-saver.swift" Aquarium \
    --size "${WIDTH}x${HEIGHT}" --seconds "$SECONDS_IN" \
    --screenshot "$OUT/thumbnail@2x.png"

# thumbnail.png is the 1x name and has to exist: an @2x file alone is honoured on this machine,
# but that was measured on a 1x display and the fallback direction is the one worth having.
cp "$OUT/thumbnail@2x.png" "$OUT/thumbnail.png"
sips -z $((HEIGHT / 2)) $((WIDTH / 2)) "$OUT/thumbnail.png" >/dev/null

echo "Wrote $OUT/thumbnail.png and $OUT/thumbnail@2x.png"
