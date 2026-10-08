// Supply drops: now and then a paper crate drifts down under a tissue-paper parachute from above
// the planes' band. The first plane whose path crosses it gets a better weapon for a while; one
// that reaches the ground lies there and fades.
//
// The crate falls slowly through the band — a dozen seconds where a plane can reach it — so it
// is a thing a person sees coming and sees a plane turn for. Only the plane nearest it diverts,
// and never one with an enemy on its tail or a target in its sights, so a drop pulls one plane
// out of the furball rather than turning the whole sky toward one point — and a crate that
// falls where the fight is busy is sometimes missed, and lands.
//
// Its own random stream, like the pilots': when and where a drop falls must not reshuffle which
// modes and papers a seed draws, and a seed must still name one exact fight.

import Foundation
import simd

enum PowerUpKind: Int, CaseIterable {
    /// Every shot goes out as three, fanned.
    case tripleShot
    /// The weapon reloads in under half the time.
    case rapidFire
}

struct PowerUp: Equatable {
    let kind: PowerUpKind
    let until: Double

    static let duration: Double = 15
}

enum DropState: Equatable {
    case falling
    /// On the ground since this time; lies for `SupplyDrop.lieTime`, then fades.
    case landed(at: Double)
    /// Came down in a lake at this time and is going under.
    case sinking(at: Double)
}

struct SupplyDrop {
    let id: Int
    let kind: PowerUpKind
    let spawnedAt: Double
    /// Wind: the slow sideways drift a parachute takes on the way down.
    let drift: SIMD2<Float>
    var position: SIMD2<Float>
    var previousPosition: SIMD2<Float>
    /// The crate's own height; the canopy rides `canopyHeight` above it.
    var altitude: Float
    var previousAltitude: Float
    var state: DropState = .falling

    /// Where a drop starts: well above the band, so it is seen falling into the fight from
    /// nearer the camera, and has a few seconds of coming before anyone can reach it.
    static let startAltitude: Float = ViewRig.bandHigh + 0.45
    /// m/s. Slow enough to spend a dozen seconds inside the band, which is the window planes
    /// have to reach it.
    static let fallSpeed: Float = 0.055
    /// The top of the canopy above the crate's base, metres — the library's crate and parachute
    /// at the size they are drawn (`SupplyField.modelScale`). Crate and canopy are not anyone's,
    /// so they do not scale with a match.
    static let canopyHeight: Float = 0.2
    /// How close, horizontally, a plane's centre must pass to the crate's line to take it —
    /// its hit radius plus this — and the height span from just under the crate to the canopy.
    static let grabReach: Float = 0.06
    static let lieTime: Double = 4
    static let fadeTime: Double = 1.5
    static let sinkTime: Double = 2

    /// 1 while it can be seen at full strength, falling to 0 as it fades or goes under.
    func opacity(at now: Double) -> Float {
        switch state {
        case .falling: return 1
        case .landed(let at): return 1 - Float(min(max((now - at - SupplyDrop.lieTime) / SupplyDrop.fadeTime, 0), 1))
        case .sinking(let at): return 1 - Float(min(max((now - at) / SupplyDrop.sinkTime, 0), 1))
        }
    }
}

extension DogfightSim {

    /// When the next drop of this match may fall: never in the opening seconds, while planes
    /// are still coming on, and then about once every forty to sixty-five seconds — two or three
    /// in a full-length match.
    ///
    /// What is in the drops alternates through a match, from a first one drawn at its start, so
    /// a match with two or three drops shows both. Drawn per drop, a run of ten seeds' matches
    /// came out more than two to one triple shot.
    func scheduleFirstDrop(now: Double) {
        nextDropAt = now + Double(supply.inRange(18, 32))
        nextDropKind = PowerUpKind.allCases[supply.index(count: PowerUpKind.allCases.count)]
    }

