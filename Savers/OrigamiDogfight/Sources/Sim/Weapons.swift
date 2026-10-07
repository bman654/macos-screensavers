// Pulling the trigger, and what happens to everything that comes out.
//
// A shot leaves at the shooter's altitude with the shooter's velocity added, slows under drag,
// drops under gravity, and hits by a swept circle test with an altitude tolerance — so height
// matters, and a pilot who jinks up or down a hand's breadth is genuinely harder to hit. A miss
// does not vanish: it falls to the ground, lies there, and fades — or, into a lake, splashes and
// goes under. Anything coming down onto an enemy tank hits it, which is how strafing runs, the
// bomber's paper balls and the odd lucky miss all knock tanks out by one rule.

import Foundation
import simd

extension DogfightSim {

    /// How far apart in height a shot and a plane may be and still connect: a paper plane's
    /// depth through the keel, plus some grace so a shot that looks on target is. At scale 1;
    /// a smaller plane is thinner by its scale.
    static let altitudeTolerance: Float = 0.08

    func fireWeapon(_ i: Int, among others: [Plane], now: Double, dt: Float) {
        var me = planes[i]
        me.cooldown -= dt
        defer { planes[i] = me }
        guard case .fighting = me.state, match.phase == .fighting else { me.burstLeft = 0; return }
        let weapon = me.gun

        if me.burstLeft > 0 {
            me.burstTimer -= dt
            if me.burstTimer <= 0 {
                shoot(from: me, climb: me.burstClimb)
                me.burstLeft -= 1
                me.burstTimer = weapon.burstInterval
            }
            return
        }
        guard me.cooldown <= 0 else { return }

        // On a dive, the tank is the target, and the shot is aimed down at it.
        if let run = me.pilot.strafe, case .dive = run.phase,
           let tank = tanks.first(where: { $0.id == run.tank && $0.isActive }),
           let climb = groundShot(from: me, at: tank) {
            shoot(from: me, climb: climb)
            me.burstClimb = climb
            me.burstLeft = weapon.burst - 1
            me.burstTimer = weapon.burstInterval
            me.cooldown = weapon.cooldown * combat.inRange(0.85, 1.2)
            me.pilot.lastShotAt = now
            return
        }

        // Any enemy in the cone will do, the chosen target first — a pilot does not hold fire
        // on a plane that crosses its nose just because it was chasing another.
        let ordered = others.filter { isTargetable($0, by: me) }
            .sorted { ($0.id == me.pilot.target ? 0 : 1, $0.id) < ($1.id == me.pilot.target ? 0 : 1, $1.id) }
        for other in ordered {
            let offset = other.position - me.position
            let distance = simd_length(offset)
            guard distance < weapon.range, distance > 0.05 else { continue }
            let flight = distance / (weapon.muzzleSpeed + me.speed)
            let lead = other.position + other.velocity * flight
            guard angleBetween(me.direction, lead - me.position) < weapon.cone else { continue }
            let drop = 0.5 * weapon.gravity * flight * flight
            let tolerance = DogfightSim.altitudeTolerance * other.spec.scale
            guard abs(me.altitude - drop - other.altitude) < tolerance * 1.3 else { continue }

            shoot(from: me)
            me.burstClimb = nil
            me.burstLeft = weapon.burst - 1
            me.burstTimer = weapon.burstInterval
            me.cooldown = weapon.cooldown * combat.inRange(0.85, 1.2)
            me.pilot.lastShotAt = now
            break
        }
    }

    /// `climb` replaces the plane's own when the shot is aimed down at a tank.
    private func shoot(from me: Plane, climb: Float? = nil) {
        let weapon = me.gun
        let k = me.spec.scale
        emit(.fired(plane: me.id, weapon: me.weapon))
        for pellet in 0..<weapon.pellets {
            let fan = weapon.pellets > 1
                ? (Float(pellet) / Float(weapon.pellets - 1) - 0.5) * 2 * weapon.spread : 0
            // Hand-thrown: every shot wanders a few degrees, which is what makes a long-range
            // shot a gamble and a close one a certainty.
            let angle = me.pose.heading + fan + combat.inRange(-0.14, 0.14)
            let direction = SIMD2(cos(angle), sin(angle))
            let start = me.position + me.direction * me.spec.size * 0.5
            let raw = SIMD3(combat.inRange(-1, 1), combat.inRange(-1, 1), combat.inRange(-1, 1))
            let axis = simd_length(raw) > 1e-4 ? simd_normalize(raw) : SIMD3<Float>(0, 0, 1)
            let spinRate = combat.inRange(8, 16) * (me.weapon == .paperBall ? 0.5 : 1)
            let height = me.altitude - 0.012 * k
            let projectile = Projectile(
                id: makeID(), kind: me.weapon, owner: me.id, side: me.side, paper: me.paper, scale: k,
                spin: axis * spinRate,
                position: start, altitude: height, previousPosition: start, previousAltitude: height,
                velocity: me.velocity + direction * weapon.muzzleSpeed, climb: climb ?? me.climb)
            projectiles.append(projectile)
        }
    }

