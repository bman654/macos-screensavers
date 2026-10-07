// The scoreboard's picture: an index card taped into the corner of the diorama, the score kept
// on it in pencil tallies and the clock scrawled in the corner — part of the paper world rather
// than a UI laid over it.
//
// Drawn with CoreGraphics into an sRGB image, which SceneKit decodes back to exactly what was
// drawn (`docs/next-session.md`, traps: colour management of generated images). Laid out in
// points and rendered at however many pixels a point is worth on the frame it lands in, so the
// card is the same size to the eye on a Retina panel, a 4K one and the picker's capped tile.

import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Everything the card shows. Equatable so the picture is redrawn only when this changes —
/// about once a second, as the clock ticks.
struct ScoreCardContent: Equatable {
    struct Entry: Equatable {
        let paper: Paper
        let count: Int
    }

    enum Body: Equatable {
        /// Teams: a row per side, tallied.
        case teams([Entry])
        /// Free-for-all: a grid of swatches with counts, which stays compact at twelve planes.
        case everyone([Entry])
        /// The match is over. One winner, or several on equal kills.
        case result(winners: [Entry], teams: Bool)
    }

    let body: Body
    /// Whole seconds left on the match clock.
    let clock: Int
    let match: Int
}

enum ScoreCard {
    /// Layout in points.
    private static let width: CGFloat = 176
    private static let header: CGFloat = 30
    private static let teamRow: CGFloat = 27
    private static let gridRow: CGFloat = 24
    private static let gridColumns = 4
    private static let foot: CGFloat = 9
    /// Room round the card for its shadow, in points.
    static let pad: CGFloat = 7

    private static let ink = CGColor(srgbRed: 0.20, green: 0.21, blue: 0.27, alpha: 1)
    private static let pencil = CGColor(srgbRed: 0.33, green: 0.33, blue: 0.36, alpha: 0.92)
    private static let card = CGColor(srgbRed: 0.985, green: 0.97, blue: 0.92, alpha: 1)
    private static let rule = CGColor(srgbRed: 0.55, green: 0.70, blue: 0.86, alpha: 0.55)
    private static let margin = CGColor(srgbRed: 0.88, green: 0.36, blue: 0.36, alpha: 0.75)

    /// The card's size in points, shadow pad included. Fixed for a match: the result is drawn
    /// in the same card the tally was, so the card does not jump when the match ends.
    static func size(sides: Int, teams: Bool) -> CGSize {
        let rows = teams ? CGFloat(sides) * teamRow
            : CGFloat((sides + gridColumns - 1) / gridColumns) * gridRow
        return CGSize(width: width + pad * 2, height: header + max(rows, teamRow * 2) + foot + pad * 2)
    }

    /// The card at `pixelsPerPoint`, nil only if CoreGraphics cannot make a context.
    static func image(_ content: ScoreCardContent, size: CGSize, pixelsPerPoint k: CGFloat) -> CGImage? {
        let w = Int(ceil(size.width * k)), h = Int(ceil(size.height * k))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: k, y: k)
        // Top-down from here on, like the layout reads.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let frame = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
        ctx.saveGState()
        // Shadow offsets are in device pixels, up positive, whatever the CTM says.
        ctx.setShadow(offset: CGSize(width: 1.5 * k, height: -2.5 * k), blur: 4 * k,
                      color: CGColor(srgbRed: 0.1, green: 0.08, blue: 0.05, alpha: 0.35))
        ctx.setFillColor(card)
        ctx.fill(frame)
        ctx.restoreGState()

