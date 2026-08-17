# The host, and the rules a new saver must follow

What the macOS 26 (Tahoe) screensaver host actually does, and what a saver has to do about it.
Everything here was established by measurement on this machine rather than from documentation,
because almost none of it is documented and several of the plausible answers are wrong.

**Read this before building the second saver.** `Shared/SaverKit/README.md` is the kit's API;
this is the platform underneath it. Each section names the spike that holds the measurements, so
that a claim can be checked rather than trusted.

## The short version

If you read nothing else:

1. **The host is not what you think.** It outlives its session, keeps views for the life of the
   process, holds several saver bundles at once, and hands a real session the *same view* the
   picker was already using. Design for that, not for create-show-destroy. **Its first view is
   never freed** — the host itself retains it — so a view must be able to give back everything
   expensive it owns while staying alive, and SaverKit's does.
2. **Never ask the view whether it is real.** Size, `isPreview`, occlusion and screen fraction all
   give the same answer for a picker tile as for a full-screen session. They have all been
   measured. §3 has the table.
3. **Tie every side effect to frames actually being produced**, not to a callback. The failing
   case is a view nobody can reach, so a fix that needs someone to call you will not run.
4. **A screensaver may be heard only when the system says a session is running *and* its own
   window is still at a presenting level.** One half is not enough; shipping only the first put
   sound on the user's desktop while they were working.
5. **Ship a `thumbnail.png`,** or the tile is a generic swirl — and clear the tile cache, or your
   correct change will look like no change at all.
6. **Err toward silence and toward doing nothing.** Every ambiguous state in this codebase
   resolves to "stay quiet", because the failure the user notices is the false positive.

---

## 1. The picker, and getting a picture into it

Source: `spikes/007-picker-thumbnail/README.md`.

### Where the picker is

**There is no Screen Saver pane on Tahoe.** `com.apple.ScreenSaver-Settings.extension` does not
exist, and neither does anything like it in `/System/Library/ExtensionKit/Extensions`; opening
that URL lands silently on General, which reads like a broken command rather than a missing pane.

The picker is a **sheet** behind **System Settings → Wallpaper → "Screen Saver…"**. Third-party
savers are grouped under **Other**, which is **collapsed to its first four entries** until
"Show All" is clicked. A saver installed while System Settings is running does not appear until
the app is restarted.

### What the tile is

The tile is a **static image read out of the bundle** — not a render of the saver. The only live
render in the picker is the large preview at the top of the sheet. A saver with no thumbnail gets
a generic blue swirl; there is no such thing as a blank tile, so "blank" in an older note means
"the swirl".

