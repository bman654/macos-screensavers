// What is standing underneath, and beside, a given point of water.
//
// It exists for two behaviours. A fish that finds a surface below it tips nose-down and works
// along it, the way a real fish picks at gravel, a rock or a frond — that needs a height. And a
// fish approaching something tall should go *round* it rather than over it — that needs a
// direction, and it is the whole reason this returns more than a number.
//
// Heights are **above the floor plane**, not in world coordinates, which is what lets the field
// be built once at launch and survive a reshape: `Tank.floorY` moves with the drawable's aspect
// ratio and every prop moves with it, so the difference between them does not change. The
// caller adds the floor. Positions are the seabed's x and z, which are the world's x and z —
// the seabed node only ever translates in Y.

import Foundation
import simd

struct SurfaceField {
    /// One prop reduced to what a query needs. Held as a flat array of values rather than as
    /// references to `PropInstance`, because this is walked per fish per step.
    private struct Mound {
        let center: SIMD2<Float>
        let radius: Float
        let radiusSquared: Float
        let height: Float
        /// How much this prop is a thing to swim *around* rather than *over*.
        ///
        /// Height against footprint, and it is the difference between a boulder and a stand of
        /// giant kelp. A wide low rock is scenery a fish passes above without noticing; a tall
        /// narrow plant is a wall. Treating both as domes to be climbed is what sent a fish up
        /// the side of a kelp — a dome that rises two metres over a few centimetres of ground is
        /// not a slope, it is a cliff.
        let steepness: Float
    }

    private let mounds: [Mound]

    /// Beyond this ratio of height to footprint a prop is treated as fully a wall. Chosen so the
    /// library's rocks and corals sit well below it and its kelp sits well above.
    private static let maxSteepness: Float = 2.5

    /// What is left of a prop's sideways repulsion once it declares a way through itself.
    ///
    /// **A prop with a passage is mostly hole, and a dome is the wrong model for it.** The arch is
    /// 0.86 m of footprint around an opening a fish is meant to use, so treating it as a solid
    /// mound gave it a shove of 1.09 — comparable to a pane of glass — and fish visibly turned
    /// away from the one prop built to be swum through. Nearly all of it is removed rather than
    /// all: enough remains to discourage a fish from settling inside a leg of the arch, and the
    /// route's own declared clearance is what keeps a transiting fish off the geometry.
    private static let passableSideShare: Float = 0.15

    init(props: [PropInstance]) {
        mounds = props.compactMap { prop in
            let radius = prop.radius
            let height = prop.height
            // A prop with no declared extent has nothing to stand on. It is still drawn; it is
            // simply not something a fish can be interested in the top of.
            guard radius > 0, height > 0 else { return nil }
            let solidity = prop.manifest.passages.isEmpty
                ? 1
                : SurfaceField.passableSideShare
            return Mound(center: prop.groundPosition, radius: radius,
                         radiusSquared: radius * radius, height: height,
                         steepness: min(height / radius, SurfaceField.maxSteepness)
                            / SurfaceField.maxSteepness * solidity)
        }
    }

    struct Sample {
        /// How high the highest thing under the point reaches above the floor.
        let height: Float
        /// A push away from anything tall the point is inside, in the floor plane. Unnormalized:
        /// it grows toward the centre of a footprint and toward the steeper props.
        let outward: SIMD2<Float>
    }

    func sample(x: Float, z: Float) -> Sample {
        let point = SIMD2<Float>(x, z)
        var top: Float = 0
        var outward = SIMD2<Float>(repeating: 0)
        for mound in mounds {
            let offset = point - mound.center
            let distanceSquared = simd_length_squared(offset)
            guard distanceSquared < mound.radiusSquared else { continue }
            let fraction = sqrt(distanceSquared / mound.radiusSquared)
            // A dome rather than a flat-topped cylinder, because a cylinder gives a fish a rim to
            // fall off: one tracking the surface would drop its nose by the prop's full height
            // between one frame and the next.
            top = max(top, mound.height * sqrt(max(0, 1 - fraction * fraction)))
            guard mound.steepness > 0 else { continue }
            // Deeper inside the footprint pushes harder. A fish exactly on the axis gets nothing
            // from this term rather than an arbitrary direction — it is already committed, and
            // inventing a way out for it would be a discontinuity every neighbouring fish sees.
            let weight = (1 - fraction) * mound.steepness
            if distanceSquared > 1e-8 {
                outward += simd_normalize(offset) * weight
            }
        }
        return Sample(height: top, outward: outward)
    }

    /// Just the height, for callers that do not care which way to go round.
    func height(x: Float, z: Float) -> Float { sample(x: x, z: z).height }
}
