// Paper roads: strips laid between the hamlets, and one from a hamlet out past the edge of the
// view so the little cars have somewhere to come from.
//
// Found as the cheapest path over a grid, where steep ground costs more than flat and a wood more
// than a field, so a road winds along the valley floor and round the woods the way a country lane
// does, rather than striking out in a straight line over a hill. Lakes, rock, snow and anything
// too steep are closed to it; so are the houses and rocks, which it passes rather than crosses.
// Then smoothed, so it reads as a strip of paper laid down in curves rather than a staircase.
//
// Cosmetic like everything in this folder: a tank crosses a road as it crosses a field.

import Foundation
import simd

struct Road {
    /// The centre line, a point every few centimetres, in sim ground coordinates.
    let points: [SIMD2<Float>]
    /// Distance along the road at each point.
    let distances: [Float]

    var length: Float { distances.last ?? 0 }

    init(points: [SIMD2<Float>]) {
        self.points = points
        var d: [Float] = [0]
        for i in 1..<max(points.count, 1) { d.append(d[i - 1] + simd_distance(points[i - 1], points[i])) }
        distances = d
    }

    /// The point `s` metres along, and the direction of travel there.
    func sample(at s: Float) -> (position: SIMD2<Float>, direction: SIMD2<Float>) {
        let s = min(max(s, 0), length)
        var lo = 0, hi = distances.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if distances[mid] <= s { lo = mid } else { hi = mid }
        }
        let span = max(distances[hi] - distances[lo], 1e-6)
        let t = (s - distances[lo]) / span
        let direction = simd_normalize(points[hi] - points[lo] + SIMD2(1e-7, 0))
        return (points[lo] + (points[hi] - points[lo]) * t, direction)
    }
}

enum Roads {
    /// Half a road's width, metres — a lane the size of the toy cars on it.
    static let halfWidth: Float = 0.022
    /// The grid the path is found on: fine enough to thread between two houses.
    fileprivate static let cell: Float = 0.05
    /// The region searched: the decorated middle of the terrain (`Scatter.region`) and a margin,
    /// so a road off the edge of the view has somewhere to go.
    fileprivate static let extent = SIMD2<Float>(3.6, 2.4)

    static func build(props: [PropSpot], terrain: Terrain, seed: UInt64) -> [Road] {
        var rand = Rand(seed: seed ^ 0x40AD_5EED_17)
        let hamlets = Layout.hamlets(props).filter { $0.count >= 2 }
        guard !hamlets.isEmpty else { return [] }
        let grid = CostGrid(terrain: terrain, props: props)

        // Each hamlet's middle, moved to the nearest open cell — the middle of a hamlet is often
        // the inside of one of its houses.
        let centres = hamlets.compactMap { group -> SIMD2<Float>? in
            let mean = group.map { props[$0].position }.reduce(.zero, +) / Float(group.count)
            return grid.nearestOpen(to: mean)
        }
        var pairs: [(SIMD2<Float>, SIMD2<Float>)] = []
        // A minimum spanning tree: every hamlet reachable, no two roads doing the same job.
        var joined = [0]
        while joined.count < centres.count {
            var best: (from: Int, to: Int, distance: Float)?
            for a in joined {
                for b in centres.indices where !joined.contains(b) {
                    let d = simd_distance(centres[a], centres[b])
                    if d < best?.distance ?? .infinity { best = (a, b, d) }
                }
            }
            guard let best else { break }
            joined.append(best.to)
            pairs.append((centres[best.from], centres[best.to]))
        }
        // And one road out of the view, from a hamlet to the edge it is nearest.
        let start = centres[rand.index(count: centres.count)]
        let exits = [SIMD2(extent.x - 0.1, start.y), SIMD2(-extent.x + 0.1, start.y),
                     SIMD2(start.x, extent.y - 0.1), SIMD2(start.x, -extent.y + 0.1)]
        if let exit = exits.min(by: { simd_distance($0, start) < simd_distance($1, start) }),
           let open = grid.nearestOpen(to: exit) {
            pairs.append((start, open))
        }

        return pairs.compactMap { a, b in
            guard simd_distance(a, b) > 0.3, let path = grid.path(from: a, to: b) else { return nil }
            return Road(points: smooth(path, terrain: terrain))
        }
    }

    /// Corners cut four times over (Chaikin), then resampled every 2.5 cm — but never across
    /// water: a cut that would take a bend over the lake's edge is left as the grid had it.
    private static func smooth(_ path: [SIMD2<Float>], terrain: Terrain) -> [SIMD2<Float>] {
        var line = path
        for _ in 0..<4 where line.count > 2 {
            var next = [line[0]]
            for i in 0..<(line.count - 1) {
                let q = line[i] * 0.75 + line[i + 1] * 0.25, r = line[i] * 0.25 + line[i + 1] * 0.75
                next += terrain.isLake(at: q) || terrain.isLake(at: r) ? [line[i + 1]] : [q, r]
            }
            next.append(line[line.count - 1])
            line = next
        }
        let road = Road(points: line)
        let count = max(Int(road.length / 0.025), 1)
        return (0...count).map { road.sample(at: road.length * Float($0) / Float(count)).position }
    }
}

