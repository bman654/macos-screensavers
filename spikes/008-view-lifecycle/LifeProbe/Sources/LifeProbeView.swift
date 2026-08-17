// Throwaway probe for spike 008: what a SaverView can observe about itself after the host has
// stopped showing it. Draws a solid colour and logs every lifecycle edge to stderr.

import AppKit
import Metal
import QuartzCore
import ScreenSaver

final class SolidHost: RenderHost {
    var sampleCount: Int { 1 }
    var clearColor: MTLClearColor { MTLClearColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 1) }
    // A deliberately large allocation so a leaked host is visible in the footprint.
    var ballast: UnsafeMutableRawPointer?
    var onFrame: (() -> Void)?
    init(device: MTLDevice) {
        // Random bytes, so the compressor cannot make the ballast vanish from the footprint.
        ballast = malloc(64 << 20)
        arc4random_buf(ballast, 64 << 20)
    }
    deinit { free(ballast); NSLog("LifeProbe: host deinit") }
    func encode(_ frame: FrameContext) {
        let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: frame.passDescriptor)
        encoder?.endEncoding()
        onFrame?()
    }
    func teardown() { NSLog("LifeProbe: host teardown") }
}

@objc(LifeProbeView)
final class LifeProbeView: SaverView {
    private var frames = 0
    private var ticks = 0
    private var lastFrameLog: CFTimeInterval = 0
    private var visibleObservation: NSKeyValueObservation?
    private var occlusionObserver: NSObjectProtocol?

    private var state: String {
        guard let window else { return "window=nil" }
        return "window=\(window.isVisible ? "shown" : "orderedOut") "
            + "occl=\(window.occlusionState.contains(.visible) ? "visible" : "occluded") "
            + "level=\(window.level.rawValue) onScreen=\(window.screen != nil) "
            + "animating=\(isAnimating) frames=\(frames) ticks=\(ticks)"
    }
    private func log(_ m: String) { NSLog("LifeProbe[\(Unmanaged.passUnretained(self).toOpaque())] \(m) | \(state)") }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        log("init")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NSLog("LifeProbe: DEINIT") }

    override func makeHost(_ context: HostContext) -> RenderHost? {
        log("makeHost")
        let host = SolidHost(device: context.device)
        host.onFrame = { [weak self] in
            guard let self else { return }
            self.frames += 1
            let now = CACurrentMediaTime()
            if now - self.lastFrameLog >= 1 { self.lastFrameLog = now; self.log("frame") }
        }
        return host
    }

    override func startAnimation() { super.startAnimation(); log("startAnimation") }
    override func stopAnimation() { super.stopAnimation(); log("stopAnimation") }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        log("viewWillMove(toWindow: \(newWindow == nil ? "nil" : "some"))")
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        log("viewDidMoveToWindow")
        guard ProcessInfo.processInfo.environment["LIFEPROBE_OBSERVE"] != "0" else { return }
        visibleObservation = window?.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            self?.log("KVO window.isVisible -> \(change.newValue ?? false)")
        }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.log("occlusion changed") }
        }
    }
    override func viewDidHide() { super.viewDidHide(); log("viewDidHide") }
    override func viewDidUnhide() { super.viewDidUnhide(); log("viewDidUnhide") }

    /// The inherited 1 Hz timer. Logging here answers whether it keeps firing once the window
    /// has been ordered out.
    override func animateOneFrame() {
        super.animateOneFrame()
        ticks += 1
        log("animateOneFrame tick")
    }
}
