// The seed, printed in the corner of the tank.
//
// A tank is drawn from one number and there was previously no way to learn what it was from
// inside the screensaver — `AQUARIUM_SEED` pins one, but the environment is empty under
// `legacyScreenSaver`, so a good tank seen on the real thing was gone for good. The badge and
// the settings sheet's seed field are one feature: read the number off the corner, type it
// back in, get the same tank.
//
// Drawn as a SpriteKit overlay rather than as geometry. A quad parented to the camera would
// have to be placed against a frustum that changes shape with the drawable, and it would be
// fogged, bloomed and tone-mapped along with the water — the badge is interface, and interface
// belongs on top of the picture rather than inside it.

import AppKit
import Foundation
import SpriteKit

struct SeedBadge {
    /// The overlay to hang on the renderer, or nil if the badge is off.
    ///
    /// `SCNRenderer` composites this after the scene, so the label is untouched by the water's
    /// fog and by the camera's HDR tone mapping — which is what keeps it legible against a
    /// deep-ocean backdrop and a shallow-reef one at the same brightness.
    static func overlay(seed: UInt64, drawableSize: CGSize) -> SKScene {
        let scene = SKScene(size: drawableSize)
        // The overlay is sized in the drawable's own pixels and re-sized on every reshape, so
        // it must not also scale its contents — `.resizeFill` is the mode that leaves the
        // coordinate system alone.
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.isUserInteractionEnabled = false

        let label = SKLabelNode()
        label.name = SeedBadge.labelName
        label.userData = ["seed": seed]
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .top
        scene.addChild(label)

        SeedBadge.layout(scene, size: drawableSize)
        return scene
    }

    /// Follows the drawable, which reshapes under a live view when a display mode changes or
    /// the System Settings preview is dragged.
    ///
    /// The font size is a fraction of the drawable's *height* rather than a point size, so the
    /// badge is the same apparent size on a Retina display as on a conventional one without
    /// anything having to know the backing scale — the same reason nothing else in this scene
    /// reads one either.
    static func resize(_ scene: SKScene, to drawableSize: CGSize) {
        guard scene.size != drawableSize else { return }
        scene.size = drawableSize
        layout(scene, size: drawableSize)
    }

    private static func layout(_ scene: SKScene, size: CGSize) {
        guard let label = scene.childNode(withName: labelName) as? SKLabelNode,
              let seed = label.userData?["seed"] as? UInt64 else { return }
        let side = min(size.width, size.height)
        // Set through an attributed string rather than through `fontName` and `fontSize`,
        // because `SKLabelNode` resolves a font *name* and the system monospaced face has no
        // name to resolve: "SFMono-Regular" logs `font not found` and silently falls back to
        // Helvetica. `NSFont` hands over the face itself, so there is nothing to look up.
        //
        // Monospaced digits, because the number's whole job is to be copied by eye — a
        // proportional face puts 1 and 7 at different widths and makes a run of digits hard to
        // keep a place in.
        let font = NSFont.monospacedSystemFont(ofSize: max(9, side * 0.016), weight: .regular)
        label.attributedText = NSAttributedString(
            string: "seed \(seed)",
            attributes: [.font: font,
                         // Faint on purpose: it has to be readable when looked for and ignorable
                         // when not, over water that ranges from near-black in the deep ocean to
                         // a bright turquoise on the reef.
                         .foregroundColor: NSColor(white: 1, alpha: 0.45)])
        // Top left. The bottom of the frame is the substrate's cross-section in the aquarium
        // look and the lit seabed in the other two, so both bottom corners are the busiest part
        // of every tank; the top left is open water in all three.
        let margin = side * 0.018
        label.position = CGPoint(x: margin, y: size.height - margin)
    }

    private static let labelName = "seed-badge"
}
