// A flat-shaded triangle soup, built a face at a time.
//
// Everything this saver makes in code — the landscape and every stand-in model — is folded
// paper, so every face is its own facet with its own normal and nothing is shared between
// faces. That is wasteful by the usual measure and exactly right here: a shared vertex would
// smooth a fold away.

import Foundation
import SceneKit
import simd

struct FacetMesh {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private(set) var colors: [SIMD4<Float>] = []
    /// Optional second and third texcoord channels, for a shader modifier that needs to know
    /// more about a face than its colour; they arrive as `_geometry.texcoords[1]` and `[2]`.
    /// Written only if every face supplied them — and a modifier must not be attached without
    /// them, since reading an absent channel makes the whole mesh vanish rather than read zero
    /// (`docs/next-session.md`, traps).
    private(set) var channel1: [SIMD2<Float>] = []
    private(set) var channel2: [SIMD2<Float>] = []

    var isEmpty: Bool { positions.isEmpty }

    mutating func reserve(faces: Int) {
        positions.reserveCapacity(faces * 3)
        normals.reserveCapacity(faces * 3)
        uvs.reserveCapacity(faces * 3)
    }

    /// One facet, counter-clockwise seen from its front. `color` is linear RGBA.
    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                           uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) = (.zero, .zero, .zero),
                           color: SIMD4<Float>? = nil) {
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        let n = length > 1e-12 ? cross / length : SIMD3<Float>(0, 1, 0)
        positions += [a, b, c]
        normals += [n, n, n]
        uvs += [uv.0, uv.1, uv.2]
        if let color { colors += [color, color, color] }
    }

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                           uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>), color: SIMD4<Float>,
                           channel1 one: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
                           channel2 two: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)) {
        triangle(a, b, c, uv: uv, color: color)
        channel1 += [one.0, one.1, one.2]
        channel2 += [two.0, two.1, two.2]
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       color: SIMD4<Float>? = nil) {
        triangle(a, b, c, color: color)
        triangle(a, c, d, color: color)
    }

    func geometry(materials: [SCNMaterial]) -> SCNGeometry {
        var sources = [FacetMesh.source(positions, .vertex, components: 3),
                       FacetMesh.source(normals, .normal, components: 3),
                       FacetMesh.source(uvs, .texcoord, components: 2)]
        if colors.count == positions.count {
            sources.append(FacetMesh.source(colors, .color, components: 4))
        }
        if channel1.count == positions.count && channel2.count == positions.count {
            sources.append(FacetMesh.source(channel1, .texcoord, components: 2))
            sources.append(FacetMesh.source(channel2, .texcoord, components: 2))
        }
        let element = SCNGeometryElement(indices: Array(0..<UInt32(positions.count)), primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = materials
        return geometry
    }

    /// `SIMD3<Float>` is padded to 16 bytes, so the stride is the type's and only the leading
    /// `components` floats of each are read.
    private static func source<T>(_ values: [T], _ semantic: SCNGeometrySource.Semantic,
                                  components: Int) -> SCNGeometrySource {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: values.count,
                                 usesFloatComponents: true, componentsPerVector: components,
                                 bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                 dataStride: MemoryLayout<T>.stride)
    }
}

/// sRGB-authored colour to the linear values SceneKit expects of a vertex colour.
///
/// Unlike an image, which SceneKit decodes by its tag, a vertex colour is taken as linear with
/// no tag to say so. Measured with an unlit quad: a vertex colour of 0.4 displayed at 184/255,
/// where an sRGB reading would have shown 102 — so a palette passed through unconverted comes
/// out pale and washed.
func linearRGBA(_ c: PaperColor, alpha: Float = 1) -> SIMD4<Float> {
    func channel(_ v: CGFloat) -> Float {
        let x = Float(v)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    return SIMD4(channel(c.r), channel(c.g), channel(c.b), alpha)
}

/// A matte paper material in a flat colour.
func paperMaterial(_ color: PaperColor, doubleSided: Bool = true, glow: CGFloat = 0) -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .lambert
    material.diffuse.contents = color.ns
    material.isDoubleSided = doubleSided
    if glow > 0 { material.emission.contents = color.scaled(glow).ns }
    return material
}
