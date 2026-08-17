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
tools/run-saver.swift Example --configure --seconds 3 --screenshot /tmp/sheet.png
```

Use `run-saver` for iteration. Driving development through System Settings is miserable,
and because a loaded `.saver` is `mmap`ed you can never quite trust that what you are
looking at is what you just built. A short-lived process per run sidesteps both.

### Measuring frames

```bash
SAVERKIT_STATS=5 tools/run-saver.swift Aquarium --size 2056x1329 --seconds 30 \
    --screenshot /tmp/shot.png       # reports every 5 seconds, on stderr
```

**Read the GPU milliseconds, not the frame rate.** The interval between display-link
callbacks depends on whether the window is visible, and a capture run deliberately parks its
window behind everything — so a low rate there proves nothing. GPU time per frame does not
care who is in front: under 8.3 ms holds 120 Hz, under 16.7 ms holds 60. Give the run a few
seconds before believing the first window; the opening frame carries shader compilation and
asset upload and lands around 60 ms.

### Settings

A saver that has settings overrides `hasConfigureSheet` and `configureSheet`, and persists to
`saverDefaults` — a `ScreenSaverDefaults` domain named after *this bundle's* identifier.
`ScreenSaverDefaults(forModuleWithName: Bundle.main.bundleIdentifier)` is the trap: inside a
screensaver that names the host appex, so the setting appears to save, is shared with every
other saver on the machine, and is read back by none of them.

Two things a settings sheet has to get right, both of which cost a debugging session in the
aquarium's:

- **The sheet must outlive its presentation.** The host asks for `configureSheet` on every
  press of Options and presents whatever it is handed, so the window has to be retained by the
  view and must have `isReleasedWhenClosed = false`. It must also re-read the stored settings
  each time it is presented — a second visit that shows what the first one left behind after a
  Cancel is showing a lie.
- **Settings are read when the host is built**, so a running view keeps the settings it
  launched with. `SaverView.reloadHost()` throws the host away and builds a fresh one, which is
  what makes OK visibly take effect in the System Settings thumbnail the sheet was opened from.
- **Nothing in a sheet may start rendering before the sheet is on screen.** `configureSheet` is
  a property, and a host is free to read it and then not present what it got — the window it
  returns has `isVisible == false`. Anything started in the getter therefore has no reliable
  stop: tie it to the window's visibility instead. KVO on `isVisible` is the hook that works;
  an ended sheet sends its delegate neither `windowWillClose` nor `windowDidEndSheet`.

`tools/run-saver.swift --configure` opens the sheet on the harness window, so a sheet can be
built and looked at without driving System Settings.

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
| The framework timer must still exist, but should not drive frames | `animationTimeInterval = 1.0`, `animateOneFrame` a no-op. (`SSENeedsAnimationTimer` in a *saver's* Info.plist is what `ScreenSaverView` reads to decide whether to schedule it at all — leave it unset.) |
| A display link in `.default` mode stops during event tracking — i.e. while the preview is being used | added in `.common` |
| `Bundle.main` is `legacyScreenSaver.appex`, not the saver | `HostContext.bundle`, `SaverView.saverBundle` |
| A settings domain named from `Bundle.main` belongs to the host, not to this saver | `SaverView.saverDefaults` |
| A post-process radius is in target *pixels*, so a look tuned at 1x arrives at half its apparent size on Retina | `RenderTargets.backingScale`, which the host multiplies in |
| A host is created on the first layout, which routinely happens *before* the view is in a window — so the layer's scale is still 1 then, whatever display it is about to land on | scale is delivered with `RenderTargets`, never in `HostContext` |
| A crash is an unrecoverable black screen | every failure path degrades instead of trapping |
| An animating view is retained by the main run loop and cannot be freed, so a host that discards one without `stopAnimation()` leaks the whole render graph and keeps drawing | `SaverView.suspendFrames()` — see below |
| The real host keeps its first view *forever* — its own container view and window retain it — and orders its window out without a callback, so the view above still holds its scene, ~600 MB at 4K, doing nothing | `SaverView.releaseHostIfIdle()`: no committed frame for `idleReleaseDelay` releases the host; the next frame rebuilds it. Override `didReleaseHost(_:)` to drop what you kept beside the host — see below |

### An animating saver view is immortal

Both things that can drive frames — the `CADisplayLink` and `ScreenSaverView`'s own animation
timer — retain their target, and both are themselves retained by the main run loop. Once a view
is animating, the run loop therefore holds a strong reference to it that nothing else can
release: `deinit` cannot run, because the only code that would invalidate the link is in
`deinit`. A host that throws a saver view away without calling `stopAnimation()` does not free
it. The view, its scene, its renderer, its MSAA and depth attachments and its layer's drawables
all survive, and it goes on rendering an invisible frame sixty times a second for the life of
the process.

This is not hypothetical: it is what made System Settings' `legacyScreenSaver` reach a 5.6 GB
footprint — 1.7 GB of it live `IOSurface` drawables — after a dozen previews, at which point the
settings sheet could no longer allocate its own live preview and the Settings button silently
did nothing. Measured at 2056x1329, a host that discards a view without stopping it: **161 MB
retained per cycle and zero views deallocated, against 3 MB per cycle and every view
deallocated** once leaving a window suspends the frames.

So `SaverView` ties frames to *being in a window* rather than to `startAnimation()` alone:
`viewDidMoveToWindow` suspends and resumes them, and the display-link callback checks too,
because a host that tears its window down around the view need not send the notification.
`SAVERKIT_LIFECYCLE=1` logs every view created and destroyed, which is the only way to see any
of this — count the two lines, and they must match.

### And the real host never frees its first view at all

That fix covers a view that *leaves* its window. The real host does something else with the
view it built for a session: it orders the window out and keeps everything — measured with
`leaks --traceTree` on a live `legacyScreenSaver`, the view is retained by the host's own
container `ScreenSaverView` (a responder-chain back-reference), by the ViewBridge window's
`initialFirstResponder`, and by `ScreenSaverView`'s animation timer, which was never stopped
because `stopAnimation()` was never called. `spikes/008-view-lifecycle/README.md` has the tree.
Two of those four references are the host's, so **deallocation is not available**; the view
was found idle at 0% CPU holding a 612 MB footprint with nothing on screen.

What *is* available is letting the render graph go. `orderOut` stops the display link dead
with no callback, but a plain 1 Hz timer keeps ticking through it, so `SaverView` runs one of
its own between `startAnimation()` and `stopAnimation()` — weak, so it retains nothing — and
when a view that still wants frames has *committed* none for `idleReleaseDelay` (4 s), it calls
`releaseHost(.idle)`: host torn down, attachments dropped, the layer's drawable pool shrunk to
a pixel, `didReleaseHost(.idle)` sent to the subclass. One test covers a window ordered out, a
view that left its window, and `startAnimation()` before there was a window. The next frame the
link delivers rebuilds everything through `makeHost(_:)`, exactly like `reloadHost()`, so
nothing has to be told the view is wanted again — the frame *is* the signal, in both
directions. `SAVERKIT_LIFECYCLE=1` logs `hibernated` and `woke` beside `created` and
`destroyed`.

Measured on the Aquarium in the harness (`spikes/008-view-lifecycle`): 495 → 287 MB four
seconds after `orderOut` at 1200x700, 886 → 387 MB at 3840x2160. A wake rebuilds the scene —
about 0.6 s on the main thread at 1200x700 — and comes back *higher* than the first look
because process-wide caches from the first scene remain (awake 436 → ~805 MB across five
cycles, hibernated 276 → 382 MB, both plateauing). The Aquarium carries its seed across an idle
release, so the tank that comes back is the one that was being watched; a `.reload` draws anew.

**Override `didReleaseHost(_:)` if you keep anything beside the host.** The Aquarium keeps its
`AquariumScene` on the view; without dropping it there the release frees the renderer and
nothing else. A view the host has *properly* stopped is not released — it keeps its scene and
resumes where it left off, as System Settings previews expect. Also measured to release, and
correctly: `view.isHidden = true`, and a window moved fully off-screen. Not: a window at alpha 0
or one fully covered — both keep a 60 fps link.

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
- **Retina 2x**, on a 2056x1329-point built-in display. The drawable is sized in pixels
  (4112x2658), the capture comes back at pixel size, the composition is identical to 1x, a
  live reshape follows, and the aquarium holds a locked 120 fps at 5.4 ms of GPU time per
  frame. Preview-ness is decided in points, so a 300-point thumbnail is still a thumbnail at
  either scale.
- **A backing-scale change under a live view.** Mirroring a 1x display onto a 2x one mid-run
  moved a running saver from 4112x2658 to 2056x1329 without a stumble: one 1.3-second stall
  for the display reconfiguration itself, then a locked rate again. `RenderTargets` carries
  the new scale, so a pixel-space radius follows it.
- **Ten minutes of continuous rendering**, 62,254 frames across that reconfiguration, with
  GPU time flat at 4.0-5.5 ms throughout and no drift.
- **A settings sheet**, driven by real clicks rather than by calling its own methods: each
  radio rebuilds the live preview, OK persists and reloads the running view's host, Cancel
  leaves the stored value untouched, and a reopened sheet shows what is stored.
- **That sheet under real System Settings**, opened from its Options button in the sandboxed
  host: every option applied, the picker's live thumbnail adopted each choice, and full-screen
  Preview ran. A second `ScreenSaverView` rendering inside the sheet, alongside the thumbnail
  already running in the same process, is therefore fine.

Not verified, and worth knowing before trusting:

- **Multi-display.** This machine presents one logical display at a time — it mirrors rather
  than extends. macOS instantiates a saver per screen, so what is untested is two live views
  at once and the memory that costs: one full set of MSAA attachments per screen, about
  350 MB at 4112x2658.
- The `default.metallib` path in `ShaderLibrary` and `build-saver.sh`, which cannot run
  here at all — no Metal toolchain.
- Long-run behaviour. Nothing has yet run for hours.
