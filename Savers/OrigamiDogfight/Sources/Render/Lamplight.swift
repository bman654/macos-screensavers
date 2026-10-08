// Lamplight on the ground round every building with windows, so that "the windows are lit" can
// be seen from a camera that looks almost straight down.
//
// The windows themselves glow (`DayLight` sets their emission), but they are on the walls, and
// from above the roofs hide all of them: in a close crop of a lit evening village not one window
// pixel showed. What a lit house looks like from the air is a pool of warm light spilling out
// round it, so that is what is drawn — a soft disc of lamp colour under each house, mill and
// hangar, which the building itself covers at the middle. One material for all of them,
// constant-lit so the dusk does not dim it, faded in and out by `glow`; at zero the pools are
// hidden outright. Blended over the ground rather than added to it: SceneKit fogs every
// fragment, and an additive square fogged adds the haze's colour to all of it, corners and all.

import AppKit
import CoreGraphics
import Foundation
import SceneKit
import simd

final class Lamplight {
    private let material = SCNMaterial()
    /// The houses' pools, draped on the folds, in one node; hangars carry their own (`pool`).
    let houses = SCNNode()
    /// Every pool, held weakly: a hangar and its pool go when its match ends.
    private let pools = NSHashTable<SCNNode>.weakObjects()

    /// 0 by day, 1 at dusk.
    var glow: Float = 0 {
        didSet {
            guard glow != oldValue else { return }
            let g = CGFloat(min(max(glow, 0), 1))
            material.transparency = g
            for node in pools.allObjects { node.isHidden = g <= 0.01 }
        }
    }

    init() {
        material.lightingModel = .constant
        material.diffuse.contents = Lamplight.poolImage()
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = false
        material.transparency = 0
        houses.isHidden = true
        pools.add(houses)
    }

    /// A pool under every house, and so under every mill, which stands in a house's place.
    func light(houses spots: [PropSpot], terrain: Terrain) {
        let spots = spots.filter { $0.kind == .house }
        guard !spots.isEmpty else { return }
        var mesh = FacetMesh()
        let n = 6
        for spot in spots {
            // Reaching about a house's width beyond its walls (`ModelShelf`: 0.11 m across).
            let half = 0.15 * spot.scale
            func at(_ i: Int, _ j: Int) -> (SIMD3<Float>, SIMD2<Float>) {
                let u = Float(i) / Float(n), v = Float(j) / Float(n)
                let p = spot.position + SIMD2((u * 2 - 1) * half, (v * 2 - 1) * half)
                return (Drape.point(p, on: terrain, lift: Drape.lift * 1.5), SIMD2(u, v))
            }
            for j in 0..<n {
                for i in 0..<n {
                    let a = at(i, j), b = at(i + 1, j), d = at(i + 1, j + 1), e = at(i, j + 1)
                    // Counter-clockwise from above, so up-facing (see the scorches).
                    mesh.triangle(a.0, b.0, d.0, uv: (a.1, b.1, d.1))
                    mesh.triangle(a.0, d.0, e.0, uv: (a.1, d.1, e.1))
                }
            }
        }
        houses.geometry = mesh.geometry(materials: [material])
        Lamplight.settle(houses)
    }

    /// A flat pool for a hangar of `length` and `width`, in the hangar's own space — x along it
    /// from the back wall to the door — so it rises and folds with the hangar. Shifted toward the
    /// back wall, where the hangar's window is.
    func pool(length: Float, width: Float) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(length * 1.7), height: CGFloat(width * 2.4))
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.simdPosition = SIMD3(-length * 0.2, 0.006, 0)
        node.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        Lamplight.settle(node)
        node.isHidden = glow <= 0.01
        pools.add(node)
        return node
    }

    /// Drawn after the ground and everything opaque, which an additive surface that does not
    /// write depth must be, or the ground drawn after it would cover it.
    private static func settle(_ node: SCNNode) {
        node.castsShadow = false
        node.renderingOrder = 20
    }

    /// Warm lamplight falling off from the middle — strong under the eaves, gone by the edge. A
    /// picture, sRGB-tagged like every generated sheet here (`PaperTextures`).
    private static func poolImage(size: Int = 64) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(size), centre = CGPoint(x: w / 2, y: w / 2)
        let colours = [CGColor(srgbRed: 1.0, green: 0.80, blue: 0.46, alpha: 0.78),
                       CGColor(srgbRed: 1.0, green: 0.74, blue: 0.40, alpha: 0.55),
                       CGColor(srgbRed: 0.96, green: 0.62, blue: 0.30, alpha: 0.18),
                       CGColor(srgbRed: 0.90, green: 0.55, blue: 0.25, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 0.4, 0.72, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: w * 0.5, options: [])
        }
        return ctx.makeImage()
    }
}