        // An index card: faint blue rules under the header, a red one beneath it.
        ctx.setLineWidth(0.6)
        ctx.setStrokeColor(rule)
        var y = frame.minY + header + 14
        while y < frame.maxY - 4 {
            ctx.strokeLineSegments(between: [CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y)])
            y += 13
        }
        ctx.setLineWidth(0.9)
        ctx.setStrokeColor(margin)
        ctx.strokeLineSegments(between: [CGPoint(x: frame.minX, y: frame.minY + header - 3),
                                         CGPoint(x: frame.maxX, y: frame.minY + header - 3)])
        tape(ctx, at: CGPoint(x: frame.midX, y: frame.minY + 1))

        let left = frame.minX + 10, right = frame.maxX - 10
        text(ctx, "Match \(content.match + 1)", at: CGPoint(x: left, y: frame.minY + 19), size: 12, colour: ink)
        if case .result = content.body {
            text(ctx, "over", at: CGPoint(x: right, y: frame.minY + 19), size: 12, colour: ink, alignRight: true)
        } else {
            text(ctx, String(format: "%d:%02d", content.clock / 60, content.clock % 60),
                 at: CGPoint(x: right, y: frame.minY + 19), size: 13, colour: ink, alignRight: true)
        }

        let top = frame.minY + header
        switch content.body {
        case .teams(let entries):
            let leader = soleLeader(entries)
            for (row, entry) in entries.enumerated() {
                let mid = top + teamRow * (CGFloat(row) + 0.5) + 2
                swatch(ctx, entry.paper, CGRect(x: left, y: mid - 8, width: 16, height: 16), k: k)
                tally(ctx, entry.count, from: left + 26, to: right - 30, mid: mid)
                text(ctx, "\(entry.count)", at: CGPoint(x: right, y: mid + 6), size: 16, colour: ink, alignRight: true)
                if leader == row { ring(ctx, around: CGPoint(x: right - 7, y: mid), width: 26) }
            }
        case .everyone(let entries):
            let leader = soleLeader(entries)
            let cell = (right - left) / CGFloat(gridColumns)
            for (index, entry) in entries.enumerated() {
                let x = left + cell * CGFloat(index % gridColumns)
                let mid = top + gridRow * (CGFloat(index / gridColumns) + 0.5) + 2
                swatch(ctx, entry.paper, CGRect(x: x, y: mid - 7, width: 14, height: 14), k: k)
                text(ctx, "\(entry.count)", at: CGPoint(x: x + 19, y: mid + 6), size: 15, colour: ink)
                // Narrow, so the loop takes in the count and not the swatch beside it.
                let digits = CGFloat("\(entry.count)".count)
                if leader == index { ring(ctx, around: CGPoint(x: x + 19 + 4.5 * digits, y: mid), width: 8 + 9 * digits) }
            }
        case .result(let winners, let teams):
            let mid = (top + frame.maxY - foot) / 2 + 2
            if winners.count == 1, let winner = winners.first {
                swatch(ctx, winner.paper, CGRect(x: left, y: mid - 13, width: 26, height: 26), k: k)
                let name = teams ? "\(PaperPalette.name(winner.paper)) wins!" : "wins!"
                text(ctx, name, at: CGPoint(x: left + 36, y: mid + 8), size: 20, colour: ink)
            } else {
                // A draw: every side on the top score, side by side.
                for (index, winner) in winners.prefix(6).enumerated() {
                    swatch(ctx, winner.paper, CGRect(x: left + CGFloat(index) * 20, y: mid - 9, width: 16, height: 16), k: k)
                }
                text(ctx, "Draw", at: CGPoint(x: right, y: mid + 8), size: 20, colour: ink, alignRight: true)
            }
        }
        return ctx.makeImage()
    }

    private static func soleLeader(_ entries: [ScoreCardContent.Entry]) -> Int? {
        guard let best = entries.map(\.count).max(), best > 0,
              entries.filter({ $0.count == best }).count == 1 else { return nil }
        return entries.firstIndex { $0.count == best }
    }

    /// Pencil tallies, in fives, squeezed together if there are more than fit.
    private static func tally(_ ctx: CGContext, _ count: Int, from x0: CGFloat, to x1: CGFloat, mid: CGFloat) {
        guard count > 0 else { return }
        let groups = (count + 4) / 5
        let natural: CGFloat = 23
        let groupWidth = min(natural, (x1 - x0) / CGFloat(groups))
        let stroke = groupWidth / natural * 4
        ctx.setStrokeColor(pencil)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        for g in 0..<groups {
            let gx = x0 + CGFloat(g) * groupWidth
            let marks = min(count - g * 5, 5)
            for m in 0..<min(marks, 4) {
                // A hand does not rule straight lines: each mark leans its own way a little.
                let x = gx + CGFloat(m) * stroke + 1
                let lean = CGFloat((g * 7 + m * 3) % 5) * 0.35 - 0.7
                ctx.strokeLineSegments(between: [CGPoint(x: x + lean, y: mid - 7), CGPoint(x: x - lean, y: mid + 7)])
            }
            if marks == 5 {
                ctx.strokeLineSegments(between: [CGPoint(x: gx - 1, y: mid + 5), CGPoint(x: gx + stroke * 3 + 3, y: mid - 5)])
            }
        }
    }

    /// A small square of the side's paper with a corner folded over, like a sample swatch.
    private static func swatch(_ ctx: CGContext, _ paper: Paper, _ r: CGRect, k: CGFloat) {
        let base = PaperPalette.base(paper)
        let fold = r.width * 0.3
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: r.minX, y: r.minY))
        outline.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        outline.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        outline.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        outline.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        outline.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0.5 * k, height: -0.8 * k), blur: k, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(outline)
        ctx.setFillColor(base.cg)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        ctx.setLineWidth(0.6)
        switch paper.kind {
        case .notebook:
            ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 0.9))
            for k in stride(from: r.minY + 3, to: r.maxY, by: 3.5) {
                ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: k), CGPoint(x: r.maxX, y: k)])
            }
        case .graph:
            ctx.setStrokeColor(CGColor(srgbRed: 0.40, green: 0.66, blue: 0.62, alpha: 0.8))
            for k in stride(from: CGFloat(0), to: r.width, by: 3) {
                ctx.strokeLineSegments(between: [CGPoint(x: r.minX + k, y: r.minY), CGPoint(x: r.minX + k, y: r.maxY),
                                                 CGPoint(x: r.minX, y: r.minY + k), CGPoint(x: r.maxX, y: r.minY + k)])
            }
        case .newspaper:
            ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 0.8))
            ctx.setLineWidth(1)
            for k in stride(from: r.minY + 3, to: r.maxY - 1, by: 2.5) {
                ctx.strokeLineSegments(between: [CGPoint(x: r.minX + 2, y: k), CGPoint(x: r.maxX - 2, y: k)])
            }
        case .kraft, .plain:
            break
        }
        ctx.restoreGState()
        // The folded-over corner, its back a shade darker.
        ctx.setFillColor(base.scaled(0.78).cg)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY + fold))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        ctx.closePath()
        ctx.fillPath()
    }

    /// A pencil loop round the leader's count.
    private static func ring(_ ctx: CGContext, around c: CGPoint, width: CGFloat) {
        ctx.setStrokeColor(margin)
        ctx.setLineWidth(1.1)
        ctx.strokeEllipse(in: CGRect(x: c.x - width / 2, y: c.y - 10, width: width, height: 19))
    }

    /// A strip of tape holding the card up.
    private static func tape(_ ctx: CGContext, at c: CGPoint) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -0.06)
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.95, blue: 0.86, alpha: 0.75))
        ctx.fill(CGRect(x: -22, y: -6, width: 44, height: 12))
        ctx.restoreGState()
    }

    /// Handwriting where the system has it, so the card reads as written on.
    private static func font(size: CGFloat) -> CTFont {
        for name in ["Noteworthy-Bold", "ChalkboardSE-Regular", "MarkerFelt-Thin"] {
            if let font = NSFont(name: name, size: size) { return font as CTFont }
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
    }

    /// `at` is the baseline's left end, or its right end when `alignRight`.
    private static func text(_ ctx: CGContext, _ string: String, at p: CGPoint, size: CGFloat, colour: CGColor,
                             alignRight: Bool = false) {
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.saveGState()
        // CoreText draws y-up; this context was flipped to read top-down.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: alignRight ? p.x - width : p.x, y: p.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

extension PaperPalette {
    /// What a team colour is called on the card.
    static func name(_ paper: Paper) -> String {
        switch paper.kind {
        case .notebook: return "Notebook"
        case .graph: return "Graph"
        case .newspaper: return "Newspaper"
        case .kraft: return "Kraft"
        case .plain:
            return ["Red", "Blue", "Yellow", "Violet", "Orange", "Teal", "Pink", "Charcoal"][paper.tint % plainCount]
        }
    }

    static var plainCount: Int { plain.count }
}
