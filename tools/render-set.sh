#!/usr/bin/env bash
# Render one tank across several gravel palettes, into a directory, one at a time.
#
# Serial on purpose. Four concurrent `run-saver` processes each open a ScreenCaptureKit
# session and all four time out with "no ScreenCaptureKit callback arrived" — the capture
# path does not survive being asked for several windows at once, and the failure looks
# exactly like a broken build rather than like contention.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
usage: $0 --out DIR [--style STYLE] [--seed N] [--size WxH] [--seconds S] [PALETTE...]

  --out DIR      where the PNGs land, one per palette, named for it
  --style        aquarium (default) | shallowReef | deepOcean
  --seed         AQUARIUM_SEED (default 42)
  --size         drawable size (default 1600x900)
  --seconds      how long to run before the screenshot (default 3)
  PALETTE...     gravel palettes (default: river quartz neon tangerine — the four that
                 show an illuminant change most clearly)
EOF
}

OUT=""
STYLE=aquarium
SEED=42
SIZE=1600x900
SECONDS_ARG=3
PALETTES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --style) STYLE="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --seconds) SECONDS_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) PALETTES+=("$1"); shift ;;
  esac
done

if [[ -z "$OUT" ]]; then usage >&2; exit 2; fi
if [[ ${#PALETTES[@]} -eq 0 ]]; then PALETTES=(river quartz neon tangerine); fi

mkdir -p "$OUT"
for palette in "${PALETTES[@]}"; do
  log="$OUT/$palette.log"
  AQUARIUM_STYLE="$STYLE" AQUARIUM_GRAVEL="$palette" AQUARIUM_SEED="$SEED" \
    "$ROOT/tools/run-saver.swift" Aquarium --size "$SIZE" --seconds "$SECONDS_ARG" \
    --screenshot "$OUT/$palette.png" >"$log" 2>&1
  # A run that dies still exits past a pipeline, and the PNG you then open is the previous
  # run's — so check the log rather than trusting the exit status of a pipe.
  if grep -Eqi 'error|traceback|fatal' "$log"; then
    echo "FAILED $palette:" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "  $palette"
done
