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

        // Held so the scene outlives `makeHost`; the host only retains the `SCNScene`, not
        // the object that drives the school.
        aquarium = scene
        return host
    }
}
