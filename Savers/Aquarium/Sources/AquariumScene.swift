// The tank: a reef on a sand floor, and a mixed school crossing the water above it.
//
// Everything in it is drawn from the model library at launch — see `ModelLibrary` for the
// manifest contract, `ReefLayout` for how the reef is spaced and `School` for the fish. This
// file owns only what is true of the whole tank: the scene, the camera, the light, the water,
// and the per-frame update that drives them.
//
// Everything here is `internal`: SaverKit and the saver's sources compile into one module.

import AppKit
import Foundation
import Metal
import SceneKit
import SpriteKit
import simd

final class AquariumScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    /// Only reached if HDR is ever turned off — see `SceneKitHost.clearColor`. Kept in step
    /// with the scene background so the two can never disagree. An instance property because
    /// the water's colour belongs to the style, and the style is drawn at launch.
    let clearColor: MTLClearColor

    /// The seed badge, or nil when the user has it switched off. Handed to the renderer by
    /// `AquariumView`, because the overlay is the *renderer's* property rather than the scene's
    /// — there is nowhere on an `SCNScene` to hang one.
    private(set) var overlay: SKScene?

    /// What kind of tank this launch is, and therefore how big it is, how densely it is
    /// decorated, what its floor is made of and how it is lit.
    private let style: TankStyle
    private var tank: Tank { style.tank }

    /// The sand and everything standing on it, in one node whose origin is the floor. Every
    /// prop is placed in its space, so responding to a reshaped drawable is one assignment
    /// rather than a walk over the reef.
    private let seabed = SCNNode()
    private var school: School?
    private var bubblers: [Bubbler] = []
    private var rand: Rand

    /// The tank's voice, or nil when the user has sound switched off — which is the default,
    /// and which is also what a thumbnail always gets. Nil costs nothing anywhere: the grain
    /// library is never read, `School.onSwish` stays unset, and no audio device is opened.
    private var sound: AquariumSound?

    /// The key light's gobo, held so the caustic net can be drifted each frame, and nil for a
    /// look with no caustics. It is the light's property rather than a node, because what moves
    /// is the pattern's texture transform and not the lamp.
    private var causticGobo: SCNMaterialProperty?

    /// The shafts, held so they can be swayed each frame, and nil for a look with none. They sit
    /// under the root rather than under `seabed`, because they belong to the water column and
    /// must not follow the floor when the drawable reshapes.
    private var godRays: GodRayField?

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
    init?(modelURL: URL, bundle: Bundle, settings: AquariumSettings, isPreview: Bool,
          drawableSize: CGSize) {
        let directory = modelURL.deletingLastPathComponent()
        let library = ModelLibrary.load(from: directory)
        let cache = ModelCache(directory: directory)
        let seed = AquariumScene.launchSeed(pinned: settings.seed)
        rand = Rand(seed: seed)
        // Never in the thumbnail. It is 384x216 in the settings sheet and smaller again in the
        // Screen Saver list, where the badge would be either illegible or — sized to stay
        // legible — a caption across a picture of a tank.
        if settings.showsSeed && !isPreview {
            overlay = SeedBadge.overlay(seed: seed, drawableSize: drawableSize)
        }

        // Drawn first, and from the launch stream rather than a fork, because the ocean's own
        // dimensions are part of the draw and everything below is measured against them. Which
        // style it is comes from a stream of its own — see `AquariumSettings.styleName`.
        style = TankStyle.draw(settings.styleName(seed: seed), seed: seed, rand: &rand)
        clearColor = MTLClearColor(red: style.water.tint.red, green: style.water.tint.green,
                                   blue: style.water.tint.blue, alpha: 1)
        aspect = Tank.aspect(of: drawableSize)

        buildEnvironment()
        buildCamera()
        if !isPreview && style.water.snowBirthRate > 0 { addMarineSnow() }
        // Drawn in the preview too, unlike the marine snow.
        //
        // They were skipped there at first, on the reasoning that a shaft reads as a smudge at
        // thumbnail size. That is the wrong trade for this particular feature: the settings
        // sheet's preview exists to show what a look actually is, and the shafts are the whole
        // of what distinguishes the deep ocean now — so a preview without them offered a choice
        // between three tanks while showing only two of them apart. The caustics were never
        // skipped, because they ride the key light, and the inconsistency was visible: picking
        // the reef or the aquarium showed a dappled floor and picking the deep ocean showed
        // nothing new at all. Snow stays out because it is texture rather than identity.
        if let rays = style.water.godRays {
            // A stream of its own, taken off the seed rather than off the launch stream. A draw
            // from `rand` here would reshuffle the reef and the school below it, so every seeded
            // render made before the shafts existed would name a different tank — and both tanks
            // would be plausible, which is what makes that failure silent. Same discipline as
            // the style and the gravel palette.
            var rayRand = Rand(seed: seed ^ 0x9A_17_5A_4F_0B_2E)
            let field = GodRayField(rays, look: style.water, tank: tank,
                                    aspect: aspect, rand: &rayRand)
            scene.rootNode.addChildNode(field.node)
            godRays = field
        }

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
        let reef = Reef.build(placements: placements, cache: cache)
        seabed.addChildNode(reef.node)

        // The thumbnail still runs every hinge cycle: transforms are free enough to show what the
        // decoration is, while particle systems add setup and simulation to a preview already
        // measured at 234–354 ms to build. Full-size tanks get both pieces of the authored act.
        // This stream is forked directly from the launch seed rather than consuming `rand`, so
        // adding animation cannot silently rename every fish and prop drawn after the reef.
        var bubblerRand = Rand(seed: seed ^ 0xB0_BB_1E_5A_71_0F)
        for prop in reef.props where prop.manifest.isAnimated {
            bubblers.append(Bubbler(prop: prop, reefNode: reef.node,
                                    particlesEnabled: !isPreview, rand: &bubblerRand))
        }
        scene.rootNode.addChildNode(seabed)

        let fish = isPreview ? AquariumScene.fishCount.preview : AquariumScene.fishCount.full
        let surface = SurfaceField(props: reef.props)
        let hosts = FishHost.hosts(in: reef.props)
        let passages = SwimPassage.passages(in: reef.props, reefNode: reef.node)
        let school = School(
            library: library, cache: cache,
            count: style.tank.schoolCount(fish),
            tank: style.tank, aspect: aspect, surface: surface, hosts: hosts,
            passages: passages, rand: &rand)
        scene.rootNode.addChildNode(school.node)
        self.school = school

        // Skipped for anything this build can tell is a thumbnail, which is not all of them.
        //
        // What is *heard* is decided entirely by the session gate in `SoundSession`; no property
        // of a view can answer that, and this test does not try to. It is about cost — a tile
        // has no business reading two megabytes of grains, and the settings sheet builds a fresh
        // tank on every click. It is also known to be incomplete: the spike measured Tahoe's
        // picker tile as a full-screen-sized view, so `isPreview` is false there and those tiles
        // do pay for a grain library they will never play. That is the same unfixed signal that
        // has the picker drawing full-fat tanks, and it wants one pass covering both.
        if settings.soundEnabled && !isPreview,
           let sound = AquariumSound(bundle: bundle, seed: seed) {
            school.swishThreshold = sound.minimumEffort
            school.swishTurnShare = sound.turnShare
            school.perFishSwishCooldown = sound.perFishCooldown
            school.onSwish = { event in
                sound.swish(bodyLength: event.bodyLength, pan: event.pan,
                            nearness: event.nearness, strength: event.strength,
                            isDart: event.isDart)
            }
            self.sound = sound
        }

        seabed.position = SCNVector3(0, tank.floorY(aspect: aspect), 0)
    }

    /// A different tank every launch, which is the whole point of drawing one — but tuning a
    /// layout against a reef that reshuffles on every build is guesswork, so it can be pinned:
    /// by `AQUARIUM_SEED` for this repo's render loop, and by the settings sheet for a user
    /// watching the real screensaver. The environment wins, and is empty under
    /// `legacyScreenSaver`, so the override costs nothing in the only place that matters.
    static func launchSeed(pinned: UInt64? = nil) -> UInt64 {
        if let fromEnvironment = ProcessInfo.processInfo.environment["AQUARIUM_SEED"],
           let seed = UInt64(fromEnvironment) { return seed }
        if let pinned { return pinned }
        return UInt64.random(in: AquariumScene.drawnSeeds)
    }

    /// Six digits, and drawn rather than derived from the clock.
    ///
    /// Both halves are for the human in the loop. A seed exists to be *transcribed* — read off
    /// the corner of a tank onto paper and typed back into the settings sheet — and the old
    /// millisecond-clock value was thirteen digits, which is a number people copy wrongly. A
    /// million tanks is far more than anyone will ever draw. Deriving it from the clock was
    /// also quietly wrong on a multi-display machine, where every screen instantiates its own
    /// saver within the same millisecond and would draw the same tank.
    ///
    /// Nothing downstream cares about the range: `AQUARIUM_SEED` still accepts any `UInt64`,
    /// so every seeded render on record — `42`, `4` — still names the tank it always did.
    private static let drawnSeeds: ClosedRange<UInt64> = 100_000...999_999

    // MARK: Per-frame update

    func update(_ frame: FrameContext) {
        // Mutating nodes here is only safe because `SceneKitHost` suppresses implicit
        // animation around this call — see the comment there.
        adoptAspect(Tank.aspect(of: frame.drawableSize))
        if let overlay { SeedBadge.resize(overlay, to: frame.drawableSize) }
        school?.update(time: frame.time, dt: Float(frame.deltaTime))
        bubblers.forEach { $0.update(dt: Float(frame.deltaTime)) }
        driftCaustics(time: frame.time)
        swayGodRays(time: frame.time)
        if let sound {
            // After the bubblers, so the rate the ear is given is the one the eye is being
            // shown this frame rather than the previous one's.
            sound.setEmission(declaredRate: bubblers.reduce(0) { $0 + $1.emissionRate })
            sound.update(time: frame.time)
        }
    }

    /// Stops the tank's voice and closes anything it was recording.
    func silence() {
        sound?.stop()
    }

    /// Crawls the caustic net across the floor.
    ///
    /// Translating the gobo's texture transform rather than moving the light, because moving the
    /// light would swing where every shadow and highlight in the tank falls. With the gobo set
    /// to repeat, a translation of any size stays seamless.
    ///
    /// The two axes drift at different rates on purpose. Equal rates make the net travel along a
    /// 45° diagonal, and a pattern with a single direction of travel reads as a sheet being
    /// pulled across the tank; unequal ones keep it from lining up with anything.
    private func driftCaustics(time: TimeInterval) {
        guard let gobo = causticGobo, let caustics = style.water.caustics else { return }
        let t = CGFloat(time) * caustics.drift
        gobo.contentsTransform = SCNMatrix4MakeTranslation(t, t * 0.61, 0)
    }

    /// Ticks the curtain's clock. All the motion lives in the field's own shader — folds pulse
    /// and exchange by interference — so this passes the scene's time and nothing else, which is
    /// what keeps a seeded render at a given second reproducible.
    private func swayGodRays(time: TimeInterval) {
        godRays?.update(time: time)
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

        // The key carries the caustics, because the key is the light a caustic is *made of* —
        // the net on the floor is the surface overhead focusing that same lamp. Hanging it here
        // rather than on a surface also means it lands on the props and on the fish for free.
        let keyNode = directional(water.key, castsShadow: false)
        if let caustics = water.caustics { attach(caustics, to: keyNode.light!) }
        scene.rootNode.addChildNode(keyNode)
        scene.rootNode.addChildNode(directional(water.rim, castsShadow: false))
        // Optional, and only the aquarium has one — a low warm source for the things standing
        // up in a tank whose every other light is blue. See `WaterLook.accent`.
        if let accent = water.accent {
            scene.rootNode.addChildNode(directional(accent, castsShadow: false))
        }
    }

    /// Hangs the caustic net on a light, and pays for it.
    ///
    /// The compensation is the part that must not be skipped: a gobo multiplies its light by the
    /// tile's own mean, so a pattern averaging 0.5 would halve everything this lamp delivers and
    /// drag the floor-versus-water ratio down with it. Scaling the intensity back up by 1/mean
    /// is what lets `WaterLook` go on stating the light the lamp delivers rather than the light
    /// it would deliver if the gobo were white — which is the number every substrate in this
    /// saver was balanced against.
    private func attach(_ caustics: Caustics, to light: SCNLight) {
        let tile = CausticPattern.tile(contrast: caustics.strength)
        guard let image = CausticTexture.image(from: tile.values), let gobo = light.gobo else {
            // A tile that cannot be encoded is a tank with no caustics, which is the look as it
            // was before this existed. Silently lighting it at 1/mean without the pattern would
            // be a tank lit twice as brightly as intended.
            return
        }
        gobo.contents = image
        gobo.wrapS = .repeat
        gobo.wrapT = .repeat
        gobo.intensity = 1
        // The floor is seen almost edge-on, which is what erased the substrate's own texture
        // until it was made anisotropic. The net projected onto it is sampled just as obliquely.
        gobo.maxAnisotropy = 16
        light.orthographicScale = caustics.orthographicScale
        light.intensity *= Caustics.compensation(forMean: tile.mean)
        causticGobo = gobo
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
