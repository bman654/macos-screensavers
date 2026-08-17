// Whether the screen is actually being saved — which is the only thing audio may be gated on.
//
// This is the distilled result of `spikes/006-saver-audio`, and it is short because the spike
// is where the argument lives. Read its README before changing anything here; almost every
// obvious alternative was tried against the real host and failed.
//
// **There is no property of a saver view that answers this question.** The picker's thumbnail
// in System Settings is a 2056x1329 view on a 2056-point screen — literally the whole screen —
// with `isPreview == false` and `occlusionState == .occluded`, which is also what the real
// full-screen preview reports. A width threshold, a fraction-of-the-screen test, the window
// level and the occlusion state were all measured, and every one of them passes the thumbnail
// as a full-screen screensaver. Worse, a view is never told when it stops being seen: an
// abandoned one goes on rendering at 60 fps with `window=shown` for as long as the host lives.
//
// So the question is asked of the system. `com.apple.screensaver.didstart` / `willstop` /
// `didstop` are distributed notifications, they reach the sandboxed host, they are true of the
// *session* rather than of a view, and they cross process boundaries — which matters, because a
// single pass through the picker provably spawns two hosts.

import AppKit
import Foundation
import QuartzCore

final class SoundSession {

    static let shared = SoundSession()

    /// True between the screensaver starting and stopping.
    private(set) var isScreenSaverRunning = false

    /// True once a `com.apple.screensaver.*` notification has been heard, after which the
    /// startup guess is never consulted again — an edge that actually arrived beats any guess.
    private var hasAuthoritativeState = false

    private var lastEvaluated: CFTimeInterval = 0
    private static let reevaluationInterval: CFTimeInterval = 0.35

    /// How long the startup guess is allowed to keep audio silent while it settles.
    ///
    /// Free, because ambience should fade in over seconds rather than appear. See
    /// `reevaluateIfUnconfirmed` for why the guess cannot simply be taken once at t=0.
    static let settlingPeriod: CFTimeInterval = 1.5

