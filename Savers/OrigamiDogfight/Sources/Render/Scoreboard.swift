// The scoreboard's place in the scene: a quad hung on the camera, in a different corner every
// match, carrying the card `ScoreCard` draws.
//
// A quad rather than a SpriteKit overlay, which costs a full-screen pass whatever is on it —
// 2 ms at 2056x1329 for the Aquarium's few characters (`docs/next-session.md`, traps). The price
// the trap names, fighting fog, tone mapping and bloom, is not paid here: this scene has none of
// them, and the card's material is unlit and drawn after everything, so it arrives as drawn.

import AppKit
import Foundation
import SceneKit
import simd

final class Scoreboard {
    let node = SCNNode()
    private let quad = SCNPlane(width: 1, height: 1)
    private let material = SCNMaterial()

    /// The scale actually rendered at — the display's, or a capped tile's — so a card sized in
    /// points is the same size to the eye at any of them.
    var backingScale: CGFloat = 1

    /// Which corner match zero takes; every match after moves one corner round, so nothing sits
    /// in one place long enough to burn in.
    private let firstCorner: Int
    private var drawn: (content: ScoreCardContent, size: CGSize, pixelsPerPoint: CGFloat)?

    /// In front of everything: the camera's near plane is 1.5 m and the nearest plane is
    /// about 3.8 m off. The card ignores depth anyway; this only keeps it out of the far clip.
    private static let distance: Float = 2.0
    /// The share of the frame kept clear at each edge — inside the central ~92%.
    private static let edgeMargin: Float = 0.045

    init(seed: UInt64) {
        firstCorner = Int(seed % 4)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.mipFilter = .none
        quad.materials = [material]
        node.geometry = quad
        node.renderingOrder = 10_000
        node.castsShadow = false
        node.opacity = 0
    }

    func update(_ sim: DogfightSim, drawableSize: CGSize, now: Double) {
        let match = sim.match
        let teams = match.mode != .ffa
        let entries = (0..<match.sides).map { side in
            ScoreCardContent.Entry(paper: match.slots.first { $0.side == side }?.paper ?? Paper(kind: .plain, tint: 0),
                                   count: match.score[side],
                                   stickers: match.stickers.indices.contains(side) ? match.stickers[side] : [])
        }
        let body: ScoreCardContent.Body
        switch match.phase {
        case .fighting:
            body = teams ? .teams(entries) : .everyone(entries)
        case .won, .ending, .intermission:
            let leaders = match.leaders
            body = .result(winners: (leaders.isEmpty ? Array(entries.indices) : leaders).map { entries[$0] }, teams: teams)
        }
        let content = ScoreCardContent(body: body, clock: Int(ceil(match.remaining(at: now))), match: match.index)

        // How big the card is and how many pixels it is drawn with are separate questions. Its
        // size is in points — the card's natural size at the scale actually rendered, so it is
        // the same size to the eye whether the frame is drawn at 2x, 1x or a reduced tier's
        // fraction — capped so it never takes so much of a small frame that it stops being a
        // card in the corner (150 pixels was a fifth of the sheet's preview). Only the bitmap
        // has a floor: never so few pixels that a capped tile turns the handwriting to mush.
        // When the floor set the size too, a reduced tier's card came out ~30% larger, and
        // shrank when the picker's preview became the real thing.
        let size = ScoreCard.size(sides: match.sides, teams: teams)
        let frame = drawableSize
        guard frame.width > 0, frame.height > 0 else { return }
        // A little over a point per point: at one point to the point the handwriting read small
        // against a full-screen fight.
        let shown = min(size.width * backingScale * 1.2, frame.width * 0.18)
        let pixelsPerPoint = max(shown, 110) / size.width
        if drawn.map({ $0.content != content || $0.size != size || abs($0.pixelsPerPoint - pixelsPerPoint) > 0.01 }) ?? true {
            material.diffuse.contents = ScoreCard.image(content, size: size, pixelsPerPoint: pixelsPerPoint)
            drawn = (content, size, pixelsPerPoint)
        }

        // Pixels to metres on the plane `distance` in front of the camera.
        let d = Scoreboard.distance
        let halfHeight = d * tan(ViewRig.verticalFOV / 2)
        let metresPerPixel = 2 * halfHeight / Float(frame.height)
        let halfWidth = halfHeight * Float(frame.width / frame.height)
        let w = Float(shown) * metresPerPixel
        let h = Float(shown * size.height / size.width) * metresPerPixel
        quad.width = CGFloat(w)
        quad.height = CGFloat(h)
        let corner = (firstCorner + match.index) % 4
        let right: Float = corner == 1 || corner == 2 ? 1 : -1
        let up: Float = corner < 2 ? 1 : -1
        let x = right * (halfWidth * (1 - 2 * Scoreboard.edgeMargin) - w / 2)
        let y = up * (halfHeight * (1 - 2 * Scoreboard.edgeMargin) - h / 2)
        node.simdPosition = SIMD3(x, y, -d)

        // Pinned up a little crooked, the other way each match.
        let tilt: Float = match.index % 2 == 0 ? 0.022 : -0.018
        var pop: Float = 1
        if case .won(let since, _) = match.phase {
            // The winner is named: the card jumps a little, the way a slapped-down card does.
            let t = Float(min(max((now - since) / 0.45, 0), 1))
            pop = 1 + 0.12 * sin(.pi * t)
        }
        node.simdOrientation = simd_quatf(angle: tilt, axis: SIMD3(0, 0, 1))
        node.simdScale = SIMD3(repeating: pop)

        var opacity = Float(min(max((now - match.startedAt - 0.6) / 0.6, 0), 1))
        if case .intermission(let until) = match.phase {
            opacity = Float(min(max((until - now) / 1.2, 0), 1))
        }
        node.opacity = CGFloat(opacity)
    }
}
