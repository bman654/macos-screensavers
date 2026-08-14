// The base class every saver in this repo subclasses.
//
// It owns the parts that are the same for all of them and wrong in non-obvious ways if
// hand-rolled: a `CAMetalLayer` whose drawable size actually tracks the view, a display
// link that survives event tracking, and the macOS 26 `legacyScreenSaver` hazards
// documented in `Shared/SaverKit/README.md`.
//
// A subclass overrides exactly one method, `makeHost(_:)`, and returns a `RenderHost`.

import AppKit
import Metal
import QuartzCore
import ScreenSaver

class SaverView: ScreenSaverView {

    // MARK: Subclass interface

    /// Build the object that draws. Called once, on the first layout with a usable size —
    /// deliberately not from `init`, because on Tahoe the view's bounds are routinely zero
    /// there and any GPU resource sized from them would be built wrong.
    ///
    /// Returning `nil` leaves the saver on a black background rather than crashing. A
    /// crashed screensaver is an unrecoverable black screen for the user, so every failure
    /// path here degrades instead of trapping.
    func makeHost(_ context: HostContext) -> RenderHost? {
        nil
    }

    /// Frame rate cap, or 0 for the display's native rate.
    ///
    /// Advisory only. `preferredFrameRateRange` quantizes to integer divisors of the
    /// refresh rate — asking for 30 on a 100 Hz display measurably yields 33.4 fps — so
    /// treat this as a budget hint, never as a timebase. Frame timing comes from
    /// `FrameContext.time`.
    var preferredFPS: Int { 0 }

    /// A view narrower than this is treated as the System Settings thumbnail.
    ///
    /// Size is the signal, not `ScreenSaverView.isPreview`, which is unreliable on Tahoe.
    /// The smallest real display this could run on is far wider than any preview.
    var previewWidthThreshold: CGFloat { 600 }

    // MARK: Settings

    /// The bundle this saver was loaded from.
    ///
    /// Never `Bundle.main` — inside `legacyScreenSaver` that is the host appex, so anything
    /// resolved through it silently belongs to the host rather than to this saver.
    var saverBundle: Bundle { Bundle(for: type(of: self)) }

    /// Where a saver's settings persist, keyed by *this bundle's* identifier.
    ///
    /// `ScreenSaverDefaults(forModuleWithName:)` names a per-module defaults domain, and the
    /// module is the saver. Handing it `Bundle.main.bundleIdentifier` writes into the host
    /// appex's own domain instead — shared with every other saver on the machine, and read
    /// back by none of them, so the setting appears to save and then does not take.
    var saverDefaults: ScreenSaverDefaults? {
        guard let identifier = saverBundle.bundleIdentifier else { return nil }
        return ScreenSaverDefaults(forModuleWithName: identifier)
    }

    // MARK: Stored state

    /// Nil only if Metal itself is unavailable, in which case the saver stays black.
    private let metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?

    private(set) var host: RenderHost?
    private var hostFailed = false

    private var depthTexture: MTLTexture?
    private var msaaTexture: MTLTexture?
    private var resolvedSampleCount = 1

    /// Not named `displayLink` — that would shadow `NSView.displayLink(target:selector:)`,
    /// which is the method used to create it.
    private var frameLink: CADisplayLink?
    private var startTimestamp: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0

    /// True between `startAnimation()` and `stopAnimation()`, which is not the same as "frames
    /// are being delivered": a view that is not in a window still wants to animate, and is
    /// suspended until one arrives.
    private var wantsFrames = false

    /// True when animation was stopped only because the view left its window, so moving back
    /// into one resumes it. Distinguishing that from a host's own `stopAnimation()` is what
    /// keeps a reparented view running.
    private var isSuspended = false

    /// Time accumulated over previous start/stop cycles, so `FrameContext.time` never goes
    /// backwards. `SCNRenderer.render(atTime:)` takes an absolute clock: handing it a value
    /// lower than the last one re-simulates or resets particle systems, and every phase in a
    /// scene driven by that clock snaps back to where it started.
    private var timeOffset: CFTimeInterval = 0

