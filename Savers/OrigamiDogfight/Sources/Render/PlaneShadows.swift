// The planes' shadows on the ground: each plane's own folded shape, flattened onto the land
// along the sun's bearing, and laid over whatever it falls on as the sun's shadow would darken it.
//
// They are not the sun's shadow map's, as every other shadow here is, because the sun is low at
// both ends of the day — that is most of what makes a morning or an evening — and a plane flies a
// metre up: under an evening sun its shadow would land a metre and a half or more away, off
// across the field, no longer plainly that plane's. A house's shadow at that angle is just a long
// evening shadow. SceneKit draws every `castsShadow` node into every light's shadow map, whatever
// the light's category, so the planes cannot have a second, higher sun to themselves; instead
// they cast nothing, and this projects them, along the sun's own bearing but never further than
// `reach` per metre of height — midday's reach, a little over.
//
// The darkening is a multiply by what the sun's shadow leaves on level ground (`DayLight` works
// it out channel by channel), so a plane's shadow matches a tree's beside it in depth and tint:
// grey-violet at noon, deep blue at dusk.
//
// What is projected is the plane's outline seen from above in its own frame, one layer thick,
// not the model: a folded plane is several layers of paper, and a multiply drawn once per layer
// darkened the shadow in steps wherever the folds overlap, as a shadow map never does. The
// outline lies in the plane's wing plane, so banking still narrows the shadow and a crumple
// still squashes it.

import AppKit
import Foundation
import SceneKit
import simd

final class PlaneShadows {
    let root = SCNNode()
    private let material = SCNMaterial()
    private var shadows: [Int: SCNNode] = [:]
    /// Outlines by plane type and size: every plane of a kind shares one.
    private var outlines: [String: SCNGeometry] = [:]
    /// The sun's direction of travel in scene axes, its reach capped, with y = -1.
    private var travel = SIMD3<Float>(0.36, -1, 0.42)

    /// How far a plane's shadow may land from it per metre of height. Midday's sun reaches 0.55.
    static let reach: Float = 0.62

    /// Above the ground it is laid on: flat, it is projected to the height of the ground where
    /// it lands, and a fold rising under it would otherwise cover part of it. Drawn without a
    /// depth test it shows anyway; this only keeps it off the very surface.
    private static let lift: Float = 0.004

    init() {
        material.lightingModel = .constant
        material.blendMode = .multiply
        material.writesToDepthBuffer = false
        // After the ground and before everything standing on it (`settle`), so a fold rising
        // under a flat shadow cannot hide it, and a tree or a tank drawn after covers it.
        material.readsFromDepthBuffer = false
        material.isDoubleSided = true
        material.diffuse.contents = NSColor.white
    }

    /// `travel` is the sun's in sim axes, z down (`DayLight.sunTravel`); `keeps` is the light the
    /// sun's shadow leaves on level ground, per channel, as a fraction.
    func light(travel sun: SIMD3<Float>, keeps: SIMD3<Float>) {
        var reach = SIMD2(sun.x, sun.y) / max(-sun.z, 1e-3)
        let length = simd_length(reach)
        if length > PlaneShadows.reach { reach *= PlaneShadows.reach / length }
        // Sim (x, y, z) to SceneKit's Y-up (x, z, -y).
        travel = SIMD3(reach.x, -1, -reach.y)
        let k = simd_clamp(keeps, SIMD3(repeating: 0), SIMD3(repeating: 1))
        // `diffuse` is decoded from sRGB to linear by SceneKit; `keeps` is linear already.
        material.diffuse.contents = NSColor(srgbRed: CGFloat(PlaneShadows.encode(k.x)), green: CGFloat(PlaneShadows.encode(k.y)),
                                            blue: CGFloat(PlaneShadows.encode(k.z)), alpha: 1)
    }

