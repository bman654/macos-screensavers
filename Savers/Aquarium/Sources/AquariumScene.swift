// The tank: a school of clownfish swimming through fogged water at a range of depths.
//
// This is the shell proof, not the finished aquarium. There are no plants, rocks, caustics
// or god rays yet, and the model is still untextured flat white because the Cycles bake step
// in `docs/aquarium-plan.md` is unfinished. What it does prove is that the whole chain —
// USDZ in the bundle, the skeleton-free swim modifier, depth fog, HDR and particles — runs
// inside `SaverView`'s drawable.
//
// Everything here is `internal`: SaverKit and the saver's sources compile into one module.

import AppKit
import Foundation
import Metal
import SceneKit
import simd

// MARK: - Swim deformation

/// A travelling sine wave down the body, applied in the vertex stage.
///
/// Proven in `spikes/001-fish-pipeline`. It works in the mesh's own object space, which is
/// only valid because the fish is exported as a single joined mesh — reaching for world
/// space via `u_modelTransform` inside a geometry modifier produces shredded geometry and a
/// magenta surface, with no diagnostic. The `tailward²` envelope holds the head steady; a
/// fish that translates bodily side to side reads as a bar of soap.
private let swimModifier = """
#pragma arguments
float swimPhase;
float swimAmplitude;
float swimWaves;
float bodyMinX;
float bodyLength;

#pragma body
float tailward = clamp((bodyMinX + bodyLength - _geometry.position.x) / bodyLength, 0.0, 1.0);
float envelope = tailward * tailward;
_geometry.position.y += sin(tailward * swimWaves * 6.2831853 - swimPhase)
                      * swimAmplitude * envelope;
"""

// MARK: - Tank constants

private enum Tank {
    /// Narrow enough to read as near-orthographic 2.5D, wide enough that the depth lanes
    /// still show parallax. Fixed by `docs/aquarium-plan.md`.
    static let fieldOfView: CGFloat = 22
    static let halfFOVTangent = Float(tan(fieldOfView * .pi / 180 / 2))

    /// `projectionDirection` is pinned horizontal, so the horizontal extent is fixed by the
    /// field of view alone and it is the *vertical* extent that shrinks as the drawable gets
    /// wider — half-height is exactly half-width divided by the aspect ratio, verified against
    /// the matrix `SCNCamera.projectionTransform(withViewportSize:)` actually builds. Vertical
    /// placement therefore has to come from the real drawable: on a 32:9 display the visible
    /// half-height is barely half of what 16:9 gives, and fish laid out against an assumed
    /// 16:9 spend whole crossings outside the frame.
    static let verticalFill: Float = 0.62

    /// Used only for a degenerate drawable size, which `SaverView` should never hand over.
    static let fallbackAspect: Float = 16.0 / 9.0

    /// Depth range the school occupies, in metres in front of the camera. The near limit is
    /// far enough back that a fish leaving the tank does so off-screen rather than popping.
    static let nearDepth: Float = 5.5
    static let farDepth: Float = 25.0
    static let depthCullNear: Float = 4.6
    static let depthCullFar: Float = 27.0

    /// Body length in metres. At the near depth this spans roughly a fifth of the frame and
    /// at the far depth about a twentieth, which is the range that makes fog legible.
    static let fishLength: Float = 0.42

    /// Screen-space speed is what the eye judges, and that is angular — so world speed has to
    /// grow with depth or the far fish crawl.
    static let speedPerDepth: Float = 0.023

    static let water = (red: 0.028, green: 0.094, blue: 0.112)
    static let waterColor = NSColor(calibratedRed: CGFloat(water.red), green: CGFloat(water.green),
                                    blue: CGFloat(water.blue), alpha: 1)

    static func halfWidth(atDepth depth: Float) -> Float { depth * halfFOVTangent }

    static func halfHeight(atDepth depth: Float, aspect: Float) -> Float {
        halfWidth(atDepth: depth) / aspect
    }

    static func aspect(of drawableSize: CGSize) -> Float {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return fallbackAspect }
        return Float(drawableSize.width / drawableSize.height)
    }
}

// MARK: - Deterministic RNG

/// Seeded so a layout that looked right in a render is the same layout next launch; tuning
/// numbers against a school that reshuffles every run is guesswork.
private struct Rand {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }

    mutating func inRange(_ lower: Float, _ upper: Float) -> Float {
        lower + (upper - lower) * next()
    }

    mutating func sign() -> Float { next() < 0.5 ? -1 : 1 }
}

// MARK: - One fish

private final class Fish {
    let node: SCNNode
    /// Held directly because the swim phase is a material uniform, and walking the hierarchy
    /// to find them again every frame would be the most expensive thing in the update.
    let materials: [SCNMaterial]

