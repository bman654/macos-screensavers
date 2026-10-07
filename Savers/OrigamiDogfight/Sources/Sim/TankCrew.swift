// How a tank decides: roll in from an edge, wander the dry ground under the fight, stop to throw
// pencils at whatever plane comes over, and drive off when the match is done.
//
// Slow on purpose. A tank's whole job on screen is to be a second, slower layer of the fight —
// something a plane dives at, and something that throws things back up — so everything it does
// is readable at a glance: it stops before it shoots, its turret visibly swings to lead, and its
// pencils rise and fall in arcs a person can follow.

import Foundation
import simd

extension DogfightSim {

    /// The ground a tank's spawn and exit are measured against: what the camera sees at about
    /// meadow height, which is wider than the planes' arena because the ground is further away.
    var groundView: ConvexQuad { rig.visible(atAltitude: 0.15) }

    // MARK: Spawning

    func spawnTanksDue(now: Double) {
        guard match.phase == .fighting else { return }
        for s in match.tankSlots.indices {
            guard match.tankSlots[s].tank == nil, let at = match.tankSlots[s].spawnAt, now >= at else { continue }
            // A side with an airfield rolls its tanks out of the hangar, waiting for the door; one
            // whose hangar has no road out comes on from the edge like everyone else.
            var hangar: Tank?
            if let base = base(for: match.tankSlots[s].side) {
                // A door still blocked after a while — a wreck burning in front of it — is given
                // up on, and the tank comes on from the edge.
                let waiting = match.tankSlots[s].runwayWaitSince ?? now
                if isRunwayClear(base, now: now) {
                    hangar = rollOut(slot: s, from: base, now: now)
                } else if now - waiting < DogfightSim.longestRunwayWait {
                    match.tankSlots[s].runwayWaitSince = waiting
                    match.tankSlots[s].spawnAt = now + 0.7
                    continue
                }
            }
            if let tank = hangar ?? spawnTank(slot: s, now: now) {
                match.tankSlots[s].tank = tank.id
                match.tankSlots[s].spawnAt = nil
                match.tankSlots[s].runwayWaitSince = nil
                tanks.append(tank)
                emit(.tankSpawned(tank: tank.id))
            } else {
                // Nowhere clear to come on from just now — another tank in the way, most likely.
                match.tankSlots[s].spawnAt = now + 1
            }
        }
    }

    /// Just outside an edge, on dry ground, with a road in to somewhere inside the arena that
    /// is not a pocket — a meadow ringed by woods would hold a tank for the whole match.
    private func spawnTank(slot index: Int, now: Double) -> Tank? {
        let slot = match.tankSlots[index]
        let spec = slot.type.spec(scale: match.tankScale)
        let grid = navGrid(for: slot.type)
        let view = groundView
        for attempt in 0..<16 {
            let edge = attempt < 8 ? (slot.homeEdge ?? rand.index(count: 4)) : rand.index(count: 4)
            let a = view.corners[edge], b = view.corners[(edge + 1) % 4]
            let normal = view.normals[edge]
            let start = a + (b - a) * rand.inRange(0.15, 0.85) - normal * spec.size * 0.7
            guard ground.isDriveable(start, footprint: spec.footprint),
                  !tanks.contains(where: { simd_distance($0.position, start) < spec.size * 2 }),
                  let search = grid.search(from: start, blocked: { self.isTankNear($0, size: spec.size, except: nil) })
            else { continue }
            let inside = search.order.filter { grid.inRegion[$0] }
            guard inside.count >= DogfightSim.roomToPatrol else { continue }
            // Among the nearest cells in, so it rolls straight in rather than across the map.
            let goal = inside[rand.index(count: min(inside.count, 40))]
            let route = search.route(from: start, to: goal, ground: ground, footprint: spec.footprint)
            let heading = atan2(normal.y, normal.x)
            var tank = Tank(id: makeID(), slot: index, side: slot.side, type: slot.type, paper: slot.paper, spec: spec,
                            state: .entering, stateSince: now, position: start, previousPosition: start,
                            altitude: terrain.surfaceHeight(at: start), heading: heading, previousHeading: heading,
                            turret: heading, previousTurret: heading, health: spec.armour,
                            progressCheckAt: now + 4, lastMovedAt: now)
            tank.route = route
            return tank
        }
        return nil
    }

    /// Cells a tank needs to be able to reach inside the arena, about 0.7 m², before it is put
    /// somewhere: less is a pocket it would sit in.
    static let roomToPatrol = 150

