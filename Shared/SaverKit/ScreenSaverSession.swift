// Is the screen actually being saved? Asked of the system, because no view can answer it.
//
// This is the session half of the gate `spikes/006-saver-audio` produced, lifted out of the
// Aquarium's `SoundSession` when a second caller needed it. Read that spike's README before
// changing anything here; almost every obvious alternative was tried against the real host and
// failed, and the reasoning is not reconstructible from this file.
//
// **Why a saver needs this beyond the window level.** The level separates a view the host is
// showing from one it has finished with, and that is all it separates. Measured in the real
// picker on Tahoe: the live preview at the top of the Screen Saver sheet runs at level
// -2147483625 — the *presenting* level, the same one a real session uses — because macOS runs
// the saver in a genuine full-screen window behind System Settings and composites the two-inch
// tile out of it. So `isPresenting` is true for a thumbnail, and a saver that trusts it alone
// renders a full-screen frame for two inches of screen.
//
// What differs is not the window but *why this host was spawned*, and these notifications are
// the only readable answer: they are true of the session rather than of a view, they reach the
// sandboxed host, and they cross process boundaries — which matters, because one pass through
// the picker provably spawns two hosts.
//
// **Two callers, opposite error directions.** Audio must err toward silence: a saver that plays
// into a room is worse than one that says nothing. Render quality must err toward full: a soft
// screensaver on a real display is worse than a tile that costs too much. So this exposes the
// state and *does not* decide; each caller reads `isRunning` with `hasSettled` and resolves the
// ambiguity its own way. `SaverView.renderQuality()` and `SoundSession` are the two.

import AppKit
import Foundation
import QuartzCore

final class ScreenSaverSession {

    static let shared = ScreenSaverSession()

    /// True between the screensaver starting and stopping, as best as can currently be told.
    /// Pair it with `hasSettled` before trusting a `false` — until then it is a guess.
    private(set) var isRunning: Bool

    /// True once a `com.apple.screensaver.*` notification has been heard, after which the
    /// startup guess is never consulted again — an edge that actually arrived beats any guess.
    private(set) var isAuthoritative = false

    /// True when `isRunning` is worth acting on in *either* direction.
    ///
    /// Either a notification arrived, or the startup guess has been re-asked at least once
    /// after the process table could actually be read and `settlingPeriod` has passed. Both
    /// halves are needed: the host is spawned *before* System Settings registers as a running
    /// process, so an answer taken at t=0 concludes "no settings pane, therefore a real
    /// screensaver" and is wrong about every picker thumbnail. Measured.
    var hasSettled: Bool {
        if isAuthoritative { return true }
        guard hasReadProcessTable, firstEvaluated > 0 else { return false }
        return CACurrentMediaTime() - firstEvaluated >= ScreenSaverSession.settlingPeriod
    }

    /// How long the startup guess is allowed to be treated as provisional.
    static let settlingPeriod: CFTimeInterval = 1.5

    private var firstEvaluated: CFTimeInterval = 0
    private var lastEvaluated: CFTimeInterval = 0
    private var hasReadProcessTable = false
    private static let reevaluationInterval: CFTimeInterval = 0.35

    private init() {
        // `SAVERKIT_SESSION=0|1` asserts the answer for the harness, which is an ordinary
        // process that the startup guess below reads exactly as it reads a picker thumbnail.
        // Cannot reach the real host, whose environment is empty.
        if let forced = ProcessInfo.processInfo.environment["SAVERKIT_SESSION"] {
            isRunning = (forced as NSString).boolValue
            isAuthoritative = true
        } else {
            // The startup guess, and it is frankly a heuristic — the honest kind.
            //
            // `didstart` is posted *before* this process exists: the engine posts it, then
            // spawns `legacyScreenSaver`, which then loads this bundle. So on the first
            // activation in a fresh host the observer is installed having already missed the
            // edge, and only `willstop`/`didstop` ever arrive. Everything that would answer it
            // as *state* was measured in both a real session and an open picker and separates
            // neither: `CGSSessionScreenIsLocked` reads 1 in both, `frontmostApplication` is
            // `com.apple.loginwindow` in both, and no window reaches `CGShieldingWindowLevel()`.
            // What differs is why the host was spawned, and the only readable proxy is whether
            // the settings pane is open.
            isRunning = ScreenSaverSession.settingsPaneIsClosed() ?? false
        }

        let center = DistributedNotificationCenter.default()
        // `.deliverImmediately` is load-bearing rather than a nicety. The default suspension
        // behaviour is `.coalesce`, which withholds notifications while the receiving
        // application is not active — and a screensaver host is never active in that sense.
        for name in ScreenSaverSession.watched {
            center.addObserver(self, selector: #selector(received(_:)),
                               name: Notification.Name(name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
    }

    /// Re-runs the startup guess until a real notification supersedes it. Safe to call from a
    /// frame path; it throttles itself.
    ///
    /// The guess cannot be taken once, at t=0 — see `hasSettled`. The state is only knowable a
    /// moment later, so it is asked again a moment later.
    func reevaluateIfUnconfirmed() {
        guard !isAuthoritative else { return }
        // Throttled, because the caller is a frame path and this is not a cheap question. Each
        // answer copies the machine's entire process table — measured at 0.22 ms and 723 KB for
        // 1116 processes. Four times is as good as ninety: what is being waited for is System
        // Settings appearing in the table at all.
        let when = CACurrentMediaTime()
        guard when - lastEvaluated >= ScreenSaverSession.reevaluationInterval else { return }
        lastEvaluated = when
        // Nil is "could not tell", and it must not become an answer in either direction: the
        // negation of a failed lookup says no settings pane is open, which reads as a real
        // screensaver. A failed read also leaves `hasReadProcessTable` false, so nothing
        // downstream mistakes silence for settled.
        guard let closed = ScreenSaverSession.settingsPaneIsClosed() else { return }
        hasReadProcessTable = true
        if firstEvaluated == 0 { firstEvaluated = when }
        isRunning = closed
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
            isAuthoritative = true
            isRunning = true
        case "com.apple.screensaver.didstop", "com.apple.screensaver.willstop":
            // `willstop` deliberately lands before the screen comes back rather than at the
            // same moment, so a saver fades out under a screensaver that is still on screen
            // instead of being cut off by the desktop reappearing.
            isAuthoritative = true
            isRunning = false
        default:
            break
        }
    }

    /// Nil when the question could not be answered, which is not at all the same as "no".
    static func settingsPaneIsClosed() -> Bool? {
        HostSignals.isSystemSettingsRunning().map { !$0 }
    }
}
