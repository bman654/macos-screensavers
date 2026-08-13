# Where to pick up

Written 2026-08-13, at the end of the session that built the `.saver` shell.

## State

The shell track is **done and verified in the real screensaver engine**. Both savers were
installed to `~/Library/Screen Savers` and rendered correctly in the System Settings
preview, so `legacyScreenSaver` genuinely loads and runs this code. They are still
installed; rebuild and reinstall to refresh them.

The asset pipeline was already validated in `spikes/001-fish-pipeline`. What is new is
everything between a `.usdz` on disk and pixels on a screen.

```
Shared/SaverKit/              SaverView, RenderHost, SceneKitHost, MetalHost, ShaderLibrary
tools/build-saver.sh          compile → bundle → sign → install
tools/run-saver.swift         windowed dev harness (screenshot, preview, live reshape)
Savers/Aquarium/              SceneKit saver: 14 fish, depth fog, marine snow
spikes/002-saver-shell/       raw Metal saver proving the other host
```

Read `Shared/SaverKit/README.md` first. It is the orientation doc: how to write a saver,
the macOS 26 hazard table, and which of them SaverKit already handles for you.

## The one result that changes what is possible

**Command Line Tools ship no offline Metal compiler**, so shaders cannot be precompiled on
this machine — they ship as `.metal` source and are compiled at runtime. That turns out to
be **permitted inside the screensaver sandbox**, which is what makes the shader-based half
of `saver-backlog.md` buildable without installing Xcode. If it had been blocked, every
field-simulation and space saver would have needed a toolchain first.

## Next: texture baking

This is now the only thing between the aquarium and looking right. The fish have correct
shape and correct motion and are flat white, because nothing procedural survives USD
export. `docs/aquarium-plan.md` §1 has the full plan for `saverlib/bake.py`; it was written
before any of this session's work and is still accurate.

After that, in `aquarium-plan.md` §2 order: tank environment, water look, depth lanes and
fish AI, camera.

## Loop

```bash
tools/build-saver.sh Aquarium
tools/run-saver.swift build/Aquarium.saver --seconds 3 --screenshot /tmp/aq.png
```

Then **look at the PNG**. The repo rule that you render and inspect before declaring
something done applies to savers exactly as it does to models — several bugs this session
compiled cleanly, ran without error, and drew nothing.

`--size WxH`, `--preview`, and `--resize WxH` (reshapes halfway through, to exercise
aspect-ratio handling) are the other flags worth knowing. Use `--screenshot`: the
interactive path deliberately takes keyboard focus and is disruptive in a loop.

`tools/build-saver.sh <saver> --install` also runs `killall legacyScreenSaver`, without
which macOS keeps serving the previous binary from its `mmap`ed copy.

## Unverified — do not assume these work

- **Retina 2x and multi-display.** The development display is a single 1x ultrawide, so
  that code path has never actually executed. The scale arithmetic was exercised by forcing
  `contentsScale`, which is not the same thing. Brandon has a Retina laptop display
  available — **opening the laptop and previewing both savers is a five-minute test and
  should be done early**, because a scale bug would affect every saver.
- **Long-run stability.** Timing precision is proven numerically out to a week, but nothing
  has run for more than seconds.
- **The `default.metallib` path** in `ShaderLibrary` and `build-saver.sh` cannot execute
  here at all, for lack of a Metal toolchain.

## Traps that cost real time, so they do not cost it twice

All of these are commented at the code that handles them; this is the index.

- A wrong `NSPrincipalClass` fails **silently**. CFBundle falls back to the first class in
  the bundle regardless of type, with `bundleLoaded: true` and empty stderr. A saver class
  must be declared `@objc(<Name>View)`. Guarded by `build-saver.sh` and `run-saver.swift`.
- `RenderHost`'s protocol-extension defaults are **statically dispatched**. A conforming
  class that does not redeclare a member freezes its witness, and a subclass's override is
  silently ignored. Already caused one bug. See `MetalHost`.
- `camera.wantsHDR = true` discards your `MTLClearColor` and returns **alpha 0**. Set
  `scene.background.contents` instead.
- SceneKit wraps any node mutation outside its render loop in an implicit animation stamped
  with `CACurrentMediaTime()`, while our clock starts at zero — so the scene renders as if
  nothing moved. Handled in `SceneKitHost` with a zero-duration `SCNTransaction`.
- `.bgra8Unorm` displays SceneKit's linear output as if already sRGB-encoded, crushing the
  image to near-black. `SceneKitHost` uses `.bgra8Unorm_srgb`.
- AppKit's `cacheDisplay` cannot capture a `CAMetalLayer` — it silently yields a black PNG.
  The harness uses ScreenCaptureKit current-process capture.
- The runtime shader path concatenates every `.metal` file into one translation unit and
  cannot `#include` project headers. Neither fails on a machine with the Metal toolchain,
  which is the worst direction for a trap.

## Loose ends

- `SceneKitHost` has no resize hook, so `AquariumScene` reads `drawableSize` from
  `FrameContext` every frame and learns about a reshape one frame late. Correct and cheap;
  add an `onResize` hook if a second SceneKit saver wants it, not before.
- `Savers/Aquarium/Assets/clownfish.usdz` is the untextured placeholder. Regenerate it once
  baking works.
