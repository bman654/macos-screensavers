// The lifecycle log: which saver views a host builds and discards, and once a second what
// each can see of its own window. Off unless asked for; SaverView is the only writer.

import Darwin
import Foundation

enum LifecycleLog {
    /// `SAVERKIT_LIFECYCLE=1` logs every saver view created and destroyed, with its address,
    /// and a once-a-second line of window signals per animating view.
    ///
    /// The one question about a saver that neither a screenshot nor a frame-rate number can
    /// answer: what the views a host builds and discards are still holding. In the harness,
    /// counting `created` against `destroyed` is the test. In the real host a discarded view is
    /// retained by the host itself and never destroyed, so the test there is the signals line:
    /// a view nobody can see should read `frames=0 hibernating=true host=false` within seconds
    /// of being set aside, and the process footprint should fall with it.
    ///
    /// Also switched on by an empty file named `saverkit-lifecycle.enable` in the process's
    /// temporary directory. The real host is not spawned from the user's launchd context, so
    /// `launchctl setenv` never reaches it; its container's `tmp` (`~/Library/Containers/
    /// com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/tmp`) is writable from outside and
    /// readable from inside the sandbox, which is what a measurement on the installed build needs.
    ///
    /// Read once, at the first log call — a sentinel touched under a running host takes effect
    /// after `killall legacyScreenSaver`, like everything else about an installed saver.
    static let isEnabled =
        ProcessInfo.processInfo.environment["SAVERKIT_LIFECYCLE"] != nil
        || FileManager.default.fileExists(atPath: temporaryDirectory
            .appendingPathComponent("saverkit-lifecycle.enable").path)

    private static let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())

    /// Where the log also goes, beside `NSLog`: the process's temporary directory, which for the
    /// sandboxed host is inside its container. The unified log needs Full Disk Access to read
    /// back and an agent driving a measurement often has none; a file needs nothing.
    ///
    /// Opened once, append-only. One host holds several saver bundles, each with its own copy
    /// of SaverKit and so its own descriptor on this file; `O_APPEND` keeps their lines whole
    /// where seek-then-write would interleave or overwrite them.
    private static let descriptor: Int32 = {
        let url = temporaryDirectory.appendingPathComponent("saverkit-lifecycle.log")
        NSLog("SaverKit lifecycle log: \(url.path)")
        return open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func emit(_ line: String) {
        NSLog("%@", line)
        guard descriptor >= 0 else { return }
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        stamped.withCString { _ = write(descriptor, $0, strlen($0)) }
    }
}
