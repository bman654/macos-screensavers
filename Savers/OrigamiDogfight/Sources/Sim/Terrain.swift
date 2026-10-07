// The landscape, as numbers: a height field drawn from the seed, and what each face of it is.
//
// It lives on the sim side of the line because the sim has to know where the ground is — a
// downed plane crashes when it meets it, and a lake swallows a wreck instead of burning it —
// and because the props are scattered by rules about these same faces. `TerrainMesh` turns it
// into geometry; nothing here knows SceneKit.
//
// The surface is a regular grid split into triangles along **alternating diagonals**, every
// triangle flat-shaded with its own normal. That is the whole of the paper look: each face is a
// separate folded facet, and the alternation is what makes the facets read as an origami
// tessellation rather than as a coarse heightmap. The height lookup below uses the same split,
// so a wreck sits on the facet that is drawn rather than on a smoothed surface beneath it.

import Foundation
import simd

enum TerrainBand: UInt8 {
    case water, shore, meadow, hill, rock, snow
}

struct Lake {
    let center: SIMD2<Float>
    let radius: Float
}

struct Terrain {
    /// Facet size: about half a plane's length. At a whole plane length the folds outgrew the
    /// features they were drawing — lakes came out as blue rectangles and every summit as one
    /// white diamond — and much finer than this it starts to read as a mesh rather than paper.
    static let cellSize: Float = 0.16

    /// Half the side of the square the terrain covers. Sized to fill the camera's view at the
    /// ground for any aspect from portrait to 4:1 (`tools/origami-sim-probe.swift` checks it),
    /// because a display can change shape under a live view and the landscape is not redrawn.
    static let halfExtent: Float = 7.0

    /// Lakes are flat paper at this height.
    static let waterLevel: Float = 0.05

    /// No summit is higher than this; `ViewRig.bandLow` keeps live planes well above it.
    static let maxHeight: Float = 0.5

    let cells: Int
    let origin: SIMD2<Float>
    /// Raw heights, `(cells + 1)²`, row-major in y. May dip below the water level; the drawn
    /// surface is clamped to it.
    let heights: [Float]
    /// Two per cell, `(j * cells + i) * 2 + k`.
    let bands: [TerrainBand]
    /// Which colour of its band a face takes — the field it belongs to, for meadows — and a
    /// small per-face brightness jitter. Both are drawn here so a seed names the whole picture.
    let variants: [UInt8]
    let jitter: [Float]
    let lakes: [Lake]

