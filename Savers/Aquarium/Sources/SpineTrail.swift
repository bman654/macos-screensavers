// The path a lurker's head has taken, kept so that its body can be laid along it.
//
// A snake is its own trail: every part of the animal passes through where the head was, so the
// shape of the body at any moment *is* the recent path of the head, S-bends included. A
// constant-curvature arc — the first thing built for the eel — cannot say that: it bends the
// mesh but the node still pivots rigidly about its centre, so the head swings one way, the tail
// sweeps the other, and a curved body pivoting as a unit reads as a bent log. Judged on the
// installed build as "he still just kind of turns like a log", and the census agreed: the arc
// was saturated at its 1.7 rad ceiling for seconds at a time and nobody could see it.
//
// So the head is the animal's position, the school records where it goes, and the shader puts
// every vertex on that record at the vertex's own distance behind the nose. Nothing here is
// species-specific except that only a lurker carries one.

import Foundation
import SceneKit
import simd

/// A ring of points spaced evenly along the head's path, newest first, and the resampling that
/// turns them into the fixed grid of samples the shader reads.
///
/// **Knots are laid at a fixed chord `spacing` behind the head.** A knot is planted whenever the
/// head has moved a full spacing past the last one, so the ring is a polyline of equal chords
/// and the head sits somewhere in the first one. The samples the shader wants are at exact
/// multiples of the spacing measured back *from the head*, which makes the resample a single
/// interpolation weight shared by every sample: `sample[i] = lerp(knot[i-1], knot[i], f)`
/// where `f` is how far the head is from planting the next knot. As the head advances the
/// samples slide forward along the polyline, and when a knot is planted the indices shift by
/// one and the weight wraps to zero — continuous, which is what keeps the body from
/// stepping.
struct SpineTrail {
    /// Samples handed to the shader per fish, three floats each, packed end to end through the
    /// sixteen floats of each of `matrixCount` `float4x4`s — there is no other way to deliver
    /// an array to a SceneKit shader modifier, and there are only sixteen because the block of
    /// custom arguments breaks past 256 bytes. Both measured; see `SwimDeformation`. The
    /// shader draws a spline through them, so sixteen over `coverage` body lengths — one sample
    /// every thirteenth of the animal — is smooth.
    static let sampleCount = 16
    static let matrixCount = 3
    /// Which sample the tail tip lands on. The shader's Catmull-Rom needs two samples *behind*
    /// the segment it is evaluating, so the last two exist for the tip alone.
    static let tipSample = sampleCount - 3
    /// How much of the animal the samples cover, in body lengths. More than one, because of the
    /// two above — and exactly this much rather than a round number, so that the tip lands on
    /// `tipSample` and every sample the block carries is read. Coverage beyond that is spacing
    /// spent on path the body never reaches, and a sample nothing reads is a sample wasted out
    /// of sixteen that a 256-byte block will not extend.
    static let coverage = Float(sampleCount - 1) / Float(tipSample)

    /// World metres between consecutive samples, and between knots.
    let spacing: Float
    private var knots: [SIMD3<Float>]
    /// Index of the newest knot in the ring.
    private var newest = 0
    private var seeded = false
    private(set) var head = SIMD3<Float>(repeating: 0)
    /// The last heading recorded. Kept only so that an *unseeded* trail can still answer
    /// `samples()` with a straight body: sixteen coincident points give the shader's spline a
    /// zero derivative, `normalize` of which is a NaN that reaches every vertex of the fish.
    private var facing = SIMD3<Float>(1, 0, 0)

    init(bodyLength: Float) {
        spacing = SpineTrail.coverage * bodyLength / Float(SpineTrail.sampleCount - 1)
        knots = Array(repeating: SIMD3<Float>(repeating: 0), count: SpineTrail.sampleCount)
    }

    /// Forgets the path. The next `record` lays a straight body behind the head, which is what
    /// a fish that has just been placed should have.
    mutating func clear() { seeded = false }

    /// Where the head is now, and which way it is facing — the facing is only used to seed a
    /// straight body when there is no path yet.
    mutating func record(head: SIMD3<Float>, forward: SIMD3<Float>) {
        self.head = head
        if simd_length(forward) > 1e-6 { facing = simd_normalize(forward) }
        if !seeded {
            let back = -facing
            for i in 0..<knots.count {
                knots[i] = head + back * (spacing * Float(i))
            }
            newest = 0
            seeded = true
            return
        }
        // Plant knots until the head is within one spacing of the newest. Normally zero or one
        // per step; a stall that moves the head a long way lays a straight run behind it, which
        // is the least wrong shape for a gap nothing was recorded across.
        var planted = 0
        while planted < knots.count {
            let last = knots[newest]
            let gap = head - last
            let distance = simd_length(gap)
            if distance < spacing { break }
            newest = (newest + knots.count - 1) % knots.count
            knots[newest] = last + gap * (spacing / distance)
            planted += 1
        }
    }

    private func knot(_ i: Int) -> SIMD3<Float> {
        knots[(newest + i) % knots.count]
    }

