// Where the airfields go: a search of every spot and heading on each team's side of the view for
// the flattest clear strip of ground, read from the terrain and the scattered props as they are.
//
// The ground is cut into 4 cm cells, each open or closed — wet, rock, snow, too steep, or under a
// prop — and every cell then learns how far it is from the nearest closed one. That turns "is
// this whole strip clear" into "is the strip's centre line far enough from anything closed",
// a few dozen lookups per candidate rather than a few hundred points tested against every prop,
// which is what lets the search try thousands of candidates in a few milliseconds at the start of
// a match. Each airfield placed is burned into the grid, so the next cannot overlap it.

import Foundation
import simd

/// Which ground an airfield may stand on, cell by cell over the view, and how far each cell is
/// from ground it may not. Built once per drawable shape — the terrain and the props never change.
struct BuildGrid {
    let origin: SIMD2<Float>
    let cell: Float
    let columns: Int
    let rows: Int
    private(set) var open: [Bool]
    let height: [Float]
    /// Metres from each cell's centre to the nearest closed cell's, or to the grid's edge.
    private(set) var clearance: [Float]

    /// Rise over run past which a face is not flat enough for a runway to lie on.
    static let maxSlope: Float = 0.2

    init(terrain: Terrain, props: [PropSpot], covering view: ConvexQuad) {
        cell = 0.04
        let (lo, hi) = view.bounds
        origin = lo
        columns = Int(ceil((hi.x - lo.x) / cell)) + 1
        rows = Int(ceil((hi.y - lo.y) / cell)) + 1
        // Every prop with the room its canopy, walls or hull take — the largest of the library's
        // trees and houses is about 5.5 cm across the middle at a spot scale of 1 — and any kind,
        // so whatever stands on the landscape keeps its ground.
        var occupied = SpacingGrid(cell: 0.1)
        for spot in props { occupied.insert(spot.position, radius: 0.055 * max(spot.scale, 0.5)) }
        let forbidden = terrain.bands.indices.map { face -> Bool in
            switch terrain.bands[face] {
            case .water, .rock, .snow: return true
            case .shore, .meadow, .hill: return terrain.slope(ofFace: face) > BuildGrid.maxSlope
            }
        }
        var open = [Bool](repeating: false, count: columns * rows)
        var height = [Float](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let p = origin + SIMD2(Float(column), Float(row)) * cell
                height[index] = terrain.surfaceHeight(at: p)
                open[index] = !terrain.lattice.anyFace(touching: p, radius: cell * 0.75) { forbidden[$0] }
                    && !occupied.isOccupied(p, radius: 0.005)
            }
        }
        self.open = open
        self.height = height
        clearance = []
        clearance = distanceField()
    }

    func index(_ p: SIMD2<Float>) -> Int? {
        let g = (p - origin) / cell
        let column = Int(g.x.rounded()), row = Int(g.y.rounded())
        guard column >= 0, row >= 0, column < columns, row < rows else { return nil }
        return row * columns + column
    }

    /// Closes every cell within `radius` of any of `points`, and recomputes the clearances.
    mutating func close(around points: [SIMD2<Float>], radius: Float) {
        let reach = Int(ceil(radius / cell))
        for p in points {
            let g = (p - origin) / cell
            let c0 = Int(g.x.rounded()), r0 = Int(g.y.rounded())
            for r in max(r0 - reach, 0)...max(min(r0 + reach, rows - 1), 0) {
                for c in max(c0 - reach, 0)...max(min(c0 + reach, columns - 1), 0) {
                    let q = origin + SIMD2(Float(c), Float(r)) * cell
                    if simd_distance(p, q) <= radius { open[r * columns + c] = false }
                }
            }
        }
        clearance = distanceField()
    }

    /// A two-pass chamfer distance transform: each cell's distance to the nearest closed cell
    /// through its eight neighbours. It over-reads a true distance by at most about 8% off the
    /// axes, which the callers allow for.
    private func distanceField() -> [Float] {
        let diagonal = cell * Float(2).squareRoot()
        var d = [Float](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                // The grid's edge counts as closed: nothing is known beyond it.
                let edge = Float(min(column, row, columns - 1 - column, rows - 1 - row) + 1) * cell
                d[index] = open[index] ? edge : 0
            }
        }
        func relax(_ index: Int, _ column: Int, _ row: Int, _ dc: Int, _ dr: Int, _ step: Float) {
            let c = column + dc, r = row + dr
            guard c >= 0, r >= 0, c < columns, r < rows else { return }
            d[index] = min(d[index], d[r * columns + c] + step)
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                relax(index, column, row, -1, 0, cell)
                relax(index, column, row, 0, -1, cell)
                relax(index, column, row, -1, -1, diagonal)
                relax(index, column, row, 1, -1, diagonal)
            }
        }
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let index = row * columns + column
                relax(index, column, row, 1, 0, cell)
                relax(index, column, row, 0, 1, cell)
                relax(index, column, row, 1, 1, diagonal)
                relax(index, column, row, -1, 1, diagonal)
            }
        }
        return d
    }
}

