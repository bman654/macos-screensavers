// Spike 006, phase 0: does sound reach the output device from inside a sandboxed screensaver?
//
// Nothing in this repo has ever played audio, and the backlog's ambient-sound track is
// designed around the assumption that it can. `WKWebView` looked equally safe in this host
// and blanked after three seconds with no diagnostic, so the assumption is worth a day before
// anything is built on it.
//
// The probe is deliberately not a sound design: it plays a quiet arpeggio and prints what the
// audio stack is doing on screen. See `AudioProbeTone` for why the counters are the result and
// the sound is only the confirmation.
//
// Three hazards from `docs/saver-backlog.md` are tested here as well, because all three are
// cheaper to answer now than to design around later:
//
//   - the System Settings thumbnail must be silent  -> the preview gate, and `silentReason`
//   - one instance per display means N players       -> `liveViews` / `audibleViews`, on screen
//   - a leaked view is immortal                      -> a leaked one that also *plays* is worse

import AppKit
import Foundation
import Metal
import ScreenSaver

@objc(AudioProbeView)
final class AudioProbeView: SaverView {

    /// Process-wide, and on screen, because the multi-instance hazard has no other symptom.
    ///
    /// macOS builds a saver per display and System Settings builds more for its thumbnail and
    /// its preview, and none of them can see each other. Two views both showing `audible 2` is
    /// the doubling hazard, observed rather than reasoned about.
    private static var liveViews = 0
    private static var audibleViews = 0

    /// Every live view, weakly. The registry exists so that a view giving up audio can hand it
    /// to another one that is still eligible — without it, the last owner to disappear takes
    /// the sound with it and a saver still on screen stays silent for the rest of the launch.
    private static let allViews = NSHashTable<AudioProbeView>.weakObjects()

    /// The single view allowed to make a sound, if any.
    ///
    /// `docs/saver-backlog.md` predicted this: "One instance has to own audio, and instances
    /// have no natural way to discover each other." They do have one, as long as macOS keeps
    /// them in a single process — a `static`. What it cannot arbitrate is a second *process*,
    /// which is the open question this machine cannot answer.
    ///
    /// First eligible claimant wins, and holds it until it stops being eligible. Which view it
    /// is does not matter: once eligibility is decided by the screensaver *session* rather than
    /// by anything about the view, every candidate is in the same session, and a sound has no
    /// position on screen to be wrong about. What does matter is that nobody takes it from a
    /// view still entitled to it — see `refreshAudio`.
    private static weak var audioOwner: AudioProbeView?

    private let tone = AudioProbeTone()
    private var readout: AudioProbeReadout?
    private var isAudible = false
    private var windowChanges = 0
    private var elapsed: CFTimeInterval = 0

    /// Seeded with a value `silentReason()` can never return, so the first decision is logged.
    private var lastSilentReason: String? = "unstarted"
    private var lastHeartbeat: CFTimeInterval = -100
    private var sessionObserver: NSObjectProtocol?
    private let created = Date()

    /// Set to 1 to let the thumbnail play, which is the only way to tell the preview gate
    /// working apart from audio failing in a small view for some unrelated reason.
    ///
    /// Only reachable through `run-saver`: the environment is empty under `legacyScreenSaver`.
    private static let allowsPreviewAudio =
        ProcessInfo.processInfo.environment["AUDIOPROBE_PREVIEW_AUDIO"] == "1"

    private var isPreviewSized: Bool { bounds.width < previewWidthThreshold }

    /// How much of its screen's width this view covers.
    ///
    /// The reason there is a second gate at all: `previewWidthThreshold` is 600 points and the
    /// Tahoe picker's tile is evidently wider than that, because the thumbnail played. An
    /// absolute threshold has to guess a number that Apple is free to change with any release,
    /// and it guessed wrong the first time it was tested against the real picker.
    ///
    /// A fraction of the screen cannot be wrong in that way. A screensaver that is actually
    /// saving the screen covers it; anything appreciably smaller is a tile, a sheet's preview,
    /// or a harness window, and none of those should be heard.
    private var screenFraction: CGFloat {
        guard let screen = window?.screen ?? NSScreen.main, screen.frame.width > 0 else {
            return 0
        }
        return bounds.width / screen.frame.width
    }

