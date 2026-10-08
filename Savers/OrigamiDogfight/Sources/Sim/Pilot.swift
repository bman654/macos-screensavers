// How a plane decides where to go.
//
// The aim is a fight that *looks* like a dogfight — chases, overshoots, breaks, scissors,
// head-on passes — rather than the stable answer pure pursuit converges to, which is two
// planes of equal turn rate orbiting each other's tails forever. Three rules break that
// symmetry: a pilot with an enemy on its tail breaks hard toward it to force an overshoot; a
// pilot that has turned hard one way for too long without a shot extends straight out and
// comes back for a pass; and speed is traded for turn, so a slower, nimbler plane can win a
// turning fight that a faster one has to leave.
//
// Over all of it sits the **predictive soft wall**: the playable area is the camera's view at
// the top of the band, and a plane starts turning away early enough, given its own turn
// radius, that it rarely leaves the screen. Entering and exiting planes ignore it.
//
// Every distance here is in v1's metres times the match's scale (`k`), so a furball of small
// planes fights exactly as a few big ones do, only smaller.

import Foundation
import simd

extension DogfightSim {

    func command(for i: Int, among others: [Plane], now: Double) -> Command {
        let me = planes[i]
        switch me.state {
        case .downed:
            if case .downed(_, let spin) = me.state {
                return Command(turn: spin * me.spec.turnRate * 1.2, speed: me.spec.cruiseSpeed * 0.9,
                               altitude: 0)
            }
            return Command(turn: 0, speed: me.speed, altitude: 0)
        case .exiting(let direction):
            return Command(turn: turnToward(direction, from: me, gain: 2.5),
                           speed: me.spec.maxSpeed, altitude: me.pilot.cruiseAltitude)
        case .entering(let aim):
            // In once it is clear of the wall — or after long enough that it must have been
            // turned round by something, so it fights from wherever it is.
            if wall.contains(me.position, margin: 0.05 * me.spec.scale) || now - me.stateSince > 7 {
                planes[i].state = .fighting
                planes[i].stateSince = now
            }
            return Command(turn: turnToward(unit(aim - me.position, or: me.direction), from: me, gain: 3),
                           speed: me.spec.cruiseSpeed, altitude: me.pilot.cruiseAltitude)
        case .fighting:
            return fightingCommand(for: i, among: others, now: now)
        case .takingOff:
            // Flown by `stepTakeOff`, never by a command.
            return Command(turn: 0, speed: me.speed, altitude: me.altitude)
        }
    }

    /// Whether `other` is something a pilot may chase or shoot at.
    func isTargetable(_ other: Plane, by me: Plane) -> Bool {
        guard other.side != me.side, other.id != me.id, match.phase == .fighting else { return false }
        switch other.state {
        case .fighting: return true
        case .entering: return rig.visible(atAltitude: other.altitude).contains(other.position)
        case .exiting, .downed, .takingOff: return false
        }
    }

