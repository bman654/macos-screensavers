// What stands still on the landscape and moves in place: windmills turning on the edge of the
// hamlets and on the hills, and the boats riding at their moorings.
//
// **Nothing here may change the fight.** The sim's props are what the tanks drive round
// (`Ground`), so a windmill is not a new prop: it takes the place of a house or a rock the sim
// already gives room to, and is drawn there instead. A tank therefore steers round a windmill
// exactly as it steered round the house, and a summer fight is the fight it was before there were
// windmills. The boats are the sim's own and stay its own; only the drawing lets them drift.

import Foundation
import simd

struct Windmill {
    /// The prop it is drawn in place of, an index into the sim's `props`.
    let prop: Int
    let position: SIMD2<Float>
    let ground: Float
    /// Which way the sails face, as a sim heading.
    let yaw: Float
    let scale: Float
    /// Radians a second, and where in the turn it started — no two mills in step.
    let rate: Float
    let phase: Float
}

struct Mooring {
    /// The boat, an index into the sim's `props`.
    let prop: Int
    /// How far it may drift from where it was put and still have open water all round it.
    let reach: Float
    /// Its drift and its bob, each on its own slow clock.
    let rates: SIMD3<Float>
    let phases: SIMD3<Float>
}

enum Layout {
    /// The middle of the view at 16:9 and a little more — where a windmill is seen rather than
    /// cropped at the edge.
    static let shown = SIMD2<Float>(2.6, 1.5)

    static func windmills(props: [PropSpot], terrain: Terrain, seed: UInt64) -> [Windmill] {
        var rand = Rand(seed: seed ^ 0x3171_D3A1_150F)
        var mills: [Windmill] = []

        func mill(_ index: Int) -> Windmill {
            let spot = props[index]
            // Facing the bottom of the screen, give or take, so the sails are seen across their
            // face rather than edge-on from a camera looking north and down.
            return Windmill(prop: index, position: spot.position, ground: spot.ground,
                            yaw: -.pi / 2 + rand.inRange(-0.35, 0.35), scale: rand.inRange(0.9, 1.1),
                            rate: rand.inRange(0.55, 0.9), phase: rand.inRange(0, 2 * .pi))
        }
        func isShown(_ p: SIMD2<Float>) -> Bool { abs(p.x) < shown.x && abs(p.y) < shown.y }

        // A mill on the outskirts of most hamlets in view: the house furthest from its
        // neighbours. One out of view would be a mill nobody ever sees turn.
        for hamlet in hamlets(props) where mills.count < 3 {
            guard rand.next() < 0.7 else { continue }
            let centre = hamlet.map { props[$0].position }.reduce(.zero, +) / Float(hamlet.count)
            guard isShown(centre), let outskirt = hamlet.max(by: { simd_distance(props[$0].position, centre)
                                                  < simd_distance(props[$1].position, centre) }),
                  hamlet.count >= 3 else { continue }
            mills.append(mill(outskirt))
        }
        // And one on a hill, now and then, on a rock the sim already keeps tanks off — a gentle
        // one in view, since a mill on a cliff reads as a mistake.
        let hillRocks = props.indices.filter { index in
            let spot = props[index]
            return spot.kind == .rock && terrain.band(at: spot.position) == .hill
                && terrain.slope(at: spot.position) < 0.3 && isShown(spot.position)
        }
        if !hillRocks.isEmpty, rand.next() < 0.75 {
            mills.append(mill(hillRocks[rand.index(count: hillRocks.count)]))
        }
        return mills
    }

    /// Houses grouped by nearness: a house within 0.6 m of a hamlet's first house is in it.
    /// The scatter places hamlets well apart (`Scatter`), so this recovers exactly its groups.
    static func hamlets(_ props: [PropSpot]) -> [[Int]] {
        var groups: [[Int]] = []
        for index in props.indices where props[index].kind == .house {
            if let g = groups.firstIndex(where: { simd_distance(props[$0[0]].position, props[index].position) < 0.6 }) {
                groups[g].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }

    static func moorings(props: [PropSpot], terrain: Terrain, seed: UInt64) -> [Mooring] {
        var rand = Rand(seed: seed ^ 0xB0A7_5D21_F7)
        return props.indices.filter { props[$0].kind == .boat }.map { index in
            let p = props[index].position
            // The widest drift, up to 7 cm, that keeps open water a boat's half-length beyond it
            // in every direction — a boat that drifted onto the beach would read as beached.
            var reach: Float = 0.07
            while reach > 0 {
                let clear = (0..<12).allSatisfy { k in
                    let a = Float(k) * .pi / 6
                    return terrain.isLake(at: p + SIMD2(cos(a), sin(a)) * (reach + 0.1))
                }
                if clear { break }
                reach -= 0.01
            }
            return Mooring(prop: index, reach: max(reach, 0),
                           rates: SIMD3(rand.inRange(0.04, 0.07), rand.inRange(0.05, 0.08), rand.inRange(1.1, 1.6)),
                           phases: SIMD3(rand.inRange(0, 2 * .pi), rand.inRange(0, 2 * .pi), rand.inRange(0, 2 * .pi)))
        }
    }
}
