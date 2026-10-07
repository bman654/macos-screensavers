// The triangles the landscape is folded from: a triangular lattice — rows of points, each row
// half a step out of line with the next — with every point nudged off its place by the seed.
//
// A square grid split into triangles has half its edges on the screen's axes, so anything
// coloured face by face — a lake, a field, a snow line — came out as a staircase of squares and
// the whole map read as a tile game. A triangular lattice has no axis pair to line up on, and
// the nudge turns even its three edge directions into every direction, so a boundary that
// follows facet edges wanders the way a fold line does.
//
// Shared by the sim and the renderer, so a lookup lands on exactly the triangle that is drawn.

import Foundation
import simd

struct FacetLattice {
    let spacing: Float
    /// Points per row, and rows.
    let columns: Int
    let rows: Int
    let origin: SIMD2<Float>
    /// `rows * columns`, row-major. Row `j` is shifted right by half a step when `j` is odd.
    let points: [SIMD2<Float>]
    /// For every face, the faces it shares an edge with: three inside the lattice, fewer on its
    /// border.
    private(set) var neighbours: [[Int]] = []

    private var rowStep: Float { spacing * 0.866_025_4 }

    var faceCount: Int { (rows - 1) * (columns - 1) * 2 }

    /// Covers the square of `halfExtent` with a margin, so the ragged half-step at the ends of
    /// alternate rows and the nudge at the border never open a gap inside it.
    ///
    /// `nudge` is a fraction of `spacing`. Under 0.43 no triangle can fold over: a point must
    /// travel the triangle's height, 0.87 of a step, to cross the opposite edge, and the point
    /// and the edge can close on each other by at most twice the nudge.
    init(halfExtent: Float, spacing: Float, nudge: Float, seed: UInt64) {
        precondition(nudge < 0.43, "a nudge of half a triangle's height can fold a triangle over")
        self.spacing = spacing
        let margin = spacing * 1.5
        let rowStep = spacing * 0.866_025_4
        columns = Int(ceil((2 * (halfExtent + margin)) / spacing)) + 1
        rows = Int(ceil((2 * (halfExtent + margin)) / rowStep)) + 1
        origin = SIMD2(-halfExtent - margin, -halfExtent - margin)

        var rand = Rand(seed: seed ^ 0x1A77_1CE5_0F_7A)
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(rows * columns)
        for j in 0..<rows {
            let shift: Float = j % 2 == 1 ? 0.5 : 0
            for i in 0..<columns {
                // Uniform in a disc, so the nudge has no favourite direction.
                let angle = rand.inRange(0, 2 * .pi)
                let reach = sqrt(rand.next()) * nudge * spacing
                points.append(origin + SIMD2((Float(i) + shift) * spacing, Float(j) * rowStep)
                              + SIMD2(cos(angle), sin(angle)) * reach)
            }
        }
        self.points = points
        neighbours = edgeNeighbours()
    }

    /// The point nearest a position, on the unnudged lattice — close enough to name a summit.
    /// Clamped as floats before converting, so no position — however far off, or not a number —
    /// can trap the conversion.
    func nearestPoint(to p: SIMD2<Float>) -> Int {
        func clamped(_ v: Float, _ upper: Int) -> Int { v.isFinite ? Int(min(max(v.rounded(), 0), Float(upper))) : 0 }
        let j = clamped((p.y - origin.y) / rowStep, rows - 1)
        let shift: Float = j % 2 == 1 ? 0.5 : 0
        let i = clamped((p.x - origin.x) / spacing - shift, columns - 1)
        return j * columns + i
    }

