// A plane's run at a tank: pick one now and then, fly at it at cruise height, drop into a
// shallow dive with the guns going, and pull back up into the band.
//
// Shallow and short, so it reads: a plane leaving the band is seen to shrink toward its own
// shadow as it goes down, which is the whole cue that it is diving, and it climbs straight back
// before anything else happens. The soft wall keeps its last word over the heading throughout —
// tanks keep inside the arena, so a run never needs the wall's room — and a threat on the
// plane's tail ends the run at once.

import Foundation
import simd

extension DogfightSim {

    /// How fast a plane may sink or climb on a run — faster than the band's play, so the dive is
    /// a dive, and not scaled: the depth it dives through is the camera's, not the plane's.
    static let strafeClimbRate: Float = 0.6

    /// Whether to start a run at a tank, and which one. A dogfight comes first: a plane with an
    /// enemy close by, or on its tail, keeps fighting.
    func maybeStartStrafe(_ me: Plane, pilot: inout PilotMemory, target: Plane?, now: Double) {
        guard pilot.strafe == nil, now >= pilot.nextStrafeAllowed, match.phase == .fighting,
              !tanks.isEmpty else { return }
        let k = me.spec.scale
        if let target, simd_distance(target.position, me.position) < 1.0 * k { return }
        let bomber = me.weapon == .paperBall
        guard combat.next() < (bomber ? 0.16 : 0.06) else { return }
        var best: (tank: Tank, distance: Float)?
        for tank in tanks where tank.side != me.side && tank.isActive && tankRegion.contains(tank.position) {
            let distance = simd_distance(tank.position, me.position)
            // Far enough to line up and dive, near enough not to cross the screen for it.
            guard distance > 0.9 * k + 0.4, distance < 3.4 else { continue }
            let taken = planes.contains { $0.side == me.side && $0.id != me.id && $0.pilot.strafe?.tank == tank.id }
            guard !taken else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (tank, distance) }
        }
        guard let best else { return }
        pilot.strafe = StrafeRun(tank: best.tank.id, phase: .approach, startedAt: now,
                                 floor: strafeFloor(over: best.tank, from: me))
    }

    typealias Steering = (desired: SIMD2<Float>, speed: Float, altitude: Float)

    /// The run's own steering, in place of a pursuit; nil when the plane is not on a run. The
    /// step a run finishes still climbs, and the next is an ordinary fighting step.
    func strafeSteering(_ me: Plane, pilot: inout PilotMemory, now: Double) -> Steering? {
        guard var run = pilot.strafe else { return nil }
        let k = me.spec.scale
        let climbing: Steering = (me.direction, me.spec.maxSpeed, pilot.cruiseAltitude)
        let tank = tanks.first { $0.id == run.tank && $0.isActive }
        var steering = climbing

        switch run.phase {
        case .approach, .dive:
            guard let tank else {
                run.phase = .pullUp(until: now + Double(combat.inRange(1.2, 1.7)))
                break
            }
            let offset = tank.position - me.position
            let distance = simd_length(offset)
            let off = angleBetween(me.direction, offset)
            run.floor = strafeFloor(over: tank, from: me)
            let toward = unit(offset, or: me.direction)
            if case .approach = run.phase {
                // Start down when there is just room to reach the floor before the tank.
                let drop = max(me.altitude - run.floor, 0)
                let start = me.speed * drop / DogfightSim.strafeClimbRate + 0.45 * k
                if distance < start, off < 0.5 {
                    run.phase = .dive(since: now)
                } else if distance < 0.35 * k || now - run.startedAt > 9 {
                    // Overflew it while still lining up, or never managed to: give it up.
                    run.phase = .pullUp(until: now + Double(combat.inRange(1.2, 1.7)))
                } else {
                    steering = (toward, me.spec.cruiseSpeed, pilot.cruiseAltitude)
                }
            }
            if case .dive(let since) = run.phase {
                if distance < 0.25 * k || off > 1.3 || now - since > 3.5 {
                    run.phase = .pullUp(until: now + Double(combat.inRange(1.2, 1.7)))
                } else {
                    steering = (toward, me.spec.cruiseSpeed, run.floor)
                }
            }
        case .pullUp:
            break
        }

        if case .pullUp(let until) = run.phase, now >= until {
            pilot.strafe = nil
            pilot.nextStrafeAllowed = now + Double(combat.inRange(10, 18))
        } else {
            pilot.strafe = run
        }
        return steering
    }

    /// A run broken off by a threat: no climb-out beat, the break turn is the climb-out.
    func abandonStrafe(_ pilot: inout PilotMemory, now: Double) {
        guard pilot.strafe != nil else { return }
        pilot.strafe = nil
        pilot.nextStrafeAllowed = now + Double(combat.inRange(8, 14))
    }

    /// The lowest a run over `tank` may go: a little above the turret, and clear of the ground
    /// under the plane and just ahead of it — a tank on a hillside has a hill beside it.
    func strafeFloor(over tank: Tank, from me: Plane) -> Float {
        let ahead = me.position + me.direction * 0.4
        let ground = max(terrain.surfaceHeight(at: me.position), terrain.surfaceHeight(at: ahead))
        return min(max(tank.altitude + tank.spec.height + 0.22, ground + 0.18), ViewRig.bandLow - 0.05)
    }

    /// The lowest a plane may be this step. On a dive, the run's floor; otherwise the band —
    /// unless it is already below it, coming back up from a run, when it may stay where it is
    /// and climb rather than be snapped up.
    func altitudeFloor(for plane: Plane, before altitude: Float) -> Float {
        if let run = plane.pilot.strafe, case .dive = run.phase { return run.floor - 0.02 }
        return min(ViewRig.bandLow - 0.02, altitude)
    }

    /// The climb a shot needs to land on `tank`, if the plane is lined up and in reach: down a
    /// diving plane's line, or lobbed a little for the bomber's paper ball, which falls hard.
    /// The shot's horizontal flight slows under drag exactly as `stepProjectiles` flies it, so
    /// the time to reach the tank is solved through that, not guessed from the muzzle speed.
    func groundShot(from me: Plane, at tank: Tank) -> Float? {
        let gun = me.gun
        let start = me.position + me.direction * me.spec.size * 0.5
        let offset = tank.position + tank.velocity * 0.3 - start
        let distance = simd_length(offset)
        guard distance < gun.range * 1.3, angleBetween(me.direction, offset) < gun.cone + 0.05 else { return nil }
        let speed = me.speed + gun.muzzleSpeed
        let reach = speed * gun.dragTime
        guard distance < reach * 0.92 else { return nil }
        let flight = -gun.dragTime * log(1 - distance / reach)
        let top = tank.altitude + tank.spec.height * 0.7
        let height = me.altitude - 0.012 * me.spec.scale
        let climb = (top - height + 0.5 * gun.gravity * flight * flight) / flight
        // Never steeper than about 35° down, which is a dive and not a plunge; a lob only for
        // the ball, and only a small one.
        let lob: Float = me.weapon == .paperBall ? 0.35 : 0.05
        guard climb > -speed * 0.7, climb < speed * lob else { return nil }
        return climb
    }
}
