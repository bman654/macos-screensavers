// Glow-in-the-dark paint: what keeps the fight readable once the light has gone.
//
// Every plane and tank is painted with swirls of luminous paint in its side's colour over its
// ordinary paper. By day the paint is invisible — it is emission only, and its strength is zero —
// and from evening into night it comes up while the paper around it, lit by almost nothing,
// sinks to a dark grey. Self-light only: the paint glows, it lights nothing else. The shots carry
// glowing bits of their own (`ProjectileField`), the crate a luminous star, and the wingtips a
// red and a green dot of paint, port and starboard.
//
// One knob, `level`, from `DayLight`; everything that glows registers its material here with the
// strength it glows at when the knob is full, and the knob turns them all.
//
// The swirl sheets are pictures, like the paper sheets they lie over, so they are drawn into an
// explicitly sRGB `CGContext` and handed over as a `CGImage` carrying that tag (`PaperTextures`).

import AppKit
import CoreGraphics
import Foundation
import SceneKit
import simd

final class GlowPaint {
    /// 0 by day, 1 at night.
    private(set) var level: Float = 0
    /// How much of their own colour the unlit effects keep — smoke, dust, paper scraps — which
    /// would otherwise stay daylight-bright on a dark landscape. 1 by day.
    private(set) var ambient: Float = 1
    private var materials: [(material: SCNMaterial, strength: Float)] = []
    private var sheets: [String: CGImage] = [:]
    /// Nodes that exist only to glow — a wingtip's dot, a shot's fleck — hidden while it is day.
    private let glowOnly = NSHashTable<SCNNode>.weakObjects()

    /// Below this the paint is off outright, so a midday frame is exactly what it was before
    /// there was paint.
    static let threshold: Float = 0.01

    var isLit: Bool { level > GlowPaint.threshold }

    func set(level: Float, ambient: Float) {
        self.ambient = ambient
        guard abs(level - self.level) > 0.0005 else { return }
        let wasLit = isLit
        self.level = level
        for entry in materials { entry.material.emission.intensity = CGFloat(isLit ? level * entry.strength : 0) }
        if wasLit != isLit { for node in glowOnly.allObjects { node.isHidden = !isLit } }
    }

    /// `material` glows with whatever its emission holds, at `strength` when the knob is full.
    func register(_ material: SCNMaterial, strength: Float) {
        material.emission.intensity = CGFloat(isLit ? level * strength : 0)
        materials.append((material, strength))
    }

    /// A node that is nothing but glow, shown only while the paint is lit.
    func glowOnly(_ node: SCNNode) {
        node.isHidden = !isLit
        glowOnly.add(node)
    }

    // MARK: Colours

    /// The colour a paper's paint glows. A team's paper is plain and its paint is its own hue,
    /// pushed to the luminous end — the teams' four (red, blue, yellow, violet) stay four apart
    /// in the dark. Printed papers glow the colour of their ink or rules, and newspaper the
    /// classic phosphor green, so a free-for-all is a scatter of distinct colours.
    static func colour(for paper: Paper) -> PaperColor {
        switch paper.kind {
        case .notebook: return PaperColor(0.42, 0.70, 1.0)
        case .graph: return PaperColor(0.30, 1.0, 0.82)
        case .newspaper: return PaperColor(0.55, 1.0, 0.30)
        case .kraft: return PaperColor(1.0, 0.66, 0.22)
        case .plain:
            let luminous = [
                PaperColor(1.0, 0.24, 0.28),   // red
                PaperColor(0.24, 0.62, 1.0),   // blue
                PaperColor(1.0, 0.94, 0.20),   // yellow
                PaperColor(0.86, 0.36, 1.0),   // violet
                PaperColor(1.0, 0.56, 0.12),   // orange
                PaperColor(0.10, 1.0, 0.90),   // teal
                PaperColor(1.0, 0.42, 0.80),   // pink
                PaperColor(0.62, 1.0, 0.28),   // charcoal, in glow-green
            ]
            return luminous[paper.tint % luminous.count]
        }
    }

    static func linear(_ c: PaperColor) -> SIMD3<Float> {
        let l = linearRGBA(c)
        return SIMD3(l.x, l.y, l.z)
    }

    // MARK: The paint