extension DogfightSim {

    /// The ground the airfields are planned over: what the camera sees at meadow height.
    private var buildGrid: BuildGrid {
        if let cached = buildGridCache, cached.aspect == rig.aspect { return cached.grid }
        let grid = BuildGrid(terrain: terrain, props: props, covering: groundView)
        buildGridCache = (rig.aspect, grid)
        return grid
    }

    /// Plans this match's airfields and tells the ground where the hangars stand. Called once a
    /// match is drawn, and again if the drawable changes shape under it.
    func planBases() {
        match.bases = []
        ground.structures = []
        guard match.mode != .ffa, (2...4).contains(match.sides) else { return }
        var grid = buildGrid
        var bases: [Airfield?] = []
        let edges = (0..<match.sides).map { side in match.slots.first { $0.side == side }?.homeEdge }
        for side in 0..<match.sides {
            guard let edge = edges[side] else { bases.append(nil); continue }
            let rivals = edges.enumerated().compactMap { $0.offset != side ? $0.element : nil }
            let base = site(for: side, edge: edge, rivals: rivals, grid: grid)
            // Burned in with a gap, so the next side's airfield is not built against this one.
            if let base { grid.close(around: centreLine(of: base).map(\.point), radius: max(base.hangarWidth, base.runwayWidth) / 2 + 0.08) }
            bases.append(base)
        }
        match.bases = bases
        ground.structures = bases.compactMap { $0.map { ($0.hangar, $0.hangarRadius) } }
    }

    /// After the drawable changes shape: the match keeps its airfields unless one is now cut off
    /// at the edge of the view. A host's first frame routinely reshapes the view it was built
    /// for, and re-planning on every reshape had airfields jump, or appear where a side had
    /// none, in the middle of a match.
    func replanBasesIfCutOff() {
        let fits = match.bases.allSatisfy { base in
            guard let base else { return true }
            let seen = rig.visible(atAltitude: base.top)
            return footprintCorners(of: base).allSatisfy { seen.contains($0, margin: 0.02) }
        }
        if !fits { planBases() }
    }

    /// Every heading within 80° of straight in from the edge, so a strip can thread between trees.
    private static let headingOffsets: [Float] = [0, 0.2, -0.2, 0.4, -0.4, 0.6, -0.6, 0.8, -0.8, 1.0, -1.0,
                                                  1.2, -1.2, 1.4, -1.4]

