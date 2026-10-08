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

    /// The fight an idle release or a quality change let go of, the countryside around it, and
    /// whether it had its card, kept so the rebuilt scene shows the same fight carrying on in the
    /// same season and light rather than a new one.
    private var resume: (sim: DogfightSim, countryside: Countryside, showsScoreboard: Bool)?
    private var countryside: Countryside?
    private var showsScoreboard = true

    /// The scene a release let go of, held weakly so the next build can say whether it really
    /// went. Under `SAVERKIT_LIFECYCLE` only: it is the in-host proof that nothing — a host
    /// closure, an effect's animation, a node — kept the scene and its render graph alive.
    private weak var releasedScene: DogfightScene?

    /// Held because the host asks for `configureSheet` on every press of Options, and presents
    /// whatever it is handed without taking ownership of it.
    private var settingsSheet: OrigamiSettingsSheet?

    /// Settings for this instance alone, in place of the saved ones: the sheet's live preview,
    /// which shows a choice the user has not made yet and may cancel. Set before the view is laid
    /// out — settings are read when the host is built.
    var settingsOverride: OrigamiSettings?
    /// Seconds of fight to run before the first frame, for a preview that should open on a fight
    /// rather than on planes still arriving.
    var previewWarmup: Double = 0

    /// Half a ProMotion display's rate, as the Aquarium does and for the same reason: this runs
    /// unattended, often on battery, and paper planes crossing a landscape read no differently
    /// at 60. The motion is unaffected by the cap because the sim steps by the clock, never by
    /// frame count — a 50 fps divisor on a 100 Hz panel shows the same fight.
    override var preferredFPS: Int { 60 }

    /// An idle release is a pause and a quality change is the same fight at another budget —
    /// the picker's preview promoted to a real session is the case, and swapping the fight at
    /// the moment it fills the screen would read as the saver restarting. The sim has no
    /// rendering state, so it is kept whole and the new scene redraws it as it stands, wrecks,
    /// fires and shots in flight included. A reload is a request for something new: settings
    /// were changed, and they are read when the sim is made.
    override func didReleaseHost(_ reason: HostReleaseReason) {
        resume = reason == .reload ? nil : dogfight.flatMap { scene in countryside.map { (scene.sim, $0, showsScoreboard) } }
        countryside = nil
        releasedScene = dogfight
        dogfight = nil
    }

    // MARK: Settings

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let sheet = settingsSheet ?? OrigamiSettingsSheet(defaults: saverDefaults)
        settingsSheet = sheet
        // Settings are read when the host is built, so without a rebuild the thumbnail the sheet
        // was opened from would go on showing what it launched with and OK would seem to do nothing.
        sheet.onCommit = { [weak self] _ in self?.reloadHost() }
        sheet.prepareForPresentation()
        return sheet.window
    }

    // MARK: Host

    override func makeHost(_ context: HostContext) -> RenderHost? {
        if LifecycleLog.isEnabled, resume != nil {
            LifecycleLog.emit("origami previous scene freed=\(releasedScene == nil)")
        }
        let aspect = Float(context.drawableSize.width / max(context.drawableSize.height, 1))
        let sim: DogfightSim
        let countryside: Countryside
        if let resume {
            sim = resume.sim
            countryside = resume.countryside
            showsScoreboard = resume.showsScoreboard
            sim.setAspect(aspect)
        } else {
            let launch = LaunchOptions.fromEnvironment()
            let settings = settingsOverride ?? OrigamiSettings.forLaunch(defaults: saverDefaults)
            let atmosphere = settings.atmosphere(seed: launch.seed)
            var config = settings.simConfig(for: atmosphere)
            config.mode = launch.mode
            config.planeCount = launch.planeCount
            showsScoreboard = settings.showsScoreboard
            sim = DogfightSim(seed: launch.seed, aspect: aspect, config: config)
            // Fast-forward before the first frame, so a harness screenshot shows a fight in
            // progress rather than an empty sky with planes on their way in.
            let warmup = settingsOverride == nil ? launch.warmup : previewWarmup
            sim.advance(steps: Int(warmup / DogfightSim.stepSeconds))
            if launch.lineup { sim.stageLineup() }
            if launch.freeze { sim.isFrozen = true }
            countryside = Countryside(sim: sim, atmosphere: atmosphere)
        }
        resume = nil
        self.countryside = countryside

        let scene = DogfightScene(sim: sim, countryside: countryside, bundle: context.bundle, device: context.device,
                                  quality: context.quality, showsScoreboard: showsScoreboard)
        // 4x everywhere, the tile included: a `.reduced` frame is magnified to fill its view, so
        // its edges need antialiasing more than a full one's, and four samples of a 720-pixel
        // frame cost a fraction of one of a full-screen one.
        let host = SceneKitHost(device: context.device, scene: scene.scene, pointOfView: scene.cameraNode,
                                sampleCount: 4, clearColor: scene.clearColor)
        // Weak: a host closure that held the scene would keep it — and the view's whole render
        // graph — alive past the release that exists to free it (`docs/saver-host.md` §2).
        host.onUpdate = { [weak scene] frame in scene?.update(frame) }
        // The scene is built at a provisional scale of 1, before the view has a window; this is
        // what tells the scoreboard how many pixels a point really is.
        host.onResize = { [weak scene] targets in scene?.adopt(backingScale: targets.backingScale) }
        dogfight = scene
        return host
    }
}

/// What a run starts with beyond the settings. The environment is empty under
/// `legacyScreenSaver`, so every `ORIGAMI_*` variable here is a harness override and costs
/// nothing in the real host.
struct LaunchOptions {
    var seed: UInt64
    /// `ORIGAMI_MODE` (ffa / teams2 / teams3): an exact mode, beyond what the sheet offers.
    var mode: MatchMode?
    /// `ORIGAMI_PLANES`: an exact plane count, 2 to 12.
    var planeCount: Int?
    /// Seconds of fight to simulate before the first frame.
    var warmup: Double
    /// `ORIGAMI_LINEUP=1`: a frozen tableau of every model, for checking orientation and scale.
    var lineup = false
    /// `ORIGAMI_FREEZE=1`: hold the fight at the end of the warmup, so a seed and a warmup name
    /// one exact picture — what `tools/build-origami-thumbnail.sh` needs to be reproducible.
    var freeze = false

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        // Six digits and drawn rather than taken from the clock, as the Aquarium's are: a seed
        // is something a person reads off and types back in, and several displays starting
        // their savers in the same millisecond must not all draw the same landscape.
        let seed = environment["ORIGAMI_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 100_000...999_999)
        let mode = environment["ORIGAMI_MODE"].flatMap { MatchMode(rawValue: $0.lowercased()) }
        let planes = environment["ORIGAMI_PLANES"].flatMap(Int.init).map { min(max($0, 2), 12) }
        // Finite only: `Double("nan")` parses, survives min and max, and traps converting to a
        // step count.
        let warmup = environment["ORIGAMI_WARMUP"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            .map { min(max($0, 0), 600) } ?? 0
        return LaunchOptions(seed: seed, mode: mode, planeCount: planes, warmup: warmup,
                             lineup: environment["ORIGAMI_LINEUP"] == "1",
                             freeze: environment["ORIGAMI_FREEZE"] == "1")
    }
}
