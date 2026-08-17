# Third-party macOS screen-saver lifecycle leak research

**Date:** 2026-08-17  
**Scope:** `ScreenSaverView` plug-ins hosted by `legacyScreenSaver.appex`, especially Sonoma 14, Sequoia 15, and Tahoe 26.  
**Evidence labels:** **Verified** means a linked primary source, published source code, or direct inspection. **Inference** means the source supports but does not directly prove the conclusion.

## Executive answer

- **Verified:** This is a widely reproduced Apple-host lifecycle defect, not an isolated saver bug. Since Sonoma, the real host may call `startAnimation` but omit `stopAnimation`, retain invisible saver instances, create more on later launches, and continue consuming CPU/GPU/RAM. The clearest sources are [Apple Developer Forums 738547](https://developer.apple.com/forums/thread/738547), [jwz's XScreenSaver 6.08 post](https://www.jwz.org/blog/2023/10/xscreensaver-6-08-out-now/), [Aerial/ScreenSaverMinimal](https://github.com/AerialScreensaver/ScreenSaverMinimal/blob/0bd0cd2d0f03078918946b54f74ca7df81be8545/README.md#L114-L127), and [Apple's Tahoe thread](https://developer.apple.com/forums/thread/787444).
- **Verified:** Open-source projects converged on a private distributed notification, `com.apple.screensaver.willstop`, followed by explicit teardown and then `NSApplication.terminate` or `exit(0)`. XScreenSaver, Aerial, Word Clock, Ealain, Snoopy, Matrix, and templates all use or document this pattern.
- **Verified:** It is only a mitigation. Aerial observed `willstop` missing under rapid Sonoma 14.1 start/stop cycles ([#1339](https://github.com/JohnCoates/Aerial/issues/1339)), and immediate exit caused Tahoe beta 4 to relaunch the host. Aerial changed to a two-second delayed exit ([commit](https://github.com/JohnCoates/Aerial/commit/db4a0da626ec65facd54cd94b9d46c9a1addedb3)).
- **Verified:** No window/view callback is a dependable universal “session ended” signal. A discarded XScreenSaver window still reported `visible` and `onActiveSpace`; an Apple forum developer found occlusion notification ineffective and window-level polling merely “closest.” `viewWillMove(toWindow:)` and `NSWindowWillClose` do not describe `orderOut`.
- **Not found:** Public documentation or source for `LegacyViewController`, `LegacyExtensionManager`, or `SSENeedsAnimationTimer`, or a documented host contract for preview-to-session view reuse. The private Tahoe binary exposes the first two names, but that reveals method names, not ownership semantics.

## 1. Platform-level evidence

### Sonoma 14

**Verified — Apple Developer Forums.** In [“Third-party screensavers not quitting on Sonoma”](https://developer.apple.com/forums/thread/738547), the reporter says dismissal leaves the saver animating invisibly and every activation creates another copy:

> “when the user dismisses the screensaver, it continues to animate invisibly in the background using up CPU and GPU cycles.”
>
> “The call to stop animating is also never sent to the view, as far as I can tell.”

The thread records additional `legacyScreenSaver` threads per activation, ~20% background CPU, failed `NSWindowDidChangeOcclusionStateNotification`, and window-level polling as the closest detector. An Apple DTS engineer says the legacy API depends on a “complicated compatibility shim” that is an ongoing source of bugs; the public recommendation is to file bugs/request a modern app-extension API. Feedback: FB13041503.

**Verified — Apple API contract versus observed behavior.** Apple says [`startAnimation()`](https://developer.apple.com/documentation/screensaver/screensaverview/startanimation()) activates the periodic timer and [`stopAnimation()`](https://developer.apple.com/documentation/screensaver/screensaverview/stopanimation()) deactivates it. Thus omission of the host call leaves the framework timer active; the forum and XScreenSaver sources confirm continued callbacks in practice.

**Verified — field reports.** LifeSaver users saw >100% CPU that compounded on later launches ([issue #25](https://github.com/amiantos/lifesaver/issues/25)); Predator logged a Sonoma memory-leak report ([#13](https://github.com/vpeschenkov/Predator/issues/13)); ArtSaver users reported `legacyScreenSaver` reaching 30+ GB ([#16](https://github.com/GabZach/ArtSaver/issues/16)). These reports establish impact, not the exact retain graph.

### Sequoia 15

**Verified, but weaker:** An [Apple Community thread](https://discussions.apple.com/thread/255256761) includes users reporting the same runaway process on Sequoia 15.0.1, including Fliqlo. The LifeSaver maintainer reported in January 2025 that later launches degraded and force-quitting all legacy hosts restored behavior ([comment](https://github.com/amiantos/lifesaver/issues/25#issuecomment-2614947058)). I found no Sequoia-specific source-level change to the host lifecycle.

### Tahoe 26

**Verified — Apple Developer Forums.** [Thread 787444](https://developer.apple.com/forums/thread/787444) records FB19204084, “Screen Saver accumulates instances of ScreenSaverView over time without stopping them,” with stacked CPU/GPU/RAM use and eventual black screens. It also records wrong `isPreview`, duplicate processes/instances, and monitor routing regressions. DTS did not expect a modern third-party appex API in macOS 26.

**Verified — Aerial instrumentation.** In [Aerial #1396](https://github.com/JohnCoates/Aerial/issues/1396), glouel disabled process exit and saw instances stack and retain memory even after manually tearing down content:

> “we're still stacking instances and hogging memory if we don't exit(0).” ([comment](https://github.com/JohnCoates/Aerial/issues/1396#issuecomment-3109451813))

Tahoe's picker spawned Preview and FullScreen instances with incorrect roles; the FullScreen instance animated in the preview window ([comment](https://github.com/JohnCoates/Aerial/issues/1396#issuecomment-3127601716)). This corroborates malformed lifecycle routing but does **not** prove that one exact view object is reused from picker to a later real session.

## 2. XScreenSaver / jwz: the strongest source-level diagnosis

**Verified — diagnosis.** jwz wrote for Sonoma 14.0:

> “Apple's screen saver framework calls `startAnimation`, but never calls `stopAnimation`, or kills the process.”
>
> “it just keeps running forever in the background on a now-invisible window”

Source: [XScreenSaver 6.08 out now](https://www.jwz.org/blog/2023/10/xscreensaver-6-08-out-now/); the [official changelog](https://www.jwz.org/xscreensaver/changelog.html) calls it a macOS 14.0 bug where savers run invisibly after unblanking.

**Verified — immortal/revived instances.** The 6.08 source comments say `legacyScreenSaver` never exits, the invisible window remains both `visible` and `onActiveSpace`, and the host “holds on to old copies of this bundle and begins animating them again” ([`XScreenSaverView.m`](https://github.com/Zygo/xscreensaver/blob/0c43268adc2e7a932ca5427db7b18d37ef53f7ad/OSX/XScreenSaverView.m#L564-L605)). Randomizer observed `animateOneFrame` sent to savers already stopped on earlier runs ([`Randomizer.m`](https://github.com/Zygo/xscreensaver/blob/906693799e4fb7581436590cf84ecb2d3c9186ba/OSX/Randomizer.m#L353-L415)). The GitHub repository is a line-addressable mirror of jwz's official release tarballs; jwz [does not publish a public development repository](https://www.jwz.org/xscreensaver/download.html).

**Verified — workaround.** For non-preview sessions XScreenSaver observes `willstop`, calls:

```objc
[self stopAnimation];
[[NSApplication sharedApplication] terminate:self];
```

Source: [`XScreenSaverView.m` lines 583–593](https://github.com/Zygo/xscreensaver/blob/0c43268adc2e7a932ca5427db7b18d37ef53f7ad/OSX/XScreenSaverView.m#L583-L593). Its `dealloc` also calls `stopAnimation` defensively, but host retention means `dealloc` cannot be the primary cleanup path ([lines 789–821](https://github.com/Zygo/xscreensaver/blob/0c43268adc2e7a932ca5427db7b18d37ef53f7ad/OSX/XScreenSaverView.m#L789-L821)).

**Verified — wrapper behavior.** `SaverRunner.m` is XScreenSaver's test/standalone wrapper, not Apple's host. It explicitly stops the saver when its window closes “Without this, timers might fire after the window is dead” ([lines 1690–1707](https://github.com/Zygo/xscreensaver/blob/906693799e4fb7581436590cf84ecb2d3c9186ba/OSX/SaverRunner.m#L1690-L1707)), and creates a fallback timer for older hosts ([lines 1660–1684](https://github.com/Zygo/xscreensaver/blob/906693799e4fb7581436590cf84ecb2d3c9186ba/OSX/SaverRunner.m#L1660-L1684)). This is good design evidence, not evidence of Apple's `orderOut` behavior.

**Coverage limit:** I found no jwz/XScreenSaver source diagnosis specifically for Sequoia or Tahoe. The Sonoma workaround remains in current releases. jwz said in 2026 that he remained on macOS 14.7.7 ([comment](https://www.jwz.org/blog/2026/01/xscreensaver-6-14/#comment-265694)).

## 3. Aerial's evolution

1. **Sonoma workaround origin:** A developer tried `exit(0)` in `willstop` and found it terminated the legacy host ([Aerial #1305 comment](https://github.com/JohnCoates/Aerial/issues/1305#issuecomment-1680853387)). Aerial shipped it in [commit 8c78e7c](https://github.com/JohnCoates/Aerial/commit/8c78e7cc4f77f4417371966ae7666125d87496d1), gated to macOS 14+ and not Companion mode.
2. **Notification is lossy:** On Sonoma 14.1 rapid hot-corner start/dismiss cycles, logs showed the OS simply omitted `com.apple.screensaver.willstop`, leaving an orphan ([#1339](https://github.com/JohnCoates/Aerial/issues/1339)). `com.apple.screenIsUnlocked` was visible at the OS level but not delivered to the sandboxed saver ([comment](https://github.com/JohnCoates/Aerial/issues/1339#issuecomment-1763453884)).
3. **Tahoe relaunch race:** Immediate `exit(0)` made Tahoe beta 4 relaunch the host about 700 ms later. A two-second delayed exit stopped that in testing ([discussion](https://github.com/JohnCoates/Aerial/issues/1396#issuecomment-3109488926), [commit](https://github.com/JohnCoates/Aerial/commit/db4a0da626ec65facd54cd94b9d46c9a1addedb3)). The value is empirical and rapid re-entry during the delay remains a race.
4. **Additional defense:** Aerial also exits on `NSWorkspace.willSleepNotification` because display sleep can stack another instance. ScreenSaverMinimal guards duplicate `startAnimation` and erroneous `stopAnimation` ([source](https://github.com/AerialScreensaver/ScreenSaverMinimal/blob/0bd0cd2d0f03078918946b54f74ca7df81be8545/ScreenSaverMinimal/ScreenSaverMinimalView.swift#L154-L183)), ignores Tahoe's zero-frame ghost, and tears down before its delayed exit ([source](https://github.com/AerialScreensaver/ScreenSaverMinimal/blob/0bd0cd2d0f03078918946b54f74ca7df81be8545/ScreenSaverMinimal/ScreenSaverMinimalView.swift#L300-L359)).
5. **Preview detection:** Historic `isPreview` values were wrong, so Aerial used frame size. Tahoe can swap the flags/roles; the template uses `CGSessionCopyCurrentDictionary` lock state and a zero-frame ghost test. This is a picker classification workaround, not a general end-of-session signal.

## 4. Other projects and workarounds

| Project | Concrete evidence | Adopted/proposed action |
|---|---|---|
| ScreenSaverMinimal | Says host sends no proper stop, destroys no instance, and piles up views ([README](https://github.com/AerialScreensaver/ScreenSaverMinimal/blob/0bd0cd2d0f03078918946b54f74ca7df81be8545/README.md#L114-L127)) | Observe `willstop`, stop custom timer, delayed `exit(0)` ([source](https://github.com/AerialScreensaver/ScreenSaverMinimal/blob/0bd0cd2d0f03078918946b54f74ca7df81be8545/ScreenSaverMinimal/ScreenSaverMinimalView.swift#L323-L348)). |
| Word Clock | Sonoma process kept running ([merged PR #324](https://github.com/simonheys/wordclock/pull/324)) | Non-preview `willstop` → `NSApplication.terminate`. |
| Ealain | Commit message: “screensaver running indefinitely” ([commit](https://github.com/amiantos/ealain/commit/ad9f29f941aa579951c8c27e5e54b42f3059d61f)) | macOS 14+ `exit(0)`; older OS calls `stopAnimation()`. |
| Snoopy | README says macOS does not call `stopAnimation`, causing legacy-host memory trouble ([README](https://github.com/hitnology/snoopy/blob/e2b8ac093914b87429fa3e71b51694f0319a0054/README.md#L16-L22)) | `willstop` → `exit(0)` ([source](https://github.com/hitnology/snoopy/blob/e2b8ac093914b87429fa3e71b51694f0319a0054/snoopy/snoopyView.m#L191-L215)). |
| Matrix | Release notes call it an all-third-party-saver CPU/memory bug ([README](https://github.com/monroewilliams/MatrixDownload/blob/ff13a12d4b60a5b8866bcb958137eda706b244d0/README.md#L17-L23)) | `willstop` → `exit(0)`, with a preference to disable it. |
| Today | Tested on M3 Sonoma ([PR #1](https://github.com/gingerbeardman/today/pull/1), open) | Non-preview `willstop` → `NSApplication.terminate`. |
| Brooklyn | Sonoma fix attempted ([PR #126](https://github.com/pedrommcarrasco/Brooklyn/pull/126), closed/unmerged) | Non-preview `willstop` → terminate. |
| Kotlin saver article | Detailed independent reproduction: `stopAnimation` essentially never called in production; no useful view property/app notification changed ([article](https://zsmb.co/building-a-macos-screen-saver-in-kotlin/)) | `willstop` → terminate; Tahoe update delays termination. |
| Wade Tregaskis guide | Documents production `stopAnimation` omission and process persistence ([article](https://wadetregaskis.com/how-to-make-a-macos-screen-saver/)) | Marks older instances “lame ducks,” observes `willstop`, and uses a bounded idle process exit. |
| ArtSaver / external watcher | User saw 30+ GB ([issue #16](https://github.com/GabZach/ArtSaver/issues/16)); proper in-bundle fix proposed in [#18](https://github.com/GabZach/ArtSaver/issues/18) | LaunchAgent periodically kills host only while saver is inactive; proposed replacement is `willstop` → terminate. |
| Kill-legacyScreenSaver | User-facing Sonoma+ memory watchdog ([repo](https://github.com/cccccyyyf/Kill-legacyScreenSaver)) | External shell job kills host above a memory threshold. |

I found no comparable lifecycle-leak documentation in the searched Padbury Clock, HALscreensaver, Cellular/AtomicClock/Nordic, or generic Vue/template repositories. That is a negative search result, not evidence they are unaffected. Fliqlo is closed-source; users report version 1.9.4 helped, but I found no public implementation or authoritative release note.

## 5. `legacyScreenSaver.appex` internals: what is and is not known

**Verified public structure:** The appex is at `/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex`; third-party bundle code executes inside it. A reverse-engineering article documents its identifier, sandbox, and `disable-library-validation` entitlement ([theevilbit](https://theevilbit.github.io/beyond/beyond_0016/)). ScreenSaverMinimal explains that this compatibility host has been used since Catalina ([README](https://github.com/AerialScreensaver/ScreenSaverMinimal/blob/0bd0cd2d0f03078918946b54f74ca7df81be8545/README.md#L133-L141)).

**Verified by direct inspection on the local Tahoe system:** strings in the private host binary include `LegacyViewController`, `LegacyExtensionManager`, `-[LegacyViewController startAnimation]`, `stopAnimation`, `setLegacyModuleView:`, and `-[LegacyExtensionManager processExtensionRequest:replyInfo:]`. This confirms class/method existence only. No indexed public source or documentation for these classes was found.

**Not verified publicly:** `SSENeedsAnimationTimer` produced no relevant source/documentation hit. No source found proves the exact responder/window/timer retain graph, whether one object is intentionally reused between picker and real sessions, or what the host does internally on `orderOut`.

**Inference supported by behavior:** Apple's base class uses a periodic animation timer, the host omits `stopAnimation`, XScreenSaver observed callbacks to stopped old objects, and direct measurements show timer retention. Together this makes “timer continues after the window is hidden/ordered out” highly credible, but the private host implementation remains undocumented.

## 6. Candidate end-of-session signals

| Signal | Evidence and verdict |
|---|---|
| `com.apple.screensaver.willstop` | **Best available session signal**, used by many projects. Private/undocumented and demonstrably omitted during rapid Sonoma cycling; distinguish non-preview before process exit. |
| Explicit `stopAnimation()` | Necessary, idempotent local teardown entry point. Do not wait for the host to call it. XScreenSaver calls it itself before termination. |
| `window.isVisible` / active-space | Apple defines [`isVisible`](https://developer.apple.com/documentation/appkit/nswindow/isvisible) as on-screen even if obscured. XScreenSaver's invisible stale window still returned true; not sufficient. |
| Window level polling | Developer Forums 738547 found this the closest changing property. Useful as a heuristic for the full-screen path, but not universal (the picker may leave a visible level-0 window). |
| `NSWindow.didChangeOcclusionStateNotification` | Apple intends it to pause expensive invisible work ([docs](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification)), but the Sonoma reporter did not receive it at dismissal. Not sufficient. |
| KVO of `isVisible` | No lifecycle guarantee found; even perfect KVO cannot fix XScreenSaver's false-true visibility case. Polling/observing can be secondary only. |
| `viewWillMove(toWindow:)` / `viewDidMoveToWindow` | [`viewWillMove`](https://developer.apple.com/documentation/appkit/nsview/1483415-viewwillmove) concerns hierarchy attachment. [`orderOut`](https://developer.apple.com/documentation/appkit/nswindow/orderout(_:)) hides the window without detaching its views, so no callback should be expected; direct measurements agree. |
| `NSWindowWillCloseNotification` | Only says a window is about to **close** ([docs](https://developer.apple.com/documentation/appkit/nswindow/willclosenotification)); host ordering-out is not close. |
| NSApplication hide/active notifications | Kotlin author tested `NSApplicationDidHideNotification` and related properties without finding dismissal. The appex process remains active. |
| `com.apple.screenIsUnlocked` | Aerial found the OS emitted it but the saver did not receive it on Sonoma. Not dependable in this sandbox. |
| `NSWorkspace.willSleepNotification` | Useful additional boundary; Aerial uses it. It covers sleep, not ordinary mouse/key dismissal. |
| `CGSessionCopyCurrentDictionary` lock state | Useful Tahoe preview-vs-real heuristic in ScreenSaverMinimal; not a documented session-end notification and may depend on lock policy. |
| CADisplayLink / occlusion throttling | No evidence that display-link cessation is guaranteed on dismissal. ScreenSaverView's own timer can keep firing, and WKWebView was considered hidden while visibly running ([WebView issue #75](https://github.com/liquidx/webviewscreensaver/issues/75)), showing presentation state can be inverted. |
| Watch System Settings process | ScreenSaverMinimal polls `NSWorkspace.runningApplications` from `animateOneFrame` to exit orphaned picker preview after System Settings closes. Narrow picker fallback, not a real-session signal. |

## 7. What this suggests we should do

### Directly supported actions

1. Make teardown **explicit, idempotent, and safe from every state**. On the first stop request: invalidate our timers/display links, pause audio/video, release the render graph and large caches, and make future `animateOneFrame`/draw calls no-ops. Never rely on `deinit`.
2. Observe `com.apple.screensaver.willstop` for non-preview sessions. In the handler, teardown **synchronously first**, then terminate the host on Sonoma+ as a bounded-lifetime backstop. Prefer the Aerial/Tahoe delayed-exit behavior over immediate exit, but treat two seconds as empirical and cancel/guard stale delayed work on rapid re-entry.
3. Guard duplicate/malformed lifecycle calls (`startAnimation` twice; `stopAnimation` before start) and make old instances “lame ducks.” A process-global generation token can ensure only the newest legitimate view owns heavyweight resources; every old instance must render no-op even if the host revives it.
4. Add secondary, cheap checks: full-screen window `isVisible`/level transition, `NSWorkspace.willSleepNotification`, and picker-specific System Settings disappearance. Any positive end signal should trigger local teardown; none should be trusted alone to decide process exit.
5. Keep periodic self-checks lightweight and independent of the render graph. The watchdog itself may be retained forever, so after teardown it must consume negligible CPU and hold no heavy objects.
6. Instrument instance ID, process ID, `startAnimation`, `stopAnimation`, `willstop`, window visibility/level/occlusion, screen-lock state, and resource-allocation generation. This is necessary to distinguish a missed notification, revived instance, malformed picker instance, and host relaunch.

### Inferences / cautions

- A forced process exit is ugly but has the broadest real-world validation. Because multiple saver views may share one host, only a verified real-session handler should exit; preview/Companion/test harness modes must not.
- Window state can improve cleanup latency on the measured full-screen path but cannot be the correctness boundary: XScreenSaver saw invisible windows still claim visibility, while Tahoe's picker can leave a window visibly present at level 0.
- The safest architecture is therefore **two layers**: eagerly shed all heavyweight resources on any credible local signal, and bound the broken host's lifetime through delayed termination when `willstop` arrives.

## Source-quality notes

- GitHub/jwz/source links above are primary. Apple Community and user issue reports are corroboration only.
- Tahoe evidence is strongest for 2025 beta/RC-era builds plus local measurement; absence of a later fix commit is not proof that every 26.x build is identical.
- No public source establishes the exact private retain chain; that part should remain attributed to direct memory-graph measurement, not to the web sources.