    private init() {
        // The startup guess, and it is frankly a heuristic — the honest kind, which errs
        // toward silence.
        //
        // `didstart` is posted *before* this process exists: the engine posts it, then spawns
        // `legacyScreenSaver`, which then loads this bundle. So on the first activation in a
        // fresh host the observer is installed having already missed the edge, and only
        // `willstop`/`didstop` ever arrive — the saver would stay silent through exactly the
        // session it was built for and learn the truth as the screen came back. It would work
        // on every activation after that, which is the shape of bug that looks intermittent
        // and is not: it fails on the one path every real user takes and works on every path a
        // person testing it takes second.
        //
        // Everything that would answer it as *state* was measured in both a real session and
        // an open picker, and none of it separates them: `CGSSessionScreenIsLocked` reads 1 in
        // both, `frontmostApplication` is `com.apple.loginwindow` in both, no window ever
        // reaches `CGShieldingWindowLevel()`, and `ScreenSaverEngine` is a launcher that has
        // already exited by the time anything is drawn. What does differ is *why* this host was
        // spawned, and the only readable proxy for that is whether the settings pane is open.
        //
        // Wrong in one direction only: a user who leaves System Settings open and walks away
        // gets a silent screensaver. That is the direction to be wrong in.
        // `AQUARIUM_SOUND_SESSION=1` asserts the answer, for `tools/run-saver.swift` only.
        //
        // Without it this repo's ground-truth loop — record the saver, measure it, listen to it —
        // depends on whether System Settings happens to be open, since the harness is an ordinary
        // process that the startup guess reads exactly as it reads a picker thumbnail. That is a
        // loop whose result is decided by an unrelated window, and the failure is nearly silent:
        // the recording is a valid WAV of nothing. Safe because the environment is empty under
        // `legacyScreenSaver`, so it cannot be reached where it would matter.
        if let forced = ProcessInfo.processInfo.environment["AQUARIUM_SOUND_SESSION"] {
            isScreenSaverRunning = (forced as NSString).boolValue
            hasAuthoritativeState = true
        } else {
            isScreenSaverRunning = SoundSession.settingsPaneIsClosed() ?? false
        }

        let center = DistributedNotificationCenter.default()
        // `.deliverImmediately` is load-bearing rather than a nicety. The default suspension
        // behaviour is `.coalesce`, which withholds notifications while the receiving
        // application is not active — and a screensaver host is never active in that sense.
        for name in SoundSession.watched {
            center.addObserver(self, selector: #selector(received(_:)),
                               name: Notification.Name(name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
    }

    /// Re-runs the startup guess until a real notification supersedes it.
    ///
    /// The guess cannot be taken once, at t=0: the host is spawned *before* System Settings has
    /// registered as a running process, so a probe that decided immediately concluded "no
    /// settings pane, therefore a real screensaver" and played into the picker. Measured. The
    /// state is only knowable a moment later, so it is asked again a moment later.
    func reevaluateIfUnconfirmed() {
        guard !hasAuthoritativeState else { return }
        // Throttled, because the caller is a frame path and this is not a cheap question. Each
        // answer is two `sysctl` calls, the second of which copies the machine's entire process
        // table — measured at 0.22 ms and a 723 KB array for 1116 processes. Asked once a frame
        // for a second and a half that is ninety of them, per instance, at exactly the moment a
        // tank is being built and its shaders compiled. Four times is as good as ninety: what
        // is being waited for is System Settings appearing in the table at all.
        let when = CACurrentMediaTime()
        guard when - lastEvaluated >= SoundSession.reevaluationInterval else { return }
        lastEvaluated = when
        // Nil is "could not tell", and it must not become "yes". Reading the kernel's process
        // list can fail, and the negation of a failed lookup is exactly the wrong answer: it
        // says no settings pane is open, which this guess reads as a real screensaver. The
        // whole claim made for this heuristic is that it errs toward silence.
        guard let running = SoundSession.settingsPaneIsClosed(),
              running != isScreenSaverRunning else { return }
        update(to: running)
    }

    private static let watched = [
        "com.apple.screensaver.didstart",
        "com.apple.screensaver.willstart",
        "com.apple.screensaver.didstop",
        "com.apple.screensaver.willstop",
    ]

    @objc private func received(_ notification: Notification) {
        switch notification.name.rawValue {
        case "com.apple.screensaver.didstart", "com.apple.screensaver.willstart":
            hasAuthoritativeState = true
            update(to: true)
        case "com.apple.screensaver.didstop", "com.apple.screensaver.willstop":
            // `willstop` deliberately silences before the screen comes back rather than at the
            // same moment, so ambience fades out under a screensaver that is still on screen
            // instead of being cut off by the desktop reappearing.
            hasAuthoritativeState = true
            update(to: false)
        default:
            break
        }
    }

    private func update(to running: Bool) {
        isScreenSaverRunning = running
    }

    /// Nil when the question could not be answered, which is not at all the same as "no".
    static func settingsPaneIsClosed() -> Bool? {
        HostSignals.isSystemSettingsRunning().map { !$0 }
    }

    // MARK: Whether *this* view is the one showing it

    /// Is this window the surface the screensaver is actually being drawn into?
    ///
    /// The notification above says whether *a* screensaver is running. It cannot say whether
    /// this view is the one showing it, and both are needed, because a `legacyScreenSaver` host
    /// is long-lived and accumulates views it has finished with — measured: a view from one
    /// activation was still animating at 60 fps ten minutes and one whole session later.
    /// Two failures come out of that, and the window level is the only signal found that
    /// separates them:
    ///
    ///   - **A stale view claims the sound before the real one exists.** On the next `didstart`
    ///     every leftover view in the host becomes eligible at once, and the host does not
    ///     construct the session's actual view until ~0.5 s later — so the leftover wins, and
    ///     "never steal from an eligible owner" then locks the real view out for the whole
    ///     session. Observed with the arpeggio playing over a tank that was silent.
    ///   - **A session can end before the host exists to hear it end.** `willstop`/`didstop` are
    ///     posted before this process is up, exactly as `didstart` is, so dismissing a
    ///     screensaver within the first second leaves the startup guess — which said *running* —
    ///     uncorrected forever. Observed: the sound faded up onto the user's desktop while they
    ///     were working, and only `killall` stopped it.
    ///
    /// Crucially this has to be a property of the *view*, not an arbitration between views: one
    /// host holds several saver **bundles** at once (`lsof` shows Aquarium and the spike's probe
    /// loaded together), and each bundle's owner `static` is its own, so they cannot see each
    /// other at all. Nothing a single bundle arbitrates could have fixed either case.
    ///
    /// The measurement and the levels themselves live with `HostSignals.isPresenting`, which
    /// SaverKit's own frame gate reads for the same reason. Erring tight is the safe direction
    /// here: too tight is a screensaver that says nothing, too loose is one that plays into a
    /// room. Checked every frame, never cached.
    static func isPresenting(_ window: NSWindow?) -> Bool {
        HostSignals.isPresenting(window)
    }
}
