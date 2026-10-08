// Team bases: in a match of two to four teams, each side gets an airfield — a hangar with a
// paper runway running out of its door — on clear, flat, dry ground on its own side of the view.
// Replacement planes roll out of the hangar, down the runway and climb into the band; tanks roll
// out of the same door. More sides than four and the landscape would be all airfields, so a
// free-for-all keeps today's entry from the edge, and so does any side no site could be found
// for.
//
// The site is searched for, not drawn at random: every candidate spot and heading on the side's
// part of the view is tested against the ground actually there — the terrain's faces and the
// scattered props, read and never changed — and the flattest, best-placed one wins. So a seed
// always puts its airfields in the same places, and a landscape with no room simply has none.

import Foundation
import simd

struct Airfield: Equatable {
    let side: Int
    /// The hangar's centre. Its door faces along `heading`, and the runway starts at the door.
    let hangar: SIMD2<Float>
    let heading: Float
    let hangarLength: Float
    let hangarWidth: Float
    let runwayLength: Float
    let runwayWidth: Float
    /// The highest ground under it, for keeping it inside the view.
    let top: Float

    var direction: SIMD2<Float> { SIMD2(cos(heading), sin(heading)) }
    var door: SIMD2<Float> { hangar + direction * hangarLength / 2 }
    var runwayEnd: SIMD2<Float> { door + direction * runwayLength }
    /// Where a plane leaves the ground, measured from the hangar's centre.
    var liftDistance: Float { hangarLength / 2 + runwayLength * 0.62 }
    /// Where a plane starts its roll: just inside the door, so it is seen to nose out.
    var rollStart: Float { hangarLength * 0.2 }

    /// The same airfield, knowing the highest ground under it.
    func at(top: Float) -> Airfield {
        Airfield(side: side, hangar: hangar, heading: heading, hangarLength: hangarLength, hangarWidth: hangarWidth,
                 runwayLength: runwayLength, runwayWidth: runwayWidth, top: top)
    }

    /// Signed distance of `p` along the runway's line from the hangar's centre.
    func along(_ p: SIMD2<Float>) -> Float { simd_dot(p - hangar, direction) }

    /// Whether `p` is on the hangar or the runway, or within `margin` of either.
    func covers(_ p: SIMD2<Float>, margin: Float = 0) -> Bool {
        let s = along(p)
        let off: Float = abs(cross(direction, p - hangar))
        let door = hangarLength / 2
        return (s >= -door - margin && s <= door + margin && off <= hangarWidth / 2 + margin)
            || (s >= door - margin && s <= door + runwayLength + margin && off <= runwayWidth / 2 + margin)
    }

    /// The room a tank must give the hangar: a disc a little inside its walls, so a tank rolling
    /// out of the door is past it as soon as it is out.
    var hangarRadius: Float { min(hangarLength, hangarWidth) * 0.5 }

    /// How long it takes to unfold at the start of a match and to fold away at the end.
    static let unfoldTime: Double = 1.6
    static let foldTime: Double = 1.6

    /// Sizes at the match's ground scale — the tanks' (`Match.tankScale`): an airfield is part of
    /// the ground war's world, between the planes' size and the landscape's, which never changes.
    /// The runway is a little wider than the narrow planes and narrower than the wide ones — a
    /// strip laid down for paper planes, not to an airport's proportions, which would take a
    /// third of the screen. The hangar keeps the library model's proportions (14 m by 10.2 m,
    /// door at the long end), long enough to hide a tank and the nose of a plane about to roll.
    static func dimensions(scale s: Float) -> (hangarLength: Float, hangarWidth: Float, runwayLength: Float,
                                               runwayWidth: Float) {
        (0.30 * s, 0.22 * s, 0.85 * s, 0.17 * s)
    }
}

extension DogfightSim {

    func base(for side: Int) -> Airfield? {
        match.bases.indices.contains(side) ? match.bases[side] : nil
    }

