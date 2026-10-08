// The paper cranes: every few minutes, and now and then in the lull between matches, a flock of
// five to nine crosses the whole view above the fight, flapping, in a V or loosely, and is gone.
//
// Not sim entities. A crane hits nothing and nothing hits it — the plan's own word is that they
// ignore the fight — so a flock is a pure function of when it set off, drawn from the seed: where
// any crane is at any moment is a formula, and a scene rebuilt mid-crossing picks the flock up
// exactly where it was.

import Foundation
import simd

struct CraneFlock {
    let start: Double
    /// Where the flock is aimed through, its heading, and its ground speed.
    let origin: SIMD2<Float>
    let direction: SIMD2<Float>
    let speed: Float
    let altitude: Float
    let members: [Member]
    /// From entering the view at one side to having left it at the other.
    let duration: Double

    struct Member {
        /// Behind and beside the leader, in the flock's own frame: x forward, y left.
        let offset: SIMD2<Float>
        let lift: Float
        let flapRate: Float
        let flapPhase: Float
        /// Which of the papers it is folded from.
        let paper: Int
        let size: Float
    }

    /// Above the top of the fight's band — they pass over the planes, never through them — and
    /// well under the camera, so they read a little larger than a plane, as nearer things do.
    static let flightAltitude: Float = 1.32
    /// From the middle of the flock to beyond the edge of the view either side, at any aspect the
    /// rig allows: the widest view at this height is under five metres across.
    static let halfPath: Float = 4.2

    /// Where member `index` is, and which way it is heading, `t` seconds into the crossing.
    func pose(of index: Int, at t: Double) -> (position: SIMD2<Float>, altitude: Float, heading: Float) {
        let m = members[index]
        let along = -CraneFlock.halfPath + speed * Float(t)
        let left = SIMD2(-direction.y, direction.x)
        // Each bird drifts a little in its place: a flock is never a rigid shape.
        let sway = SIMD2(0.03 * wave(t, rate: 0.37, phase: Double(m.flapPhase)),
                         0.04 * wave(t, rate: 0.29, phase: Double(m.flapPhase) * 1.7))
        let local = m.offset + sway
        let p = origin + direction * (along + local.x) + left * local.y
        let heading = atan2(direction.y, direction.x) + 0.08 * wave(t, rate: 0.29, phase: Double(m.flapPhase) * 1.7)
        return (p, altitude + m.lift + 0.012 * wave(t, rate: 1.1, phase: Double(m.flapPhase)), heading)
    }

    static func make(start: Double, rand: inout Rand) -> CraneFlock {
        let angle = rand.inRange(0, 2 * .pi)
        let direction = SIMD2(cos(angle), sin(angle))
        let origin = SIMD2(rand.inRange(-1.0, 1.0), rand.inRange(-0.5, 0.5))
        let count = 5 + rand.index(count: 5)
        let isV = rand.next() < 0.6
        var members: [Member] = []
        for i in 0..<count {
            let offset: SIMD2<Float>
            if isV {
                // Leader at the point, the rest down both arms in turn.
                let row = Float((i + 1) / 2), side: Float = i % 2 == 0 ? 1 : -1
                offset = SIMD2(-0.15 * row, i == 0 ? 0 : side * 0.13 * row)
                    + SIMD2(rand.inRange(-0.02, 0.02), rand.inRange(-0.02, 0.02))
            } else {
                // Loosely: anywhere in a ragged oval, but never on top of a neighbour.
                var candidate = SIMD2<Float>.zero
                for _ in 0..<20 {
                    candidate = SIMD2(rand.inRange(-0.45, 0.25), rand.inRange(-0.32, 0.32))
                    if members.allSatisfy({ simd_distance($0.offset, candidate) > 0.13 }) { break }
                }
                offset = candidate
            }
            members.append(Member(offset: offset, lift: rand.inRange(-0.04, 0.04),
                                  flapRate: rand.inRange(8.5, 10.5), flapPhase: rand.inRange(0, 2 * .pi),
                                  paper: rand.index(count: 4), size: rand.inRange(0.92, 1.08)))
        }
        let speed = rand.inRange(0.36, 0.46)
        // Long enough for the last bird, half a metre behind the leader, to be clear too.
        let duration = Double((2 * halfPath + 0.6) / speed)
        return CraneFlock(start: start, origin: origin, direction: direction, speed: speed,
                          altitude: flightAltitude, members: members, duration: duration)
    }
}

/// When the flocks come. The regular ones are a sequence drawn from the seed — every two and a
/// half to five and a half minutes — so the schedule needs nothing stored; the ones that come in
/// the lull after a match are kept, because when a match ends is the fight's to say.
struct CraneSchedule {
    private let seed: UInt64
    private var rand: Rand
    private var nextStart: Double
    private(set) var flocks: [CraneFlock] = []

    /// How often a match's end brings a flock over the empty sky.
    static let lullChance: Float = 0.3

    /// `firstAt` pins the first flock, for a harness that wants one in its picture.
    init(seed: UInt64, firstAt: Double? = nil) {
        self.seed = seed
        var rand = Rand(seed: seed ^ 0xC4A7_E5F1_0C6)
        let drawn = Double(rand.inRange(40, 120))
        self.rand = rand
        nextStart = firstAt ?? drawn
    }

    /// Brings the list up to `time`: flocks due are added, flocks across and gone are dropped.
    mutating func advance(to time: Double) {
        while nextStart <= time {
            flocks.append(CraneFlock.make(start: nextStart, rand: &rand))
            nextStart += Double(rand.inRange(150, 330))
        }
        flocks.removeAll { $0.start + $0.duration < time }
    }

    mutating func matchEnded(index: Int, at time: Double) {
        var draw = Rand(seed: seed ^ UInt64(index) &* 0x2545_F491 ^ 0x1A11)
        guard draw.next() < CraneSchedule.lullChance,
              // Not on top of a flock already crossing or about to.
              !flocks.contains(where: { $0.start + $0.duration > time }), nextStart - time > 30
        else { return }
        flocks.append(CraneFlock.make(start: time + 4, rand: &draw))
    }
}
