// Models built in code, for whatever the Blender library does not (yet) provide.
//
// The runtime must survive an empty `Assets/` with a picture rather than a black screen
// (`docs/origami-plan.md`), and these are that picture: each is the plan's description of the
// model reduced to a handful of folded facets — recognisably a dart, a delta, a fir tree — in
// the same frame and anchoring as an imported model, so nothing downstream can tell which it got.
//
// Planes are authored in Blender's axes (x forward, y left, z up) like the real models, and
// converted with the same rule, so a stand-in and an import are oriented by one code path's
// worth of reasoning.

import AppKit
import Foundation
import SceneKit
import simd

enum StandIns {
    /// US letter, height over width — what the real planes are folded from.
    static let letterAspect: Float = 11 / 8.5

    // MARK: Planes

    static func plane(_ type: PlaneType) -> ModelTemplate {
        var b = SheetBuilder()
        switch type {
        case .dart:
            let nose = SIMD3<Float>(0.14, 0, 0), tail = SIMD3<Float>(-0.14, 0, 0)
            let mid = SIMD3<Float>(-0.14, 0.03, 0.004), tip = SIMD3<Float>(-0.13, 0.06, 0.016)
            b.mirrored(nose, tail, mid)
            b.mirrored(nose, mid, tip)
            b.keel(nose, tail, SIMD3(-0.12, 0, -0.032))
        case .glider:
            let nose = SIMD3<Float>(0.13, 0, 0), noseCorner = SIMD3<Float>(0.13, 0.016, 0)
            let tail = SIMD3<Float>(-0.13, 0, 0)
            let rootFront = SIMD3<Float>(0.05, 0.03, 0.004), rootBack = SIMD3<Float>(-0.08, 0.03, 0.004)
            let tipFront = SIMD3<Float>(0.025, 0.14, 0.018), tipBack = SIMD3<Float>(-0.055, 0.14, 0.018)
            b.mirrored(nose, tail, rootBack)
            b.mirrored(nose, rootBack, rootFront)
            b.mirrored(nose, rootFront, noseCorner)
            b.mirrored(rootFront, rootBack, tipBack)
            b.mirrored(rootFront, tipBack, tipFront)
            b.keel(nose, tail, SIMD3(-0.11, 0, -0.024))
        case .bomber:
            let nose = SIMD3<Float>(0.125, 0, 0), noseCorner = SIMD3<Float>(0.125, 0.034, 0.002)
            let tail = SIMD3<Float>(-0.13, 0, 0)
            let rootFront = SIMD3<Float>(0.06, 0.052, 0.004), rootBack = SIMD3<Float>(-0.13, 0.045, 0.004)
            let tipFront = SIMD3<Float>(-0.02, 0.115, 0.012), tipBack = SIMD3<Float>(-0.105, 0.11, 0.012)
            b.mirrored(nose, tail, rootBack)
            b.mirrored(nose, rootBack, rootFront)
            b.mirrored(nose, rootFront, noseCorner)
            b.mirrored(rootFront, rootBack, tipBack)
            b.mirrored(rootFront, tipBack, tipFront)
            b.keel(nose, tail, SIMD3(-0.1, 0, -0.034))
        case .stunt:
            let nose = SIMD3<Float>(0.125, 0, 0), tail = SIMD3<Float>(-0.125, 0, 0)
            let mid = SIMD3<Float>(-0.125, 0.035, 0.003), tip = SIMD3<Float>(-0.115, 0.1, 0.012)
            b.mirrored(nose, tail, mid)
            b.mirrored(nose, mid, tip)
            // Upturned winglets.
            b.mirrored(tip, SIMD3(-0.05, 0.075, 0.01), SIMD3(-0.12, 0.1, 0.055), upright: true)
            b.keel(nose, tail, SIMD3(-0.11, 0, -0.026))
        case .interceptor:
            let nose = SIMD3<Float>(0.145, 0, 0), notch = SIMD3<Float>(-0.1, 0, 0)
            let rootFront = SIMD3<Float>(0.03, 0.018, 0.003), rootBack = SIMD3<Float>(-0.07, 0.024, 0.003)
            let tipFront = SIMD3<Float>(-0.095, 0.088, 0.014), tipBack = SIMD3<Float>(-0.12, 0.084, 0.014)
            let tailTip = SIMD3<Float>(-0.145, 0.022, 0.004)
            b.mirrored(nose, notch, rootBack)
            b.mirrored(nose, rootBack, rootFront)
            b.mirrored(rootFront, rootBack, tipBack)
            b.mirrored(rootFront, tipBack, tipFront)
            b.mirrored(notch, tailTip, rootBack)  // the split tail
            b.keel(nose, notch, SIMD3(-0.09, 0, -0.026))
        }
        let node = SCNNode(geometry: b.mesh.geometry(materials: [paperMaterial(PaperColor(0.95, 0.95, 0.92))]))
        return centered(node, sheetAspect: letterAspect)
    }

