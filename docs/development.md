# Development

How the repository is laid out and how to build it. If you only want to *use* a screensaver,
the [root README](../README.md) is the place to start.

## Layout

```
Shared/SaverKit/      Swift code common to every saver (ScreenSaverView base, SceneKit and
                      raw Metal hosts, macOS 26 legacyScreenSaver workarounds)
Savers/<Name>/        One screensaver. Sources/ (Swift), Models/ (Blender build scripts),
                      Sounds/ (synthesis scripts), Assets/ (generated, not committed)
tools/blender/        `saverlib` — reusable parametric modeling, materials, render harness
tools/                Build, bake, package and install scripts
docs/                 Design docs and the running record of what was learned
spikes/               Throwaway experiments that de-risk a pipeline step. Numbered, kept
                      for the record, not part of any build
build/                Scratch output. Not committed
```

## Requirements

- macOS 26+, Apple Silicon
- Swift command-line tools (`xcode-select --install`) — **full Xcode is not required**
- Blender 4.2+ for asset authoring (`brew install --cask blender`)
- `ffmpeg` for contact sheets and preview movies
- `uv` for the image-inspection interpreter:
  `uv venv --python 3.14.3 .venv && uv pip install --python .venv/bin/python numpy scipy pillow`

## Assets are build outputs, not sources

**A fresh clone has an empty `Savers/*/Assets/` and cannot build a working saver until you bake
it.** Models are parametric Blender scripts and sounds are synthesis scripts, so committing the
`.usdz` and `.wav` files would put tens of megabytes into history on every re-bake — and a
re-bake is a normal part of the authoring loop, not an unusual event.

```bash
tools/build-library.py    # ~44 MB of models and texture atlases. Needs Blender.
tools/build-audio.py      # the grain library the tank's audio is assembled from
```

Do both once before your first `build-saver.sh`, and again whenever you change a model script
or a sound script.

## Building a saver

```bash
tools/build-saver.sh Aquarium                    # compile + bundle + ad-hoc sign
tools/build-saver.sh Aquarium -i                 # ...and install to ~/Library/Screen Savers
tools/build-saver.sh Aquarium --version 1.0.1    # set CFBundleShortVersionString
```

Because a loaded `.saver` is held open via `mmap`, the install step runs
`killall legacyScreenSaver` — otherwise macOS keeps serving the previous binary.

For iteration, drive a saver in a window instead of through System Settings:

```bash
tools/run-saver.swift build/Aquarium.saver --seconds 3 --screenshot /tmp/shot.png
tools/run-saver.swift build/Aquarium.saver --configure          # open the settings sheet
```

Shaders ship as `.metal` **source** and are compiled at runtime, because Command Line Tools
include no Metal compiler. Runtime compilation is verified to work inside the screensaver
sandbox; `build-saver.sh` will additionally precompile a `default.metallib` if a Metal
toolchain is present.

## Cutting a release

```bash
tools/package-release.sh Aquarium 1.0.0
```

That builds at the given version, verifies the bundle reports it, zips with `ditto` (a plain
`zip` breaks the code signature), unpacks the archive again and re-verifies the signature, and
writes a `.sha256` beside it. It prints the tag to use — `aquarium-1.0.0`.

Releases are cut by hand. GitHub-hosted runners have neither macOS 26 nor Blender, so there is
nothing useful CI could do here.

**The artifact is ad-hoc signed, not notarized**, because notarization needs a paid Apple
Developer account. Users therefore have to clear the quarantine flag after downloading; that is
documented in each saver's README, and `--sign IDENTITY` is threaded through both scripts for
whenever a real certificate exists.

## Rebuilding one model

```bash
tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- --species clownfish --preview
tools/gallery.py --out build/gallery/fish.png --columns 4 'build/fish/*/studio_00_side.png'
```

Always render and look at the result. The numbers alone do not tell you whether it reads as a
fish.

## Platform notes

Third-party screensavers on macOS 26 must still use the legacy `ScreenSaverView` API — Apple's
replacement engine is private. Known Tahoe-specific hazards are documented in
[`Shared/SaverKit/README.md`](../Shared/SaverKit/README.md) and handled by the base class.

## Where the knowledge lives

- [`docs/next-session.md`](next-session.md) — current state, what is next, and every trap that
  already cost time once
- [`docs/saver-host.md`](saver-host.md) — what the screensaver host actually does. Read first
  when starting a new saver
- [`Shared/SaverKit/README.md`](../Shared/SaverKit/README.md) — the kit's API
- [`docs/aquarium-plan.md`](aquarium-plan.md) — the aquarium's design decisions
- [`docs/water-looks.md`](water-looks.md) — art direction for the three tank styles
- [`docs/tank-sound.md`](tank-sound.md) — how the audio is synthesised
- [`docs/decorations.md`](decorations.md) — the model manifest contract
- [`docs/saver-backlog.md`](saver-backlog.md) — planned savers beyond the aquarium
- `spikes/*/README.md` — what each experiment proved, and what it disproved
