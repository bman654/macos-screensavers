# The picker tile

What the Screen Saver picker does with a third-party saver's thumbnail, established by
measurement on macOS 26 (Tahoe) rather than from documentation. Everything below was read off
probe savers built by `make-probes.py`, each identical except for which thumbnail files it ships
and each drawing a *different colour live* than its thumbnail — so a tile that rendered the view
instead of reading a resource would have been unmistakable.

## Where the picker is

**There is no Screen Saver pane on Tahoe.** `com.apple.ScreenSaver-Settings.extension` does not
exist and neither does anything like it in `/System/Library/ExtensionKit/Extensions`; opening
that URL silently lands on General, which reads like a broken command. The picker is a **sheet**
behind **Wallpaper → "Screen Saver…"**, and third-party savers are in a group called **Other**
that is **collapsed to its first four entries** until "Show All" is clicked. A saver installed
after System Settings launched does not appear until the app is restarted.

## What the tile does with the resource

| Question | Answer |
| --- | --- |
| Is `Contents/Resources/thumbnail.png` honoured for a third-party saver? | **Yes.** No `Info.plist` key names it; it is purely a filename convention. |
| Is the tile live or static? | **Static.** No probe ever showed its live drawing. The only live render is the preview at the top of the sheet. |
| What does a saver with no thumbnail get? | A generic blue swirl — not a blank tile. |
| Will it take an image larger than Apple's 90x58? | **Yes,** and it should: 640x412 is visibly crisper in the tile than 90x58. |
| Is `thumbnail@2x.png` alone honoured? | **Yes** — a probe shipping only the `@2x` name displayed. |
| How big is the tile? | **108x71 points**, aspect 1.521. Apple's 90x58 is 1.552, so nothing is lost to letterboxing. |
| Does it stretch? | No. A circle stays a circle. |
| Does it crop? | **Yes — about 5–6% off every edge.** |

The crop was measured with a ruler thumbnail: concentric bands at 0, 2, 4, 6 and 8% inset,
authored at the tile's own aspect so nothing could be blamed on an aspect mismatch. The bands at
0, 2 and 4% are gone on every edge and the 6% band survives top and bottom. **Keep anything that
matters inside the central 88%.**

## The trap that costs the most time

**The picker caches a rendered tile PNG per saver and does not invalidate it when the bundle
changes.** Ship a thumbnail into a saver the machine has already seen and the tile stays exactly
as it was — no error, no stale-looking artifact, just the old picture. Restarting System
Settings does not help, and neither does `killall legacyScreenSaver`.

The cache is two files:

```
$(getconf DARWIN_USER_CACHE_DIR)com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails/<sha256>.png
$(getconf DARWIN_USER_CACHE_DIR)com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.legacy-screenSaver
```

The second is a binary plist mapping each saver's name to its tile's hashed path — `plutil -p`
it and grep for the saver to find which PNG is its own. Delete both and `killall WallpaperAgent`.
`plutil -convert json` fails on this file ("Invalid object in plist for JSON format"), so use
`plutil -p`.

This is a **development-loop trap, not a shipping bug**: a machine seeing the saver for the first
time has no cache entry and renders the tile from the bundle correctly. It only bites where the
saver was installed before it had a thumbnail — which is every machine a developer works on.

## Driving the picker at all

`settings-ui.swift` exists because **System Settings has no accessibility tree**. Each pane is an
out-of-process ExtensionKit view, so `entire contents of window 1` returns *zero* elements and
there is no button for System Events to press — the failure looks like the script searching the
wrong window. Synthetic `CGEvent`s are the way in, and they need Accessibility permission for
whatever runs them.

Two further quirks, both of which read as "the click did not work":

- **A click on a background window is consumed activating it.** Activate the app first, or click
  twice.
- `screencapture -l <sheet-window-id>` returns an image the size of the *parent* window, with the
  sheet composited into it — so coordinates read off that capture are in the parent's space.

## Running it

```bash
.venv/bin/python spikes/007-picker-thumbnail/make-probes.py --install
.venv/bin/python spikes/007-picker-thumbnail/make-probes.py --uninstall
swiftc -O spikes/007-picker-thumbnail/settings-ui.swift -o /tmp/settings-ui
```

**`--uninstall` deletes its whole scratch directory, `/tmp/thumbprobe`.** Put screenshots and
renders somewhere else or they go with it.

## What shipped

`tools/build-thumbnail.sh` renders the Aquarium's tile and `tools/build-saver.sh` copies
`Savers/<Name>/Thumbnail/thumbnail*.png` into the bundle's `Contents/Resources`. The files are
kept out of `Assets/` because that directory is generated build output. The copy happens before
signing, so the signature seals them.
