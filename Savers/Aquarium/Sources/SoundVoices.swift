// Everything that runs on CoreAudio's render thread: a pool of grain voices, the stochastic
// scheduler that fills them, the synthesised water underneath, and the gate that fades the lot.
//
// **The rules this file obeys, all for the same reason.** The render callback runs on a
// real-time thread with a deadline of a few milliseconds and no priority inversion protection.
// Missing it is not a glitch in the ambience — it is a click, and a click is broadband. So:
// no allocation, no locks, no ARC traffic, no Swift arrays or strings, no `os_log`. State is a
// C array of trivial structs; parameters arrive as atomics; the one thing the main thread has
// to push (a fish's swish) arrives through a single-producer single-consumer ring.
//
// **There is no loop anywhere.** A screensaver runs for hours and the ear finds the period of
// any loop, however long — so the bed is scheduled, bubble by bubble, from a library of grains
// that are individually shorter than a second. What repeats is the statistics, and statistics
// do not sound like repetition.

import Foundation
import Synchronization

/// A fish gesture, handed from the main thread to the audio thread.
struct SoundTrigger {
    var offset: Int32 = 0
    var frames: Int32 = 0
    var rate: Float = 1
    var gain: Float = 0
    var pan: Float = 0
}

/// One grain in flight.
private struct Voice {
    var offset: Int32 = 0
    var frames: Int32 = 0
    var position: Double = 0
    var rate: Double = 1
    var gainLeft: Float = 0
    var gainRight: Float = 0
    var active: Bool = false
}

/// Two poles of state-variable band-pass, plus the integrator that makes brown noise.
///
/// One per output channel, with independent noise, because a mono floor convolved into both
/// channels collapses to the middle of the listener's head — and an enveloping, directionless
/// field is exactly what being underwater sounds like. See `tools/audio/soundlib/water.py`.
private struct WaterChannel {
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    var brown: Float = 0
    /// Three high-pass poles and one low-pass, as one-pole sections.
    ///
    /// A state-variable band-pass was the first attempt and it was wrong for a reason worth
    /// keeping: an SVF's band output has 6 dB/octave skirts, brown noise falls at 6 dB/octave,
    /// and the two cancel — so the "band-passed" floor ran flat all the way down to DC.
    /// Measured against the Python preview of the same manifest, the saver had nineteen decibels
    /// too much energy below 80 Hz and its spectral centroid sat at 188 Hz against the
    /// preview's 671. Three poles below and two above is what makes the two agree.
    var high: (Float, Float, Float) = (0, 0, 0)
    var low: Float = 0
}

final class SoundCore: @unchecked Sendable {

    /// Bumped by the view once per rendered frame.
    ///
    /// The stall guard, and the reason this can be trusted not to hum at somebody for an hour.
    /// Ordering a window out stops the display link and fires *no* lifecycle callback — no
    /// `viewDidMoveToWindow`, no `stopAnimation` — so a saver that gates audio on AppKit's
    /// notifications goes on playing after its preview has been dismissed. Measured in
    /// `spikes/006-saver-audio`. Frames are the one signal that reliably stops, because they
    /// stop for the same reason the view stopped being seen, and watching them needs nothing to
    /// be notified of anything: the failing case is a view nobody can reach.
    let frameTick = Atomic<Int64>(0)

    /// 1 while this instance owns the sound and the session says the screen is being saved.
    let gateTarget = Atomic<UInt32>(0)

    /// Audible bubbles per second, from whichever emitters are currently emitting on screen.
    let bedRate = Atomic<UInt32>(0)

    let renderedFrames = Atomic<Int64>(0)
    let voicesInFlight = Atomic<Int32>(0)
    let bubblesPlaced = Atomic<Int64>(0)
    let bubblesDropped = Atomic<Int64>(0)
    /// Callbacks larger than this core can serve. Should always be zero; if it is not, the
    /// scratch channel needs to grow.
    let oversizedCallbacks = Atomic<Int64>(0)

    // MARK: Configuration, read-only once the engine starts

