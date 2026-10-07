// The world: a fixed-step, seeded simulation of the whole fight.
//
// **Fixed step, and stepped by count, never by frame delta.** A state machine integrated
// against the frame's delta is reproducible only to within whatever the frame rate did
// (`docs/next-session.md`, traps), and this one is full of thresholds — a shot fired or not, a
// hit by a millimetre — so a variable step would make a seed name a different fight on every
// machine. The renderer asks for "as many steps as the clock says" and interpolates between
// the last two; the headless probe asks for thirty minutes of them in a second.
//
// No rendering imports. Everything visual — paper textures, smoke, the fire's flicker — is the
// renderer's, derived from the state here.

import Foundation
import simd

final class DogfightSim {
    static let step: Float = 1.0 / 120
    static let stepSeconds = Double(step)

    let seed: UInt64
    let terrain: Terrain
    let config: SimConfig
    private(set) var rig: ViewRig

    private(set) var steps = 0
    var time: Double { Double(steps) * DogfightSim.stepSeconds }

    var planes: [Plane] = []
    var projectiles: [Projectile] = []
    var wrecks: [Wreck] = []
    var match: Match
    private(set) var matchesCompleted = 0

    /// Everything that happened since the last `drainEvents()`. Bounded, so a sim nobody is
    /// draining — a warmup, or a renderer that has not been built yet — cannot grow without limit.
    private(set) var events: [SimEvent] = []
    private static let eventCap = 4096

    /// Match and spawn decisions.
    private var rand: Rand
    /// Every decision a pilot makes, and the scatter of every shot. A stream of its own so that
    /// a change to the AI does not reshuffle which modes and papers a seed draws.
    var combat: Rand
    private var nextID = 1

    /// Live projectiles are bounded by the fire rates; landed ones by this, oldest first.
    static let projectileCap = 240

    init(seed: UInt64, aspect: Float, config: SimConfig = SimConfig()) {
        self.seed = seed
        self.config = config
        terrain = Terrain(seed: seed)
        rig = ViewRig(aspect: aspect)
        rand = Rand(seed: seed ^ 0x3A7C_0FF1_CE5E_ED)
        combat = Rand(seed: seed ^ 0xC0B4_7D06_F16E)
        match = Match.draw(index: 0, now: 0, config: config, rand: &rand)
        emit(.matchStarted(index: 0, mode: match.mode, planes: match.slots.count))
    }

    /// Re-frames the arena for a drawable of a new shape. The landscape is generous enough not
    /// to need redrawing; only the wall moves.
    func setAspect(_ aspect: Float) {
        guard abs(aspect - rig.aspect) > 1e-4 else { return }
        rig = ViewRig(aspect: aspect)
    }

