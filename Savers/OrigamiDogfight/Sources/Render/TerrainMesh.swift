// The landscape as geometry: every triangle of `Terrain` its own flat-shaded facet in its own
// colour of paper, with its fold lines scored in.
//
// Three vertices per triangle, never shared, so each face carries its own normal and colour —
// a shared-vertex mesh would smooth the folds away, and the folds are the whole look.
//
// The colours are the season's (`SeasonPalette`); the light on the folds is the hour's, set on
// the material as the sun moves (`DayLight`).

import AppKit
import Foundation
import SceneKit
import simd

enum TerrainMesh {

    static func node(for terrain: Terrain, seed: UInt64, season: Season) -> SCNNode {
        let palette = SeasonPalette.of(season)
        let lattice = terrain.lattice
        let points = (0..<lattice.faceCount).map { scenePoints(terrain, face: $0) }
        let normals = points.map { simd_normalize(simd_cross($0[1] - $0[0], $0[2] - $0[0])) }
        let creases = creaseCodes(terrain, points: points, normals: normals)
        var mesh = FacetMesh()
        mesh.reserve(faces: lattice.faceCount)
        // One grain tile spans this many metres; small enough that the fibres read at screen
        // scale, large enough that the repeat is not seen.
        let grainTile: Float = 0.9
        // Which corner of its face each vertex is, for the crease shader.
        let corner = (SIMD2<Float>(1, 0), SIMD2<Float>(0, 1), SIMD2<Float>(0, 0))

        for face in 0..<lattice.faceCount {
            let p = points[face]
            // The drawn band, so a frozen lake is drawn as ice where the fight treats it as ground.
            let color = linearRGBA(color(for: terrain.surface[face], variant: Int(terrain.variants[face]),
                                         jitter: terrain.jitter[face], palette: palette))
            let uv = p.map { SIMD2($0.x, $0.z) / grainTile }
            let code = SIMD2<Float>(creases[face], 0)
            mesh.triangle(p[0], p[1], p[2], uv: (uv[0], uv[1], uv[2]), color: color,
                          channel1: corner, channel2: (code, code, code))
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
        material.shaderModifiers = [.geometry: creaseGeometry, .surface: creaseSurface]
        let dark = palette.foldDark
        material.setValue(NSValue(scnVector3: SCNVector3(CGFloat(dark.x), CGFloat(dark.y), CGFloat(dark.z))),
                          forKey: "foldDark")
        aim(material, foldsFrom: DayLight.sunTravel(at: 0.5))

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
    ///
    /// A uniform rather than baked into the vertex colours, as it was while the sun never moved:
    /// the sun now crosses the sky over a session, and the folds must turn with it.
    static func aim(_ material: SCNMaterial, foldsFrom travel: SIMD3<Float>) {
        let elevation: Float = 32 * .pi / 180
        // Toward the sun is against its travel; sim (x, y) is SceneKit (x, -z).
        let bearing = simd_normalize(SIMD2(-travel.x, travel.y))
        let light = SIMD3(bearing.x * cos(elevation), sin(elevation), bearing.y * cos(elevation))
        material.setValue(NSValue(scnVector3: SCNVector3(CGFloat(light.x), CGFloat(light.y), CGFloat(light.z))),
                          forKey: "foldLight")
    }

    /// Per face, how sharply it is folded along each of its three edges — the edge opposite
    /// corner 0, 1, 2 — packed into one float: each a signed level from -7 (sharp valley) to 7
    /// (sharp ridge), offset to 1...15 and stored four bits apart. Whole numbers below 4096
    /// survive a float and the rasteriser exactly, since all three vertices carry the same one.
    ///
    /// Graded on the folds this landscape actually has — half its edges turn by under 3°, a
    /// tenth by over 12° — so meadow creases are faint and a ridge is a clear line. A ramp
    /// pitched at sharp folds left every line invisible.
    private static func creaseCodes(_ terrain: Terrain, points: [[SIMD3<Float>]],
                                    normals: [SIMD3<Float>]) -> [Float] {
        let lattice = terrain.lattice
        let centres = points.map { ($0[0] + $0[1] + $0[2]) / 3 }
        let gentle: Float = 2 * .pi / 180, sharp: Float = 10 * .pi / 180
        return (0..<lattice.faceCount).map { face in
            let c = lattice.corners(of: face)
            let corners = [c.x, c.y, c.z]
            var code: Float = 0
            for k in 0..<3 {
                let edge = [corners[(k + 1) % 3], corners[(k + 2) % 3]]
                var level: Float = 0
                if let other = lattice.neighbours[face].first(where: { n in
                    edge.allSatisfy { any(lattice.corners(of: n) .== $0) }
                }) {
                    let angle = acos(min(max(simd_dot(normals[face], normals[other]), -1), 1))
                    // The neighbour's middle below this face's plane: the fold between them is a ridge.
                    let ridge = simd_dot(centres[other] - centres[face], normals[face]) < 0
                    level = (smoothstep(gentle, sharp, angle) * 7).rounded() * (ridge ? 1 : -1)
                }
                code += (level + 8) * pow(16, Float(k))
            }
            return code
        }
    }

    /// Unpacks the fold levels once per vertex and hands the fragment its place in the face —
    /// and shades the face for the low sun: every vertex of a face carries the face's own normal,
    /// so the shade is one value across it. Strengthened past what the low sun alone would give,
    /// then floored: a lake bank or a cliff turned from the sun went near black, and the ground
    /// is a backdrop. Below level the shade darkens each channel by its own `foldDark`, which is
    /// how winter's shaded snow goes blue rather than grey. The terrain node sits at the origin
    /// unrotated, so the model-space normal is the world's.
    private static let creaseGeometry = """
    #pragma arguments
    float3 foldLight;
    float3 foldDark;
    #pragma varyings
    float3 facet;
    float3 fold;
    float3 shade;
    #pragma body
    float level = 0.35 + 0.65 * max(foldLight.y, 0.0);
    float lit = 0.35 + 0.65 * max(dot(_geometry.normal, foldLight), 0.0);
    float s = max(1.0 + 1.4 * (lit / level - 1.0), 0.62);
    out.shade = s >= 1.0 ? float3(s) : 1.0 - (1.0 - s) * foldDark;
    float2 corner = _geometry.texcoords[1];
    out.facet = float3(corner.x, corner.y, 1.0 - corner.x - corner.y);
    float packed = _geometry.texcoords[2].x;
    float3 levels = float3(fmod(packed, 16.0), fmod(floor(packed / 16.0), 16.0), floor(packed / 256.0));
    out.fold = (levels - 8.0) / 7.0;
    """

    /// A crease about a pixel and a half wide along each folded edge, measured in screen pixels
    /// so it stays a fine score line at every size: a ridge catches a little light, a valley a
    /// little shade. Both faces of an edge draw their half of the line.
    private static let creaseSurface = """
    #pragma varyings
    float3 facet;
    float3 fold;
    float3 shade;
    #pragma body
    _surface.diffuse.rgb = min(_surface.diffuse.rgb * in.shade, float3(1.0));
    float3 pixel = max(fwidth(in.facet), float3(1e-6));
    float3 near = 1.0 - smoothstep(float3(0.0), pixel * 1.6, in.facet);
    float3 f = in.fold * near;
    float ridge = max(max(f.x, f.y), max(f.z, 0.0));
    float valley = max(max(-f.x, -f.y), max(-f.z, 0.0));
    _surface.diffuse.rgb *= 1.0 + 0.3 * (0.7 * ridge - valley);
    """

    // MARK: Colour

    private static func color(for band: TerrainBand, variant: Int, jitter: Float,
                              palette p: SeasonPalette) -> PaperColor {
        let base: PaperColor
        let spread: CGFloat
        switch band {
        case .water: base = variant == 1 ? p.shallows : p.water; spread = 0.0125
        case .shore: base = p.shore; spread = 0.02
        case .meadow: base = p.meadows[variant % p.meadows.count]; spread = 0.025
        case .hill: base = p.hills[variant % p.hills.count]; spread = 0.025
        case .rock: base = p.rocks[variant % p.rocks.count]; spread = 0.025
        case .snow: base = p.snow; spread = 0.0125
        }
        // Small: one field is one sheet of paper, and its faces should differ by how they are
        // folded, not by a random tint each.
        return base.scaled(1 + CGFloat(jitter) * spread)
    }
}
