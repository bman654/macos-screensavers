# macOS Screensavers

A multi-screensaver monorepo for macOS 26 (Tahoe), plus the asset pipeline that feeds it.

Each screensaver ships as a `.saver` bundle built from shared Swift code in `Shared/SaverKit`.
3D assets are authored **as code** — parametric Blender Python scripts under each saver's
`Models/` directory, using the shared `saverlib` helpers — so a model is reviewable,
diff-able, and re-derivable rather than a binary blob.

## Layout

```
Shared/SaverKit/      Swift code common to every saver (ScreenSaverView base, SceneKit host,
                      macOS 26 legacyScreenSaver workarounds)
Savers/<Name>/        One screensaver. Sources/ (Swift), Models/ (Blender build scripts),
                      Assets/ (generated USDZ/textures, committed)
tools/blender/        `saverlib` — reusable parametric modeling, materials, render harness
tools/                Build + install scripts
spikes/               Throwaway experiments that de-risk a pipeline step. Numbered, kept
                      for the record, not part of any build
build/                Scratch output. Not committed
```

## Requirements

- macOS 26+, Apple Silicon
- Swift command-line tools (`xcode-select --install`) — **full Xcode is not required**
- Blender 4.2+ for asset authoring (`brew install --cask blender`)
- `ffmpeg` for contact sheets and preview movies

## Building a saver

```bash
tools/build-saver.sh Aquarium      # compile + bundle + ad-hoc sign
tools/build-saver.sh Aquarium -i   # ...and install to ~/Library/Screen Savers
```

Because a loaded `.saver` is held open via `mmap`, the install step runs
`killall legacyScreenSaver` — otherwise macOS keeps serving the previous binary.

## Rebuilding assets

```bash
tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- --species clownfish --preview
```

Assets are committed so that building a saver never requires Blender.

## Platform notes

Third-party screensavers on macOS 26 must still use the legacy `ScreenSaverView` API —
Apple's replacement engine is private. Known Tahoe-specific hazards are documented in
`Shared/SaverKit/README.md` and handled by the base class.
