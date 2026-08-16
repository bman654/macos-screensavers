// The picture the probe draws: a black field and a block of monospaced diagnostics.
//
// It exists because of where this spike has to be run. The load-bearing test is the login
// window, and there is no console, no debugger and no environment there — whatever the probe
// has to say, it has to say on screen. A screenshot of this readout is the entire result.
//
// Drawn as a SpriteKit overlay on an otherwise empty SceneKit scene, which is the same
// mechanism the aquarium's seed badge uses. There is no scene to speak of: `SCNRenderer`
// clears to the background and composites the overlay on top, and the overlay is text, which
// is the only thing this probe has to show.

import AppKit
import Foundation
import SceneKit
import SpriteKit

final class AudioProbeReadout {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let overlay = SKScene()

    private var lines: [SKLabelNode] = []
    private var lastText: [String] = []
    private var size: CGSize = .zero

    /// A dark blue-grey rather than black: a truly black screen is also what a *failed* saver
    /// looks like, and the two need to be distinguishable from across a room.
    private static let background = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.10, alpha: 1)

    init(lineCount: Int) {
        scene.background.contents = AudioProbeReadout.background
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)

        // Sized in the drawable's own pixels and re-sized on every reshape, so it must not
        // also scale its contents — `.resizeFill` is the mode that leaves the coordinate
        // system alone.
        overlay.scaleMode = .resizeFill
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false

        for _ in 0..<lineCount {
            let label = SKLabelNode()
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .top
            overlay.addChild(label)
            lines.append(label)
        }
        lastText = Array(repeating: "", count: lineCount)
    }

    func resize(to drawableSize: CGSize) {
        guard drawableSize != size, drawableSize.width > 0 else { return }
        size = drawableSize
        overlay.size = drawableSize
        layout()
    }

    /// Text is rebuilt only when it changes. Handing `SKLabelNode` a fresh `NSAttributedString`
    /// sixty times a second re-runs text layout for every line on the main thread, and the
    /// numbers on screen change a few times a second at most.
    func update(_ text: [String]) {
        guard text != lastText else { return }
        lastText = text
        layout()
    }

    private func layout() {
        guard size.width > 0 else { return }
        let side = min(size.width, size.height)
        let fontSize = max(11, side * 0.022)
        let margin = side * 0.04
        // Set through an attributed string rather than through `fontName`: `SKLabelNode`
        // resolves a font *name*, and the system monospaced face has no name to resolve —
        // "SFMono-Regular" logs `font not found` and silently falls back to Helvetica.
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        for (index, label) in lines.enumerated() {
            let string = index < lastText.count ? lastText[index] : ""
            label.attributedText = NSAttributedString(
                string: string,
                attributes: [.font: font, .foregroundColor: colour(for: string)])
            label.position = CGPoint(x: margin,
                                     y: size.height - margin - CGFloat(index) * fontSize * 1.45)
        }
    }

    /// A verdict readable from across a room, before any of the numbers are.
    private func colour(for line: String) -> NSColor {
        if line.contains("FAILED") { return NSColor(calibratedRed: 1, green: 0.35, blue: 0.3, alpha: 1) }
        if line.contains("running") { return NSColor(calibratedRed: 0.4, green: 1, blue: 0.5, alpha: 1) }
        if line.contains("silent") { return NSColor(calibratedRed: 1, green: 0.85, blue: 0.35, alpha: 1) }
        return NSColor(white: 0.82, alpha: 1)
    }
}
