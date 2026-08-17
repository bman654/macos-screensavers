#!/usr/bin/env bash
# Build a loadable legacy ScreenSaverView bundle without requiring Xcode.
#
# The explicit MH_BUNDLE link mode and post-link Obj-C class check prevent two failures that
# otherwise surface only as an unexplained black screen in Foundation's screensaver host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
usage: $0 <Name|path> [-i|--install] [--install-dir DIR] [--sign IDENTITY] [--out DIR]

  Name               builds Savers/Name
  path               builds that saver directory directly
  -i, --install      installs into ~/Library/Screen Savers and restarts the host
  --install-dir DIR  with --install, uses DIR instead (for isolated testing)
  --sign IDENTITY    signs with IDENTITY instead of an ad-hoc identity (-)
  --out DIR          writes the bundle into DIR (default: $ROOT/build)
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi
if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

SAVER_ARGUMENT="$1"
shift
INSTALL=false
INSTALL_DIR="$HOME/Library/Screen Savers"
SIGN_IDENTITY="-"
OUT_DIR="$ROOT/build"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--install)
      INSTALL=true
      shift
      ;;
    --install-dir)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --install-dir requires a directory" >&2
        exit 2
      fi
      INSTALL_DIR="$2"
      shift 2
      ;;
    --sign)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --sign requires an identity" >&2
        exit 2
      fi
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --out)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --out requires a directory" >&2
        exit 2
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SAVER_ARGUMENT" == */* ]]; then
  SAVER_DIR="$SAVER_ARGUMENT"
else
  SAVER_DIR="$ROOT/Savers/$SAVER_ARGUMENT"
fi

if [[ ! -d "$SAVER_DIR" ]]; then
  echo "error: saver directory not found: $SAVER_DIR" >&2
  exit 1
fi