    private let library: SoundLibrary
    /// The grain audio, hoisted out of `library` so the render loop never reads a stored
    /// property of another class.
    ///
    /// They are the same pointers, and the copies are not tidiness: reading `library.samples`
    /// from inside the render block loads a strong reference before it loads the pointer, and a
    /// strong-reference load can emit retain/release — which takes a lock in the Swift runtime
    /// and can therefore park the audio thread behind an unrelated allocation on some other
    /// thread. `library` is still held so that the buffers outlive this.
    private let samples: UnsafeMutablePointer<Float>
    private let grains: UnsafeMutablePointer<GrainSlice>
    private let bubbleSizes: UnsafeMutablePointer<GrainSizeClass>
    private let bubbleSizeCount: Int
    private let burstSizes: UnsafeMutablePointer<GrainSizeClass>
    private let burstSizeCount: Int
    let sampleRate: Double
    /// Grain sample rate over device sample rate, folded into every voice's playback rate.
    /// The bake is 48 kHz; a device running at 44.1 needs no resampler, only a ratio.
    private let rateRatio: Double

    private let masterGain: Float
    private let panWidth: Float
    private let fadeInCoefficient: Float
    private let fadeOutCoefficient: Float
    private let stallCoefficient: Float
    private let stallSamples: Double

    private let radiusMedian: Float
    private let radiusSigma: Float
    private let radiusMin: Float
    private let radiusMax: Float
    private let burstShare: Float
    private let bubbleGain: Float

    private let brownCoefficient: Float
    private let highCoefficient: Float
    private let lowCoefficient: Float
    private let waterGain: Float
    private let waterLFO: Float
    private let waterDepth: Float

    // MARK: Render-thread state, touched by nothing else

    private let voices: UnsafeMutablePointer<Voice>
    private let voiceCount: Int

    /// Somewhere for the second channel to go when the output device is mono.
    ///
    /// The render always writes a decorrelated pair; a mono device gets the left of it rather
    /// than a sum, because summing a decorrelated pair combs. Pointing both channels at the
    /// same buffer would have worked in the sense of not crashing, and would have delivered the
    /// *right* channel — the second write overwrites the first.
    let discard: UnsafeMutablePointer<Float>
    private static let maximumFrameCount = 8192
    private var water = (left: WaterChannel(), right: WaterChannel())
    private var gain: Float = 0
    private var stallGain: Float = 1
    private var samplesSinceFrame: Double = 0
    private var lastSeenTick: Int64 = -1
    private var untilNextBubble: Double = 0
    private var waterPhase: Float = 0
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    // MARK: The trigger ring

    private let triggers: UnsafeMutablePointer<SoundTrigger>
    private static let triggerCapacity = 32
    private let triggerHead = Atomic<Int32>(0)
    private let triggerTail = Atomic<Int32>(0)

    /// Thirty-two voices, which is generous and still small.
    ///
    /// The ceiling that matters is the bed's: at the manifest's maximum rate of 26 bubbles a
    /// second and a grain around 0.4 s long, about eleven are alive at any moment. Thirty-two
    /// leaves room for a burst of fish on top without ever reaching the drop path — and if it
    /// ever does, dropping a bubble is inaudible, whereas stealing one mid-ring is a click.
    private static let voicePoolSize = 32

    init(library: SoundLibrary, sampleRate: Double, seed: UInt64) {
        self.library = library
        samples = library.samples
        grains = library.grains
        bubbleSizes = library.bubbleSizes
        bubbleSizeCount = library.bubbleSizeCount
        burstSizes = library.burstSizes
        burstSizeCount = library.burstSizeCount
        self.sampleRate = sampleRate
        rateRatio = library.manifest.sampleRate / sampleRate
        self.seed = seed | 1

        let mix = library.manifest.mix
        masterGain = mix.masterGain
        panWidth = mix.panWidth
        // One-pole ramps rather than linear ones. A ramp that arrives is a corner in the
        // envelope; an exponential never quite does, and at these time constants "never quite"
        // is well under the dither floor.
        fadeInCoefficient = SoundCore.coefficient(seconds: mix.fadeIn / 3, rate: sampleRate)
        fadeOutCoefficient = SoundCore.coefficient(seconds: mix.fadeOut / 3, rate: sampleRate)
        // The stall fade is fast and separate, because it is answering a different question:
        // not "should ambience be playing" but "is this view still on screen at all". 30 ms,
        // which reads as immediate and still has no edge in it.
        stallCoefficient = SoundCore.coefficient(seconds: 0.03, rate: sampleRate)
        // A quarter second is comfortably longer than any legitimate hitch — a dropped frame, a
        // display reconfiguration, a shader compile — and far shorter than a person's patience
        // for a screensaver still making noise after they dismissed it.
        stallSamples = sampleRate * 0.25

        let bed = library.manifest.bed
        radiusMedian = bed.radiusMedian
        radiusSigma = bed.radiusSigma
        radiusMin = bed.radiusMin
        radiusMax = bed.radiusMax
        burstShare = bed.burstShare
        bubbleGain = bed.bubbleGain
        bedRate.store(bed.idleRate.bitPattern, ordering: .relaxed)

        let waterSpec = library.manifest.water
        brownCoefficient = Float(2 * Double.pi * 8 / sampleRate)
        highCoefficient = Float(2 * Double.pi * Double(waterSpec.low) / sampleRate)
        lowCoefficient = Float(2 * Double.pi * Double(waterSpec.high) / sampleRate)
        waterGain = waterSpec.gain * SoundCore.waterTrim
        waterLFO = waterSpec.lfoHz
        waterDepth = waterSpec.lfoDepth

        voiceCount = SoundCore.voicePoolSize
        voices = .allocate(capacity: voiceCount)
        voices.initialize(repeating: Voice(), count: voiceCount)
        triggers = .allocate(capacity: SoundCore.triggerCapacity)
        triggers.initialize(repeating: SoundTrigger(), count: SoundCore.triggerCapacity)
        discard = .allocate(capacity: SoundCore.maximumFrameCount)
        discard.initialize(repeating: 0, count: SoundCore.maximumFrameCount)

        water.left.seed = seed | 0x51
        water.right.seed = seed &* 0x2545_F491 | 0x77
    }