    /// Deliberately conservative in both directions: unknown screen reads as 0 and therefore as
    /// a thumbnail, because the cost of being wrong is asymmetric. A silent screensaver is a
    /// missing feature; one that plays uninvited at 2am is why people uninstall them.
    private var isThumbnail: Bool { screenFraction < 0.5 }

    /// The one line that decides whether the width gate or the fraction gate is the right one
    /// for SaverKit to adopt, so it is printed wherever a decision is logged.
    private var geometry: String {
        let screen = window?.screen ?? NSScreen.main
        let screenWidth = Int(screen?.frame.width ?? 0)
        return "view=\(Int(bounds.width))x\(Int(bounds.height))pt screen=\(screenWidth)pt "
            + String(format: "fraction=%.2f", screenFraction)
            + " widthGate=\(isPreviewSized) fractionGate=\(isThumbnail)"
    }

    /// Everything this view does, on the unified log.
    ///
    /// `legacyScreenSaver` runs in the user's session, so `NSLog` from inside it is reachable
    /// with `log show --predicate 'eventMessage CONTAINS "AudioProbe"'`. That is a far better
    /// instrument than the on-screen readout for anything about *lifecycle*, because the whole
    /// question is what happens to a view after it stops being on screen — at which point its
    /// readout is, by definition, not being looked at.
    private func log(_ message: String) {
        AudioProbeLog.write("[\(Unmanaged.passUnretained(self).toOpaque())] \(message)")
    }

    /// The three ways a view can stop being seen, which are not the same and do not fire the
    /// same callbacks: no window at all, a window that has been ordered out, and a window that
    /// is on screen but fully covered.
    private var visibility: String {
        guard let window else { return "window=nil" }
        let occluded = window.occlusionState.contains(.visible) ? "visible" : "occluded"
        // The window's level is logged because it is the other candidate discriminator, and
        // this round is the one chance to measure both at once. A screensaver that has actually
        // taken the screen sits at `CGShieldingWindowLevel()`; a thumbnail in a settings pane is
        // an ordinary window whatever size it has been given.
        return "window=\(window.isVisible ? "shown" : "orderedOut") \(occluded) "
            + "level=\(window.level.rawValue) shield=\(Int(CGShieldingWindowLevel()))"
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        AudioProbeView.liveViews += 1
        AudioProbeView.allViews.add(self)
        log("init frame=\(Int(frame.width))x\(Int(frame.height)) isPreview=\(isPreview) "
            + "live=\(AudioProbeView.liveViews) "
            + "host=\(ProcessInfo.processInfo.processName) log=\(AudioProbeLog.url.path)")
        // Touching the singleton here is what installs the distributed-notification observer,
        // and it has to happen before the first `refreshAudio` rather than lazily inside it.
        sessionObserver = NotificationCenter.default.addObserver(
            forName: AudioProbeSession.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.log("session changed -> "
                      + "running=\(AudioProbeSession.shared.isScreenSaverRunning)")
            self?.refreshAudio()
        }
        _ = AudioProbeSession.shared
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("instantiated by ScreenSaverView, never from a nib")
    }

    deinit {
        if let sessionObserver {
            NotificationCenter.default.removeObserver(sessionObserver)
        }
        AudioProbeView.liveViews -= 1
        if AudioProbeView.audioOwner === self {
            AudioProbeView.audioOwner = nil
            handAudioToAnotherEligibleView()
        }
        setAudible(false)
        tone.stop()
        AudioProbeLog.write("[\(Unmanaged.passUnretained(self).toOpaque())] "
                            + "deinit live=\(AudioProbeView.liveViews)")
    }

