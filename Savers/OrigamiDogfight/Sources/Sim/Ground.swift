// Where a tank may drive: dry, gentle ground, clear of the props standing on it.
//
// Asked of every point a tank is about to move onto, so the rule cannot be broken by a waypoint
// chosen badly or a turn taken wide — a tank that would put a tread in a lake or on a cliff
// simply stops and chooses again.

import Foundation
import simd

struct Ground {
    let terrain: Terrain
    /// Every prop, each with the room a tank must give it.
    private let obstacles: SpacingGrid

    /// Rise over run. A meadow's crumple is about 0.1 and a hill's flank 0.3–0.5; past this a
    /// tank would be seen climbing a slope it plainly could not.
    static let maxSlope: Float = 0.42

    init(terrain: Terrain, props: [PropSpot]) {
        self.terrain = terrain
        var grid = SpacingGrid(cell: 0.1)
        for spot in props {
            // A tank threads between trees — only the trunk is in its way, and woods it could
            // not enter at all would leave whole valleys empty — but gives a house, a rock or a
            // boat its whole footprint.
            let room: Float
            switch spot.kind {
            case .tree: room = 0.02
            case .rock: room = 0.045 * spot.scale
            case .house: room = 0.07 * spot.scale
            case .boat: room = 0.06
            }
            grid.insert(spot.position, radius: room)
        }
        obstacles = grid
    }

    /// Whether a tank of `clearance` may stand at `p`: its middle and four points round its rim
    /// on dry, gentle land, and nothing standing in its way.
    func isDriveable(_ p: SIMD2<Float>, clearance r: Float) -> Bool {
        for offset in [SIMD2<Float>(0, 0), SIMD2(r, 0), SIMD2(-r, 0), SIMD2(0, r), SIMD2(0, -r)] {
            switch terrain.band(at: p + offset) {
            case .water, .rock, .snow: return false
            case .shore, .meadow, .hill: break
            }
            if terrain.slope(at: p + offset) > Ground.maxSlope { return false }
        }
        return !obstacles.isOccupied(p, radius: r * 0.6)
    }

    /// Whether the straight road from `a` to `b` is driveable all the way.
    func isClear(from a: SIMD2<Float>, to b: SIMD2<Float>, clearance r: Float) -> Bool {
        let length = simd_distance(a, b)
        let steps = max(Int(ceil(length / 0.05)), 1)
        for k in 1...steps where !isDriveable(a + (b - a) * (Float(k) / Float(steps)), clearance: r) {
            return false
        }
        return true
    }
}