    /// The shadow of the plane `id`, whose folded model is `model`, cast for this frame. `kind`
    /// names the model's shape and size — planes of one kind share an outline, cut on first
    /// sight from the model's own triangles.
    func cast(_ id: Int, kind: @autoclosure () -> String, model: SCNNode, terrain: Terrain) {
        let shadow = shadows[id] ?? make(id, kind: kind(), from: model)
        let world = model.simdWorldTransform
        let at = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        // Where the middle of the shadow lands: first onto the height under the plane, then
        // onto the height there, which is what the shadow is laid at.
        func ground(_ p: SIMD3<Float>) -> Float { terrain.surfaceHeight(at: SIMD2(p.x, -p.z)) }
        let first = at + travel * max(at.y - ground(at), 0)
        let height = max(ground(first + travel * (first.y - ground(first))), ground(at) - 0.05) + PlaneShadows.lift
        // Projection onto the level plane y = height along `travel` (whose y is -1): a point
        // moves by `travel` times its height above that plane.
        let project = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(travel.x, 0, travel.z, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(-travel.x * height, height, -travel.z * height, 1)))
        shadow.simdTransform = project * world
    }

    /// The plane has gone: its shadow with it.
    func drop(_ id: Int) {
        shadows.removeValue(forKey: id)?.removeFromParentNode()
    }

    private func make(_ id: Int, kind: String, from model: SCNNode) -> SCNNode {
        let outline = outlines[kind] ?? PlaneShadows.outline(of: model, material: material)
        outlines[kind] = outline
        let shadow = SCNNode(geometry: outline)
        shadow.castsShadow = false
        shadow.renderingOrder = PlaneShadows.order
        root.addChildNode(shadow)
        shadows[id] = shadow
        return shadow
    }

    /// `model`'s outline seen from straight above in its own space, as flat quads on y = 0 that
    /// never overlap: its triangles are filled into a mask, and each row's runs of filled cells
    /// become one quad. Cells of a hundred-and-twenty-sixth of the plane's length are under a
    /// pixel at the size a plane is drawn in the fight, and still fine on the lineup's large ones.
    private static func outline(of model: SCNNode, material: SCNMaterial) -> SCNGeometry {
        // Not the wingtips' navigation lights: an `SCNPlane`'s vertex data is a unit square, sized
        // elsewhere, so read as triangles a 1 cm dot is a metre-wide sheet — it made the dart's
        // shadow a wedge across half the field.
        let triangles = StickerSpots.topTriangles(of: model, exclude: [PlaneFleet.navigationLights])
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for t in triangles { lo = simd_min(lo, t.lo); hi = simd_max(hi, t.hi) }
        var mesh = FacetMesh()
        let cells = 128
        guard lo.x < hi.x, lo.y < hi.y,
              let ctx = CGContext(data: nil, width: cells, height: cells, bitsPerComponent: 8, bytesPerRow: cells,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return mesh.geometry(materials: [material]) }
        let cell = max(hi.x - lo.x, hi.y - lo.y) / Float(cells - 2)
        let origin = lo - SIMD2(repeating: cell)
        func pixel(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: CGFloat((p.x - origin.x) / cell), y: CGFloat((p.z - origin.y) / cell))
        }
        ctx.setShouldAntialias(false)
        ctx.setFillColor(gray: 1, alpha: 1)
        for t in triangles {
            ctx.beginPath()
            ctx.move(to: pixel(t.a)); ctx.addLine(to: pixel(t.b)); ctx.addLine(to: pixel(t.c))
            ctx.closePath()
            ctx.fillPath()
        }
        guard let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return mesh.geometry(materials: [material]) }
        // The bitmap's first row in memory is its top, which is the largest z.
        func filled(_ i: Int, _ j: Int) -> Bool { bytes[(cells - 1 - j) * cells + i] > 127 }
        for j in 0..<cells {
            var i = 0
            while i < cells {
                guard filled(i, j) else { i += 1; continue }
                let start = i
                while i < cells, filled(i, j) { i += 1 }
                let x0 = origin.x + Float(start) * cell, x1 = origin.x + Float(i) * cell
                let z0 = origin.y + Float(j) * cell, z1 = z0 + cell
                let a = SIMD3(x0, 0, z0), b = SIMD3(x1, 0, z0), c = SIMD3(x1, 0, z1), d = SIMD3(x0, 0, z1)
                mesh.triangle(a, c, b)
                mesh.triangle(a, d, c)
            }
        }
        return mesh.geometry(materials: [material])
    }

    /// The ground and what is draped on it are drawn first (`groundOrder`), then the shadows,
    /// then everything else at SceneKit's default of 0.
    static let order = -1
    static let groundOrder = -2

    private static func encode(_ v: Float) -> Float {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}
