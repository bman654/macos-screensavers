// The Origami Dogfight saver's entry point: a seeded sim handed to the shared SceneKit host.
// The drawable, display link, idle release and quality ladder all live in `SaverView`.

import AppKit
import Foundation
import ScreenSaver

/// The `@objc` rename is load-bearing: `NSPrincipalClass` in the built bundle is the bare name,
/// and Swift would otherwise export `OrigamiDogfight.OrigamiDogfightView`, which CFBundle
/// silently fails to resolve (`Shared/SaverKit/README.md`).
@objc(OrigamiDogfightView)
final class OrigamiDogfightView: SaverView {

    private var dogfight: DogfightScene?

    /// The fight an idle release or a quality change let go of, kept so the rebuilt scene shows
    /// the same fight carrying on rather than a new one.
    private var resumeSim: DogfightSim?

    /// Half a ProMotion display's rate, as the Aquarium does and for the same reason: this runs
    /// unattended, often on battery, and paper planes crossing a landscape read no differently
    /// at 60. The motion is unaffected by the cap because the sim steps by the clock, never by
    /// frame count — a 50 fps divisor on a 100 Hz panel shows the same fight.
    override var preferredFPS: Int { 60 }

    /// An idle release is a pause and a quality change is the same fight at another budget —
    /// the picker's preview promoted to a real session is the case, and swapping the fight at
    /// the moment it fills the screen would read as the saver restarting. The sim has no
    /// rendering state, so it is kept whole and the new scene redraws it as it stands, wrecks,
    /// fires and shots in flight included. A reload is a request for something new.
    override func didReleaseHost(_ reason: HostReleaseReason) {
        resumeSim = reason == .reload ? nil : dogfight?.sim
        dogfight = nil
    }

    override func makeHost(_ context: HostContext) -> RenderHost? {
        let aspect = Float(context.drawableSize.width / max(context.drawableSize.height, 1))
        let sim: DogfightSim
        if let resumeSim {
            sim = resumeSim
            sim.setAspect(aspect)
        } else {
            let launch = LaunchOptions.fromEnvironment()
            sim = DogfightSim(seed: launch.seed, aspect: aspect, config: launch.config)
            // Fast-forward before the first frame, so a harness screenshot shows a fight in
            // progress rather than an empty sky with planes on their way in.
            sim.advance(steps: Int(launch.warmup / DogfightSim.stepSeconds))
            if launch.lineup { sim.stageLineup() }
        }
        resumeSim = nil

        let scene = DogfightScene(sim: sim, bundle: context.bundle, quality: context.quality)
        // 4x everywhere, the tile included: a `.reduced` frame is magnified to fill its view, so
        // its edges need antialiasing more than a full one's, and four samples of a 720-pixel
        // frame cost a fraction of one of a full-screen one.
        let host = SceneKitHost(device: context.device, scene: scene.scene, pointOfView: scene.cameraNode,
                                sampleCount: 4, clearColor: scene.clearColor)
        // Weak: a host closure that held the scene would keep it — and the view's whole render
        // graph — alive past the release that exists to free it (`docs/saver-host.md` §2).
        host.onUpdate = { [weak scene] frame in scene?.update(frame) }
        dogfight = scene
        return host
    }
}

/// What a run starts with. The environment is empty under `legacyScreenSaver`, so every
/// `ORIGAMI_*` variable is a harness override and costs nothing in the real host.
struct LaunchOptions {
    var seed: UInt64
    var config: SimConfig
    /// Seconds of fight to simulate before the first frame.
    var warmup: Double
    /// `ORIGAMI_LINEUP=1`: a frozen tableau of every model, for checking orientation and scale.
    var lineup = false

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        // Six digits and drawn rather than taken from the clock, as the Aquarium's are: a seed
        // is something a person reads off and types back in, and several displays starting
        // their savers in the same millisecond must not all draw the same landscape.
        let seed = environment["ORIGAMI_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 100_000...999_999)
        let mode = environment["ORIGAMI_MODE"].flatMap { MatchMode(rawValue: $0.lowercased()) }
        let planes = environment["ORIGAMI_PLANES"].flatMap(Int.init).map { min(max($0, 2), 8) }
        let warmup = environment["ORIGAMI_WARMUP"].flatMap(Double.init).map { min(max($0, 0), 600) } ?? 0
        return LaunchOptions(seed: seed, config: SimConfig(mode: mode, planeCount: planes), warmup: warmup,
                             lineup: environment["ORIGAMI_LINEUP"] == "1")
    }
}
