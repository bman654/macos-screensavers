// What lies flat on the landscape: the paper roads, and the char marks where things burned.
//
// Both are draped — a mesh whose every vertex is set on the drawn surface under it and lifted a
// few millimetres — rather than flat quads, because the ground is folded: a flat mark on a
// hillside floats off one side of it and is buried in the other. Neither casts a shadow, and both
// take the planes' shadows as the ground does.

import AppKit
import CoreGraphics
import Foundation
import SceneKit
import simd

enum Drape {
    /// High enough that the depth buffer never lets the ground show through, at the six metres
    /// the camera stands off — and low enough that nobody sees a step at a mark's edge.
    static let lift: Float = 0.004

    static func point(_ p: SIMD2<Float>, on terrain: Terrain, lift: Float = Drape.lift) -> SIMD3<Float> {
        p.scene(altitude: terrain.surfaceHeight(at: p) + lift)
    }
}

final class GroundMarks {
    let root = SCNNode()
    private let terrain: Terrain
    private let scorch = SCNMaterial()
    private var scorches: [Int: SCNNode] = [:]

    init(terrain: Terrain) {
        self.terrain = terrain
        scorch.lightingModel = .lambert
        scorch.diffuse.contents = GroundMarks.charImage()
        scorch.blendMode = .alpha
        scorch.writesToDepthBuffer = false
        scorch.isDoubleSided = false
    }

    func sync(_ marks: Marks, time: Double) {
        var seen = Set<Int>()
        for mark in marks.scorches {
            seen.insert(mark.id)
            let node = scorches[mark.id] ?? make(mark)
            scorches[mark.id] = node
            // Spreading out from under the fire over its first seconds; fading as the next match
            // comes on.
            let grow = smoothstep(0, 2.5, Float(time - mark.bornAt))
            let fade = mark.fadeFrom.map { 1 - smoothstep(0, Float(Marks.fadeTime), Float(time - $0)) } ?? 1
            node.opacity = CGFloat(0.92 * grow * fade)
        }
        for (id, node) in scorches where !seen.contains(id) {
            node.removeFromParentNode()
            scorches[id] = nil
        }
    }

    /// A seven-by-seven grid over the mark's square, turned by its own angle so no two char the
    /// same way.
    private func make(_ mark: Scorch) -> SCNNode {
        var mesh = FacetMesh()
        let n = 6
        let half = mark.size / 2
        let c = cos(mark.turn), s = sin(mark.turn)
        func at(_ i: Int, _ j: Int) -> (SIMD3<Float>, SIMD2<Float>) {
            let u = Float(i) / Float(n), v = Float(j) / Float(n)
            let local = SIMD2((u * 2 - 1) * half, (v * 2 - 1) * half)
            let p = mark.position + SIMD2(local.x * c - local.y * s, local.x * s + local.y * c)
            return (Drape.point(p, on: terrain), SIMD2(u, v))
        }
        for j in 0..<n {
            for i in 0..<n {
                let a = at(i, j), b = at(i + 1, j), d = at(i + 1, j + 1), e = at(i, j + 1)
                // Counter-clockwise seen from above in the sim's axes, which is up-facing in
                // SceneKit's, as the terrain's own faces are (`FacetLattice.corners`).
                mesh.triangle(a.0, b.0, d.0, uv: (a.1, b.1, d.1))
                mesh.triangle(a.0, d.0, e.0, uv: (a.1, d.1, e.1))
            }
        }
        let node = SCNNode(geometry: mesh.geometry(materials: [scorch]))
        node.castsShadow = false
        node.opacity = 0
        root.addChildNode(node)
        return node
    }