    func drainEvents() -> [SimEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    func emit(_ event: SimEvent) {
        if events.count >= DogfightSim.eventCap { events.removeFirst(events.count / 2) }
        events.append(event)
    }

    func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    func plane(id: Int) -> Plane? { planes.first { $0.id == id } }

    // MARK: Step

    /// A frozen sim keeps its state exactly as staged — the lineup's, for inspecting models.
    var isFrozen = false
    /// Whether the frozen state is the model lineup rather than a held moment of a fight.
    var isLineup = false

    func advance(steps count: Int = 1) {
        guard !isFrozen else { return }
        for _ in 0..<max(count, 0) { advanceOne() }
    }

    private func advanceOne() {
        steps += 1
        let now = time
        let dt = DogfightSim.step
        for i in planes.indices { planes[i].previous = planes[i].pose }
        for i in projectiles.indices {
            projectiles[i].previousPosition = projectiles[i].position
            projectiles[i].previousAltitude = projectiles[i].altitude
        }

        updateMatch(now: now)
        spawnDue(now: now)

        // Pilots decide from the positions everyone had at the start of the step, so the order
        // planes are stored in cannot favour anyone.
        let snapshot = planes
        for i in planes.indices {
            let command = command(for: i, among: snapshot, now: now)
            fly(i, command: command, dt: dt)
            fireWeapon(i, among: snapshot, now: now, dt: dt)
        }
        stepProjectiles(now: now, dt: dt)
        retirePlanes(now: now)
        wrecks.removeAll { now - $0.crashedAt > $0.lifetime }
    }

    // MARK: Flight

    struct Command {
        var turn: Float
        var speed: Float
        var altitude: Float
    }

    private func fly(_ i: Int, command: Command, dt: Float) {
        var p = planes[i]
        let spec = p.spec
        // Rate limits on everything, so a reversal is seen as a roll from one bank to the other
        // rather than a snap — the scissors read only because of this.
        p.turnRate += max(min(command.turn - p.turnRate, 9 * dt), -9 * dt)
        p.speed += max(min(command.speed - p.speed, 0.7 * dt), -0.7 * dt)
        let wantClimb: Float
        if p.state.isDowned {
            wantClimb = -0.8
        } else {
            wantClimb = max(min((command.altitude - p.pose.altitude) * 1.6, spec.climbRate), -spec.climbRate)
        }
        p.climb += max(min(wantClimb - p.climb, (p.state.isDowned ? 0.55 : 1.2) * dt),
                       -(p.state.isDowned ? 0.55 : 1.2) * dt)

        p.pose.heading = (p.pose.heading + p.turnRate * dt).wrappedAngle
        p.pose.position += p.direction * p.speed * dt
        p.pose.altitude += p.climb * dt
        if !p.state.isDowned {
            // The band is a hard limit for a live plane — the command already keeps inside it,
            // this only stops overshoot of the controller.
            p.pose.altitude = min(max(p.pose.altitude, ViewRig.bandLow - 0.02), ViewRig.bandHigh + 0.02)
        }

        // Bank as a real turn would ask for it — tan(bank) = v·ω / g — with a toy g chosen so a
        // glider's hardest turn lays it over about 65°.
        if case .downed(_, let spin) = p.state {
            // Out of control: rolled hard over into the spiral, rocking as it goes.
            let rock = sin(Float(time) * 9 + Float(p.id)) * 0.25
            let goal = spin * 1.35 + rock
            p.pose.bank += max(min(goal - p.pose.bank, 3 * dt), -3 * dt)
        } else {
            let goal = atan(p.speed * p.turnRate / 1.45)
            p.pose.bank += max(min(goal - p.pose.bank, 4.5 * dt), -4.5 * dt)
        }
        p.pose.pitch = atan2(p.climb, max(p.speed, 0.1))
        planes[i] = p
    }

    // MARK: Lifecycle

    private func updateMatch(now: Double) {
        switch match.phase {
        case .fighting:
            guard match.kills >= match.killTarget || now - match.startedAt > Match.timeLimit else { return }
            match.phase = .ending
            emit(.matchEnded(index: match.index, kills: match.kills))
            for i in planes.indices where !planes[i].state.isDowned {
                planes[i].state = .exiting(direction: exitDirection(for: planes[i]))
                planes[i].stateSince = now
            }
        case .ending:
            if planes.isEmpty {
                matchesCompleted += 1
                match.phase = .intermission(until: now + 2.0)
            }
        case .intermission(let until):
            guard now >= until else { return }
            match = Match.draw(index: match.index + 1, now: now, config: config, rand: &rand)
            emit(.matchStarted(index: match.index, mode: match.mode, planes: match.slots.count))
        }
    }

    /// Off the nearest edge, so the survivors leave the way they are already going rather than
    /// all turning for one side of the screen.
    private func exitDirection(for plane: Plane) -> SIMD2<Float> {
        let quad = rig.wall
        var best = 0
        var bestScore = Float.greatestFiniteMagnitude
        for e in 0..<4 {
            // Distance to the edge, discounted when the plane is already heading at it.
            let toward = -simd_dot(plane.direction, quad.normals[e])
            let score = quad.distance(plane.position, edge: e) - toward * 0.8
            if score < bestScore { bestScore = score; best = e }
        }
        return -quad.normals[best]
    }

    private func spawnDue(now: Double) {
        guard match.phase == .fighting else { return }
        for s in match.slots.indices {
            guard match.slots[s].plane == nil, let at = match.slots[s].spawnAt, now >= at else { continue }
            let plane = spawn(slot: s, now: now)
            match.slots[s].plane = plane.id
            match.slots[s].spawnAt = nil
            planes.append(plane)
            emit(.spawned(plane: plane.id))
        }
    }

    private func spawn(slot index: Int, now: Double) -> Plane {
        let slot = match.slots[index]
        let type = PlaneType.allCases[rand.index(count: PlaneType.allCases.count)]
        let spec = type.spec
        let weapon = spec.weapons[rand.index(count: spec.weapons.count)]
        let altitude = rand.inRange(ViewRig.bandLow + 0.05, ViewRig.bandHigh - 0.05)

        // A team mostly comes on from its own side; now and then a replacement arrives from
        // somewhere else, which keeps a long team fight from settling into two fronts.
        let edge = (slot.homeEdge.map { rand.next() < 0.75 ? $0 : nil } ?? nil) ?? rand.index(count: 4)
        let quad = rig.visible(atAltitude: altitude)
        let a = quad.corners[edge], b = quad.corners[(edge + 1) % 4]
        let along = a + (b - a) * rand.inRange(0.2, 0.8)
        let position = along - quad.normals[edge] * (spec.size + 0.25)
        let (lo, hi) = rig.wall.bounds
        let aim = rig.wall.centroid + SIMD2(rand.inRange(-0.3, 0.3) * (hi.x - lo.x),
                                            rand.inRange(-0.3, 0.3) * (hi.y - lo.y))
        let heading = atan2(aim.y - position.y, aim.x - position.x)
        let pose = Pose(position: position, altitude: altitude, heading: heading, bank: 0, pitch: 0)
        return Plane(id: makeID(), slot: index, side: slot.side, type: type, weapon: weapon,
                     paper: slot.paper, spec: spec, state: .entering(aim: aim), stateSince: now,
                     pose: pose, previous: pose, speed: spec.cruiseSpeed, health: spec.armour,
                     pilot: PilotMemory(lastShotAt: now, cruiseAltitude: altitude))
    }

    /// Crashes become wrecks, planes that have flown off are let go, and either frees the slot.
    private func retirePlanes(now: Double) {
        var i = 0
        while i < planes.count {
            let p = planes[i]
            var gone = false
            switch p.state {
            case .downed:
                let ground = terrain.surfaceHeight(at: p.position)
                if p.altitude <= ground + 0.015 {
                    let inWater = terrain.isWater(at: p.position)
                    let wreck = Wreck(id: makeID(), type: p.type, paper: p.paper, position: p.position,
                                      ground: ground, heading: p.pose.heading,
                                      roll: max(min(p.pose.bank, 0.6), -0.6) * 0.5,
                                      crashedAt: now, inWater: inWater)
                    wrecks.append(wreck)
                    emit(.crashed(wreck: wreck.id, position: p.position, ground: ground,
                                  inWater: inWater, paper: p.paper))
                    gone = true
                } else if !rig.visible(atAltitude: p.altitude).contains(p.position, margin: -3) {
                    // Spiralled far out of view (it cannot, in practice, but a plane must never
                    // be able to hold its slot forever).
                    gone = true
                }
            case .exiting:
                let outside = !rig.visible(atAltitude: p.altitude).contains(p.position, margin: -(p.spec.size + 0.2))
                if outside || now - p.stateSince > 14 {
                    emit(.exited(plane: p.id))
                    gone = true
                }
            case .entering, .fighting:
                break
            }
            if gone {
                if let s = match.slots.firstIndex(where: { $0.plane == p.id }) {
                    match.slots[s].plane = nil
                    // A replacement after a short beat, so the crash has the screen to itself.
                    match.slots[s].spawnAt = match.phase == .fighting ? now + Double(rand.inRange(1.8, 3.2)) : nil
                }
                planes.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    // MARK: Damage

    func damage(plane index: Int, by shooter: Int, amount: Float, now: Double) {
        guard !planes[index].state.isDowned else { return }
        planes[index].health -= amount
        guard planes[index].health <= 0 else { return }
        let spin: Float = planes[index].turnRate == 0 ? combat.sign() : (planes[index].turnRate > 0 ? 1 : -1)
        planes[index].state = .downed(killer: shooter, spin: spin)
        planes[index].stateSince = now
        planes[index].burstLeft = 0
        emit(.downed(victim: planes[index].id, by: shooter))
        if match.phase == .fighting {
            match.kills += 1
            match.lastKillAt = now
        }
    }
}