# A Swift module and its bare Objective-C principal class both need identifier-safe names.
NAME="$(basename "${SAVER_DIR%/}")"
if [[ ! "$NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "error: saver directory basename must be a Swift identifier: $NAME" >&2
  exit 1
fi
PRINCIPAL_CLASS="${NAME}View"
mkdir -p "$OUT_DIR"
FINAL_BUNDLE="$OUT_DIR/$NAME.saver"
STAGING_BUNDLE="$OUT_DIR/.${NAME}.saver.build.$$"
BUNDLE="$STAGING_BUNDLE"
EXECUTABLE="$BUNDLE/Contents/MacOS/$NAME"
RESOURCES="$BUNDLE/Contents/Resources"
METAL_TMP=""
INSTALL_STAGING=""
INSTALL_BACKUP=""
INSTALLED_BUNDLE=""
INSTALL_REPLACEMENT_IN_POSITION=false
INSTALL_COMPLETE=false

cleanup() {
  local status=$?

  # Restoration has to precede disposable-file cleanup: an EPERM while removing staging must
  # not strand the known-good saver under its backup name.
  if [[ "$INSTALL_COMPLETE" != true ]]; then
    if [[ -n "$INSTALL_BACKUP" && ( -e "$INSTALL_BACKUP" || -L "$INSTALL_BACKUP" ) ]]; then
      if rm -rf "$INSTALLED_BUNDLE" && mv "$INSTALL_BACKUP" "$INSTALLED_BUNDLE"; then
        echo "Restored $INSTALLED_BUNDLE after installation failed." >&2
      else
        echo "error: could not restore installed saver from $INSTALL_BACKUP" >&2
      fi
    elif [[ "$INSTALL_REPLACEMENT_IN_POSITION" == true ]]; then
      rm -rf "$INSTALLED_BUNDLE" || true
    fi
  fi

  rm -rf "$STAGING_BUNDLE" || true
  [[ -z "$METAL_TMP" ]] || rm -rf "$METAL_TMP" || true
  [[ -z "$INSTALL_STAGING" ]] || rm -rf "$INSTALL_STAGING" || true

  return "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

SOURCES=()
if [[ -d "$ROOT/Shared/SaverKit" ]]; then
  while IFS= read -r source; do
    SOURCES+=("$source")
  done < <(find "$ROOT/Shared/SaverKit" -type f -name '*.swift' -print | LC_ALL=C sort)
fi
if [[ -d "$SAVER_DIR/Sources" ]]; then
  while IFS= read -r source; do
    SOURCES+=("$source")
  done < <(find "$SAVER_DIR/Sources" -type f -name '*.swift' -print | LC_ALL=C sort)
fi

if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "error: no Swift sources found in Shared/SaverKit or $SAVER_DIR/Sources" >&2
  exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$RESOURCES"

cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$NAME</string>
  <key>CFBundleIdentifier</key>
  <string>dev.saverkit.$NAME</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$NAME</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSPrincipalClass</key>
  <string>$PRINCIPAL_CLASS</string>
</dict>
</plist>
EOF

printf 'Compiling %s (%d Swift sources)...\n' "$NAME" "${#SOURCES[@]}"
if ! swiftc \
  -emit-library -Xlinker -bundle \
  -target arm64-apple-macosx26.0 \
  -module-name "$NAME" \
  -parse-as-library \
  -O \
  -framework ScreenSaver -framework AppKit -framework SceneKit \
  -framework Metal -framework MetalKit -framework QuartzCore \
  "${SOURCES[@]}" \
  -o "$EXECUTABLE"
then
  echo "error: Swift compilation failed for $NAME" >&2
  rm -rf "$BUNDLE"
  exit 1
fi

# Foundation may silently choose another class when NSPrincipalClass is misspelled, so prove
# the generated plist's bare Objective-C name is actually exported before making a bundle.
if ! otool -v -s __TEXT __objc_classname "$EXECUTABLE" 2>/dev/null \
      | grep -Eq "(^|[[:space:]])${PRINCIPAL_CLASS}($|[[:space:]])" \
    || ! nm -a "$EXECUTABLE" 2>/dev/null \
      | grep -F " _OBJC_CLASS_\$_${PRINCIPAL_CLASS}" >/dev/null; then
  echo "error: principal class '$PRINCIPAL_CLASS' is absent from the binary's Obj-C class list" >&2
  echo "       Declare the saver class with @objc($PRINCIPAL_CLASS) so bare NSPrincipalClass resolves." >&2
  rm -rf "$BUNDLE"
  exit 1
fi

if [[ -d "$SAVER_DIR/Assets" ]]; then
  ditto "$SAVER_DIR/Assets" "$RESOURCES"
fi

# The picker finds a saver's tile by filename, at Contents/Resources/thumbnail.png — no
# Info.plist key names it, and without the file the tile is a generic swirl however good the
# saver looks running. Kept out of Assets/ because that directory is generated build output.
if [[ -d "$SAVER_DIR/Thumbnail" ]]; then
  for thumbnail in "$SAVER_DIR"/Thumbnail/thumbnail*.png; do
    [[ -f "$thumbnail" ]] || continue
    cp "$thumbnail" "$RESOURCES/"
  done
fi

SHADER_SOURCES=()
if [[ -d "$SAVER_DIR/Shaders" ]]; then
  mkdir -p "$RESOURCES/Shaders"
  for shader in "$SAVER_DIR"/Shaders/*.metal; do
    [[ -f "$shader" ]] || continue
    cp "$shader" "$RESOURCES/Shaders/"
    SHADER_SOURCES+=("$shader")
  done
fi

METAL_TOOLS_AVAILABLE=false
if xcrun -sdk macosx --find metal >/dev/null 2>&1 \
    && xcrun -sdk macosx --find metallib >/dev/null 2>&1; then
  METAL_TOOLS_AVAILABLE=true
fi

if [[ ${#SHADER_SOURCES[@]} -gt 0 ]]; then
  METAL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/build-saver-metal.XXXXXX")"

  if [[ "$METAL_TOOLS_AVAILABLE" == true ]]; then
    AIR_FILES=()
    index=0
    for shader in "${SHADER_SOURCES[@]}"; do
      air="$METAL_TMP/$index.air"
      if ! xcrun -sdk macosx metal -c "$shader" -o "$air"; then
        echo "error: Metal shader compilation failed for $NAME" >&2
        rm -rf "$BUNDLE"
        exit 1
      fi
      AIR_FILES+=("$air")
      index=$((index + 1))
    done
    if ! xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$RESOURCES/default.metallib"; then
      echo "error: Metal library creation failed for $NAME" >&2
      rm -rf "$BUNDLE"
      exit 1
    fi
  else
    echo "Metal compiler unavailable; .metal sources will compile at runtime."
  fi

  # Source remains in every bundle as a fallback, so validate the loader's concatenated translation
  # unit even when a precompiled library exists; separate per-file compilation misses name collisions.
  cat > "$METAL_TMP/ValidateShaders.swift" <<'SWIFT'
import Foundation
import Metal

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("error: shader validator requires a saver bundle path")
}
guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
    fail("error: shader validator could not open bundle at \(CommandLine.arguments[1])")
}

let sourceURLs = bundle.urls(forResourcesWithExtension: "metal", subdirectory: "Shaders")?.sorted {
    $0.lastPathComponent < $1.lastPathComponent
} ?? []

var sources: [String] = []
for url in sourceURLs {
    do {
        sources.append(try String(contentsOf: url, encoding: .utf8))
    } catch {
        fail("error: could not read Metal shader source at \(url.path): \(error.localizedDescription)")
    }
}

guard let device = MTLCreateSystemDefaultDevice() else {
    fail("error: no Metal device is available to validate runtime shader source")
}

do {
    _ = try device.makeLibrary(source: sources.joined(separator: "\n\n"), options: nil)
} catch {
    fail("error: Metal runtime shader validation failed:\n\(error.localizedDescription)")
}
SWIFT
  if ! swiftc -framework Metal "$METAL_TMP/ValidateShaders.swift" \
      -o "$METAL_TMP/validate-shaders"; then
    echo "error: could not build the Metal shader validator" >&2
    rm -rf "$BUNDLE"
    exit 1
  fi
  if ! "$METAL_TMP/validate-shaders" "$BUNDLE"; then
    rm -rf "$BUNDLE"
    exit 1
  fi
fi

# ld already emits the ad-hoc signature arm64 requires. Explicit signing is still last because
# its _CodeSignature resource seal would be invalidated by any subsequent resource copy.
codesign --force --sign "$SIGN_IDENTITY" "$BUNDLE"
codesign --verify --strict "$BUNDLE"

# Sending build output directly to the install directory would make output promotion delete the
# live saver before the guarded install swap can run, so reject that unsafe configuration.
if [[ "$INSTALL" == true ]]; then
  mkdir -p "$INSTALL_DIR"
  OUT_ABSOLUTE="$(cd "$OUT_DIR" && pwd -P)"
  INSTALL_DIR_ABSOLUTE="$(cd "$INSTALL_DIR" && pwd -P)"
  if [[ "$OUT_ABSOLUTE" == "$INSTALL_DIR_ABSOLUTE" ]]; then
    echo "error: --out and --install-dir must be different directories when installing" >&2
    rm -rf "$BUNDLE"
    exit 1
  fi
fi

# Keep the previous output usable until compilation, validation, resources, and signing all pass.
rm -rf "$FINAL_BUNDLE"
mv "$STAGING_BUNDLE" "$FINAL_BUNDLE"
BUNDLE="$FINAL_BUNDLE"

if [[ "$INSTALL" == true ]]; then
  INSTALLED_BUNDLE="$INSTALL_DIR/$NAME.saver"
  BUNDLE_ABSOLUTE="$(cd "$(dirname "$BUNDLE")" && pwd -P)/$(basename "$BUNDLE")"
  INSTALLED_ABSOLUTE="$(cd "$INSTALL_DIR" && pwd -P)/$NAME.saver"
  if [[ "$BUNDLE_ABSOLUTE" != "$INSTALLED_ABSOLUTE" ]]; then
    # The selected saver must remain loadable until its replacement has survived both copying
    # and signature verification; otherwise an interrupted install turns the next screen blank.
    INSTALL_STAGING="$(mktemp -d "$INSTALL_DIR/.${NAME}.saver.install.XXXXXX")"
    INSTALL_BACKUP="${INSTALL_STAGING}.backup"
    ditto "$BUNDLE" "$INSTALL_STAGING"
    # mktemp's owner-only directory mode must not become the installed bundle's mode.
    chmod 755 "$INSTALL_STAGING"
    codesign --verify --strict "$INSTALL_STAGING"

    if [[ -e "$INSTALLED_BUNDLE" || -L "$INSTALLED_BUNDLE" ]]; then
      mv "$INSTALLED_BUNDLE" "$INSTALL_BACKUP"
    fi
    mv "$INSTALL_STAGING" "$INSTALLED_BUNDLE"
    INSTALL_REPLACEMENT_IN_POSITION=true
    codesign --verify --strict "$INSTALLED_BUNDLE"
    INSTALL_COMPLETE=true
    if [[ -e "$INSTALL_BACKUP" || -L "$INSTALL_BACKUP" ]]; then
      rm -rf "$INSTALL_BACKUP"
    fi
  fi
  # The host mmap()s loaded bundles, so replacing files cannot refresh its old executable.
  killall legacyScreenSaver 2>/dev/null || true
  echo "Installed $INSTALLED_BUNDLE"
else
  echo "Built $BUNDLE"
fi
