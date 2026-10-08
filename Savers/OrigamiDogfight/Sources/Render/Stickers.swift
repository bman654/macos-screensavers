// What an ace's stickers look like, and where on a plane or tank they go.
//
// The art is CoreGraphics, drawn once into sRGB images — pictures, so SceneKit decodes them back
// to what was drawn (`docs/next-session.md`, traps: colour management of generated images) — and
// the same drawing goes onto the scoreboard card. Each is a die-cut sticker: the shape on a white
// border, the way a sheet of reward stickers looks, which is also what lets a gold star read
// against a yellow plane.
//
// On a model a sticker is a small decal quad lying on the top surface, found once per model by
// looking down on its triangles for flat patches clear of its edges — the wings of a plane, the
// deck of a tank. A model's own geometry decides, so a stand-in and a Blender model get stickers
// the same way, and a new plane type needs no table of wing positions.

import AppKit
import CoreGraphics
import Foundation
import SceneKit
import simd

enum StickerArt {
    /// Draws `sticker` filling `rect` in `ctx`, which may be flipped either way: every shape is
    /// symmetric left to right, and the two that are not up-down symmetric are drawn through
    /// `up`, the direction of the sticker's top in the context's own coordinates.
    static func draw(_ sticker: Sticker, in ctx: CGContext, rect r: CGRect, up: CGFloat = 1) {
        let c = CGPoint(x: r.midX, y: r.midY)
        let s = min(r.width, r.height) / 2
        let shape: CGPath
        switch sticker {
        case .silverStar, .goldStar: shape = star(center: c, radius: s * 0.86, up: up)
        case .smiley: shape = CGPath(ellipseIn: CGRect(x: c.x - s * 0.8, y: c.y - s * 0.8, width: s * 1.6, height: s * 1.6),
                                     transform: nil)
        case .heart: shape = heart(center: c, size: s * 0.82, up: up)
        case .rainbow: shape = rainbowBand(center: c, size: s, up: up)
        }

        // The die-cut border: the shape stroked wide in white, with a shadow so the sticker
        // stands a hair proud of the paper. Wide on purpose — a gold star on a yellow plane is
        // otherwise a thin outline, and the border is what says "sticker" on any paper.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: s * 0.03, height: -s * 0.05 * up), blur: s * 0.08,
                      color: CGColor(srgbRed: 0.1, green: 0.08, blue: 0.05, alpha: 0.5))
        ctx.addPath(shape)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(s * 0.32)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 0.98, alpha: 1))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0.98, alpha: 1))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        switch sticker {
        case .goldStar:
            fill(ctx, shape, CGColor(srgbRed: 0.99, green: 0.80, blue: 0.16, alpha: 1),
                 edge: CGColor(srgbRed: 0.80, green: 0.52, blue: 0.06, alpha: 1), s: s)
            fill(ctx, star(center: CGPoint(x: c.x, y: c.y + s * 0.05 * up), radius: s * 0.4, up: up),
                 CGColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1), edge: nil, s: s)
        case .silverStar:
            fill(ctx, shape, CGColor(srgbRed: 0.80, green: 0.82, blue: 0.87, alpha: 1),
                 edge: CGColor(srgbRed: 0.52, green: 0.54, blue: 0.62, alpha: 1), s: s)
            fill(ctx, star(center: CGPoint(x: c.x, y: c.y + s * 0.05 * up), radius: s * 0.4, up: up),
                 CGColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1), edge: nil, s: s)
        case .smiley:
            fill(ctx, shape, CGColor(srgbRed: 1.0, green: 0.84, blue: 0.18, alpha: 1),
                 edge: CGColor(srgbRed: 0.85, green: 0.6, blue: 0.08, alpha: 1), s: s)
            let ink = CGColor(srgbRed: 0.24, green: 0.16, blue: 0.08, alpha: 1)
            ctx.setFillColor(ink)
            for dx in [-0.27, 0.27] as [CGFloat] {
                ctx.fillEllipse(in: CGRect(x: c.x + dx * s - s * 0.09, y: c.y + 0.2 * s * up - s * 0.13,
                                           width: s * 0.18, height: s * 0.26))
            }
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(s * 0.1)
            ctx.setLineCap(.round)
            ctx.beginPath()
            // The smile: the lower arc of a circle, whichever way up the context is.
            ctx.addArc(center: CGPoint(x: c.x, y: c.y + 0.05 * s * up), radius: s * 0.42,
                       startAngle: up > 0 ? .pi * 1.18 : .pi * 0.18, endAngle: up > 0 ? .pi * 1.82 : .pi * 0.82,
                       clockwise: false)
            ctx.strokePath()
        case .heart:
            fill(ctx, shape, CGColor(srgbRed: 0.93, green: 0.22, blue: 0.36, alpha: 1),
                 edge: CGColor(srgbRed: 0.68, green: 0.10, blue: 0.22, alpha: 1), s: s)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.72, blue: 0.78, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: c.x - s * 0.42, y: c.y + s * 0.12 * up - s * 0.1, width: s * 0.22, height: s * 0.2))
        case .rainbow:
            let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.92, 0.22, 0.2), (0.98, 0.56, 0.12), (0.99, 0.84, 0.18),
                                                          (0.30, 0.70, 0.30), (0.22, 0.46, 0.86), (0.52, 0.32, 0.76)]
            let base = CGPoint(x: c.x, y: c.y - s * 0.32 * up)
            for (index, colour) in colours.enumerated() {
                let outer = s * (0.86 - CGFloat(index) * 0.1)
                ctx.setStrokeColor(CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 1))
                ctx.setLineWidth(s * 0.1)
                ctx.setLineCap(.butt)
                ctx.beginPath()
                ctx.addArc(center: base, radius: outer - s * 0.05, startAngle: 0, endAngle: .pi, clockwise: up < 0)
                ctx.strokePath()
            }
            // Clouds at its feet.
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            for dx in [-0.62, 0.62] as [CGFloat] {
                for (ox, oy, rr) in [(-0.13, 0.0, 0.16), (0.1, 0.03, 0.19), (0.0, 0.12, 0.15)] as [(CGFloat, CGFloat, CGFloat)] {
                    ctx.fillEllipse(in: CGRect(x: c.x + (dx + ox) * s - rr * s, y: base.y + oy * s * up - rr * s,
                                               width: rr * 2 * s, height: rr * 2 * s))
                }
            }
        }
    }

    private static func fill(_ ctx: CGContext, _ path: CGPath, _ colour: CGColor, edge: CGColor?, s: CGFloat) {
        ctx.addPath(path)
        ctx.setFillColor(colour)
        ctx.fillPath()
        guard let edge else { return }
        ctx.addPath(path)
        ctx.setStrokeColor(edge)
        ctx.setLineWidth(s * 0.05)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    private static func star(center c: CGPoint, radius: CGFloat, up: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for k in 0..<10 {
            let r = k % 2 == 0 ? radius : radius * 0.45
            let a = CGFloat.pi / 2 + CGFloat(k) * .pi / 5
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r * up)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private static func heart(center c: CGPoint, size s: CGFloat, up: CGFloat) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s * up) }
        path.move(to: p(0, -0.9))
        path.addCurve(to: p(-1, 0.25), control1: p(-0.3, -0.55), control2: p(-1, -0.3))
        path.addCurve(to: p(0, 0.55), control1: p(-1, 0.95), control2: p(-0.15, 0.95))
        path.addCurve(to: p(1, 0.25), control1: p(0.15, 0.95), control2: p(1, 0.95))
        path.addCurve(to: p(0, -0.9), control1: p(1, -0.3), control2: p(0.3, -0.55))
        path.closeSubpath()
        return path
    }

    /// The rainbow's die-cut outline: a half disc over its clouds.
    private static func rainbowBand(center c: CGPoint, size s: CGFloat, up: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let base = CGPoint(x: c.x, y: c.y - s * 0.32 * up)
        path.addArc(center: base, radius: s * 0.86, startAngle: 0, endAngle: .pi, clockwise: up < 0)
        path.addLine(to: CGPoint(x: base.x - s * 0.86, y: base.y - s * 0.22 * up))
        path.addLine(to: CGPoint(x: base.x + s * 0.86, y: base.y - s * 0.22 * up))
        path.closeSubpath()
        return path
    }

    /// One sticker as a square image with a clear background, for a decal.
    static func image(_ sticker: Sticker, size: Int = 128) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let inset = CGFloat(size) * 0.13
        draw(sticker, in: ctx, rect: CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset))
        return ctx.makeImage()
    }
}