    /// Nil unless `SAVERKIT_STATS` is set; see `FrameStats`.
    private let stats = FrameStats.makeIfEnabled()

    private var isPreviewSized: Bool { bounds.width < previewWidthThreshold }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    /// `SAVERKIT_LIFECYCLE=1` logs every saver view created and destroyed, with its address.
    ///
    /// The one question about a saver that neither a screenshot nor a frame-rate number can
    /// answer: whether the views a host builds and discards are actually being freed. Counting
    /// the two lines is the whole test — a host that creates ten views and destroys nine is
    /// leaking a whole render graph per cycle, which is invisible until the process runs out of
    /// memory hours later and something unrelated fails to allocate.
    private static let logsLifecycle =
        ProcessInfo.processInfo.environment["SAVERKIT_LIFECYCLE"] != nil

    private func logLifecycle(_ event: String) {
        guard SaverView.logsLifecycle else { return }
        NSLog("SaverKit lifecycle: \(event) \(type(of: self)) "
              + "\(Unmanaged.passUnretained(self).toOpaque())")
    }

    // MARK: Init

    override init?(frame: NSRect, isPreview: Bool) {
        // Assigned before `super.init` so that `makeBackingLayer()` — which AppKit calls
        // synchronously from `wantsLayer = true` below — can see it.
        self.metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, isPreview: isPreview)

        // The inherited timer still exists and `legacyScreenSaver` expects it
        // (`SSENeedsAnimationTimer` in its Info.plist), but the display link does the real
        // work. Keep the timer cheap; `animateOneFrame` is intentionally a no-op.
        animationTimeInterval = 1.0

