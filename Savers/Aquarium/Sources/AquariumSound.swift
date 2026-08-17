// The tank's voice: an audio engine, the gate that decides when it may be heard, and the two
// things on screen that drive it — the aerators, and the fish.
//
// `SoundVoices` is the render thread's half and `SoundSession` is the gate's; this is the part
// the scene talks to. Six rules come straight out of `spikes/006-saver-audio` and each has a
// measurement behind it. Read that README before changing any of them:
//
//   1. Gate on the screensaver session, never on the view. No property of a saver view
//      distinguishes the real screensaver from the picker's thumbnail.
//   2. Seed the session state at startup and let it settle, because `didstart` is posted before
//      this process exists and is therefore unreachable on a fresh host.
//   3. Fade out on `willstop`, not `didstop`, so ambience ends under a screensaver still on
//      screen rather than being cut off by the desktop returning.
//   4. Start the engine once and ride a gain ramp. `AVAudioEngine.start()` measured at 470 ms;
//      a fade is instant. Never start and stop the engine to mute and unmute.
//   5. One owner, and never steal from an eligible one. Three views in one process otherwise
//      play three voices at triple gain — observed.
//   6. Ramp every gate change. A square-edged gate clicks, and a click is broadband.

import AVFoundation
import Foundation
import QuartzCore
import Synchronization

final class AquariumSound {

    /// Who currently holds the sound.
    ///
    /// The screensaver starting is *one* notification delivered to every view's observer in
    /// turn, so all of them become eligible inside the same runloop pass. The first pass at
    /// this let each claim the sound as it woke, and the result was audible: the first note
    /// started, cut off, and started again. Nobody takes it from an owner still entitled to it;
    /// which view wins does not matter, because they are all in the same session and a sound
    /// has no position on screen to be wrong about.
    ///
    /// Weak, because a view that is discarded without being stopped is a thing this repo has
    /// already been bitten by — see the leak note in `Shared/SaverKit/README.md`.
    private static weak var owner: AquariumSound?

    /// When the owner last drew a frame, on the *machine's* clock. Ownership can be taken from
    /// a stalled owner and only from a stalled one.
    ///
    /// `CACurrentMediaTime()` and not `FrameContext.time`, which is seconds since *that view's*
    /// animation started and therefore restarts at zero for every view. Comparing one
    /// instance's frame time against another's would have got this exactly backwards in both
    /// directions: a freshly created view could never take over from a stalled owner, and a
    /// long-running one would take over from a healthy view that had merely started later.
    ///
    /// "Never steal from an eligible owner" needs a way to say whether the owner is still
    /// eligible, and object liveness is not that — the spike proved the two differ. A view
    /// whose window is ordered out stops rendering, is told nothing, and is immortal, so it
    /// would hold this reference for the life of the host while another perfectly healthy view
    /// stayed silent behind it. Its render core already fades itself out on the same signal;
    /// this is what lets somebody else take over.
    private static var ownerHeartbeat: CFTimeInterval = 0

    /// How long an owner may go without a frame before it is considered abandoned. Comfortably
    /// longer than any legitimate hitch, and the same quarter second the render thread uses to
    /// decide it has stopped being looked at.
    private static let ownerTimeout: CFTimeInterval = 0.75

    private var core: SoundCore
    private let library: SoundLibrary
    private let seed: UInt64
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var recording: AVAudioFile?
    private var isStarting = false

    /// Bumped by `stop()`. The async start captures it and discards its engine if it changed.
    ///
    /// Without it, stopping during the half-second an engine takes to start does nothing —
    /// `engine` is still nil, so `stop()` has nothing to tear down — and the start then
    /// completes and installs a running engine that nobody asked for. That is the exact shape
    /// of the bug this whole feature exists to avoid: a screensaver making noise after it was
    /// told not to.
    private var startGeneration = 0

    /// When this instance first drew a frame, so the settling period can be measured from
    /// something that exists rather than from process start.
    private var firstFrame: CFTimeInterval?

