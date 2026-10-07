#!/usr/bin/env bash
# Render Origami Dogfight's picker tile.
#
# The tile in System Settings is a static image read out of the bundle, so this script is where
# the chosen frame is recorded: the picture is a render of the saver, not a painting of it, and
# re-running this reproduces it. `docs/saver-host.md` §1 has the rules it follows.
#
# It is a *crop* of a full frame, which the Aquarium's tile is not, and that was decided by
# looking at candidates at 108x71, the size the picker draws. The whole arena at that size is a
# handsome paper map with the planes reduced to six-pixel specks — nothing in it says "dogfight".
# Cropped to the fight, a three-team match: yellow, red and violet planes cross over the meadow,
# two wrecks burn, and four paper tanks — a red heavy, a red light, a yellow and a violet — hold
# the ground, all of it inside the central 88% the picker keeps.
# A crop changes nothing about how the saver draws: same camera, same light, same fight. The
# moment was found by scanning two hundred and forty seeds in the headless sim for a crop holding
# a tank, planes of two sides or more and a fresh fire, then judged by eye at tile size among
# the four best.
#
# The scoreboard is off for the tile: at 108x71 the card is a pale smudge in a corner, and the
# tile has room for one idea, which is the fight.
#
# ORIGAMI_FREEZE holds the fight at the end of the warmup, so the seed and the warmup name one
# exact frame. Only the fire's flicker and its sparks move between runs. **Any change to the
# simulation moves the fight**, so after one the frame below shows a different moment — usually
# empty landscape — and has to be chosen again; look at the tile after every re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Savers/OrigamiDogfight/Thumbnail"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/origami-thumbnail.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

SEED=149
TEAMS=teams
TIER=some
TANKS=always
# A whole number of 1/120 s steps, nudged past the boundary so rounding cannot drop one.
WARMUP=87.7504

# The frame is drawn at 4320x2840, the tile's aspect, and the crop taken from it is still
# larger than the 1080x710 tile, so the tile is a downsample rather than an enlargement.
WIDTH=4320
HEIGHT=2840
CROP_X=960
CROP_Y=680
CROP_W=1760
CROP_H=1157

# Ten times the 108x71-point tile, and half that for the 1x name.
TILE_W=1080
TILE_H=710

mkdir -p "$OUT"
echo "Rendering seed $SEED ($TEAMS, $TIER planes, tanks $TANKS, ${WARMUP}s in) at ${WIDTH}x${HEIGHT}..."
ORIGAMI_SEED="$SEED" ORIGAMI_TEAMS="$TEAMS" ORIGAMI_PLANES_TIER="$TIER" ORIGAMI_TANKS="$TANKS" \
    ORIGAMI_SCOREBOARD=0 ORIGAMI_WARMUP="$WARMUP" ORIGAMI_FREEZE=1 \
    "$ROOT/tools/run-saver.swift" OrigamiDogfight \
    --size "${WIDTH}x${HEIGHT}" --seconds 3 --screenshot "$SCRATCH/frame.png"

# run-saver captures the window's backing pixels, so on a Retina display the frame comes back
# at twice the size asked for, and crop offsets stated in points would land on the wrong part
# of it. Normalise to the size the crop was chosen at first; on a 1x display this is a no-op.
captured_w=$(sips -g pixelWidth "$SCRATCH/frame.png" | awk '/pixelWidth/ {print $2}')
captured_h=$(sips -g pixelHeight "$SCRATCH/frame.png" | awk '/pixelHeight/ {print $2}')
if [[ "$captured_w" != "$WIDTH" || "$captured_h" != "$HEIGHT" ]]; then
  echo "Capture is ${captured_w}x${captured_h}; resampling to ${WIDTH}x${HEIGHT} before cropping."
  sips -z "$HEIGHT" "$WIDTH" "$SCRATCH/frame.png" --out "$SCRATCH/frame.png" >/dev/null
fi

sips -c "$CROP_H" "$CROP_W" --cropOffset "$CROP_Y" "$CROP_X" "$SCRATCH/frame.png" \
    --out "$SCRATCH/crop.png" >/dev/null
sips -z "$TILE_H" "$TILE_W" "$SCRATCH/crop.png" --out "$OUT/thumbnail@2x.png" >/dev/null
# thumbnail.png is the 1x name and has to exist: an @2x file alone is honoured on this machine,
# but that was measured on a 1x display and the fallback direction is the one worth having.
sips -z $((TILE_H / 2)) $((TILE_W / 2)) "$SCRATCH/crop.png" --out "$OUT/thumbnail.png" >/dev/null

echo "Wrote $OUT/thumbnail.png and $OUT/thumbnail@2x.png"
