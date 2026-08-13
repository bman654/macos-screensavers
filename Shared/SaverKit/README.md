# SaverKit

The shared shell every saver in this repo is built on. It exists so that the parts which
are identical for all of them — and wrong in non-obvious ways when hand-rolled — are
written once: a `CAMetalLayer` whose drawable actually tracks the view, a display link that
survives event tracking, and the macOS 26 `legacyScreenSaver` hazards listed below.

There is no SwiftPM package. `tools/build-saver.sh` compiles these sources directly into
each saver, because SwiftPM cannot emit a loadable bundle and the indirection buys nothing.
A consequence worth knowing: **SaverKit and the saver's own sources are one module**, so
everything here is `internal` and `public` would be noise.

## Writing a saver

Two files and a build:

```swift
// Savers/<Name>/Sources/<Name>View.swift
@objc(ExampleView)                       // REQUIRED — see the NSPrincipalClass hazard
final class ExampleView: SaverView {
    override func makeHost(_ context: HostContext) -> RenderHost? {
        try? ExampleHost(context: context)
    }
}
```

```bash
tools/build-saver.sh Example        # build to build/Example.saver
tools/build-saver.sh Example -i     # ...and install, killing legacyScreenSaver
tools/run-saver.swift build/Example.saver --seconds 3 --screenshot /tmp/shot.png
```

Use `run-saver` for iteration. Driving development through System Settings is miserable,
and because a loaded `.saver` is `mmap`ed you can never quite trust that what you are
looking at is what you just built. A short-lived process per run sidesteps both.

### Which host

`RenderHost` is the whole interface between `SaverView` and whatever draws. Both hosts
share one `CAMetalLayer`, one display link and one resize path, so a saver can use either —
or composite both into a single drawable, which is verified to work.

- **`SceneKitHost`** — 3D scenes, PBR, particles, depth fog, bloom. The aquarium uses this.
- **`MetalHost`** — a raw render pass. The field-simulation and space savers in
  `docs/saver-backlog.md` need this; it is deliberately minimal and grows when the first
  one is actually written, not before.

`SaverView` hands a host a configured `MTLRenderPassDescriptor` and a command buffer. A
host encodes; it never touches the layer, the drawable, or presentation.

**Build pipeline state in `hostDidResize`, not in `init`.** A host declares the sample count
and pixel formats it *wants*; `SaverView` clamps the sample count to what the device actually
supports and may drop it further if a large attachment fails to allocate. `hostDidResize`
receives a `RenderTargets` with the values that were really used, and is always called before
any frame is encoded. A pipeline built in `init` from the host's own request will disagree
with the attachments whenever the clamp changes anything — which is a Metal validation
failure precisely on the devices the clamp exists to accommodate.

## macOS 26 hazards, and where each is handled

These are the things that cost real time. Each is handled in SaverKit so that a saver does
not have to know about it.

| Hazard | Handled in |
|---|---|
| `isPreview` is unreliable — derive preview-ness from view size | `SaverView.isPreviewSized` |
| Bounds are routinely zero at `init`; GPU resources sized from them are built wrong | host creation deferred to first real layout |
| `CAMetalLayer` does not track its own bounds, and does not inherit the window's scale | `updateDrawableSize()`, called synchronously from the resize callbacks |
| `makeBackingLayer()` runs synchronously inside `wantsLayer = true`, so later layer config is silently ignored | all layer setup is in `makeBackingLayer()` |
| `startAnimation`/`stopAnimation` must call `super` | `SaverView` |
| The framework timer must still exist (`SSENeedsAnimationTimer`), but should not drive frames | `animationTimeInterval = 1.0`, `animateOneFrame` a no-op |
| A display link in `.default` mode stops during event tracking — i.e. while the preview is being used | added in `.common` |
| `Bundle.main` is `legacyScreenSaver.appex`, not the saver | `HostContext.bundle` |
| A crash is an unrecoverable black screen | every failure path degrades instead of trapping |

Two more that are not SaverKit's to fix, but will bite:

- **`NSPrincipalClass` must be the bare `@objc(Name)` name.** Without the `@objc` rename
  Swift registers a mangled name, the bare value fails to resolve, and CFBundle silently
  falls back to *the first class in the bundle's Obj-C class list regardless of type* — so
  you get either the wrong view or, given our source ordering, nothing at all. It is silent
  in both directions: `bundleLoaded: true`, no error, empty stderr. `build-saver.sh` fails
  the build if the class is missing from the binary, and `run-saver` fails loudly if the
  resolved class is not a `ScreenSaverView`.
- **A loaded bundle is `mmap`ed.** Installing without `killall legacyScreenSaver` means
  macOS keeps serving the previous binary. `--install` does this for you.

## Protocol-extension defaults do not dispatch dynamically

`RenderHost` supplies defaults via a protocol extension. Those are **statically** dispatched:
if a conforming class does not declare a member itself, the witness is frozen to the
extension's value and a subclass's override is silently ignored when `SaverView` reads it
through the protocol — compiling cleanly and rendering with the wrong settings.

So any `RenderHost` class meant to be subclassed must redeclare the members it wants
subclasses to customise. `MetalHost` does this for `sampleCount` and `clearColor`. This has
already caused one bug; check it before adding a customisation point.

## Verified, and not

Verified on macOS 26.5.1 / Apple Silicon / Swift 6.3.2, Command Line Tools only:

- The full chain — build, ad-hoc sign, install, load, render — under real
  `legacyScreenSaver`, for both a SceneKit saver and a raw Metal saver.
- **Runtime Metal shader compilation works inside the sandbox**, which is what makes the
  shader-based savers buildable without Xcode. See `spikes/002-saver-shell/README.md`.
- SceneKit into the drawable keeps depth, fog, particles, actions, bloom and 4x MSAA.

Not verified, and worth knowing before trusting:

- **Multi-display**, and a Retina 2x display. This machine has one 1x display. The scale
  arithmetic was exercised by forcing `contentsScale`, but real backing-property changes
  across displays are untested.
- The `default.metallib` path in `ShaderLibrary` and `build-saver.sh`, which cannot run
  here at all — no Metal toolchain.
- Long-run behaviour. Nothing has yet run for hours.