    private func fightingCommand(for i: Int, among others: [Plane], now: Double) -> Command {
        var me = planes[i]
        let spec = me.spec
        let k = spec.scale
        let dt = DogfightSim.step
        let heading = me.direction
        var pilot = me.pilot

        // Target: the nearest enemy, weighted toward what is in front, sticky so it does not
        // flick between two equidistant planes, and spread so a team does not all chase one.
        let current = pilot.target.flatMap { id in others.first { $0.id == id } }
        if now >= pilot.retargetAt || current.map({ !isTargetable($0, by: me) }) ?? true {
            var best: Plane?
            var bestScore = Float.greatestFiniteMagnitude
            for other in others where isTargetable(other, by: me) {
                let offset = other.position - me.position
                let distance = simd_length(offset)
                let off = angleBetween(heading, offset)
                let crowd = others.filter { $0.side == me.side && $0.id != me.id && $0.pilot.target == other.id }.count
                var score = distance * (1 + 1.5 * off / .pi) * (1 + 0.5 * Float(crowd))
                if other.id == pilot.target { score *= 0.7 }
                if score < bestScore { bestScore = score; best = other }
            }
            pilot.target = best?.id
            pilot.retargetAt = now + Double(combat.inRange(0.35, 0.6))
        }
        let target = pilot.target.flatMap { id in others.first { $0.id == id } }

        // Threat: an enemy behind me, close, with its nose on me.
        var threat: Plane?
        var threatDistance: Float = 1.3 * k
        for other in others where other.side != me.side && !other.state.isDowned && other.state.isAloft {
            let offset = other.position - me.position
            let distance = simd_length(offset)
            guard distance < threatDistance, distance > 1e-3 else { continue }
            let behind = angleBetween(-heading, offset) < 1.15
            let aimed = angleBetween(other.direction, -offset) < 0.55
            if behind && aimed { threat = other; threatDistance = distance }
        }

        // Expire a finished manoeuvre.
        switch pilot.maneuver {
        case .breakTurn(_, let until), .extend(_, let until):
            if now >= until { pilot.maneuver = .pursue; pilot.jinkAltitude = nil }
        case .pursue:
            break
        }

        if threat != nil {
            abandonStrafe(&pilot, now: now)
        } else {
            maybeStartStrafe(me, pilot: &pilot, target: target, now: now)
        }

        if let threat, pilot.maneuver == .pursue, now >= pilot.nextBreakAllowed {
            let toThreat = threat.position - me.position
            let side: Float = cross(heading, toThreat) >= 0 ? 1 : -1
            pilot.maneuver = .breakTurn(direction: side, until: now + Double(combat.inRange(0.8, 1.4)))
            pilot.nextBreakAllowed = now + Double(combat.inRange(2.5, 4.5))
            // Jink away from the attacker's altitude: shots are only good within a hand's
            // breadth of height, so changing it is half of a break.
            let away: Float = threat.altitude > me.altitude ? -1 : 1
            pilot.jinkAltitude = min(max(me.altitude + away * combat.inRange(0.15, 0.25) * k,
                                         ViewRig.bandLow), ViewRig.bandHigh)
        }

        // Anti-orbit: a long hard turn the same way with nothing to show for it is a circle.
        let hard = abs(me.turnRate) > spec.turnRate * 0.6
        let sign: Float = me.turnRate >= 0 ? 1 : -1
        if hard && sign == pilot.turnSign {
            pilot.sameTurnTime += dt
        } else {
            pilot.sameTurnTime = 0
            pilot.turnSign = hard ? sign : 0
        }
        if pilot.maneuver == .pursue, pilot.sameTurnTime > 4.0, now - pilot.lastShotAt > 2.5 {
            pilot.maneuver = .extend(heading: openSkyHeading(for: me, among: others),
                                     until: now + Double(combat.inRange(1.4, 2.4)))
            pilot.sameTurnTime = 0
        }
        // Overshoot: the target is now behind and close. Turning back into it is how a fight
        // collapses into a furball; running out and coming back is how it becomes a pass.
        if pilot.maneuver == .pursue, let target, threat == nil {
            let offset = target.position - me.position
            let distance = simd_length(offset)
            let behind = angleBetween(heading, offset) > 2.1
            // The fast types fight by boom-and-zoom: through, out and round again, rather
            // than turning with anything nimbler.
            let zoomer = me.type == .dart || me.type == .interceptor
            if distance < 0.7 * k, behind || (zoomer && now - pilot.lastShotAt < 0.2 && distance < 0.45 * k),
               combat.next() < (zoomer ? 0.05 : 0.02) {
                pilot.maneuver = .extend(heading: openSkyHeading(for: me, among: others),
                                         until: now + Double(combat.inRange(1.5, 2.6)))
            }
        }

        // Cruise altitude wanders, so idle planes are not all at one height.
        if now >= pilot.cruiseUntil {
            pilot.cruiseAltitude = combat.inRange(ViewRig.bandLow + 0.05, ViewRig.bandHigh - 0.05)
            pilot.cruiseUntil = now + Double(combat.inRange(3, 7))
        }

        var desired = heading
        var speed = spec.cruiseSpeed
        var altitude = pilot.jinkAltitude ?? pilot.cruiseAltitude
        var forcedTurn: Float?

        let run = strafeSteering(me, pilot: &pilot, now: now)
        if let run {
            desired = run.desired
            speed = run.speed
            altitude = run.altitude
        } else {
            switch pilot.maneuver {
            case .breakTurn(let direction, _):
                forcedTurn = direction * spec.turnRate
                speed = spec.minSpeed
            case .extend(let h, _):
                desired = SIMD2(cos(h), sin(h))
                speed = spec.maxSpeed
            case .pursue:
                if threat == nil, let grab = supplySteering(for: me, among: others, target: target, now: now) {
                    // A crate coming down within reach: go and take it.
                    desired = grab.desired
                    altitude = pilot.jinkAltitude ?? grab.altitude
                } else if let target {
                    let weapon = me.gun
                    let offset = target.position - me.position
                    let distance = simd_length(offset)
                    // Lead pursuit: aim where the target will be when a shot would arrive.
                    let flight = min(distance / (weapon.muzzleSpeed + me.speed), 0.6)
                    let lead = target.position + target.velocity * flight
                    desired = unit(lead - me.position, or: heading)
                    let off = angleBetween(heading, lead - me.position)
                    if off > 1.2 {
                        speed = spec.minSpeed          // tighten the turn
                    } else if distance < 0.5 * k && off < 0.5 {
                        speed = max(min(target.speed * 0.95, spec.maxSpeed), spec.minSpeed)  // do not overshoot
                    } else if distance > 1.6 * k {
                        speed = spec.maxSpeed          // close the range
                    }
                    // Hold the target's height plus what the shot will drop on the way.
                    altitude = pilot.jinkAltitude ?? (target.altitude + 0.5 * weapon.gravity * flight * flight)
                } else {
                    // Nothing to fight: drift toward the middle of the arena.
                    let toCenter = wall.centroid - me.position
                    if simd_length(toCenter) > 0.5 { desired = unit(heading + unit(toCenter, or: heading) * 0.4, or: heading) }
                }
            }
        }

        // Separation: clear of teammates, and never through anyone at the same height.
        var push = SIMD2<Float>(0, 0)
        for other in others where other.id != me.id && !other.state.isDowned && other.state.isAloft {
            let offset = me.position - other.position
            let distance = simd_length(offset)
            guard distance > 1e-4 else { continue }
            let reach: Float = (other.side == me.side ? 0.5 : 0.22) * k
            if distance < reach {
                push += offset / distance * (reach - distance) / reach
            }
            if run == nil, distance < 0.3 * k, abs(other.altitude - me.altitude) < 0.12 * k {
                altitude += (me.altitude >= other.altitude ? 1 : -1) * 0.15 * k
            }
        }
        if simd_length(push) > 0 { desired = unit(desired + push * 1.5, or: heading) }
        // And never into anyone: a path about to cross another's at its height is broken off.
        switch run == nil ? avoidance(for: me, among: others) : nil {
        case .holdBack(let slower)?:
            speed = min(speed, slower)
        case .breakAway(let away, let height)?:
            desired = unit(desired + away * 1.2, or: away)
            altitude = height
        case nil:
            break
        }

        // The wall has the last word.
        let (urgency, inward) = wallPull(for: me)
        pilot.wallUrgency = urgency
        // An extension that has reached the edge is over: the run out was the point, and
        // carrying it on would only press the plane along the wall.
        if urgency > 0.8, case .extend = pilot.maneuver { pilot.maneuver = .pursue }
        // The same for a run still lining up: the wall has turned it away, so the run is off.
        if urgency > 1, let strafe = pilot.strafe, case .approach = strafe.phase { abandonStrafe(&pilot, now: now) }
        if urgency > 0 {
            let weight = min(urgency, 1)
            desired = unit(desired * (1 - weight) + inward * urgency * 1.5, or: inward)
            if urgency > 0.7 {
                forcedTurn = nil
                speed = min(speed, (spec.minSpeed + spec.cruiseSpeed) / 2)
            }
        }

        var turn = forcedTurn ?? turnToward(desired, from: me, gain: 3.5)
        // Facing straight into the wall, either way round is "toward" it; turn toward the open
        // side so the choice is the short one rather than whichever the arithmetic rounds to.
        if urgency > 1, angleBetween(heading, inward) > 2.6 {
            let toCenter = wall.centroid - me.position
            turn = (cross(heading, toCenter) >= 0 ? 1 : -1) * spec.turnRate
        }

        me.pilot = pilot
        planes[i] = me
        let floor = pilot.strafe.map { $0.floor } ?? ViewRig.bandLow
        return Command(turn: turn, speed: speed, altitude: min(max(altitude, floor), ViewRig.bandHigh))
    }

