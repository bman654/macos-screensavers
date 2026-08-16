# Spike 006 — can a screensaver make a sound?

**Question:** does audio reach the output device from inside a sandboxed
`legacyScreenSaver` on macOS 26, and do the three hazards in
`docs/saver-backlog.md` §"Ambient audio" behave the way that section guesses?

**Why it is phase 0 of anything.** The backlog's ambient-audio track — a low bubbling bed for
the aquarium, toggleable, default off — is designed around an assumption nothing has tested.
`WKWebView` looked equally safe in this host and blanked after three seconds with no
diagnostic. Audio *output* needs no entitlement where microphone input does, so it ought to
work; "ought to" is what this spike is here to replace.

**Answer: yes.** Audio reaches the output device from inside the sandboxed host, confirmed by
ear on the installed build in System Settings. Nothing in the backlog's ambient-audio track is
blocked.

**And the mechanism the feature needs is settled: gate audio on the screensaver *session*, not
on anything about the view.** `com.apple.screensaver.didstart` / `didstop` are distributed
notifications, they reach the sandboxed host, and they are the only signal that is both true of
the session and visible across processes. Every property of the view was tried first and every
one of them passed a picker thumbnail as a full-screen screensaver — including a view size that
*is* the full screen. That is the finding worth the spike.

Confirmed on the installed build: silent in the picker, plays on Preview, plays when the
screensaver starts for real, stops when it is dismissed, one voice at a time.

## The probe

`AudioProbe/` is a saver that plays a quiet arpeggio and prints what the audio stack is doing
on screen. It is not a sound design; the arpeggio exists only so a person can confirm the last
step that instruments cannot.

```bash
tools/build-saver.sh spikes/006-saver-audio/AudioProbe -i
tools/run-saver.swift build/AudioProbe.saver --size 1200x700 --seconds 8 \
    --screenshot /tmp/audioprobe.png
tools/run-saver.swift build/AudioProbe.saver --preview --seconds 4 \
    --screenshot /tmp/preview.png                      # must read "silent (preview)"
tools/run-saver.swift build/AudioProbe.saver --instances 3 --size 1200x700 \
    --seconds 10 --screenshot /tmp/three.png           # the per-display hazard
AUDIOPROBE_PREVIEW_AUDIO=1 tools/run-saver.swift build/AudioProbe.saver --preview --seconds 4
```

**The readout is the result, not the sound.** "I heard nothing" has four causes that want
completely different fixes, and only the last one needs ears:

| Symptom on screen | Cause |
|---|---|
| `engine FAILED <reason>` | the engine refused to start; CoreAudio says why |
| `output 0 Hz, 0 ch` | started, but there is no route to a device |
| `render 0 calls` while running | running, and nothing is pulling it — the sandbox is not asking for samples |
| counters climbing, no sound | it is being consumed and discarded, or it is a volume/routing problem |

`render` is the load-bearing instrument. It is incremented on CoreAudio's own render thread,
so it climbs if and only if the HAL is actually asking this process for samples. That is what
makes the login window testable at all: there is no console there, no debugger and no
environment, so whatever the probe has to say it has to say on screen.

## What holds, outside the sandbox

Measured through `run-saver` on macOS 26.5.1 / Apple Silicon:

- **Audio plays, and is consumed in real time.** 48000 Hz, 2 ch, and an 8-second run rendered
  388,096 frames — 8.1 seconds of audio. The counters track the wall clock, which is what
  distinguishes a device pulling samples from an engine that merely claims to be running.
- **`AVFoundation` and `Synchronization` need no build change.** Swift autolinking resolves
  both; `tools/build-saver.sh` did not have to grow a `-framework` flag, and no saver that
  wants audio later will either.
- **The preview gate works at harness sizes, and that proved nothing.** At 480x270 points the
  probe reads `silent (preview)` with `0 Hz, 0 ch` and zero render calls — the engine is never
  built, so a thumbnail costs nothing rather than being started and muted. But a harness can
  only test the sizes it is told to use, and the size that mattered was the picker's — which
  turned out to be the whole screen. See "There is no property of a saver view that says
  whether the screen is being saved". **A gate tested only against sizes you chose yourself is
  a gate you have not tested.**