    func stepSupplyDrops(now: Double, dt: Float) {
        if match.phase == .fighting, now >= nextDropAt {
            if !drops.contains(where: { $0.state == .falling }), let drop = makeDrop(now: now) {
                drops.append(drop)
                emit(.dropSpawned(drop: drop.id))
            }
            nextDropAt = now + Double(supply.inRange(40, 65))
        }

        var i = 0
        while i < drops.count {
            var drop = drops[i]
            drop.previousPosition = drop.position
            drop.previousAltitude = drop.altitude
            var remove = false
            switch drop.state {
            case .falling:
                drop.position += drop.drift * dt
                drop.altitude -= SupplyDrop.fallSpeed * dt
                if let taker = firstToReach(drop) {
                    let until = now + PowerUp.duration
                    planes[taker].powerUp = PowerUp(kind: drop.kind, until: until)
                    emit(.dropGrabbed(drop: drop.id, plane: planes[taker].id, kind: drop.kind,
                                      position: drop.position, altitude: drop.altitude))
                    remove = true
                } else {
                    let ground = terrain.surfaceHeight(at: drop.position)
                    if drop.altitude <= ground {
                        drop.altitude = ground
                        let wet = terrain.isWater(at: drop.position)
                        drop.state = wet ? .sinking(at: now) : .landed(at: now)
                        emit(.dropLanded(drop: drop.id, inWater: wet))
                    }
                }
            case .landed(let at):
                remove = now - at > SupplyDrop.lieTime + SupplyDrop.fadeTime
            case .sinking(let at):
                remove = now - at > SupplyDrop.sinkTime
            }
            if remove {
                drops.remove(at: i)
            } else {
                drops[i] = drop
                i += 1
            }
        }
    }

    /// Somewhere well inside the fight, so its whole fall — drift included — is in view, and a
    /// plane can reach it without leaving the arena.
    private func makeDrop(now: Double) -> SupplyDrop? {
        let high = rig.visible(atAltitude: SupplyDrop.startAltitude)
        let (lo, hi) = wall.bounds
        for _ in 0..<12 {
            let p = SIMD2(supply.inRange(lo.x, hi.x), supply.inRange(lo.y, hi.y))
            guard wall.contains(p, margin: 0.45), high.contains(p, margin: 0.2) else { continue }
            let angle = supply.inRange(0, 2 * .pi)
            let drift = SIMD2(cos(angle), sin(angle)) * supply.inRange(0.01, 0.03)
            let kind = nextDropKind
            nextDropKind = PowerUpKind.allCases[(kind.rawValue + 1) % PowerUpKind.allCases.count]
            return SupplyDrop(id: makeID(), kind: kind, spawnedAt: now, drift: drift, position: p, previousPosition: p,
                              altitude: SupplyDrop.startAltitude, previousAltitude: SupplyDrop.startAltitude)
        }
        return nil
    }

    /// The plane whose path this step came nearest the crate's line, among those inside its
    /// reach — nearest along the way rather than first in the array, so the order planes are
    /// stored in cannot decide a race.
    private func firstToReach(_ drop: SupplyDrop) -> Int? {
        var best: (index: Int, distance: Float)?
        for (index, plane) in planes.enumerated() {
            switch plane.state {
            case .fighting, .entering: break
            case .exiting, .downed, .takingOff: continue
            }
            let height = plane.altitude - drop.altitude
            guard height > -0.04, height < SupplyDrop.canopyHeight + 0.02 else { continue }
            let distance = segmentDistance(drop.position, plane.previous.position, plane.position)
            guard distance < plane.spec.hitRadius + SupplyDrop.grabReach else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (index, distance) }
        }
        return best?.index
    }

    /// Steering toward a drop, for a plane that should go for it — or nil. Called from the
    /// pursuit, after the threat and the strafing run have had their say, with the plane's
    /// current target: a pilot with an enemy in front and in range keeps shooting.
    func supplySteering(for me: Plane, among others: [Plane], target: Plane?, now: Double)
        -> (desired: SIMD2<Float>, altitude: Float)? {
        guard me.powerUp(at: now) == nil,
              let drop = drops.first(where: { $0.state == .falling }),
              drop.altitude < ViewRig.bandHigh + 0.2, drop.altitude + SupplyDrop.canopyHeight > ViewRig.bandLow
        else { return nil }
        let distance = simd_distance(me.position, drop.position)
        guard distance < 2.0 else { return nil }
        if let target, simd_distance(target.position, me.position) < me.gun.range * 1.2,
           angleBetween(me.direction, target.position - me.position) < 0.6 { return nil }
        // Only the nearest plane that could go for it does.
        for other in others where other.id != me.id && other.state == .fighting && other.powerUp(at: now) == nil {
            let d = simd_distance(other.position, drop.position)
            if d < distance || (d == distance && other.id < me.id) { return nil }
        }
        let desired = unit(drop.position + drop.drift * 0.5 - me.position, or: me.direction)
        let altitude = min(max(drop.altitude + SupplyDrop.canopyHeight * 0.4, ViewRig.bandLow), ViewRig.bandHigh)
        return (desired, altitude)
    }
}

/// Distance from `p` to the segment `a`–`b`.
func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let ab = b - a
    let length2 = simd_length_squared(ab)
    guard length2 > 1e-12 else { return simd_distance(p, a) }
    let t = min(max(simd_dot(p - a, ab) / length2, 0), 1)
    return simd_distance(p, a + ab * t)
}