    /// Return to the state a freshly built core is in. Only safe once the engine has stopped.
    ///
    /// `gain` is render-thread state that decays *while the render thread runs*, so stopping an
    /// engine freezes it wherever it was — near 1.0 for something that was audible. Restarting
    /// on a configuration change then emits a first callback at full level after a stretch of
    /// digital silence, which is a step, which is a click, which is broadband. That is the one
    /// rule this whole feature keeps: ramp every gate change. Silencing the *target* is not
    /// enough when nothing is running to follow it.
    func reset() {
        gain = 0
        stallGain = 1
        samplesSinceFrame = 0
        lastSeenTick = -1
        for index in 0..<voiceCount { voices[index].active = false }
    }

    deinit {
        voices.deallocate()
        triggers.deallocate()
        discard.deallocate()
    }

    /// Calibration for the synthesised floor, measured rather than derived.
    ///
    /// The manifest states the water's level as a fraction of full scale, which is what the
    /// Python preview applies directly to a normalised band of brown noise. This filter chain
    /// is a different one — a one-pole integrator into a state-variable band-pass — so its
    /// output level for the same input is not the same number. The trim is what makes the saver
    /// and the preview agree, and it was set by recording the saver with
    /// `AQUARIUM_AUDIO_RECORD` and comparing band RMS against the preview's.
    private static let waterTrim: Float = 44.0

    // MARK: The main thread's half

    /// Queue a fish gesture. Called from the frame path; returns false if the ring is full.
    ///
    /// Full means the audio thread has not run since thirty-two triggers were pushed, which at
    /// the manifest's cooldowns cannot happen — so the drop is a backstop, not a policy.
    @discardableResult
    func push(_ trigger: SoundTrigger) -> Bool {
        let head = triggerHead.load(ordering: .relaxed)
        let next = (head + 1) % Int32(SoundCore.triggerCapacity)
        guard next != triggerTail.load(ordering: .acquiring) else { return false }
        triggers[Int(head)] = trigger
        // Release, so the write above is visible to the consumer before the index that
        // publishes it.
        triggerHead.store(next, ordering: .releasing)
        return true
    }