    func stepProjectiles(now: Double, dt: Float) {
        var i = 0
        while i < projectiles.count {
            var p = projectiles[i]
            p.age += dt
            var remove = false
            switch p.state {
            case .flying:
                let weapon = p.spec
                p.velocity *= exp(-dt / weapon.dragTime)
                p.position += p.velocity * dt
                p.climb -= weapon.gravity * dt
                p.altitude += p.climb * dt

                if let victim = firstHit(by: p, radius: weapon.radius) {
                    let target = planes[victim]
                    emit(.hit(victim: target.id, by: p.owner, weapon: p.kind, position: p.position,
                              altitude: p.altitude, paper: target.paper, scale: target.spec.scale))
                    damage(plane: victim, by: p.owner, side: p.side, amount: weapon.damage, now: now)
                    remove = true
                } else if let victim = firstTankHit(by: p, radius: weapon.radius) {
                    let tank = tanks[victim]
                    emit(.tankHit(tank: tank.id, by: p.owner, position: p.position, altitude: p.altitude,
                                  paper: tank.paper, scale: tank.spec.scale))
                    damage(tank: victim, by: p.owner, side: p.side, amount: weapon.damage, now: now)
                    remove = true
                } else {
                    let ground = terrain.surfaceHeight(at: p.position)
                    if p.altitude <= ground {
                        p.altitude = ground
                        if terrain.isWater(at: p.position) {
                            p.state = .sinking(at: p.age)
                            emit(.splashed(position: p.position, kind: p.kind, scale: p.scale))
                        } else {
                            p.state = .landed(at: p.age)
                        }
                    } else if simd_length(p.position) > Terrain.halfExtent * 1.3 {
                        remove = true
                    }
                }
            case .landed(let at):
                remove = p.age - at > WeaponSpec.lieTime + WeaponSpec.fadeTime
            case .sinking(let at):
                remove = p.age - at > WeaponSpec.sinkTime
            }
            if remove {
                projectiles.remove(at: i)
            } else {
                projectiles[i] = p
                i += 1
            }
        }
        // A storm of misses must not grow the scene without bound: the oldest settled go first.
        var excess = projectiles.count - DogfightSim.projectileCap
        if excess > 0 {
            projectiles.removeAll { p in
                guard excess > 0, p.isSettled else { return false }
                excess -= 1
                return true
            }
        }
    }

    /// The enemy plane the projectile's path this step reached first.
    ///
    /// First along the path, not first in the array: two planes overlapping in the shot's way
    /// would otherwise give the hit to whichever was stored first, which is the order they
    /// spawned in and nothing to do with where the shot went.
    private func firstHit(by p: Projectile, radius: Float) -> Int? {
        let a = p.previousPosition
        let segment = p.position - a
        let length2 = simd_length_squared(segment)
        var best: (index: Int, along: Float)?
        for (index, plane) in planes.enumerated() where plane.side != p.side && !plane.state.isDowned {
            guard abs(plane.altitude - p.altitude) < DogfightSim.altitudeTolerance * plane.spec.scale else { continue }
            guard let entry = sweptEntry(from: a, along: segment, length2: length2, into: plane.position,
                                         reach: plane.spec.hitRadius + radius) else { continue }
            if best.map({ entry < $0.along }) ?? true { best = (index, entry) }
        }
        return best?.index
    }

    /// The enemy tank a shot coming down this step landed on: inside its footprint, and below
    /// its turret top. Not a pencil going up — every pencil starts inside a tank.
    private func firstTankHit(by p: Projectile, radius: Float) -> Int? {
        guard p.climb < 0 else { return nil }
        let a = p.previousPosition
        let segment = p.position - a
        let length2 = simd_length_squared(segment)
        var best: (index: Int, along: Float)?
        for (index, tank) in tanks.enumerated() where tank.side != p.side && tank.isActive {
            let top = tank.altitude + tank.spec.height + 0.02 * tank.spec.scale
            guard p.altitude < top, p.altitude > tank.altitude - 0.03 else { continue }
            guard let entry = sweptEntry(from: a, along: segment, length2: length2, into: tank.position,
                                         reach: tank.spec.hitRadius + radius) else { continue }
            if best.map({ entry < $0.along }) ?? true { best = (index, entry) }
        }
        return best?.index
    }

    /// Where along `a + s·segment`, s in [0, 1], the path first enters a circle of `reach`
    /// round `center`: the smaller root of |a + s·d − c|² = R², or 0 when it began inside.
    private func sweptEntry(from a: SIMD2<Float>, along segment: SIMD2<Float>, length2: Float,
                            into center: SIMD2<Float>, reach: Float) -> Float? {
        let offset = a - center
        let c = simd_length_squared(offset) - reach * reach
        if c <= 0 { return 0 }
        guard length2 > 1e-12 else { return nil }
        let b = simd_dot(offset, segment)
        let discriminant = b * b - length2 * c
        guard b < 0, discriminant >= 0 else { return nil }
        let entry = (-b - discriminant.squareRoot()) / length2
        return entry <= 1 ? entry : nil
    }
}
