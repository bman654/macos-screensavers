// Mid-air collisions: two planes that touch both crumple and come down.
//
// Rare on purpose. A collision is funny once every few minutes and clumsy every few seconds, so
// the test is the planes' real overlap — their keels' circles touching, at nearly the same
// height — rather than the generous one a shot gets, and the pilots already keep clear: a
// teammate is given half a metre, and anyone at the same height within a few lengths makes one
// of the two climb or dive (`Pilot.swift`). What gets through is the head-on pass that nobody
// broke off from, which is what a real mid-air is.
//
// Nobody scores. Both planes count toward the match's end, as any other plane lost does, but a
// collision is not a kill, so the card's tallies and the aces' stickers are untouched.

import Foundation
import simd

extension DogfightSim {

    /// How far apart two planes' centres may be, as a fraction of the sum of their hit radii,
    /// before they are touching. Under 1: a paper plane's outline is mostly the wings' thin
    /// trailing edges, and two that only clip wingtips from above read as passing, not hitting.
    static let collisionReach: Float = 0.7
    /// Height difference, at scale 1, within which two planes are at the same height: about a
    /// keel's depth, so a plane passing a hand's breadth over another is seen to pass.
    static let collisionHeight: Float = 0.03

    func checkCollisions(now: Double) {
        guard planes.count > 1 else { return }
        var hit: [(Int, Int)] = []
        var taken = Set<Int>()
        for i in planes.indices where canCollide(planes[i]) && !taken.contains(i) {
            for j in (i + 1)..<planes.count where canCollide(planes[j]) && !taken.contains(j) {
                let a = planes[i], b = planes[j]
                let reach = (a.spec.hitRadius + b.spec.hitRadius) * DogfightSim.collisionReach
                guard simd_distance_squared(a.position, b.position) < reach * reach else { continue }
                let height = DogfightSim.collisionHeight * (a.spec.scale + b.spec.scale) / 2
                guard abs(a.altitude - b.altitude) < height else { continue }
                hit.append((i, j))
                taken.insert(i)
                taken.insert(j)
                break
            }
        }
        for (i, j) in hit { collide(i, j, now: now) }
    }

    /// What a pilot does about a plane whose path is about to meet its own at about its height,
    /// or nil when nobody is coming. Looked ahead by closest approach rather than by distance,
    /// and answered the way the geometry asks:
    ///
    /// - **Catching someone up** on much the same heading: throttle back and hold the height.
    ///   The chaser is the one closing, and a chaser that climbed away from its target at the
    ///   moment it was best placed to shoot would never fire the fight's best shots.
    /// - **Being caught up** from behind: nothing. The one behind can see, and gives way.
    /// - **Head-on or crossing**: turn off the point where they would meet, and climb if it is the
    ///   higher of the two or dive if the lower, so the pair split rather than mirror each other
    ///   into the same height — and only at the last moment, after the pass has been fired.
    func avoidance(for me: Plane, among others: [Plane]) -> Avoidance? {
        let k = me.spec.scale
        var soonest: (time: Float, other: Plane, miss: SIMD2<Float>, overtaking: Bool)?
        for other in others where other.id != me.id && other.state.isAloft && !other.state.isDowned {
            let offset = other.position - me.position
            guard simd_length_squared(offset) < 1.44 * k * k else { continue }
            let sameWay = simd_dot(me.direction, other.direction) > 0.5
            let ahead = simd_dot(me.direction, offset) > 0
            // Someone closing on my tail is theirs to avoid.
            if sameWay && !ahead { continue }
            let horizon = sameWay ? DogfightSim.overtakeLookAhead : DogfightSim.passLookAhead
            let closing = other.velocity - me.velocity
            let speed2 = simd_length_squared(closing)
            let time = speed2 > 1e-6 ? min(max(-simd_dot(offset, closing) / speed2, 0), horizon) : 0
            let miss = offset + closing * time
            let reach = (me.spec.hitRadius + other.spec.hitRadius) * 1.5
            guard simd_length_squared(miss) < reach * reach else { continue }
            let height = (other.altitude + other.climb * time) - (me.altitude + me.climb * time)
            guard abs(height) < 0.09 * k else { continue }
            if soonest.map({ time < $0.time }) ?? true { soonest = (time, other, miss, sameWay) }
        }
        guard let soonest else { return nil }
        if soonest.overtaking {
            return .holdBack(speed: max(soonest.other.speed * 0.85, me.spec.minSpeed))
        }
        let above = me.altitude > soonest.other.altitude
            || (me.altitude == soonest.other.altitude && me.id > soonest.other.id)
        let away = unit(-soonest.miss, or: SIMD2(-me.direction.y, me.direction.x))
        return .breakAway(away: away, altitude: me.altitude + (above ? 1 : -1) * 0.15 * k)
    }

    enum Avoidance {
        case holdBack(speed: Float)
        case breakAway(away: SIMD2<Float>, altitude: Float)
    }

    /// Seconds ahead a pilot watches for a head-on or crossing path: time enough to climb a
    /// keel's depth clear, and no more. Looking further ahead had both planes of every head-on
    /// pass jinking out of each other's sights before either could fire, and the fight's
    /// kills fell by a quarter.
    static let passLookAhead: Float = 0.4
    /// Catching up is slow, so it is watched for longer: a chaser easing off a second out
    /// settles behind its target instead of into it.
    static let overtakeLookAhead: Float = 1.0

    /// Fighting or coming on, in view: an exiting plane has left the match, and one still on
    /// the runway is not in the air to be hit.
    private func canCollide(_ plane: Plane) -> Bool {
        switch plane.state {
        case .fighting: return true
        case .entering: return rig.visible(atAltitude: plane.altitude).contains(plane.position)
        case .exiting, .downed, .takingOff: return false
        }
    }

    private func collide(_ i: Int, _ j: Int, now: Double) {
        let a = planes[i], b = planes[j]
        let middle = (a.position + b.position) / 2
        emit(.collided(a: a.id, b: b.id, position: middle, altitude: (a.altitude + b.altitude) / 2,
                       papers: [a.paper, b.paper], scale: (a.spec.scale + b.spec.scale) / 2))
        // Knocked apart: each spins away from the other, so the two spirals separate rather
        // than falling through each other.
        let side: Float = cross(a.direction, b.position - a.position)
        for (index, spin) in [(i, side >= 0 ? Float(-1) : 1), (j, side >= 0 ? Float(1) : -1)] {
            planes[index].state = .downed(killer: 0, spin: spin)
            planes[index].stateSince = now
            planes[index].crumpled = true
            planes[index].burstLeft = 0
            planes[index].pilot.strafe = nil
            planes[index].speed *= 0.7
            emit(.downed(victim: planes[index].id, by: 0))
        }
        if match.phase == .fighting {
            match.kills += 2
            match.lastKillAt = now
            match.collisions += 2
        }
    }
}
