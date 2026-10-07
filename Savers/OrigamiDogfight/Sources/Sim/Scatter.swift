// Where the props stand: trees in woods, rocks on the hills, a few hamlets, boats on the lakes.
//
// Rules rather than a hand layout, so every seed gets a landscape that makes sense: no tree in a
// lake or on a cliff, houses on flat ground near water, boats well clear of the shore. Pure data
// out — the renderer decides which model each spot gets and how big it is drawn.

import Foundation
import simd

enum PropKind: String, CaseIterable {
    case tree, rock, house, boat
}

struct PropSpot {
    let kind: PropKind
    let position: SIMD2<Float>
    let ground: Float
    let yaw: Float
    /// A multiplier on the kind's drawn size, so no two trees in a wood are the same height.
    let scale: Float
    /// Picks among the library's models of this kind; the renderer reduces it modulo the count.
    let variant: Int
}

enum Scatter {
    /// Only the middle of the terrain is decorated: this covers the ground a 21:9 display sees,
    /// and past it the faceted, coloured paper alone fills the view at far less cost.
    static let region = SIMD2<Float>(4.8, 3.3)

    static func spots(on terrain: Terrain, seed: UInt64) -> [PropSpot] {
        var rand = Rand(seed: seed ^ 0x5CA7_7E12_0B0A_75)
        let noise = ValueNoise(seed: UInt32(truncatingIfNeeded: seed &* 0x9E37 &+ 0x51))
        var grid = SpacingGrid(cell: 0.1)
        var spots: [PropSpot] = []

        func place(_ kind: PropKind, _ p: SIMD2<Float>, spacing: Float, yaw: Float, scale: Float) {
            grid.insert(p, radius: spacing)
            spots.append(PropSpot(kind: kind, position: p, ground: terrain.surfaceHeight(at: p),
                                  yaw: yaw, scale: scale, variant: Int(rand.next() * 1000)))
        }
        func randomPoint() -> SIMD2<Float> {
            SIMD2(rand.inRange(-region.x, region.x), rand.inRange(-region.y, region.y))
        }
        func isDryAndFlat(_ p: SIMD2<Float>, maxSlope: Float) -> Bool {
            let band = terrain.band(at: p)
            return (band == .meadow || band == .hill) && terrain.slope(at: p) < maxSlope
                && terrain.surfaceHeight(at: p) > Terrain.waterLevel + 0.025
        }

        // Hamlets first: they need the most room, and they want the flat ground near water.
        var hamlets = 0
        for _ in 0..<200 where hamlets < 3 {
            let center = randomPoint()
            guard isDryAndFlat(center, maxSlope: 0.2), !grid.isOccupied(center, radius: 0.5),
                  terrain.lakes.contains(where: { simd_distance($0.center, center) < $0.radius + 1.0 })
            else { continue }
            hamlets += 1
            // Houses in a hamlet share a street direction, give or take, so they read as built.
            let street = rand.inRange(0, .pi / 2)
            let count = 3 + rand.index(count: 4)
            var placed = 0
            for _ in 0..<40 where placed < count {
                let offset = SIMD2(rand.inRange(-0.32, 0.32), rand.inRange(-0.32, 0.32))
                let p = center + offset
                guard isDryAndFlat(p, maxSlope: 0.25), !grid.isOccupied(p, radius: 0.075) else { continue }
                let yaw = street + Float(rand.index(count: 4)) * .pi / 2 + rand.inRange(-0.12, 0.12)
                place(.house, p, spacing: 0.075, yaw: yaw, scale: rand.inRange(0.85, 1.15))
                placed += 1
            }
        }

        // Boats well out on the water: a boat touching the shore reads as beached.
        for lake in terrain.lakes {
            let count = 1 + rand.index(count: 2)
            var placed = 0
            for _ in 0..<30 where placed < count {
                let angle = rand.inRange(0, 2 * .pi)
                let p = lake.center + SIMD2(cos(angle), sin(angle)) * rand.inRange(0, lake.radius * 0.6)
                let clear = (0..<8).allSatisfy { k in
                    let a = Float(k) * .pi / 4
                    return terrain.isWater(at: p + SIMD2(cos(a), sin(a)) * 0.13)
                }
                guard clear, !grid.isOccupied(p, radius: 0.12) else { continue }
                place(.boat, p, spacing: 0.12, yaw: rand.inRange(0, 2 * .pi), scale: rand.inRange(0.85, 1.1))
                placed += 1
            }
        }

        // Rocks on the high ground, a few strays on the hills.
        var rocks = 0
        for _ in 0..<600 where rocks < 34 {
            let p = randomPoint()
            let band = terrain.band(at: p)
            guard band == .rock || (band == .hill && rand.next() < 0.25) || (band == .meadow && rand.next() < 0.02),
                  !grid.isOccupied(p, radius: 0.06) else { continue }
            place(.rock, p, spacing: 0.06, yaw: rand.inRange(0, 2 * .pi), scale: rand.inRange(0.7, 1.35))
            rocks += 1
        }

        // Woods: dense where a coarse noise field is high, a scattering of lone trees elsewhere.
        var trees = 0
        for _ in 0..<9000 where trees < 420 {
            let p = randomPoint()
            guard isDryAndFlat(p, maxSlope: 0.6) else { continue }
            let wood = noise.fbm(p / 1.1, octaves: 2)
            let chance: Float = wood > 0.56 ? 0.9 : (wood > 0.48 ? 0.25 : 0.03)
            guard rand.next() < chance, !grid.isOccupied(p, radius: 0.045) else { continue }
            place(.tree, p, spacing: 0.045, yaw: rand.inRange(0, 2 * .pi), scale: rand.inRange(0.75, 1.25))
            trees += 1
        }
        return spots
    }
}

/// A uniform hash grid for "is anything within r of here", which keeps four hundred trees'
/// worth of rejection sampling linear rather than quadratic.
struct SpacingGrid {
    let cell: Float
    private var buckets: [SIMD2<Int32>: [(SIMD2<Float>, Float)]] = [:]
    /// The widest radius placed so far, which bounds how many buckets a query must visit.
    private var widest: Float = 0

    init(cell: Float) { self.cell = cell }

    private func key(_ p: SIMD2<Float>) -> SIMD2<Int32> {
        SIMD2(Int32(floor(p.x / cell)), Int32(floor(p.y / cell)))
    }

    mutating func insert(_ p: SIMD2<Float>, radius: Float) {
        buckets[key(p), default: []].append((p, radius))
        widest = max(widest, radius)
    }

    /// Whether a disc of `radius` at `p` would overlap anything placed, each by its own radius.
    func isOccupied(_ p: SIMD2<Float>, radius: Float) -> Bool {
        let reach = Int32(ceil((radius + widest) / cell))
        let k = key(p)
        for dy in -reach...reach {
            for dx in -reach...reach {
                for (q, r) in buckets[SIMD2(k.x + dx, k.y + dy)] ?? [] where simd_distance(p, q) < radius + r {
                    return true
                }
            }
        }
        return false
    }
}
