// Why the tank is or is not making a sound, written where it can be read.
//
// `AQUARIUM_AUDIO_STATS` answers this under `tools/run-saver.swift` and cannot answer it in the
// place it matters: the environment is empty inside `legacyScreenSaver`, `NSLog` reaches the
// unified log and `log show` then refuses to read it without Full Disk Access, and the saver has
// no readout to print on. So "I heard nothing" has no diagnosis at all on a real machine — which
// is exactly the situation this file was written in, with a build that was provably correct
// under the harness and silent on the installed screensaver.
//
// The sandbox will let the host write inside its own container, and the container is under the
// user's home where anything can read it afterwards. Same channel, and the same reasoning, as
// `spikes/006-saver-audio/AudioProbe/Sources/AudioProbeLog.swift`.
//
// **Off unless a sentinel file exists**, so a shipped saver does no file I/O at all — the check
// is one `access(2)` at startup and a `Bool` thereafter:
//
//   touch ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/tmp/aquarium-audio-debug
//   killall legacyScreenSaver
//
// One file per process, opened `O_APPEND`. Several hosts are alive at once here and each would
// hold its own file offset, so a shared handle loses whichever writes finish first — a log that
// silently drops evidence is worse than no log, because it is believed.

import Darwin
import Foundation

enum SoundLog {

    private static let pid = ProcessInfo.processInfo.processIdentifier

    private static let directory = URL(fileURLWithPath: NSTemporaryDirectory())

    /// The sentinel, and the log's whole cost when it is absent.
    static let isEnabled: Bool =
        FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("aquarium-audio-debug").path)

    private static let handle: FileHandle? = {
        guard isEnabled else { return nil }
        let url = directory.appendingPathComponent("aquarium-sound-\(pid).log")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// A wall clock rather than a stopwatch: the events that decide this are system-wide, and
    /// lining several hosts' logs up against one of them is the entire point.
    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled, let handle else { return }
        let line = "\(clock.string(from: Date()))  pid \(pid)  \(message())\n"
        handle.write(Data(line.utf8))
    }
}
