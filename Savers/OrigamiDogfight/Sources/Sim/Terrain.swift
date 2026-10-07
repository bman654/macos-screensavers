// The landscape, as numbers: a height field drawn from the seed, and what each face of it is.
//
// It lives on the sim side of the line because the sim has to know where the ground is — a
// downed plane crashes when it meets it, and a lake swallows a wreck instead of burning it —
// and because the props are scattered by rules about these same faces. `TerrainMesh` turns it
// into geometry; nothing here knows SceneKit.
//
// The surface is `FacetLattice`'s triangles, each flat-shaded with its own normal and coloured
// whole, from what is true at its own middle. Every face is one piece of folded paper, so a
// colour boundary always runs along a fold, never across a facet. Every question about a point
// — its height, its slope, whether it is lake — is answered from the face drawn there, with the
// heights it is drawn at, so a wreck sits on the facet that is seen and splashes only into water
// that is seen.

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
    /// Lattice step, a little under a plane's length. Big enough that each fold is a shape you
    /// can see — a summit is a handful of faces round one point — and small enough that a lake
    /// a metre and a half across still has a dozen faces of shoreline and reads as a lake rather
    /// than as a blue polygon.
    static let facetSize: Float = 0.26

    /// Half the side of the square the terrain covers. Sized to fill the camera's view at the
    /// ground for any aspect from portrait to 4:1 (`tools/origami-sim-probe.swift` checks it),
    /// because a display can change shape under a live view and the landscape is not redrawn.
    static let halfExtent: Float = 7.0

    /// Lakes are flat paper at this height.
    static let waterLevel: Float = 0.05

    /// No summit is higher than this; `ViewRig.bandLow` keeps live planes well above it.
    static let maxHeight: Float = 0.5

    let lattice: FacetLattice
    /// The height every lattice point is drawn at: the corners of water faces pressed flat to
    /// the water level, and nothing below it. The mesh and every lookup read these, never the
    /// raw field.
    let ground: [Float]
    /// One per face of `lattice`.
    let bands: [TerrainBand]
    /// Which colour of its band a face takes — for water whether it is the shallows, for the
    /// rest the field it belongs to — and a small per-face brightness jitter. Both are drawn
    /// here so a seed names the whole picture.
    let variants: [UInt8]
    let jitter: [Float]
    let lakes: [Lake]

    init(seed: UInt64) {
        var rand = Rand(seed: seed ^ 0x7E44_A1_9C_03_55)
        let noise = ValueNoise(seed: UInt32(truncatingIfNeeded: seed &* 0x2545_F491))
        let lattice = FacetLattice(halfExtent: Terrain.halfExtent, spacing: Terrain.facetSize,
                                   nudge: 0.28, seed: seed)
        self.lattice = lattice

        let peaks = Terrain.placePeaks(&rand, lattice: lattice)
        let lakes = Terrain.placeLakes(&rand, clearOf: peaks)
        self.lakes = lakes

        var raw = lattice.points.map { Terrain.height(at: $0, peaks: peaks, lakes: lakes, noise: noise) }
        // Crumple: every point nudged a little, so even flat meadow catches the light facet by
        // facet the way a sheet of folded paper does. Kept small — a bigger crumple drowned the
        // hills' own folds in noise — and well under the meadow's margin over the water, so it
        // cannot open a pond.
        for index in raw.indices { raw[index] += rand.inRange(-0.006, 0.006) }
        Terrain.rescaleRelief(&raw)

        let corners = (0..<lattice.faceCount).map(lattice.corners(of:))
        let neighbours = lattice.neighbours
        // Water is decided per face, from the face's middle, and then its corners are pressed
        // flat to the water level. Deciding it by corner instead — water only where all three
        // are under — is what drew lakes as stair-stepped blobs; and pressing the corners keeps
        // the shore's facets meeting the water's edge, where otherwise a corner of a water face
        // standing above the water would leave a crack between the two.
        let isWater = Terrain.smoothed(corners.map { Terrain.mean(raw, $0) < Terrain.waterLevel },
                                       neighbours: neighbours)
        let wet = Terrain.points(of: isWater, corners: corners, count: raw.count)
        let ground = raw.indices.map { wet[$0] ? Terrain.waterLevel : max(raw[$0], Terrain.waterLevel) }
        self.ground = ground

        // A beach round every lake, one face deep — each face with a corner on the water — and
        // inside it the shallows, the water faces with a corner on the land. Both smoothed like
        // the water itself, so their inner and outer edges are curves too.
        let dry = Terrain.points(of: isWater.map(!), corners: corners, count: raw.count)
        let beach = zip(Terrain.smoothed(corners.map { Terrain.touches($0, wet) }, neighbours: neighbours),
                        isWater).map { $0 && !$1 }
        let shallows = zip(Terrain.smoothed(corners.map { Terrain.touches($0, dry) }, neighbours: neighbours),
                           isWater).map { $0 && $1 }
        let snow = Terrain.snowCaps(on: peaks, ground: ground, corners: corners)
        let summits = peaks.map { ground[$0.summit] }

        var bands = [TerrainBand](repeating: .meadow, count: corners.count)
        var variants = [UInt8](repeating: 0, count: corners.count)
        var jitter = [Float](repeating: 0, count: corners.count)
        for (face, c) in corners.enumerated() {
            let center = lattice.centroid(of: face)
            jitter[face] = rand.inRange(-1, 1)
            if isWater[face] {
                bands[face] = .water
                variants[face] = shallows[face] ? 1 : 0
                continue
            }
            variants[face] = Terrain.field(at: center, noise: noise)
            if beach[face] {
                bands[face] = .shore
            } else if snow[face] {
                bands[face] = .snow
            } else {
                // The peak this face stands on, if any: the one it is deepest inside.
                let onPeak = peaks.indices
                    .map { (index: $0, depth: simd_distance(center, peaks[$0].center) / peaks[$0].radius) }
                    .filter { $0.depth < 0.95 }
                    .min { $0.depth < $1.depth }
                bands[face] = Terrain.classify(mean: Terrain.mean(ground, c), steep: Terrain.slope(of: c, lattice, ground),
                                               summit: onPeak.map { summits[$0.index] })
            }
        }
        self.bands = bands
        self.variants = variants
        self.jitter = jitter
    }

    // MARK: Lookup

    /// The drawn surface's height — the facet's own plane — at a point. Outside the lattice it
    /// answers the datum, which is below anything that could ask.
    func surfaceHeight(at p: SIMD2<Float>) -> Float {
        guard let (face, w) = lattice.locate(p) else { return Terrain.waterLevel }
        let c = lattice.corners(of: face)
        return ground[Int(c.x)] * w.x + ground[Int(c.y)] * w.y + ground[Int(c.z)] * w.z
    }

    func band(at p: SIMD2<Float>) -> TerrainBand {
        guard let (face, _) = lattice.locate(p) else { return .meadow }
        return bands[face]
    }

    func isWater(at p: SIMD2<Float>) -> Bool { band(at: p) == .water }

    /// Rise over run of the facet under a point.
    func slope(at p: SIMD2<Float>) -> Float {
        guard let (face, _) = lattice.locate(p) else { return 0 }
        return Terrain.slope(of: lattice.corners(of: face), lattice, ground)
    }

    // MARK: Shape

    private struct Peak {
        let center: SIMD2<Float>
        let radius: Float
        let height: Float
        /// Spurs: the flank reaches further out along `lobes` directions, so the mountain folds
        /// into ridges and gullies running down from the summit rather than being a plain cone.
        let lobes: Float
        let phase: Float
        /// The lattice point at `center`.
        let summit: Int
    }

    private static func placePeaks(_ rand: inout Rand, lattice: FacetLattice) -> [Peak] {
        (0..<(1 + rand.index(count: 2))).map { _ in
            let angle = rand.inRange(0, 2 * .pi)
            let reach = rand.inRange(1.3, 2.6)
            // On a lattice point, so the summit is one point every face round it rises to: a
            // crisp folded tip rather than a ridge that happens to run across a face.
            let summit = lattice.nearestPoint(to: SIMD2(cos(angle) * reach, sin(angle) * reach * 0.65))
            return Peak(center: lattice.points[summit],
                        radius: rand.inRange(1.0, 1.4), height: rand.inRange(0.34, 0.42),
                        lobes: Float(4 + rand.index(count: 3)), phase: rand.inRange(0, 2 * .pi),
                        summit: summit)
        }
    }

    /// Lakes kept clear of the mountains: a lake on a summit is a crater.
    private static func placeLakes(_ rand: inout Rand, clearOf peaks: [Peak]) -> [Lake] {
        var lakes: [Lake] = []
        let lakeCount = 2 + rand.index(count: 2)
        for _ in 0..<40 where lakes.count < lakeCount {
            let center = SIMD2(rand.inRange(-2.3, 2.3), rand.inRange(-1.3, 1.3))
            let radius = rand.inRange(0.5, 0.95)
            let clearOfPeaks = peaks.allSatisfy { simd_distance($0.center, center) > $0.radius * 0.8 + radius + 0.3 }
            let clearOfLakes = lakes.allSatisfy { simd_distance($0.center, center) > $0.radius + radius + 0.4 }
            if clearOfPeaks && clearOfLakes { lakes.append(Lake(center: center, radius: radius)) }
        }
        return lakes
    }

    private static func height(at p: SIMD2<Float>, peaks: [Peak], lakes: [Lake], noise: ValueNoise) -> Float {
        // Rolling meadow, with hills where a second, coarser field rises. Every feature is
        // several faces across: anything finer than a face only adds noise to the shading.
        var h = 0.13 + 0.07 * (noise.fbm(p / 2.6, octaves: 3) - 0.5) * 2
        let hillMask = smoothstep(0.5, 0.78, noise.fbm(p / 2.4 + SIMD2(31, 7), octaves: 2))
        h += 0.15 * hillMask * (0.6 + 0.8 * noise.fbm(p / 1.0 + SIMD2(5, 53), octaves: 2))
        // Never down to the water away from a lake, or the meadows break out in one-face ponds.
        h = max(h, Terrain.waterLevel + 0.03)
        for peak in peaks {
            // A cone with a concave flank, not a Gaussian: a Gaussian is flat on top, so its
            // summit facets all face the sun alike and read as one white sheet rather than as
            // a folded peak. A narrow spike on top steepens the faces round the summit point
            // further, so the cap they carry is folded hard enough to show a lit side and a
            // shaded one.
            let d = p - peak.center
            let spur = 1 - 0.18 * cos(peak.lobes * atan2(d.y, d.x) + peak.phase)
            let flank = max(0, 1 - simd_length(d) / peak.radius * spur)
            let tip = max(0, 1 - simd_length(d) / (peak.radius * 0.3))
            h += peak.height * (flank * flank + 0.2 * tip)
        }
        for lake in lakes {
            // A ragged shore: the radius wanders with a noise field so no lake is a disc.
            let wobble = 0.35 * (noise.fbm(p / 0.6 + SIMD2(71, 29), octaves: 2) - 0.5)
            let d = simd_distance(p, lake.center) / lake.radius + wobble
            h += (Terrain.waterLevel - 0.07 - h) * smoothstep(1.05, 0.6, d)
        }
        return h
    }

    /// Peaks and hills stack, so a summit can rise well past the ceiling. Clamping it, or
    /// compressing it toward the ceiling, cuts it off flat — and those plateaus came out as
    /// broad white snowfields rather than caps. Rescaling all the relief above the meadows
    /// keeps every summit pointed and puts the highest one just under the ceiling.
    private static func rescaleRelief(_ heights: inout [Float]) {
        let meadowTop: Float = 0.2
        let summit = heights.max() ?? 0
        guard summit > Terrain.maxHeight else { return }
        let k = (Terrain.maxHeight - meadowTop) / (summit - meadowTop)
        for index in heights.indices where heights[index] > meadowTop {
            heights[index] = meadowTop + (heights[index] - meadowTop) * k
        }
    }

    // MARK: Faces

    /// A region traced face by face is all teeth along its edge — every face the line clips
    /// sticks out as a spike or bites in as a notch — and a lake came out as a star. Faces with
    /// the region along two of their three edges join it, then faces with it along at most one
    /// leave it, which files the teeth off and leaves a faceted curve.
    ///
    /// Two passes, not one rule applied to both at once: along a straight edge the clipped
    /// faces alternate up and down, and a simultaneous rule just swaps them every pass.
    private static func smoothed(_ region: [Bool], neighbours: [[Int]]) -> [Bool] {
        var region = region
        for _ in 0..<2 {
            region = region.indices.map { face in
                region[face] || (neighbours[face].count == 3 && neighbours[face].filter { region[$0] }.count >= 2)
            }
            region = region.indices.map { face in
                region[face] && neighbours[face].filter { region[$0] }.count >= 2
            }
        }
        return region
    }

    /// Snow: the faces folded round a tall summit's own point, and of those only the ones that
    /// stand within a little of the highest — the faces along the ridges, not down the gullies —
    /// and never fewer than two, since one white face alone reads as a sheet lying on the hill
    /// rather than as a fold. So a cap is two to four steep faces with a lit side and a shaded
    /// one. A snow *line*
    /// instead — any face above some height — gave one seed a dusting and another a broad white
    /// slab, because how far a summit rises above any given height depends on how the peaks and
    /// hills happened to stack.
    private static func snowCaps(on peaks: [Peak], ground: [Float], corners: [SIMD3<Int32>]) -> [Bool] {
        var snow = [Bool](repeating: false, count: corners.count)
        for peak in peaks where ground[peak.summit] >= 0.36 {
            let point = Int32(peak.summit)
            let fan = corners.indices.filter { any(corners[$0] .== point) }
                .map { (face: $0, height: mean(ground, corners[$0])) }
                .sorted { $0.height > $1.height }
            guard let top = fan.first?.height else { continue }
            for (rank, entry) in fan.enumerated() where rank < 2 || entry.height >= top - 0.015 {
                snow[entry.face] = true
            }
        }
        return snow
    }

    /// Rock is the upper flank of a mountain, reckoned from its own summit, and any face too
    /// steep to hold grass; hill is the high ground the meadows rise to.
    private static func classify(mean: Float, steep: Float, summit: Float?) -> TerrainBand {
        if let summit, mean >= max(summit - 0.2, 0.26) { return .rock }
        if steep > 0.8 { return .rock }
        if mean > 0.2 { return .hill }
        return .meadow
    }

    /// Fields: the meadow is cut into irregular polygons — the nearest of a scattering of
    /// sites, one per metre or so — and each takes one of a handful of greens. Faces are
    /// coloured whole, so a field's edge follows the folds. A quantised noise field did this
    /// before, and on a square grid it came out as axis-aligned rectangles.
    private static func field(at p: SIMD2<Float>, noise: ValueNoise) -> UInt8 {
        let cell = floor(p)
        var nearest = Float.infinity
        var pick: Float = 0
        for dy in -1...1 {
            for dx in -1...1 {
                // `ValueNoise` at a whole-number point is its lattice hash, so a site's place and
                // colour come from the seed with nothing stored.
                let k = cell + SIMD2(Float(dx), Float(dy))
                let site = k + SIMD2(noise.value(k + SIMD2(211, 0)), noise.value(k + SIMD2(0, 389)))
                let d = simd_distance_squared(p, site)
                if d < nearest {
                    nearest = d
                    pick = noise.value(k + SIMD2(577, 1013))
                }
            }
        }
        return UInt8(min(Int(pick * 5), 4))
    }

    private static func mean(_ values: [Float], _ c: SIMD3<Int32>) -> Float {
        (values[Int(c.x)] + values[Int(c.y)] + values[Int(c.z)]) / 3
    }

    private static func touches(_ c: SIMD3<Int32>, _ flags: [Bool]) -> Bool {
        flags[Int(c.x)] || flags[Int(c.y)] || flags[Int(c.z)]
    }

    /// Every lattice point that is a corner of some face in `region`.
    private static func points(of region: [Bool], corners: [SIMD3<Int32>], count: Int) -> [Bool] {
        var flags = [Bool](repeating: false, count: count)
        for (face, c) in corners.enumerated() where region[face] {
            flags[Int(c.x)] = true
            flags[Int(c.y)] = true
            flags[Int(c.z)] = true
        }
        return flags
    }

    private static func slope(of c: SIMD3<Int32>, _ lattice: FacetLattice, _ ground: [Float]) -> Float {
        let p = [c.x, c.y, c.z].map { i in SIMD3(lattice.points[Int(i)].x, lattice.points[Int(i)].y, ground[Int(i)]) }
        let n = simd_cross(p[1] - p[0], p[2] - p[0])
        return simd_length(SIMD2(n.x, n.y)) / max(abs(n.z), 1e-6)
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