    override func makeHost(_ context: HostContext) -> RenderHost? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let readout = AudioProbeReadout(lineCount: 11)
        self.readout = readout

        let host = SceneKitHost(device: device,
                                scene: readout.scene,
                                pointOfView: readout.cameraNode,
                                // Nothing here is a diagonal edge; the whole picture is text,
                                // which SpriteKit antialiases itself.
                                sampleCount: 1)
        host.renderer.overlaySKScene = readout.overlay
        readout.resize(to: context.drawableSize)

        host.onResize = { [weak readout] targets in
            readout?.resize(to: targets.drawableSize)
        }
        host.onUpdate = { [weak self] frame in
            guard let self else { return }
            self.elapsed = frame.time
            // The heartbeat the audio thread listens for. Everything else here is diagnostic;
            // this line is what stops the sound when the view stops being seen.
            self.tone.noteFrame()
            self.readout?.update(self.status())
            // A heartbeat, because the question is what a view does *after* it stops being
            // looked at. A view still logging here is still rendering; one that goes quiet in
            // the log while still audible is the leak, and the two are indistinguishable from
            // the front of the screen.
            if frame.time - self.lastHeartbeat >= 2 {
                self.lastHeartbeat = frame.time
                // Until a real notification has been heard, the session state is a guess that
                // gets better with age; ask it again and re-decide.
                AudioProbeSession.shared.reevaluateIfUnconfirmed()
                self.refreshAudio()
                self.log("frame t=\(Int(frame.time)) \(self.visibility) "
                         + "audible=\(self.isAudible) rendered=\(self.tone.renderedFrames) "
                         + AudioProbeSession.stateSnapshot())
            }
        }
        return host
    }

    // MARK: Audio lifecycle
    //
    // Tied to being in a window, not to `startAnimation()`. That is the same signal
    // `SaverView.suspendFrames` uses and for a sharper version of the same reason: an animating
    // view is retained by the run loop and cannot be freed, so a host that discards one without
    // stopping it leaks the whole graph. A leaked view that is only *rendering* wastes a GPU
    // and some memory into a window nobody can see. A leaked view that is also *playing* is
    // audible in the room forever, and every subsequent preview adds another voice.

    override func startAnimation() {
        super.startAnimation()
        log("startAnimation \(visibility)")
        refreshAudio()
    }

    override func stopAnimation() {
        super.stopAnimation()
        log("stopAnimation \(visibility)")
        refreshAudio()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanges += 1
        log("viewDidMoveToWindow \(visibility) changes=\(windowChanges)")
        refreshAudio()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Preview-ness is a size question, and a view can cross the threshold while live —
        // System Settings resizes its thumbnail, and `run-saver --resize` does it on purpose.
        log("setFrameSize \(geometry)")
        refreshAudio()
    }

    private func refreshAudio() {
        let ownReason = silentReason()
        let eligible = ownReason == nil

        if eligible {
            // Never take the sound from an owner that is still entitled to it.
            //
            // The screensaver starting is one notification delivered to every view's observer
            // in turn, so all of them become eligible within the same runloop pass. When each
            // claimed as it woke up, the engine started, stopped after zero frames and started
            // again — heard as the first note beginning, cutting off, and beginning again.
            // Whichever view gets there first is as good as any other: they are all in the same
            // session, and sound has no position on screen to be wrong about.
            let owner = AudioProbeView.audioOwner
            if owner !== self, owner == nil || owner?.silentReason() != nil {
                AudioProbeView.audioOwner = self
                owner?.yieldAudio(to: self)
            }
        } else if AudioProbeView.audioOwner === self {
            AudioProbeView.audioOwner = nil
            handAudioToAnotherEligibleView()
        }

        let reason = ownReason
            ?? (AudioProbeView.audioOwner === self ? nil : "another instance owns audio")
        apply(reason)
    }

    /// Silences this view without letting it re-claim, for use by whoever just took ownership.
    private func yieldAudio(to claimant: AudioProbeView) {
        log("yielding audio to \(Unmanaged.passUnretained(claimant).toOpaque())")
        apply("another instance owns audio")
    }

    /// A view that stops being eligible passes the sound on rather than ending it.
    ///
    /// The case this exists for is two displays: if the owner's screen sleeps or its view is
    /// torn down, the saver still running on the other screen should become audible instead of
    /// the machine going quiet until something else happens to trigger a claim.
    private func handAudioToAnotherEligibleView() {
        for candidate in AudioProbeView.allViews.allObjects
        where candidate !== self && candidate.silentReason() == nil {
            AudioProbeView.audioOwner = candidate
            log("handed audio to \(Unmanaged.passUnretained(candidate).toOpaque())")
            candidate.refreshAudio()
            return
        }
    }

    private func apply(_ reason: String?) {
        if reason != lastSilentReason {
            lastSilentReason = reason
            log("audio -> \(reason ?? "PLAYING") \(visibility) animating=\(isAnimating) "
                + geometry)
        }
        if let reason {
            setAudible(false)
            tone.hold(reason: reason)
        } else {
            setAudible(true)
            tone.start()
        }
    }

    /// Why the probe is not making a sound, or nil if it should be.
    private func silentReason() -> String? {
        if window == nil { return "no window" }
        if !isAnimating { return "not animating" }
        // A deliberate pause before the first sound. Everything that decides whether this view
        // should be heard is unreliable in the first moment of a host's life, and none of it is
        // worth being fast about: ambience that fades in over a couple of seconds is what was
        // wanted anyway, so the settling time is free.
        if Date().timeIntervalSince(created) < 1.5 { return "settling" }
        guard !AudioProbeView.allowsPreviewAudio else { return nil }
        // The gate that actually decides it. Every geometric test was tried against the real
        // host and every one of them passed a picker thumbnail as a full-screen saver — see
        // `AudioProbeSession`. The two below are kept because they cost nothing and are right
        // about a harness window, but neither is load-bearing any more.
        if !AudioProbeSession.shared.isScreenSaverRunning { return "screensaver not running" }
        if isPreviewSized { return "preview (width)" }
        if isThumbnail { return "preview (screen fraction)" }
        return nil
    }

    private func setAudible(_ audible: Bool) {
        guard audible != isAudible else { return }
        isAudible = audible
        AudioProbeView.audibleViews += audible ? 1 : -1
    }

    // MARK: Readout

    private func status() -> [String] {
        let scale = window?.backingScaleFactor ?? 1
        let process = ProcessInfo.processInfo
        return [
            "AUDIO PROBE — spike 006 phase 0",
            "",
            "engine       \(tone.state.label)"
                + (tone.isMutedByStall ? "  MUTED (no frames)" : ""),
            "output       \(Int(tone.outputSampleRate)) Hz, \(tone.outputChannels) ch",
            "render       \(tone.renderCalls) calls, \(tone.renderedFrames) frames"
                + String(format: " (%.1f s)", tone.renderedSeconds),
            "reconfigured \(tone.configurationChanges)x",
            "views        \(AudioProbeView.liveViews) live, "
                + "\(AudioProbeView.audibleViews) audible, \(windowChanges) window changes"
                + (AudioProbeView.audioOwner === self ? ", OWNER" : ""),
            "view         \(Int(bounds.width))x\(Int(bounds.height)) pt @\(scale)x"
                + String(format: "  %.2f of screen", screenFraction)
                + (isPreviewSized || isThumbnail ? "  PREVIEW" : ""),
            "visibility   \(visibility)  animating \(isAnimating)",
            "session      screensaver running: "
                + "\(AudioProbeSession.shared.isScreenSaverRunning)",
            "host         \(process.processName) pid \(process.processIdentifier)"
                + String(format: "   up %.0f s", elapsed),
        ]
    }
}
