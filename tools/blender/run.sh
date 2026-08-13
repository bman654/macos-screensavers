#!/usr/bin/env bash
# Run a model-building script inside Blender, headless.
#
#   tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- --species clownfish
#
# Blender's bundled Python does not see the repo, so the script itself puts `saverlib`
# on sys.path from its own location. This wrapper only resolves the binary and forwards
# arguments after `--` through to the script.
set -euo pipefail

BLENDER="${BLENDER:-}"
if [[ -z "$BLENDER" ]]; then
  for candidate in \
    /Applications/Blender.app/Contents/MacOS/Blender \
    "$(command -v blender 2>/dev/null || true)"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then BLENDER="$candidate"; break; fi
  done
fi

if [[ -z "$BLENDER" ]]; then
  echo "Blender not found. Install with: brew install --cask blender" >&2
  echo "Or set BLENDER=/path/to/Blender" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <script.py> [-- <script args>]" >&2
  exit 2
fi

SCRIPT="$1"; shift
[[ "${1:-}" == "--" ]] && shift   # accept the separator with or without it

exec "$BLENDER" --background --factory-startup --python "$SCRIPT" -- "$@"
