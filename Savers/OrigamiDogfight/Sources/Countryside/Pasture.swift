// Sheep: a few small flocks, each on an open meadow of its own, grazing and wandering slowly.
//
// Mostly they stand still — a sheep is a grazing animal first — and now and then one walks a few
// of its own lengths to fresh grass. They never set foot on a lake, frozen or not, nor on a
// cliff, a beach or a rock; never walk through a tree or a house; and keep a body's width from
// one another, so a flock never folds into one white lump. A tank rolling through their field
// sends them trotting out of its way, which is the one thing the fight does to them, and nothing
// they do reaches the fight.
//
// Fixed-step, like the sim and for the same reason, on a clock of its own: 30 steps a second, a
// tenth of the sim's, since a sheep moves a few millimetres a second.

import Foundation
import simd

struct Sheep {
    var position: SIMD2<Float>
    var previous: SIMD2<Float>
    var heading: Float
    var previousHeading: Float
    var target: SIMD2<Float>?
    var speed: Float = 0
    var restUntil: Double
    let flock: Int
    let size: Float
}

struct Pasture {
    struct Field {
        let centre: SIMD2<Float>
        let radius: Float
    }

    static let step: Double = 1.0 / 30
    /// A body length and a little, centre to centre.
    static let spacing: Float = 0.042

    private(set) var fields: [Field] = []
    private(set) var sheep: [Sheep] = []
    private(set) var steps = 0
    private var rand: Rand
    private let terrain: Terrain
    /// Every prop a sheep must walk round, by the room it takes.
    private let obstacles: SpacingGrid

    init(terrain: Terrain, props: [PropSpot], seed: UInt64) {
        self.terrain = terrain
        rand = Rand(seed: seed ^ 0x5EE9_FAB1_E5)
        var grid = SpacingGrid(cell: 0.1)
        for spot in props {
            switch spot.kind {
            case .tree: grid.insert(spot.position, radius: 0.022 * spot.scale)
            case .rock: grid.insert(spot.position, radius: 0.035 * spot.scale)
            case .house: grid.insert(spot.position, radius: 0.07 * spot.scale)
            case .boat: break
            }
        }
        obstacles = grid

        // Open grass in the middle of the view: a meadow face, flat, a lake's width from any
        // water, and no wood — a field with three trees in it is a field, one with ten is a wood.
        let flocks = 2 + rand.index(count: 2)
        for _ in 0..<400 where fields.count < flocks {
            let centre = SIMD2(rand.inRange(-2.3, 2.3), rand.inRange(-1.3, 1.3))
            let radius: Float = rand.inRange(0.22, 0.32)
            guard terrain.band(at: centre) == .meadow, terrain.slope(at: centre) < 0.22,
                  fields.allSatisfy({ simd_distance($0.centre, centre) > 0.9 }),
                  !grid.isOccupied(centre, radius: 0.12),
                  (0..<12).allSatisfy({ k in
                      let a = Float(k) * .pi / 6
                      let edge = centre + SIMD2(cos(a), sin(a)) * radius
                      return isGrass(edge) && !terrain.isLake(at: centre + SIMD2(cos(a), sin(a)) * (radius + 0.15))
                  }),
                  props.filter({ $0.kind == .tree && simd_distance($0.position, centre) < radius }).count < 4
            else { continue }
            let field = Field(centre: centre, radius: radius)
            fields.append(field)
            let count = 3 + rand.index(count: 4)
            var placed = 0
            for _ in 0..<60 where placed < count {
                let a = rand.inRange(0, 2 * .pi), r = sqrt(rand.next()) * radius * 0.7
                let p = centre + SIMD2(cos(a), sin(a)) * r
                guard isGrass(p), isClear(p, ignoring: nil) else { continue }
                let heading = rand.inRange(-.pi, .pi)
                sheep.append(Sheep(position: p, previous: p, heading: heading, previousHeading: heading,
                                   target: nil, restUntil: Double(rand.inRange(0, 6)), flock: fields.count - 1,
                                   size: rand.inRange(0.9, 1.1)))
                placed += 1
            }
        }
    }

    /// Ground a sheep may stand on: grass, not too steep, not a lake.
    private func isGrass(_ p: SIMD2<Float>) -> Bool {
        let band = terrain.band(at: p)
        return (band == .meadow || band == .hill) && !terrain.isLake(at: p) && terrain.slope(at: p) < 0.4
            && !obstacles.isOccupied(p, radius: 0.012)
    }

    private func isClear(_ p: SIMD2<Float>, ignoring index: Int?) -> Bool {
        sheep.indices.allSatisfy { j in
            j == index || simd_distance(sheep[j].position, p) > Pasture.spacing
                && (sheep[j].target.map { simd_distance($0, p) > Pasture.spacing } ?? true)
        }
    }

