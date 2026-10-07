// One match: who is fighting whom, in what paper, and when it is over.
//
// A match draws a mode and a roster; after a number of kills or a time limit the survivors fly
// off and the next one enters. The landscape stays — only the fight changes — so a long watch
// sees free-for-alls and team fights alternate over the same valleys.

import Foundation

enum MatchMode: String, CaseIterable {
    case ffa, teams2, teams3

    /// How many sides fight, given how many planes.
    func sides(planes: Int) -> Int {
        switch self {
        case .ffa: return planes
        case .teams2: return 2
        case .teams3: return 3
        }
    }
}

/// A seat in the roster. A replacement for a downed plane takes the same seat, so it flies for
/// the same side in the same paper.
struct Slot {
    let side: Int
    let paper: Paper
    /// The screen edge this side comes on from, so teams arrive from opposite sides and open
    /// with a head-on pass. Nil in a free-for-all, where every entry picks its own.
    let homeEdge: Int?
    var plane: Int?
    var spawnAt: Double?
}

enum MatchPhase: Equatable {
    case fighting
    /// The kill target or the clock has been reached: survivors are leaving, nobody respawns.
    case ending
    case intermission(until: Double)
}

struct Match {
    let index: Int
    let mode: MatchMode
    var slots: [Slot]
    let killTarget: Int
    let startedAt: Double
    var kills = 0
    var lastKillAt: Double
    var phase: MatchPhase = .fighting

    /// A match that has not reached its kill target by now ends anyway, so a stalemate can
    /// never hold the screen.
    static let timeLimit: Double = 150

    static func draw(index: Int, now: Double, config: SimConfig, rand: inout Rand) -> Match {
        let mode = config.mode ?? MatchMode.allCases[rand.index(count: MatchMode.allCases.count)]
        let planes: Int
        if let pinned = config.planeCount {
            planes = min(max(pinned, 2), 8)
        } else {
            switch mode {
            case .ffa: planes = 4 + rand.index(count: 3)
            case .teams2: planes = rand.next() < 0.5 ? 4 : 6
            case .teams3: planes = 6
            }
        }
        let sides = min(mode.sides(planes: planes), planes)

        // Teams fly one clear colour each; a free-for-all gives every plane a different paper.
        var papers: [Paper] = []
        if mode == .ffa {
            var pool: [Paper] = [Paper(kind: .notebook, tint: 0), Paper(kind: .graph, tint: 0),
                                 Paper(kind: .newspaper, tint: 0), Paper(kind: .kraft, tint: 0)]
            pool += (0..<Paper.plainCount).map { Paper(kind: .plain, tint: $0) }
            for _ in 0..<sides {
                papers.append(pool.remove(at: rand.index(count: pool.count)))
            }
        } else {
            var colours = TeamColours.indices
            for _ in 0..<sides {
                papers.append(Paper(kind: .plain, tint: colours.remove(at: rand.index(count: colours.count))))
            }
        }

        // Home edges: two teams face each other across the long axis; three come from three sides.
        let flip = rand.next() < 0.5
        let homeEdges: [Int] = mode == .teams3 ? [3, 1, flip ? 0 : 2] : (flip ? [3, 1] : [1, 3])

        var slots: [Slot] = []
        for seat in 0..<planes {
            let side = seat % sides
            slots.append(Slot(side: side, paper: papers[side],
                              homeEdge: mode == .ffa ? nil : homeEdges[side % homeEdges.count],
                              plane: nil,
                              // Staggered so the planes arrive as a stream rather than a wall.
                              spawnAt: now + 0.3 + Double(seat) * 0.45 + Double(rand.inRange(0, 0.3))))
        }
        let killTarget = planes * 2 + rand.index(count: planes + 1)
        return Match(index: index, mode: mode, slots: slots, killTarget: killTarget,
                     startedAt: now, lastKillAt: now)
    }
}

/// Harness pins, from `ORIGAMI_MODE` and `ORIGAMI_PLANES`. Empty in a real run.
struct SimConfig {
    var mode: MatchMode?
    var planeCount: Int?
}
