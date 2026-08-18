#!/usr/bin/env bash
# Build a saver at a given version and zip it for a GitHub release.
#
# `ditto -c -k --keepParent` rather than `zip`: the bundle is code-signed, and only ditto
# preserves the extended attributes and symlink structure that keep `codesign --verify`
# passing on the other side of the round trip. A plain `zip` produces an archive that
# unpacks into a bundle macOS then refuses to load.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
usage: $0 <Name> <version> [--out DIR] [--sign IDENTITY]

  Name          the saver to build, e.g. Aquarium
  version       marketing version, e.g. 1.0.0

  --out DIR     where the .zip lands (default: \$ROOT/build/release)
  --sign ID     signing identity passed through to build-saver.sh (default: ad-hoc)

Writes DIR/<Name>-<version>.zip plus a .sha256 beside it, and prints the tag the
release should carry.
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 2
fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

NAME="$1"
VERSION="$2"
shift 2
OUT_DIR="$ROOT/build/release"
SIGN_IDENTITY="-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 && -n "$2" ]] || { echo "error: --out requires a directory" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --sign)
      [[ $# -ge 2 && -n "$2" ]] || { echo "error: --sign requires an identity" >&2; exit 2; }
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: version must be dot-separated digits, got: $VERSION" >&2
  exit 2
fi

# The library and the grain bed are build outputs, not sources, so a fresh clone reaches this
# script with an empty Assets/ and would otherwise ship a saver with no fish and no sound.
ASSETS="$ROOT/Savers/$NAME/Assets"
if ! compgen -G "$ASSETS/*.usdz" > /dev/null; then
  echo "error: no models in $ASSETS — run tools/build-library.py first (needs Blender)" >&2
  exit 1
fi
if [[ ! -d "$ASSETS/audio" ]]; then
  echo "error: no grain library in $ASSETS/audio — run tools/build-audio.py first" >&2
  exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/package-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

"$ROOT/tools/build-saver.sh" "$NAME" --version "$VERSION" --sign "$SIGN_IDENTITY" --out "$STAGING"

BUNDLE="$STAGING/$NAME.saver"
[[ -d "$BUNDLE" ]] || { echo "error: build produced no bundle at $BUNDLE" >&2; exit 1; }

BUILT_VERSION="$(defaults read "$BUNDLE/Contents/Info" CFBundleShortVersionString)"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "error: bundle reports version $BUILT_VERSION, expected $VERSION" >&2
  exit 1
fi
codesign --verify --strict "$BUNDLE"

mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/$NAME-$VERSION.zip"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ARCHIVE"

# Verify the round trip rather than trusting it: an archive that unpacks into a bundle
# macOS refuses to load is indistinguishable from a good one until someone downloads it.
VERIFY="$STAGING/verify"
mkdir -p "$VERIFY"
ditto -x -k "$ARCHIVE" "$VERIFY"
codesign --verify --strict "$VERIFY/$NAME.saver"

( cd "$OUT_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )

printf '\n%s\n' "$ARCHIVE"
printf '  size    %s\n' "$(du -h "$ARCHIVE" | cut -f1)"
printf '  sha256  %s\n' "$(cut -d' ' -f1 < "$ARCHIVE.sha256")"
printf '  tag     %s\n' "$(echo "$NAME" | tr '[:upper:]' '[:lower:]')-$VERSION"