| | |
| --- | --- |
| Where it is read from | `Contents/Resources/thumbnail.png` |
| How it is found | **Filename convention.** No `Info.plist` key names it. |
| `thumbnail@2x.png` | Honoured, and honoured *alone* — a bundle shipping only the `@2x` name displays. |
| Tile size | **108x71 points**, aspect 1.521 (Apple's own 90x58 is 1.552, so nothing is lost to letterboxing) |
| Larger images | **Accepted, and better.** 640x412 is visibly crisper in the tile than 90x58. |
| Stretching | None. A circle stays a circle. |
| Cropping | **About 5–6% off every edge.** |

The crop was measured with a ruler thumbnail carrying concentric bands at 0, 2, 4, 6 and 8%
inset, authored at the tile's own aspect so nothing could be blamed on an aspect mismatch: the 0,
2 and 4% bands are gone on every edge and the 6% band survives top and bottom.

### The rules

- **Keep anything that matters inside the central 88%.**
- **Compose for 108x71.** Judge candidates at that size, not at full size shrunk in your head.
  The aquarium's default reef look was rejected for the tile on exactly this basis — at tile size
  its teal-on-grey reads as a smudge.
- **Ship the picture as a render of the saver**, produced by `run-saver --screenshot` at the
  tile's aspect, so the tile cannot drift from what the saver looks like. `tools/build-thumbnail.sh`
  is the worked example, and the script is where the chosen frame is recorded.
- **Put the files in `Savers/<Name>/Thumbnail/`**, not in `Assets/`. `Assets/` is generated build
  output and is not tracked. `build-saver.sh` copies `Thumbnail/thumbnail*.png` into
  `Contents/Resources` before signing, so the signature seals them.

### The cache — the trap that costs an afternoon

**The picker renders each saver's tile once, caches it as a hashed PNG, and never invalidates it
when the bundle changes.** Ship a correct thumbnail into a saver the machine has already seen and
the tile stays exactly as it was: no error, nothing stale-looking, just the old picture.
Restarting System Settings does not help. Neither does `killall legacyScreenSaver`.

```bash
tools/refresh-picker-tile.sh
```

That clears both halves of the cache and restarts the agent. The two locations, under
`$(getconf DARWIN_USER_CACHE_DIR)`:

```
com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails/<sha256>.png
com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.legacy-screenSaver
```

The second is a binary plist mapping each saver's name to its tile's hashed path. To find one
saver's PNG rather than clearing all of them, `plutil -p` it and grep for the saver's name —
`plutil -convert json` **fails** on this file with "Invalid object in plist for JSON format".

This is a **development trap, not a shipping bug**: a machine seeing the saver for the first time
has no cache entry and renders the tile from the bundle correctly. It only bites where the saver
was installed before it had a thumbnail, which is every machine anyone develops on.

### Driving System Settings from a script

**System Settings has no accessibility tree.** Each pane is an out-of-process ExtensionKit view,
so `entire contents of window 1` returns *zero* elements and there is no button for System Events
to press. The failure looks like the script searching the wrong window.

`spikes/007-picker-thumbnail/settings-ui.swift` drives it with synthetic `CGEvent`s instead, which
need Accessibility permission for whatever runs them. Two further quirks, both of which read as
"the click did not work":

- **A click on a background window is consumed activating it.** Activate the app first, or click
  twice.
- `screencapture -l <sheet-window-id>` returns an image the size of the **parent** window with the
  sheet composited into it, so coordinates read off that capture are in the parent's space.

---

## 2. Views, and how one leaks

Sources: `Shared/SaverKit/README.md` §"An animating saver view is immortal",
`spikes/006-saver-audio/README.md`, `spikes/008-view-lifecycle/README.md`,
`Shared/SaverKit/SaverView.swift`.

### What the host actually does, measured

Almost every wrong assumption in this repo has come from imagining a host that creates one view,
shows it, and destroys it. It does none of those reliably.

- **The host outlives its session and keeps its views.** A view from a previous activation was
  found still animating at 60 fps ten minutes and a whole session later.
- **One host holds several saver *bundles* at once** — an `lsof` sweep caught a single
  `legacyScreenSaver` pid with both `Aquarium.saver` and `AudioProbe.saver` open. A `static` in
  your bundle therefore cannot see the view competing with yours, because it may not be your saver.
- **A pass through the picker leaves two hosts alive**, one holding 0x0 views and one holding
  full-screen ones.
- **A real session reuses the picker's existing host and its existing full-screen view** rather
  than spawning one. "Was this view born into the session" is not a question with an answer.
- The host builds the session's real view about **0.56 s after `didstart`**.
- **An abandoned view is never told it stopped being seen.** One was measured still rendering at
  60 fps with `window=shown` and `animating=true`, long after System Settings had been closed.

### An animating view is immortal, and that was a 5.7 GB bug

`CADisplayLink` retains its target, the run loop retains the link, and `ScreenSaverView`'s own
inherited animation timer does the same. So once a view has started animating, **the main run
loop holds a strong reference to it that nothing else can release.** If the only code that
invalidates the link lives in `deinit`, `deinit` can never run — the cycle sustains itself.

A host that discards a saver view without calling `stopAnimation()` therefore does not free it.
The view, its scene, its renderer, its render attachments and its layer's drawables all survive,
and it goes on rendering an invisible frame sixty times a second for the life of the process,
allocating a fresh IOSurface every one of them.

```
                        before the fix        after
per discarded view      161 MB retained       3 MB per cycle
views deallocated       0 of 6                6 of 6
host after a dozen      5.6–5.7 GB (the two records differ slightly),
  Previews              1.7 GB of it live IOSurface drawables
```

161 MB is at 2056x1329; the same view is about 570 MB at 4112x2658.

**The symptom was not a memory warning.** It was the Settings button silently doing nothing — the
sheet could no longer allocate its own live preview. No crash, nothing in the unified log. Any
"this worked earlier and now does nothing" in a saver host should send you here first.

### The fix, and the rule it encodes

Frames are tied to **being in a window**, not to `startAnimation()` having been called. A view
with no window has nothing to composite into, so there is no frame worth producing.

```swift
private func suspendFrames() {
    guard wantsFrames, !isSuspended else { return }
    isSuspended = true
    stopFrameLink()
    super.stopAnimation()      // also stops the inherited ScreenSaverView timer
}
```

Three places enforce it, all in `SaverView.swift`: `viewDidMoveToWindow()` suspends on
`window == nil` and resumes otherwise; `startFrameLink()` refuses to create a link without a
window; and the display-link callback itself carries the safety net —

```swift
guard window != nil else { suspendFrames(); return }
```

That last one is not belt-and-braces. `viewDidMoveToWindow` is AppKit's to send, and **a host
that tears its window down around the view need not send one.** The link always fires, so
checking there is the only guarantee.

`isSuspended` is kept distinct from `wantsFrames` so that a view which merely left its window
resumes when reparented, rather than being confused with one that was genuinely stopped.

### What actually keeps a leftover alive — measured on the real host

`spikes/008-view-lifecycle/README.md` §1 has the full `leaks --traceTree` of an `AquariumView`
in an idle `legacyScreenSaver` twenty minutes after its session ended: 0% CPU, **612 MB
footprint, nothing on screen**. Four strong references:

| Who | What | Ours to break? |
| --- | --- | --- |
| The host's container `ScreenSaverView` (`LegacyViewController.view`) | responder-chain back-reference to our view | no |
| The ViewBridge window, still in `NSApp.windows` | `initialFirstResponder` | no |
| `ScreenSaverView`'s own animation timer | target — never invalidated, because `stopAnimation()` was never called | yes |
| Our `CADisplayLink` | target — same reason | yes |

Breaking the two that are ours frees the view's own 768 bytes. **Deallocation is off the
table; releasing the render graph is not**, and that is what SaverKit now does — see below.

### Three ways a host stops showing a view, and they behave differently

Isolated by `spikes/006-saver-audio/lifecycle-driver.swift` and, with more instruments,
`spikes/008-view-lifecycle/driver.swift`:

| What the host does | What your view is told |
| --- | --- |
| `window.orderOut()` | Nothing on the *view*. KVO on `window.isVisible` and the occlusion notification do fire; the display link stops dead; **the inherited 1 Hz timer keeps ticking**. |
| `contentView = nil` | `viewDidMoveToWindow` fires with `window == nil`; the timer stops too (`_oneStep:` is gated on `window != nil`) |
| `window.orderFront()` again | Nothing. The link simply resumes. |
| drops all references | `deinit` — the "no `deinit`" of spike 006 was the driver's own autorelease pool and its never-closed window (spike 008 §4) |

The general rule the spike produced, and the one to design against:

> **Tie every external side effect to frames actually being produced, not to a callback.** The
> failing case is a view nobody can reach, so any fix that requires someone to call you is a fix
> that will not run.

### The idle release, which is that rule applied to memory

Sound already fades when frames stop (§3, the 0.25 s stall guard). The render graph now goes
the same way, on a longer clock: a view that still wants frames and has *committed* none for
`SaverView.idleReleaseDelay` (4 s) tears down its host, attachments and drawable pool and calls
`didReleaseHost(.idle)`; the next frame the link delivers rebuilds them through `makeHost(_:)`.
The watchdog is a weak 1 Hz timer of SaverView's own, alive between `startAnimation()` and
`stopAnimation()` — a plain timer keeps ticking through `orderOut`, which is the whole trick. A
view the host has properly stopped is left alone.

Measured on the Aquarium in the harness: 495 → 287 MB four seconds after `orderOut` at
1200x700, 886 → 387 MB at 4K; the wake rebuilds the scene (~0.6 s of main thread at 1200x700,
same seed) and comes back higher than the first look because of process-wide caches, then
plateaus. `SAVERKIT_LIFECYCLE=1` logs `hibernated` and `woke`. Also releases, correctly: a
hidden view, a window moved off-screen. Does not: alpha 0, a covered window. What it does *not*
know is whether anyone is looking — a display asleep past four seconds, or a main thread frozen
that long, gets a rebuild on the next frame rather than a resume.

Two consequences for a saver:

- **Override `didReleaseHost(_:)`** if you keep anything beside the host. The Aquarium keeps its
  scene on the view, and without dropping it there the release would free the renderer only.
  `.idle` is a pause worth resuming from (the Aquarium keeps its seed); `.reload` is not.
- **Never rely on `animateOneFrame` for a heartbeat.** It is gated on `window != nil`, and
  `SSENeedsAnimationTimer` in a saver's Info.plist can switch it off entirely. SaverView's
  watchdog is its own timer for exactly that reason.

**What this does not cover:** a picker-spawned host whose view goes on rendering after System
Settings quits (spike 006 measured one at 60 fps, `window=shown`, level 0). Its link never goes
silent. Spike 008 §6 has the measurement to take before touching it.

**The road not taken:** every open-source saver that has met this bug — XScreenSaver, Aerial,
ScreenSaverMinimal and others — observes `com.apple.screensaver.willstop` and *exits the host*
(Aerial after a 2 s delay, because Tahoe relaunched it on an immediate exit). It works, and it
is a mitigation with three costs this repo would pay: `willstop` was measured missing under
rapid start/stop, it never reaches a picker preview, and one host carries several savers'
views. The idle release frees what matters without any of that; if it ever proves
insufficient, that is the fallback, and it belongs behind a session-only, non-preview check.

### What SaverKit does for you, and what your saver must still do

Automatic — do not re-implement:

- Suspending and resuming frames on window changes, plus the display-link safety net.
- Releasing the render graph after 4 s without a frame, and rebuilding it on the next one.
- `deinit` invalidates the frame link and calls `host?.teardown()`.
- Owning the `CAMetalLayer`, drawable sizing, MSAA and depth attachments, presentation and
  command-buffer commit. **A host encodes; it never touches the layer, the drawable, or
  presentation.**
- Freeing attachments on `reloadHost()` — hundreds of megabytes at 5K.
- A monotonic clock across stop/start, with the frame delta clamped to 0.1 s.
- Failing soft: a nil host or nil device draws black rather than trapping.

Yours to get right:

- **Build GPU resources in `makeHost(_:)`, never in `init`.** Bounds are routinely zero at `init`
  on Tahoe.
- **Release everything in `RenderHost.teardown()`** — it is the only teardown hook `SaverView`
  calls on the host. `SceneKitHost.teardown()` is the model, and note that it explicitly nils
  `overlaySKScene`, which is "exactly the kind of thing the leaked-view bug dragged along".
- **Override `didReleaseHost(_:)`** to drop whatever the view itself kept beside the host; it is
  called on `reloadHost()` and on the idle release, before `makeHost(_:)` can be asked again.
- **Never let a host closure strongly capture the view or the scene.** The Aquarium uses
  `[weak self, weak scene]` on `onUpdate` and `[weak scene]` on `onResize`.
- **Override `stopAnimation()` to stop anything external, and call `super`.** When a host says
  stop, an audio engine should actually go away rather than be held at zero gain.
- **Never cache anything the host mutates behind your back.** The window level is the specific
  offender — see §3.
- `@objc(Name)` on the view class, or the bundle will not load. Resolve assets through
  `HostContext.bundle`, never `Bundle.main`. A `RenderHost` subclass must redeclare every
  protocol member, because protocol-extension defaults are statically dispatched.

### Proving you have not regressed it

```bash
SAVERKIT_LIFECYCLE=1 …          # logs "created"/"destroyed <Type> <address>"
```

Counting the two lines is the whole regression test. Two traps around measuring it:

- **A harness that pumps the run loop by hand measures its own autorelease pool.** A first probe
  reported a steady 445 MB per cycle "leaking from the settings sheet", which does not leak at
  all. Use `app.run()`, and `leaks <pid> --traceTree=<addr>`.
- **`run-saver` proves nothing about deallocation**, because process exit does not run `deinit`.

### `isPreview` is wrong in the picker, for every saver — and this is still open

SaverKit never reads `ScreenSaverView.isPreview`; it derives preview-ness from size, via
`previewWidthThreshold` (600 points) and `isPreviewSized`. **Both signals fail in the picker**,
because the tile is a 2056x1329 view on a 2056-point screen — a full-screen-sized view that
something above the saver scales down into a tile.

| Signal | In the picker tile |
| --- | --- |
| `ScreenSaverView.isPreview` | `false` |
| width vs 600 pt | 2056 pt — not a preview |
| width as a fraction of the screen | 1.00 |
| `occlusionState` | `occluded` — and so is the real full-screen preview |
| window level | ordinary, never `CGShieldingWindowLevel()` |

The consequence is live and **unfixed**: the Aquarium renders five lights, caustics, god rays,
bloom and MSAA into a tile a couple of inches wide, several alive at once in a settings pane.
Nothing in SaverKit has been changed for it. Note that the screensaver-session notification of §3
is **not** the fix — a thumbnail should render cheaply whether or not a screensaver is running.

A warning for whoever does fix it: the sheet's own preview is created at 384x216 and
`run-saver --preview` at 480x270, both comfortably under the threshold. **A gate tested only
against sizes you chose yourself is a gate you have not tested.**

### The settings sheet is a second view, and it leaks the same way

`reloadHost()` exists because settings are read when the host is built, so a running view keeps
whatever it launched with and OK appears to do nothing. It is safe only because it is main-thread
work between frames.

Four rules, each of which was learned the hard way:

- **The view retains the sheet and sets `isReleasedWhenClosed = false`.** Releasing on close hands
  the host a freed window the second time.
- **Re-read stored settings on every presentation, not in `init`**, or the second visit shows what
  the first left behind after a Cancel.
- **Nothing may render before the sheet is on screen.** `configureSheet` is a *property*; a host
  may read it and present nothing, so a preview started in the getter has no stop.
- **KVO on `window.isVisible` is the only hook that works.** On `endSheet`, `isVisible` goes false
  and the KVO fires, while `windowWillClose` and `windowDidEndSheet` do not arrive. Without it, a
  host-dismissed sheet leaves a tank rendering at 60 fps inside System Settings with nothing on
  screen to show for it.

Settings are read from `ScreenSaverDefaults(forModuleWithName:)` using the **saver bundle's**
identifier; `Bundle.main.bundleIdentifier` names the host appex's domain instead.

---

## 3. When a saver may make a sound, and which instance makes it

Sources: `spikes/006-saver-audio/README.md` (the plumbing),
`docs/tank-sound.md` §"The gate has two halves", `Savers/Aquarium/Sources/SoundSession.swift`.

This is the hardest thing in the repo to get right, because **the wrong answers all work when you
test them**. The cost of being wrong is sound playing on the user's desktop while they work.

### The rule

A view may be audible only when **both** of these are true, and then only if it holds the voice:

```swift
let running = SoundSession.shared.isScreenSaverRunning && isPresenting
let audible = running && AquariumSound.owner === self
```

Half one asks the system whether *a* screensaver session is running. Half two asks whether *this
view* is the one showing it. Shipping only the first half is what put sound on the user's desktop.

### Half one: the session notifications

Four distributed notifications, registered on `DistributedNotificationCenter.default()`:

```
com.apple.screensaver.didstart     com.apple.screensaver.willstart    -> running
com.apple.screensaver.didstop      com.apple.screensaver.willstop     -> stopped
```

Two details are load-bearing:

- **Register with `suspensionBehavior: .deliverImmediately`.** The default is `.coalesce`, which
  withholds notifications while the receiving application is not active — and a screensaver host
  is never "active" in that sense. With the default you simply never hear anything.
- **Stop on `willstop`, not `didstop`**, so the fade happens while the saver still covers the
  desktop. Measured order in the real host: `didstart` at 18.36, `willstop` at 35.25, `didstop` at
  35.26, `screenIsUnlocked` at 35.34.

**`didstart` is posted before the host process exists** — the engine posts the edge and *then*
spawns the host that loads your bundle. A fresh observer has already missed it. So the state is
**seeded at startup and allowed to settle**:

| Constant | Value | Why |
| --- | --- | --- |
| `SoundSession.settlingPeriod` | 1.5 s | Silent for this long from an instance's first frame |
| `SoundSession.reevaluationInterval` | 0.35 s | Throttle on re-guessing during the settle |
| Owner heartbeat timeout | 0.75 s | See below |

The seed itself is a heuristic — *is the System Settings process closed?* — and it is only a
heuristic. It cannot be evaluated at time zero, because the host appears before System Settings
has registered as a process; an immediate check was measured misclassifying the picker as a real
session and playing into it. Rechecks stop permanently the moment any real notification arrives.
A failure to read the process list becomes `false`, never "running": **the policy is to err
toward silence.** The known false negative is a user who leaves System Settings open and walks
away.

Use the **kernel process table**, not `NSWorkspace.runningApplications` — the latter was measured
returning an identical stale snapshot for ten seconds in this host.

### Half two: is this view the one on screen

The notification is true of the machine, not of your view. Hosts keep stale views for the life of
the process, and one was measured still animating ten minutes and a whole session later.

The window level is the only per-view signal that tracks this, and it has exactly three values:

| Raw level | Meaning |
| ---: | --- |
| `-2147483625` | Presenting the screensaver — for the session, and no longer |
| `-2147483622` | The `tools/run-saver.swift` harness window |
| `0` | `.normal` — the host has finished with this view, or its session ended under it |

```swift
static func isPresenting(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    return window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow))
}
```

**The comparison is against the desktop *icon* level (`-2147483603`), not the desktop level.**
Several summaries in this repo say "below the desktop level"; that is loose wording. The harness
window sits above the desktop but below its icons, and a literal desktop-level test would make
every harness run silent.

**Re-read the level every frame. Never cache it.** The host changes it underneath a live view
with no callback of any kind.

This half closes two measured failures that half one alone cannot:

- **A stale view claims the sound before the real one exists.** A prior view at level `0` took
  the voice on `didstart` at 09:24:46.441; the session's real view was not constructed until
  09:24:47.005 — 0.56 s later — and was then locked out by the do-not-steal rule.
- **A session dismissed inside its first second is missed entirely.** Both edges are posted before
  the host exists, so the startup guess is never corrected *in either direction*. One run seeded
  `running=true` and faded up onto the user's desktop, stopping only at `killall`. Level `0`
  rejects it.

### What does not work — do not re-derive these

Every one of these looks like it identifies a real session and does not:

| Candidate | Real session | Picker | Verdict |
| --- | --- | --- | --- |
| `ScreenSaverView.isPreview` | `false` | `false` | Useless |
| View width vs a threshold | 2056 pt | 2056 pt | Useless — the tile is a full-screen view |
| Width as a fraction of the screen | 1.00 | 1.00 | Useless |
| `occlusionState` | `occluded` | `occluded` | Useless |
| Shield-level window | never reached | never reached | Useless |
| `CGSSessionScreenIsLocked` | 1 | 1 | Useless |
| `frontmostApplication` | `loginwindow` | `loginwindow` | Useless |
| `CGDisplayIsAsleep` | false | false | Useless |
| Shield in `CGWindowListCopyWindowInfo` | `atShield=0` | `atShield=0` | Useless |
| Parent process | `launchd` | `launchd` | Useless |
| `ScreenSaverEngine` in `NSWorkspace` | sometimes | absent | Rejected — stale snapshot |
| `ScreenSaverEngine` in the sysctl table | absent | absent | Rejected — it is only a launcher and has exited |
| Is System Settings running? | false | true | **Kept, as a startup heuristic only** |

Three later theories about the host, all refuted:

- *"The picker's grid tiles are live views that play."* No — third-party tiles are static images
  (§1). The live objects were one full-screen view of the selected saver and one 0x0 view.
- *"Switching picker selection abandons the previous saver."* No — deselection produced a clean
  `viewDidMoveToWindow window=nil` and then `deinit`. The immortal view came from a dismissed
  session.
- *"A view born before the session cannot be the session's real view."* No — a real session reuses
  the picker's existing host and full-screen view.

### Which instance: one-owner arbitration

Three views in one process, ungated, produced *three engines and triple gain*.

`AquariumSound.owner` is a `weak static`. Once both gate halves pass: the current owner refreshes
its heartbeat; a non-owner claims only if there is no owner or the heartbeat has expired; a stale
owner is stopped before being replaced; and an owner that no longer passes the gate releases the
voice. The rule is **first eligible claimant wins, then never steal from an eligible owner** — an
earlier version let every observer claim in turn during a single notification delivery, which was
audible as a start, a cut and a restart.

Three timeouts, and they are deliberately different:

| Timeout | Value | Meaning |
| --- | --- | --- |
| `AquariumSound.ownerTimeout` | **0.75 s** | An owner this far behind on frames may be taken over |
| `SoundCore` frame-stall guard | **0.25 s** | The render thread decides it is no longer being looked at |
| Stall fade coefficient | **0.03 s** | So a stall fades rather than cutting square |

The ordering matters: a stalled owner fades itself out at 0.25 s, well before anyone may take the
voice at 0.75 s, so the handover is inaudible.

Use a machine clock (`CACurrentMediaTime()`), **not** the frame time — each view's `FrameContext.time`
starts from zero independently, so they cannot be compared across instances.

### What is still open

- **The arbiter is process-local.** Two views in one host share one voice correctly. **Two hosts
  would each start an engine.** The picker provably spawns two, and the gate keeps both silent
  there — but two *real* extended displays are untested, because this machine mirrors. A lock file
  in the shared container is the cheapest candidate fix; **it is not implemented.**
- **`stop()` does not fade.** It zeroes the gate and stops the engine in the same breath. Normally
  the session's own fade has already run, because `willstop` precedes teardown — but a host that
  discards a view *without* the session ending, which is the harness path, cuts rather than fades.
- **The login window is untested.** No verified result exists and no login-specific branch is
  implemented.

### Running it under the harness

```bash
AQUARIUM_SOUND=1 AQUARIUM_SOUND_SESSION=1 AQUARIUM_AUDIO_STATS=30 \
    AQUARIUM_AUDIO_RECORD=/tmp/tank.wav \
    tools/run-saver.swift Aquarium --size 1200x700 --seconds 95 --screenshot /tmp/t.png
```

**`AQUARIUM_SOUND_SESSION=1` is not optional**, and leaving it off is this loop's trap: without it
the gate falls back to "is System Settings open", which the harness cannot answer for itself, so
whether your recording contains anything depends on an unrelated window — and the failure is a
perfectly valid WAV of silence. The stats line names which half refused: `session idle` is half
one, `showing no` is half two.

These variables are harness overrides only. **The environment is empty under
`legacyScreenSaver`**, so none of them can affect an installed saver.

### If a second saver grows a voice

None of this lives in SaverKit yet; it is all under `Savers/Aquarium/Sources/`. The generic parts
— worth promoting the moment a second saver needs sound, and dangerous to reimplement from
scratch — are the notification registration and state handling, the startup seed and its settle,
`isPresenting` and its per-frame reevaluation, the one-owner heartbeat, and the frame-stall
fail-safe. `AquariumScene` already carries a note that `isPresenting` and its plumbing should move
into SaverKit together.

Genuinely Aquarium-specific, and not to be dragged along: the engine and its event API, the grain
library and everything about the soundscape, the settings flag and its default-off policy, and
the `AQUARIUM_*` diagnostics.
