// The diorama: a folded-paper landscape under a warm sun, a camera looking almost straight
// down on it, and every frame the sim's state turned into posed nodes.
//
// This file owns only what is true of the whole scene — camera, lights, the clock that turns
// frame time into fixed sim steps, and the dispatch of the sim's events to effects. Planes,
// shots and wrecks each have a file of their own.

import AppKit
import Foundation
import Metal
import SceneKit
import simd

final class DogfightScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let sim: DogfightSim

    /// Only reached through the non-HDR path, which this scene uses; matched to the paper
    /// background so a frame can never flash a different colour at its edges.
    let clearColor = MTLClearColor(red: 0.86, green: 0.84, blue: 0.78, alpha: 1)

    private let effects = Effects()
    private let fleet: PlaneFleet
    private let shots: ProjectileField
    private let wrecks: WreckField
    private let keyLight = SCNLight()

    /// The sun's direction of travel, in sim axes: toward the lower right of the frame, mostly
    /// down. The key light is aimed along it, and the terrain's folds are shaded from it.
    static let sunTravel = SIMD3<Float>(0.36, -0.42, -1)

    /// Frame time at which sim step zero would have been due. Set on the first frame — so a
    /// sim handed over from a previous scene carries on from where it was rather than jumping —
    /// and advanced whenever the sim would otherwise have to catch up a long stall.
    private var clockOrigin: Double?

    /// The most steps one frame may run: a quarter of a second. A frozen main thread or a long
    /// rebuild then costs a skipped quarter-second, never a burst of a hundred steps on one frame.
    private static let maxCatchUp = 30

    init(sim: DogfightSim, bundle: Bundle, quality: RenderQuality) {
        self.sim = sim
        // Zero-duration, for the reason `SceneKitHost.encode` gives: a node property set outside
        // SceneKit's render loop is otherwise an implicit animation stamped with a clock the
        // renderer does not use.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        defer { SCNTransaction.commit() }
        let library = OrigamiLibrary(directory: bundle.resourceURL)
        let shelf = ModelShelf(library: library)
        let papers = PaperMaterials(seed: sim.seed)
        fleet = PlaneFleet(shelf: shelf, papers: papers, effects: effects)
        shots = ProjectileField(shelf: shelf)
        wrecks = WreckField(shelf: shelf, papers: papers, effects: effects, fleet: fleet)

        scene.background.contents = NSColor(srgbRed: 0.86, green: 0.84, blue: 0.78, alpha: 1)
        scene.rootNode.addChildNode(TerrainMesh.node(for: sim.terrain, seed: sim.seed))
        scene.rootNode.addChildNode(Scenery.node(spots: Scatter.spots(on: sim.terrain, seed: sim.seed), shelf: shelf))
        for root in [wrecks.root, shots.root, fleet.root, effects.root] { scene.rootNode.addChildNode(root) }
        buildLights(quality: quality)
        buildCamera()
        // Which fight this scene was handed, and how far into it — the only way to see that an
        // idle release or a quality change resumed the fight rather than starting a new one.
        if LifecycleLog.isEnabled {
            LifecycleLog.emit(String(format: "origami scene built seed=%llu simTime=%.2fs quality=%@",
                                     sim.seed, sim.time, quality == .full ? "full" : "reduced"))
        }
        if sim.isLineup {
            // The lineup is for checking models, so say which ones are really the library's.
            let planes = PlaneType.allCases.map { "\($0.modelName)=\(shelf.plane($0).isStandIn ? "stand-in" : "library")" }
            let shots = WeaponKind.allCases.map { "\($0)=\(shelf.projectile($0).isStandIn ? "stand-in" : "library")" }
            let props = PropKind.allCases.map { kind in "\(kind.rawValue)×\(shelf.props(kind).filter { !$0.isStandIn }.count)" }
            NSLog("Origami lineup: %d library models; planes %@; shots %@; props %@; fire=%@ smoke=%@",
                  library.entries.count, planes.joined(separator: " "), shots.joined(separator: " "),
                  props.joined(separator: " "), shelf.fire().isStandIn ? "stand-in" : "library",
                  shelf.smoke() == nil ? "stand-in" : "library")
        }

        // Whatever happened during a warmup, or before an idle release, is already over: its
        // wrecks are in the sim's state and will be drawn from it, and its sparks are gone.
        _ = sim.drainEvents()
    }

    // MARK: Frame

    func update(_ frame: FrameContext) {
        let aspect = Float(frame.drawableSize.width / max(frame.drawableSize.height, 1))
        if abs(aspect - sim.rig.aspect) > 1e-4 {
            sim.setAspect(aspect)
            placeCamera()
        }

        let step = DogfightSim.stepSeconds
        var origin = clockOrigin ?? (frame.time - Double(sim.steps) * step)
        var due = Int(floor((frame.time - origin) / step)) - sim.steps
        if due > DogfightScene.maxCatchUp {
            origin += Double(due - DogfightScene.maxCatchUp) * step
            due = DogfightScene.maxCatchUp
        } else if due < 0 {
            origin = frame.time - Double(sim.steps) * step
            due = 0
        }
        clockOrigin = origin
        sim.advance(steps: due)
        let alpha = Float(min(max((frame.time - origin) / step - Double(sim.steps), 0), 1))

        effects.update(time: frame.time)
        for event in sim.drainEvents() { react(to: event) }
        fleet.sync(sim, alpha: alpha, time: frame.time)
        shots.sync(sim, alpha: alpha)
        wrecks.sync(sim, time: frame.time)
    }

    private func react(to event: SimEvent) {
        switch event {
        case .hit(_, _, _, let position, let altitude, let paper):
            effects.confetti(at: position.scene(altitude: altitude), color: PaperPalette.base(paper))
        case .downed(let victim, _):
            if let plane = sim.plane(id: victim) {
                effects.shootDown(at: plane.position.scene(altitude: plane.altitude), color: PaperPalette.base(plane.paper))
            }
        case .crashed(_, let position, let ground, let inWater, let paper):
            if inWater {
                effects.splash(at: position.scene(altitude: ground))
            } else {
                effects.crash(at: position.scene(altitude: ground + 0.02), color: PaperPalette.base(paper))
            }
        case .matchStarted, .matchEnded, .spawned, .fired, .exited:
            break
        }
    }

    // MARK: Light

    private func buildLights(quality: RenderQuality) {
        // A warm sun from the upper left of the frame, high enough that a plane's shadow lands
        // clearly offset from it — about half a metre for a plane at the top of the band. Too
        // high, alone, for the landscape's folds to show from overhead; `TerrainMesh` bakes a
        // lower sun on this same bearing into the ground's colours for that.
        keyLight.type = .directional
        keyLight.color = NSColor(srgbRed: 1.0, green: 0.93, blue: 0.80, alpha: 1)
        keyLight.intensity = 820
        keyLight.castsShadow = true
        // The one fidelity knob a `.reduced` tile may turn: the shadow map does not shrink with
        // the resolution cap, and a two-inch tile cannot show a 2048-texel map's edges anyway.
        let map: CGFloat = quality == .reduced ? 1024 : 2048
        keyLight.shadowMapSize = CGSize(width: map, height: map)
        keyLight.shadowSampleCount = 8
        keyLight.shadowRadius = 2.0
        keyLight.shadowColor = NSColor(white: 0, alpha: 0.42)
        keyLight.shadowMode = .forward
        keyLight.automaticallyAdjustsShadowProjection = true
        keyLight.maximumShadowDistance = 16
        let key = SCNNode()
        key.light = keyLight
        let travel = DogfightScene.sunTravel
        key.simdLook(at: SIMD3(travel.x, travel.z, -travel.y), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(key)

        // Skylight: cool and soft, so a shadow is a cooler, dimmer paper rather than a hole.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(srgbRed: 0.80, green: 0.85, blue: 0.96, alpha: 1)
        ambient.intensity = 430
        let sky = SCNNode()
        sky.light = ambient
        scene.rootNode.addChildNode(sky)
    }

    // MARK: Camera

    private func buildCamera() {
        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.fieldOfView = CGFloat(ViewRig.verticalFOV * 180 / .pi)
        camera.zNear = 1.5
        camera.zFar = 30
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        placeCamera()
    }

    /// From the sim's rig, so the soft wall and the edge of the screen are the same line.
    private func placeCamera() {
        let rig = sim.rig
        func yUp(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, v.z, -v.y) }
        cameraNode.simdPosition = yUp(rig.eye)
        cameraNode.simdLook(at: yUp(rig.eye + rig.forward), up: yUp(rig.up), localFront: SIMD3(0, 0, -1))
    }
}