    /// Moves a recorded path with a floor that has moved under it.
    ///
    /// A reshape rescales the whole water column about the floor, and the head is rescaled with
    /// every other fish's position — so the path has to go with it or the next frame draws a body
    /// stretching from the new head to the old trail. Transformed rather than cleared, because
    /// clearing straightens the animal: an eel mid-turn would snap to a rod on a window resize.
    ///
    /// The chords are no longer exactly `spacing` afterwards, since only y is scaled. That
    /// resolves itself within a body length of swimming — `record` plants the next knot on the
    /// real distance and the resample's weight is clamped — and a slightly uneven body for a
    /// second is a far smaller error than a straight one.
    mutating func rescale(oldFloor: Float, newFloor: Float, scale: Float) {
        head.y = newFloor + (head.y - oldFloor) * scale
        for i in knots.indices { knots[i].y = newFloor + (knots[i].y - oldFloor) * scale }
    }

    /// The path as `sampleCount` points at exact multiples of `spacing` behind the head, the
    /// head itself first.
    func samples() -> [SIMD3<Float>] {
        guard seeded else {
            // A straight body behind the head, never a cloud of coincident points — see
            // `facing`. Reachable in one frame: a fish placed and posed before the next fixed
            // step has run has a head and no path.
            let back = -facing
            return (0..<knots.count).map { head + back * (spacing * Float($0)) }
        }
        var out = [SIMD3<Float>](repeating: head, count: knots.count)
        let ahead = simd_length(head - knot(0))
        let f = min(max(ahead / spacing, 0), 1)
        for i in 1..<knots.count {
            out[i] = simd_mix(knot(i), knot(i - 1), SIMD3<Float>(repeating: f))
        }
        return out
    }

    /// What the body's shape is, in the two numbers the eye judges: how far the path departs
    /// from the head's own axis, in body lengths, and the angle between the heading and the
    /// path's direction one body length back. A straight animal is `(0, 0)`; a hairpin is
    /// something like `(0.3, 170°)`.
    ///
    /// Reported by the school census, because a still frame cannot say whether the body is
    /// bending or merely turned, and a number that stays at zero for a whole run is the failure
    /// that would otherwise be invisible.
    func shape(bodyLength: Float) -> (deviation: Float, turnedDegrees: Float) {
        guard seeded, bodyLength > 0 else { return (0, 0) }
        let points = samples()
        let tail = min(Int((bodyLength / spacing).rounded()), points.count - 2)
        guard tail >= 2 else { return (0, 0) }
        let axis = simd_normalize(points[0] - points[1])
        var deviation: Float = 0
        for i in 1...tail {
            let offset = points[i] - points[0]
            let along = simd_dot(offset, axis)
            deviation = max(deviation, simd_length(offset - axis * along))
        }
        let tailAxis = simd_normalize(points[tail - 1] - points[tail])
        let cosine = min(max(simd_dot(axis, tailAxis), -1), 1)
        return (deviation / bodyLength, acos(cosine) * 180 / .pi)
    }

    /// The oldest sample — where the tip of the tail is.
    ///
    /// Answered without building the whole run, because a transit asks for it on every fixed
    /// step of every lurker on its last leg.
    func tailSample() -> SIMD3<Float> {
        let last = knots.count - 1
        guard seeded else { return head - facing * (spacing * Float(last)) }
        let f = min(max(simd_length(head - knot(0)) / spacing, 0), 1)
        return simd_mix(knot(last), knot(last - 1), SIMD3<Float>(repeating: f))
    }

    /// The point half a body length behind the head — the middle of the animal.
    ///
    /// For a lurker `position` is the nose, so every number the census states about "where the
    /// eel is" is a number about its head. On an animal this long that is the very claim in
    /// question: a head at a fifth of the column with the body trailing above it is not an eel
    /// on the floor. Reported alongside the head so the two can disagree in the open.
    func midpoint(bodyLength: Float) -> SIMD3<Float> {
        let points = samples()
        let index = min(max(Int((bodyLength / (2 * spacing)).rounded()), 0), points.count - 1)
        return points[index]
    }
}

/// HARNESS AID, `AQUARIUM_EEL_TRAIL=1`. A ball on every spine sample, in the school's own space,
/// so a run in a window shows where the body is being asked to lie. Green at the head, red at
/// the tail, like the passage markers.
///
/// Kept for the same reason those are: whether the mesh actually follows the trail is a
/// question a still can only answer with the trail drawn on it.
final class SpineTrailMarkers {
    static let enabled = ProcessInfo.processInfo.environment["AQUARIUM_EEL_TRAIL"] != nil

    private let balls: [SCNNode]

    init(parent: SCNNode, radius: CGFloat) {
        var balls: [SCNNode] = []
        for i in 0..<SpineTrail.sampleCount {
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 8
            let material = SCNMaterial()
            let t = CGFloat(i) / CGFloat(SpineTrail.sampleCount - 1)
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(red: t, green: 1 - t, blue: 0.1, alpha: 1)
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = true
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.renderingOrder = 1000
            parent.addChildNode(node)
            balls.append(node)
        }
        self.balls = balls
    }

    func show(_ samples: [SIMD3<Float>]) {
        for (ball, point) in zip(balls, samples) { ball.simdPosition = point }
    }
}
