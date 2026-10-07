// Roads for tanks: the ground under the camera cut into cells, each open or not to a tank of
// one size, and routes found through them breadth-first.
//
// Straight-line waypoints drawn at random were tried first and failed in a way the soak caught:
// a tank that rolled into a meadow ringed by woods and a lake found no straight road out in
// thirty tries, and sat there for the rest of the match. A grid search finds the gap in the
// woods if there is one, and says so when there is not — which is how a spawn learns to refuse
// a pocket before a tank is put in it.

import Foundation
import simd

struct NavGrid {
    let origin: SIMD2<Float>
    let cell: Float
    let columns: Int
    let rows: Int
    /// Driveable by a tank of this grid's footprint.
    let open: [Bool]
    /// Inside the tanks' region, where a patrol may go. Entering and leaving cross the rest.
    let inRegion: [Bool]

    init(ground: Ground, footprint: Float, covering view: ConvexQuad, region: ConvexQuad, margin: Float) {
        cell = 0.07
        let (lo, hi) = view.bounds
        origin = lo - SIMD2(repeating: 0.6)
        columns = Int(ceil((hi.x - lo.x + 1.2) / cell))
        rows = Int(ceil((hi.y - lo.y + 1.2) / cell))
        var open = [Bool](repeating: false, count: columns * rows)
        var inside = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let p = origin + SIMD2(Float(column) + 0.5, Float(row) + 0.5) * cell
                open[index] = ground.isDriveable(p, footprint: footprint)
                inside[index] = region.contains(p, margin: margin)
            }
        }
        self.open = open
        inRegion = inside
    }

    func index(of p: SIMD2<Float>) -> Int? {
        let g = (p - origin) / cell
        let column = Int(floor(g.x)), row = Int(floor(g.y))
        guard column >= 0, row >= 0, column < columns, row < rows else { return nil }
        return row * columns + column
    }

    func center(of index: Int) -> SIMD2<Float> {
        origin + SIMD2(Float(index % columns) + 0.5, Float(index / columns) + 0.5) * cell
    }

    /// Every open cell reachable from `start`, with its parent on a shortest route and its depth
    /// in cells, in the order found — nearest first. `blocked` closes cells a tank must not
    /// route through (another tank standing there). The start cell counts as open whatever it
    /// is, so a tank whose own cell rounds the wrong way can still leave it.
    func search(from start: SIMD2<Float>, blocked: (SIMD2<Float>) -> Bool) -> Search? {
        guard let first = index(of: start) else { return nil }
        var parent = [Int32](repeating: -1, count: open.count)
        var depth = [UInt16](repeating: 0, count: open.count)
        var order = [first]
        parent[first] = Int32(first)
        var head = 0
        while head < order.count {
            let current = order[head]
            head += 1
            let column = current % columns, row = current / columns
            for (dx, dy) in NavGrid.steps {
                let c = column + dx, r = row + dy
                guard c >= 0, r >= 0, c < columns, r < rows else { continue }
                let next = r * columns + c
                guard parent[next] < 0, open[next] else { continue }
                // No cutting a corner between two closed cells: the diagonal would graze both.
                if dx != 0 && dy != 0, !open[row * columns + c] || !open[r * columns + column] { continue }
                guard !blocked(center(of: next)) else { continue }
                parent[next] = Int32(current)
                depth[next] = depth[current] &+ 1
                order.append(next)
            }
        }
        return Search(grid: self, start: first, parent: parent, depth: depth, order: order)
    }

    private static let steps = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]

    struct Search {
        let grid: NavGrid
        let start: Int
        let parent: [Int32]
        let depth: [UInt16]
        /// Reached cells, nearest first.
        let order: [Int]

        /// From `position` — the tank's own, which is not its cell's centre — through the cells
        /// to `goal`, pulled taut: every corner the road can cut in a straight line is cut, so a
        /// tank drives a few long legs rather than a staircase of cell centres.
        func route(from position: SIMD2<Float>, to goal: Int, ground: Ground, footprint: Float) -> [SIMD2<Float>] {
            var cells: [Int] = []
            var at = goal
            while at != start {
                cells.append(at)
                at = Int(parent[at])
            }
            let points = [position, grid.center(of: start)] + cells.reversed().map(grid.center(of:))
            var taut: [SIMD2<Float>] = []
            var from = 0
            while from < points.count - 1 {
                var to = points.count - 1
                while to > from + 1, !ground.isClear(from: points[from], to: points[to], footprint: footprint) { to -= 1 }
                taut.append(points[to])
                from = to
            }
            return taut
        }
    }
}