/// The decal materials, one per sticker, shared by every vehicle that wears one.
final class StickerMaterials {
    private var cache: [Sticker: SCNMaterial] = [:]

    func material(_ sticker: Sticker) -> SCNMaterial {
        if let hit = cache[sticker] { return hit }
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = StickerArt.image(sticker) ?? NSColor.white
        material.diffuse.mipFilter = .linear
        material.transparencyMode = .aOne
        // Lies a hair above the paper it is stuck to and is drawn after it; writing depth would
        // only let one sticker's clear corner cut a hole in the wing beside it.
        material.writesToDepthBuffer = false
        material.isDoubleSided = false
        cache[sticker] = material
        return material
    }
}

/// Where a model's stickers go: flat patches of its top surface, in the template's own space.
struct StickerSpot {
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    /// The sticker's diameter there.
    let size: Float
}

enum StickerSpots {
    /// Up to three spots on `template`'s upper surface: one each side of its centre line and a
    /// third behind the first — a plane's two wings and then the first wing again, a tank's deck
    /// either side of the turret. `exclude` names nodes whose triangles are not surface for a
    /// sticker, such as a tank's turret, which turns.
    static func spots(on template: ModelTemplate, exclude: Set<String> = []) -> [StickerSpot] {
        let triangles = topTriangles(of: template.node, exclude: exclude)
        guard !triangles.isEmpty else { return [] }
        let length = template.extent.x, width = template.extent.z
        let reference = max(length, width)
        var chosen: [StickerSpot] = []
        for slot in 0..<3 {
            var best: (spot: StickerSpot, score: Float)?
            // As big as will fit: from overhead a plane is a few dozen points long, and a
            // sticker much under a third of it is a speck.
            for diameter in [0.32, 0.26, 0.2, 0.15].map({ $0 * reference }) {
                let r = diameter / 2
                for ix in 0..<24 {
                    for iz in 0..<16 {
                        let x = -length / 2 + length * (Float(ix) + 0.5) / 24
                        let z = -width / 2 + width * (Float(iz) + 0.5) / 16
                        // Right of the centre line first, then left, then right again further aft —
                        // clear of the keel's fold down the middle.
                        let clear = r * 0.6
                        guard slot == 1 ? z < -clear : z > clear else { continue }
                        guard let hit = surface(at: SIMD2(x, z), in: triangles) else { continue }
                        guard hit.normal.y > 0.55 else { continue }
                        // The whole disc on one flat facet's worth of surface: on the wing, not
                        // hanging off its edge or bent across a fold. Measured against the plane
                        // through the hit along its normal, so a wing with dihedral still counts.
                        let n = hit.normal
                        let fits = (0..<8).allSatisfy { k in
                            let a = Float(k) * .pi / 4
                            let dx = cos(a) * r, dz = sin(a) * r
                            guard let rim = surface(at: SIMD2(x + dx, z + dz), in: triangles) else { return false }
                            let expected = hit.height - (n.x * dx + n.z * dz) / n.y
                            return abs(rim.height - expected) < r * 0.25
                        }
                        guard fits else { continue }
                        let point = SIMD3(x, hit.height, z)
                        guard chosen.allSatisfy({ simd_distance($0.position, point) > ($0.size / 2 + r) * 1.05 }) else { continue }
                        // Out along the wing and near the middle of its chord; a slot after the
                        // first two prefers the back of the plane.
                        var score = abs(z) / max(width / 2, 1e-4) - abs(x) / max(length, 1e-4) * 0.6 + diameter / reference
                        if slot == 2 { score -= x / max(length, 1e-4) }
                        if best.map({ score > $0.score }) ?? true {
                            best = (StickerSpot(position: point, normal: hit.normal, size: diameter), score)
                        }
                    }
                }
                if best != nil { break }
            }
            if let best { chosen.append(best.spot) }
        }
        return chosen
    }

