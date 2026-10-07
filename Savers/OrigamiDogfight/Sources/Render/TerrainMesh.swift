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
    private static let shallows = PaperColor(0.52, 0.74, 0.87)
    private static let shore = PaperColor(0.88, 0.78, 0.58)
    private static let meadows = [PaperColor(0.56, 0.76, 0.40), PaperColor(0.46, 0.69, 0.35),
                                  PaperColor(0.64, 0.80, 0.44), PaperColor(0.40, 0.62, 0.33),
                                  PaperColor(0.80, 0.78, 0.44)]
    /// A deeper green than the meadows rather than an olive: the hills cover a third of some
    /// landscapes, and olive there read as a drab brown mass behind the fight.
    private static let hills = [PaperColor(0.45, 0.61, 0.34), PaperColor(0.41, 0.57, 0.32)]
    private static let rocks = [PaperColor(0.62, 0.57, 0.50), PaperColor(0.53, 0.49, 0.44)]
    /// Off-white, so the sunlit face of a cap is the only one that reaches white and the others
    /// show the fold. At white the whole cap clipped to one blank sheet.
    private static let snow = PaperColor(0.84, 0.85, 0.86)

    static func node(for terrain: Terrain, seed: UInt64) -> SCNNode {
        let lattice = terrain.lattice
        let points = (0..<lattice.faceCount).map { scenePoints(terrain, face: $0) }
        let normals = points.map { simd_normalize(simd_cross($0[1] - $0[0], $0[2] - $0[0])) }
        var mesh = FacetMesh()
        mesh.reserve(faces: lattice.faceCount)
        // One grain tile spans this many metres; small enough that the fibres read at screen
        // scale, large enough that the repeat is not seen.
        let grainTile: Float = 0.9

        for face in 0..<lattice.faceCount {
            let p = points[face]
            var color = linearRGBA(color(for: terrain.bands[face], variant: Int(terrain.variants[face]),
                                         jitter: terrain.jitter[face]))
            let shade = foldShade(normals[face])
            color = SIMD4(simd_min(SIMD3(color.x, color.y, color.z) * shade, SIMD3(repeating: 1)), color.w)
            let uv = p.map { SIMD2($0.x, $0.z) / grainTile }
            mesh.triangle(p[0], p[1], p[2], uv: (uv[0], uv[1], uv[2]), color: color)
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

    private static func scenePoints(_ terrain: Terrain, face: Int) -> [SIMD3<Float>] {
        let c = terrain.lattice.corners(of: face)
        return [c.x, c.y, c.z].map { i in
            let p = terrain.lattice.points[Int(i)]
            // Sim (x, y, altitude) to SceneKit's Y-up (x, altitude, -y).
            return SIMD3(p.x, terrain.ground[Int(i)], -p.y)
        }
    }

    // MARK: Folds

    /// Where the light comes from for the folds: the sun's own bearing, but low.
    ///
    /// The scene's sun is high, because it also casts the planes' shadows and those must land
    /// close enough to be read as theirs. Under a high sun, though, faces tilted a few degrees
    /// apart differ by a few percent, and from straight overhead that is the only cue to relief
    /// there is: the folds vanished and the land read as flat paper with triangles drawn on it.
    /// So each face's colour carries what a low sun would do to it, as a factor that leaves
    /// level ground exactly as it was. The real sun still lights and shadows on top.
    private static let foldLight: SIMD3<Float> = {
        let elevation: Float = 32 * .pi / 180
        let travel = DogfightScene.sunTravel
        // Toward the sun is against its travel; sim (x, y) is SceneKit (x, -z).
        let bearing = simd_normalize(SIMD2(-travel.x, travel.y))
        return SIMD3(bearing.x * cos(elevation), sin(elevation), bearing.y * cos(elevation))
    }()

    private static func foldShade(_ normal: SIMD3<Float>) -> Float {
        let ambient: Float = 0.35
        func lit(_ n: SIMD3<Float>) -> Float { ambient + (1 - ambient) * max(simd_dot(n, foldLight), 0) }
        let relative = lit(normal) / lit(SIMD3(0, 1, 0))
        // Strengthened past what the low sun alone would give, then floored: a lake bank or a
        // cliff turned from the sun went near black, and the ground is a backdrop.
        return max(1 + 1.4 * (relative - 1), 0.62)
    }

    // MARK: Colour

    private static func color(for band: TerrainBand, variant: Int, jitter: Float) -> PaperColor {
        let base: PaperColor
        let spread: CGFloat
        switch band {
        case .water: base = variant == 1 ? shallows : water; spread = 0.0125
        case .shore: base = shore; spread = 0.02
        case .meadow: base = meadows[variant % meadows.count]; spread = 0.025
        case .hill: base = hills[variant % hills.count]; spread = 0.025
        case .rock: base = rocks[variant % rocks.count]; spread = 0.025
        case .snow: base = snow; spread = 0.0125
        }
        // Small: one field is one sheet of paper, and its faces should differ by how they are
        // folded, not by a random tint each.
        return base.scaled(1 + CGFloat(jitter) * spread)
    }
}
