// The Aquarium saver's entry point. Everything it does is hand a built tank to the shared
// SceneKit host; the drawable, display link and resize handling all live in `SaverView`.

import Foundation
import ScreenSaver

/// The `@objc` rename is load-bearing. `NSPrincipalClass` in the built bundle is the bare
/// name `AquariumView`, and Swift would otherwise export this as `Aquarium.AquariumView`.
/// Foundation's single-class fallback cannot rescue that here — the bundle contains many
/// classes, so a mismatch just yields a screensaver that refuses to load.
@objc(AquariumView)
final class AquariumView: SaverView {

    private var aquarium: AquariumScene?

    /// Half the rate of a ProMotion display, deliberately.
    ///
    /// The tank costs about 5.4 ms of GPU per frame at 4112x2658 with 4x MSAA, so it *can*
    /// hold 120 fps — but this runs unattended, often on battery, and nothing in a school of
    /// fish drifting across a tank reads differently at 60. Halving the frame rate halves the
    /// energy for the same motion, because the fish are driven by `FrameContext.time` rather
    /// than by a per-frame step. Measured: a locked 60.0 fps at 4112x2658, every frame
    /// interval 16.67 ms, GPU busy time down from 648 ms per second to 342.
    ///
    /// A cap, not a timebase. `preferredFrameRateRange` quantizes to divisors of the display's
    /// refresh rate, so this lands exactly on 120 and 60 Hz panels and on the nearest divisor
    /// elsewhere — 50 fps on a 100 Hz display. Nothing in the tank cares, because nothing in
    /// the tank counts frames.
    override var preferredFPS: Int { 60 }

    override func makeHost(_ context: HostContext) -> RenderHost? {
        // The drawable size, not the view's bounds: the tank's vertical extent is derived from
        // the aspect ratio the camera will actually project into, and the scene re-reads it
        // from every frame, so this only has to be right enough for the opening layout.
        guard let modelURL = AquariumScene.modelURL(in: context.bundle),
              let scene = AquariumScene(modelURL: modelURL, isPreview: context.isPreview,
                                        drawableSize: context.drawableSize)
        else { return nil }

        // The thumbnail runs alongside the rest of System Settings, so it drops the fish
        // count, the marine snow and MSAA. The composition — camera, depth range, fog — is
        // identical, so the preview shows what the saver will actually look like.
        let host = SceneKitHost(device: context.device,
                                scene: scene.scene,
                                pointOfView: scene.cameraNode,
                                sampleCount: context.isPreview ? 1 : 4,
                                clearColor: scene.clearColor)
        host.onUpdate = { [weak scene] frame in scene?.update(frame) }
        // Only the backing scale is worth reacting to here; the drawable's shape reaches the
        // scene every frame through `FrameContext`. This is not optional polish — the scene is
        // always built at a provisional scale of 1, and this is what corrects it.
        host.onResize = { [weak scene] targets in scene?.adopt(backingScale: targets.backingScale) }

        // Held so the scene outlives `makeHost`; the host only retains the `SCNScene`, not
        // the object that drives the school.
        aquarium = scene
        return host
    }
}