    /// Pick a grain for a bubble of this radius, and the rate that turns it into one.
    ///
    /// Resampling is the *physically correct* transform here rather than an approximation: a
    /// bubble's damping is dominated by radiation, radiation damping is 2*pi*f0*r/c, and f0*r
    /// is a constant — so ring-down time is exactly inversely proportional to frequency, which
    /// is what changing playback rate does. Playing a 1.5 mm bubble 20% fast *is* a 1.25 mm
    /// bubble. See `tools/audio/soundlib/bubble.py`.
    ///
    /// The ratio is still clamped, because the tank's response is baked into every grain and a
    /// resample stretches that too — a bubble may become a different bubble, but the tank may
    /// not become a different tank.
    private func pick(radiusMm: Float, from classes: UnsafeMutablePointer<GrainSizeClass>,
                      count: Int) -> (index: Int, rate: Double) {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for index in 0..<count {
            let distance = abs(log(max(classes[index].radiusMm, 1e-4) / max(radiusMm, 1e-4)))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        let sizeClass = classes[best]
        let ratio = min(max(sizeClass.radiusMm / max(radiusMm, 1e-4), 0.75), 1.33)
        let variant = Int(sizeClass.first) + Int(nextFloat() * Float(sizeClass.count))
        return (min(variant, Int(sizeClass.first) + Int(sizeClass.count) - 1),
                Double(ratio) * rateRatio)
    }

    // MARK: Render

    func render(frameCount: Int, left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>) {
        // The scratch channel is fixed-size, so a callback larger than it would run off the end
        // of it. CoreAudio asks for a few hundred frames in practice and an aggregate device is
        // the only plausible way past this ceiling.
        //
        // *Zeroed* rather than simply returned from. `AVAudioSourceNode` does not guarantee it
        // hands over a cleared buffer, so returning early leaves whatever was in that memory to
        // be played — uninitialised memory at full scale, which is the loudest possible failure
        // in a feature whose entire design is about avoiding broadband transients.
        guard frameCount <= SoundCore.maximumFrameCount else {
            left.update(repeating: 0, count: frameCount)
            right.update(repeating: 0, count: frameCount)
            oversizedCallbacks.wrappingAdd(1, ordering: .relaxed)
            return
        }
        drainTriggers()

        let tick = frameTick.load(ordering: .relaxed)
        if tick != lastSeenTick {
            lastSeenTick = tick
            samplesSinceFrame = 0
        } else {
            samplesSinceFrame += Double(frameCount)
        }
        let stalled = samplesSinceFrame > stallSamples
        let target = Float(bitPattern: gateTarget.load(ordering: .relaxed))
        let rate = Double(Float(bitPattern: bedRate.load(ordering: .relaxed)))

        for frame in 0..<frameCount {
            // Two independent envelopes. The session's is slow because ambience should arrive
            // and leave over seconds; the stall's is fast because it is answering "has this
            // view been thrown away".
            gain += (target - gain) * (target > gain ? fadeInCoefficient : fadeOutCoefficient)
            stallGain += ((stalled ? 0 : 1) - stallGain) * stallCoefficient

            // The bed. Poisson arrivals, so the gaps are exponential and no two bubbles ever
            // fall on a grid — which is what a regular rate with jitter always ends up sounding
            // like. Scheduled even while the gate is shut, so that opening it reveals a bed
            // already in progress rather than one starting from silence.
            untilNextBubble -= 1
            if untilNextBubble <= 0 {
                spawnBubble()
                untilNextBubble = nextExponential(perSecond: max(rate, 0.02)) * sampleRate
            }

            var mixLeft: Float = 0
            var mixRight: Float = 0
            for index in 0..<voiceCount where voices[index].active {
                let position = voices[index].position
                let sample = Int(position)
                if sample + 1 >= Int(voices[index].frames) {
                    voices[index].active = false
                    continue
                }
                let blend = Float(position - Double(sample))
                let base = (Int(voices[index].offset) + sample) * 2
                let l = samples[base] * (1 - blend) + samples[base + 2] * blend
                let r = samples[base + 1] * (1 - blend) + samples[base + 3] * blend
                mixLeft += l * voices[index].gainLeft
                mixRight += r * voices[index].gainRight
                voices[index].position = position + voices[index].rate
            }

            // The floor of moving water. Almost inaudible on its own, and it is what stops the
            // grains sounding like samples being triggered into digital silence.
            waterPhase += waterLFO / Float(sampleRate)
            if waterPhase > 1 { waterPhase -= 1 }
            let breathing = 1 - waterDepth * 0.5
                * (1 - cos(2 * Float.pi * waterPhase))
            mixLeft += waterSample(&water.left) * waterGain * breathing
            mixRight += waterSample(&water.right) * waterGain * breathing

            let level = gain * stallGain * masterGain
            // Soft clip rather than hard. The scheduler can put four bubbles inside one
            // ring-down and the sum is not bounded by anything; `tanh` costs a few nanoseconds
            // and cannot produce the broadband edge that hard clipping would.
            left[frame] = tanh(mixLeft * level)
            right[frame] = tanh(mixRight * level)
        }

        var live: Int32 = 0
        for index in 0..<voiceCount where voices[index].active { live += 1 }
        voicesInFlight.store(live, ordering: .relaxed)
        renderedFrames.wrappingAdd(Int64(frameCount), ordering: .relaxed)
    }

    // MARK: Scheduling

    private func drainTriggers() {
        var tail = triggerTail.load(ordering: .relaxed)
        let head = triggerHead.load(ordering: .acquiring)
        while tail != head {
            let trigger = triggers[Int(tail)]
            start(offset: trigger.offset, frames: trigger.frames,
                  rate: Double(trigger.rate) * rateRatio, gain: trigger.gain,
                  pan: trigger.pan)
            tail = (tail + 1) % Int32(SoundCore.triggerCapacity)
        }
        triggerTail.store(tail, ordering: .releasing)
    }

    private func spawnBubble() {
        // Log-normal, because bubble sizes off a porous stone are, and because the long tail is
        // what supplies the occasional low blorp that stops a bed sounding like rice on a drum.
        let radius = min(max(radiusMedian * exp(radiusSigma * nextNormal()),
                             radiusMin), radiusMax)

        let chosen: (index: Int, rate: Double)
        if burstSizeCount > 0 && nextFloat() < burstShare {
            chosen = pick(radiusMm: radius, from: burstSizes, count: burstSizeCount)
        } else {
            chosen = pick(radiusMm: radius, from: bubbleSizes, count: bubbleSizeCount)
        }

        let slice = grains[chosen.index]
        guard slice.frames > 1 else {
            bubblesDropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        // A stream is a column, not a point: bubbles rising off one stone still arrive from
        // slightly different places and distances as they climb.
        let placed = start(offset: slice.offset, frames: slice.frames, rate: chosen.rate,
                           gain: slice.gain * bubbleGain * (0.55 + 0.45 * nextFloat()),
                           pan: (nextFloat() * 2 - 1) * panWidth)
        if placed {
            bubblesPlaced.wrappingAdd(1, ordering: .relaxed)
        } else {
            bubblesDropped.wrappingAdd(1, ordering: .relaxed)
        }
    }

    @discardableResult
    private func start(offset: Int32, frames: Int32, rate: Double, gain: Float,
                       pan: Float) -> Bool {
        var slot = -1
        for index in 0..<voiceCount where !voices[index].active {
            slot = index
            break
        }
        guard slot >= 0 else { return false }

        // Constant power, so a grain does not get quieter as it moves off centre. The pan is
        // narrow by design — sound travels at 1480 m/s in water, so the delay across a head is
        // about 40 microseconds and a submerged listener localises very poorly. A hard pan is
        // an air cue and it would undo the work the baked space does.
        let angle = (min(max(pan, -1), 1) + 1) * Float.pi / 4
        voices[slot] = Voice(offset: offset, frames: frames, position: 0, rate: rate,
                             gainLeft: cos(angle) * 1.414_2 * gain,
                             gainRight: sin(angle) * 1.414_2 * gain,
                             active: true)
        return true
    }

    // MARK: Synthesis and noise

    /// Brown noise into a state-variable band-pass. Two multiply-adds a sample, and it never
    /// repeats — which is the whole reason the floor is synthesised rather than baked. A
    /// stationary texture has no events to schedule, so as a file it would have to be a loop,
    /// and a loop is the one thing this design refuses.
    private func waterSample(_ channel: inout WaterChannel) -> Float {
        channel.seed = channel.seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let white = Float(Int32(truncatingIfNeeded: channel.seed >> 33)) / 1_073_741_824.0

        // -6 dB/octave above 8 Hz: the spectrum of moving water rather than of a hiss.
        channel.brown += (white - channel.brown) * brownCoefficient

        var value = channel.brown
        channel.high.0 += (value - channel.high.0) * highCoefficient
        value -= channel.high.0
        channel.high.1 += (value - channel.high.1) * highCoefficient
        value -= channel.high.1
        channel.high.2 += (value - channel.high.2) * highCoefficient
        value -= channel.high.2

        // One pole up here, three down below. Brown noise is -6 dB/octave of spectrum,
        // which is only -3 dB/octave of band energy, and the reference recording falls a
        // measured 6 dB per octave in band terms — so one more pole, not two.
        channel.low += (value - channel.low) * lowCoefficient
        return channel.low
    }

    private func nextFloat() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Float(seed >> 40) * (1.0 / 16_777_216.0)
    }

    private func nextExponential(perSecond rate: Double) -> Double {
        -log(Double(max(nextFloat(), 1e-6))) / rate
    }

    /// Box-Muller. Two logs and a cosine per pair, which at a few dozen bubbles a second is
    /// nothing, and it is the only way to get the log-normal the radius distribution wants.
    private func nextNormal() -> Float {
        let u = max(nextFloat(), 1e-6)
        let v = nextFloat()
        return (-2 * log(u)).squareRoot() * cos(2 * Float.pi * v)
    }

    private static func coefficient(seconds: Float, rate: Double) -> Float {
        Float(1 - exp(-1 / (Double(max(seconds, 0.001)) * rate)))
    }
}
