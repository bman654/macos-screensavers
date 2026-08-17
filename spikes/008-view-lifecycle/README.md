# Spike 008 — what keeps an abandoned saver view alive, and what it can do about it

**Question.** After a screensaver session ends, `legacyScreenSaver` keeps a view alive that
nobody can see. What retains it, can the view notice on its own, and can it get rid of itself?

**Answer, in one line.** The *host* retains it — its own container view and its ViewBridge
window — so the view cannot die; but its render graph is the whole cost, the view can notice
the host has stopped drawing it because the 1 Hz `ScreenSaverView` timer keeps ticking while
the display link has gone silent, and it can hand the graph back and rebuild it on the next
frame. That is now in `SaverView` (`idleReleaseDelay`, `releaseHostIfIdle`, `didReleaseHost(_:)`).

Everything below was measured on macOS 26.5.1 on this machine, 2026-08-17.

## 1. The retain tree of a real leftover

A `legacyScreenSaver` (pid 7492) had been idle for twenty minutes after an idle-triggered
session: **0.0% CPU, 612 MB footprint, one `AquariumView`**, one window in the
`CGWindowList` — layer 0, 3840x2160, alpha 1, **not on screen**. `heap`/`leaks` work on it
without a debugger:

```
heap 7492 -addresses AquariumView          # -> 0xc53186400
leaks 7492 --traceTree=0xc53186400
```

The strong roots, noise removed:

```
<AquariumView 0xc53186400>
  <NSPointerArray> __strong slice.items
    <ScreenSaverView 0xc52d34500> +24: _respondersWeAreNextFor      <- host's container view
      <LegacyViewController> +64: view                              <- LegacyViewController.view
        <NSViewServiceMarshal> _viewController
        <LegacyExtensionManager> _viewControllers  <- ScreenSaver __bss 'sSharedManager'
      <NSKVONotifying_NSServiceViewControllerWindow> +104: _initialFirstResponderX
        <NSViewServiceApplication> _openWindows                    <- window still open
  <NSTimer 0xc52877000> +160  <- CFRunLoopMode <- main CFRunLoop    <- ScreenSaverView's timer
  <__NSMallocBlock__> -[NSView(NSDisplayLinkInternal) _displayLinkWithOptions:target:selector:]
                      __strong [capture]                          <- our CADisplayLink's target
```

Read it as four references. Two are the host's and cannot be broken from inside the bundle:
the container `ScreenSaverView` (a plain instance the host creates with `isPreview:YES` and a
zero frame, per the appex disassembly — our view is its subview and it is our `nextResponder`,
which on macOS 26 is a *strong* back-reference) and the ViewBridge marshal window, still in
`NSApp`'s open-window list, whose `initialFirstResponder` is our view. Two are ours, and both
exist because **`stopAnimation()` was never called on this view**: `ScreenSaverView`'s
`_animationTimer` and the display link. Breaking ours would free the view's own 768 bytes and
nothing else.

**So the goal cannot be deallocation.** The 612 MB is the scene, the renderer, the attachments
and the drawables — everything hanging off `SaverView.host` — and that is what a view can let
go of by itself.

## 2. What a view can observe, phase by phase

`driver.swift` walks a saver through the ways a host stops showing a view, 8 s per phase, and
`LifeProbe/` is a `SaverView` subclass that logs every edge and counts both link frames and
`animateOneFrame` ticks. `swiftc -O driver.swift -o /tmp/lifedriver` — **compile it**; under
the `swift` interpreter every trace is buried in JIT noise and the top-level autorelease pool
retains the view (see §4).

```
                          viewDidMove   KVO           occlusion    link      animateOneFrame
                          ToWindow      isVisible     notification frames    (1 Hz timer)
window.orderOut()         no            -> false      fires        stop      keeps ticking
window.orderFront()       no            -> true       fires        resume    (was ticking)
contentView = nil         yes, nil      -            -            stopped   stops (window nil)
window.close()            no            (not meas.)  (not meas.)  stop      keeps ticking
```

Three corrections to what the repo believed:

- **`orderOut` is not callback-free.** KVO on `window.isVisible` and
  `NSWindow.didChangeOcclusionStateNotification` both fire. What does not fire is anything on
  the *view* — `viewDidMoveToWindow`, `stopAnimation` — which is all the earlier probe watched.
- **A plain timer survives `orderOut`.** The inherited `-[ScreenSaverView _oneStep:]` is gated
  on `[self window] != nil` and nothing else (disassembled; §5), so it ticks through `orderOut`
  and through `close` — that is what proved a run-loop timer is a heartbeat the host cannot
  take away. SaverView's watchdog is nonetheless its *own* weak 1 Hz timer, because the
  inherited one stops when the window goes nil and can be switched off by
  `SSENeedsAnimationTimer` in the saver's Info.plist (which `ScreenSaverView` reads from the
  *saver's* bundle), and the watchdog has to run in exactly the states where nothing else does.