    /// Point indices of a face, counter-clockwise seen from above. Faces run two to a column
    /// along each strip between rows `j` and `j + 1`.
    func corners(of face: Int) -> SIMD3<Int32> {
        let k = face % 2
        let cell = face / 2
        let i = cell % (columns - 1), j = cell / (columns - 1)
        let bottom = Int32(j * columns + i), top = Int32((j + 1) * columns + i)
        if j % 2 == 0 {
            // Top row sits half a step right: an upward triangle on b_i b_i+1, then a downward one.
            return k == 0 ? SIMD3(bottom, bottom + 1, top) : SIMD3(bottom + 1, top + 1, top)
        }
        // Bottom row sits half a step right: a downward triangle under t_i t_i+1, then an upward one.
        return k == 0 ? SIMD3(top, bottom, top + 1) : SIMD3(bottom, bottom + 1, top + 1)
    }

    /// Found by matching edges rather than from the row arithmetic, which is easy to get subtly
    /// wrong at the ends of the shifted rows and has nothing to show for being clever.
    private func edgeNeighbours() -> [[Int]] {
        var owner: [UInt64: Int] = [:]
        owner.reserveCapacity(faceCount * 2)
        var neighbours = [[Int]](repeating: [], count: faceCount)
        for face in 0..<faceCount {
            let c = corners(of: face)
            for (a, b) in [(c.x, c.y), (c.y, c.z), (c.z, c.x)] {
                let key = UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b)))
                if let other = owner.removeValue(forKey: key) {
                    neighbours[face].append(other)
                    neighbours[other].append(face)
                } else {
                    owner[key] = face
                }
            }
        }
        return neighbours
    }

    func centroid(of face: Int) -> SIMD2<Float> {
        let c = corners(of: face)
        return (points[Int(c.x)] + points[Int(c.y)] + points[Int(c.z)]) / 3
    }

    /// The face under a point and the point's barycentric weights on that face's corners, or nil
    /// off the lattice.
    ///
    /// A nudged triangle lies within its unnudged one grown by the nudge, so only the faces
    /// whose unnudged shape is that close need testing: the strip the point is in and one either
    /// side, and four columns. Of those, the one the point is deepest inside wins — a point on a
    /// shared edge belongs to either, and float error must not leave it belonging to neither.
    func locate(_ p: SIMD2<Float>) -> (face: Int, weights: SIMD3<Float>)? {
        let g = p - origin
        guard g.x >= 0, g.y >= 0, g.x <= Float(columns - 1) * spacing, g.y <= Float(rows - 1) * rowStep
        else { return nil }
        let strip = Int(g.y / rowStep)
        let column = Int(g.x / spacing)
        var best: (face: Int, weights: SIMD3<Float>, depth: Float)?
        for j in max(strip - 1, 0)...min(strip + 1, rows - 2) {
            for i in max(column - 2, 0)...min(column + 1, columns - 2) {
                for k in 0..<2 {
                    let face = (j * (columns - 1) + i) * 2 + k
                    let c = corners(of: face)
                    let w = FacetLattice.barycentric(p, points[Int(c.x)], points[Int(c.y)], points[Int(c.z)])
                    let depth = min(w.x, w.y, w.z)
                    if depth >= 0 { return (face, w) }
                    if depth > best?.depth ?? -.infinity { best = (face, w, depth) }
                }
            }
        }
        return best.map { ($0.face, $0.weights) }
    }

    /// Whether any face that a disc of `radius` round `center` overlaps — even by a sliver —
    /// satisfies `test`. Exact, not sampled: a face counts when the centre is inside it or any
    /// of its edges passes within `radius` of the centre. Faces off the lattice do not exist,
    /// and neither does anything under a point that is not a number.
    func anyFace(touching center: SIMD2<Float>, radius: Float, where test: (Int) -> Bool) -> Bool {
        let r2 = radius * radius
        return anyCandidate(near: center, center, radius: radius) { face, a, b, d in
            let touches = FacetLattice.barycentric(center, a, b, d).min() >= 0
                || FacetLattice.distanceSquared(center, a, b) <= r2
                || FacetLattice.distanceSquared(center, b, d) <= r2
                || FacetLattice.distanceSquared(center, d, a) <= r2
            return touches && test(face)
        }
    }

    /// Whether any face that a strip `radius` either side of the segment `p`–`q` overlaps — the
    /// capsule swept by a disc along it — satisfies `test`. Exact in the same way: a face counts
    /// when either end is inside it or any of its edges passes within `radius` of the segment,
    /// which includes the segment crossing it.
    func anyFace(touchingSegment p: SIMD2<Float>, _ q: SIMD2<Float>, radius: Float,
                 where test: (Int) -> Bool) -> Bool {
        let r2 = radius * radius
        return anyCandidate(near: p, q, radius: radius) { face, a, b, d in
            let touches = FacetLattice.barycentric(p, a, b, d).min() >= 0
                || FacetLattice.barycentric(q, a, b, d).min() >= 0
                || FacetLattice.segmentDistanceSquared(p, q, a, b) <= r2
                || FacetLattice.segmentDistanceSquared(p, q, b, d) <= r2
                || FacetLattice.segmentDistanceSquared(p, q, d, a) <= r2
            return touches && test(face)
        }
    }

    /// Every face that could come within `radius` of the box round `p` and `q`, until `visit`
    /// says yes. A nudged face lies within its unnudged triangle grown by under a third of a
    /// step, so the strips and columns the box spans, plus one either side, hold every face it
    /// can touch — the same search `locate` makes, widened.
    private func anyCandidate(near p: SIMD2<Float>, _ q: SIMD2<Float>, radius: Float,
                              visit: (Int, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) -> Bool) -> Bool {
        guard p.x.isFinite, p.y.isFinite, q.x.isFinite, q.y.isFinite, radius.isFinite, radius >= 0 else { return false }
        let lo = simd_min(p, q) - origin, hi = simd_max(p, q) - origin
        // Clamped before converting, so a point far off the lattice cannot overflow an Int.
        let limit = Float(max(rows, columns) + 4)
        func cell(_ v: Float, _ step: Float) -> Int { Int(min(max(floor(v / step), -limit), limit)) }
        let firstStrip = max(cell(lo.y - radius, rowStep) - 1, 0)
        let lastStrip = min(cell(hi.y + radius, rowStep) + 1, rows - 2)
        let firstColumn = max(cell(lo.x - radius, spacing) - 2, 0)
        let lastColumn = min(cell(hi.x + radius, spacing) + 1, columns - 2)
        guard firstStrip <= lastStrip, firstColumn <= lastColumn else { return false }
        for j in firstStrip...lastStrip {
            for i in firstColumn...lastColumn {
                for k in 0..<2 {
                    let face = (j * (columns - 1) + i) * 2 + k
                    let c = corners(of: face)
                    if visit(face, points[Int(c.x)], points[Int(c.y)], points[Int(c.z)]) { return true }
                }
            }
        }
        return false
    }

    /// The closest two segments come, squared: zero if they cross, else the nearest an end of
    /// one comes to the other.
    private static func segmentDistanceSquared(_ p: SIMD2<Float>, _ q: SIMD2<Float>,
                                               _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        func side(_ o: SIMD2<Float>, _ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
            (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x)
        }
        let d1 = side(a, b, p), d2 = side(a, b, q), d3 = side(p, q, a), d4 = side(p, q, b)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return 0 }
        return min(distanceSquared(p, a, b), distanceSquared(q, a, b), distanceSquared(a, p, q), distanceSquared(b, p, q))
    }

    /// From `p` to the nearest point of the segment `a`–`b`, squared.
    private static func distanceSquared(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-12), 0), 1)
        return simd_distance_squared(p, a + ab * t)
    }

    private static func barycentric(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                    _ c: SIMD2<Float>) -> SIMD3<Float> {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let d = v0.x * v1.y - v1.x * v0.y
        guard abs(d) > 1e-12 else { return SIMD3(1, 0, 0) }
        let wb = (v2.x * v1.y - v1.x * v2.y) / d
        let wc = (v0.x * v2.y - v2.x * v0.y) / d
        return SIMD3(1 - wb - wc, wb, wc)
    }
}
