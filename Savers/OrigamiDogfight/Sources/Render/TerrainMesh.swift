// The landscape as geometry: every triangle of `Terrain` its own flat-shaded facet in its own
// colour of paper.
//
// Three vertices per triangle, never shared, so each face carries its own normal and colour —
// a shared-vertex mesh would smooth the folds away, and the folds are the whole look.

import AppKit
import Foundation
import SceneKit
import simd

enum TerrainMesh {

    /// The landscape palette, sRGB as authored. Meadows are a patchwork of greens and the odd
    /// ripe field, so the low ground reads as folded farmland rather than one green sheet.
    private static let water = PaperColor(0.40, 0.66, 0.84)
    private static let shore = PaperColor(0.88, 0.78, 0.58)
    private static let meadows = [PaperColor(0.56, 0.76, 0.40), PaperColor(0.46, 0.69, 0.35),
                                  PaperColor(0.64, 0.80, 0.44), PaperColor(0.40, 0.62, 0.33),
                                  PaperColor(0.80, 0.78, 0.44)]
    private static let hills = [PaperColor(0.52, 0.58, 0.31), PaperColor(0.45, 0.52, 0.29)]
    private static let rocks = [PaperColor(0.62, 0.57, 0.50), PaperColor(0.53, 0.49, 0.44)]
    private static let snow = PaperColor(0.97, 0.97, 0.95)

    static func node(for terrain: Terrain, seed: UInt64) -> SCNNode {
        let side = terrain.cells + 1
        var mesh = FacetMesh()
        mesh.reserve(faces: terrain.cells * terrain.cells * 2)
        // One grain tile spans this many metres; small enough that the fibres read at screen
        // scale, large enough that the repeat is not seen.
        let grainTile: Float = 0.9

        for j in 0..<terrain.cells {
            for i in 0..<terrain.cells {
                for k in 0..<2 {
                    let face = (j * terrain.cells + i) * 2 + k
                    let band = terrain.bands[face]
                    let points = Terrain.faceCorners(i: i, j: j, k: k).map { c -> SIMD3<Float> in
                        let gx = i + c.x, gy = j + c.y
                        let p = terrain.origin + SIMD2(Float(gx), Float(gy)) * Terrain.cellSize
                        let h = band == .water ? Terrain.waterLevel
                            : max(terrain.heights[gy * side + gx], Terrain.waterLevel)
                        // Sim (x, y, altitude) to SceneKit's Y-up (x, altitude, -y).
                        return SIMD3(p.x, h, -p.y)
                    }
                    let color = linearRGBA(color(for: band, variant: Int(terrain.variants[face]),
                                                 jitter: terrain.jitter[face]))
                    let uv = points.map { SIMD2($0.x, $0.z) / grainTile }
                    mesh.triangle(points[0], points[1], points[2], uv: (uv[0], uv[1], uv[2]), color: color)
                }
            }
        }

        let material = SCNMaterial()
        material.lightingModel = .lambert
        // The vertex colour multiplies this, so the grain textures every face without
        // re-tinting it.
        material.diffuse.contents = PaperTextures.grain(seed: seed)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.mipFilter = .linear
        material.diffuse.maxAnisotropy = 8

        let node = SCNNode(geometry: mesh.geometry(materials: [material]))
        node.name = "terrain"
        // The ground takes shadows; it casts none worth the cost — from above, a hill's shadow
        // falls on its own far slope, which the flat shading already darkens.
        node.castsShadow = false
        return node
    }

    private static func color(for band: TerrainBand, variant: Int, jitter: Float) -> PaperColor {
        let base: PaperColor
        let spread: CGFloat
        switch band {
        case .water: base = water; spread = 0.025
        case .shore: base = shore; spread = 0.04
        case .meadow: base = meadows[variant % meadows.count]; spread = 0.05
        case .hill: base = hills[variant % hills.count]; spread = 0.05
        case .rock: base = rocks[variant % rocks.count]; spread = 0.05
        case .snow: base = snow; spread = 0.025
        }
        return base.scaled(1 + CGFloat(jitter) * spread)
    }
}