    /// The best spot and heading for `side`'s airfield near `edge`, or nil if there is none.
    private func site(for side: Int, edge: Int, rivals: [Int], grid: BuildGrid) -> Airfield? {
        let view = groundView
        let size = Airfield.dimensions(scale: match.tankScale)
        let span = { (e: Int) in max(view.distance(view.corners[(e + 2) % 4], edge: e), 1e-3) }
        let edgeStart = view.corners[edge], edgeEnd = view.corners[(edge + 1) % 4]
        let edgeLength = max(simd_distance(edgeStart, edgeEnd), 1e-3)
        let edgeMid = (edgeStart + edgeEnd) / 2
        let edgeDirection = (edgeEnd - edgeStart) / edgeLength
        let inward = view.normals[edge]
        let inwardHeading = atan2(inward.y, inward.x)
        // How far a plane climbing out at the take-off rate covers before it is in the band.
        let climbOut = match.scale * 1.15 * (ViewRig.bandLow - 0.1) / DogfightSim.takeOffClimb
        let hangarHalf = (size.hangarLength * size.hangarLength + size.hangarWidth * size.hangarWidth).squareRoot() / 2

        var best: (base: Airfield, score: Float)?
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                // The hangar's centre needs room for the whole hangar round it, whatever its heading.
                guard grid.clearance[row * grid.columns + column] > hangarHalf else { continue }
                let hangar = grid.origin + SIMD2(Float(column), Float(row)) * grid.cell
                // Its own side of the view: well in from its edge, and nearer its own edge than
                // any other team's — so a three-way fight's airfields do not crowd one corner.
                let depth = view.distance(hangar, edge: edge) / span(edge)
                guard depth > 0.05, depth < 0.3,
                      rivals.allSatisfy({ view.distance(hangar, edge: $0) / span($0) > depth }) else { continue }
                for offset in DogfightSim.headingOffsets {
                    var base = Airfield(side: side, hangar: hangar, heading: (inwardHeading + offset).wrappedAngle,
                                        hangarLength: size.hangarLength, hangarWidth: size.hangarWidth,
                                        runwayLength: size.runwayLength, runwayWidth: size.runwayWidth, top: 0)
                    guard let relief = check(base, grid: grid) else { continue }
                    base = base.at(top: relief.top)
                    // Fully in view at its own height, and the climb-out stays inside the arena.
                    let seen = rig.visible(atAltitude: relief.top)
                    guard footprintCorners(of: base).allSatisfy({ seen.contains($0, margin: 0.06) }),
                          wall.contains(base.hangar + base.direction * (base.liftDistance + climbOut))
                    else { continue }
                    let along = abs(simd_dot(hangar - edgeMid, edgeDirection)) / edgeLength
                    let score = relief.range * 10 + abs(offset) * 0.25 + abs(depth - 0.16) * 2 + along * 0.8
                    if best.map({ score < $0.score }) ?? true { best = (base, score) }
                }
            }
        }
        return best?.base
    }

    /// The highest ground under the airfield and how much it varies along it, or nil if any of
    /// it is somewhere it may not be: wet, steep, under a prop, on another side's airfield, or
    /// off the grid.
    private func check(_ base: Airfield, grid: BuildGrid) -> (top: Float, range: Float)? {
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        for (point, half) in centreLine(of: base) {
            // Room for the strip either side of this point and half a step along it, plus the
            // chamfer's over-read; the 1 cm is "not on it", not a clearance round it.
            let need = ((half * half + 0.02 * 0.02).squareRoot() + 0.01) * 1.08
            guard let index = grid.index(point), grid.clearance[index] > need else { return nil }
            low = min(low, grid.height[index])
            high = max(high, grid.height[index])
            // The strip is draped over the ground, so a gentle tilt along it reads as a field on
            // a slope; more than this and it reads as a ramp.
            if high - low > 0.09 { return nil }
        }
        return (high, high - low)
    }

    /// Points down the middle of hangar and runway, 4 cm apart and on both ends exactly, each
    /// with the half-width there.
    func centreLine(of base: Airfield) -> [(point: SIMD2<Float>, half: Float)] {
        let start = -base.hangarLength / 2, end = base.hangarLength / 2 + base.runwayLength
        let count = Int(ceil((end - start) / 0.04))
        return (0...count).map { k in
            let s = start + (end - start) * Float(k) / Float(count)
            let half = (s <= base.hangarLength / 2 ? base.hangarWidth : base.runwayWidth) / 2
            return (base.hangar + base.direction * s, half)
        }
    }

    /// Points over the hangar and runway, `margin` beyond their edges, a cell apart.
    func footprint(of base: Airfield, margin: Float) -> [SIMD2<Float>] {
        let d = base.direction, n = SIMD2(-d.y, d.x)
        var points: [SIMD2<Float>] = []
        for (point, half) in centreLine(of: base) {
            let width = half + margin
            var t = -width
            while t < width {
                points.append(point + n * t)
                t += 0.04
            }
            points.append(point + n * width)
        }
        return points
    }

    private func footprintCorners(of base: Airfield) -> [SIMD2<Float>] {
        let d = base.direction, n = SIMD2(-d.y, d.x)
        let back = base.hangar - d * base.hangarLength / 2, front = base.runwayEnd
        let half = max(base.hangarWidth, base.runwayWidth) / 2
        return [back + n * half, back - n * half, front + n * half, front - n * half]
    }
}
