// The audio half of the probe: an `AVAudioEngine` playing a gentle arpeggio, instrumented so
// that a silent run can be told apart from a broken one *without hearing it*.
//
// The question this spike exists to answer is whether sound reaches the output device from
// inside a sandboxed `legacyScreenSaver`. "I heard nothing" has at least four causes and they
// want completely different fixes:
//
//   1. the engine refused to start          -> `state` is `.failed`, with CoreAudio's reason
//   2. the engine started but has no route  -> `outputSampleRate` is 0, or channels is 0
//   3. the engine is running and nothing is pulling it -> `renderedFrames` stays put
//   4. everything is running and it is inaudible -> counters climb, and the fault is volume,
//      routing, or the sandbox silently discarding what it consumes
//
// Only the fourth needs ears. `renderedFrames` is the load-bearing instrument: it is
// incremented on CoreAudio's own render thread, so it climbs if and only if the HAL is
// actually asking this process for samples. Everything else can be read off a screenshot,
// which is what makes the login-window case testable at all — there is no console there.

import AVFoundation
import Foundation
import Synchronization

/// Counters written on the audio render thread and read on the main thread.
///
/// A separate object rather than fields on `AudioProbeTone` for two reasons: `Atomic` is
/// non-copyable and so cannot be captured by a closure, and capturing the tone itself in the
/// render block would form a cycle through the engine that keeps a discarded probe alive —
/// which is the exact failure mode this spike is meant to be watching for.
private final class ToneCounters: Sendable {
    let renderedFrames = Atomic<Int64>(0)
    let renderCalls = Atomic<Int64>(0)

    /// Bumped by the view once per rendered frame. The audio thread watches it and fades out
    /// when it stops moving — see `AudioProbeTone.noteFrame`.
    let frameTick = Atomic<Int64>(0)

    /// Written by the audio thread so the readout can say why it went quiet.
    let mutedByStall = Atomic<Bool>(false)
}

/// The signal. Deliberately not a sample buffer: a screensaver's ambience will be synthesised
/// or scheduled rather than looped, so the probe exercises the same path — a render callback
/// producing samples on demand — as the thing it is a proof for.
private final class ToneVoice {
    private let sampleRate: Double
    private var phase: Double = 0
    private var elapsed: Double = 0

    /// A minor arpeggio at conversational pitch, quiet, with a slow attack. Unmistakably
    /// artificial so it cannot be confused with room noise or another app, and gentle enough
    /// that hearing it unexpectedly is not unpleasant — this gets installed and may well play
    /// when nobody meant it to.
    private let notes: [Double] = [220.0, 277.18, 329.63]
    private let notePeriod = 1.4
    private let gateLength = 1.0
    private let ramp = 0.25
    private let amplitude: Float = 0.07

    /// The last frame tick this voice saw, and how many samples it has produced since it
    /// changed. Both live on the audio thread and are touched by nothing else.
    var lastSeenTick: Int64 = -1
    var samplesSinceFrame = 0

    /// Ramped rather than switched. A gate that jumps to zero clicks, and a click is
    /// broadband — it would be audible through the very routing failures this probe exists to
    /// detect. One pole, about 30 ms, which is short enough that stopping reads as immediate.
    var gain: Float = 0
    private lazy var gainCoefficient = Float(1 - exp(-1 / (0.03 * sampleRate)))

    /// True once no frame has been rendered for a quarter second.
    ///
    /// A quarter second is comfortably longer than any legitimate hitch — a dropped frame, a
    /// display reconfiguration, a shader compile on the first frame — and far shorter than a
    /// person's patience for a screensaver that is still humming after they dismissed it.
    var isStalled: Bool { Double(samplesSinceFrame) > sampleRate * 0.25 }

    func advanceGain(toward target: Float) {
        gain += (target - gain) * gainCoefficient
    }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func nextSample() -> Float {
        let cycle = notePeriod * Double(notes.count)
        let position = elapsed.truncatingRemainder(dividingBy: cycle)
        let index = min(notes.count - 1, Int(position / notePeriod))
        let frequency = notes[index]
        let within = position - Double(index) * notePeriod

        phase += 2 * .pi * frequency / sampleRate
        if phase > 2 * .pi { phase -= 2 * .pi }
        elapsed += 1 / sampleRate

        return Float(sin(phase)) * amplitude * envelope(within)
    }

    /// Raised cosine both ends. A gate with square edges clicks, and a click is broadband —
    /// it would be audible through exactly the low-level routing failure this probe is trying
    /// to detect, and would therefore lie about success.
    private func envelope(_ t: Double) -> Float {
        guard t < gateLength else { return 0 }
        if t < ramp {
            return Float(0.5 * (1 - cos(.pi * t / ramp)))
        }
        if t > gateLength - ramp {
            return Float(0.5 * (1 + cos(.pi * (t - (gateLength - ramp)) / ramp)))
        }
        return 1
    }
}

final class AudioProbeTone {

    enum State: Equatable {
        case idle
        case silent(String)
        case running
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "idle"
            case .silent(let reason): return "silent (\(reason))"
            case .running: return "running"
            case .failed(let message): return "FAILED \(message)"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var outputSampleRate: Double = 0
    private(set) var outputChannels: UInt32 = 0

    /// How many times the engine has had to be rebuilt because the output device changed.
    ///
    /// `AVAudioEngineConfigurationChange` stops the engine, and a screensaver runs for hours
    /// across exactly the events that raise it — headphones, a display with speakers, a
    /// Bluetooth device waking. Silence after twenty minutes with `state == .running` would be
    /// indistinguishable from success without this number.
    private(set) var configurationChanges = 0

