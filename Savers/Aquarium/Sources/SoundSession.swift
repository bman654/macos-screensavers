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
    ///
    /// The state itself lives in `SaverKit.ScreenSaverSession`, which is this gate's session
    /// half lifted out when `SaverView.renderQuality()` needed the same question answered. What
    /// stays here is the *error direction*, which is not shared: audio errs toward silence, so
    /// an unsettled answer is read as "not running" and the tank stays quiet until the system
    /// says otherwise. Render quality errs the other way, toward a full-quality frame. Neither
    /// caller may take the other's default.
    var isScreenSaverRunning: Bool {
        if let forced { return forced }
        let session = ScreenSaverSession.shared
        // Unsettled means the startup guess has not been re-asked yet — see `hasSettled`. A
        // saver that trusted it would play into the picker for a second and a half.
        guard session.hasSettled || session.isAuthoritative else { return false }
        return session.isRunning
    }

    /// `AQUARIUM_SOUND_SESSION=1` asserts the answer, for `tools/run-saver.swift` only.
    ///
    /// Without it this repo's ground-truth loop — record the saver, measure it, listen to it —
    /// depends on whether System Settings happens to be open, since the harness is an ordinary
    /// process that the startup guess reads exactly as it reads a picker thumbnail. That is a
    /// loop whose result is decided by an unrelated window, and the failure is nearly silent:
    /// the recording is a valid WAV of nothing. Safe because the environment is empty under
    /// `legacyScreenSaver`, so it cannot be reached where it would matter.
    ///
    /// Kept here rather than folded into SaverKit's own `SAVERKIT_SESSION` because it means
    /// something narrower: it asserts what the *audio* gate should believe, and a harness run
    /// recording a WAV has no opinion about how many pixels the tank should be drawn at.
    private let forced: Bool? = (ProcessInfo.processInfo.environment["AQUARIUM_SOUND_SESSION"]
                                     as NSString?)?.boolValue

    private init() {}

    /// Re-runs the startup guess until a real notification supersedes it. Throttled by the
    /// shared session; safe to call once a frame.
    func reevaluateIfUnconfirmed() {
        ScreenSaverSession.shared.reevaluateIfUnconfirmed()
    }

    /// How long the startup guess is allowed to keep audio silent while it settles.
    ///
    /// Free, because ambience should fade in over seconds rather than appear.
    static let settlingPeriod: CFTimeInterval = ScreenSaverSession.settlingPeriod

    /// Nil when the question could not be answered, which is not at all the same as "no".
    static func settingsPaneIsClosed() -> Bool? {
        ScreenSaverSession.settingsPaneIsClosed()
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
