// The volume of water everything else is placed in, and the seeded RNG that places it.
//
// Split out of `AquariumScene` because the floor, the reef and the school all measure
// themselves against these numbers, and every one of them has to take the *real* drawable's
// aspect ratio rather than assume one.

import AppKit
import Foundation
import simd

enum Tank {
    /// Narrow enough to read as near-orthographic 2.5D, wide enough that the depth lanes
    /// still show parallax. Fixed by `docs/aquarium-plan.md`.
    static let fieldOfView: CGFloat = 22
    static let halfFOVTangent = Float(tan(fieldOfView * .pi / 180 / 2))

    /// `projectionDirection` is pinned horizontal, so the horizontal extent is fixed by the
    /// field of view alone and it is the *vertical* extent that shrinks as the drawable gets
    /// wider — half-height is exactly half-width divided by the aspect ratio, verified against
    /// the matrix `SCNCamera.projectionTransform(withViewportSize:)` actually builds. Vertical
    /// placement therefore has to come from the real drawable: on a 32:9 display the visible
    /// half-height is barely half of what 16:9 gives, and fish laid out against an assumed
    /// 16:9 spend whole crossings outside the frame.
    static let verticalFill: Float = 0.62

    /// Used only for a degenerate drawable size, which `SaverView` should never hand over.
    static let fallbackAspect: Float = 16.0 / 9.0

    /// Depth range the school occupies, in metres in front of the camera. The near limit is
    /// far enough back that a fish leaving the tank does so off-screen rather than popping.
    static let nearDepth: Float = 5.5
    static let farDepth: Float = 25.0
    static let depthCullNear: Float = 4.6
    static let depthCullFar: Float = 27.0

    /// Screen-space speed is what the eye judges, and that is angular — so world speed has to
    /// grow with depth or the far fish crawl.
    static let speedPerDepth: Float = 0.023

    static let water = (red: 0.028, green: 0.094, blue: 0.112)
    static let waterColor = NSColor(calibratedRed: CGFloat(water.red), green: CGFloat(water.green),
                                    blue: CGFloat(water.blue), alpha: 1)

    static let fogStart = nearDepth * 0.8
    static let fogEnd = farDepth * 1.05

    // MARK: The floor

    /// The depth at which the sand meets the bottom edge of the frame — i.e. the floor is set
    /// exactly one half-height below the eye *at this depth*, so nearer sand is below the frame
    /// and further sand climbs toward the horizon.
    ///
    /// Stating it as a depth rather than as a height is what makes the tank aspect-invariant.
    /// The sand's screen position at depth `d` works out to `-floorEntryDepth / d` in normalized
    /// device coordinates, with the aspect ratio cancelling — so a 32:9 drawable shows the same
    /// beach line as a 16:9 one instead of the reef sliding off the bottom, which is what a
    /// fixed height in metres would do. Everything standing on the floor inherits that for free.
    static let floorEntryDepth: Float = 6.2

    /// Past `fogEnd`, so the far edge of the sand is fully fogged out and there is no rim where
    /// the floor simply stops. The same reason the background and the fog colour must agree.
    static let floorFarDepth: Float = 34

    /// Negative: the floor is below the eye. Derived from the drawable, never assumed.
    static func floorY(aspect: Float) -> Float {
        -halfHeight(atDepth: floorEntryDepth, aspect: aspect)
    }

    /// The far end of the depth band the reef is scattered through.
    ///
    /// It stops a long way short of `fogEnd`, and that is the floor's doing rather
    /// than the fog's: perspective compresses everything past about 15 m into the last few
    /// degrees before the horizon, so the floor there crosses from lit to fully fogged within
    /// a hand's width of screen. A prop beyond that stands on ground which has already
    /// dissolved into the background, and reads as hanging in the water — the sunken ship did
    /// exactly that at 21 m. Keeping the reef where its own floor is still visible is what
    /// seats it.
    static let reefFarDepth: Float = 18.5

    /// The nearest a prop may stand, which — unlike the floor — is not aspect-invariant.
    ///
    /// On a 16:9 drawable this sits *inside* `floorEntryDepth`, so the nearest props stand on
    /// floor that is already below the frame and are cropped by the bottom edge. Stopping the
    /// reef where the floor starts leaves an empty bright apron of sand across the bottom of
    /// the frame, and something crossing that edge is what gives the tank a foreground.
    ///
    /// A wider drawable has a shorter frustum at every depth, though, and a prop is the one
    /// thing in the tank whose size is fixed in metres by its author. On 32:9 the frame is only
    /// 0.77 m tall at 7 m, so a boulder that crops nicely on 16:9 is taller than the whole
    /// frame. The near limit is therefore the depth at which the frame is tall enough to hold a
    /// prop, and the fixed limit applies only once that is satisfied.
    static func reefNearDepth(aspect: Float) -> Float {
        max(floorEntryDepth - 0.7, reefMinHalfHeight * aspect / halfFOVTangent)
    }

    /// Half the frame height a prop needs, in metres: about a boulder at full scale.
    private static let reefMinHalfHeight: Float = 0.45

    /// How far above the sand a fish may be placed, as a multiple of its own length. Fish hold
    /// their world height for a whole crossing, so this is a spawn constraint rather than a
    /// collision response — it only has to be big enough that the bob never dips into sand.
    static let fishFloorClearance: Float = 1.6

    // MARK: Frustum

    static func halfWidth(atDepth depth: Float) -> Float { depth * halfFOVTangent }

    static func halfHeight(atDepth depth: Float, aspect: Float) -> Float {
        halfWidth(atDepth: depth) / aspect
    }

    static func aspect(of drawableSize: CGSize) -> Float {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return fallbackAspect }
        return Float(drawableSize.width / drawableSize.height)
    }
}

// MARK: - Deterministic RNG

/// Seeded so a layout that looked right in a render is the same layout next launch; tuning
/// numbers against a school that reshuffles every run is guesswork.
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
