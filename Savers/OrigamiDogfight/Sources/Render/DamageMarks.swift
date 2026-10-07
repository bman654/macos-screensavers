// Damage on the paper: smudges, then scorch marks, then char, deepening as a plane's or tank's
// armour goes (`Damage.stage`).
//
// Three sheets, drawn once with CoreGraphics and shared by everything: each is near-white paper
// with marks on it, laid over a vehicle's own paper as SceneKit's `multiply` through the same
// sheet coordinates its paper uses — so the marks fold with the paper, and white leaves the paper
// exactly as it was. Each stage keeps the marks of the one before and adds to them, so a plane
// that is hit again is seen to get worse rather than to change. Half the marks crowd the sheet's
// edges, which fold out to a plane's wingtips and trailing edge, where a paper plane does get
// scuffed; the rest fall anywhere, since a tank's hull is unwrapped into the middle of its sheet.
//
// Pictures, so sRGB-tagged images, which SceneKit decodes back to what was drawn
// (`docs/next-session.md`, traps).

import AppKit
import CoreGraphics
import Foundation
import SceneKit

enum DamageMarks {
    /// The marks for stages 1 to 3, built on first use. Stage 0 has none.
    static func image(stage: Int) -> CGImage? {
        guard (1...3).contains(stage) else { return nil }
        return sheets[stage - 1]
    }

    private static let sheets: [CGImage?] = (1...3).map { draw(stage: $0) }

    private static func draw(stage: Int, size: Int = 256) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = CGFloat(size)
        // An overall grime that deepens with each stage, under the marks: wherever a model's
        // paper is unwrapped onto the sheet, and however few marks land there, it is seen to
        // get dirtier. A tank's hull top missed most of the marks without it.
        let grime: CGFloat = [0.98, 0.9, 0.8][stage - 1]
        ctx.setFillColor(CGColor(srgbRed: grime, green: grime * 0.98, blue: grime * 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        // One stream for every stage, so stage 2 redraws stage 1's marks exactly and adds more.
        var rand = Rand(seed: 0xDA6E_5C02)

        /// Somewhere on the sheet: half the time near an edge, otherwise anywhere.
        func edgeward() -> CGPoint {
            let u = CGFloat(rand.next()), v = CGFloat(rand.next())
            let pull = CGFloat(rand.next())
            let x = pull < 0.25 ? (u < 0.5 ? u * 0.4 : 1 - (1 - u) * 0.4) : u
            let y = pull >= 0.25 && pull < 0.5 ? (v < 0.5 ? v * 0.4 : 1 - (1 - v) * 0.4) : v
            return CGPoint(x: x * s, y: y * s)
        }

        // Stage 1: graphite scuffs — the smudges and grazes of a plane that has been clipped.
        // Firm-hearted and few, with a short crisp graze through most: it is the edges that
        // show on a bright yellow or pink sheet, where a soft grey wash only dulled the colour,
        // and a few marks with edges read as hits where a wash all over read as dirt.
        for _ in 0..<12 {
            let p = edgeward()
            let r = CGFloat(rand.inRange(0.04, 0.075)) * s
            blot(ctx, at: p, radius: r, colour: (0.50, 0.50, 0.53), alpha: 0.9, rand: &rand)
            guard rand.next() < 0.75 else { continue }
            let angle = CGFloat(rand.inRange(0, 2 * .pi)), length = CGFloat(rand.inRange(0.05, 0.1)) * s
            let d = CGPoint(x: cos(angle) * length / 2, y: sin(angle) * length / 2)
            ctx.setStrokeColor(CGColor(srgbRed: 0.38, green: 0.38, blue: 0.42, alpha: 0.8))
            ctx.setLineWidth(s * CGFloat(rand.inRange(0.008, 0.014)))
            ctx.setLineCap(.round)
            ctx.strokeLineSegments(between: [CGPoint(x: p.x - d.x, y: p.y - d.y), CGPoint(x: p.x + d.x, y: p.y + d.y)])
        }
        if stage >= 2 {
            // Stage 2: brown scorches with darker hearts, where shots burned through.
            for _ in 0..<16 {
                let p = edgeward()
                let r = CGFloat(rand.inRange(0.05, 0.1)) * s
                blot(ctx, at: p, radius: r, colour: (0.62, 0.45, 0.28), alpha: 0.75, rand: &rand)
                blot(ctx, at: p, radius: r * 0.45, colour: (0.32, 0.22, 0.15), alpha: 0.8, rand: &rand)
            }
        }
        if stage >= 3 {
            // Stage 3: charred — big dark patches and blackened edges all round.
            for _ in 0..<14 {
                let p = edgeward()
                let r = CGFloat(rand.inRange(0.08, 0.15)) * s
                blot(ctx, at: p, radius: r, colour: (0.40, 0.30, 0.22), alpha: 0.8, rand: &rand)
                blot(ctx, at: p, radius: r * 0.5, colour: (0.16, 0.13, 0.11), alpha: 0.85, rand: &rand)
            }
            ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.19, blue: 0.14, alpha: 0.7))
            ctx.setLineWidth(s * 0.05)
            ctx.stroke(CGRect(x: 0, y: 0, width: s, height: s))
        }
        return ctx.makeImage()
    }

    /// A ragged soft-edged mark: a cluster of overlapping discs, faint at its rim.
    private static func blot(_ ctx: CGContext, at p: CGPoint, radius r: CGFloat, colour: (CGFloat, CGFloat, CGFloat),
                             alpha: CGFloat, rand: inout Rand) {
        for _ in 0..<7 {
            let dx = CGFloat(rand.inRange(-0.5, 0.5)) * r, dy = CGFloat(rand.inRange(-0.5, 0.5)) * r
            let rr = r * CGFloat(rand.inRange(0.45, 0.8))
            let c = CGPoint(x: p.x + dx, y: p.y + dy)
            let colours = [CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: alpha * 0.45),
                           CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours,
                                            locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: rr, options: [])
        }
    }
}

extension PaperMaterials {
    /// The paper's material with the marks for `stage` laid over it: one per paper, sheet shape
    /// and stage, shared like the clean one is.
    func material(for paper: Paper, aspect: CGFloat, damage stage: Int) -> SCNMaterial {
        let clean = material(for: paper, aspect: aspect)
        guard let marks = DamageMarks.image(stage: stage) else { return clean }
        let key = "\(paper.kind.rawValue)-\(paper.tint)-\(Int(aspect * 100))-d\(stage)"
        if let cached = damaged[key] { return cached }
        let material = (clean.copy() as? SCNMaterial) ?? clean
        material.multiply.contents = marks
        material.multiply.mipFilter = .linear
        damaged[key] = material
        return material
    }
}