    func navGrid(for type: TankType) -> NavGrid {
        if let grid = navGrids[type] { return grid }
        let spec = type.spec(scale: match.tankScale)
        let grid = NavGrid(ground: ground, footprint: spec.footprint, covering: groundView, region: tankRegion,
                           margin: spec.size)
        navGrids[type] = grid
        return grid
    }

    private func isTankNear(_ p: SIMD2<Float>, size: Float, except id: Int?) -> Bool {
        tanks.contains { $0.id != id && simd_distance($0.position, p) < ($0.spec.size + size) * 0.7 }
    }

    // MARK: Stepping

    func stepTanks(among planes: [Plane], now: Double, dt: Float) {
        for i in tanks.indices {
            tanks[i].previousPosition = tanks[i].position
            tanks[i].previousHeading = tanks[i].heading
            tanks[i].previousTurret = tanks[i].turret
        }
        for i in tanks.indices { stepTank(i, among: planes, now: now, dt: dt) }
    }

    private func stepTank(_ i: Int, among planes: [Plane], now: Double, dt: Float) {
        var tank = tanks[i]
        defer { tanks[i] = tank }
        tank.cooldown -= dt
        // Past the winner being named nothing more may be thrown. A target is only dropped on
        // the next retarget, so this also gates the halt and the throw below, not just the pick.
        let holdFire = match.phase != .fighting || !tank.isActive

        if now >= tank.retargetAt {
            tank.target = holdFire ? nil : nearestEnemy(of: tank, among: planes)
            tank.retargetAt = now + Double(combat.inRange(0.4, 0.7))
        }
        let target = tank.target.flatMap { id in planes.first { $0.id == id } }
            .flatMap { isTargetable($0, byTankOf: tank.side) ? $0 : nil }
        if target != nil { tank.lastSawTargetAt = now }
        let shot = target.flatMap { pencilShot(from: tank, at: $0) }

        // The turret leads its target, or settles back over the hull's nose with nothing to do.
        let aim: Float
        if let shot {
            aim = atan2(shot.velocity.y, shot.velocity.x)
        } else if let target {
            aim = atan2(target.position.y - tank.position.y, target.position.x - tank.position.x)
        } else {
            aim = tank.heading
        }
        let slew = (aim - tank.turret).wrappedAngle
        tank.turret = (tank.turret + max(min(slew * 4, tank.spec.turretTurnRate), -tank.spec.turretTurnRate) * dt).wrappedAngle

        switch tank.state {
        case .entering:
            // Rolling in a little quicker than it patrols: the arena's edge is some way off the
            // screen's, and a tank that took a quarter of a match to arrive would miss it.
            if !follow(&tank, pace: 1.6, now: now, dt: dt) || tank.route.isEmpty || now - tank.stateSince > 25 {
                tank.state = .patrol
                tank.stateSince = now
                tank.route = []
            }
        case .patrol:
            if !holdFire, shot != nil, tank.cooldown < 0.8, now >= tank.nextHaltAllowed {
                tank.state = .halted(until: now + Double(combat.inRange(1.8, 3)))
                tank.stateSince = now
            } else {
                patrol(&tank, now: now, dt: dt)
            }
        case .halted(let until):
            brake(&tank, dt: dt)
            if !holdFire, let shot, tank.cooldown <= 0, abs((atan2(shot.velocity.y, shot.velocity.x) - tank.turret).wrappedAngle) < 0.1 {
                throwPencil(from: &tank, shot: shot, now: now)
            }
            if now >= until || (target == nil && now - tank.lastSawTargetAt > 1.2) {
                tank.state = .patrol
                tank.stateSince = now
                tank.nextHaltAllowed = now + Double(combat.inRange(4, 7))
            }
        case .leaving:
            let blocked = !follow(&tank, pace: 1.8, now: now, dt: dt)
            if !groundView.contains(tank.position, margin: -tank.spec.size) {
                // Gone: removed by `retireTanks`.
            } else if blocked || tank.route.isEmpty || now - tank.stateSince > 14 {
                tank.state = .folding(since: now)
                tank.stateSince = now
            }
        case .folding:
            brake(&tank, dt: dt)
        }
        if tank.speed > 1e-3 { tank.lastMovedAt = now }
        tank.altitude = terrain.surfaceHeight(at: tank.position)
    }

