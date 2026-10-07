// One match: who is fighting whom, in what paper, at what size, and when it is over.
//
// A match draws a mode, a crowd size and a roster; after a number of kills or a time limit the
// card names a winner, the survivors fly off and the next one enters. The landscape stays —
// only the fight changes — so a long watch sees free-for-alls and team fights, a few planes and
// a furball, alternate over the same valleys.

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

/// A tank's seat, which works the same way: a destroyed tank's replacement rolls in for the
/// same side.
struct TankSlot {
    let side: Int
    let paper: Paper
    let type: TankType
    let homeEdge: Int?
    var tank: Int?
    var spawnAt: Double?
}

enum MatchPhase: Equatable {
    case fighting
    /// The kill target or the clock has been reached. Nobody fires and nobody respawns; the
    /// card names the winner for a beat before anyone leaves, so the match ends rather than
    /// simply stopping.
    case won(since: Double, until: Double)
    /// Survivors are leaving.
    case ending
    case intermission(until: Double)
}

struct Match {
    let index: Int
    let mode: MatchMode
    let tier: PlaneTier
    /// How big this match's planes are against the v1 roster's, and with them everything that
    /// belongs to them — see `Match.scale(planes:)`.
    let scale: Float
    var slots: [Slot]
    var tankSlots: [TankSlot]
    let killTarget: Int
    let startedAt: Double
    var kills = 0
    var lastKillAt: Double
    /// Kills credited to each side, planes and tanks alike — the card's tally.
    var score: [Int]
    var phase: MatchPhase = .fighting

    /// A match that has not reached its kill target by now ends anyway, so a stalemate can
    /// never hold the screen.
    static let timeLimit: Double = 150
    /// How long the card shows the winner before the survivors turn for home.
    static let victoryBeat: Double = 3.0

    var sides: Int { score.count }

    /// The sides on the most kills, empty when nobody scored at all.
    var leaders: [Int] {
        guard let best = score.max(), best > 0 else { return [] }
        return score.indices.filter { score[$0] == best }
    }

    /// Seconds of the time limit left, never negative.
    func remaining(at now: Double) -> Double { max(0, Match.timeLimit - (now - startedAt)) }

    /// Self-similar scale: a smaller plane is smaller in every length and speed that belongs to
    /// it, so it flies the same number of body lengths a second and turns in the same number of
    /// lengths. The camera and the landscape never change, so more planes cost no landscape;
    /// they buy room by shrinking. Even six planes come out a little under v1's, which read as
    /// slightly too large — and therefore too fast — on the real screen.
    ///
    /// Area-preserving from six planes up — twelve planes cover the sky six did, so "lots" is a
    /// busier sky of smaller planes, not a crowded one — and capped below v1's size for a few.
    /// Chosen by watching: a gentler curve (0.86 at six, 0.63 at twelve) still read as big,
    /// fast planes at "lots".
    static func scale(planes: Int) -> Float {
        min(0.92, 0.82 * (6 / Float(max(planes, 1))).squareRoot())
    }

    static func draw(index: Int, now: Double, config: SimConfig, rand: inout Rand) -> Match {
        let mode: MatchMode
        if let pinned = config.mode {
            mode = pinned
        } else {
            switch config.teams {
            case .ffa: mode = .ffa
            case .teams: mode = rand.next() < 0.5 ? .teams2 : .teams3
            case .surprise: mode = MatchMode.allCases[rand.index(count: MatchMode.allCases.count)]
            }
        }
        let planes: Int
        let tier: PlaneTier
        if let pinned = config.planeCount {
            planes = min(max(pinned, 2), 12)
            tier = PlaneTier(planes: planes)
        } else {
            tier = config.planes.tier ?? PlaneTier.allCases[rand.index(count: PlaneTier.allCases.count)]
            let counts = tier.counts(for: mode)
            planes = counts[rand.index(count: counts.count)]
        }
        let sides = min(mode.sides(planes: planes), planes)

        // Teams fly one clear colour each; a free-for-all gives every plane a different paper.
        // Twelve planes outnumber the twelve papers by none, so the pool is refilled rather than
        // allowed to run dry if a pin ever asks for more.
        var papers: [Paper] = []
        if mode == .ffa {
            var pool: [Paper] = []
            for _ in 0..<sides {
                if pool.isEmpty {
                    pool = [Paper(kind: .notebook, tint: 0), Paper(kind: .graph, tint: 0),
                            Paper(kind: .newspaper, tint: 0), Paper(kind: .kraft, tint: 0)]
                    pool += (0..<Paper.plainCount).map { Paper(kind: .plain, tint: $0) }
                }
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
        // A bigger crowd arrives as a quicker stream, so twelve planes are not still coming on
        // ten seconds into the match.
        let stagger = 2.7 / Double(max(planes, 6))
        for seat in 0..<planes {
            let side = seat % sides
            slots.append(Slot(side: side, paper: papers[side],
                              homeEdge: mode == .ffa ? nil : homeEdges[side % homeEdges.count],
                              plane: nil,
                              spawnAt: now + 0.3 + Double(seat) * stagger + Double(rand.inRange(0, 0.3))))
        }

        let tankSlots = drawTanks(config: config, mode: mode, tier: tier, sides: sides, papers: papers,
                                  homeEdges: homeEdges, now: now, rand: &rand)
        let killTarget = planes * 2 + rand.index(count: planes + 1) + tankSlots.count
        return Match(index: index, mode: mode, tier: tier, scale: scale(planes: planes), slots: slots,
                     tankSlots: tankSlots, killTarget: killTarget, startedAt: now, lastKillAt: now,
                     score: [Int](repeating: 0, count: sides))
    }

    /// At most two tanks a side, per the plan. A free-for-all of twelve one-plane sides with two
    /// tanks each would be a tank battle with planes in it, so there only a few sides get one.
    private static func drawTanks(config: SimConfig, mode: MatchMode, tier: PlaneTier, sides: Int,
                                  papers: [Paper], homeEdges: [Int], now: Double,
                                  rand: inout Rand) -> [TankSlot] {
        let wanted: Bool
        switch config.tanks {
        case .off: wanted = false
        case .always: wanted = true
        case .sometimes: wanted = rand.next() < 0.5
        }
        guard wanted else { return [] }
        var seats: [Int] = []
        if mode == .ffa {
            var pool = Array(0..<sides)
            let count = min(sides, tier == .few ? 2 : 2 + rand.index(count: 2))
            for _ in 0..<count { seats.append(pool.remove(at: rand.index(count: pool.count))) }
        } else {
            let perSide: Int
            switch tier {
            case .few: perSide = 1
            case .some: perSide = 1 + rand.index(count: 2)
            case .lots: perSide = 2
            }
            for side in 0..<sides { seats += [Int](repeating: side, count: perSide) }
        }
        return seats.enumerated().map { order, side in
            TankSlot(side: side, paper: papers[side], type: rand.next() < 0.35 ? .heavy : .light,
                     homeEdge: mode == .ffa ? nil : homeEdges[side % homeEdges.count], tank: nil,
                     // After the first planes, so the match opens in the air.
                     spawnAt: now + 1.5 + Double(order) * 0.8 + Double(rand.inRange(0, 0.6)))
        }
    }
}
