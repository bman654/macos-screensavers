// Whether the screen is actually being saved — which is not something a saver view can work
// out for itself, and that is the finding this file exists because of.
//
// Every geometric signal was tried and every one of them failed against the real host:
//
//   - `isPreview` is false for the picker's thumbnail
//   - so is a 600-point width threshold, and so is a fraction-of-the-screen test, because the
//     picker's view is 2056x1329 on a 2056-point screen — the *whole screen*, scaled down into
//     a tile by something above the saver
//   - `occlusionState` reports `occluded` for the real full-screen preview as well, so it does
//     not separate them either
//   - and the view is never told when it stops being seen: it goes on rendering at 60 fps,
//     `window=shown`, `animating=true`, for as long as the host process lives — measured at
//     2.26 million audio frames still climbing, long after System Settings had been closed
//
// So there is no property of the view that distinguishes "the screensaver the user is looking
// at" from "a view the host forgot about". The question has to be asked of the system instead.
// `com.apple.screensaver.*` is a distributed notification, which means it is also the only
// signal that crosses process boundaries — and there is more than one host process alive
// during a single pass through System Settings, so a `static` arbiter inside one of them was
// never going to be enough on its own.

import AppKit
import CoreGraphics
import Foundation

final class AudioProbeSession {

    static let shared = AudioProbeSession()

    /// Posted locally whenever `isScreenSaverRunning` changes, so every view in the process
    /// re-decides at once.
    static let didChange = Notification.Name("AudioProbeSessionDidChange")

    /// True between the screensaver starting and stopping.
    ///
    /// Starts false, and that is the deliberate failure mode: if these notifications never
    /// arrive inside the sandbox, the probe is silent everywhere and the log says why. Silence
    /// plus evidence is a good outcome for a spike; a saver that hums at an empty room for an
    /// hour is not.
    private(set) var isScreenSaverRunning = false

    /// True once a `com.apple.screensaver.*` notification has been heard, after which the
    /// heuristic seed is never consulted again — an edge that actually arrived beats any guess.
    private var hasAuthoritativeState = false

    /// Re-runs the startup heuristic until a real notification supersedes it.
    ///
    /// The seed cannot be taken once, at t=0: the host is spawned *before* System Settings has
    /// registered as a running process, so a probe that decided immediately concluded "no
    /// settings pane, therefore a real screensaver" and played into the picker. Measured. The
    /// state is only knowable a moment later, so it is asked again a moment later — which costs
    /// nothing that matters, because ambience should fade in over seconds rather than appear.
    func reevaluateIfUnconfirmed() {
        guard !hasAuthoritativeState else { return }
        let running = !AudioProbeSession.isProcessRunning(named: "System Settings")
        guard running != isScreenSaverRunning else { return }
        update(to: running, because: "heuristic recheck")
    }

    /// The engine's presence *is* the state, and it is readable at any moment.
    ///
    /// Measured, with the probe logging both cases:
    ///
    ///   screensaver running  [wallpaper.agent, ScreenSaver.Engine, ...legacyScreenSaver]
    ///   picker open          [wallpaper.agent,                     ...legacyScreenSaver]
    ///
    /// Two other candidates were measured at the same time and both would have been believed:
    /// `CGSSessionScreenIsLocked` reads 1 and `frontmostApplication` reads `com.apple.loginwindow`
    /// in *both* cases, because the lock state a screensaver leaves behind outlives it and this
    /// process sees a stale copy. Neither separates them.
    private static let engineIdentifier = "com.apple.ScreenSaver.Engine"

