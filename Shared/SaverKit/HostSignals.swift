// What a saver view can learn about whether anyone can see it, and how well each signal works.
//
// The screensaver host is long-lived and keeps views it has finished with, still animating.
// Nothing tells such a view it has been set aside: `viewDidMoveToWindow`, `stopAnimation`,
// occlusion, `isVisible`, `isOnActiveSpace`, `alpha`, `screen` — every one of them was logged once
// a second from inside the real host across a hot-corner session and its dismissal, and every one
// read the same before and after. The window level is the single field that moved
// (`spikes/008-view-lifecycle/README.md` §6, `docs/saver-host.md` §2). These two functions are
// the two signals that survived that measurement; both are used by SaverView's own frame gate
// and by the aquarium's audio gate.

import AppKit
import Darwin
import QuartzCore

enum HostSignals {
    /// Is this window the surface a screensaver is actually being drawn into?
    ///
    /// Measured levels, and there are only three:
    ///
    /// ```
    /// -2147483625   presenting the screensaver, for the whole session and no longer
    /// -2147483622   the `tools/run-saver.swift` harness window
    ///           0   .normal — a view the host has finished with, one whose session ended
    ///               under it, or the picker's live preview
    /// ```
    ///
    /// The bound is `desktopIcon` rather than `desktop` (-2147483623) because the harness sits
    /// *above* the desktop and below the icons, and the harness must count as presenting or
    /// this repo's ground-truth recording loop goes silent and every harness run goes dark.
    ///
    /// Read it every time it is needed, never cache it. The host changes a view's level out
    /// from under it with no callback of any kind — a view that asked once would answer with
    /// the truth from before it was set aside.
    static func isPresenting(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow))
    }

    /// Is System Settings running? Nil if the kernel could not be asked.
    ///
    /// The only readable proxy for *why* a view exists at a non-presenting level: the picker's
    /// large live preview and a settings sheet's preview both live only while System Settings
    /// does. A view at `.normal` in a host with no System Settings behind it is a leftover that
    /// nobody can see.
    static func isSystemSettingsRunning() -> Bool? {
        isProcessRunning(named: "System Settings")
    }

    private static var settingsRunning = true
    private static var settingsCheckedAt: CFTimeInterval = 0

    /// `isSystemSettingsRunning()`, throttled and shared by every view in the bundle: one
    /// process-table read per interval however many leftovers a host has accumulated. Main
    /// thread only, like everything else on a view's frame path.
    ///
    /// The first call does not read at all: this host is spawned *before* System Settings has
    /// registered in the process table (measured, see `SoundSession.reevaluateIfUnconfirmed`),
    /// so an immediate answer would say "no" of a picker that is in fact opening. Starts as
    /// "running", and a failed lookup keeps the last answer — both err toward drawing.
    static func systemSettingsIsRunning(recheckAfter interval: CFTimeInterval) -> Bool {
        let now = CACurrentMediaTime()
        if settingsCheckedAt == 0 { settingsCheckedAt = now }
        if now - settingsCheckedAt >= interval {
            settingsCheckedAt = now
            if let running = isProcessRunning(named: "System Settings") {
                if running != settingsRunning {
                    NSLog("SaverKit audience: System Settings %@", running ? "open" : "gone")
                }
                settingsRunning = running
            }
        }
        return settingsRunning
    }

    /// Is a process with this executable name alive, according to the kernel? Nil if the
    /// kernel could not be asked.
    ///
    /// `sysctl` rather than `NSWorkspace.runningApplications`, which behaves as a stale
    /// snapshot in this host — it returned an identical list for ten seconds across a
    /// screensaver session that provably started, and `didLaunchApplicationNotification` never
    /// fired. A process list read from the kernel cannot be stale.
    ///
    /// Not free: two `sysctl` calls, the second copying the machine's whole process table —
    /// measured at 0.22 ms and a 723 KB array for 1116 processes. Callers throttle it to
    /// seconds, never frames.
    static func isProcessRunning(named wanted: String) -> Bool? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // Read before the inout call: `u_int(name.count)` inside the argument list is a second
        // access to `name` while `&name` is exclusive, which Swift 6 rejects.
        let levels = u_int(name.count)
        var size = 0
        guard sysctl(&name, levels, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, levels, &processes, &size, nil, 0) == 0 else { return nil }

        let found = size / MemoryLayout<kinfo_proc>.stride
        for index in 0..<min(found, processes.count) {
            var command = processes[index].kp_proc.p_comm
            let capacity = MemoryLayout.size(ofValue: command)
            let executable = withUnsafePointer(to: &command) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if executable == wanted { return true }
        }
        return false
    }
}
