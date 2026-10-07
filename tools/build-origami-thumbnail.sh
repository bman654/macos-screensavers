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
# Cropped to the fight, planes of all three teams — yellow, red and blue — read as folded paper
# tangling round fresh fires beside a snow cap, and all of it sits inside the central 88% the
# picker keeps. A crop changes nothing about how the saver draws: same camera, same light, same
# fight. The moment was found by scanning seeds for a tight cluster of planes from several sides
# near a fire that had just caught, then judged by eye at tile size.
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

SEED=61
MODE=teams3
PLANES=6
WARMUP=90

# The frame is drawn at twice the size it was chosen at (2160x1420) — the same aspect, so the
# same arena and the same fight — and the crop is taken from it at twice the offsets, so the
# tile is a downsample rather than an enlargement.
WIDTH=4320
HEIGHT=2840
CROP_X=1380
CROP_Y=460
CROP_W=1920
CROP_H=1262

# Ten times the 108x71-point tile, and half that for the 1x name.
TILE_W=1080
TILE_H=710

mkdir -p "$OUT"
echo "Rendering seed $SEED ($MODE, $PLANES planes, ${WARMUP}s in) at ${WIDTH}x${HEIGHT}..."
ORIGAMI_SEED="$SEED" ORIGAMI_MODE="$MODE" ORIGAMI_PLANES="$PLANES" ORIGAMI_WARMUP="$WARMUP" \
    ORIGAMI_FREEZE=1 \
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