- **Three instances in one process all play at once, and they can see each other.** With
  `--instances 3` the readout says `3 live, 3 audible`: three independent `AVAudioEngine`s,
  three voices, triple gain. That is the backlog's per-display hazard, observed. It also
  answers the harder half — the count is a process-wide `static`, so instances *do* have a way
  to discover one another as long as macOS puts them in one process.

## What the real host found

Both failures came from the same first run in System Settings, and neither is visible from a
harness. They are recorded in the order they will bite anyone who skips this spike.

### A window ordered out stops the frames and tells nobody

**The symptom:** dismissing the full-screen preview left it playing. So did closing System
Settings. The sound outlived both, and only `killall legacyScreenSaver` stopped it — the host
appex survives its client, so a saver abandoned in it plays into an empty room indefinitely.

**The cause**, isolated with `lifecycle-driver.swift`, which walks a view through the three
ways a host can stop showing it:

```
phase 2  window.orderOut()      no callback at all — and the frame heartbeat stops dead
phase 3  contentView = nil      viewDidMoveToWindow fires, window=nil, audio stops
phase 4  all references dropped no deinit — the view is immortal, exactly as SaverKit says
```

Ordering a window out stops the display link, because the view no longer has a display to
link to. It fires **no** `viewDidMoveToWindow`, no `stopAnimation`, no occlusion change that
reaches the view. So a saver that gates audio on AppKit's lifecycle callbacks — which is the
obvious design, and was this probe's first one — goes on playing after the only signal it was
watching for has failed to arrive.

**The fix, and it is the one general rule this spike produces: audio may only be produced
while frames are being produced.** The view bumps an atomic counter once per rendered frame;
the audio render block watches it and fades out when it stops moving. It needs nothing to be
notified of anything, which is the whole point — the failing case is a view that is
unreachable, so any fix requiring someone to call it is a fix that will not run.

Measured on the recorded output (`AUDIOPROBE_RECORD`), window ordered out at t=6.0:

```
t=5.8 -26.3 dBFS   t=6.2 -26.9   t=6.3 -42.4   t=6.4 -73.0   t=6.5 -111.6   t=11 -240
```

Full level to 6.2 s, inaudible by 6.35 s: a 0.25 s stall threshold plus a 30 ms ramp. The ramp
is not decoration — a gate that jumps to zero clicks, and a click is broadband, so it would be
audible through the very routing failures this probe exists to detect.

### There is no property of a saver view that says whether the screen is being saved

This is the spike's real result, and every geometric answer was tried against the real host
before it was reached. Each one passed a picker thumbnail as a full-screen screensaver:

| Signal | What the picker's thumbnail reports |
|---|---|
| `isPreview` | `false` |
| view width vs 600 pt | 2056 pt — not a preview |
| view width as a fraction of the screen | **1.00 — it is literally the whole screen** |
| `occlusionState` | `occluded`, and so is the real full-screen preview |
| window level | ordinary, and never `CGShieldingWindowLevel()` (2147483628) — no window here ever reaches it |

The picker's tile is a **2056x1329 view on a 2056-point screen**, scaled down into a tile by
something above the saver. So the tile and the real thing are the same size, and no measurement
of the view can separate them.

Worse, the view is never told when it stops being seen. Measured on the abandoned one: still
rendering at 60 fps, `window=shown`, `animating=true`, 2.26 million audio frames and climbing,
long after System Settings had been closed. The frame-stall guard above cannot fire, because
the frames never stall.

**So the question has to be asked of the system** — and even then, only half of it can be
answered cleanly. `com.apple.screensaver.didstart` and `didstop` are distributed notifications,
and they are confirmed to reach the sandboxed host:

