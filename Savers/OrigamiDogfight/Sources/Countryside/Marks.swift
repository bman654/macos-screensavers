// What a fight leaves on the land: a char mark where each plane or tank burned, and now and then
// a tree the fire spread to, burnt black until the next match folds it back to green.
//
// Read off the sim's own crash events, and never fed back: a burning tree sets fire to nothing,
// blocks nothing and scores nothing. The marks are the countryside's, kept beside the sim across
// an idle release so a rebuilt scene shows the same scorched ground.

import Foundation
import simd

struct Scorch {
    /// The wreck that made it.
    let id: Int
    let position: SIMD2<Float>
    /// Across, metres: a plane's or a tank's length, scaled with it.
    let size: Float
    let bornAt: Double
    /// When the match it belongs to ended, from which it fades.
    var fadeFrom: Double?
    /// Turns the char's ragged edge, so no two marks are the same shape.
    let turn: Float
}

struct TreeFire {
    /// The tree, an index into the sim's `props`.
    let prop: Int
    let catchesAt: Double
    /// When the next match began and the tree started folding back to green.
    var restoreFrom: Double?

    static let burnTime: Double = 8
    /// How long the char takes to fold back to green.
    static let restoreTime: Double = 1.6

    func burning(at t: Double) -> Bool { t >= catchesAt && t < catchesAt + TreeFire.burnTime }
}

struct Marks {
    private(set) var scorches: [Scorch] = []
    private(set) var fires: [TreeFire] = []

    /// A fade over three seconds as the next match comes on.
    static let fadeTime: Double = 3
    /// A long match with lots of planes leaves a few dozen; past this the oldest go first.
    static let scorchCap = 40
    /// How often a crash on land spreads to a tree near enough to catch.
    static let spreadChance: Float = 0.25

    /// `at` is when it burned: the wreck's own crash time when the sim still has the wreck,
    /// which is what lets a mark made during a warmup be the age it really is.
    mutating func burned(at position: SIMD2<Float>, size: Float, time: Double, id: Int,
                         props: [PropSpot], seed: UInt64) {
        var rand = Rand(seed: seed ^ UInt64(truncatingIfNeeded: id) &* 0x9E37_79B9 ^ 0x5C0_4C11)
        scorches.append(Scorch(id: id, position: position, size: size, bornAt: time, fadeFrom: nil,
                               turn: rand.inRange(0, 2 * .pi)))
        if scorches.count > Marks.scorchCap { scorches.removeFirst(scorches.count - Marks.scorchCap) }

        guard rand.next() < Marks.spreadChance else { return }
        // The nearest tree within reach of the flames — a little further for a bigger fire —
        // that is not already burnt.
        let reach: Float = 0.12 + 0.8 * size
        var best: (index: Int, distance: Float)?
        for index in props.indices where props[index].kind == .tree {
            let d = simd_distance(props[index].position, position)
            guard d < reach, d < best?.distance ?? .infinity,
                  !fires.contains(where: { $0.prop == index }) else { continue }
            best = (index, d)
        }
        guard let tree = best else { return }
        // It catches after the fire has taken hold, sooner the closer it stands.
        fires.append(TreeFire(prop: tree.index,
                              catchesAt: time + 1.5 + Double(tree.distance / reach) * 3 + Double(rand.inRange(0, 1)),
                              restoreFrom: nil))
    }

    /// A new match: the ground starts to clear and the trees fold back to green. A tree whose
    /// fire had not yet caught never catches.
    mutating func matchBegan(at time: Double) {
        for i in scorches.indices where scorches[i].fadeFrom == nil { scorches[i].fadeFrom = time }
        fires.removeAll { $0.catchesAt > time }
        // One still alight burns out first: green paper folding out of a flame reads as a glitch.
        for i in fires.indices where fires[i].restoreFrom == nil {
            fires[i].restoreFrom = max(time, fires[i].catchesAt + TreeFire.burnTime)
        }
    }

    mutating func forget(before time: Double) {
        scorches.removeAll { ($0.fadeFrom ?? .infinity) + Marks.fadeTime < time }
        fires.removeAll { ($0.restoreFrom ?? .infinity) + TreeFire.restoreTime < time }
    }
}