    /// Steps the flocks up to `time`. `tanks` are where any tank is now, for the sheep to keep
    /// clear of. A long gap — a scene built late, or a stall — is skipped rather than walked.
    mutating func advance(to time: Double, tanks: [SIMD2<Float>]) {
        let due = Int(floor(time / Pasture.step)) - steps
        if due > 90 || due < 0 {
            steps = Int(floor(time / Pasture.step))
            for i in sheep.indices { sheep[i].previous = sheep[i].position; sheep[i].previousHeading = sheep[i].heading }
            return
        }
        for _ in 0..<due {
            steps += 1
            stepOnce(now: Double(steps) * Pasture.step, tanks: tanks)
        }
    }

    private mutating func stepOnce(now: Double, tanks: [SIMD2<Float>]) {
        let dt = Float(Pasture.step)
        for i in sheep.indices {
            var s = sheep[i]
            s.previous = s.position
            s.previousHeading = s.heading
            let field = fields[s.flock]

            // A tank close by: trot straight away from it, as far as the grass allows.
            if let tank = tanks.min(by: { simd_distance($0, s.position) < simd_distance($1, s.position) }),
               simd_distance(tank, s.position) < 0.3 {
                let away = simd_normalize(s.position - tank + SIMD2(1e-4, 0))
                let goal = s.position + away * 0.12
                if isGrass(goal) {
                    s.target = goal
                    s.speed = 0.09
                    s.restUntil = now
                }
            }

            if s.target == nil, now >= s.restUntil {
                // A few lengths to fresh grass, somewhere in its own field and nobody else's spot.
                for _ in 0..<6 {
                    let a = rand.inRange(0, 2 * .pi), r = rand.inRange(0.04, 0.14)
                    var goal = s.position + SIMD2(cos(a), sin(a)) * r
                    // Drawn back toward the middle of the field from its edge.
                    if simd_distance(goal, field.centre) > field.radius {
                        goal = field.centre + simd_normalize(goal - field.centre) * field.radius * 0.8
                    }
                    if isGrass(goal), isClear(goal, ignoring: i) {
                        s.target = goal
                        s.speed = rand.inRange(0.018, 0.03)
                        break
                    }
                }
                if s.target == nil { s.restUntil = now + Double(rand.inRange(1, 3)) }
            }

            if let goal = s.target {
                let to = goal - s.position
                let distance = simd_length(to)
                if distance < 0.006 {
                    s.target = nil
                    s.speed = 0
                    s.restUntil = now + Double(rand.inRange(4, 14))
                } else {
                    // Turn toward it — a sheep walks where it faces — then step forward.
                    let want = atan2(to.y, to.x)
                    let turn = max(min((want - s.heading).wrappedAngle, 2.2 * dt), -2.2 * dt)
                    s.heading = (s.heading + turn).wrappedAngle
                    let facing = SIMD2(cos(s.heading), sin(s.heading))
                    let pace = abs((want - s.heading).wrappedAngle) < 0.6 ? s.speed : s.speed * 0.25
                    let next = s.position + facing * min(pace * dt, distance)
                    if isGrass(next), isClear(next, ignoring: i) || !isClear(s.position, ignoring: i) {
                        s.position = next
                    } else {
                        // Blocked: give up and graze where it stands.
                        s.target = nil
                        s.speed = 0
                        s.restUntil = now + Double(rand.inRange(1, 4))
                    }
                }
            }
            sheep[i] = s
        }
        separate()
    }

    /// Two sheep closer than a body length step apart — half the overlap each, along the line
    /// between them — where the grass allows. Only a trot from a tank can bring that about.
    private mutating func separate() {
        for i in sheep.indices {
            for j in (i + 1)..<sheep.count {
                let d = sheep[j].position - sheep[i].position
                let distance = simd_length(d)
                guard distance < Pasture.spacing * 0.9 else { continue }
                let push = (distance > 1e-5 ? d / distance : SIMD2(1, 0)) * (Pasture.spacing * 0.9 - distance) * 0.5
                if isGrass(sheep[i].position - push) { sheep[i].position -= push }
                if isGrass(sheep[j].position + push) { sheep[j].position += push }
            }
        }
    }

    /// Between the last two steps, for a frame that falls between them.
    func pose(of index: Int, at time: Double) -> (position: SIMD2<Float>, heading: Float) {
        let s = sheep[index]
        let alpha = Float(min(max(time / Pasture.step - Double(steps - 1), 0), 1))
        return (s.previous + (s.position - s.previous) * alpha,
                s.previousHeading + (s.heading - s.previousHeading).wrappedAngle * alpha)
    }
}