    /// Accumulates a folded sheet in Blender axes, keeping every wing facet's normal pointing
    /// up — a lambert face lit from its back reads as a hole in the wing — and giving each
    /// vertex its sheet coordinate.
    private struct SheetBuilder {
        var mesh = FacetMesh()
        private let length: Float = 0.29
        private let span: Float = 0.3

        mutating func mirrored(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, upright: Bool = false) {
            face(a, b, c, upright: upright)
            let m = SIMD3<Float>(1, -1, 1)
            face(a * m, b * m, c * m, upright: upright)
        }

        mutating func keel(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            face(a, b, c, upright: true)
        }

        private mutating func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, upright: Bool) {
            var (p, q, r) = (a, b, c)
            if !upright, simd_cross(q - p, r - p).z < 0 { swap(&q, &r) }
            func yUp(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, v.z, -v.y) }
            func uv(_ v: SIMD3<Float>) -> SIMD2<Float> {
                // Across the sheet is the span (and, for the keel, the depth folded under);
                // along it is the length, nose at the top of the sheet.
                SIMD2(0.5 + (v.y - v.z * 2) / span, 0.5 - v.x / length)
            }
            mesh.triangle(yUp(p), yUp(q), yUp(r), uv: (uv(p), uv(q), uv(r)))
        }
    }

    // MARK: Projectiles

    static func projectile(_ kind: WeaponKind) -> ModelTemplate {
        let silver = PaperColor(0.80, 0.81, 0.84)
        let node: SCNNode
        switch kind {
        case .spitball:
            node = SCNNode(geometry: icosphere(radius: 0.5, crumple: 0.08, seed: 1,
                                               material: paperMaterial(PaperColor(0.93, 0.92, 0.86))))
        case .paperBall:
            var mesh = FacetMesh()
            addIcosphere(&mesh, center: .zero, radius: 0.5, subdivisions: 1, crumple: 0.12, seed: 7)
            let material = paperMaterial(PaperColor(0.96, 0.95, 0.90))
            material.diffuse.contents = PaperTextures.sheet(Paper(kind: .notebook, tint: 0), aspect: 1, width: 256, seed: 3)
            node = SCNNode(geometry: mesh.geometry(materials: [material]))
        case .thumbtack:
            node = SCNNode()
            let head = SCNNode(geometry: SCNCylinder(radius: 0.42, height: 0.2))
            head.geometry?.materials = [paperMaterial(PaperColor(0.88, 0.2, 0.2))]
            head.simdPosition = SIMD3(0, 0.25, 0)
            let pin = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.06, height: 0.65))
            pin.geometry?.materials = [paperMaterial(silver)]
            pin.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
            pin.simdPosition = SIMD3(0, -0.15, 0)
            node.addChildNode(head)
            node.addChildNode(pin)
        case .paperClip:
            node = SCNNode()
            for (ring, offset) in [(Float(0.26), Float(0.05)), (0.17, -0.06)] {
                let loop = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(ring), pipeRadius: 0.035))
                loop.geometry?.materials = [paperMaterial(silver)]
                loop.simdScale = SIMD3(1.9, 1, 1)
                loop.simdPosition = SIMD3(offset, 0, 0)
                node.addChildNode(loop)
            }
        case .eraser:
            var mesh = FacetMesh()
            addBox(&mesh, min: SIMD3(-0.5, -0.17, -0.22), max: SIMD3(0.5, 0.17, 0.22), bevelTop: 0.25)
            node = SCNNode(geometry: mesh.geometry(materials: [paperMaterial(PaperColor(0.96, 0.6, 0.64))]))
        case .staples:
            var mesh = FacetMesh()
            addBox(&mesh, min: SIMD3(-0.5, 0.12, -0.05), max: SIMD3(0.5, 0.22, 0.05))
            addBox(&mesh, min: SIMD3(-0.5, -0.2, -0.05), max: SIMD3(-0.4, 0.12, 0.05))
            addBox(&mesh, min: SIMD3(0.4, -0.2, -0.05), max: SIMD3(0.5, 0.12, 0.05))
            node = SCNNode(geometry: mesh.geometry(materials: [paperMaterial(silver)]))
        case .rubberBand:
            node = SCNNode(geometry: SCNTorus(ringRadius: 0.45, pipeRadius: 0.035))
            node.geometry?.materials = [paperMaterial(PaperColor(0.86, 0.52, 0.32))]
            node.simdScale = SIMD3(1, 1, 0.42)
        case .confetti:
            node = SCNNode(geometry: SCNCylinder(radius: 0.5, height: 0.1))
            node.geometry?.materials = [paperMaterial(PaperColor(0.96, 0.95, 0.9))]
        }
        return centered(node, sheetAspect: 1)
    }

    // MARK: Props

    static func prop(_ kind: PropKind, variant: Int) -> ModelTemplate {
        var mesh = FacetMesh()
        var materials: [SCNMaterial] = []
        switch kind {
        case .tree:
            let greens = [PaperColor(0.20, 0.50, 0.30), PaperColor(0.28, 0.58, 0.28), PaperColor(0.36, 0.55, 0.22)]
            let green = greens[variant % greens.count]
            addPrism(&mesh, sides: 5, radius: 0.06, bottom: 0, top: 0.2, color: linearRGBA(PaperColor(0.50, 0.35, 0.22)))
            if variant % 2 == 0 {
                // A fir: two stacked folded cones.
                addCone(&mesh, sides: 6, radius: 0.45, bottom: 0.12, apex: 0.72, color: linearRGBA(green))
                addCone(&mesh, sides: 6, radius: 0.32, bottom: 0.45, apex: 1.0, color: linearRGBA(green.scaled(1.12)))
            } else {
                // A broadleaf: one faceted ball.
                addIcosphere(&mesh, center: SIMD3(0, 0.6, 0), radius: 0.4, subdivisions: 1, crumple: 0.1,
                             seed: UInt64(variant), color: linearRGBA(green.scaled(1.1)))
            }
            materials = [vertexColored()]
        case .rock:
            addIcosphere(&mesh, center: SIMD3(0, 0.3, 0), radius: 0.5, subdivisions: 0, crumple: 0.18,
                         seed: UInt64(variant) + 11, color: linearRGBA(PaperColor(0.62, 0.60, 0.56)), squash: 0.6)
            materials = [vertexColored()]
        case .house:
            let walls = linearRGBA(PaperColor(0.96, 0.93, 0.86))
            let roofs = [PaperColor(0.78, 0.30, 0.24), PaperColor(0.36, 0.40, 0.55), PaperColor(0.55, 0.36, 0.26)]
            addBox(&mesh, min: SIMD3(-0.5, 0, -0.32), max: SIMD3(0.5, 0.5, 0.32), color: walls)
            addGable(&mesh, width: 1.08, depth: 0.74, eave: 0.5, ridge: 0.85,
                     color: linearRGBA(roofs[variant % roofs.count]))
            materials = [vertexColored()]
        case .boat:
            // A paper boat: a folded hull and a triangular sail standing out of it.
            let white = linearRGBA(PaperColor(0.97, 0.96, 0.92))
            let hullTop: Float = 0.22
            let bow = SIMD3<Float>(0.5, hullTop + 0.08, 0), stern = SIMD3<Float>(-0.5, hullTop + 0.08, 0)
            let keelFront = SIMD3<Float>(0.28, 0, 0), keelBack = SIMD3<Float>(-0.28, 0, 0)
            let side: Float = 0.2
            for s: Float in [-1, 1] {
                mesh.quad(keelBack, keelFront, SIMD3(0.3, hullTop, side * s), SIMD3(-0.3, hullTop, side * s), color: white)
                mesh.triangle(keelFront, bow, SIMD3(0.3, hullTop, side * s), color: white)
                mesh.triangle(keelBack, SIMD3(-0.3, hullTop, side * s), stern, color: white)
            }
            mesh.triangle(SIMD3(-0.22, hullTop, 0), SIMD3(0.22, hullTop, 0), SIMD3(0, 0.75, 0), color: white)
            materials = [vertexColored()]
        }
        let node = SCNNode(geometry: mesh.geometry(materials: materials))
        return based(node)
    }

    // MARK: Fire

    /// An origami fire: folded paper tongues, each its own `flame_<n>` child with its origin at
    /// its base so it can be flickered by scaling, as the Blender one is.
    static func fire() -> ModelTemplate {
        let root = SCNNode()
        let colors = [PaperColor(1.0, 0.80, 0.20), PaperColor(0.99, 0.55, 0.12), PaperColor(0.93, 0.28, 0.12),
                      PaperColor(1.0, 0.68, 0.16), PaperColor(0.98, 0.42, 0.12), PaperColor(1.0, 0.86, 0.3),
                      PaperColor(0.95, 0.35, 0.1)]
        // A tall centre tongue and a ring leaning outward. Seen from straight above, a ring of
        // upright cones is a dot; leaning them out is what makes the fire a star of flames.
        let placements: [(angle: Float, reach: Float, height: Float, radius: Float)] = [
            (0, 0, 1.0, 0.2), (0.3, 0.17, 0.75, 0.15), (1.2, 0.2, 0.62, 0.14), (2.2, 0.16, 0.8, 0.15),
            (3.1, 0.2, 0.6, 0.13), (4.1, 0.17, 0.72, 0.15), (5.2, 0.2, 0.66, 0.14)]
        for (index, place) in placements.enumerated() {
            var mesh = FacetMesh()
            addCone(&mesh, sides: 4, radius: place.radius, bottom: 0, apex: place.height, color: nil, twist: Float(index))
            let flame = SCNNode(geometry: mesh.geometry(materials: [paperMaterial(colors[index], glow: 0.8)]))
            flame.name = "flame_\(index)"
            let radial = SIMD3<Float>(cos(place.angle), 0, sin(place.angle))
            flame.simdPosition = radial * place.reach
            if place.reach > 0 {
                flame.simdOrientation = simd_quatf(angle: 0.55, axis: simd_normalize(SIMD3(radial.z, 0, -radial.x)))
            }
            flame.castsShadow = false
            root.addChildNode(flame)
        }
        return ModelTemplate(node: root, extent: SIMD3(0.9, 1, 0.9), sheetAspect: 1, isStandIn: true)
    }

    // MARK: Builders

    private static func vertexColored() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = NSColor.white
        return material
    }

    private static func centered(_ node: SCNNode, sheetAspect: Float) -> ModelTemplate {
        let holder = SCNNode()
        holder.addChildNode(node)
        let (lo, hi) = OrigamiLibrary.bounds(of: holder) ?? (SIMD3(repeating: -0.5), SIMD3(repeating: 0.5))
        node.simdPosition -= (lo + hi) / 2
        return ModelTemplate(node: holder, extent: hi - lo, sheetAspect: sheetAspect, isStandIn: true)
    }

    private static func based(_ node: SCNNode) -> ModelTemplate {
        let holder = SCNNode()
        holder.addChildNode(node)
        let (lo, hi) = OrigamiLibrary.bounds(of: holder) ?? (SIMD3(repeating: -0.5), SIMD3(repeating: 0.5))
        node.simdPosition -= SIMD3((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        return ModelTemplate(node: holder, extent: hi - lo, sheetAspect: 1, isStandIn: true)
    }

    static func icosphere(radius: Float, crumple: Float, seed: UInt64, material: SCNMaterial) -> SCNGeometry {
        var mesh = FacetMesh()
        addIcosphere(&mesh, center: .zero, radius: radius, subdivisions: 1, crumple: crumple, seed: seed)
        return mesh.geometry(materials: [material])
    }

    /// A faceted ball with its vertices pushed in and out a little — crumpled rather than cut.
    static func addIcosphere(_ mesh: inout FacetMesh, center: SIMD3<Float>, radius: Float, subdivisions: Int,
                             crumple: Float, seed: UInt64, color: SIMD4<Float>? = nil, squash: Float = 1) {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var vertices: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
            [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map { simd_normalize($0) }
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
            (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
            (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        for _ in 0..<subdivisions {
            var midpoints: [Int: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let key = min(a, b) * 1000 + max(a, b)
                if let found = midpoints[key] { return found }
                vertices.append(simd_normalize((vertices[a] + vertices[b]) / 2))
                midpoints[key] = vertices.count - 1
                return vertices.count - 1
            }
            faces = faces.flatMap { a, b, c -> [(Int, Int, Int)] in
                let ab = mid(a, b), bc = mid(b, c), ca = mid(c, a)
                return [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
        }
        var rand = Rand(seed: seed &+ 0x1C0)
        let pushed = vertices.map { v -> SIMD3<Float> in
            let r = radius * (1 + rand.inRange(-crumple, crumple))
            return center + SIMD3(v.x, v.y * squash, v.z) * r
        }
        for (a, b, c) in faces {
            let uv = { (v: SIMD3<Float>) in SIMD2(0.5 + atan2(v.z, v.x) / (2 * .pi), 0.5 - v.y / (2 * radius)) }
            mesh.triangle(pushed[a], pushed[b], pushed[c],
                          uv: (uv(pushed[a] - center), uv(pushed[b] - center), uv(pushed[c] - center)), color: color)
        }
    }

    static func addCone(_ mesh: inout FacetMesh, sides: Int, radius: Float, bottom: Float, apex: Float,
                        color: SIMD4<Float>?, twist: Float = 0) {
        let top = SIMD3<Float>(0, apex, 0)
        for k in 0..<sides {
            let a0 = Float(k) / Float(sides) * 2 * .pi + twist, a1 = Float(k + 1) / Float(sides) * 2 * .pi + twist
            let p0 = SIMD3(cos(a0) * radius, bottom, sin(a0) * radius)
            let p1 = SIMD3(cos(a1) * radius, bottom, sin(a1) * radius)
            mesh.triangle(p1, p0, top, color: color)
            mesh.triangle(p0, p1, SIMD3(0, bottom, 0), color: color)
        }
    }

    private static func addPrism(_ mesh: inout FacetMesh, sides: Int, radius: Float, bottom: Float, top: Float,
                                 color: SIMD4<Float>?) {
        for k in 0..<sides {
            let a0 = Float(k) / Float(sides) * 2 * .pi, a1 = Float(k + 1) / Float(sides) * 2 * .pi
            let b0 = SIMD3(cos(a0) * radius, bottom, sin(a0) * radius), b1 = SIMD3(cos(a1) * radius, bottom, sin(a1) * radius)
            mesh.quad(b1, b0, SIMD3(b0.x, top, b0.z), SIMD3(b1.x, top, b1.z), color: color)
        }
    }

    static func addBox(_ mesh: inout FacetMesh, min lo: SIMD3<Float>, max hi: SIMD3<Float>,
                       bevelTop: Float = 0, color: SIMD4<Float>? = nil) {
        // A bevel pulls the top face's front edge back, for the eraser's worn wedge.
        let front = hi.x - (hi.x - lo.x) * bevelTop
        let c = [SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z),
                 SIMD3(lo.x, hi.y, lo.z), SIMD3(front, hi.y, lo.z), SIMD3(front, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z)]
        mesh.quad(c[0], c[1], c[2], c[3], color: color)     // bottom
        mesh.quad(c[4], c[7], c[6], c[5], color: color)     // top
        mesh.quad(c[0], c[4], c[5], c[1], color: color)     // -z
        mesh.quad(c[3], c[2], c[6], c[7], color: color)     // +z
        mesh.quad(c[0], c[3], c[7], c[4], color: color)     // -x
        mesh.quad(c[1], c[5], c[6], c[2], color: color)     // +x
    }

    private static func addGable(_ mesh: inout FacetMesh, width: Float, depth: Float, eave: Float, ridge: Float,
                                 color: SIMD4<Float>) {
        let hx = width / 2, hz = depth / 2
        let r0 = SIMD3<Float>(-hx, ridge, 0), r1 = SIMD3<Float>(hx, ridge, 0)
        mesh.quad(SIMD3(-hx, eave, hz), SIMD3(hx, eave, hz), r1, r0, color: color)
        mesh.quad(SIMD3(hx, eave, -hz), SIMD3(-hx, eave, -hz), r0, r1, color: color)
        mesh.triangle(SIMD3(-hx, eave, -hz), SIMD3(-hx, eave, hz), r0, color: color)
        mesh.triangle(SIMD3(hx, eave, hz), SIMD3(hx, eave, -hz), r1, color: color)
    }
}
