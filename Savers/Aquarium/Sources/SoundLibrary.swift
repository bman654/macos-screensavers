// The baked grains, in the layout the audio thread needs them in.
//
// `tools/build-audio.py` writes `Assets/audio/*.wav` plus a `manifest.json` that carries both
// the grain table and every number that shapes the mix. Both this and `tools/audio-preview.py`
// read that manifest, which is what makes the preview an honest rehearsal of the saver rather
// than a separate instrument that happens to sound similar.
//
// **Everything the render callback touches is a C array, deliberately.** Swift arrays and
// strings are heap objects, and reading one across a class boundary can emit a retain/release
// pair — which takes a lock in the runtime and can therefore block the audio thread behind an
// unrelated allocation. So the grain audio is one contiguous float buffer and the tables that
// index it are `UnsafeMutablePointer`s of trivial structs, all built once here, on the main
// thread, before the engine starts.

import AVFoundation
import Foundation

/// One grain's extent inside the shared sample buffer.
struct GrainSlice {
    var offset: Int32
    var frames: Int32
    /// The level the synthesis authored for it, relative to the loudest of its family.
    ///
    /// Every file is stored at full scale so the whole sixteen-bit word carries sound; the
    /// relation between bubble size and loudness lives here instead. See `_level_family` in
    /// `tools/build-audio.py`.
    var gain: Float
    var radiusMm: Float
}

/// The variants of one baked size, as a range into the grain table.
struct GrainSizeClass {
    var radiusMm: Float
    var first: Int32
    var count: Int32
}

struct SoundManifest: Decodable {
    struct Grain: Decodable {
        let name: String
        let family: String
        let file: String
        let gain: Float
        let frames: Int
        let radiusMm: Float?
    }
    struct Bed: Decodable {
        let rateScale: Float
        let maxRate: Float
        let idleRate: Float
        let radiusMedian: Float
        let radiusSigma: Float
        let radiusMin: Float
        let radiusMax: Float
        let burstShare: Float
        let bubbleGain: Float
    }
    struct Water: Decodable {
        let low: Float
        let high: Float
        let gain: Float
        let lfoHz: Float
        let lfoDepth: Float
    }
    struct Fish: Decodable {
        let minEffort: Float
        let turnShare: Float
        let fishCooldown: Float
        let tankCooldown: Float
        let swishGain: Float
        let dartGain: Float
        let rateMin: Float
        let rateMax: Float
    }
    struct Mix: Decodable {
        let panWidth: Float
        let masterGain: Float
        let fadeIn: Float
        let fadeOut: Float
    }

    let sampleRate: Double
    let referenceBodyLength: Float
    let grains: [Grain]
    let bed: Bed
    let water: Water
    let fish: Fish
    let mix: Mix
}

final class SoundLibrary {

    let manifest: SoundManifest

    /// Interleaved stereo, every grain end to end. Owned here and freed in `deinit`.
    let samples: UnsafeMutablePointer<Float>
    let grains: UnsafeMutablePointer<GrainSlice>
    /// How many of `grains` are playable. Unreadable files are dropped rather than kept as
    /// empty slices, so every index in `0..<grainCount` names real audio.
    let grainCount: Int

    let bubbleSizes: UnsafeMutablePointer<GrainSizeClass>
    let bubbleSizeCount: Int
    let burstSizes: UnsafeMutablePointer<GrainSizeClass>
    let burstSizeCount: Int

    let swishFirst: Int
    let swishCount: Int
    let dartFirst: Int
    let dartCount: Int

    private let sampleCapacity: Int

    /// Nil rather than throwing when the library is absent, because that is a normal state:
    /// `Assets/audio/` is build output and is not tracked, exactly like the model library. A
    /// clone that has not run `tools/build-audio.py` gets a silent tank, not a broken one.
    init?(bundle: Bundle) {
        guard let manifestURL = bundle.url(forResource: "manifest", withExtension: "json",
                                           subdirectory: "audio"),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SoundManifest.self, from: data)
        else { return nil }
        self.manifest = manifest

        // Grains are ordered by family here so that every family is a contiguous range and the
        // audio thread can pick one with two integers instead of a lookup.
        let ordered = SoundLibrary.order(manifest.grains)
        guard !ordered.isEmpty else { return nil }