    struct Triangle {
        let a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>
        let normal: SIMD3<Float>
        /// Its footprint's box, so most triangles are passed over without the barycentric test.
        let lo: SIMD2<Float>, hi: SIMD2<Float>

        init(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, normal: SIMD3<Float>) {
            self.a = a; self.b = b; self.c = c
            self.normal = normal
            lo = SIMD2(min(a.x, b.x, c.x), min(a.z, b.z, c.z))
            hi = SIMD2(max(a.x, b.x, c.x), max(a.z, b.z, c.z))
        }
    }

    /// The highest triangle over a point of the footprint, seen from above.
    private static func surface(at p: SIMD2<Float>, in triangles: [Triangle]) -> (height: Float, normal: SIMD3<Float>)? {
        var best: (Float, SIMD3<Float>)?
        for t in triangles where p.x >= t.lo.x && p.x <= t.hi.x && p.y >= t.lo.y && p.y <= t.hi.y {
            let a = SIMD2(t.a.x, t.a.z), b = SIMD2(t.b.x, t.b.z), c = SIMD2(t.c.x, t.c.z)
            let v0 = b - a, v1 = c - a, v2 = p - a
            let d = v0.x * v1.y - v1.x * v0.y
            guard abs(d) > 1e-12 else { continue }
            let u = (v2.x * v1.y - v1.x * v2.y) / d
            let v = (v0.x * v2.y - v2.x * v0.y) / d
            guard u >= 0, v >= 0, u + v <= 1 else { continue }
            let height = t.a.y + u * (t.b.y - t.a.y) + v * (t.c.y - t.a.y)
            if best.map({ height > $0.0 }) ?? true { best = (height, t.normal) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Every triangle under `root`, in its space, facing up — a folded sheet is double-sided, so
    /// a face's winding says nothing and its normal is turned to point up. Also what a plane's
    /// shadow is cut from (`PlaneShadows`).
    static func topTriangles(of root: SCNNode, exclude: Set<String>) -> [Triangle] {
        var triangles: [Triangle] = []
        var skipped = Set<ObjectIdentifier>()
        root.enumerateHierarchy { node, _ in
            if let name = node.name, exclude.contains(name) {
                node.enumerateHierarchy { child, _ in skipped.insert(ObjectIdentifier(child)) }
            }
        }
        root.enumerateHierarchy { node, _ in
            guard !skipped.contains(ObjectIdentifier(node)), let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first,
                  source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3
            else { return }
            let transform = root.simdConvertTransform(matrix_identity_float4x4, from: node)
            var vertices: [SIMD3<Float>] = []
            vertices.reserveCapacity(source.vectorCount)
            source.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for index in 0..<source.vectorCount {
                    let offset = source.dataOffset + index * source.dataStride
                    guard offset + 12 <= raw.count else { break }
                    let v = SIMD3(raw.loadUnaligned(fromByteOffset: offset, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
                    let p = transform * SIMD4(v, 1)
                    vertices.append(SIMD3(p.x, p.y, p.z))
                }
            }
            for element in geometry.elements {
                for (i, j, k) in indexTriples(element) where i < vertices.count && j < vertices.count && k < vertices.count {
                    let a = vertices[i], b = vertices[j], c = vertices[k]
                    var n = simd_cross(b - a, c - a)
                    let length = simd_length(n)
                    guard length > 1e-12 else { continue }
                    n /= length
                    if n.y < 0 { n = -n }
                    triangles.append(Triangle(a: a, b: b, c: c, normal: n))
                }
            }
        }
        return triangles
    }

    /// An element's triangles as vertex-index triples: triangles as they are, polygons as fans.
    /// Anything else — lines, points — has no surface to stick to.
    ///
    /// An imported element may interleave several index channels per corner — position, normal
    /// and texture coordinate each indexed separately, measured as three for the library's
    /// planes — and only the first is the position's. The channel count is not taken on trust
    /// from a property newer systems have; it is what the data's size says it must be.
    private static func indexTriples(_ element: SCNGeometryElement) -> [(Int, Int, Int)] {
        let size = element.bytesPerIndex
        let data = element.data
        func index(_ k: Int) -> Int {
            data.withUnsafeBytes { raw -> Int in
                switch size {
                case 1: return Int(raw.load(fromByteOffset: k, as: UInt8.self))
                case 2: return Int(raw.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self))
                default: return Int(raw.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self))
                }
            }
        }
        let available = data.count / max(size, 1)
        let primitives = element.primitiveCount
        var out: [(Int, Int, Int)] = []
        switch element.primitiveType {
        case .triangles:
            let channels = max(available / max(primitives * 3, 1), 1)
            func corner(_ k: Int) -> Int { index(k * channels) }
            for t in 0..<primitives where (t * 3 + 2) * channels < available {
                out.append((corner(t * 3), corner(t * 3 + 1), corner(t * 3 + 2)))
            }
        case .polygon:
            // The polygon counts come first, then every polygon's corners in turn.
            guard primitives < available else { break }
            let counts = (0..<primitives).map(index)
            let corners = counts.reduce(0, +)
            guard corners > 0 else { break }
            let channels = max((available - primitives) / corners, 1)
            func corner(_ k: Int) -> Int { index(primitives + k * channels) }
            var cursor = 0
            for count in counts {
                guard count >= 3, primitives + (cursor + count) * channels <= available else { break }
                for k in 1..<(count - 1) { out.append((corner(cursor), corner(cursor + k), corner(cursor + k + 1))) }
                cursor += count
            }
        default:
            break
        }
        return out
    }

    /// A decal for `sticker` at `spot`, in the template's space, lifted a hair off the surface.
    static func decal(_ sticker: Sticker, at spot: StickerSpot, materials: StickerMaterials) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(spot.size), height: CGFloat(spot.size))
        plane.materials = [materials.material(sticker)]
        let node = SCNNode(geometry: plane)
        // An `SCNPlane` faces +Z; lay it on the surface, its top toward the model's nose so a
        // star stands the right way up to a plane flying up the screen.
        let lay = simd_quatf(from: SIMD3(0, 0, 1), to: spot.normal)
        let up = lay.act(SIMD3(0, 1, 0))
        let nose = simd_normalize(SIMD3<Float>(1, 0, 0) - spot.normal * spot.normal.x)
        let twist = atan2(simd_dot(simd_cross(up, nose), spot.normal), simd_dot(up, nose))
        node.simdOrientation = simd_quatf(angle: twist, axis: spot.normal) * lay
        node.simdPosition = spot.position + spot.normal * spot.size * 0.04
        node.castsShadow = false
        node.renderingOrder = 5
        return node
    }
}