    /// Glows `material` — a vehicle's paper — with the swirl sheet for `paper`, through the same
    /// sheet coordinates its paper uses.
    func paint(_ material: SCNMaterial, paper: Paper, aspect: CGFloat, seed: UInt64) {
        let key = "\(paper.kind.rawValue)-\(paper.tint)-\(Int(aspect * 100))"
        let sheet = sheets[key] ?? GlowPaint.swirls(colour: GlowPaint.colour(for: paper), aspect: aspect,
                                                    seed: seed ^ UInt64(paper.kind.rawValue * 577 + paper.tint * 97))
        sheets[key] = sheet
        guard let sheet else { return }
        material.emission.contents = sheet
        material.emission.mipFilter = .linear
        material.emission.maxAnisotropy = 8
        register(material, strength: 1)
    }

    /// Swirls and camouflage blots of luminous paint on black, and a thin rim of it round the
    /// sheet's edge, which folds out to the plane's outline — so even a plane that shows only
    /// its plain side still draws its shape in the dark. About a third of the sheet is paint:
    /// less and a small plane showed one stray squiggle; more and it was a plain glowing shape,
    /// its paper gone.
    static func swirls(colour: PaperColor, aspect: CGFloat, width: Int = 256, seed: UInt64) -> CGImage? {
        let height = max(Int(CGFloat(width) * aspect), 8)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var rand = Rand(seed: seed ^ 0x6_10_57)
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Swirls: brush strokes that wander and curl, each a run of short arcs whose turn drifts.
        for _ in 0..<7 {
            var p = CGPoint(x: CGFloat(rand.next()) * w, y: CGFloat(rand.next()) * h)
            var heading = CGFloat(rand.inRange(0, 2 * .pi))
            var turn = CGFloat(rand.inRange(-0.5, 0.5))
            let path = CGMutablePath()
            path.move(to: p)
            for _ in 0..<26 {
                turn += CGFloat(rand.inRange(-0.18, 0.18))
                turn = min(max(turn, -0.55), 0.55)
                heading += turn
                p = CGPoint(x: p.x + cos(heading) * w * 0.035, y: p.y + sin(heading) * w * 0.035)
                path.addLine(to: p)
            }
            ctx.addPath(path)
            ctx.setStrokeColor(colour.cg)
            ctx.setLineWidth(w * CGFloat(rand.inRange(0.035, 0.065)))
            ctx.strokePath()
        }
        // Blots: the camouflage between the swirls, in a deeper shade of the same paint.
        let deep = colour.scaled(0.72)
        for _ in 0..<9 {
            let c = CGPoint(x: CGFloat(rand.next()) * w, y: CGFloat(rand.next()) * h)
            let r = w * CGFloat(rand.inRange(0.04, 0.09))
            ctx.setFillColor(deep.cg)
            for _ in 0..<4 {
                let dx = CGFloat(rand.inRange(-0.7, 0.7)) * r, dy = CGFloat(rand.inRange(-0.7, 0.7)) * r
                let rr = r * CGFloat(rand.inRange(0.5, 0.9))
                ctx.fillEllipse(in: CGRect(x: c.x + dx - rr, y: c.y + dy - rr, width: rr * 2, height: rr * 2))
            }
        }
        ctx.setStrokeColor(colour.cg)
        ctx.setLineWidth(w * 0.05)
        ctx.stroke(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Dots

    /// A round dot of luminous paint, `colour`, soft at its rim: a wingtip's navigation light, a
    /// shot's LED or fleck. Constant-lit — it is all glow — and faded with the knob.
    func dotMaterial(_ colour: PaperColor, strength: Float = 1) -> SCNMaterial {
        let material = GlowPaint.dotMaterial(colour)
        register(material, strength: strength)
        return material
    }

    /// The same dot, at full strength and on no knob — for a lamp that is switched, not charged.
    static func dotMaterial(_ colour: PaperColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black
        material.emission.contents = GlowPaint.dotImage(colour)
        // Alpha-blended through a round mask, never added: scene fog tints every fragment, and an
        // additive square's black corners fogged come out as a pale square (`Lamplight`).
        material.transparent.contents = GlowPaint.dotMask
        material.transparencyMode = .aOne
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }

    private static let dotMask: CGImage? = {
        let size = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = CGFloat(size), c = CGPoint(x: s / 2, y: s / 2)
        let colours = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                       CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        }
        return ctx.makeImage()
    }()

    private static func dotImage(_ colour: PaperColor, size: Int = 32) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = CGFloat(size), c = CGPoint(x: s / 2, y: s / 2)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let colours = [colour.cg, colour.cg, colour.scaled(0.45).cg,
                       CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 0.45, 0.75, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        }
        return ctx.makeImage()
    }

    /// A flat round dot node `diameter` across, facing +Y, glowing `material`.
    static func dot(_ material: SCNMaterial, diameter: Float) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(diameter), height: CGFloat(diameter))
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        node.castsShadow = false
        node.renderingOrder = 6
        return node
    }
}
