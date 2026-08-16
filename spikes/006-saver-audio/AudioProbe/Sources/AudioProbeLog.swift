// A log file, because the unified log is not reachable here.
//
// `NSLog` from inside `legacyScreenSaver` does reach the unified log, and `log show` then
// refuses to read it: "Could not open local log store: Operation not permitted" without
// elevation or Full Disk Access. That is a permission the person running this test should not
// have to grant to answer a question about a screensaver.
//
// The sandbox will let the host write inside its own container, and the container is under the
// user's home where anything can read it afterwards:
//
//   ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/tmp/
//
// Which matters more than it sounds: the whole question is what a saver view does *after* it
// stops being on screen, and at that point neither its readout nor the person watching can see
// anything at all. A file is the only channel that survives the thing being measured.
//
// **One file per process, opened O_APPEND.** The first version of this wrote one shared file
// with a handle seeked to the end at startup, and it produced a log that was internally
// consistent, plausible, and wrong: it showed four views that never rendered and no engine ever
// starting, for a process that was provably playing audio at the time. Several hosts run at
// once here — the settings pane's and the full-screen preview's are different processes — and
// each held its own file offset, so their writes landed on top of one another and whichever
// finished last decided what the file said. A log that silently loses the evidence is worse
// than no log, because it is believed.

import Darwin
import Foundation

enum AudioProbeLog {

    private static let pid = ProcessInfo.processInfo.processIdentifier

    /// Inside the screensaver this is the sandbox container's `tmp`; under a harness it is the
    /// ordinary one, so the same build logs usefully in both places. Named per process, since
    /// more than one host is alive during a single pass through System Settings.
    static let url: URL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audioprobe-\(pid).log")

    private static let handle: FileHandle? = {
        // `O_APPEND` rather than a seek: every write is positioned by the kernel at the current
        // end of file, so two processes sharing a path cannot overwrite each other. A
        // `FileHandle` opened for writing keeps its own offset and cannot do this.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }()

    private static let started = Date()

    /// Every line is stamped with seconds since this process started rather than a wall clock:
    /// the questions here are all about intervals — how long after a window went away did the
    /// sound stop — and a stopwatch answers those without arithmetic. The pid is on every line
    /// so that logs from several hosts can be merged and still be readable.
    static func write(_ message: String) {
        let stamp = String(format: "%7.2f", Date().timeIntervalSince(started))
        NSLog(message)
        handle?.write(Data("\(stamp)  pid \(pid)  \(message)\n".utf8))
    }
}
