// The tank: a reef on a sand floor, and a mixed school crossing the water above it.
//
// Everything in it is drawn from the model library at launch — see `ModelLibrary` for the
// manifest contract, `ReefLayout` for how the reef is spaced and `School` for the fish. This
// file owns only what is true of the whole tank: the scene, the camera, the light, the water,
// and the per-frame update that drives them.
//
// Still missing from `docs/aquarium-plan.md` §2: caustics, god rays, fish AI and the animated
// props — a chest's lid and a vent's bubbles are declared in the manifests and not yet read.
//
// Everything here is `internal`: SaverKit and the saver's sources compile into one module.

import AppKit
import Foundation
import Metal
import SceneKit
import simd

final class AquariumScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    /// Only reached if HDR is ever turned off — see `SceneKitHost.clearColor`. Kept in step
    /// with the scene background so the two can never disagree.
    static let clearColor = MTLClearColor(red: Tank.water.red, green: Tank.water.green,
                                          blue: Tank.water.blue, alpha: 1)

    /// The sand and everything standing on it, in one node whose origin is the floor. Every
    /// prop is placed in its space, so responding to a reshaped drawable is one assignment
    /// rather than a walk over the reef.
    private let seabed = SCNNode()
    private var school: School?
    private var rand: Rand

    /// Width over height of the drawable. Every vertical extent in the tank is derived from
    /// this, and it is re-read each frame from `FrameContext` because a view can change shape
    /// under a live scene — a display mode change, or the System Settings preview being
    /// resized — and a tank laid out for the old shape would otherwise be half outside the frame.
    private var aspect: Float

    /// How much of the library one launch draws. The preview thumbnail runs alongside the rest
    /// of System Settings, so it takes a thinner tank; the composition is identical.
    private static let propCount = (preview: 12, full: 30)
    private static let anchorCount = (preview: 1, full: 3)
    private static let fishCount = (preview: 8, full: 22)
    /// How many *distinct* models a launch may import — the launch's load budget rather than a
    /// look. Instances are clones and cost almost nothing; each new model is another archive to
    /// read. The school is self-limiting, since a species arrives as a whole school.
    private static let distinctProps = (preview: 5, full: 8)

    /// Locates the model library. Always resolved against the host's bundle — inside a
    /// screensaver `Bundle.main` is `legacyScreenSaver.appex`, so it silently finds nothing.
    ///
    /// It returns a URL rather than the bundle because that is what the view hands to `init`,
    /// and one file is enough: `build-saver.sh` `ditto`s `Assets/` flat into `Resources/`, so
    /// the directory this URL sits in *is* the library. Falling back to the clownfish keeps an
    /// index-less bundle loading, which is what a partially regenerated library looks like.
    static func modelURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "index", withExtension: "json")
            ?? bundle.url(forResource: "clownfish", withExtension: "usdz")
    }

    /// Declared failable to match the host's expectations, and deliberately never nil: a tank
    /// with an unreadable library still renders fogged water, whereas returning nil renders an
    /// unrecoverable black screen. Every model that fails to load simply does not appear.
    init?(modelURL: URL, isPreview: Bool, drawableSize: CGSize) {
        let directory = modelURL.deletingLastPathComponent()
        let library = ModelLibrary.load(from: directory)
        let cache = ModelCache(directory: directory)
        rand = Rand(seed: AquariumScene.launchSeed())

        aspect = Tank.aspect(of: drawableSize)

        buildEnvironment()
        buildCamera()
        if !isPreview { addMarineSnow() }

        seabed.addChildNode(TankFloor.node(.sand))
        let placements = ReefLayout.layout(
            props: library.props,
            count: isPreview ? AquariumScene.propCount.preview : AquariumScene.propCount.full,
            anchors: isPreview ? AquariumScene.anchorCount.preview
                               : AquariumScene.anchorCount.full,
            distinct: isPreview ? AquariumScene.distinctProps.preview
                                : AquariumScene.distinctProps.full,
            aspect: aspect, rand: &rand)
        seabed.addChildNode(Reef.node(placements: placements, cache: cache))
        scene.rootNode.addChildNode(seabed)

        let school = School(
            library: library, cache: cache,
            count: isPreview ? AquariumScene.fishCount.preview : AquariumScene.fishCount.full,
            aspect: aspect, rand: &rand)
        scene.rootNode.addChildNode(school.node)
        self.school = school

        seabed.position = SCNVector3(0, Tank.floorY(aspect: aspect), 0)
    }

    /// A different tank every launch, which is the whole point of drawing one — but tuning a
    /// layout against a reef that reshuffles on every build is guesswork, so `AQUARIUM_SEED`
    /// pins it. The environment is empty under `legacyScreenSaver`, so the override costs
    /// nothing in the only place that matters.
    private static func launchSeed() -> UInt64 {
        if let pinned = ProcessInfo.processInfo.environment["AQUARIUM_SEED"],
           let seed = UInt64(pinned) { return seed }
        return UInt64(bitPattern: Int64(Date().timeIntervalSince1970 * 1000)) ^ 0x5EA_F15
    }

    // MARK: Per-frame update

    func update(_ frame: FrameContext) {
        // Mutating nodes here is only safe because `SceneKitHost` suppresses implicit
        // animation around this call — see the comment there.
        adoptAspect(Tank.aspect(of: frame.drawableSize))
        school?.update(time: frame.time, dt: Float(frame.deltaTime))
    }

    /// Reshapes the tank when the drawable changes shape.
    ///
    /// The floor is stated as a depth rather than as a height precisely so that this is a
    /// single translation: `Tank.floorY` is one half-height at a fixed depth, so it shrinks
    /// with the frustum and the sand stays on the same line across the frame. The reef rides
    /// along as its children.
    ///
    /// The reef keeps the *layout* it was born with, though, and only its height follows. A
    /// prop is fixed in metres, so a reef laid out for 16:9 has near props taller than a 32:9
    /// frame — see `Tank.reefNearDepth(aspect:)`, which is applied when the layout is drawn.
    /// Redrawing it here would mean re-importing models mid-run and popping the whole tank; a
    /// display that changes shape gets a reef that is merely a little large until the next
    /// launch, which is the cheaper of the two failures by a distance.
    private func adoptAspect(_ newAspect: Float) {
        guard newAspect != aspect, newAspect > 0 else { return }
        aspect = newAspect
        seabed.position = SCNVector3(0, Tank.floorY(aspect: aspect), 0)
        school?.adoptAspect(newAspect)
    }

    // MARK: Environment

    private func buildEnvironment() {
        // With `wantsHDR` on, the pass's `MTLClearColor` is discarded and the drawable comes
        // back with alpha 0 — the background has to be stated here or the saver renders over
        // nothing. This is the single most expensive trap in the whole host.
        scene.background.contents = Tank.waterColor

        // Fog colour matches the background exactly so the deepest fish dissolve into the
        // backdrop instead of into a visible wall of a slightly different colour. The floor
        // runs past `fogEnd` for the same reason: sand that simply stopped would be a rim.
        scene.fogColor = Tank.waterColor
        scene.fogStartDistance = CGFloat(Tank.fogStart)
        scene.fogEndDistance = CGFloat(Tank.fogEnd)
        scene.fogDensityExponent = 1.25

        // The rig from the fish spike, re-aimed for a Y-up tank: a cool ambient fill for the
        // water, a warm key from above standing in for the surface, and a blue rim from
        // behind to separate a white fish from a dark background.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.52, alpha: 1)
        ambient.intensity = 360
        scene.rootNode.addChildNode(node(with: ambient))

        let key = SCNLight()
        key.type = .directional
        key.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.88, alpha: 1)
        key.intensity = 900
        key.castsShadow = false
        let keyNode = node(with: key)
        keyNode.eulerAngles = SCNVector3(-1.15, 0.35, 0)
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.color = NSColor(calibratedRed: 0.36, green: 0.68, blue: 0.92, alpha: 1)
        rim.intensity = 420
        let rimNode = node(with: rim)
        rimNode.eulerAngles = SCNVector3(0.35, 2.5, 0)
        scene.rootNode.addChildNode(rimNode)
    }

    private func buildCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = Tank.fieldOfView
        // Pinned horizontal so the framing does not jump between the System Settings
        // thumbnail and the full screen if their aspect ratios differ. The price is that the
        // *vertical* extent then varies with the drawable's shape, which is why every vertical
        // extent in `Tank` takes the real aspect ratio.
        camera.projectionDirection = .horizontal
        camera.zNear = 0.1
        camera.zFar = 60

        // Mandatory for bloom: `bloomIntensity` on its own does literally nothing. It also
        // brings SceneKit's tone mapping, which is what keeps the white fish from clipping.
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.35
        camera.bloomThreshold = 0.9
        camera.bloomBlurRadius = 12
        camera.vignettingIntensity = 0.55
        camera.vignettingPower = 1.4

        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Mid-tank, where snow reads at a useful size against both the near and the far fish.
    private let snowDepth: Float = 14

    private func addMarineSnow() {
        let snow = SCNParticleSystem()
        // Without an image a particle is an opaque square, which at this density reads as
        // static rather than as drifting matter. The sprite is generated rather than shipped
        // so there is no second asset to keep in the bundle.
        snow.particleImage = AquariumScene.softDot()
        snow.birthRate = 32
        snow.particleLifeSpan = 16
        snow.particleSize = 0.013
        snow.particleSizeVariation = 0.007
        snow.particleColor = NSColor(calibratedWhite: 0.78, alpha: 0.28)
        snow.particleColorVariation = SCNVector4(0, 0, 0.1, 0.15)
        snow.particleVelocity = 0.09
        snow.particleVelocityVariation = 0.06
        snow.emittingDirection = SCNVector3(0, -1, 0)
        snow.spreadingAngle = 40
        // Twice the visible height at the emitter's depth. A wider drawable has a *shorter*
        // frustum, and a fixed box would then spend most of its snow off-screen: with the
        // birth rate held constant, matching the box to the frame is what keeps the on-screen
        // density the same on a 32:9 display as on 16:9. Sized once, because replacing the
        // emitter shape restarts every particle already in flight.
        let snowHeight = 4 * Tank.halfHeight(atDepth: snowDepth, aspect: aspect)
        snow.emitterShape = SCNBox(width: 10, height: CGFloat(snowHeight),
                                   length: 16, chamferRadius: 0)
        snow.birthLocation = .volume
        snow.loops = true
        snow.isLightingEnabled = false
        snow.isAffectedByGravity = false
        // Additive particles at any usable density saturate an HDR frame to white. Alpha
        // blending is what keeps a dark tank dark.
        snow.blendMode = .alpha

        let emitter = SCNNode()
        emitter.position = SCNVector3(0, 0, -snowDepth)
        emitter.addParticleSystem(snow)
        scene.rootNode.addChildNode(emitter)
    }

    private static func softDot(diameter: CGFloat = 32) -> NSImage {
        let image = NSImage(size: CGSize(width: diameter, height: diameter))
        image.lockFocus()
        let gradient = NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 1),
                                           NSColor(calibratedWhite: 1, alpha: 0)])
        gradient?.draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)),
                       relativeCenterPosition: .zero)
        image.unlockFocus()
        return image
    }

    private func node(with light: SCNLight) -> SCNNode {
        let node = SCNNode()
        node.light = light
        return node
    }
}