```
18.36  notification com.apple.screensaver.didstart  -> running=true
35.25  notification com.apple.screensaver.willstop  -> running=false
35.26  notification com.apple.screensaver.didstop   -> running=false
35.34  notification com.apple.screenIsUnlocked
```

Three properties make this the right signal rather than merely a working one:

- **It is true of the session, not of a view**, which is what the question was actually about.
- **It crosses processes.** There are provably *two* hosts alive during one pass through the
  picker — one holding 0x0 views, one holding full-screen ones — so a `static` arbiter inside
  one of them could never have been sufficient on its own.
- **`willstop` arrives before `didstop`**, which is somewhere to fade out rather than cut.

Confirmed on the installed build: silent in the thumbnail, plays on Preview, plays when the
screensaver starts for real from a hot corner, stops on dismissal, and `1 audible` of `3 live`
throughout.

### The half that has no clean answer: the first activation

**`didstart` is posted before the host process exists.** The engine posts it, *then* spawns
`legacyScreenSaver`, which then loads this bundle — so on the first activation in a fresh host
the observer is installed at t=0.00 having already missed it. Only `willstop` and `didstop`
arrive. The saver therefore stays silent through exactly the session it was built for, and
learns the truth as the screen comes back. It works on the second and third activations because
the host survives, which is what makes it look intermittent when it is not: **it fails on the
one path every real user takes, and works on every path a person testing it takes second.**

An edge nobody can be present for is not a signal, so the state has to be readable at startup.
Everything plausible was measured, in both a real screensaver session and an open picker:

| State query | Screensaver running | Picker open | Use |
|---|---|---|---|
| `ScreenSaverEngine` in `NSWorkspace.runningApplications` | present *sometimes* | absent | **no** — the list is a stale snapshot in this host; identical for 10 s across a session that provably started, and `didLaunchApplicationNotification` never fires |
| `ScreenSaverEngine` in the kernel process list (`sysctl`) | **absent** | absent | **no** — on Tahoe it is a launcher that has exited before anything is drawn |
| `CGSSessionScreenIsLocked` | 1 | 1 | no |
| `frontmostApplication` | `com.apple.loginwindow` | `com.apple.loginwindow` | no |
| `CGDisplayIsAsleep` | false | false | no |
| shield-level window in `CGWindowListCopyWindowInfo` | `maxLayer=2004, atShield=0` | `maxLayer=2004, atShield=0` | no |
| parent process | `launchd` | `launchd` | no |
| **is System Settings running** | **false** | **true** | **yes, as a heuristic** |

So the startup seed is "no settings pane open, therefore this host was spawned to save the
screen". It is a heuristic and it is wrong in exactly one direction: a user who leaves System
Settings open and walks away gets a silent screensaver. That is the direction to be wrong in,
and `didstart` corrects it for every activation after the first.

**It cannot be evaluated at t=0 either.** The host is spawned before System Settings has
registered as a process, so a probe that decided immediately concluded "no settings pane" and
played into the picker — measured, after the seed was first added. The state is only knowable a
moment later, so it is asked again a moment later: audio is held for a 1.5 s settling period and
the guess is re-run on each heartbeat until a real notification supersedes it. **That delay is
free, because ambience should fade in over seconds rather than appear.**

Measured, both cases, on the installed build:

```
picker open        0.54 audio -> settling   2.56 heuristic recheck -> running=false   silent
real screensaver   0.54 audio -> settling   2.57 audio -> PLAYING  2.86 engine STARTED
```

### One notification, several claimants, one stutter

Both audible cases began with the first note starting, cutting off, and starting again —
user-reported, and exactly right. The screensaver starting is *one* notification delivered to
every view's observer in turn, so all of them become eligible inside the same runloop pass, and
each claimed the sound as it woke:

```
18.37  [A] audio -> PLAYING
18.84  engine STARTED
18.84  [C] session changed -> running=true
18.84  [A] yielding audio to [C]
18.84  engine STOPPED after 0 frames
18.95  engine STARTED
```