/// The ground as a road builder sees it: what a step onto each cell costs, or that it is closed.
private struct CostGrid {
    let columns: Int, rows: Int
    let cell: Float
    let origin: SIMD2<Float>
    /// Per cell; infinity where no road may go.
    let cost: [Float]

    init(terrain: Terrain, props: [PropSpot]) {
        cell = Roads.cell
        let extent = Roads.extent
        origin = -extent
        columns = Int(2 * extent.x / cell) + 1
        rows = Int(2 * extent.y / cell) + 1
        var blocks = SpacingGrid(cell: 0.1)
        var woods = SpacingGrid(cell: 0.1)
        for spot in props {
            switch spot.kind {
            case .house: blocks.insert(spot.position, radius: 0.075 * spot.scale)
            case .rock: blocks.insert(spot.position, radius: 0.04 * spot.scale)
            case .tree: woods.insert(spot.position, radius: 0.03)
            case .boat: break
            }
        }
        var cost = [Float](repeating: .infinity, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                let p = origin + SIMD2(Float(i), Float(j)) * cell
                let band = terrain.band(at: p)
                guard band == .meadow || band == .hill || band == .shore, !terrain.isLake(at: p),
                      !blocks.isOccupied(p, radius: Roads.halfWidth) else { continue }
                let slope = terrain.slope(at: p)
                guard slope < 0.33 else { continue }
                // A wood is not closed — some valleys are wooded end to end — but it costs as
                // much as a long detour, which is what a road through one should be.
                let wooded: Float = woods.isOccupied(p, radius: Roads.halfWidth) ? 6 : 0
                cost[j * columns + i] = 1 + 20 * slope * slope + wooded
            }
        }
        self.cost = cost
    }

    private func index(_ p: SIMD2<Float>) -> Int? {
        let g = (p - origin) / cell
        let i = Int(g.x.rounded()), j = Int(g.y.rounded())
        guard i >= 0, j >= 0, i < columns, j < rows else { return nil }
        return j * columns + i
    }

    private func point(_ index: Int) -> SIMD2<Float> {
        origin + SIMD2(Float(index % columns), Float(index / columns)) * cell
    }

    /// The open cell nearest a point, within twenty centimetres.
    func nearestOpen(to p: SIMD2<Float>) -> SIMD2<Float>? {
        guard let centre = index(p) else { return nil }
        let ci = centre % columns, cj = centre / columns
        var best: (Int, Float)?
        for dj in -4...4 {
            for di in -4...4 {
                let i = ci + di, j = cj + dj
                guard i >= 0, j >= 0, i < columns, j < rows, cost[j * columns + i].isFinite else { continue }
                let d = simd_distance(point(j * columns + i), p)
                if d < best?.1 ?? .infinity { best = (j * columns + i, d) }
            }
        }
        return best.map { point($0.0) }
    }

    /// A* over the eight neighbours, the straight-line distance its heuristic.
    func path(from a: SIMD2<Float>, to b: SIMD2<Float>) -> [SIMD2<Float>]? {
        guard let start = index(a), let goal = index(b), cost[start].isFinite, cost[goal].isFinite else { return nil }
        var best = [Float](repeating: .infinity, count: cost.count)
        var came = [Int](repeating: -1, count: cost.count)
        var open = MinHeap()
        best[start] = 0
        open.push(start, priority: simd_distance(a, b))
        let goalPoint = point(goal)
        while let current = open.pop() {
            if current == goal { break }
            let ci = current % columns, cj = current / columns
            for dj in -1...1 {
                for di in -1...1 where di != 0 || dj != 0 {
                    let i = ci + di, j = cj + dj
                    guard i >= 0, j >= 0, i < columns, j < rows else { continue }
                    let next = j * columns + i
                    guard cost[next].isFinite else { continue }
                    let step = (di != 0 && dj != 0 ? 1.4142 : 1) * cell * (cost[current] + cost[next]) / 2
                    let g = best[current] + step
                    guard g < best[next] else { continue }
                    best[next] = g
                    came[next] = current
                    open.push(next, priority: g + simd_distance(point(next), goalPoint))
                }
            }
        }
        guard best[goal].isFinite else { return nil }
        var path = [goal]
        while let last = path.last, came[last] >= 0 { path.append(came[last]) }
        return path.reversed().map(point)
    }
}

/// A binary heap of indices by priority, lowest first. Stale entries — an index pushed again
/// with a better priority — are simply popped later and do no harm, since A* re-checks costs.
private struct MinHeap {
    private var items: [(index: Int, priority: Float)] = []

    mutating func push(_ index: Int, priority: Float) {
        items.append((index, priority))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].priority < items[parent].priority else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Int? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].priority < items[smallest].priority { smallest = left }
                if right < items.count, items[right].priority < items[smallest].priority { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return top.index
    }
}