    /// Whether an airfield has finished unfolding and nothing is on its runway: a plane still
    /// rolling or climbing out low, a tank in the doorway, or a wreck lying anywhere a plane
    /// would roll through it or climb out through its fire.
    func isRunwayClear(_ base: Airfield, now: Double) -> Bool {
        guard match.phase == .fighting, now - match.startedAt > Airfield.unfoldTime else { return false }
        let busy = planes.contains { plane in
            guard case .takingOff(let side) = plane.state, side == base.side else { return false }
            return base.along(plane.position) < base.liftDistance + base.runwayLength * 0.2
        }
        let blocked = tanks.contains { tank in
            let s = base.along(tank.position)
            let side: Float = cross(base.direction, tank.position - base.hangar)
            let off = abs(side)
            return s > -base.hangarLength && s < base.hangarLength / 2 + base.runwayLength * 0.5
                && off < base.runwayWidth + tank.spec.size
        }
        return !busy && !blocked && !isWrecked(base)
    }

    /// Whether a wreck on land — burning, folding or fading, for as long as it is drawn — lies
    /// across the strip a plane covers from where it starts its roll to where its climb takes
    /// it over the fire. A tank rolling out uses the same door and the first of the same strip.
    func isWrecked(_ base: Airfield) -> Bool {
        // The widest and fastest plane this match could send down it.
        let span = PlaneType.allCases.map { $0.spec(scale: match.scale).size }.max() ?? 0
        let speed = PlaneType.allCases.map { $0.spec(scale: match.scale).cruiseSpeed }.max() ?? 0
        let liftGround = terrain.surfaceHeight(at: base.hangar + base.direction * base.liftDistance)
        return wrecks.contains { wreck in
            guard !wreck.inWater else { return false }
            let s = base.along(wreck.position)
            let off: Float = abs(cross(base.direction, wreck.position - base.hangar))
            // Past the lift point, a plane is over the fire once it has climbed to the fire's top
            // from the runway's height there — the ground can fall or rise a little along it.
            let height: Float = wreck.ground + wreck.fireTop - liftGround
            let climb = DogfightSim.climbTime(toClear: height)
            let end = base.liftDistance + speed * climb
            let room = wreck.reach + span * 0.5
            return s > base.rollStart - room && s < end + room && off < room
        }
    }

    /// Seconds from leaving the runway to standing `height` over it, on `stepTakeOff`'s climb:
    /// the climb rate gathering at 0.9 m/s² up to `takeOffClimb`, then held.
    static func climbTime(toClear height: Float) -> Float {
        let gather: Float = 0.9
        let rampTime = takeOffClimb / gather
        let rampHeight = 0.5 * gather * rampTime * rampTime
        guard height > rampHeight else { return (2 * max(height, 0) / gather).squareRoot() }
        return rampTime + (height - rampHeight) / takeOffClimb
    }

    /// The longest a replacement waits on a blocked runway — a wreck burning across it, most
    /// likely — before it gives up the airfield and comes on from the edge instead.
    static let longestRunwayWait: Double = 8

    // MARK: Take-off

    /// m/s, the climb out from the runway into the band: steeper than the band's play, so a
    /// plane is up and fighting a second or two after it leaves the ground.
    static let takeOffClimb: Float = 0.42

    /// A replacement plane for `slot`, inside the hangar's door, about to roll.
    func launch(slot index: Int, from base: Airfield, now: Double) -> Plane {
        let slot = match.slots[index]
        let type = PlaneType.allCases[rand.index(count: PlaneType.allCases.count)]
        let spec = type.spec(scale: match.scale)
        let weapon = spec.weapons[rand.index(count: spec.weapons.count)]
        let position = base.hangar + base.direction * base.rollStart
        let altitude = terrain.surfaceHeight(at: position) + DogfightSim.wheelHeight * spec.scale
        let pose = Pose(position: position, altitude: altitude, heading: base.heading, bank: 0, pitch: 0)
        let id = makeID()
        emit(.tookOff(plane: id, base: base.side))
        return Plane(id: id, slot: index, side: slot.side, type: type, weapon: weapon,
                     paper: slot.paper, spec: spec, state: .takingOff(base: base.side), stateSince: now,
                     pose: pose, previous: pose, speed: spec.cruiseSpeed * 0.2, health: spec.armour,
                     pilot: PilotMemory(lastShotAt: now, cruiseAltitude: ViewRig.bandLow + 0.1))
    }

    /// How high a plane's centre rides over the runway, at scale 1: on its keel, not in the paper.
    /// A model is anchored at the middle of its bounds and a folded keel hangs well below the
    /// wings, so at less than this a rolling plane sank through the strip it was rolling on.
    static let wheelHeight: Float = 0.035