- **The link resumes by itself.** `orderFront` after `orderOut` restarts frames with no call
  of any kind, so a resume path that waits for a frame needs no notification either.

## 3. The release, measured

With `SAVERKIT_LIFECYCLE=1` and the Aquarium at 1200x700 in the driver, `footprint <pid>`
sampled every 2 s:

```
phase 0   animating                     495 MB
orderout  +4 s: "hibernated"            287 MB      <- host, scene, attachments gone
orderin   next frame: "woke", makeHost  613 MB      <- rebuilt; caches from look 1 remain
orderout  +4 s: "hibernated"            348 MB
```

At 3840x2160 (`LIFEDRIVER_SIZE=3840x2160`): 886 → 387 MB hibernated once the layer's drawable
pool is shrunk with the rest (450 MB before that line was added — the pool is ~60 MB at 4K).

Five cycles at 1200x700: hibernated footprints 276, 341, 368, 373, 382 MB and awake 436, 681,
804, 817, 805 MB — both plateau. So the *high-water mark* of a view that wakes is higher than
its first look, by the process-wide caches (SceneKit's resource manager, shader and pipeline
caches) that `reloadHost()` has always left behind; it is bounded, and it is not the leak. A
wake costs about 0.6 s of main thread at 1200x700 (frame interval straddling the rebuild,
`SAVERKIT_STATS`), several times that at 5K with MSAA — and it rebuilds the *same* tank: the
Aquarium carries its seed across an idle release (`seed=258962` on both `scene built` lines
of an `orderout,orderin` run), and only a `.reload` draws anew.

`contentView = nil`, `startAnimation()` before a window (`detach,stop,start`), `close`, a
hidden view and a window moved off-screen all release through the same one test — no
committed frame for 4 s — and re-attaching to a shown window wakes. A view the host has
*properly* stopped is deliberately not released: it keeps its scene, as System Settings'
stop/start of a preview expects. Not released, correctly: a window at alpha 0 or fully
covered, both of which keep a 60 fps link.

## 4. The "no deinit" from spike 006 was the harness

Spike 006 recorded that dropping every reference to a detached view produced no `deinit`, with
no root cause. The root cause is the driver, twice over: created at top level of a `swift`
script, the view's autoreleased +1 sits in the main thread's outermost pool, which never
drains; and the borderless window, never `close()`d and `isReleasedWhenClosed = false`, stays
in `NSApp.windows` and — measured — its `NSNextStepFrame._subviews` still holds the view after
`contentView = nil`. Neither is SaverKit's. With the view created inside an `autoreleasepool`
and the window closed, the only remaining referrer after `detach` was AppKit's notification
registrar, and after `stop,detach,close,drop` nothing of SaverKit's — no link, no timer — was
in the tree at all. The regression test is still `SAVERKIT_LIFECYCLE=1` and counting lines, but
count `hibernated`/`woke` as well now, and only ever in a compiled harness.

Reviewed adversarially before landing (two reviewers, different model families); what changed
because of it: the watchdog became SaverView's own timer rather than `animateOneFrame`, so a
`startAnimation()` with no window is covered; only a *committed* frame counts as activity, so a
view whose `render` bails on a missing attachment or drawable ages out instead of holding a dead
scene (and rebuilds at most once per delay); an idle release no longer clears `hostFailed`; the
drawable pool is shrunk; the seed survives a wake. Known and accepted: a main thread frozen
past 4 s, or a display asleep that long with the session still up, gets a rebuild on the next
frame rather than a resume; the Aquarium's audio re-runs its 1.5 s settle after a wake, which is
the same path a settings reload takes; `AQUARIUM_AUDIO_RECORD` would be truncated by a wake,
which no harness path can produce.

## 5. What the field does, for the record

Web and binary research done alongside this spike — `research.md` beside this file is the
sourced report; the load-bearing facts are repeated here:

- The defect is Apple's and universal since Sonoma: `stopAnimation` is not sent to a real
  session's view, the host process persists, instances stack (Apple Developer Forums 738547
  and 787444, FB13041503, FB19204084; jwz's XScreenSaver 6.08 notes; Aerial #1305/#1339/#1396;
  the ScreenSaverMinimal README).
- The community answer is **observe `com.apple.screensaver.willstop` and exit the host** —
  XScreenSaver (`terminate:`), Aerial (`exit(0)`, delayed 2 s on Tahoe because an immediate
  exit made beta 4 relaunch the host), and half a dozen smaller savers. It is a mitigation:
  `willstop` was measured missing under rapid Sonoma start/stop, it never reaches a picker
  preview, and one host holds several savers' views (`lsof` here: Aquarium and AudioProbe in
  one pid), all of which an `exit` takes with it. **Not adopted here**; the idle release frees
  what matters without killing anyone, and the option is recorded in `docs/saver-host.md`.