    /// Road to road, each to somewhere it can reach inside the arena. On arriving it stops and
    /// looks round for a moment, which is what a tank between fights does.
    private func patrol(_ tank: inout Tank, now: Double, dt: Float) {
        if tank.route.isEmpty, now >= tank.nextRouteTry {
            tank.route = patrolRoute(for: tank)
            tank.progressDistance = .greatestFiniteMagnitude
            tank.progressCheckAt = now + 4
            tank.nextRouteTry = now + 0.5
            if tank.route.isEmpty {
                // Hemmed in, by other tanks most likely: turn on the spot meanwhile. A tank that
                // finds no road for seconds on end is in a pocket nothing will open, and folds
                // away so a replacement can roll in somewhere better.
                tank.heading = (tank.heading + tank.spec.hullTurnRate * 0.5 * dt).wrappedAngle
                tank.routeFailures += 1
                if tank.routeFailures >= 8 {
                    tank.state = .folding(since: now)
                    tank.stateSince = now
                }
            } else {
                tank.routeFailures = 0
            }
            return
        }
        guard !tank.route.isEmpty else {
            brake(&tank, dt: dt)
            return
        }
        if !follow(&tank, pace: 1, now: now, dt: dt) {
            tank.route = []
            tank.blockedCount += 1
            // Wedged: every road it is given is shut from where it stands. A hop to any open
            // ground nearby usually frees it; a tank that cannot even do that folds away rather
            // than sit there all match.
            if tank.blockedCount >= 6 {
                tank.state = .folding(since: now)
                tank.stateSince = now
            } else if tank.blockedCount >= 3, let hop = escapeHop(for: tank) {
                tank.route = [hop]
                tank.progressDistance = .greatestFiniteMagnitude
                tank.progressCheckAt = now + 4
            }
        } else if tank.route.isEmpty {
            tank.state = .halted(until: now + Double(combat.inRange(0.5, 1.4)))
            tank.stateSince = now
        }
    }

    /// Somewhere between half a metre and two and a half away by road, round any tank in the way.
    private func patrolRoute(for tank: Tank) -> [SIMD2<Float>] {
        let grid = navGrid(for: tank.type)
        guard let search = grid.search(from: tank.position, blocked: { self.isTankNear($0, size: tank.spec.size, except: tank.id) })
        else { return [] }
        var goals = search.order.filter { grid.inRegion[$0] && (6...34).contains(search.depth[$0]) }
        // Nothing at a stroll's distance — a tank still outside the arena, or in a narrow strip
        // of it — so anywhere in the arena it can reach at all.
        if goals.isEmpty { goals = search.order.filter { grid.inRegion[$0] && search.depth[$0] >= 2 } }
        guard !goals.isEmpty else { return [] }
        return search.route(from: tank.position, to: goals[combat.index(count: goals.count)], ground: ground,
                            footprint: tank.spec.footprint)
    }

    /// The nearest point a short straight hop away that is open, in sixteen directions.
    private func escapeHop(for tank: Tank) -> SIMD2<Float>? {
        for reach in [0.05, 0.1, 0.16] as [Float] {
            for k in 0..<16 {
                let angle = tank.heading + .pi + Float(k / 2) * (.pi / 8) * (k % 2 == 0 ? 1 : -1)
                let hop = tank.position + SIMD2(cos(angle), sin(angle)) * reach
                if ground.isClear(from: tank.position, to: hop, footprint: tank.spec.footprint) { return hop }
            }
        }
        return nil
    }

    /// Drives the next leg of the route, dropping each leg as it is reached. False when the
    /// tank is blocked, or has made no headway along the leg for four seconds.
    private func follow(_ tank: inout Tank, pace: Float, now: Double, dt: Float) -> Bool {
        // Tight: every leg was checked clear from the end of the one before, not from wherever
        // near it the tank happens to be, so cutting a leg short can drive it into a tree.
        while let next = tank.route.first, simd_distance(tank.position, next) < 0.012 {
            tank.route.removeFirst()
            tank.progressDistance = .greatestFiniteMagnitude
            tank.progressCheckAt = now + 4
        }
        guard let next = tank.route.first else {
            brake(&tank, dt: dt)
            tank.blockedCount = 0
            return true
        }
        if now >= tank.progressCheckAt {
            let distance = simd_distance(tank.position, next)
            if distance > tank.progressDistance - tank.spec.size * 0.15 { return false }
            tank.progressDistance = distance
            tank.progressCheckAt = now + 4
        }
        return drive(&tank, toward: next, pace: pace, now: now, dt: dt)
    }