    /// One step of a take-off: roll out of the hangar gathering speed, leave the ground most of
    /// the way down the runway, and climb straight out until it reaches the band — then it is an
    /// ordinary fighting plane, still climbing the last of the way.
    func stepTakeOff(_ i: Int, now: Double, dt: Float) {
        var p = planes[i]
        defer { planes[i] = p }
        // A runway that is gone, or moved out from under it when the view changed shape: it flies
        // on from where it is.
        let side: Int? = { if case .takingOff(let s) = p.state { return s } else { return nil } }()
        guard let side, let base = base(for: side),
              abs(cross(base.direction, p.position - base.hangar)) < base.runwayWidth,
              base.along(p.position) > -base.hangarLength else {
            p.state = .fighting
            p.stateSince = now
            return
        }
        let spec = p.spec
        let s = base.along(p.position)
        // Constant acceleration from the roll's starting speed to nearly cruise at the lift point.
        let v0 = spec.cruiseSpeed * 0.2, v1 = spec.cruiseSpeed * 0.95
        let accel = (v1 * v1 - v0 * v0) / (2 * max(base.liftDistance - base.rollStart, 0.05))
        let wheels = terrain.surfaceHeight(at: p.position) + DogfightSim.wheelHeight * spec.scale
        if s < base.liftDistance {
            p.speed = min(p.speed + accel * dt, v1)
            p.climb = 0
            p.pose.altitude = wheels
        } else {
            p.speed = min(p.speed + accel * dt, spec.cruiseSpeed)
            p.climb = min(p.climb + 0.9 * dt, DogfightSim.takeOffClimb)
            p.pose.altitude = max(p.pose.altitude + p.climb * dt, wheels)
        }
        p.turnRate = 0
        p.pose.heading = base.heading
        p.pose.position += p.direction * p.speed * dt
        p.pose.bank += max(min(-p.pose.bank, 3 * dt), -3 * dt)
        p.pose.pitch = atan2(p.climb, max(p.speed, 0.1))
        // Up: the rest of the climb is the band's ordinary one.
        if p.pose.altitude >= ViewRig.bandLow - 0.08 || now - p.stateSince > 10 {
            p.state = .fighting
            p.stateSince = now
            p.pilot.cruiseAltitude = combat.inRange(ViewRig.bandLow + 0.05, ViewRig.bandHigh - 0.1)
            p.pilot.cruiseUntil = now + Double(combat.inRange(3, 6))
        }
    }

    // MARK: Tanks out of the hangar

    /// A tank rolling out of its side's hangar door, with a road from just outside it to
    /// somewhere in the arena; nil if the door is blocked or there is no road.
    func rollOut(slot index: Int, from base: Airfield, now: Double) -> Tank? {
        let slot = match.tankSlots[index]
        let spec = slot.type.spec(scale: match.tankScale)
        guard isRunwayClear(base, now: now) else { return nil }
        let start = base.hangar
        let apron = base.door + base.direction * (spec.size * 0.8 + 0.04)
        let grid = navGrid(for: slot.type)
        // The way out of the door is the runway, which was chosen clear; only where it ends up
        // has to be open, since the hangar's own room would refuse every point inside the door.
        guard ground.isDriveable(apron, footprint: spec.footprint),
              let search = grid.search(from: apron, blocked: { _ in false })
        else { return nil }
        let inside = search.order.filter { grid.inRegion[$0] }
        guard inside.count >= DogfightSim.roomToPatrol else { return nil }
        let goal = inside[rand.index(count: min(inside.count, 40))]
        let route = [apron] + search.route(from: apron, to: goal, ground: ground, footprint: spec.footprint)
        var tank = Tank(id: makeID(), slot: index, side: slot.side, type: slot.type, paper: slot.paper, spec: spec,
                        state: .entering, stateSince: now, position: start, previousPosition: start,
                        altitude: terrain.surfaceHeight(at: start), heading: base.heading,
                        previousHeading: base.heading, turret: base.heading, previousTurret: base.heading,
                        health: spec.armour, progressCheckAt: now + 4, lastMovedAt: now)
        tank.route = route
        return tank
    }
}