    /// The frame clock, carried here rather than passed to `swish`.
    ///
    /// A swish is raised deep inside `School`'s fixed-step simulation, which has deliberately
    /// no access to the frame's own time — it integrates against a step count so that a seeded
    /// render is reproducible. Handing it a clock only so it could hand one back would put a
    /// timebase into the school for the benefit of the speaker.
    private var now: CFTimeInterval = 0

    /// A stream of its own off the launch seed, the same discipline the tank's own draws follow:
    /// taking numbers from a shared stream would make adding a sound reshuffle the reef.
    private var choice: Rand

    /// The last time any fish was heard. The per-tank floor, and it is the load-bearing one:
    /// ten fish each entitled to a swish every few seconds is a shoal of whispers.
    private var lastSwish: CFTimeInterval = -.greatestFiniteMagnitude

    /// Heard and refused, for `AQUARIUM_AUDIO_STATS`. The ratio is the interesting number: a
    /// run where almost everything is refused means the tank cooldown, not the effort
    /// threshold, is what a listener is actually hearing.
    private var swishesPlayed = 0
    private var swishesRefused = 0

    /// What `School` needs in order to decide which gestures are worth offering at all.
    var minimumEffort: Float { library.manifest.fish.minEffort }
    var turnShare: Float { library.manifest.fish.turnShare }
    var perFishCooldown: Float { library.manifest.fish.fishCooldown }

    init?(bundle: Bundle, seed: UInt64) {
        guard let library = SoundLibrary(bundle: bundle) else { return nil }
        self.library = library
        self.seed = seed
        choice = Rand(seed: seed ^ 0x50_1F_D0_0D_5E_ED)
        // At the library's own rate for now. The device's rate is not knowable without asking
        // an engine for its output node, and asking is not free — it instantiates the IO audio
        // unit, which is exactly what a thumbnail must not do. The core is rebuilt at the real
        // rate when the graph is, in `startEngineIfNeeded`.
        core = SoundCore(library: library, sampleRate: library.manifest.sampleRate, seed: seed)
    }

    deinit {
        stop()
    }

    // MARK: The frame path

    /// Called once per rendered frame. Cheap on purpose — one relaxed atomic increment plus, on
    /// the rare frames where something changes, a little bookkeeping.
    ///
    /// - Parameter isPresenting: whether this view's window is the surface the screensaver is
    ///   being drawn into, from `SoundSession.isPresenting`. It is the *view's* half of the gate
    ///   and the session notification is the system's half; neither is sufficient alone, and the
    ///   comment on that function is where both failures it fixes are recorded.
    func update(time: CFTimeInterval, isPresenting: Bool) {
        core.frameTick.wrappingAdd(1, ordering: .relaxed)
        now = time

        let first = firstFrame ?? time
        if firstFrame == nil { firstFrame = time }

        // The settling period. `SoundSession`'s startup guess cannot be taken at t=0 — the host
        // is spawned before System Settings has registered as a process, so a saver that
        // decided immediately concluded "no settings pane, therefore a real screensaver" and
        // played into the picker. Measured. Asking again a moment later costs nothing, because
        // ambience should fade in over seconds rather than appear.
        if time - first < SoundSession.settlingPeriod {
            SoundSession.shared.reevaluateIfUnconfirmed()
            core.gateTarget.store(Float(0).bitPattern, ordering: .relaxed)
            // Logged too, or a tank that never leaves this branch — one whose frame clock does
            // not advance the way this assumes — writes nothing at all and looks like a saver
            // whose sound was never built.
            if SoundLog.isEnabled, lastLoggedState == "unstarted" {
                lastLoggedState = "settling"
                SoundLog.write("settling  t=\(String(format: "%.2f", time))")
            }
            return
        }

        // Both halves, and ownership is claimed on the pair rather than on the session alone: a
        // view that is not the one on screen must not hold the sound, or it locks out the view
        // that is — which is precisely the failure this gate was added for.
        let running = SoundSession.shared.isScreenSaverRunning && isPresenting
        if running {
            let wall = CACurrentMediaTime()
            if AquariumSound.owner === self {
                AquariumSound.ownerHeartbeat = wall
            } else if AquariumSound.owner == nil
                        || wall - AquariumSound.ownerHeartbeat > AquariumSound.ownerTimeout {
                AquariumSound.owner?.stop()
                AquariumSound.owner = self
                AquariumSound.ownerHeartbeat = wall
            }
        } else if AquariumSound.owner === self {
            AquariumSound.owner = nil
        }

        let audible = running && AquariumSound.owner === self
        core.gateTarget.store((audible ? Float(1) : Float(0)).bitPattern, ordering: .relaxed)
        if audible { startEngineIfNeeded() }
        self.isPresenting = isPresenting
        reportIfAsked(time: time)
        logIfChanged(audible: audible, isPresenting: isPresenting)
    }

