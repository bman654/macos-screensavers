// Paper roads: strips laid between the hamlets, and one from a hamlet out past the edge of the
// view so the little cars have somewhere to come from.
//
// Found as the cheapest path over a grid, where steep ground costs more than flat and a wood more
// than a field, so a road winds along the valley floor and round the woods the way a country lane
// does, rather than striking out in a straight line over a hill. Lakes, rock, snow and anything
// too steep are closed to it; so are the houses and rocks, which it passes rather than crosses.
// Then smoothed, so it reads as a strip of paper laid down in curves rather than a staircase.
//
// **No road crosses a lake, at its full width, at any stage** — a frozen lake included, since a
// lane laid across the ice would be a lane across the water every summer the seed is drawn in.
// A point test is not enough: a step between two dry cells, a corner the smoothing cuts, or a
// chord of the final resample can each pass over a cove the points on either side miss, and the
// cars would drive across open water. So every segment is checked as the strip it is drawn as,
// against every lake face it overlaps, and a road that still crossed one would be dropped.
//
// Built by the sim, not the countryside, for one reason: an airfield is laid down on clear ground,
// and a road is not clear — a runway across a lane would have the little cars driving over it
// (`AirfieldSites.swift`). Nothing else in the fight sees them: a tank crosses a road as it
// crosses a field. A pure function of the seed's terrain and props, never of the season or the
// match, so a seed's roads and its airfields are the same in every season.

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
        guard points.count >= 2 else { return (points.first ?? .zero, SIMD2(1, 0)) }
        let s = s.isFinite ? min(max(s, 0), length) : 0
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
        let hamlets = Scatter.hamlets(props).filter { $0.count >= 2 }
        guard !hamlets.isEmpty else { return [] }
        let shore = Shoreline(terrain: terrain)
        let grid = CostGrid(terrain: terrain, props: props, shore: shore)

        // Each hamlet's middle, moved to the nearest open cell — the middle of a hamlet is often
        // the inside of one of its houses.
        let centres = hamlets.compactMap { group -> SIMD2<Float>? in
            let mean = group.map { props[$0].position }.reduce(.zero, +) / Float(group.count)
            return grid.nearestOpen(to: mean)
        }
        // Every hamlet hemmed in — by its own houses, a lake and a hillside — leaves nothing to
        // join and nowhere to start the road out from (seeds 3704 and 101409 among them).
        guard !centres.isEmpty else { return [] }
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
            let points = smooth(path, shore: shore)
            // Belt and braces: every step above keeps the strip dry by construction, and a road
            // that somehow is not is better missing than drawn across a lake.
            guard points.count >= 2, !zip(points, points.dropFirst()).contains(where: shore.isWet) else { return nil }
            return Road(points: points)
        }
    }

    /// Whether any stretch of the strip drawn along `points` lies over a lake face — tested
    /// exactly, segment by segment, for a check that shares nothing with the builder's shortcuts.
    static func crossesLake(_ points: [SIMD2<Float>], terrain: Terrain) -> Bool {
        zip(points, points.dropFirst()).contains { terrain.isLake(alongSegment: $0, $1, radius: halfWidth) }
    }

    /// Corners cut four times over (Chaikin), then resampled every 2.5 cm — but never across
    /// water. The grid's path is dry along every step, at the strip's width, and so is any part
    /// of a step; the only new ground a cut covers is the chord across a corner, so a corner
    /// whose chord would take the strip over a lake's edge keeps its point, as the grid had it.
    /// The resample's chords are checked the same way.
    private static func smooth(_ path: [SIMD2<Float>], shore: Shoreline) -> [SIMD2<Float>] {
        var line = path
        for _ in 0..<4 where line.count > 2 {
            var next = [line[0]]
            for i in 0..<(line.count - 1) {
                let q = line[i] * 0.75 + line[i + 1] * 0.25, r = line[i] * 0.25 + line[i + 1] * 0.75
                // The corner at `line[i]`, cut from the last segment's three-quarter point to this
                // one's quarter point.
                if i > 0, let last = next.last, shore.isWet(last, q) {
                    next.append(line[i])
                }
                next += [q, r]
            }
            next.append(line[line.count - 1])
            line = next
        }
        let road = Road(points: line)
        let count = max(Int(road.length / 0.025), 1)
        var points = [line[0]]
        var vertex = 1
        for k in 1...count {
            let s = road.length * Float(k) / Float(count)
            let p = k == count ? line[line.count - 1] : road.sample(at: s).position
            // A chord spanning one of the line's corners cuts it; where that would be wet, the
            // corners stay.
            var corners: [SIMD2<Float>] = []
            while vertex < line.count - 1, road.distances[vertex] < s {
                corners.append(line[vertex])
                vertex += 1
            }
            if !corners.isEmpty, let last = points.last, shore.isWet(last, p) {
                points += corners
            }
            points.append(p)
        }
        return points
    }
}