    /// A char mark: a ragged blot, darkest where the fire sat, browning out to a singed edge
    /// with a few flecks of burnt paper thrown past it. A picture, so sRGB-tagged like every
    /// generated sheet here (`PaperTextures`).
    private static func charImage(size: Int = 128) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var rand = Rand(seed: 0xC4A2)
        let w = CGFloat(size), centre = CGPoint(x: w / 2, y: w / 2)
        let path = CGMutablePath()
        let lobes = 22
        for k in 0...lobes {
            let a = CGFloat(k) / CGFloat(lobes) * 2 * .pi
            let r = w * 0.5 * CGFloat(rand.inRange(0.62, 0.92))
            let p = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        let colours = [CGColor(srgbRed: 0.08, green: 0.06, blue: 0.05, alpha: 0.95),
                       CGColor(srgbRed: 0.16, green: 0.11, blue: 0.08, alpha: 0.85),
                       CGColor(srgbRed: 0.36, green: 0.25, blue: 0.15, alpha: 0.0)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 0.45, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: w * 0.48, options: [])
        }
        ctx.resetClip()
        for _ in 0..<26 {
            let a = CGFloat(rand.inRange(0, 2 * .pi)), r = w * CGFloat(rand.inRange(0.25, 0.47))
            let s = w * CGFloat(rand.inRange(0.012, 0.03))
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.08, blue: 0.06, alpha: CGFloat(rand.inRange(0.5, 0.9))))
            ctx.fill(CGRect(x: centre.x + cos(a) * r - s / 2, y: centre.y + sin(a) * r - s / 2, width: s, height: s))
        }
        return ctx.makeImage()
    }
}

/// The roads: every strip in one node, draped edge by edge so it lies in the folds.
enum RoadStrips {
    static func node(roads: [Road], terrain: Terrain, season: Season) -> SCNNode {
        var mesh = FacetMesh()
        let w = Roads.halfWidth
        for road in roads where road.points.count > 1 {
            var previous: (SIMD3<Float>, SIMD3<Float>, Float)?
            for (i, p) in road.points.enumerated() {
                let a = road.points[max(i - 1, 0)], b = road.points[min(i + 1, road.points.count - 1)]
                let along = simd_normalize(b - a + SIMD2(1e-7, 0))
                let side = SIMD2(-along.y, along.x)
                let left = Drape.point(p + side * w, on: terrain), right = Drape.point(p - side * w, on: terrain)
                // A tenth of a metre of road per repeat of its texture.
                let v = road.distances[i] / 0.1
                if let (pl, pr, pv) = previous {
                    // Counter-clockwise from above, so up-facing (see the scorches).
                    mesh.triangle(pl, pr, right, uv: (SIMD2(0, pv), SIMD2(1, pv), SIMD2(1, v)))
                    mesh.triangle(pl, right, left, uv: (SIMD2(0, pv), SIMD2(1, v), SIMD2(0, v)))
                }
                previous = (left, right, v)
            }
        }
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = stripImage(season: season)
        material.diffuse.wrapT = .repeat
        material.diffuse.mipFilter = .linear
        let node = SCNNode(geometry: mesh.geometry(materials: [material]))
        node.name = "roads"
        node.castsShadow = false
        return node
    }

    /// A strip of paper: a pale lane folded down at both edges, a little worn along the middle
    /// where the wheels go. Winter's is the grey of a lane through snow.
    private static func stripImage(season: Season) -> CGImage? {
        let width = 32, height = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let base = season == .winter ? PaperColor(0.66, 0.65, 0.64) : PaperColor(0.84, 0.78, 0.64)
        ctx.setFillColor(base.cg)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(base.scaled(0.8).cg)
        ctx.fill(CGRect(x: 0, y: 0, width: 3, height: height))
        ctx.fill(CGRect(x: width - 3, y: 0, width: 3, height: height))
        ctx.setFillColor(base.scaled(0.93).cg)
        ctx.fill(CGRect(x: 9, y: 0, width: 3, height: height))
        ctx.fill(CGRect(x: width - 12, y: 0, width: 3, height: height))
        return ctx.makeImage()
    }
}