    /// The bed's density, from whichever aerators are emitting on screen this instant.
    ///
    /// This is what makes it *this* tank rather than aquarium noise played over one. Every
    /// emitter in the model library already declares a birth rate and `Bubbler` already knows
    /// which of them are alive, so the sound follows the picture for free.
    func setEmission(declaredRate: Float) {
        let bed = library.manifest.bed
        let rate = max(bed.idleRate, min(declaredRate * bed.rateScale, bed.maxRate))
        core.bedRate.store(rate.bitPattern, ordering: .relaxed)
    }

    /// Offer a fish gesture. Refused silently if the tank has been heard from too recently.
    ///
    /// - Parameters:
    ///   - bodyLength: metres. Sets the playback rate, and a resample is the exact size
    ///     transform for this synthesis: a stroke's band centre goes as 1/sqrt(length) and its
    ///     duration as sqrt(length), so scaling time by k is scaling body length by 1/k².
    ///   - pan: -1 at the left edge of the frame, +1 at the right, before the narrow pan width
    ///     the manifest allows.
    ///   - nearness: 1 at the glass, falling toward the back wall. Distance is a gain here and
    ///     not a filter, because the grain already carries the tank's response.
    ///   - strength: how far past its threshold the fish went. A hard turn and a bolt are the
    ///     same gesture at different sizes, and this is what keeps them from sounding alike.
    @discardableResult
    func swish(bodyLength: Float, pan: Float, nearness: Float, strength: Float,
               isDart: Bool) -> Bool {
        let fish = library.manifest.fish
        guard now - lastSwish >= Double(fish.tankCooldown) else {
            swishesRefused += 1
            return false
        }

        let first = isDart ? library.dartFirst : library.swishFirst
        let count = isDart ? library.dartCount : library.swishCount
        guard count > 0 else { return false }
        // From this tank's own stream, not the system generator. Everything else about a
        // launch is reproducible from the seed, and a recording made with `AQUARIUM_AUDIO_RECORD`
        // is only comparable against another one if the same tank picks the same grains.
        let slice = library.grains[first + Int(choice.next() * Float(count)) % count]
        guard slice.frames > 1 else { return false }

        let ratio = min(max((library.manifest.referenceBodyLength / max(bodyLength, 0.02))
                            .squareRoot(), fish.rateMin), fish.rateMax)
        let level = (isDart ? fish.dartGain : fish.swishGain) * slice.gain
            * min(max(nearness, 0.2), 1) * min(max(strength, 0.4), 1.6)

        lastSwish = now
        swishesPlayed += 1
        return core.push(SoundTrigger(offset: slice.offset, frames: slice.frames, rate: ratio,
                                      gain: level,
                                      pan: min(max(pan, -1), 1)
                                          * library.manifest.mix.panWidth))
    }

    // MARK: The engine

    /// Started on a background queue the first time this instance becomes audible.
    ///
    /// Two reasons it is not started in `init`. `AVAudioEngine.start()` measured at 470 ms, and
    /// blocking scene construction for half a second would cost the first frames of a tank that
    /// has just appeared. And a picker thumbnail should never open an audio device at all —
    /// deferring the start until the gate opens means a tile costs nothing rather than being
    /// started and muted.
    private func startEngineIfNeeded() {
        guard engine == nil, !isStarting, now >= nextStartAttempt else { return }
        isStarting = true
        let generation = startGeneration

        let engine = AVAudioEngine()
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate,
                                         channels: max(1, output.channelCount))
        else {
            // A zero-rate output format is what "there is no route to a device" looks like
            // here, and constructing a format from it returns nil where `connect` would trap.
            //
            // Backed off rather than retried, because this is reached from the frame path: a
            // machine with no route — which the spike names as a plausible login-window
            // outcome — would otherwise construct and discard an `AVAudioEngine` sixty times a
            // second for as long as the screensaver ran.
            isStarting = false
            backOff()
            return
        }