    /// Turns toward `point` and moves if it is facing near enough — a tank pivots on the spot
    /// rather than driving a wide arc it may not have room for. False when the next step would
    /// leave driveable ground or run into another tank; the tank then stays where it is.
    private func drive(_ tank: inout Tank, toward point: SIMD2<Float>, pace: Float, now: Double, dt: Float) -> Bool {
        let offset = point - tank.position
        guard simd_length(offset) > 1e-4 else { brake(&tank, dt: dt); return true }
        let error = (atan2(offset.y, offset.x) - tank.heading).wrappedAngle
        let turn = max(min(error * 5, tank.spec.hullTurnRate), -tank.spec.hullTurnRate)
        tank.heading = (tank.heading + turn * dt).wrappedAngle
        // Rolls through a gentle bend and pivots on the spot for a sharp one. The arc a bend
        // cuts is short, and if it ever clips something the step below stops it and the tank
        // squares up to the leg instead.
        let want = abs(error) > 0.5 ? 0 : tank.spec.speed * pace * (1 - abs(error) * 1.6)
        let accel = 0.3 * tank.spec.scale * dt
        tank.speed += max(min(want - tank.speed, accel), -accel)
        let next = tank.position + tank.direction * tank.speed * dt
        let crowded = tanks.contains { other in
            guard other.id != tank.id, !isFolding(other) else { return false }
            let room = (other.spec.size + tank.spec.size) * 0.6
            let now = simd_distance(other.position, tank.position), then = simd_distance(other.position, next)
            return then < room && then < now
        }
        guard !crowded, ground.isDriveable(next, footprint: tank.spec.footprint, leaving: tank.position) else {
            tank.speed = 0
            // Still swinging onto the leg: the leg itself may be clear. Blocked only when
            // squarely facing it.
            return abs(error) > 0.05
        }
        tank.position = next
        if tank.speed > 1e-3 { tank.blockedCount = 0 }
        return true
    }

    private func brake(_ tank: inout Tank, dt: Float) {
        tank.speed = max(tank.speed - 0.5 * tank.spec.scale * dt, 0)
        if tank.speed > 0 {
            let next = tank.position + tank.direction * tank.speed * dt
            if ground.isDriveable(next, footprint: tank.spec.footprint, leaving: tank.position) {
                tank.position = next
            } else {
                tank.speed = 0
            }
        }
    }

    private func isFolding(_ tank: Tank) -> Bool {
        if case .folding = tank.state { return true }
        return false
    }

    // MARK: Gunnery

    func isTargetable(_ plane: Plane, byTankOf side: Int) -> Bool {
        guard plane.side != side else { return false }
        switch plane.state {
        case .fighting: return true
        case .entering: return rig.visible(atAltitude: plane.altitude).contains(plane.position)
        case .exiting, .downed, .takingOff: return false
        }
    }

