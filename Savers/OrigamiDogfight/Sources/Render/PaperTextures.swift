// The sheets the planes are folded from, drawn at runtime with CoreGraphics.
//
// A plane model's UVs are its unfolded sheet's own flat coordinates (u across the width, v along
// the length — `docs/origami-plan.md` §Asset contract), so a sheet drawn here lands on the
// folded plane with its rules running across the folds the way a real folded sheet's would.
//
// **Colour management.** SceneKit decodes a generated image through the curve its own tag names
// (`docs/next-session.md`, traps): sRGB-tagged arrives as authored, and `NSImage.lockFocus` gives
// a calibrated-space image that measured as gamma 1.8. These are pictures, not data, so they are
// drawn into an explicitly sRGB `CGContext` and handed over as a `CGImage` carrying that tag.

import AppKit
import CoreGraphics
import Foundation
import SceneKit

/// An sRGB colour as authored, before SceneKit linearises it.
struct PaperColor {
    let r: CGFloat, g: CGFloat, b: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    func scaled(_ k: CGFloat) -> PaperColor {
        PaperColor(min(r * k, 1), min(g * k, 1), min(b * k, 1))
    }
}

enum PaperPalette {
    /// Plain origami colours. The first four are the team colours (`TeamColours`), chosen to
    /// stay distinct from one another and from the green landscape under them.
    static let plain: [PaperColor] = [
        PaperColor(0.88, 0.20, 0.18),   // red
        PaperColor(0.18, 0.42, 0.86),   // blue
        PaperColor(0.99, 0.80, 0.16),   // yellow
        PaperColor(0.66, 0.30, 0.78),   // violet — not green: a green team vanishes over meadow
        PaperColor(0.98, 0.52, 0.14),   // orange
        PaperColor(0.10, 0.70, 0.72),   // teal
        PaperColor(0.98, 0.55, 0.72),   // pink
        PaperColor(0.30, 0.30, 0.36),   // charcoal
    ]

    /// The colour that reads as "this plane" — what confetti from a hit is cut from.
    static func base(_ paper: Paper) -> PaperColor {
        switch paper.kind {
        case .notebook: return PaperColor(0.96, 0.95, 0.90)
        case .graph: return PaperColor(0.93, 0.96, 0.96)
        case .newspaper: return PaperColor(0.86, 0.85, 0.80)
        case .kraft: return PaperColor(0.72, 0.55, 0.36)
        case .plain: return plain[paper.tint % plain.count]
        }
    }
}