- Wade Tregaskis's "lame duck" pattern — a new instance posts on the local
  `NotificationCenter` and older instances neuter themselves — solves stacking *within* one
  host and would suit the audio arbiter; it does not free anything the host holds.
- From the appex and framework disassembly: `LegacyViewController.view` is a stock
  `ScreenSaverView`; its references to our view are `weak`; `setLegacyModuleView:` stops and
  removes the *previous* module view when a new one is installed into the same controller
  (which is why later views deinit and the first does not); `ScreenSaverExtensionManager`
  accumulates view controllers except in preview; `startAnimation` is deferred until a first
  non-zero resize and dispatched async; a `{0,0}` ghost host is spawned beside every real one;
  `com.apple.screensaver.willstart` does not exist in any binary on this machine, while
  `previewdidstop` and `didlaunch` do.

## 6. The leftover that keeps rendering — measured on the real host, and closed

Spike 006 had measured a *different* leftover: a picker-spawned host whose view went on
rendering at 60 fps after System Settings quit, `window=shown`, level 0. Its link never goes
silent, so the idle release of §3 cannot see it. On 2026-08-17 the same shape turned up after
an ordinary **hot-corner session** on the installed build: the host was at ~24% CPU and
623–627 MB two minutes after dismissal, `sample` showed `frameLinkFired → render →
SceneKitHost.encode` every frame, and `winlist.swift` showed its 3840x2160 window at layer 0
and off-screen. §3's release had nothing to release: frames never stopped.

**What the view can see, logged from inside the host.** `LifecycleLog` (gated by
`SAVERKIT_LIFECYCLE=1` or a `saverkit-lifecycle.enable` sentinel in the host container's `tmp`
— `launchctl setenv` never reaches the appex, and `log show` needs Full Disk Access, so the log
also goes to a file there) writes one line a second per animating view with every readable
window property beside the frames it committed. Across a hot-corner session and its dismissal:

```
15:19:36  frames=44  level=-2147483625  isVisible=true onActiveSpace=true occlusion=occluded
                                        screen=true alpha=1.0 cgOnscreen=false cgListed=false
   …      frames=60  level=-2147483625  (identical)
15:19:47  frames=58  level=0            (identical)          <- dismissed
   …      frames=60  level=0            (identical, for the life of the process)
```

**Every property but the level read the same before and after.** `isVisible`, `isOnActiveSpace`,
`occlusionState` (occluded during the real session too), `screen`, `alphaValue`, and both CG
window-list bits (the appex's window is not in the CG list from inside the appex at all). The
level is the only signal, and it says "not presenting" — which is also what the picker's live
preview says. The tie is broken by the process table: a full-screen view at `.normal` in a host
with no System Settings behind it has nobody to draw for.

**The fix is `SaverView.hasAudience()`**, checked in the link callback before the wake and
before `render`. A view draws if its window is at any level but `.normal` (the one level
measured for a leftover — a wrong "no" here is a black screensaver, so unmeasured levels draw),
or it is preview-sized, or it has never presented and System Settings is running (asked of the
kernel every 3 s, one shared answer per bundle, first answer held for an interval because the
host is spawned before Settings registers, and never while presenting). A view that has once
presented is a session's, and at `.normal` it is a leftover no matter what else is running.
Otherwise it commits nothing, and §3's watchdog hibernates it 4 s later. `run-saver.swift` sets
`SAVERKIT_AUDIENCE=1` for itself, because its interactive window is an ordinary window at level
0 — the exact shape of a leftover — and only the harness knows the difference;
`SAVERKIT_AUDIENCE=0` makes that window play the leftover, and it hibernates in the harness 7 s
after start. Also measured on the way: the gate must precede `wakeIfHibernating()`, or a
hibernated view with no audience rebuilds its graph on every tick and releases it 3 ms later.

**Verified on the installed build, hot-corner session, 2026-08-17:**

```
15:30:32  frames=44  level=-2147483625   presenting
15:30:44  frames=8   level=0             dismissed; gate engaged within the second
15:30:45  audience: none
15:30:47  frames=0
15:30:48  hibernated
```

`footprint`: **135 MB** (had been 623–627 MB); `heap` shows the `AquariumView` and no
`SCNRenderer`/`SCNScene`; CPU at the noise floor. A second hot-corner session in the same host
built a *new* view, which presented at 60 fps while the first stayed hibernated
(`host=false drawable=1x1`), then hibernated 4 s after its own dismissal: two views, 248 MB
(process-wide caches, §3), ~0–1% CPU. Reuse of a hibernated view by a later session is the
wake path of §3, unchanged.