    private func nearestEnemy(of tank: Tank, among planes: [Plane]) -> Int? {
        var best: (id: Int, distance: Float)?
        for plane in planes where isTargetable(plane, byTankOf: tank.side) {
            let distance = simd_distance(plane.position, tank.position)
            guard distance < tank.spec.range * 1.8 else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (plane.id, distance) }
        }
        return best?.id
    }

    /// A pencil that meets `plane` on its way up: thrown hard enough to top out a little above
    /// the band, with whatever horizontal speed puts it where the plane will be when it gets
    /// there. Nil when that is out of reach — too far, or a throw too flat to read as one.
    func pencilShot(from tank: Tank, at plane: Plane) -> (velocity: SIMD2<Float>, climb: Float)? {
        let pencil = WeaponKind.pencil.spec(scale: tank.spec.scale)
        let start = tank.altitude + tank.spec.height * 0.8
        let apex = ViewRig.bandHigh + 0.12
        let rise = plane.altitude - start
        guard apex - start > 0.3, rise > 0.1, rise < apex - start - 0.01 else { return nil }
        let climb = (2 * pencil.gravity * (apex - start)).squareRoot()
        let flight = (climb - (climb * climb - 2 * pencil.gravity * rise).squareRoot()) / pencil.gravity
        guard flight > 0.05 else { return nil }
        let meet = plane.position + plane.velocity * flight
        // From the muzzle, which is half a tank out along the way the turret will point.
        let muzzle = tank.position + unit(meet - tank.position, or: tank.direction) * tank.spec.size * 0.5
        let offset = meet - muzzle
        let reach = simd_length(offset)
        // Steep, always: never flatter than about 50° — the point of a pencil is that it goes up.
        guard reach < tank.spec.range, reach / flight < climb * 0.85 else { return nil }
        return (offset / flight, climb)
    }

    /// From the muzzle: the barrel's tip, half the tank's length out along the turret, a little
    /// under the turret top.
    private func throwPencil(from tank: inout Tank, shot: (velocity: SIMD2<Float>, climb: Float), now: Double) {
        let start = tank.altitude + tank.spec.height * 0.8
        let along = SIMD2(cos(tank.turret), sin(tank.turret))
        let barrel = tank.spec.barrels[tank.shotsFired % tank.spec.barrels.count]
        let muzzle = tank.position + along * tank.spec.size * 0.5 + SIMD2(-along.y, along.x) * barrel * tank.spec.size
        let raw = SIMD3(combat.inRange(-0.3, 0.3), combat.inRange(-0.3, 0.3), 1)
        // A thrown pencil wobbles about its length, and the hand is not perfect.
        let wander = SIMD2(combat.inRange(-1, 1), combat.inRange(-1, 1)) * 0.04 * tank.spec.scale
        let projectile = Projectile(
            id: makeID(), kind: .pencil, owner: tank.id, side: tank.side, paper: tank.paper,
            scale: tank.spec.scale, spin: simd_normalize(raw) * combat.inRange(5, 9),
            position: muzzle, altitude: start, previousPosition: muzzle, previousAltitude: start,
            velocity: shot.velocity + wander, climb: shot.climb)
        projectiles.append(projectile)
        tank.cooldown = tank.spec.cooldown * combat.inRange(0.85, 1.2)
        tank.firedAt = now
        tank.shotsFired += 1
        emit(.tankFired(tank: tank.id))
    }

    // MARK: Damage and leaving

    func damage(tank index: Int, by shooter: Int, side: Int, amount: Float, now: Double) {
        guard tanks[index].isActive else { return }
        tanks[index].health -= amount
        guard tanks[index].health <= 0 else { return }
        let tank = tanks[index]
        let wreck = Wreck(id: makeID(), model: .tank(tank.type), paper: tank.paper, scale: tank.spec.scale,
                          position: tank.position, ground: tank.altitude, heading: tank.heading,
                          roll: combat.inRange(-0.12, 0.12), turret: (tank.turret - tank.heading).wrappedAngle,
                          crashedAt: now, inWater: false)
        wrecks.append(wreck)
        emit(.tankDestroyed(tank: tank.id, by: shooter, wreck: wreck.id, position: tank.position,
                            ground: tank.altitude, paper: tank.paper, scale: tank.spec.scale))
        credit(side: side, now: now)
        awardKill(to: shooter, now: now)
        if let s = match.tankSlots.firstIndex(where: { $0.tank == tank.id }) {
            match.tankSlots[s].tank = nil
            // Longer than a plane's: a burning tank should have the ground to itself a while.
            match.tankSlots[s].spawnAt = match.phase == .fighting ? now + Double(rand.inRange(5, 8)) : nil
        }
        tanks.remove(at: index)
    }

    /// The match is over: every tank takes the shortest road off the screen, and a tank with
    /// none folds away where it stands.
    func sendTanksHome(now: Double) {
        let view = groundView
        for i in tanks.indices where tanks[i].isActive {
            let tank = tanks[i]
            let grid = navGrid(for: tank.type)
            let search = grid.search(from: tank.position, blocked: { _ in false })
            let exit = search?.order.first { !view.contains(grid.center(of: $0), margin: -tank.spec.size * 1.2) }
            if let search, let exit {
                tanks[i].route = search.route(from: tank.position, to: exit, ground: ground, footprint: tank.spec.footprint)
                tanks[i].state = .leaving
            } else {
                tanks[i].state = .folding(since: now)
            }
            tanks[i].progressDistance = .greatestFiniteMagnitude
            tanks[i].progressCheckAt = now + 4
            tanks[i].stateSince = now
            tanks[i].target = nil
        }
    }

    /// Tanks that have driven off, or finished folding away, free their seats.
    func retireTanks(now: Double) {
        tanks.removeAll { tank in
            let gone: Bool
            switch tank.state {
            case .leaving: gone = !groundView.contains(tank.position, margin: -tank.spec.size)
            case .folding(let since): gone = now - since > DogfightSim.foldTime
            case .entering, .patrol, .halted: gone = false
            }
            if gone {
                if let s = match.tankSlots.firstIndex(where: { $0.tank == tank.id }) {
                    match.tankSlots[s].tank = nil
                    // One that folded away mid-match, wedged, is replaced; one that drove off at
                    // the end is not.
                    if match.phase == .fighting { match.tankSlots[s].spawnAt = now + Double(rand.inRange(3, 5)) }
                }
                emit(.tankLeft(tank: tank.id))
            }
            return gone
        }
    }

    /// How long a tank takes to fold flat and fade.
    static let foldTime: Double = 1.4
}
