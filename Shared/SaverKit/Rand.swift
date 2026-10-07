// The seeded RNG every saver draws its scene from.
//
// Split out of the Aquarium's `Tank` when the tank became a value (the tank's *dimensions* are
// one of the things this draws, so it could no longer live inside them), and moved into SaverKit
// when Origami Dogfight became the second saver to need it. The stream itself is unchanged by the
// move — every seed on record still names the tank, or the fight, it always did.

import Foundation

/// Seeded so a layout that looked right in a render is the same layout next launch; tuning
/// numbers against a scene that reshuffles every run is guesswork.
struct Rand {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }

    mutating func inRange(_ lower: Float, _ upper: Float) -> Float {
        lower + (upper - lower) * next()
    }

    mutating func sign() -> Float { next() < 0.5 ? -1 : 1 }

    /// A stream of its own, so that consuming more numbers in one part of the tank does not
    /// reshuffle another. Without it, adding one prop restyles the entire school.
    mutating func fork() -> Rand {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Rand(seed: state ^ 0xD1B5_4A32_D192_ED03)
    }

    /// A uniform index into `count` items.
    ///
    /// The clamp is the point: `next()` is documented as below 1, but one rounding away from it
    /// would index off the end, and this is drawn per fish and per prop rather than once.
    mutating func index(count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(Int(next() * Float(count)), count - 1)
    }

    /// Index into `items` with probability proportional to `weight`. Returns nil only when
    /// every candidate weighs nothing, which is the caller's cue that the pool is exhausted
    /// rather than a reason to trap.
    mutating func weightedIndex<T>(_ items: [T], weight: (T) -> Float) -> Int? {
        let total = items.reduce(Float(0)) { $0 + max(0, weight($1)) }
        guard total > 0 else { return nil }
        var ticket = next() * total
        for (index, item) in items.enumerated() {
            ticket -= max(0, weight(item))
            if ticket <= 0 { return index }
        }
        return items.indices.last
    }
}
