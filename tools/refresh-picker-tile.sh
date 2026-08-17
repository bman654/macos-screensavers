#!/usr/bin/env bash
# Make the Screen Saver picker re-read savers' tiles from their bundles.
#
# The picker renders each saver's tile once, caches the result as a hashed PNG, and never
# invalidates it when the bundle changes. Ship a new thumbnail into a saver the machine has
# already seen and the tile stays exactly as it was — no error, nothing stale-looking, just the
# old picture. Restarting System Settings does not help and neither does killing
# legacyScreenSaver, which is what makes this cost an afternoon the first time.
#
# Everything removed here is a cache and regenerates on the next look at the picker.
set -euo pipefail

CACHE_ROOT="$(getconf DARWIN_USER_CACHE_DIR)"
if [[ -z "$CACHE_ROOT" || "$CACHE_ROOT" != /var/folders/* ]]; then
  echo "error: refusing to delete anything — DARWIN_USER_CACHE_DIR is '$CACHE_ROOT'" >&2
  exit 1
fi

TILES="${CACHE_ROOT}com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
VIEW_MODEL="${CACHE_ROOT}com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.legacy-screenSaver"

# The view model maps each saver to its tile's hashed path, so removing tiles without it leaves
# the picker pointing at files that are gone.
if [[ -d "$TILES" ]]; then
  count=$(find "$TILES" -type f -name '*.png' | wc -l | tr -d ' ')
  rm -f "$TILES"/*.png
  echo "Cleared $count cached tile(s)."
else
  echo "No tile cache present; nothing to clear."
fi

if [[ -f "$VIEW_MODEL" ]]; then
  rm -f "$VIEW_MODEL"
  echo "Cleared the legacy screen saver view model."
fi

# The picker's own list is cached in-process too, so the app has to go as well as the agent.
osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true
killall WallpaperAgent 2>/dev/null || true

echo "Reopen System Settings > Wallpaper > \"Screen Saver…\" and expand Other to see the tile."