    /// A heading out of the crowd: away from the nearby planes, toward the middle of the arena,
    /// and not far off the way the plane is already going — an extension is a straight line,
    /// so it has to be one the plane can fly without first turning round.
    func openSkyHeading(for me: Plane, among others: [Plane]) -> Float {
        let k = me.spec.scale
        var away = SIMD2<Float>(0, 0)
        for other in others where other.id != me.id && !other.state.isDowned && other.state.isAloft {
            let offset = me.position - other.position
            let distance = max(simd_length(offset), 0.05 * k)
            if distance < 1.5 * k { away += offset / distance * (1.5 * k - distance) / k }
        }
        let toCenter = wall.centroid - me.position
        var direction = me.direction * 1.2 + away * 0.8
        if simd_length(toCenter) > 0.3 { direction += unit(toCenter, or: .zero) * min(simd_length(toCenter), 1.5) }
        let length = simd_length(direction)
        let out = length > 1e-4 ? direction / length : me.direction
        return atan2(out.y, out.x)
    }

    /// How hard the edges are pulling, and which way is in.
    ///
    /// For each edge: the distance a turn at full rate needs to swing the heading parallel to
    /// it is r(1 − cos φ), φ the angle between the heading and the edge line; a pilot starts
    /// turning that far out, plus a reaction distance, plus a soft zone over which the pull
    /// ramps up. So a fast, wide-turning dart begins its turn much earlier than a glider does.
    func wallPull(for plane: Plane) -> (urgency: Float, inward: SIMD2<Float>) {
        let k = plane.spec.scale
        let radius = plane.speed / plane.spec.turnRate
        let heading = plane.direction
        let soft: Float = 0.25 * k
        var urgency: Float = 0
        var inward = SIMD2<Float>(0, 0)
        for e in 0..<4 {
            let d = wall.distance(plane.position, edge: e)
            let n = wall.normals[e]
            let approach = -simd_dot(heading, n)
            var u: Float
            if approach > 0 {
                // Clamped: a unit heading dotted with a unit normal can round past 1, and the NaN
                // that follows would switch the wall off for that tick.
                let need = radius * (1 - max(0, 1 - approach * approach).squareRoot())
                u = (need + plane.speed * 0.3 + soft - d) / soft
            } else {
                u = (0.15 * k - d) / (0.3 * k)
            }
            if d < 0 { u = max(u, 1 + min(-d * 4 / k, 1)) }
            u = min(max(u, 0), 2)
            urgency = max(urgency, u)
            inward += n * u
        }
        let length = simd_length(inward)
        return (urgency, length > 1e-5 ? inward / length : .zero)
    }

    func turnToward(_ desired: SIMD2<Float>, from plane: Plane, gain: Float) -> Float {
        let goal = atan2(desired.y, desired.x)
        let difference = (goal - plane.pose.heading).wrappedAngle
        return max(min(difference * gain, plane.spec.turnRate), -plane.spec.turnRate)
    }
}

/// `v` scaled to unit length, or `fallback` when it has none to scale. Every steering vector
/// here is a sum of pulls that can cancel exactly — a target dead ahead of a push away from a
/// teammate — and `simd_normalize` of a zero vector is NaN, which would turn a heading into NaN
/// and lose the plane for good without a single visible error.
func unit(_ v: SIMD2<Float>, or fallback: SIMD2<Float>) -> SIMD2<Float> {
    let length = simd_length(v)
    return length > 1e-6 ? v / length : fallback
}

func angleBetween(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let la = simd_length(a), lb = simd_length(b)
    guard la > 1e-6, lb > 1e-6 else { return 0 }
    return acos(max(min(simd_dot(a, b) / (la * lb), 1), -1))
}

/// z of the 3D cross product: positive when `b` is counter-clockwise (to the left) of `a`.
func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