    init(seed: UInt64) {
        var rand = Rand(seed: seed ^ 0x7E44_A1_9C_03_55)
        let cells = Int((2 * Terrain.halfExtent / Terrain.cellSize).rounded())
        self.cells = cells
        origin = SIMD2(-Terrain.halfExtent, -Terrain.halfExtent)
        let noise = ValueNoise(seed: UInt32(truncatingIfNeeded: seed &* 0x2545_F491))

        // Mountains first, then lakes kept clear of them: a lake on a summit is a crater.
        var peaks: [(center: SIMD2<Float>, radius: Float, height: Float)] = []
        let peakCount = 1 + rand.index(count: 2)
        for _ in 0..<peakCount {
            let angle = rand.inRange(0, 2 * .pi)
            let reach = rand.inRange(1.3, 2.6)
            peaks.append((SIMD2(cos(angle) * reach, sin(angle) * reach * 0.65),
                          rand.inRange(1.0, 1.4), rand.inRange(0.34, 0.42)))
        }
        var lakes: [Lake] = []
        let lakeCount = 2 + rand.index(count: 2)
        for _ in 0..<40 where lakes.count < lakeCount {
            let center = SIMD2(rand.inRange(-2.3, 2.3), rand.inRange(-1.3, 1.3))
            let radius = rand.inRange(0.5, 0.95)
            let clearOfPeaks = peaks.allSatisfy { simd_distance($0.center, center) > $0.radius * 0.8 + radius + 0.3 }
            let clearOfLakes = lakes.allSatisfy { simd_distance($0.center, center) > $0.radius + radius + 0.4 }
            if clearOfPeaks && clearOfLakes { lakes.append(Lake(center: center, radius: radius)) }
        }
        self.lakes = lakes

        let side = cells + 1
        var heights = [Float](repeating: 0, count: side * side)
        for j in 0..<side {
            for i in 0..<side {
                let p = SIMD2(Float(i), Float(j)) * Terrain.cellSize + origin
                // Rolling meadow, with hills where a second, coarser field rises.
                var h = 0.11 + 0.075 * (noise.fbm(p / 3.0, octaves: 3) - 0.5) * 2
                let hillMask = smoothstep(0.5, 0.78, noise.fbm(p / 2.4 + SIMD2(31, 7), octaves: 2))
                h += 0.13 * hillMask * (0.6 + 0.8 * noise.fbm(p / 0.9 + SIMD2(5, 53), octaves: 2))
                for peak in peaks {
                    // A cone with a concave flank, not a Gaussian: a Gaussian is flat on top,
                    // so its summit facets all face the sun alike and read as one white sheet
                    // rather than as a folded peak with a cap.
                    let r = simd_distance(p, peak.center) / peak.radius
                    let ridge = 0.7 + 0.6 * noise.fbm(p / 0.45 + SIMD2(17, 3), octaves: 2)
                    let flank = max(0, 1 - r)
                    h += peak.height * flank * flank * ridge
                }
                for lake in lakes {
                    // A ragged shore: the radius wanders with a noise field so no lake is a disc.
                    let wobble = 0.35 * (noise.fbm(p / 0.6 + SIMD2(71, 29), octaves: 2) - 0.5)
                    let d = simd_distance(p, lake.center) / lake.radius + wobble
                    h = h + (Terrain.waterLevel - 0.07 - h) * smoothstep(1.05, 0.6, d)
                }
                // Crumple: every vertex nudged a little, so even flat meadow catches the light
                // facet by facet the way a sheet of folded paper does.
                h += rand.inRange(-0.01, 0.01)
                heights[j * side + i] = max(h, 0)
            }
        }
        // Peaks and hills stack, so a summit can rise well past the ceiling. Clamping it, or
        // compressing it toward the ceiling, cuts it off flat — and those plateaus came out as
        // broad white snowfields rather than caps. Rescaling all the relief above the meadows
        // keeps every summit pointed and puts the highest one just under the ceiling.
        let meadowTop: Float = 0.2
        let summit = heights.max() ?? 0
        if summit > Terrain.maxHeight {
            let k = (Terrain.maxHeight - meadowTop) / (summit - meadowTop)
            for index in heights.indices where heights[index] > meadowTop {
                heights[index] = meadowTop + (heights[index] - meadowTop) * k
            }
        }
        self.heights = heights

        // Snow and rock lines from this landscape's own heights rather than fixed numbers: a
        // fixed snow line gave one seed a dusting and another broad white snowfields, because
        // how far a summit rises above any given height depends on how the peaks and hills
        // happened to stack. Measured over the middle of the terrain, which is what is seen.
        var central: [Float] = []
        for j in 0..<cells {
            for i in 0..<cells {
                let center = (SIMD2(Float(i), Float(j)) + 0.5) * Terrain.cellSize + origin
                guard abs(center.x) < 3.5, abs(center.y) < 2.2 else { continue }
                let corners = [(0, 0), (1, 0), (0, 1), (1, 1)].map { heights[(j + $0.1) * side + i + $0.0] }
                central.append(corners.reduce(0, +) / 4)
            }
        }
        central.sort()
        func quantile(_ q: Float) -> Float {
            central.isEmpty ? Terrain.maxHeight : central[min(Int(Float(central.count) * q), central.count - 1)]
        }
        // Floors, so a low, rolling seed gets no snow at all rather than snow on its hilltops.
        let lines = BandLines(snow: max(0.36, quantile(0.993)), rock: max(0.26, quantile(0.94)))

        var bands = [TerrainBand](repeating: .meadow, count: cells * cells * 2)
        var variants = [UInt8](repeating: 0, count: bands.count)
        var jitter = [Float](repeating: 0, count: bands.count)
        for j in 0..<cells {
            for i in 0..<cells {
                for k in 0..<2 {
                    let face = (j * cells + i) * 2 + k
                    let corners = Terrain.faceCorners(i: i, j: j, k: k)
                    let raw = corners.map { heights[($0.y + j) * side + $0.x + i] }
                    let center = (SIMD2(Float(i), Float(j)) + 0.5) * Terrain.cellSize + origin
                    bands[face] = Terrain.classify(raw, cellSize: Terrain.cellSize, corners: corners, lines: lines)
                    // Fields: a coarse noise quantised into a handful of bins, so meadow faces
                    // group into patches of one green — a patchwork, like folded farmland.
                    let field = noise.value(center / 0.7 + SIMD2(13, 101))
                    variants[face] = UInt8(min(Int(field * 5), 4))
                    jitter[face] = rand.inRange(-1, 1)
                }
            }
        }
        self.bands = bands
        self.variants = variants
        self.jitter = jitter
    }

    // MARK: Lookup

    /// The drawn surface's height — the facet's own plane, water clamped flat — at a point.
    /// Outside the grid it answers the datum, which is below anything that could ask.
    func surfaceHeight(at p: SIMD2<Float>) -> Float {
        guard let (i, j, u, v) = locate(p) else { return Terrain.waterLevel }
        let k = Terrain.faceIndex(i: i, j: j, u: u, v: v)
        let corners = Terrain.faceCorners(i: i, j: j, k: k)
        let side = cells + 1
        let h = corners.map { max(heights[($0.y + j) * side + $0.x + i], Terrain.waterLevel) }
        let a = SIMD2(Float(corners[0].x), Float(corners[0].y))
        let b = SIMD2(Float(corners[1].x), Float(corners[1].y))
        let c = SIMD2(Float(corners[2].x), Float(corners[2].y))
        let w = Terrain.barycentric(SIMD2(u, v), a, b, c)
        return h[0] * w.x + h[1] * w.y + h[2] * w.z
    }

