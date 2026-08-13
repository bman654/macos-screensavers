// A `RenderHost` that lets SceneKit draw into the drawable `SaverView` already owns.
//
// `SCNRenderer.render(atTime:viewport:commandBuffer:passDescriptor:)` encodes into a pass
// descriptor we hand it, which is what makes SceneKit and raw Metal interchangeable behind
// one `CAMetalLayer` — and what lets a future saver run a raw pass over a SceneKit pass in
// the same drawable.
//
// This host is deliberately empty of subject matter: it holds a scene, a point of view and
// a per-frame hook. Everything about fish, tanks or fog lives in the saver that builds the
// scene.

import Foundation
import Metal
import QuartzCore
import SceneKit

final class SceneKitHost: RenderHost {
    let renderer: SCNRenderer
    let scene: SCNScene
    let pointOfView: SCNNode

    /// sRGB, and not the protocol's `.bgra8Unorm` default.
    ///
    /// SceneKit shades in linear space and writes linear values straight into whatever
    /// attachment it is handed. Into a plain `.bgra8Unorm` target that is displayed as if it
    /// were already sRGB-encoded, which crushes the whole image — a 0.068 background arrives
    /// as 2/255 and the scene looks black. The sRGB attachment format makes the hardware do
    /// the encode on write. `SaverView` propagates this to the `CAMetalLayer`.
    let colorPixelFormat: MTLPixelFormat

    let sampleCount: Int

    /// Discarded whenever the point of view has `wantsHDR` on — SceneKit renders to its own
    /// float buffer and composites the tone-mapped result over the attachment, ignoring both
    /// this clear and the drawable's alpha. Set `scene.background.contents` to a colour
    /// instead; this value only matters for the non-HDR path.
    var clearColor: MTLClearColor

    /// Called once per frame, immediately before the scene is rendered.
    ///
    /// The scene owner drives its own simulation from here rather than from `SCNAction`s,
    /// so the animation clock is `FrameContext`'s and survives the pause between
    /// `stopAnimation()` and `startAnimation()`.
    var onUpdate: ((FrameContext) -> Void)?

    init(device: MTLDevice,
         scene: SCNScene,
         pointOfView: SCNNode,
         sampleCount: Int = 4,
         colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb,
         clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) {
        self.scene = scene
        self.pointOfView = pointOfView
        self.sampleCount = sampleCount
        self.colorPixelFormat = colorPixelFormat
        self.clearColor = clearColor

        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        // Every light in the scene is placed deliberately; the default rig would wash them out.
        renderer.autoenablesDefaultLighting = false
    }

    // The viewport is taken from `FrameContext` each frame rather than cached at resize,
    // because that is the size the drawable actually came back as — there is no window in
    // which the two can disagree. Nothing else here depends on size, so `hostDidResize`
    // stays the protocol's no-op.
    func encode(_ frame: FrameContext) {
        // Any node property set outside SceneKit's own render loop is wrapped in an implicit
        // animation, and those animations are stamped with `CACurrentMediaTime()` while
        // `render(atTime:)` below is driven by the display link's clock, which starts at zero.
        // The animation is therefore evaluated long before it begins, the presentation tree
        // never leaves its initial value, and a scene driven by per-frame mutation renders as
        // if nothing had moved — geometry sits wherever it was when the renderer was attached,
        // usually the origin, i.e. invisible. Zero duration is what makes a mutation take
        // effect on the frame that made it. The symptom points nowhere near animation, so this
        // belongs to the host rather than to every scene that mutates a node.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        onUpdate?(frame)
        SCNTransaction.commit()

        // `atTime` is an ABSOLUTE timeline, not a delta: SceneKit evaluates actions,
        // animations and particle systems at this value. Passing a per-frame delta freezes
        // every particle system in the scene.
        renderer.render(atTime: frame.time,
                        viewport: CGRect(origin: .zero, size: frame.drawableSize),
                        commandBuffer: frame.commandBuffer,
                        passDescriptor: frame.passDescriptor)
    }

    func teardown() {
        onUpdate = nil
        renderer.scene = nil
    }
}