    private var engine: AVAudioEngine?
    private let counters = ToneCounters()
    private var observer: NSObjectProtocol?
    private var recording: AVAudioFile?

    var renderedFrames: Int64 { counters.renderedFrames.load(ordering: .relaxed) }
    var renderCalls: Int64 { counters.renderCalls.load(ordering: .relaxed) }

    /// True when the audio thread has faded itself out because frames stopped arriving.
    var isMutedByStall: Bool { counters.mutedByStall.load(ordering: .relaxed) }

    /// Called once per rendered frame. Cheap on purpose — a relaxed atomic increment, which is
    /// a single instruction, because this sits in the frame path of every saver that has sound.
    func noteFrame() {
        counters.frameTick.wrappingAdd(1, ordering: .relaxed)
    }

    var renderedSeconds: Double {
        guard outputSampleRate > 0 else { return 0 }
        return Double(renderedFrames) / outputSampleRate
    }

    /// Silence with a stated reason, which is not the same as being stopped.
    ///
    /// The preview must be quiet, and a probe that is merely `.idle` there cannot tell us
    /// whether the gate worked or the engine failed to start for an unrelated reason.
    func hold(reason: String) {
        stop()
        state = .silent(reason)
    }

    func start() {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let output = engine.outputNode.outputFormat(forBus: 0)
        outputSampleRate = output.sampleRate
        outputChannels = output.channelCount

        // A zero-rate output format is what "there is no route to a device" looks like here;
        // constructing a format from it returns nil and `connect` would trap.
        guard output.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate,
                                         channels: max(1, output.channelCount)) else {
            state = .failed("no output format (rate \(output.sampleRate), "
                            + "\(output.channelCount) ch)")
            return
        }

        let voice = ToneVoice(sampleRate: output.sampleRate)
        let counters = self.counters
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            // The stall guard, and the reason this probe can be trusted not to hum at somebody
            // for an hour. Ordering a window out stops the display link and fires *no*
            // lifecycle callback — no `viewDidMoveToWindow`, no `stopAnimation` — so a saver
            // that gates audio on AppKit's notifications goes on playing after its preview is
            // dismissed. Measured: `spikes/006-saver-audio/lifecycle-driver.swift` phase 2.
            //
            // Frames are the one signal that reliably stops, because they stop for the same
            // reason the view stopped being seen. So audio is produced only while frames are:
            // the view bumps `frameTick`, and when it stops moving this fades out. It needs
            // nothing to be notified of anything, which is what makes it hold for a view that
            // has been abandoned and is unreachable.
            let tick = counters.frameTick.load(ordering: .relaxed)
            if tick != voice.lastSeenTick {
                voice.lastSeenTick = tick
                voice.samplesSinceFrame = 0
            } else {
                voice.samplesSinceFrame += Int(frameCount)
            }
            let target: Float = voice.isStalled ? 0 : 1
            counters.mutedByStall.store(voice.isStalled, ordering: .relaxed)

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                voice.advanceGain(toward: target)
                let sample = voice.nextSample() * voice.gain
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            counters.renderCalls.wrappingAdd(1, ordering: .relaxed)
            counters.renderedFrames.wrappingAdd(Int64(frameCount), ordering: .relaxed)
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            state = .failed("start: \(error.localizedDescription)")
            engine.detach(source)
            return
        }

        self.engine = engine
        state = .running
        // Logged here rather than only at the call site, because the previous round's log was
        // believed when it said no engine had started in a process that was audibly playing.
        // The engine reporting itself cannot be missed by a caller that forgot to.
        AudioProbeLog.write("engine STARTED \(Int(output.sampleRate)) Hz "
                            + "\(output.channelCount) ch")
        observeConfigurationChanges(of: engine)
        startRecordingIfRequested(on: engine)
    }

    /// `AUDIOPROBE_RECORD=/tmp/out.wav` writes what the engine actually produced.
    ///
    /// The only way to check a fade that happens on the audio thread. A log line cannot show
    /// it, a screenshot cannot show it, and whoever is running the test cannot hear a quarter
    /// of a second reliably — but a WAV can be measured. Reachable only through a harness,
    /// since the environment is empty under `legacyScreenSaver`.
    private func startRecordingIfRequested(on engine: AVAudioEngine) {
        guard let path = ProcessInfo.processInfo.environment["AUDIOPROBE_RECORD"],
              !path.isEmpty else { return }
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                          settings: mixerFormat.settings) else {
            NSLog("AudioProbe: could not open \(path) for recording")
            return
        }
        recording = file
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: mixerFormat) {
            buffer, _ in
            try? file.write(from: buffer)
        }
    }

    func stop() {
        if engine != nil {
            AudioProbeLog.write("engine STOPPED after \(renderedFrames) frames")
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if recording != nil {
            engine?.mainMixerNode.removeTap(onBus: 0)
            recording = nil
        }
        engine?.stop()
        engine = nil
        if case .failed = state {} else { state = .idle }
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            self.configurationChanges += 1
            // The graph survives the notification but the engine does not restart itself, and
            // the output format may be a different rate — which the source node's format no
            // longer matches. Rebuilding from scratch is the honest response; whether it is
            // also the *sufficient* one is one of the things this spike is here to find out.
            engine.stop()
            self.stop()
            self.start()
        }
    }
}
