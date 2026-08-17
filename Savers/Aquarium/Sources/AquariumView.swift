// The Aquarium saver's entry point. Everything it does is hand a built tank to the shared
// SceneKit host; the drawable, display link and resize handling all live in `SaverView`.

import AppKit
import Foundation
import ScreenSaver

/// The `@objc` rename is load-bearing. `NSPrincipalClass` in the built bundle is the bare
/// name `AquariumView`, and Swift would otherwise export this as `Aquarium.AquariumView`.
/// Foundation's single-class fallback cannot rescue that here — the bundle contains many
/// classes, so a mismatch just yields a screensaver that refuses to load.
@objc(AquariumView)
final class AquariumView: SaverView {

    private var aquarium: AquariumScene?

    /// Held because the host asks for `configureSheet` on every press of Options, and presents
    /// whatever it is handed without taking ownership of it.
    private var settingsSheet: AquariumSettingsSheet?

    /// Settings for this instance alone, in place of the saved ones.
    ///
    /// Exists for the sheet's live preview, which shows a choice the user has not made yet and
    /// may cancel. Set it before the view is laid out — settings are read once, when the host
    /// is built, which happens on the first layout with a usable size.
    var settingsOverride: AquariumSettings?

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

    /// Silence is not optional when a host says stop.
    ///
    /// The frame-stall guard in `SoundCore` already covers the case this repo was bitten by —
    /// a window ordered out, which fires no callback at all — but that is a backstop for a view
    /// nobody can reach. When a host does say so, the engine should actually go away rather
    /// than be held at zero gain. It is also what closes the `AQUARIUM_AUDIO_RECORD` file:
    /// `tools/run-saver.swift` stops the view before it captures, and a WAV whose header was
    /// never finalised is a recording no tool can open.
    override func stopAnimation() {
        aquarium?.silence()
        super.stopAnimation()
    }

    // MARK: Settings

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let sheet = settingsSheet ?? AquariumSettingsSheet(defaults: saverDefaults)
        settingsSheet = sheet
        // Adopting the new style immediately is what makes OK look like it did something: the
        // thumbnail this sheet was opened from is a live view, and the style is read when the
        // host is built, so without a rebuild it keeps the look it launched with.
        sheet.onCommit = { [weak self] _ in self?.reloadHost() }
        sheet.prepareForPresentation()
        return sheet.window
    }

    override func makeHost(_ context: HostContext) -> RenderHost? {
        // The drawable size, not the view's bounds: the tank's vertical extent is derived from
        // the aspect ratio the camera will actually project into, and the scene re-reads it
        // from every frame, so this only has to be right enough for the opening layout.
        let settings = settingsOverride ?? AquariumSettings.forLaunch(defaults: saverDefaults)
        guard let modelURL = AquariumScene.modelURL(in: context.bundle),
              let scene = AquariumScene(modelURL: modelURL, bundle: context.bundle,
                                        settings: settings, isPreview: context.isPreview,
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
        // The seed badge. It hangs on the renderer rather than on the scene, which is why the
        // scene builds it and this hands it over — see `SeedBadge`.
        host.renderer.overlaySKScene = scene.overlay
        // The window is read here, every frame, because this is the only place in the saver that
        // has one — and it must be re-read rather than captured, since the host changes a view's
        // window level out from under it with no callback when it has finished with the view.
        // `SoundSession.isPresenting` is where that is measured and argued.
        host.onUpdate = { [weak self, weak scene] frame in
            scene?.isPresenting = SoundSession.isPresenting(self?.window)
            scene?.update(frame)
        }
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
