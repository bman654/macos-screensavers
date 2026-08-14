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
    /// with the scene background so the two can never disagree. An instance property because
    /// the water's colour belongs to the style, and the style is drawn at launch.
    let clearColor: MTLClearColor

    /// What kind of tank this launch is, and therefore how big it is, how densely it is
    /// decorated, what its floor is made of and how it is lit.
    private let style: TankStyle
    private var tank: Tank { style.tank }

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

    /// Pixels per point, used only to keep the bloom the same apparent size on a Retina
    /// display as on a conventional one — see `buildCamera` and `adopt(backingScale:)`.
    ///
    /// Starts at 1 and is corrected before the first frame, because the scene is built before
    /// the view is in a window and therefore before its true scale is knowable. A var for the
    /// same reason it cannot be a parameter: a live view moves between scales when a display
    /// is attached, mirrored or unplugged.
    private var backingScale: CGFloat = 1

    /// How much of the library the *reference* tank draws. The preview thumbnail runs alongside
    /// the rest of System Settings, so it takes a thinner tank; the composition is identical.
    ///
    /// Both counts are then adjusted for the tank actually drawn: props by the style's declared
    /// density, fish by the tank's own size — see `TankStyle.propDensity` and
    /// `Tank.schoolCount`. Neither adjustment belongs here, because neither is a property of
    /// the preview.
    private static let propCount = (preview: 12, full: 30)
    private static let fishCount = (preview: 8, full: 22)
    /// The preview's share of the style's distinct-model budget, which is the launch's load
    /// budget rather than a look. Instances are clones and cost almost nothing; each new model
    /// is another archive to read. The school is self-limiting, since a species arrives as a
    /// whole school.
    private static let previewDistinctShare: Float = 0.625

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

        // Drawn first, and from the launch stream rather than a fork, because the ocean's own
        // dimensions are part of the draw and everything below is measured against them.
        style = TankStyle.draw(TankStyle.launchStyle(), rand: &rand)
        clearColor = MTLClearColor(red: style.water.tint.red, green: style.water.tint.green,
                                   blue: style.water.tint.blue, alpha: 1)
        aspect = Tank.aspect(of: drawableSize)

        buildEnvironment()
        buildCamera()
        if !isPreview && style.water.snowBirthRate > 0 { addMarineSnow() }

        seabed.addChildNode(TankFloor.node(style.substrate, tank: style.tank))
        let props = isPreview ? AquariumScene.propCount.preview : AquariumScene.propCount.full
        let budget = isPreview
            ? max(3, Int((Float(style.distinctProps) * AquariumScene.previewDistinctShare)
                    .rounded()))
            : style.distinctProps
        let placements = ReefLayout.layout(
            props: library.props,
            count: style.tank.propCount(props, density: style.propDensity, aspect: aspect),
            anchors: isPreview ? 1 : style.anchorCount,
            distinct: budget,
            tank: style.tank, slack: style.spacingSlack, aspect: aspect, rand: &rand)
        seabed.addChildNode(Reef.node(placements: placements, cache: cache))
        scene.rootNode.addChildNode(seabed)

        let fish = isPreview ? AquariumScene.fishCount.preview : AquariumScene.fishCount.full
        let school = School(
            library: library, cache: cache,
            count: style.tank.schoolCount(fish),
            tank: style.tank, aspect: aspect, rand: &rand)
        scene.rootNode.addChildNode(school.node)
        self.school = school

        seabed.position = SCNVector3(0, tank.floorY(aspect: aspect), 0)
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

    /// Retunes the one thing in the tank that is measured in pixels, when the view moves to a
    /// display of a different scale. Everything else here is in metres or in fractions of the
    /// frame and does not care.
    func adopt(backingScale newScale: CGFloat) {
        guard newScale != backingScale, newScale > 0 else { return }
        backingScale = newScale
        cameraNode.camera?.bloomBlurRadius = style.water.bloomBlurRadius * newScale
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
        seabed.position = SCNVector3(0, tank.floorY(aspect: aspect), 0)
        school?.adoptAspect(newAspect)
    }

    // MARK: Environment

    private func buildEnvironment() {
        // With `wantsHDR` on, the pass's `MTLClearColor` is discarded and the drawable comes
        // back with alpha 0 — the background has to be stated here or the saver renders over
        // nothing. This is the single most expensive trap in the whole host.
        let water = style.water
        scene.background.contents = water.backgroundContents

        // Without this, every metal in the tank reads as rock. A metallic PBR surface takes
        // almost all of its colour from what it reflects, so with no environment it has nothing
        // to reflect, collapses to its dark specular response, and the diving suit's brass
        // helmet comes out the same dull olive as the boulder beside it. The three directional
        // lights below cannot stand in: they give metal highlights, not an environment.
        //
        // It also contributes diffuse light to *everything*, and the matte rock and coral are
        // most of the scene — so its intensity is part of the budget the substrate is balanced
        // against, and changing it means re-running `tools/water-luminance.py`.
        scene.lightingEnvironment.contents = water.environmentContents
        scene.lightingEnvironment.intensity = water.environment.intensity

        // Fog colour matches the background exactly so the deepest fish dissolve into the
        // backdrop instead of into a visible wall of a slightly different colour. The surface
        // ramp above is built to respect that: it reaches the flat water colour at the horizon
        // and holds it below, so the only backdrop it brightens is backdrop the fog never
        // touches. The floor runs past `fogEnd` for the same reason: sand that simply stopped
        // would be a rim.
        //
        // The distances are the *tank's*, not the look's — they are the only numbers in this
        // whole rig that would have to be stated in metres against a tank of a particular size,
        // and the tank's size is drawn per launch. Only the fog's shape belongs to the water.
        scene.fogColor = water.color
        scene.fogStartDistance = CGFloat(tank.fogStart)
        scene.fogEndDistance = CGFloat(tank.fogEnd)
        scene.fogDensityExponent = water.fogDensityExponent

        // A fill standing in for light scattered by the water itself, a key standing in for
        // whatever is overhead — the surface in an ocean, a hood lamp in a tank — and a rim from
        // behind to separate a pale fish from the backdrop. Which colours and intensities those
        // are is `WaterLook`'s business and not this function's: nothing here may grow a
        // literal, or the styles stop being interchangeable.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = water.ambient.color
        ambient.intensity = water.ambient.intensity
        scene.rootNode.addChildNode(node(with: ambient))

        scene.rootNode.addChildNode(directional(water.key, castsShadow: false))
        scene.rootNode.addChildNode(directional(water.rim, castsShadow: false))
    }

    private func directional(_ spec: WaterLook.Light, castsShadow: Bool) -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.color = spec.color
        light.intensity = spec.intensity
        light.castsShadow = castsShadow
        let node = node(with: light)
        node.eulerAngles = spec.euler
        return node
    }

    private func buildCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = tank.fieldOfView
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
        camera.bloomIntensity = style.water.bloomIntensity
        camera.bloomThreshold = style.water.bloomThreshold
        // The look's radius as authored, i.e. at 1x; `adopt(backingScale:)` scales it to the
        // display before the first frame. `bloomBlurRadius` is documented in points but
        // SceneKit applies it in render-target pixels — a probe rendering one emissive quad of
        // fixed frame fraction at 512, 1024 and 2048 px measured the same 24 px halo at all
        // three — so unscaled, a look tuned on a conventional display arrives on a Retina one
        // with its glow at half the apparent width.
        camera.bloomBlurRadius = style.water.bloomBlurRadius * backingScale
        camera.vignettingIntensity = style.water.vignettingIntensity
        camera.vignettingPower = style.water.vignettingPower

        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Mid-tank, where snow reads at a useful size against both the near and the far fish.
    private var snowDepth: Float { tank.nearDepth + 0.45 * (tank.farDepth - tank.nearDepth) }

    private func addMarineSnow() {
        let snow = SCNParticleSystem()
        // Without an image a particle is an opaque square, which at this density reads as
        // static rather than as drifting matter. The sprite is generated rather than shipped
        // so there is no second asset to keep in the bundle.
        snow.particleImage = AquariumScene.softDot()
        snow.birthRate = style.water.snowBirthRate
        snow.particleLifeSpan = 16
        // Suspended matter is scenery, not wildlife: like every decoration it holds its
        // on-screen size rather than its metres, so a close-in tank gets physically finer
        // flecks drifting at a proportionally slower real speed and the frame looks the same.
        let grain = CGFloat(tank.propScale)
        snow.particleSize = 0.013 * grain
        snow.particleSizeVariation = 0.007 * grain
        snow.particleColor = NSColor(calibratedWhite: 0.78, alpha: style.water.snowAlpha)
        snow.particleColorVariation = SCNVector4(0, 0, 0.1, 0.15)
        snow.particleVelocity = 0.09 * grain
        snow.particleVelocityVariation = 0.06 * grain
        snow.emittingDirection = SCNVector3(0, -1, 0)
        snow.spreadingAngle = 40
        // Twice the visible height at the emitter's depth. A wider drawable has a *shorter*
        // frustum, and a fixed box would then spend most of its snow off-screen: with the
        // birth rate held constant, matching the box to the frame is what keeps the on-screen
        // density the same on a 32:9 display as on 16:9. Sized once, because replacing the
        // emitter shape restarts every particle already in flight.
        let snowDepth = self.snowDepth
        let snowHeight = 4 * tank.halfHeight(atDepth: snowDepth, aspect: aspect)
        snow.emitterShape = SCNBox(width: CGFloat(3.7 * tank.halfWidth(atDepth: snowDepth)),
                                   height: CGFloat(snowHeight),
                                   length: CGFloat(tank.farDepth - tank.nearDepth) * 0.82,
                                   chamferRadius: 0)
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