        // Clamped, because the declared count sizes the allocation the WAV is then read into.
        // A negative one in a hand-edited or truncated manifest would *shrink* the buffer while
        // a later readable grain still wrote its full length into it — a heap overflow inside a
        // screensaver host, from a data file. The generated manifest never contains one; that
        // is exactly why it would never be noticed.
        let declared = ordered.map { max($0.frames, 0) }
        let total = declared.reduce(0, +)
        sampleCapacity = total * 2
        samples = .allocate(capacity: max(sampleCapacity, 2))
        samples.initialize(repeating: 0, count: max(sampleCapacity, 2))

        grains = .allocate(capacity: ordered.count)

        var cursor = 0
        var playable: [SoundManifest.Grain] = []
        for (entry, capacity) in zip(ordered, declared) {
            guard capacity > 1,
                  let url = bundle.url(forResource: (entry.file as NSString)
                                        .deletingPathExtension,
                                       withExtension: "wav", subdirectory: "audio"),
                  let frames = SoundLibrary.read(url, into: samples + cursor * 2,
                                                 capacity: capacity),
                  frames > 1
            else {
                // One unreadable grain must not take the whole library down, and it must not
                // stay in the tables either. Leaving a zero-frame slice in them was the first
                // pass, and it fails quietly in the worst way: the scheduler goes on picking
                // that variant with the same probability as the others and then places nothing,
                // so a corrupt bundle produces a bed that is simply thinner than it should be,
                // with no counter anywhere showing why.
                continue
            }
            grains[playable.count] = GrainSlice(offset: Int32(cursor), frames: Int32(frames),
                                                gain: entry.gain,
                                                radiusMm: entry.radiusMm ?? 0)
            cursor += capacity
            playable.append(entry)
        }
        grainCount = playable.count

        (bubbleSizes, bubbleSizeCount) = SoundLibrary.sizeClasses(of: "bubble", in: playable)
        (burstSizes, burstSizeCount) = SoundLibrary.sizeClasses(of: "burst", in: playable)
        (swishFirst, swishCount) = SoundLibrary.range(of: "swish", in: playable)
        (dartFirst, dartCount) = SoundLibrary.range(of: "dart", in: playable)

        guard bubbleSizeCount > 0 else { return nil }
    }

    deinit {
        samples.deallocate()
        grains.deallocate()
        bubbleSizes.deallocate()
        burstSizes.deallocate()
    }

    // MARK: Building the tables

    private static let familyOrder = ["bubble", "burst", "swish", "dart"]

    private static func order(_ grains: [SoundManifest.Grain]) -> [SoundManifest.Grain] {
        grains
            .filter { familyOrder.contains($0.family) }
            .sorted {
                let left = (familyOrder.firstIndex(of: $0.family) ?? 0,
                            $0.radiusMm ?? 0, $0.name)
                let right = (familyOrder.firstIndex(of: $1.family) ?? 0,
                             $1.radiusMm ?? 0, $1.name)
                return left < right
            }
    }

    private static func range(of family: String,
                              in ordered: [SoundManifest.Grain]) -> (Int, Int) {
        let indices = ordered.indices.filter { ordered[$0].family == family }
        return (indices.first ?? 0, indices.count)
    }

    private static func sizeClasses(of family: String, in ordered: [SoundManifest.Grain])
        -> (UnsafeMutablePointer<GrainSizeClass>, Int) {
        var classes: [GrainSizeClass] = []
        for (index, entry) in ordered.enumerated() where entry.family == family {
            let radius = entry.radiusMm ?? 0
            if var last = classes.last, abs(last.radiusMm - radius) < 1e-4 {
                last.count += 1
                classes[classes.count - 1] = last
            } else {
                classes.append(GrainSizeClass(radiusMm: radius, first: Int32(index), count: 1))
            }
        }
        let storage = UnsafeMutablePointer<GrainSizeClass>.allocate(
            capacity: max(classes.count, 1))
        for (index, value) in classes.enumerated() { storage[index] = value }
        return (storage, classes.count)
    }

    /// Read a WAV into interleaved stereo at `destination`. Returns frames written.
    ///
    /// Mono files are duplicated rather than refused. The bake writes stereo, but a grain
    /// hand-made for a test should not have to be.
    private static func read(_ url: URL, into destination: UnsafeMutablePointer<Float>,
                             capacity: Int) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = min(Int(file.length), capacity)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              (try? file.read(into: buffer, frameCount: AVAudioFrameCount(frames))) != nil,
              let channels = buffer.floatChannelData
        else { return nil }

        let available = Int(buffer.frameLength)
        let right = format.channelCount > 1 ? channels[1] : channels[0]
        for frame in 0..<available {
            destination[frame * 2] = channels[0][frame]
            destination[frame * 2 + 1] = right[frame]
        }
        return available
    }
}
