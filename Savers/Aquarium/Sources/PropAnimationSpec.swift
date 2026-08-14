// What a prop *does* once it has been placed: which of its parts turn, where it lets go of
// bubbles, the cycle that drives both, and the routes a fish may swim through it.
//
// `docs/decorations.md` is the contract and `Models/props/_spec.py` is the emitter; this is only
// the decoder. It is split out of `ModelLibrary` because that file answers "where does this
// stand", which every launch needs, and this one answers "what does it do", which only the four
// animated props and the three with holes in them have an answer to.
//
// Every type here decodes defensively, and that is not politeness. `ModelLibrary.load` wraps a
// manifest decode in `try?`, so one thrown error does not skip a field — it skips the whole
// model, and a chest that silently stops appearing in the tank reads as a broken asset rather
// than as a typo in one JSON key.

import Foundation
import simd

// MARK: - Parts

/// A rigid part that turns about its own origin, which Blender wrote as the node's transform —
/// so hinging one is a node rotation with no pivot metadata to carry across. See
/// `spikes/004-articulated-decor/`.
struct PartSpec: Decodable {
    let node: String
    /// In the model's own space, which is Blender's Z-up. The part node is *inside* the tank's
    /// -π/2 correction, so this axis is used verbatim and never rotated.
    let axis: SIMD3<Float>
    /// What a cycle's `to: 1.0` means. Stated here rather than in the cycle so the angle can be
    /// retuned without rewriting the timing, which is the whole reason the cycle is normalized.
    let openDegrees: Float

    var openRadians: Float { openDegrees * .pi / 180 }

    private enum CodingKeys: String, CodingKey { case node, axis, openDegrees }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decode(String.self, forKey: .node)
        let raw = try container.decodeIfPresent([Float].self, forKey: .axis) ?? [1, 0, 0]
        // A short or malformed axis becomes X rather than a zero vector: a zero axis is a
        // rotation SceneKit accepts and does nothing with, which looks like a part that failed
        // to move for a reason somewhere else entirely.
        let axis = SIMD3<Float>(raw.count > 0 ? raw[0] : 1,
                                raw.count > 1 ? raw[1] : 0,
                                raw.count > 2 ? raw[2] : 0)
        self.axis = simd_length(axis) > 0 ? simd_normalize(axis) : SIMD3<Float>(1, 0, 0)
        openDegrees = try container.decodeIfPresent(Float.self, forKey: .openDegrees) ?? 60
    }
}

// MARK: - Emitters

/// Where a prop lets go of bubbles. An empty in the model, so it can be authored on the moving
/// part and ride along with it.
struct EmitterSpec: Decodable {
    let node: String
    /// Bubbles per second at scale 1.0.
    let rate: Float
    /// The radius of the mouth they leave from, in metres.
    let radius: Float
    /// Bubble diameter range, in metres.
    let size: Span
    /// How fast they leave, in metres per second. They are slowed and spread on the way up by
    /// the stream itself — see `BubbleStream`.
    let speed: Float
    /// A vent bubbles for as long as the tank is running and has no cycle to be driven by.
    let continuous: Bool

    private enum CodingKeys: String, CodingKey {
        case node, rate, radius, size, speed, continuous
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decode(String.self, forKey: .node)
        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? 40
        radius = try container.decodeIfPresent(Float.self, forKey: .radius) ?? 0.012
        size = try container.decodeIfPresent(Span.self, forKey: .size) ?? Span(0.002, 0.005)
        speed = try container.decodeIfPresent(Float.self, forKey: .speed) ?? 0.09
        continuous = try container.decodeIfPresent(Bool.self, forKey: .continuous) ?? false
    }
}

// MARK: - The cycle

/// A `duration`: a number, or a `[min, max]` pair sampled fresh on every pass through the cycle.
///
/// The range is not decoration. Several chests on screen opening in lockstep is the single most
/// mechanical-looking failure available here, and a fixed duration guarantees it for any two
/// props that started together — which, on a launch, is all of them.
struct Duration: Decodable {
    let span: Span

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(Float.self) {
            span = Span(value, value)
        } else {
            span = try Span(from: decoder)
        }
    }

    func sample(_ rand: inout Rand) -> Float { max(0, span.sample(&rand)) }
}

/// How a part's angle is carried from one value to the next. Unknown names ease in and out
/// rather than throwing, for the reason at the top of this file.
enum Ease: String, Decodable {
    case linear, easeIn, easeOut, easeInOut

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Ease(rawValue: raw) ?? .easeInOut
    }

    func apply(_ t: Float) -> Float {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return t * (2 - t)
        case .easeInOut: return t * t * (3 - 2 * t)
        }
    }
}

/// One step of a prop's cycle. The three kinds are deliberately not a sum type carrying their
/// own payloads: the manifest is flat JSON written by a Python emitter, and a phase that names a
/// part it has no business naming is harmless — the player only reads the fields its kind uses.
struct CyclePhase: Decodable {
    enum Kind: String, Decodable {
        /// Nothing moves. Where the randomised waiting lives.
        case idle
        /// A part travels to `to`.
        case move
        /// An emitter runs. Whatever a previous `move` left open stays open.
        case emit

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .idle
        }
    }

    let phase: Kind
    let duration: Duration
    let part: String?
    /// Normalized against the part's own `openDegrees`, so 0 is shut and 1 is fully open.
    let to: Float?
    let emitter: String?
    let ease: Ease

    private enum CodingKeys: String, CodingKey { case phase, duration, part, to, emitter, ease }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(Kind.self, forKey: .phase) ?? .idle
        duration = try container.decodeIfPresent(Duration.self, forKey: .duration)
            ?? Duration(seconds: 1)
        part = try container.decodeIfPresent(String.self, forKey: .part)
        to = try container.decodeIfPresent(Float.self, forKey: .to)
        emitter = try container.decodeIfPresent(String.self, forKey: .emitter)
        ease = try container.decodeIfPresent(Ease.self, forKey: .ease) ?? .easeInOut
    }
}

extension Duration {
    init(seconds: Float) { span = Span(seconds, seconds) }
}

// MARK: - Passages

/// A way *through* a prop, as ordered waypoints. A wreck's hull is a closed mesh whether or not
/// there is a route inside it and nothing downstream can infer one from geometry, so the model
/// states it.
struct PassageSpec: Decodable {
    let nodes: [String]
    /// The tightest clearance anywhere along the route, which is what decides which species fit.
    /// Authors are asked to under-declare it: a fish declining a gap it would have made is much
    /// cheaper than a fish clipping through a hull.
    let radius: Float

    private enum CodingKeys: String, CodingKey { case nodes, radius }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([String].self, forKey: .nodes) ?? []
        radius = try container.decodeIfPresent(Float.self, forKey: .radius) ?? 0.2
    }
}