        // The device's rate is only knowable here, and a 48 kHz library on a 44.1 kHz device
        // needs no resampler — only a ratio folded into every voice's playback rate, which the
        // core computes once at construction. Rebuilt rather than adjusted so that a
        // configuration change onto a device at a different rate takes the same path.
        if core.sampleRate != output.sampleRate {
            core = SoundCore(library: library, sampleRate: output.sampleRate, seed: seed)
        }
        let core = self.core

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            // A mono device gets the left channel only rather than a sum, because the grains
            // are a decorrelated pair and summing them combs. It needs somewhere for the right
            // channel to go, though: aliasing it onto `first` means the render writes left and
            // then overwrites it with right, which is the *other* channel of a decorrelated
            // pair — harmless, and not what the comment said.
            let second = buffers.count > 1
                ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? core.discard
                : core.discard
            core.render(frameCount: Int(frameCount), left: first, right: second)
            for extra in 2..<max(buffers.count, 2) where extra < buffers.count {
                if let data = buffers[extra].mData?.assumingMemoryBound(to: Float.self) {
                    data.update(from: first, count: Int(frameCount))
                }
            }
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()

        // Off the frame path: half a second of engine start lands exactly at the moment the
        // screen has just gone dark, which is the worst possible moment to drop frames.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try engine.start()
            } catch {
                DispatchQueue.main.async {
                    self?.isStarting = false
                    self?.backOff()
                }
                return
            }
            DispatchQueue.main.async {
                // Two conditions, and the second one is the subtle half.
                //
                // A stale completion must not clear `isStarting`, because by then it belongs to
                // a *newer* start: clearing it lets the next audible frame dispatch a third,
                // both of which then pass the generation check and run this body. The second
                // assignment would overwrite an engine that is running, referenced by nothing,
                // and therefore unstoppable — two render threads driving one `SoundCore`, whose
                // voices and filter state are deliberately not atomic. `stop()` already cleared
                // the flag for the generation this completion belongs to.
                guard let self, generation == self.startGeneration, self.engine == nil else {
                    engine.stop()
                    return
                }
                self.engine = engine
                self.isStarting = false
                self.observeConfigurationChanges(of: engine)
                self.startRecordingIfRequested(on: engine)
            }
        }
    }

    /// Seconds to wait before trying to start again after a failure, doubling to a ceiling.
    ///
    /// A screensaver runs for hours and a route can appear at any point in them — headphones,
    /// a display with speakers — so giving up permanently is wrong too.
    private var nextStartAttempt: CFTimeInterval = 0
    private var startBackoff: CFTimeInterval = 1

    private func backOff() {
        nextStartAttempt = now + startBackoff
        startBackoff = min(startBackoff * 2, 30)
    }

    func stop() {
        startGeneration += 1
        isStarting = false
        // Silent first. The ramp that matters is the session's, and it has normally already run
        // by the time a host tears a view down — `willstop` arrives before the screen comes
        // back, and this is teardown. Setting the target here covers the other order.
        core.gateTarget.store(Float(0).bitPattern, ordering: .relaxed)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if recording != nil {
            engine?.mainMixerNode.removeTap(onBus: 0)
            recording = nil
        }
        engine?.stop()
        engine = nil
        // After `engine.stop()`, which blocks until the render thread has finished, so this
        // cannot race it. Zeroing the *target* above is not enough on its own: the envelope
        // that follows a target only moves while something is rendering, so a stopped engine
        // freezes its gain at full and a restarted one would begin there.
        core.reset()
        if AquariumSound.owner === self { AquariumSound.owner = nil }
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // A screensaver runs for hours across exactly the events that raise this —
            // headphones, a display with speakers, a Bluetooth device waking. The graph
            // survives but the engine does not restart itself, and the output may be at a
            // different rate that the source node no longer matches.
            guard let self else { return }
            self.stop()
            self.startEngineIfNeeded()
        }
    }

    /// `AQUARIUM_AUDIO_RECORD=/tmp/tank.wav` writes what the engine actually produced.
    ///
    /// This is the other half of the authoring loop, and the only ground truth there is: the
    /// Python preview rehearses the same manifest through a different implementation, so a
    /// recording is what proves the two agree. Inspect it with the `audio-lens` skill, and
    /// listen to it. Reachable only through `tools/run-saver.swift`, since the environment is
    /// empty under `legacyScreenSaver`.
    private func startRecordingIfRequested(on engine: AVAudioEngine) {
        guard let path = ProcessInfo.processInfo.environment["AQUARIUM_AUDIO_RECORD"],
              !path.isEmpty else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        // Sixteen-bit PCM, not the mixer's own float format, and that matters more than it
        // looks. `format.settings` writes 32-bit float in a WAVE_FORMAT_EXTENSIBLE container,
        // which `afplay` handles and every inspection tool in this loop refuses — Python's
        // `wave` and the `audio-lens` skill both fail to open it. A recording nothing can
        // measure is not a diagnostic. `AVAudioFile` converts on write.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                          settings: settings) else { return }
        recording = file
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
            buffer, _ in
            try? file.write(from: buffer)
        }
    }

    // MARK: Diagnostics

    private var lastReport: CFTimeInterval = 0

    /// Last frame's answer, kept only so the stats line can print it. A run where the session is
    /// running and nothing is heard has two very different causes now, and this names which.
    private var isPresenting = false

    /// `AQUARIUM_AUDIO_STATS=<seconds>`, and `render` is the load-bearing number.
    ///
    /// It is incremented on CoreAudio's own render thread, so it climbs if and only if the HAL
    /// is actually asking this process for samples. "I heard nothing" otherwise has four causes
    /// that want completely different fixes, and only the last of them needs ears.
    private static let statsPeriod: Double? = ProcessInfo.processInfo
        .environment["AQUARIUM_AUDIO_STATS"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }

    /// The same four facts as the stats line, on the only channel that exists inside the real
    /// host — and only when they change, because this is called every frame for hours.
    ///
    /// Seeded with a state the gate can never produce, so the first decision is always written.
    private var lastLoggedState = "unstarted"

    private func logIfChanged(audible: Bool, isPresenting: Bool) {
        guard SoundLog.isEnabled else { return }
        let owner: String
        if AquariumSound.owner === self {
            owner = "mine"
        } else {
            owner = AquariumSound.owner == nil ? "none" : "other"
        }
        let state = "audible=\(audible)"
            + "  session=\(SoundSession.shared.isScreenSaverRunning)"
            + "  presenting=\(isPresenting)"
            + "  owner=\(owner)"
            + "  engine=\(engine == nil ? "off" : "running")"
        guard state != lastLoggedState else { return }
        lastLoggedState = state
        SoundLog.write(state)
    }

    private func reportIfAsked(time: CFTimeInterval) {
        // Read once. `ProcessInfo.environment` materialises a fresh dictionary of the whole
        // environment on every access, so asking it per frame allocates on the frame path even
        // when the variable is unset — and it is unset in every shipped run.
        guard let period = AquariumSound.statsPeriod, time - lastReport >= period else { return }
        lastReport = time
        print(String(format:
            "[sound] t=%6.1f  engine %@  session %@  showing %@  owner %@  render %d  voices %d"
            + "  bubbles %d (dropped %d)  swishes %d (refused %d)",
            time, engine == nil ? "off" : "running",
            SoundSession.shared.isScreenSaverRunning ? "running" : "idle",
            isPresenting ? "yes" : "no",
            AquariumSound.owner === self ? "mine" : "other",
            core.renderedFrames.load(ordering: .relaxed),
            core.voicesInFlight.load(ordering: .relaxed),
            core.bubblesPlaced.load(ordering: .relaxed),
            core.bubblesDropped.load(ordering: .relaxed), swishesPlayed, swishesRefused))
    }
}