    private static func isEngineRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == engineIdentifier
        }
    }

    /// The same question asked of the kernel instead of of AppKit.
    ///
    /// `NSWorkspace.runningApplications` appears to be a snapshot in this host rather than a
    /// live query — it returned an identical list for ten seconds across a screensaver session
    /// that provably started, and `didLaunchApplicationNotification` never fired. A process list
    /// from `sysctl` cannot be stale: it is read from the kernel at the moment it is asked.
    static func isEngineProcessRunning() -> Bool { isProcessRunning(named: "ScreenSaverEngine") }

    static func isProcessRunning(named wanted: String) -> Bool {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // Read before the inout call: `u_int(name.count)` inside the argument list is a second
        // access to `name` while `&name` is exclusive, which Swift 6 rejects.
        let levels = u_int(name.count)
        var size = 0
        guard sysctl(&name, levels, nil, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, levels, &processes, &size, nil, 0) == 0 else {
            return false
        }
        let found = size / MemoryLayout<kinfo_proc>.stride
        for index in 0..<min(found, processes.count) {
            var command = processes[index].kp_proc.p_comm
            let capacity = MemoryLayout.size(ofValue: command)
            let executable = withUnsafePointer(to: &command) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if executable == wanted { return true }
        }
        return false
    }

    /// Is anything on screen sitting at or above the shielding level?
    ///
    /// The candidate of last resort, and the only one left that describes the *screen* rather
    /// than this process. A screensaver that has taken the display has to be covering everything
    /// somehow, and whatever does that covering is a window in the on-screen list even when it
    /// belongs to another process. Window *names* need Screen Recording permission; layers and
    /// bounds do not.
    static func shieldWindowSummary() -> String {
        let shield = CGShieldingWindowLevel()
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else {
            return "windowList=unavailable"
        }
        let layers = windows.compactMap { $0[kCGWindowLayer as String] as? Int }
        let atOrAboveShield = layers.filter { $0 >= Int(shield) }.count
        return "windows=\(windows.count) maxLayer=\(layers.max() ?? 0) "
            + "atShield=\(atOrAboveShield)"
    }

    /// The name of a process, from the kernel. Used for our parent, which is the last cheap
    /// thing that might differ between a host spawned to save the screen and one spawned to
    /// draw a tile in a settings pane.
    static func processName(of pid: pid_t) -> String {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let levels = u_int(name.count)
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, levels, &process, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var command = process.kp_proc.p_comm
        let capacity = MemoryLayout.size(ofValue: command)
        return withUnsafePointer(to: &command) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    private init() {
        // The startup seed, and it is frankly a heuristic — the honest kind, which errs toward
        // silence.
        //
        // `didstart` is posted before this process exists, so the edge that would tell us we are
        // saving the screen is unreachable on the first activation in a fresh host: measured
        // repeatedly, only `willstop` and `didstop` ever arrive, so the probe stays quiet through
        // the session it should have played and learns the truth as the screen comes back. An
        // edge nobody can be present for is not a signal.
        //
        // Everything that would answer it as *state* was measured and none of it separates a
        // real screensaver from an open picker on this OS — view size, `isPreview`, occlusion,
        // window level, `CGSSessionScreenIsLocked`, the frontmost application, a shield-level
        // window in `CGWindowListCopyWindowInfo`, and the presence of `ScreenSaverEngine`, which
        // on Tahoe is a launcher that has already exited by the time anything is drawn. The full
        // table is in the spike's README.
        //
        // What does differ is why this host was spawned, and the only readable proxy for that is
        // whether the Screen Saver settings pane is open. Wrong in one direction only: if a user
        // leaves System Settings open and walks away, the screensaver that starts is silent. That
        // is the direction to be wrong in, and `didstart` still corrects it for every activation
        // after the first, because by then this process exists to hear it.
        isScreenSaverRunning = !AudioProbeSession.isProcessRunning(named: "System Settings")

        // Launch and termination give the same fact as edges, so the state above never has to be
        // polled. Belt and braces with the distributed notifications rather than a replacement:
        // those are earlier and say what they mean, this one cannot be missed.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(engineMayHaveChanged(_:)),
                                  name: name, object: nil)
        }

        let center = DistributedNotificationCenter.default()
        // `.deliverImmediately`, and it is load-bearing rather than a nicety.
        //
        // The default suspension behaviour is `.coalesce`, which holds notifications back while
        // the receiving application is not active — and a screensaver host is never active in
        // that sense. Measured: on the *first* activation in a fresh host the screensaver
        // started, the view came up, and `didstart` never arrived, so the probe sat there
        // reading "screensaver not running" for the whole session. The second and third
        // activations worked, because by then the observer had been installed long enough for
        // the queue to drain — which is exactly the shape of bug that looks intermittent and is
        // not: it fails on the one path every real user takes, and works on every path a person
        // testing it takes second.
        for name in AudioProbeSession.watched {
            center.addObserver(self, selector: #selector(received(_:)),
                               name: Notification.Name(name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
        // A catch-all as well, filtered when it is logged. Which notifications this host
        // actually receives is itself one of the unknowns — naming them in advance assumes an
        // answer, and the last three rounds were all lost to assuming an answer.
        center.addObserver(self, selector: #selector(received(_:)), name: nil, object: nil,
                           suspensionBehavior: .deliverImmediately)
        AudioProbeLog.write("session observer installed (deliverImmediately), "
                            + "seeded running=\(isScreenSaverRunning)")
    }

    /// Candidate answers to "is the screen being saved *right now*", logged rather than used.
    ///
    /// A notification is an edge, and the edge that matters is unreachable: the engine posts
    /// `didstart` and *then* spawns the host and loads this bundle, so on the first activation
    /// in a fresh process the observer is installed at t=0.00 having already missed it. Only
    /// `willstop`/`didstop` arrive, which is exactly the wrong half — the probe stays silent
    /// through the session it should have played, and learns the truth as the screen comes back.
    ///
    /// So the state has to be readable at startup. None of these is known to work yet; they are
    /// here to be measured against a real activation and a real picker, because guessing which
    /// one works is what cost the previous rounds.
    static func stateSnapshot() -> String {
        var parts: [String] = []

        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let sessionKeys = ["CGSSessionScreenIsLocked", "kCGSSessionOnConsoleKey",
                           "CGSSessionScreenLockedTime"]
        for key in sessionKeys where session[key] != nil {
            parts.append("\(key)=\(session[key]!)")
        }
        if session.isEmpty { parts.append("session=unavailable") }

        let savers = NSWorkspace.shared.runningApplications.compactMap { application -> String? in
            guard let identifier = application.bundleIdentifier,
                  identifier.lowercased().contains("screensaver")
                    || identifier.lowercased().contains("wallpaper") else { return nil }
            return identifier
        }
        parts.append("runningSavers=[\(savers.joined(separator: ","))]")
        parts.append("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        parts.append("displayAsleep=\(CGDisplayIsAsleep(CGMainDisplayID()) != 0)")
        parts.append("workspaceApps=\(NSWorkspace.shared.runningApplications.count)")
        parts.append("engineProcess=\(isEngineProcessRunning())")
        parts.append(shieldWindowSummary())
        parts.append("parent=\(processName(of: getppid()))(\(getppid()))")
        parts.append("settingsOpen=\(isProcessRunning(named: "System Settings"))")

        return parts.joined(separator: " ")
    }

    private static let watched = [
        "com.apple.screensaver.didstart",
        "com.apple.screensaver.didstop",
        "com.apple.screensaver.willstart",
        "com.apple.screensaver.willstop",
        "com.apple.screenIsLocked",
        "com.apple.screenIsUnlocked",
    ]

    /// Logged if it might plausibly bear on this question. The catch-all sees a great deal of
    /// unrelated system traffic and none of it is worth the disk.
    private static func isInteresting(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["screensaver", "screenislocked", "screenisunlocked", "screenlock",
                "displayisasleep", "displaydidwake", "sessiondid"]
            .contains { lowered.contains($0) }
    }

    @objc private func engineMayHaveChanged(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        guard application?.bundleIdentifier == AudioProbeSession.engineIdentifier else { return }
        update(to: AudioProbeSession.isEngineRunning(), because: "engine "
               + (notification.name == NSWorkspace.didLaunchApplicationNotification
                  ? "launched" : "terminated"))
    }

    private func update(to running: Bool, because reason: String) {
        let was = isScreenSaverRunning
        isScreenSaverRunning = running
        AudioProbeLog.write("\(reason) -> running=\(running)")
        guard was != running else { return }
        NotificationCenter.default.post(name: AudioProbeSession.didChange, object: nil)
    }

    @objc private func received(_ notification: Notification) {
        let name = notification.name.rawValue
        guard AudioProbeSession.isInteresting(name) else { return }

        switch name {
        case "com.apple.screensaver.didstart", "com.apple.screensaver.willstart",
             "com.apple.screensaver.didstop", "com.apple.screensaver.willstop":
            hasAuthoritativeState = true
        default:
            break
        }

        switch name {
        case "com.apple.screensaver.didstart", "com.apple.screensaver.willstart":
            update(to: true, because: "notification \(name)")
        case "com.apple.screensaver.didstop", "com.apple.screensaver.willstop":
            // `willstop` deliberately silences before the screen comes back rather than at the
            // same moment, so ambience fades out under a screensaver that is still on screen
            // instead of being cut off by the desktop reappearing.
            update(to: false, because: "notification \(name)")
        default:
            AudioProbeLog.write("notification \(name) (ignored)")
        }
    }
}