/// The ground as a road builder sees it: what a step onto each cell costs, or that it is closed.
private struct CostGrid {
    let columns: Int, rows: Int
    let cell: Float
    let origin: SIMD2<Float>
    /// Per cell; infinity where no road may go.
    let cost: [Float]
    /// Per cell: whether a lake face lies within a step and a half-width of it, so a step from
    /// it has to be checked against the water along its whole length, not just at its ends.
    let nearWater: [Bool]
    let shore: Shoreline

    init(terrain: Terrain, props: [PropSpot], shore: Shoreline) {
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
        self.shore = shore
        var cost = [Float](repeating: .infinity, count: columns * rows)
        var nearWater = [Bool](repeating: false, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                let p = origin + SIMD2(Float(i), Float(j)) * cell
                let band = terrain.band(at: p)
                // The strip's width round the cell clear of every lake face, not just its centre.
                guard band == .meadow || band == .hill || band == .shore, !shore.isWet(p, p),
                      !blocks.isOccupied(p, radius: Roads.halfWidth) else { continue }
                nearWater[j * columns + i] = shore.isNearLake(p)
                    && terrain.isLake(alongSegment: p, p, radius: Shoreline.reach)
                let slope = terrain.slope(at: p)
                guard slope < 0.33 else { continue }
                // A wood is not closed — some valleys are wooded end to end — but it costs as
                // much as a long detour, which is what a road through one should be.
                let wooded: Float = woods.isOccupied(p, radius: Roads.halfWidth) ? 6 : 0
                cost[j * columns + i] = 1 + 20 * slope * slope + wooded
            }
        }
        self.cost = cost
        self.nearWater = nearWater
    }

    private func index(_ p: SIMD2<Float>) -> Int? {
        let g = ((p - origin) / cell).rounded(.toNearestOrAwayFromZero)
        guard g.x >= 0, g.y >= 0, g.x < Float(columns), g.y < Float(rows) else { return nil }
        return Int(g.y) * columns + Int(g.x)
    }

    /// Whether a step between two open cells keeps the strip off the water all the way along.
    private func isDryStep(_ from: Int, _ to: Int) -> Bool {
        guard nearWater[from] || nearWater[to] else { return true }
        return !shore.isWet(point(from), point(to))
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
                    guard cost[next].isFinite, isDryStep(current, next) else { continue }
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

/// The lakes as the road builder asks about them: whether the strip along a segment lies over
/// one, exactly, but with the answer for nearly all the ground found without the exact test.
/// Whether a lake face lies within `reach` of each face is found once per face, from its edges,
/// the first time anything on it asks; a strip that stays within `reach` of a point on a face
/// that is not can touch no lake. Only the ground along the shores is left to test exactly.
private final class Shoreline {
    /// A step's diagonal and a half-width: the farthest from its start any strip the builder
    /// draws reaches.
    static let reach = Roads.halfWidth + Roads.cell * 1.5

    let terrain: Terrain
    /// Per face: 0 not yet asked, 1 no lake within `reach`, 2 one is.
    private var near: [UInt8]
    /// Every lake face's bounding box, grown by `reach`: a face whose own box meets none of them
    /// is nowhere near a lake, which settles most faces without the exact test.
    private let lakeBoxes: [(lo: SIMD2<Float>, hi: SIMD2<Float>)]

    init(terrain: Terrain) {
        self.terrain = terrain
        near = [UInt8](repeating: 0, count: terrain.lattice.faceCount)
        lakeBoxes = terrain.surface.indices.filter { terrain.surface[$0] == .water }.map { face in
            let (a, b, d) = Shoreline.corners(of: face, terrain.lattice)
            return (simd_min(a, simd_min(b, d)) - Shoreline.reach, simd_max(a, simd_max(b, d)) + Shoreline.reach)
        }
    }

    private static func corners(of face: Int, _ lattice: FacetLattice) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        let c = lattice.corners(of: face)
        return (lattice.points[Int(c.x)], lattice.points[Int(c.y)], lattice.points[Int(c.z)])
    }

    func isNearLake(_ p: SIMD2<Float>) -> Bool {
        guard let face = terrain.lattice.locate(p)?.face else { return false }
        if near[face] == 0 {
            let (a, b, d) = Shoreline.corners(of: face, terrain.lattice)
            let lo = simd_min(a, simd_min(b, d)), hi = simd_max(a, simd_max(b, d))
            let close = lakeBoxes.contains { all(lo .<= $0.hi) && all($0.lo .<= hi) }
            let wet = close && [(a, b), (b, d), (d, a)].contains {
                terrain.isLake(alongSegment: $0, $1, radius: Shoreline.reach)
            }
            near[face] = wet ? 2 : 1
        }
        return near[face] == 2
    }

    /// Whether the road's strip along `a`–`b` lies over any lake face.
    func isWet(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        if simd_distance(a, b) + Roads.halfWidth <= Shoreline.reach, !isNearLake(a) { return false }
        return terrain.isLake(alongSegment: a, b, radius: Roads.halfWidth)
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