    var position = SIMD3<Float>(repeating: 0)
    var velocity = SIMD3<Float>(repeating: 0)
    var beat: Float = 1.5
    var phaseOffset: Float = 0
    var bobRate: Float = 0.3
    var bobPhase: Float = 0
    var bobAmplitude: Float = 0

    init(node: SCNNode, materials: [SCNMaterial]) {
        self.node = node
        self.materials = materials
    }
}

// MARK: - The scene

final class AquariumScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    /// Only reached if HDR is ever turned off — see `SceneKitHost.clearColor`. Kept in step
    /// with the scene background so the two can never disagree.
    static let clearColor = MTLClearColor(red: Tank.water.red, green: Tank.water.green,
                                          blue: Tank.water.blue, alpha: 1)

    private var fishes: [Fish] = []
    private var rand = Rand(seed: 0x5EA_F15)

    /// Width over height of the drawable. Every vertical extent in the tank is derived from
    /// this, and it is re-read each frame from `FrameContext` because a view can change shape
    /// under a live scene — a display mode change, or the System Settings preview being
    /// resized — and fish laid out for the old shape would otherwise be left outside the frame.
    private var aspect: Float

    /// Locates the school's asset. Always resolved against the host's bundle — inside a
    /// screensaver `Bundle.main` is `legacyScreenSaver.appex`, so it silently finds nothing.
    static func modelURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "clownfish", withExtension: "usdz")
    }

    /// Returns nil when the model cannot be loaded, so the saver degrades to black instead of
    /// trapping — a crashed screensaver is an unrecoverable black screen for the user anyway,
    /// but a trap also takes `legacyScreenSaver` down with it.
    init?(modelURL: URL, isPreview: Bool, drawableSize: CGSize) {
        guard let imported = try? SCNScene(url: modelURL, options: nil),
              let (minBound, maxBound) = AquariumScene.worldBounds(of: imported.rootNode)
        else { return nil }

        // `SCNVector3` is CGFloat-componented on macOS; everything downstream is Float.
        let bodyLength = Float(maxBound.x - minBound.x)
        guard bodyLength > 0 else { return nil }

        aspect = Tank.aspect(of: drawableSize)

        buildEnvironment()
        buildCamera()
        if !isPreview { addMarineSnow() }

        let template = imported.rootNode.clone()
        let center = SCNVector3((minBound.x + maxBound.x) / 2,
                                (minBound.y + maxBound.y) / 2,
                                (minBound.z + maxBound.z) / 2)
        let count = isPreview ? 6 : 14
        for index in 0..<count {
            let fish = makeFish(from: template, center: center,
                                bodyMinX: Float(minBound.x), bodyLength: bodyLength)
            place(fish, spawningOffScreen: false,
                  stratum: (Float(index) + 0.5) / Float(count))
            // Spread the tail beats so a school of clones does not pulse in unison.
            fish.phaseOffset = Float(index) / Float(count) * 2 * .pi
            fishes.append(fish)
            scene.rootNode.addChildNode(fish.node)
        }
    }

    // MARK: Per-frame update

    func update(_ frame: FrameContext) {
        // Mutating nodes here is only safe because `SceneKitHost` suppresses implicit
        // animation around this call — see the comment there.
        let dt = Float(frame.deltaTime)
        adoptAspect(Tank.aspect(of: frame.drawableSize))

        for fish in fishes {
            fish.position += fish.velocity * dt
            if hasLeftTank(fish) { place(fish, spawningOffScreen: true) }

            let bob = sin(AquariumScene.wrappedPhase(frame.time, rate: fish.bobRate,
                                                     offset: fish.bobPhase))
                * fish.bobAmplitude
            fish.node.position = SCNVector3(fish.position.x,
                                            fish.position.y + bob,
                                            fish.position.z)

            let phase = AquariumScene.wrappedPhase(frame.time, rate: fish.beat * 2 * .pi,
                                                   offset: fish.phaseOffset)
            for material in fish.materials {
                material.setValue(NSNumber(value: phase), forKey: "swimPhase")
            }

            // The wave displaces the body laterally, which for a fish swimming across the
            // frame is almost straight into the camera and therefore nearly invisible. Real
            // fish also yaw their heads in recoil against the tail; borrowing that here is
            // what makes the deformation read from the front-on view of the tank.
            let recoil = 0.10 * sin(phase)
            fish.node.eulerAngles = SCNVector3(0, headingYaw(of: fish.velocity) + recoil, 0)
        }
    }

    /// Evaluates `time * rate + offset` in `Double` and reduces it into one period before it
    /// is narrowed to the `Float` the sine and the material uniform carry.
    ///
    /// A screensaver on an unattended machine runs for days, and an ever-growing `Float` clock
    /// loses timing resolution as it does: at 48 hours its ULP is already 1/64 s, so the
    /// fastest tail beats start advancing in visibly uneven steps, and by a week barely a
    /// quarter of the frames at 60 Hz land on a distinct value — the school stutters. Wrapping
    /// after the conversion cannot recover precision the conversion already discarded, so the
    /// reduction has to happen here, in `Double`. It is seamless because a phase is periodic:
    /// every consumer of this value is a sine, for which 2π is an exact period.
    ///
    /// Per fish rather than once for the whole school: the beats are unrelated reals, so there
    /// is no shared time period that is a whole number of cycles for all of them.
    private static func wrappedPhase(_ time: CFTimeInterval, rate: Float, offset: Float) -> Float {
        let phase = time * Double(rate) + Double(offset)
        return Float(phase.truncatingRemainder(dividingBy: 2 * .pi))
    }

    // MARK: Fish construction and motion

    private func makeFish(from template: SCNNode, center: SCNVector3,
                          bodyMinX: Float, bodyLength: Float) -> Fish {
        let model = template.clone()

        // `clone()` shares geometry *and* materials with the original. Each fish needs its
        // own materials because the swim phase is a material uniform — sharing them would
        // make the whole school beat as one animal. Copying the geometry is cheap: the
        // vertex buffers stay shared, only the material list is duplicated.
        var materials: [SCNMaterial] = []
        model.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let copy = geometry.copy() as? SCNGeometry else { return }
            copy.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
            for material in copy.materials {
                material.shaderModifiers = [.geometry: swimModifier]
                material.setValue(NSNumber(value: 0.0), forKey: "swimPhase")
                // Amplitude is in the model's own object space, so it scales with the source
                // mesh, not with the fish's world size.
                material.setValue(NSNumber(value: bodyLength * 0.11), forKey: "swimAmplitude")
                material.setValue(NSNumber(value: 1.15), forKey: "swimWaves")
                material.setValue(NSNumber(value: bodyMinX), forKey: "bodyMinX")
                material.setValue(NSNumber(value: bodyLength), forKey: "bodyLength")
            }
            node.geometry = copy
            materials.append(contentsOf: copy.materials)
        }

        // Blender exports Z-up with the nose at +X; the tank is Y-up. The pivot carries that
        // correction plus the scale, and the model is offset inside it so the fish turns
        // about its own centre rather than about the origin of the export.
        let pivot = SCNNode()
        pivot.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        let scale = Tank.fishLength / bodyLength
        pivot.scale = SCNVector3(scale, scale, scale)
        model.position = SCNVector3(-center.x, -center.y, -center.z)
        pivot.addChildNode(model)

        let node = SCNNode()
        node.addChildNode(pivot)
        return Fish(node: node, materials: materials)
    }

    /// Positions a fish on a straight crossing of the tank.
    ///
    /// The heading is deliberately never parallel to the frame: a fish angled 13–30° in depth
    /// changes size and fog as it crosses, which is what sells the depth lanes, and it keeps
    /// the tail sweep off the view axis. The depth component always aims at the far side of
    /// the tank from where the fish starts, so every crossing is a long one — a fish that
    /// spawned near the camera heading further forward would vanish again immediately.
    ///
    /// `stratum` is set only for the opening layout, where it spreads the school evenly across
    /// depth and width. Left to chance, fourteen draws routinely clump into one corner and leave
    /// half the tank empty — and the first seconds after the screen blanks are the ones that
    /// get looked at. Respawns are unconstrained; by then the school has mixed.
    private func place(_ fish: Fish, spawningOffScreen: Bool, stratum: Float? = nil) {
        let depth = stratum.map { Tank.nearDepth + ($0 + rand.inRange(-0.4, 0.4) / 14)
                                    * (Tank.farDepth - Tank.nearDepth) }
            ?? rand.inRange(Tank.nearDepth, Tank.farDepth)
        let speed = depth * Tank.speedPerDepth * rand.inRange(0.75, 1.3)
        let tilt = rand.inRange(0.22, 0.52)
        let towardFar: Float = depth < (Tank.nearDepth + Tank.farDepth) / 2 ? -1 : 1
        let horizontal = rand.sign()

        fish.velocity = SIMD3<Float>(horizontal * speed * cos(tilt), 0,
                                     towardFar * speed * sin(tilt))

        let margin = Tank.fishLength * 1.05
        let edge = Tank.halfWidth(atDepth: depth) + margin
        // Golden-ratio stride: consecutive fish land far apart horizontally even though their
        // depths are adjacent, so the opening frame reads as a spread school.
        let spread = stratum.map { ((($0 * 0.618_034 + 0.31).truncatingRemainder(dividingBy: 1))
                                    * 2 - 1) * edge }
        let x = spawningOffScreen ? -horizontal * edge : (spread ?? rand.inRange(-edge, edge))
        let halfHeight = Tank.halfHeight(atDepth: depth, aspect: aspect)
        fish.position = SIMD3<Float>(x,
                                     rand.inRange(-1, 1) * halfHeight * Tank.verticalFill,
                                     -depth)

        fish.beat = rand.inRange(1.15, 1.75)
        fish.bobRate = rand.inRange(0.18, 0.42)
        fish.bobPhase = rand.inRange(0, 2 * .pi)
        fish.bobAmplitude = halfHeight * 0.07
    }

    /// Rescales the school when the drawable changes shape.
    ///
    /// Half-height is inversely proportional to the aspect ratio at every depth, so scaling
    /// each fish by the ratio of the two aspects leaves it exactly where it was in the frame.
    /// Clamping instead would pile the school onto the new edges; leaving them alone would
    /// strand the outermost ones outside a frame they never leave, because a crossing only
    /// ends horizontally.
    private func adoptAspect(_ newAspect: Float) {
        guard newAspect != aspect, newAspect > 0 else { return }
        let scale = aspect / newAspect
        aspect = newAspect
        for fish in fishes {
            fish.position.y *= scale
            fish.bobAmplitude *= scale
        }
    }

    private func hasLeftTank(_ fish: Fish) -> Bool {
        let depth = -fish.position.z
        if depth < Tank.depthCullNear || depth > Tank.depthCullFar { return true }
        // Vertical as well as horizontal. A fish holds its world height while its depth
        // changes, so one that started high in the far, tall part of the frustum can end up
        // above the near, short part of it — and a crossing only ever *ends* horizontally, so
        // without this it would stay invisible for the rest of a crossing and the school would
        // silently look thinner. The margin is well outside anything `place` produces, so this
        // fires only once a fish is genuinely out of frame, and the respawn is off-screen.
        if abs(fish.position.y) > Tank.halfHeight(atDepth: depth, aspect: aspect)
            + Tank.fishLength { return true }
        let edge = Tank.halfWidth(atDepth: depth) + Tank.fishLength * 1.25
        return abs(fish.position.x) > edge && fish.position.x * fish.velocity.x > 0
    }

    /// Yaw that points the model's +X nose along `velocity`. A node rotated by `yaw` about
    /// +Y sends local +X to `(cos yaw, 0, -sin yaw)`, hence the negated z.
    private func headingYaw(of velocity: SIMD3<Float>) -> Float {
        atan2(-velocity.z, velocity.x)
    }

    // MARK: Environment

    private func buildEnvironment() {
        // With `wantsHDR` on, the pass's `MTLClearColor` is discarded and the drawable comes
        // back with alpha 0 — the background has to be stated here or the saver renders over
        // nothing. This is the single most expensive trap in the whole host.
        scene.background.contents = Tank.waterColor

        // Fog colour matches the background exactly so the deepest fish dissolve into the
        // backdrop instead of into a visible wall of a slightly different colour.
        scene.fogColor = Tank.waterColor
        scene.fogStartDistance = CGFloat(Tank.nearDepth) * 0.8
        scene.fogEndDistance = CGFloat(Tank.farDepth) * 1.05
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

    // MARK: Bounds

    /// Union of every geometry node's box, expressed in the root's space.
    ///
    /// `SCNNode.boundingBox` on the root reports only that node's own geometry in some import
    /// layouts, which yields a zero extent for a hierarchy whose meshes all live in children —
    /// and a zero extent would make the swim envelope divide by zero.
    private static func worldBounds(of root: SCNNode) -> (SCNVector3, SCNVector3)? {
        var lo = SCNVector3(Float.greatestFiniteMagnitude,
                            Float.greatestFiniteMagnitude,
                            Float.greatestFiniteMagnitude)
        var hi = SCNVector3(-Float.greatestFiniteMagnitude,
                            -Float.greatestFiniteMagnitude,
                            -Float.greatestFiniteMagnitude)
        var found = false

        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] {
                for y in [a.y, b.y] {
                    for z in [a.z, b.z] {
                        let p = root.convertPosition(SCNVector3(x, y, z), from: node)
                        lo = SCNVector3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                        hi = SCNVector3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
                        found = true
                    }
                }
            }
        }
        return found ? (lo, hi) : nil
    }
}