    func band(at p: SIMD2<Float>) -> TerrainBand {
        guard let (i, j, u, v) = locate(p) else { return .meadow }
        return bands[(j * cells + i) * 2 + Terrain.faceIndex(i: i, j: j, u: u, v: v)]
    }

    func isWater(at p: SIMD2<Float>) -> Bool { band(at: p) == .water }

    /// Rise over run of the facet under a point.
    func slope(at p: SIMD2<Float>) -> Float {
        guard let (i, j, u, v) = locate(p) else { return 0 }
        let k = Terrain.faceIndex(i: i, j: j, u: u, v: v)
        let corners = Terrain.faceCorners(i: i, j: j, k: k)
        let side = cells + 1
        let raw = corners.map { max(heights[($0.y + j) * side + $0.x + i], Terrain.waterLevel) }
        return Terrain.slope(raw, corners: corners, cellSize: Terrain.cellSize)
    }

    /// Cell and the point's position inside it, in [0, 1)².
    private func locate(_ p: SIMD2<Float>) -> (Int, Int, Float, Float)? {
        let g = (p - origin) / Terrain.cellSize
        guard g.x >= 0, g.y >= 0, g.x < Float(cells), g.y < Float(cells) else { return nil }
        let i = min(Int(g.x), cells - 1)
        let j = min(Int(g.y), cells - 1)
        return (i, j, g.x - Float(i), g.y - Float(j))
    }

    // MARK: Triangulation

    /// Corner offsets of face `k` of cell (i, j), counter-clockwise from above. The diagonal
    /// alternates with the cell's parity — the origami-tessellation pattern.
    static func faceCorners(i: Int, j: Int, k: Int) -> [(x: Int, y: Int)] {
        if (i + j) % 2 == 0 {
            return k == 0 ? [(0, 0), (1, 0), (1, 1)] : [(0, 0), (1, 1), (0, 1)]
        }
        return k == 0 ? [(0, 0), (1, 0), (0, 1)] : [(1, 0), (1, 1), (0, 1)]
    }

    static func faceIndex(i: Int, j: Int, u: Float, v: Float) -> Int {
        (i + j) % 2 == 0 ? (u >= v ? 0 : 1) : (u + v <= 1 ? 0 : 1)
    }

    private static func barycentric(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                    _ c: SIMD2<Float>) -> SIMD3<Float> {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let d = v0.x * v1.y - v1.x * v0.y
        guard abs(d) > 1e-9 else { return SIMD3(1, 0, 0) }
        let wb = (v2.x * v1.y - v1.x * v2.y) / d
        let wc = (v0.x * v2.y - v2.x * v0.y) / d
        return SIMD3(1 - wb - wc, wb, wc)
    }

    private static func slope(_ h: [Float], corners: [(x: Int, y: Int)], cellSize: Float) -> Float {
        let p = (0..<3).map { SIMD3(Float(corners[$0].x) * cellSize, Float(corners[$0].y) * cellSize, h[$0]) }
        let n = simd_cross(p[1] - p[0], p[2] - p[0])
        return simd_length(SIMD2(n.x, n.y)) / max(abs(n.z), 1e-6)
    }

    private struct BandLines {
        let snow: Float
        let rock: Float
    }

    private static func classify(_ raw: [Float], cellSize: Float,
                                 corners: [(x: Int, y: Int)], lines: BandLines) -> TerrainBand {
        let water = Terrain.waterLevel
        if raw.max()! < water { return .water }
        if raw.min()! < water + 0.012 { return .shore }
        let mean = raw.reduce(0, +) / 3
        let steep = slope(raw, corners: corners, cellSize: cellSize)
        if mean > lines.snow { return .snow }
        if mean > lines.rock || steep > 0.75 { return .rock }
        if mean > min(0.185, lines.rock - 0.04) { return .hill }
        return .meadow
    }
}

func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Seeded lattice value noise. Hash-based rather than table-based so it needs no state beyond
/// the seed, and integer-only in the hash so a seed names the same landscape on every machine.
struct ValueNoise {
    let seed: UInt32

    func value(_ p: SIMD2<Float>) -> Float {
        let fx = floor(p.x), fy = floor(p.y)
        let ix = Int32(fx), iy = Int32(fy)
        let tx = p.x - fx, ty = p.y - fy
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let a = lattice(ix, iy), b = lattice(ix + 1, iy)
        let c = lattice(ix, iy + 1), d = lattice(ix + 1, iy + 1)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    /// Sum of octaves, normalised back to [0, 1].
    func fbm(_ p: SIMD2<Float>, octaves: Int) -> Float {
        var sum: Float = 0, amplitude: Float = 1, total: Float = 0, q = p
        for _ in 0..<octaves {
            sum += value(q) * amplitude
            total += amplitude
            amplitude *= 0.5
            q = q * 2.03 + SIMD2(17.1, 9.7)
        }
        return sum / total
    }

    private func lattice(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343 ^ UInt32(bitPattern: y) &* 0xD816_3841 ^ seed
        h = (h ^ (h >> 13)) &* 0x5BD1_E995
        h ^= h >> 15
        return Float(h & 0xFFFFFF) / Float(0x1000000)
    }
}
