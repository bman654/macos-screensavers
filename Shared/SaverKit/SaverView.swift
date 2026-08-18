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

    /// Why a view let its host go. A saver may want to treat the two differently: a reload is
    /// a request for something new, an idle release is a pause it should try to resume from.
    enum HostReleaseReason {
        /// `reloadHost()` — settings changed, build the host afresh.
        case reload
        /// No frame was committed for `idleReleaseDelay`; the graph will be rebuilt on the next.
        case idle
        /// The audience changed what this view is worth drawing at, and the host was built for
        /// the other answer. Same view, same moment, a different budget — see `RenderQuality`.
        case quality
    }

    /// Called after the view has released its `RenderHost`, for either reason above. Drop
    /// anything the saver built alongside the host and kept a reference to; `makeHost(_:)` will
    /// be asked for a new one when the view is next drawn.
    ///
    /// Exists because a saver commonly retains what drives its scene separately from the host
    /// (the Aquarium keeps its `AquariumScene`), and SaverView cannot free what it never held.
    /// A saver that keeps nothing outside its host has nothing to do here.
    func didReleaseHost(_ reason: HostReleaseReason) {}

    /// Seconds without a committed frame before a view that still wants frames releases its
    /// render graph.
    ///
    /// The host keeps views it has finished with for the life of the process and never tells
    /// them so: it orders their window out, which stops the display link dead with no callback
    /// of any kind, and holds on to the view. `SAVERKIT_LIFECYCLE` measures a first view per
    /// host that is *never* deallocated — retained by the host's own container view and its
    /// window — so deallocation cannot be the goal. Releasing what the view owns can be. A view
    /// that has committed nothing for this long hands back its host, its attachments, its
    /// drawables and its scene; the next frame the link delivers rebuilds them.
    ///
    /// Four seconds is well past any stall of a view that is being shown in the paths measured
    /// (`spikes/008-view-lifecycle`), and well inside anything a person would notice as memory
    /// pressure — the leftover found on the real host was holding 612 MB with nothing on
    /// screen. Two things it is not: it is not proof that nobody is looking (a display asleep
    /// or a main thread frozen past four seconds gets a rebuild — a fresh scene, and about
    /// 0.6 s of main-thread work at 1200x700 — on the next frame), and it is not a stop, so a
    /// saver that keeps state across a release should carry it in `didReleaseHost(_:)`.
    var idleReleaseDelay: CFTimeInterval { 4 }

    /// A view narrower than this is treated as the System Settings thumbnail.
    ///
    /// Size is the signal, not `ScreenSaverView.isPreview`, which is unreliable on Tahoe.
    /// The smallest real display this could run on is far wider than any preview.
    ///
    /// One half of the answer only. A small view is certainly a preview; a large one is not
    /// certainly a session, because the picker's live preview is a *full-screen-sized* view
    /// shown at two inches. `renderQuality` is where both halves meet.
    var previewWidthThreshold: CGFloat { 600 }

    /// The longest edge, in pixels, a `.reduced` view renders at.
    ///
    /// The one saving that costs nothing anybody can see. The picker's live preview is a
    /// 2056x1329-point view composited into a tile a couple of inches wide, so it is asking for
    /// something like eight times the pixels it can possibly display; a `CAMetalLayer` scales a
    /// smaller drawable up to its bounds for free, and the compositor was going to scale the
    /// frame down anyway. Measured on the aquarium at 2056x1329: 3.60 ms of GPU per frame at
    /// full size, and the fill half of that is gone by 720.
    ///
    /// Above what any preview is displayed at, deliberately — this is a ceiling on waste, not
    /// an attempt to guess the tile's size, which nothing in the view can read.
    ///
    /// In **pixels**, so it is a ceiling on work rather than on apparent size: the settings
    /// sheet's 384x216-point preview passes it untouched at 1x and is trimmed by 6% at 2x,
    /// where it would otherwise be 768 px. That is the correct behaviour for a work ceiling and
    /// is invisible either way; the point is that it is not "previews are exempt".
    var reducedPixelCap: CGFloat { 720 }

    /// Frame rate cap for a `.reduced` view, or 0 to keep `preferredFPS`.
    ///
    /// Halving the rate halves everything the resolution cap does not touch — the school's
    /// simulation, the fin deformation, the draw calls — and a tank of drifting fish at two
    /// inches does not read differently at 30. Applied to the live link rather than at
    /// creation, since a view changes quality without being restarted.
    var reducedFPS: Int { 30 }

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

    /// The rendered scale last handed to the host, so a change can be noticed when the
    /// drawable's integer size does not move. 0 until the first delivery.
    private var deliveredScale: CGFloat = 0

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

    /// True once an idle view has released its render graph and is waiting for a frame to
    /// rebuild it. Distinct from `isSuspended` (no window) and `wantsFrames` (animating): a
    /// view can be any combination, and only this one says the host is gone.
    private var isHibernating = false

    /// The machine clock at the last committed frame — or at the last `startAnimation()` or link
    /// creation, so a view that has been asked for frames and produced none ages from the ask.
    /// A link that has gone silent leaves no other trace.
    private var lastFrameCommit: CFTimeInterval = 0

    /// The idle watchdog: a 1 Hz repeating timer on the main run loop, alive between
    /// `startAnimation()` and `stopAnimation()`. Block-based with a weak capture, so it does
    /// not keep the view alive; the inherited `ScreenSaverView` timer already does that, and
    /// this one is not relied on for anything but the check. It is deliberately SaverView's own
    /// rather than `animateOneFrame`: the inherited timer's callback is gated on `window != nil`
    /// and can be switched off by a saver's own Info.plist (`SSENeedsAnimationTimer`), and the
    /// watchdog must run in exactly the states where nothing else does.
    private var watchdog: Timer?

    /// `SAVERKIT_AUDIENCE=1` declares that every view in this process is being looked at;
    /// `SAVERKIT_AUDIENCE=0` withdraws that, so the harness can stand in for a leftover.
    /// `tools/run-saver.swift` sets `1` for itself: its interactive window is an ordinary
    /// window on the developer's screen, which is exactly the shape of a leftover in the real
    /// host, and the harness knows the difference where the view cannot. Cannot reach the host,
    /// whose environment is empty.
    private static let assumesAudience =
        (ProcessInfo.processInfo.environment["SAVERKIT_AUDIENCE"] as NSString?)?.boolValue ?? false

    /// The tier the current host was built for. Quality is decided at build time — a saver
    /// reads it once, from `HostContext` — so this is what a live answer has to be compared
    /// against to know whether a rebuild is owed.
    private var builtQuality: RenderQuality = .full

    /// When the live answer first disagreed with `builtQuality`, or 0 while they agree. Only a
    /// downgrade waits; see `applyQualityIfChanged()`.
    private var qualityPendingSince: CFTimeInterval = 0

    /// True when the current host's tier was decided from something that was not yet knowable.
    ///
    /// Two things are provisional early on, and both are the normal case rather than an edge:
    /// a host is created on the first layout with usable bounds, which on Tahoe routinely
    /// happens *before* the view is in a window; and `ScreenSaverSession` needs about a second
    /// and a half to tell a real session from a picker thumbnail, because the host is spawned
    /// before System Settings registers in the process table.
    ///
    /// Either way the tier that was built is a guess, and the first answer given once the
    /// guess can be checked is not a flicker to be debounced — it is the first real
    /// measurement, and it is applied at once. Without this the picker's tile would draw a
    /// full-screen frame for three and a half seconds and *then* pay a rebuild, which is both
    /// the cost this exists to avoid and a visible restart.
    private var builtProvisionally = false

    /// `SAVERKIT_QUALITY=full|reduced` pins the tier for every view in the process.
    ///
    /// The harness has an ordinary window on the developer's screen and cannot be the picker,
    /// whose live preview is the whole case this exists for — so the one way to render that
    /// case outside System Settings is to say so. Anything unrecognised leaves the view to
    /// decide for itself. Cannot reach the real host, whose environment is empty.
    private static let pinnedQuality: RenderQuality? = {
        switch ProcessInfo.processInfo.environment["SAVERKIT_QUALITY"]?.lowercased() {
        case "full": return .full
        case "reduced": return .reduced
        default: return nil
        }
    }()

    /// Latched the first time this view's window is at a presenting level. A view that has
    /// presented is a session's view: back at an ordinary level it is a leftover, whatever else
    /// is running. The picker's live preview never presents, so it never latches.
    private var hasPresented = false

    /// Time accumulated over previous start/stop cycles, so `FrameContext.time` never goes
    /// backwards. `SCNRenderer.render(atTime:)` takes an absolute clock: handing it a value
    /// lower than the last one re-simulates or resets particle systems, and every phase in a
    /// scene driven by that clock snaps back to where it started.
    private var timeOffset: CFTimeInterval = 0

    /// Nil unless `SAVERKIT_STATS` is set; see `FrameStats`.
    private let stats = FrameStats.makeIfEnabled()

    private var isPreviewSized: Bool { bounds.width < previewWidthThreshold }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private func logLifecycle(_ event: String) {
        guard LifecycleLog.isEnabled else { return }
        LifecycleLog.emit("SaverKit lifecycle: \(event) \(type(of: self)) "
                          + "\(Unmanaged.passUnretained(self).toOpaque())")
    }

    /// Frames committed since the last signals line; the one number that says whether this
    /// view is producing frames, whatever else the host tells it.
    private var framesSinceSignal = 0

    /// Under `SAVERKIT_LIFECYCLE`, once a second from the watchdog: everything a view can read
    /// about its own window, beside how many frames it committed. A host abandons views without
    /// telling them, and the only way to learn which signal still distinguishes a view someone
    /// can see from one nobody can is to log them all from inside the real host and compare.
    private func logSignals() {
        guard LifecycleLog.isEnabled else { return }
        let frames = framesSinceSignal
        framesSinceSignal = 0
        var fields = ["frames=\(frames)", "wants=\(wantsFrames)", "suspended=\(isSuspended)",
                      "hibernating=\(isHibernating)", "host=\(host != nil)",
                      "session=\(ScreenSaverSession.shared.isRunning ? "running" : "idle")"
                          + (ScreenSaverSession.shared.hasSettled ? "" : "?"),
                      "quality=\(renderQuality() == .reduced ? "reduced" : "full")",
                      "built=\(builtQuality == .reduced ? "reduced" : "full")",
                      "bounds=\(Int(bounds.width))x\(Int(bounds.height))",
                      "drawable=\(Int(metalLayer?.drawableSize.width ?? 0))x\(Int(metalLayer?.drawableSize.height ?? 0))",
                      "hidden=\(isHiddenOrHasHiddenAncestor)",
                      "visibleRect=\(Int(visibleRect.width))x\(Int(visibleRect.height))"]
        if let window {
            // `windowNumber` is documented as non-positive for a window without a window device,
            // and `CGWindowID` is unsigned: converting a -1 would trap the whole host.
            let info = window.windowNumber > 0
                ? (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber))
                   as? [[String: Any]])?.first
                : nil
            fields += ["level=\(window.level.rawValue)", "isVisible=\(window.isVisible)",
                       "onActiveSpace=\(window.isOnActiveSpace)",
                       "occlusion=\(window.occlusionState.contains(.visible) ? "visible" : "occluded")",
                       "screen=\(window.screen != nil)", "alpha=\(window.alphaValue)",
                       "winFrame=\(Int(window.frame.width))x\(Int(window.frame.height))",
                       "winNumber=\(window.windowNumber)",
                       "cgOnscreen=\(info?[kCGWindowIsOnscreen as String] as? Bool ?? false)",
                       "cgListed=\(info != nil)",
                       "keyOrMain=\(window.isKeyWindow || window.isMainWindow)"]
        } else {
            fields.append("window=nil")
        }
        LifecycleLog.emit("SaverKit signals: \(type(of: self)) \(Unmanaged.passUnretained(self).toOpaque()) "
                          + fields.joined(separator: " "))
    }

    // MARK: Init

    override init?(frame: NSRect, isPreview: Bool) {
        // Assigned before `super.init` so that `makeBackingLayer()` — which AppKit calls
        // synchronously from `wantsLayer = true` below — can see it.
        self.metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, isPreview: isPreview)

        // The inherited timer still exists — `ScreenSaverView` schedules it unless the *saver's*
        // own Info.plist sets `SSENeedsAnimationTimer` to false — but the display link does the
        // real work. Keep it cheap; `animateOneFrame` is intentionally a no-op.
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
        watchdog?.invalidate()
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

    /// The drawable this view should be rendering into, or nil if the bounds are not yet real.
    ///
    /// Not simply bounds times scale: a `.reduced` view is composited at a fraction of the size
    /// it believes it is, so it renders at a fraction of the pixels and the layer scales the
    /// result up to fill itself. `contentsGravity` is `resize` by default and the magnification
    /// filter is linear, so this costs nothing and needs nothing configured — it is the same
    /// dynamic-resolution trick a game uses to hold a frame rate, applied to a view that will
    /// never be looked at closely enough to see it.
    private func targetDrawableSize() -> CGSize? {
        guard let metalLayer else { return nil }
        let scale = metalLayer.contentsScale
        var width = bounds.width * scale
        var height = bounds.height * scale
        // Zero bounds are normal at init on Tahoe. The caller leaves the previous drawable
        // size alone and waits for a real layout.
        guard width > 0, height > 0 else { return nil }

        // The tier the *host* was built for while one exists, and the live answer only when one
        // is about to be built. The two differ for as long as a downgrade is being held, and
        // taking the live answer there lets a resize arriving mid-hold cap the drawable under a
        // host that is still `.full` — after which, if the tier flips back before the hold
        // expires, `applyQualityIfChanged` sees agreement, declines to rebuild, and nothing is
        // left to restore the resolution. Sizing to the built tier keeps the drawable and the
        // host as one decision: it changes when, and only when, the host is rebuilt, and
        // `reloadHost` re-sizes before building precisely so that it can.
        let quality = host == nil ? renderQuality() : builtQuality
        if quality == .reduced, reducedPixelCap > 0 {
            // The longest edge, so a portrait tile is capped by the edge that is actually long,
            // and one factor for both so the aspect the camera projects into does not move.
            let shrink = reducedPixelCap / max(width, height)
            if shrink < 1 {
                width *= shrink
                height *= shrink
            }
        }
        return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
    }

    private func updateDrawableSize() {
        guard let metalLayer, let pixels = targetDrawableSize() else { return }
        // A hibernating view is resized by a host that is not showing it; the wake path
        // re-runs this once a frame is actually wanted.
        guard !isHibernating else { return }
        guard pixels != metalLayer.drawableSize || depthTexture == nil else {
            // The attachments are already the right size, but the *scale* they are being drawn
            // at may not be what the host was last told. Under the resolution cap two different
            // bounds round to one drawable — 2056 and 3000 points both cap to 720 — so a
            // proportional resize can move the rendered scale by half without moving a single
            // pixel of the target. Nothing else would tell the host, and a radius sized in
            // points would stay wrong until some later resize happened to change a rounded
            // dimension. Re-state the targets; do not reallocate them.
            deliverTargetsIfScaleChanged()
            return
        }

        metalLayer.drawableSize = pixels
        ensureHost()
        rebuildAttachments()
    }

    /// Pixels per point actually being rendered into a drawable of this size.
    ///
    /// Falls back to the layer's own scale only when the bounds are not yet real, which is the
    /// state a host is never built in.
    private func renderedScale(for drawableSize: CGSize) -> CGFloat {
        bounds.width > 0 ? drawableSize.width / bounds.width
                         : metalLayer?.contentsScale ?? 1
    }

    /// Hands the host its current render targets and records the scale that went with them.
    private func deliverTargets() {
        guard let host, let metalDevice, let metalLayer, depthTexture != nil else { return }
        let size = metalLayer.drawableSize
        deliveredScale = renderedScale(for: size)
        host.hostDidResize(to: RenderTargets(drawableSize: size,
                                             sampleCount: resolvedSampleCount,
                                             colorPixelFormat: host.colorPixelFormat,
                                             depthPixelFormat: host.depthPixelFormat,
                                             backingScale: deliveredScale),
                           device: metalDevice)
    }

    private func deliverTargetsIfScaleChanged() {
        guard let metalLayer, host != nil, depthTexture != nil,
              renderedScale(for: metalLayer.drawableSize) != deliveredScale else { return }
        deliverTargets()
    }

    // MARK: Host lifecycle

    private func ensureHost() {
        guard host == nil, !hostFailed,
              let metalDevice, let metalLayer,
              metalLayer.drawableSize.width > 0 else { return }

        let quality = renderQuality()
        let context = HostContext(device: metalDevice,
                                  bundle: saverBundle,
                                  quality: quality,
                                  drawableSize: metalLayer.drawableSize)

        guard let created = makeHost(context) else {
            // Latched so a failing host is not retried on every resize.
            hostFailed = true
            return
        }
        host = created
        builtQuality = quality
        builtProvisionally = window == nil || !ScreenSaverSession.shared.hasSettled
        qualityPendingSince = 0
        // The rate belongs to the tier, and the link outlives a host: a view that changes
        // quality is not restarted, so nothing else would ever revise it.
        applyPreferredFrameRate()
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
        reloadHost(.reload)
    }

    private func reloadHost(_ reason: HostReleaseReason) {
        releaseHost(reason)
        // A reload is a fresh chance for a host that failed to build; an idle release is not.
        hostFailed = false
        qualityPendingSince = 0
        // A hibernating view builds its host on the next frame it is asked for, and not before.
        guard !isHibernating else { return }
        // Resized before the host is built, not after: the resolution cap moves with the tier,
        // and a host is handed its drawable size once, at creation.
        if let metalLayer, let pixels = targetDrawableSize() { metalLayer.drawableSize = pixels }
        ensureHost()
        rebuildAttachments()
    }

    /// Frees everything built for drawing: the host, the render attachments and whatever the
    /// saver kept beside them.
    private func releaseHost(_ reason: HostReleaseReason) {
        host?.teardown()
        host = nil
        // Dropped rather than left in place: `rebuildAttachments` reallocates them for the new
        // host anyway, but it returns early if the new host fails to build, and these are
        // hundreds of megabytes at 5K that a view which has stopped drawing has no use for.
        depthTexture = nil
        msaaTexture = nil
        didReleaseHost(reason)
    }

    // MARK: Audience
    //
    // Measured on the real host, logging every readable window property once a second across a
    // hot-corner session and its dismissal (spikes/008-view-lifecycle/README.md §6): after the
    // session ended the view went on committing 60 frames a second into a full-screen window at
    // level 0, at ~24% CPU and 620 MB, and `isVisible`, `isOnActiveSpace`, `occlusionState`,
    // `screen`, `alphaValue` and the CG on-screen bit all read exactly as they had while it was
    // presenting. The level was the only thing that moved. So the level is the test, and two
    // facts break the one tie it cannot — a full-screen view at `.normal` is either the picker's
    // live preview or a leftover: the picker's preview has never presented, and it exists only
    // while System Settings does.

    /// Can anyone see the frame this view is about to draw?
    ///
    /// Draws: a view whose window is at any level but the one measured for a leftover (a
    /// session, the harness's capture window, anything unmeasured — erring toward drawing,
    /// because a wrong "no" here is a black screensaver, not a quiet one); a preview-sized view,
    /// which somebody opened on purpose and which costs nothing worth arguing about; and a
    /// full-screen view at `.normal` that has never presented, while System Settings is running
    /// — the picker's live preview. What is left is a leftover, and nobody is looking at it.
    ///
    /// The process check is shared by every view in the bundle, throttled to seconds, and
    /// never asked while presenting, so a running screensaver never pays for it. Errs toward
    /// drawing: a failed lookup keeps the last answer, which starts as "running".
    ///
    /// The one visible cost: a picker preview that was promoted to present a real session
    /// (measured — a session reuses the picker's host and its full-screen view) is dark once
    /// that session ends, until it is reselected. Rare, and the alternative was measured: with
    /// System Settings open on any pane, every dismissed session's leftover would draw at full
    /// rate for as long as Settings stayed open.
    private func hasAudience() -> Bool {
        if SaverView.assumesAudience { return true }
        if HostSignals.isPresenting(window) { hasPresented = true; return true }
        guard let window, window.level == .normal else { return true }
        if bounds.width > 0 && isPreviewSized { return true }
        if hasPresented { return false }
        return HostSignals.systemSettingsIsRunning(recheckAfter: SaverView.settingsCheckInterval)
    }

    /// What this view is worth drawing at, right now. Read every frame, never cached — the
    /// host moves a view's level with no callback of any kind, so a cached answer is the truth
    /// from before it was moved.
    ///
    /// The same ladder `hasAudience()` climbs, asked for a budget instead of a yes or no, and
    /// it lands on the one rung that method does not act on: a full-screen-sized view at
    /// `.normal` that has never presented, in a host with System Settings behind it, is the
    /// picker's live preview — a couple of inches of tile that has been asking for a
    /// full-screen frame since the day this saver shipped.
    ///
    /// Everything unmeasured resolves to `.full`. A wrong `.reduced` is a soft screensaver on a
    /// real display, which is the failure a user would actually notice; a wrong `.full` is only
    /// the cost this is trying to save.
    private func renderQuality() -> RenderQuality {
        if let pinned = SaverView.pinnedQuality { return pinned }
        // First, and ahead of the window entirely, because it is the one test that cannot be
        // wrong in either direction: nothing presents a screensaver into a view narrower than
        // `previewWidthThreshold`, and every host that shows one at that size is showing a
        // preview. Putting it after `isPresenting` was measured to make `run-saver --preview`
        // draw a full-fat frame, since the harness window counts as presenting — a developer
        // asking to see the preview would have been shown something else.
        if bounds.width > 0 && isPreviewSized { return .reduced }
        // Before the session test, not after. The harness is an ordinary process that the
        // session's startup guess reads exactly as it reads a picker thumbnail, so without this
        // a developer's render would be softened by whether System Settings happened to be open
        // — the same trap `SoundSession` documents for the recording loop, where the failure is
        // a valid WAV of silence. Here it would be a valid PNG of the wrong resolution.
        if SaverView.assumesAudience { return .full }
        // A presenting window is a screensaver *surface* — and so is the picker's live preview.
        // Measured in the real picker on Tahoe: the tile at the top of the Screen Saver sheet
        // runs at the presenting level, because macOS draws the saver into a genuine
        // full-screen window behind System Settings and composites two inches out of it. The
        // level cannot tell them apart, so the session is asked instead.
        if HostSignals.isPresenting(window) {
            hasPresented = true
            return sessionIsIdle() ? .reduced : .full
        }
        guard let window, window.level == .normal else { return .full }
        // A leftover. It is not drawing at all, so the tier is academic — but a view that has
        // presented once may be promoted again, and coming back at full size is the right way
        // to be wrong.
        if hasPresented { return .full }
        return HostSignals.systemSettingsIsRunning(recheckAfter: SaverView.settingsCheckInterval)
            ? .reduced : .full
    }

    /// Rebuilds the host when the audience's answer no longer matches what the host was built
    /// for. Called from the frame path, which is the only place that runs in every state a view
    /// can be abandoned in.
    ///
    /// The two directions are deliberately not symmetric. An **upgrade is immediate**: a real
    /// session reuses the picker's own full-screen view (measured, `docs/saver-host.md` §2), so
    /// the moment that view starts presenting it is the screensaver, and waiting would put a
    /// visibly soft frame on a real display at exactly the moment somebody starts watching. A
    /// **downgrade has to hold**, because a rebuild is 234–354 ms of main-thread work in the
    /// aquarium and taking one on a momentary flicker buys nothing.
    private func applyQualityIfChanged() {
        let wanted = renderQuality()
        guard host != nil, wanted != builtQuality else {
            qualityPendingSince = 0
            // The provisional tier has just been confirmed by a reading that was not a guess,
            // so it has stopped being one: from here on a disagreement is a real change and
            // gets the hold like any other.
            if window != nil && ScreenSaverSession.shared.hasSettled { builtProvisionally = false }
            return
        }
        // A downgrade off a windowless guess is not a downgrade, it is the first measurement.
        // Holding it would leave the picker's tile drawing a full-screen frame for two seconds
        // and then rebuilding — which is both the cost this exists to avoid and a visible
        // restart, since a rebuild draws a fresh tank.
        if wanted == .full || builtProvisionally {
            reloadHost(.quality)
            return
        }
        let now = CACurrentMediaTime()
        if qualityPendingSince == 0 { qualityPendingSince = now; return }
        guard now - qualityPendingSince >= SaverView.qualityHoldDelay else { return }
        reloadHost(.quality)
    }

    /// Is the system telling us that nothing is being screen-saved right now?
    ///
    /// Only ever used to *withhold* quality from a presenting view, and only on a settled
    /// answer, because the two callers of `ScreenSaverSession` err in opposite directions:
    /// audio must default to silence, and this must default to a full-quality frame. An
    /// unsettled answer, or a system that could not be asked, draws at full.
    ///
    /// **The accepted risk, and it is the mirror of the audio gate's.** `didstart` is posted
    /// before the host process exists, so a session that spawns a *fresh* host while System
    /// Settings happens to be open on some unrelated pane misses the edge, and the startup
    /// guess — "the settings pane is open, so this is a thumbnail" — is then wrong about a real
    /// screensaver. That costs a soft full-screen frame for one activation; the host is warm
    /// for every one after it and hears `didstart` properly. The audio gate takes the same bet
    /// and pays for it in silence. `SAVERKIT_QUALITY=full` is the escape hatch.
    private func sessionIsIdle() -> Bool {
        let session = ScreenSaverSession.shared
        guard session.hasSettled else { return false }
        return !session.isRunning
    }

    /// How long a downgrade has to stay true before it costs a rebuild.
    private static let qualityHoldDelay: CFTimeInterval = 2

    /// How often the process table is read on behalf of a never-presented view at `.normal`.
    /// The cost of a stale answer is a picker preview that starts a few seconds late; the cost
    /// of asking is a copy of the whole process table, so neither end wants to be extreme.
    private static let settingsCheckInterval: CFTimeInterval = 3

    // MARK: Idle release
    //
    // The memory half of the rule the audio spike produced: tie every side effect to frames
    // actually being produced, never to a callback. Sound fades when the frames stop; here the
    // render graph is let go when nothing has been committed for `idleReleaseDelay`. Nothing has
    // to notify the view — the failing case is precisely a view nobody notifies.

    /// Releases the render graph if no frame has been committed for `idleReleaseDelay`.
    ///
    /// One test for every way frames can have stopped: a window ordered out (link alive and
    /// silent), a view that left its window (link gone), `startAnimation()` before there was a
    /// window to link to (never had one). Committing is what counts, not the link calling back —
    /// a callback whose `render` bailed on a missing attachment or drawable produced nothing
    /// anyone could see, and holding a scene for it holds it for nobody.
    private func releaseHostIfIdle() {
        // Only a view that still *wants* frames and is not getting them. One the host has
        // properly stopped is being managed, keeps its scene, and resumes where it left off.
        guard wantsFrames, !isHibernating, host != nil || depthTexture != nil,
              lastFrameCommit > 0,
              CACurrentMediaTime() - lastFrameCommit >= idleReleaseDelay else { return }
        hibernate()
    }

    private func hibernate() {
        isHibernating = true
        logLifecycle("hibernated")
        releaseHost(.idle)
        // The layer keeps a pool of presented drawables sized to `drawableSize` — some 100 MB at
        // 4K — and only lets them go when that size changes. Wake restores it from the bounds
        // through `updateDrawableSize()`, and nothing draws in between: `render` bails on the
        // nil host long before it asks for a drawable.
        metalLayer?.drawableSize = CGSize(width: 1, height: 1)
    }

    /// The other direction: a frame is wanted, so build again. Called from the frame path only.
    /// A wake whose frames then fail to commit ages out again after `idleReleaseDelay`, so a
    /// view that cannot draw rebuilds at most once per delay rather than holding a dead scene.
    private func wakeIfHibernating() {
        guard isHibernating else { return }
        isHibernating = false
        logLifecycle("woke")
        // Aged from the wake, not from the last frame before hibernation: a first render that
        // fails transiently (no drawable, say) would otherwise look four seconds idle at once
        // and rebuild the whole graph again on the very next tick.
        lastFrameCommit = CACurrentMediaTime()
        // Everything below is what a first layout does; the depth texture is nil, so it runs.
        updateDrawableSize()
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.logSignals()
            self?.releaseHostIfIdle()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
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

        // The scale handed over is the one actually rendered at, not the display's — they
        // differ under a `.reduced` tier's resolution cap, and it is this one every consumer of
        // the field wants. A bloom radius is the case that proves it: `SCNCamera.bloomBlurRadius`
        // is applied in render-target pixels, so a radius sized for a 2056-pixel frame is nearly
        // three times as wide across a 720-pixel one, and the tile would come back visibly
        // hazier than the saver it is advertising. See `deliverTargets()`.
        deliverTargets()
    }

    // MARK: Animation

    override func startAnimation() {
        // The header is explicit that overrides must call the inherited implementation.
        super.startAnimation()
        wantsFrames = true
        isSuspended = false
        // Frames were asked for now; if none is ever committed, the graph ages from here.
        lastFrameCommit = CACurrentMediaTime()
        startFrameLink()
        startWatchdog()
    }

    override func stopAnimation() {
        wantsFrames = false
        isSuspended = false
        stopWatchdog()
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
        frameLink = link
        applyPreferredFrameRate()
        // `.common`, not `.default`: in `.default` the callback stops during event
        // tracking, which is exactly when a preview is being scrubbed in System Settings.
        link.add(to: .main, forMode: .common)
        lastFrameCommit = CACurrentMediaTime()
    }

    /// Asks the live link for the rate this view's tier deserves.
    ///
    /// Set on the existing link rather than at creation, because a view changes quality without
    /// ever being stopped and started — the picker's preview promoted to a real session is the
    /// case, and it has to come back to full rate as well as full size.
    private func applyPreferredFrameRate() {
        guard let frameLink else { return }
        var fps = preferredFPS
        if builtQuality == .reduced, reducedFPS > 0 {
            fps = fps > 0 ? min(fps, reducedFPS) : reducedFPS
        }
        guard fps > 0 else {
            frameLink.preferredFrameRateRange = .default
            return
        }
        frameLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
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
        // Before the wake, or a hibernated view with nobody to draw for rebuilds its whole
        // graph every second only to release it again — measured in the harness as a
        // hibernate/wake pair 3 ms apart on every watchdog tick.
        guard hasAudience() else { return }
        // Before the quality check, and from here rather than from the saver, because a tank
        // with its sound switched off still has to know whether it is a thumbnail. Throttled
        // inside, and it stops asking the moment a notification supersedes the guess.
        ScreenSaverSession.shared.reevaluateIfUnconfirmed()
        wakeIfHibernating()
        // After the wake, because a hibernated view has no host to compare against and would
        // spend the check on nothing; before the frame, so the frame that is about to be drawn
        // is the one the audience is owed.
        applyQualityIfChanged()

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

        if render(time: time, delta: delta) {
            // Stamped when a frame *finishes*, not when the link fires: a wake rebuilds the
            // whole scene on the main thread first, and a build slower than `idleReleaseDelay`
            // stamped at the start would look idle the moment it ended.
            lastFrameCommit = CACurrentMediaTime()
            framesSinceSignal += 1
        }
    }

    /// True if a frame was committed; false if there was nothing to draw with.
    private func render(time: CFTimeInterval, delta: CFTimeInterval) -> Bool {
        guard let host, let commandQueue, let metalLayer,
              bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let depthTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = metalLayer.nextDrawable()
        else { return false }

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
        return true
    }

    // MARK: Fail-soft

    override func draw(_ rect: NSRect) {
        // Only reached when Metal is unavailable and the view was never layer-backed.
        NSColor.black.setFill()
        rect.fill()
    }
}