        guard metalDevice != nil else { return }
        logLifecycle("created")
        commandQueue = metalDevice?.makeCommandQueue()
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SaverView is instantiated by ScreenSaverView, never from a nib")
    }

    deinit {
        logLifecycle("destroyed")
        frameLink?.invalidate()
        host?.teardown()
    }

    /// Configure the layer here and only here. AppKit calls this synchronously from
    /// `wantsLayer = true`, so any property assigned to the layer from outside afterwards
    /// is silently too late.
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = metalDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.allowsNextDrawableTimeout = true
        return layer
    }

    // MARK: Sizing
    //
    // A CAMetalLayer does not track its own bounds — nothing below updates `drawableSize`
    // except `updateDrawableSize()`. Doing it synchronously from the resize callbacks,
    // rather than from the display-link callback, is what avoids a stretched frame on
    // every resize.

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A layer returned from `makeBackingLayer()` does not inherit the window's scale;
        // it starts at 1.0 regardless of the display.
        metalLayer?.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 1
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        if window == nil {
            suspendFrames()
        } else {
            if isSuspended {
                isSuspended = false
                super.startAnimation()
            }
            // Not conditional on having been suspended: a host may call `startAnimation()`
            // before putting the view in a window, and this is then the first moment the link
            // can legally be created.
            startFrameLink()
        }
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = metalLayer.contentsScale
        let pixels = CGSize(width: (bounds.width * scale).rounded(),
                            height: (bounds.height * scale).rounded())

        // Zero bounds are normal at init on Tahoe. Leave the previous drawable size alone
        // and wait for a real layout.
        guard pixels.width > 0, pixels.height > 0 else { return }
        guard pixels != metalLayer.drawableSize || depthTexture == nil else { return }

        metalLayer.drawableSize = pixels
        ensureHost()
        rebuildAttachments()
    }

    // MARK: Host lifecycle

    private func ensureHost() {
        guard host == nil, !hostFailed,
              let metalDevice, let metalLayer,
              metalLayer.drawableSize.width > 0 else { return }

        let context = HostContext(device: metalDevice,
                                  bundle: saverBundle,
                                  isPreview: isPreviewSized,
                                  drawableSize: metalLayer.drawableSize)

        guard let created = makeHost(context) else {
            // Latched so a failing host is not retried on every resize.
            hostFailed = true
            return
        }
        host = created
        metalLayer.pixelFormat = created.colorPixelFormat
    }

    /// Throws away the current host and builds a fresh one from `makeHost(_:)`.
    ///
    /// What a settings sheet needs: a saver's settings are read when its host is built, so a
    /// running view — the System Settings thumbnail, in practice — otherwise keeps whatever it
    /// launched with and the sheet's OK button looks like it did nothing.
    ///
    /// Safe only because it is main-thread work between frames: `render` is driven by the
    /// display link on the main thread and bails on a nil host, and any GPU work the old host
    /// already submitted is retained by its own command buffer.
    func reloadHost() {
        host?.teardown()
        host = nil
        hostFailed = false
        // Dropped rather than left in place: `rebuildAttachments` reallocates them for the new
        // host anyway, but it returns early if the new host fails to build, and these are
        // hundreds of megabytes at 5K that a view which has stopped drawing has no use for.
        depthTexture = nil
        msaaTexture = nil
        ensureHost()
        rebuildAttachments()
    }

    private func rebuildAttachments() {
        guard let host, let metalDevice, let metalLayer else { return }
        let size = metalLayer.drawableSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return }

        // Requesting an unsupported sample count is a hard assertion inside Metal, so
        // clamp rather than trust. 8x is unsupported on M1 Max.
        var samples = max(1, host.sampleCount)
        while samples > 1 && !metalDevice.supportsTextureSampleCount(samples) {
            samples /= 2
        }

        // Allocate into locals and publish only once every required texture exists.
        //
        // A partial set is worse than none: if the depth texture allocated multisampled but
        // the colour texture did not, a nil `msaaTexture` reads as "single sample" and the
        // pass would pair a single-sample drawable with a multisampled depth attachment,
        // which is an invalid render pass rather than a dropped frame. At 5K with 4x MSAA
        // these attachments are hundreds of megabytes per view, and every display gets its
        // own set, so allocation failure is a real possibility rather than a theoretical one.
        // Falling back to a single sample keeps the saver drawing; giving up keeps it black,
        // which is still better than a validation failure.
        while true {
            let depth = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: host.depthPixelFormat, width: width, height: height, mipmapped: false)
            depth.usage = .renderTarget
            depth.storageMode = .private
            if samples > 1 {
                depth.textureType = .type2DMultisample
                depth.sampleCount = samples
            }

            var newColor: MTLTexture?
            if samples > 1 {
                let color = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: host.colorPixelFormat, width: width, height: height,
                    mipmapped: false)
                color.usage = .renderTarget
                color.storageMode = .private
                color.textureType = .type2DMultisample
                color.sampleCount = samples
                newColor = metalDevice.makeTexture(descriptor: color)
            }

            let newDepth = metalDevice.makeTexture(descriptor: depth)
            let complete = newDepth != nil && (samples == 1 || newColor != nil)

            if complete {
                depthTexture = newDepth
                msaaTexture = newColor
                resolvedSampleCount = samples
                break
            }
            guard samples > 1 else {
                // Even the single-sample set failed. Publish nothing; `render` bails on a
                // nil depth texture and the saver stays black instead of crashing.
                depthTexture = nil
                msaaTexture = nil
                resolvedSampleCount = 1
                NSLog("SaverView: could not allocate render attachments at %dx%d", width, height)
                return
            }
            samples /= 2
        }

        host.hostDidResize(to: RenderTargets(drawableSize: size,
                                             sampleCount: resolvedSampleCount,
                                             colorPixelFormat: host.colorPixelFormat,
                                             depthPixelFormat: host.depthPixelFormat,
                                             backingScale: metalLayer.contentsScale),
                           device: metalDevice)
    }

    // MARK: Animation

    override func startAnimation() {
        // The header is explicit that overrides must call the inherited implementation.
        super.startAnimation()
        wantsFrames = true
        isSuspended = false
        startFrameLink()
    }

    override func stopAnimation() {
        wantsFrames = false
        isSuspended = false
        stopFrameLink()
        super.stopAnimation()
    }

    /// Stop drawing, and stop the inherited timer with it, because the view has no window.
    ///
    /// This is the difference between a discarded saver view being collected and being
    /// immortal. A `CADisplayLink` retains its target and is itself retained by the run loop it
    /// was added to, and `ScreenSaverView`'s own animation timer does exactly the same — so once
    /// a view is animating, the main run loop holds a strong reference to it that no other
    /// object can release. A host that throws a saver view away without calling
    /// `stopAnimation()` therefore does not free it: the view, its scene, its renderer, its
    /// render attachments and its layer's drawables all survive, and it goes on rendering an
    /// invisible frame sixty times a second for the life of the process. Measured at 2056x1329:
    /// 161 MB retained per discarded view, none of them ever deallocated, growing without bound
    /// across repeated previews until an allocation the host needed — a settings sheet, say —
    /// could no longer be satisfied.
    ///
    /// Leaving a window is the signal available for it, and it is the right one: a view with no
    /// window has nothing to composite into, so there is no frame worth producing.
    private func suspendFrames() {
        guard wantsFrames, !isSuspended else { return }
        isSuspended = true
        stopFrameLink()
        super.stopAnimation()
    }

    private func startFrameLink() {
        // No window means no compositor to draw into — and a link started there is what makes a
        // discarded view immortal. See `suspendFrames`.
        guard metalDevice != nil, frameLink == nil, wantsFrames, window != nil else { return }

        // Rebase on the next callback, continuing from `lastFrameTime` rather than restarting
        // at zero — see `timeOffset`.
        startTimestamp = 0

        let link = displayLink(target: self, selector: #selector(frameLinkFired(_:)))
        if preferredFPS > 0 {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(preferredFPS), maximum: Float(preferredFPS),
                preferred: Float(preferredFPS))
        }
        // `.common`, not `.default`: in `.default` the callback stops during event
        // tracking, which is exactly when a preview is being scrubbed in System Settings.
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    private func stopFrameLink() {
        frameLink?.invalidate()
        frameLink = nil
        // Carry the clock across the pause. A view can be stopped and started repeatedly —
        // System Settings previews do exactly this — while keeping the same host and scene.
        timeOffset = lastFrameTime
    }

    /// Intentionally empty. The inherited timer exists because the host expects it; frames
    /// come from the display link.
    override func animateOneFrame() {}

    @objc private func frameLinkFired(_ link: CADisplayLink) {
        // The safety net for `suspendFrames`. `viewDidMoveToWindow` is what normally catches a
        // discarded view, but it is AppKit's to send and a host that tears its window down
        // around the view need not produce one. The link itself always fires, so checking here
        // means a view can never go on rendering — and go on keeping itself alive — into a
        // window that is gone.
        guard window != nil else {
            suspendFrames()
            return
        }

        // `targetTimestamp` is the vsync this frame is for, so animation driven from it is
        // one frame less latent than one driven from `timestamp`.
        if startTimestamp == 0 { startTimestamp = link.targetTimestamp }
        let time = timeOffset + (link.targetTimestamp - startTimestamp)

        // Clamped so the gap across a stop/start, or a stalled frame, cannot hand a
        // simulation a delta large enough to blow it up.
        let delta = min(max(time - lastFrameTime, 0), 0.1)
        lastFrameTime = time

        // `timestamp`, not `targetTimestamp`: this measures the rate frames are actually
        // delivered at, not the vsync they were aimed at.
        stats?.frameTick(link.timestamp, drawableSize: metalLayer?.drawableSize ?? .zero)

        render(time: time, delta: delta)
    }

    private func render(time: CFTimeInterval, delta: CFTimeInterval) {
        guard let host, let commandQueue, let metalLayer,
              bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let depthTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = metalLayer.nextDrawable()
        else { return }

        let pass = MTLRenderPassDescriptor()
        if let msaaTexture {
            pass.colorAttachments[0].texture = msaaTexture
            pass.colorAttachments[0].resolveTexture = drawable.texture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = host.clearColor

        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare

        host.encode(FrameContext(time: time,
                                 deltaTime: delta,
                                 drawableSize: metalLayer.drawableSize,
                                 commandBuffer: commandBuffer,
                                 passDescriptor: pass))

        stats?.observe(commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Fail-soft

    override func draw(_ rect: NSRect) {
        // Only reached when Metal is unavailable and the view was never layer-backed.
        NSColor.black.setFill()
        rect.fill()
    }
}