enum PaperTextures {
    /// A plane's sheet, `width` pixels across and `width * aspect` long. Nil only if CoreGraphics
    /// cannot make a context, in which case the material falls back to the paper's flat colour.
    static func sheet(_ paper: Paper, aspect: CGFloat, width: Int = 512, seed: UInt64) -> CGImage? {
        let height = max(Int(CGFloat(width) * aspect), 8)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var rand = Rand(seed: seed ^ UInt64(paper.kind.rawValue * 977 + paper.tint * 131))
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(PaperPalette.base(paper).cg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        switch paper.kind {
        case .notebook:
            // Pale blue rules across the sheet, a red margin down it, and the three punched holes.
            ctx.setStrokeColor(PaperColor(0.52, 0.68, 0.90).cg)
            ctx.setLineWidth(w / 220)
            let ruling = h / 30
            var y = h - ruling * 2.5
            while y > ruling * 0.5 {
                ctx.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: w, y: y)])
                y -= ruling
            }
            ctx.setStrokeColor(PaperColor(0.90, 0.40, 0.42).cg)
            ctx.setLineWidth(w / 180)
            ctx.strokeLineSegments(between: [CGPoint(x: w * 0.16, y: 0), CGPoint(x: w * 0.16, y: h)])
            ctx.setFillColor(PaperColor(0.80, 0.80, 0.78).cg)
            for k in 0..<3 {
                let cy = h * (0.18 + 0.32 * CGFloat(k))
                ctx.fillEllipse(in: CGRect(x: w * 0.045, y: cy, width: w * 0.045, height: w * 0.045))
            }
        case .graph:
            let step = w / 22
            for (index, x) in stride(from: CGFloat(0), through: w, by: step).enumerated() {
                ctx.setStrokeColor(PaperColor(0.55, 0.78, 0.82).cg)
                ctx.setLineWidth(index % 5 == 0 ? w / 230 : w / 520)
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: h)])
            }
            for (index, y) in stride(from: CGFloat(0), through: h, by: step).enumerated() {
                ctx.setStrokeColor(PaperColor(0.55, 0.78, 0.82).cg)
                ctx.setLineWidth(index % 5 == 0 ? w / 230 : w / 520)
                ctx.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: w, y: y)])
            }
        case .newspaper:
            drawNewspaper(ctx, w: w, h: h, rand: &rand)
        case .kraft:
            // Fibres: short strokes a shade either side of the base, mostly along the grain.
            for _ in 0..<900 {
                let shade = CGFloat(rand.inRange(0.82, 1.12))
                ctx.setStrokeColor(PaperPalette.base(paper).scaled(shade).cg)
                ctx.setLineWidth(CGFloat(rand.inRange(0.6, 1.6)))
                let x = CGFloat(rand.next()) * w, y = CGFloat(rand.next()) * h
                let length = CGFloat(rand.inRange(4, 14))
                let angle = CGFloat(rand.inRange(-0.3, 0.3))
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: y),
                                                 CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length)])
            }
        case .plain:
            // Origami paper has a faint printed texture; without it a plain sheet reads as plastic.
            let base = PaperPalette.base(paper)
            for _ in 0..<1400 {
                ctx.setFillColor(base.scaled(CGFloat(rand.inRange(0.9, 1.08))).cg)
                let x = CGFloat(rand.next()) * w, y = CGFloat(rand.next()) * h
                ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        return ctx.makeImage()
    }

    private static func drawNewspaper(_ ctx: CGContext, w: CGFloat, h: CGFloat, rand: inout Rand) {
        let ink = PaperColor(0.18, 0.18, 0.18)
        // Masthead and a headline: the two bars a newspaper reads as from across a room.
        ctx.setFillColor(ink.cg)
        ctx.fill(CGRect(x: w * 0.08, y: h * 0.90, width: w * 0.84, height: h * 0.045))
        ctx.fill(CGRect(x: w * 0.06, y: h * 0.885, width: w * 0.88, height: h * 0.004))
        ctx.fill(CGRect(x: w * 0.06, y: h * 0.80, width: w * 0.62, height: h * 0.03))
        // A grey photograph.
        ctx.setFillColor(PaperColor(0.55, 0.55, 0.53).cg)
        let photo = CGRect(x: w * 0.53, y: h * 0.48, width: w * 0.41, height: h * 0.26)
        ctx.fill(photo)
        ctx.setFillColor(PaperColor(0.38, 0.38, 0.37).cg)
        ctx.fillEllipse(in: photo.insetBy(dx: photo.width * 0.3, dy: photo.height * 0.2).offsetBy(dx: 0, dy: -photo.height * 0.1))
        // Columns of text, as grey lines of ragged length.
        ctx.setFillColor(PaperColor(0.45, 0.45, 0.44).cg)
        let columns: [(x: CGFloat, width: CGFloat, top: CGFloat)] = [
            (0.06, 0.42, 0.77), (0.53, 0.41, 0.45), (0.06, 0.42, 0.40)]
        let line = h / 70
        for (index, column) in columns.enumerated() {
            var y = h * column.top
            let bottom = index == 2 ? h * 0.04 : (index == 0 ? h * 0.43 : h * 0.04)
            while y > bottom {
                let ragged = CGFloat(rand.inRange(0.75, 1))
                ctx.fill(CGRect(x: w * column.x, y: y, width: w * column.width * ragged, height: line * 0.45))
                y -= line
            }
        }
    }

    /// Near-white paper grain for the landscape, multiplied under each face's colour. Values
    /// stay high, so it textures a face without darkening the palette it was balanced at.
    static func grain(size: Int = 256, seed: UInt64) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var rand = Rand(seed: seed ^ 0x6A41_2B)
        let s = CGFloat(size)
        ctx.setFillColor(PaperColor(0.97, 0.97, 0.96).cg)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        for _ in 0..<2600 {
            let v = CGFloat(rand.inRange(0.86, 1.0))
            ctx.setFillColor(PaperColor(v, v, v * 0.99).cg)
            ctx.fill(CGRect(x: CGFloat(rand.next()) * s, y: CGFloat(rand.next()) * s,
                            width: CGFloat(rand.inRange(1, 2.5)), height: CGFloat(rand.inRange(1, 2.5))))
        }
        // Long faint fibres, wrapped so the tile repeats without a seam.
        for _ in 0..<160 {
            let v = CGFloat(rand.inRange(0.88, 0.95))
            ctx.setStrokeColor(PaperColor(v, v, v).cg)
            ctx.setLineWidth(CGFloat(rand.inRange(0.5, 1.2)))
            let x = CGFloat(rand.next()) * s, y = CGFloat(rand.next()) * s
            let angle = CGFloat(rand.inRange(0, .pi))
            let length = CGFloat(rand.inRange(8, 30))
            for dx in [-s, 0, s] {
                for dy in [-s, 0, s] {
                    ctx.strokeLineSegments(between: [CGPoint(x: x + dx, y: y + dy),
                                                     CGPoint(x: x + dx + cos(angle) * length,
                                                             y: y + dy + sin(angle) * length)])
                }
            }
        }
        return ctx.makeImage()
    }

    /// A small square for paper-scrap particles, and a soft dot for smoke.
    static func square(size: Int = 16) -> CGImage? {
        image(size: size) { ctx, s in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8))
        }
    }

    static func softDot(size: Int = 64) -> CGImage? {
        image(size: size) { ctx, s in
            let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: s / 2, y: s / 2)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c,
                                   endRadius: s / 2, options: [])
        }
    }

    private static func image(size: Int, draw: (CGContext, CGFloat) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(ctx, CGFloat(size))
        return ctx.makeImage()
    }
}