The rule is now that nobody takes the sound from an owner still entitled to it. First eligible
claimant wins and keeps it; which view that is does not matter, because they are all in the
same session and a sound has no position on screen to be wrong about.

**And a number for whoever designs the real thing: `AVAudioEngine.start()` took 470 ms** —
18.37 to 18.84 above. Ambience should therefore start its engine once and ride a gain ramp,
never start and stop the engine to mute and unmute. A fade is instant; a start is half a
second, and it lands exactly at the moment the screen has just gone dark.

### `isPreview` is wrong in the picker, and this is not only an audio bug

`HostContext.isPreview` is what the aquarium uses to cut particle counts and skip expensive
passes, and it is derived from view width because `ScreenSaverView.isPreview` is unreliable.
Both are wrong for the Tahoe picker: the flag is `false` and the view is the full size of the
screen. **So the picker has been rendering full-fat tanks into a thumbnail all along** — five
lights, caustics, god rays, bloom and MSAA, for a tile a couple of inches wide, in a settings
pane that keeps several of them alive at once.

Nothing has been changed in SaverKit for it. It wants its own pass, with the aquarium in front
of someone, and it is now measurable: the probe logs `widthGate=` and `fractionGate=` beside the
real numbers. Note that the session notification is not the answer for *this* half — a
thumbnail should render cheaply whether or not the screensaver is running, so the cost gate and
the audio gate are different questions with different signals.

## Still to test

**The login window.** Log out and let the saver start at the login screen; read `engine` and
`render` off the screen. This is the one case with no log to read, and it is why the probe
draws its diagnostics rather than only writing them. It is also the case most likely to differ,
since the distributed notification the audio gate now depends on is posted in a different
session context.

**Two real displays.** Untestable on this machine, which mirrors rather than extends.
`--instances` stands in for several views in one process, and the picker showed two *processes*
— but neither tells us what two screens do. The session notification should hold either way,
being system-wide; what is unknown is whether both hosts then play at once, since the
`static` owner only arbitrates within a process. If they do, the arbiter has to move to
something cross-process, and the cheapest candidate is a lock file in the container both hosts
already share.

## What the real feature should take from this

1. **Gate on the session, never on the view.** `com.apple.screensaver.didstart` / `willstop` /
   `didstop`, registered `.deliverImmediately` — the default `.coalesce` withholds them from a
   process that is never "active", which a screensaver host never is.
2. **Seed the state at startup and let it settle**, because `didstart` is unreachable on a fresh
   host. Hold audio ~1.5 s and re-check until a notification supersedes the guess.
3. **Fade out on `willstop`, not `didstop`**, so ambience ends under a screensaver still on
   screen rather than being cut off by the desktop returning.
4. **Start the engine once and ride a gain ramp.** `AVAudioEngine.start()` measured at 470 ms;
   a fade is instant. Never start/stop the engine to mute and unmute.
5. **One owner, and never steal from an eligible one.** Within a process a `static` is enough.
   Across processes it is not, and this spike could not test two displays — if two hosts ever
   play at once, the arbiter needs a lock file in the container they already share.
6. **Ramp every gate change.** A square-edged gate clicks, and a click is broadband — it is
   audible through the very routing failures a probe like this exists to detect.

**Not for production as written:** the probe's heartbeat calls `stateSnapshot()`, which
enumerates every process on the machine every two seconds. That is a diagnostic, and it must not
survive into a saver.

## What this spike is not

It is not sound design. The arpeggio is a test signal chosen to be unmistakably artificial,
quiet, and free of clicks — a square-edged gate would be broadband and audible *through* the
low-level routing failures this probe exists to detect, so it would lie about success.

Bubbles come next, and the tooling for them is a Python script rather than a sample library:
a bubble in water is a Minnaert resonator whose frequency is set by its radius alone
(f·r ≈ 3260 Hz·mm), which makes an aquarium bed one of the few sounds that is genuinely
parametric in the way this repo's models are. That is phase 1, and it is only worth starting
once the answer above is yes.
