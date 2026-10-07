// Where a tank may drive: dry, gentle ground, clear of the props standing on it.
//
// Asked of every point a tank is about to move onto, so the rule cannot be broken by a waypoint
// chosen badly or a turn taken wide — a tank that would put a tread in a lake or on a cliff
// simply stops and chooses again.
//
// The question is asked of a disc that encloses the whole hull and both treads at any heading
// (`TankSpec.footprint`), against every terrain face the disc overlaps. Five point samples round
// a smaller circle were tried first, and a tank turned so a rear tread corner sat between the
// samples put seven hull vertices over a lake.

import Foundation
import simd

struct Ground {
    let terrain: Terrain
    /// Every prop, each with the room a tank must give it.
    private let obstacles: SpacingGrid
    /// One per terrain face: lake, rock, snow, or too steep for a tank to be seen on.
    private let forbidden: [Bool]

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
        forbidden = terrain.bands.indices.map { face in
            switch terrain.bands[face] {
            case .water, .rock, .snow: return true
            case .shore, .meadow, .hill: return terrain.slope(ofFace: face) > Ground.maxSlope
            }
        }
    }

    /// Whether a tank whose footprint is a disc of `footprint` may stand at `p`: no face under
    /// any part of it forbidden, and no prop in its way. Props are given room from about half the
    /// footprint — the hull's own width — since a tank brushing a tree's canopy is how a tank
    /// threads a wood.
    func isDriveable(_ p: SIMD2<Float>, footprint r: Float) -> Bool {
        !terrain.lattice.anyFace(touching: p, radius: r) { forbidden[$0] }
            && !obstacles.isOccupied(p, radius: r * 0.5)
    }

    /// Whether the straight road from `a` to `b` is driveable all the way.
    func isClear(from a: SIMD2<Float>, to b: SIMD2<Float>, footprint r: Float) -> Bool {
        let length = simd_distance(a, b)
        let steps = max(Int(ceil(length / 0.05)), 1)
        for k in 1...steps where !isDriveable(a + (b - a) * (Float(k) / Float(steps)), footprint: r) {
            return false
        }
        return true
    }
}