/// One material per paper, shared by every plane folded from it, and painted with its swirls of
/// glow-in-the-dark paint (`GlowPaint`).
final class PaperMaterials {
    private var cache: [String: SCNMaterial] = [:]
    /// The same papers with damage marks over them (`DamageMarks`).
    var damaged: [String: SCNMaterial] = [:]
    private let seed: UInt64
    let paint: GlowPaint
    /// The moonlight, which takes half the colour out of the paper at night — the paint around
    /// the glowing swirls goes toward grey, as Brandon pictured it, and keeps a hint of its side.
    let ground: GroundLights
    static let moonWeight: Float = 0.5

    init(seed: UInt64, paint: GlowPaint, ground: GroundLights) {
        self.seed = seed
        self.paint = paint
        self.ground = ground
    }

    func material(for paper: Paper, aspect: CGFloat) -> SCNMaterial {
        let key = "\(paper.kind.rawValue)-\(paper.tint)-\(Int(aspect * 100))"
        if let cached = cache[key] { return cached }
        let material = SCNMaterial()
        material.lightingModel = .lambert
        // A folded sheet is seen from both sides — the underside of a banked wing is the case
        // that shows it — and a single-sided mesh would be missing every face turned away.
        material.isDoubleSided = true
        if let image = PaperTextures.sheet(paper, aspect: aspect, seed: seed) {
            material.diffuse.contents = image
            material.diffuse.mipFilter = .linear
            material.diffuse.maxAnisotropy = 8
        } else {
            material.diffuse.contents = PaperPalette.base(paper).ns
        }
        paint.paint(material, paper: paper, aspect: aspect, seed: seed)
        ground.grade(material, weight: PaperMaterials.moonWeight)
        cache[key] = material
        return material
    }
}
