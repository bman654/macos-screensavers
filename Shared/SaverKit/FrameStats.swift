// Frame timing for a running saver, off unless `SAVERKIT_STATS` is set.
//
// It exists because the two things this repo cannot answer by looking at a screenshot are
// "does it hold the display's refresh rate" and "does it still, an hour later". Both are
// properties of the render loop, which lives in `SaverView`, so there is nowhere else for
// the measurement to go.
//
//     SAVERKIT_STATS=5 tools/run-saver.swift Aquarium --size 2056x1329 --seconds 30 \
//         --screenshot /tmp/shot.png          # reports every 5 seconds, to stderr
//
// GPU milliseconds is the number to trust. The interval between display-link callbacks
// depends on whether the window is visible — macOS throttles an occluded one — and the
// harness deliberately parks its window behind everything during a capture, so a low
// observed rate there means nothing on its own. Time actually spent on the GPU does not
// care who is in front.

import Foundation
import Metal
import QuartzCore

final class FrameStats {

    /// Nil unless `SAVERKIT_STATS` is set. Its value is the reporting interval in seconds;
    /// anything unparseable means the default.
    static func makeIfEnabled() -> FrameStats? {
        guard let raw = ProcessInfo.processInfo.environment["SAVERKIT_STATS"] else { return nil }
        let interval = Double(raw).flatMap { $0 > 0 ? $0 : nil } ?? 5.0
        return FrameStats(reportInterval: interval)
    }

    private let reportInterval: CFTimeInterval

    /// Guards everything below it: GPU completion handlers arrive on a Metal-owned thread,
    /// while the frame ticks arrive on the main thread from the display link.
    private let lock = NSLock()

    private var frameTimestamps: [CFTimeInterval] = []
    private var gpuMilliseconds: [Double] = []
    private var windowStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var drawableSize: CGSize = .zero
    private var totalFrames = 0

    private init(reportInterval: CFTimeInterval) {
        self.reportInterval = reportInterval
    }

    /// Called once per display-link callback, with that callback's own timestamp.
    func frameTick(_ timestamp: CFTimeInterval, drawableSize: CGSize) {
        var report: String?
        lock.lock()
        if windowStart == 0 { windowStart = timestamp }
        if lastTimestamp > 0 { frameTimestamps.append(timestamp - lastTimestamp) }
        lastTimestamp = timestamp
        self.drawableSize = drawableSize
        totalFrames += 1
        if timestamp - windowStart >= reportInterval {
            report = summary(span: timestamp - windowStart)
            frameTimestamps.removeAll(keepingCapacity: true)
            gpuMilliseconds.removeAll(keepingCapacity: true)
            windowStart = timestamp
        }
        lock.unlock()
        if let report { NSLog("%@", report) }
    }

    /// Records how long this frame occupied the GPU. The handler runs off the main thread.
    func observe(_ commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let elapsed = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            // A buffer that never reached the GPU reports zero for both ends.
            guard elapsed > 0 else { return }
            lock.lock()
            gpuMilliseconds.append(elapsed)
            lock.unlock()
        }
    }

    /// Caller holds the lock.
    private func summary(span: CFTimeInterval) -> String {
        let intervals = frameTimestamps.sorted()
        let gpu = gpuMilliseconds.sorted()
        let fps = span > 0 ? Double(frameTimestamps.count) / span : 0

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let index = Int((Double(values.count - 1) * fraction).rounded())
            return values[index]
        }

        return String(
            format: "SaverKit stats: %.0fx%.0f  %.1f fps over %.1fs (%d frames, %d total)  "
                + "frame ms p50 %.2f p95 %.2f max %.2f  gpu ms mean %.2f p95 %.2f max %.2f (%d samples)",
            drawableSize.width, drawableSize.height, fps, span,
            frameTimestamps.count, totalFrames,
            percentile(intervals, 0.5) * 1000,
            percentile(intervals, 0.95) * 1000,
            (intervals.last ?? 0) * 1000,
            gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count),
            percentile(gpu, 0.95), gpu.last ?? 0, gpu.count)
    }
}
