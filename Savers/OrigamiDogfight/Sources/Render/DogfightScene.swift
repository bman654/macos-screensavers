// The diorama: a folded-paper landscape under a warm sun, a camera looking almost straight
// down on it, and every frame the sim's state turned into posed nodes.
//
// This file owns only what is true of the whole scene — the camera, the clock that turns frame
// time into fixed sim steps, and the dispatch of the sim's events to effects. Planes, tanks,
// shots, wrecks and the scoreboard each have a file of their own; the landscape, its season,
// the sun and everything living around the fight are `Landscape`'s.

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
    private let armour: TankField
    private let shots: ProjectileField
    private let wrecks: WreckField
    private let supplies: SupplyField
    private let airfields: AirfieldField
    private let scoreboard: Scoreboard?
    private let landscape: Landscape

    /// Frame time at which sim step zero would have been due. Set on the first frame — so a
    /// sim handed over from a previous scene carries on from where it was rather than jumping —
    /// and advanced whenever the sim would otherwise have to catch up a long stall.
    private var clockOrigin: Double?

    /// The most steps one frame may run: a quarter of a second. A frozen main thread or a long
    /// rebuild then costs a skipped quarter-second, never a burst of a hundred steps on one frame.
    private static let maxCatchUp = 30

    init(sim: DogfightSim, countryside: Countryside, bundle: Bundle, quality: RenderQuality, showsScoreboard: Bool) {
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
        armour = TankField(shelf: shelf, papers: papers, stickers: fleet.stickers)
        shots = ProjectileField(shelf: shelf)
        wrecks = WreckField(shelf: shelf, papers: papers, effects: effects, fleet: fleet, armour: armour)
        supplies = SupplyField(shelf: shelf)
        airfields = AirfieldField(shelf: shelf, papers: papers)
        // The lineup is for looking at models; a card in the corner would only be in the way.
        scoreboard = showsScoreboard && !sim.isLineup ? Scoreboard(seed: sim.seed) : nil

        scene.background.contents = NSColor(srgbRed: 0.86, green: 0.84, blue: 0.78, alpha: 1)
        landscape = Landscape(sim: sim, countryside: countryside, shelf: shelf, quality: quality, scene: scene.rootNode)
        scene.rootNode.addChildNode(landscape.root)
        for root in [airfields.root, wrecks.root, armour.root, shots.root, fleet.root, supplies.root, effects.root] {
            scene.rootNode.addChildNode(root)
        }
        buildCamera()
        if let scoreboard { cameraNode.addChildNode(scoreboard.node) }
        // Which fight this scene was handed, and how far into it — the only way to see that an
        // idle release or a quality change resumed the fight rather than starting a new one.
        if LifecycleLog.isEnabled {
            LifecycleLog.emit(String(format: "origami scene built seed=%llu simTime=%.2fs quality=%@ aspect=%.4f",
                                     sim.seed, sim.time, quality == .full ? "full" : "reduced", sim.rig.aspect))
        }
        if sim.isLineup {
            // The lineup is for checking models, so say which ones are really the library's.
            let planes = PlaneType.allCases.map { "\($0.modelName)=\(shelf.plane($0).isStandIn ? "stand-in" : "library")" }
            let shots = WeaponKind.allCases.map { "\($0)=\(shelf.projectile($0).isStandIn ? "stand-in" : "library")" }
            let tanks = TankType.allCases.map { type -> String in
                let template = shelf.tank(type)
                let model = armour.model(type: type, paper: Paper(kind: .plain, tint: 0), size: 0.2)
                var paper = 0
                model.node.enumerateHierarchy { node, _ in
                    paper += node.geometry?.materials.filter { $0.name == "paper" }.count ?? 0
                }
                return "\(type.modelName)=\(template.isStandIn ? "stand-in" : "library") turret=\(model.turret != nil) paperMaterials=\(paper)"
            }
            let props = PropKind.allCases.map { kind in "\(kind.rawValue)×\(shelf.props(kind).filter { !$0.isStandIn }.count)" }
            NSLog("Origami lineup: %d library models; planes %@; shots %@; tanks %@; props %@; fire=%@ smoke=%@",
                  library.entries.count, planes.joined(separator: " "), shots.joined(separator: " "),
                  tanks.joined(separator: " "),
                  props.joined(separator: " "), shelf.fire().isStandIn ? "stand-in" : "library",
                  shelf.smoke() == nil ? "stand-in" : "library")
            NSLog("Origami lineup: countryside %@", Landscape.census(shelf))
        }

        // Whatever happened during a warmup, or before an idle release, is already over: its
        // wrecks are in the sim's state and will be drawn from it, and its sparks are gone. The
        // marks it left on the ground are not, and the landscape keeps those.
        for event in sim.drainEvents() { landscape.observe(event, sim: sim, live: false) }
    }

    // MARK: Frame

    func update(_ frame: FrameContext) {
        let aspect = Float(frame.drawableSize.width / max(frame.drawableSize.height, 1))
        if abs(aspect - sim.rig.aspect) > 1e-4 {
            if LifecycleLog.isEnabled {
                LifecycleLog.emit(String(format: "origami aspect %.4f -> %.4f at simTime=%.2fs", sim.rig.aspect, aspect, sim.time))
            }
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
        for event in sim.drainEvents() {
            react(to: event)
            landscape.observe(event, sim: sim, live: true)
        }
        landscape.update(sim: sim, time: sim.time + Double(alpha) * DogfightSim.stepSeconds)
        fleet.sync(sim, alpha: alpha, time: frame.time)
        armour.sync(sim, alpha: alpha)
        shots.sync(sim, alpha: alpha)
        wrecks.sync(sim, time: frame.time)
        supplies.sync(sim, alpha: alpha, time: frame.time)
        airfields.sync(sim, now: sim.time + Double(alpha) * DogfightSim.stepSeconds)
        scoreboard?.update(sim, drawableSize: frame.drawableSize,
                           now: sim.time + Double(alpha) * DogfightSim.stepSeconds)
    }

    /// The scale actually rendered at, from `RenderTargets` — the scene is built before the
    /// view has a window, at a provisional scale of 1, and this is what corrects it.
    func adopt(backingScale: CGFloat) {
        scoreboard?.backingScale = backingScale
    }

    private func react(to event: SimEvent) {
        switch event {
        case .hit(_, _, _, let position, let altitude, let paper, let scale),
             .tankHit(_, _, let position, let altitude, let paper, let scale):
            effects.confetti(at: position.scene(altitude: altitude), color: PaperPalette.base(paper), scale: scale)
        case .downed(let victim, _):
            if let plane = sim.plane(id: victim) {
                effects.shootDown(at: plane.position.scene(altitude: plane.altitude), color: PaperPalette.base(plane.paper),
                                  scale: plane.spec.scale)
            }
        case .crashed(_, let position, let ground, let inWater, let paper, let scale):
            if inWater {
                effects.splash(at: position.scene(altitude: ground), scale: scale)
            } else {
                effects.crash(at: position.scene(altitude: ground + 0.02 * scale), color: PaperPalette.base(paper), scale: scale)
            }
        case .tankDestroyed(_, _, _, let position, let ground, let paper, let scale):
            effects.crash(at: position.scene(altitude: ground + 0.03 * scale), color: PaperPalette.base(paper), scale: scale)
        case .splashed(let position, let kind, let scale):
            effects.shotSplash(at: position.scene(altitude: Terrain.waterLevel), size: kind.spec(scale: scale).size)
        case .collided(_, _, let position, let altitude, let papers, let scale):
            effects.collision(at: position.scene(altitude: altitude), colors: papers.map(PaperPalette.base), scale: scale)
        case .dropGrabbed(_, _, _, let position, let altitude):
            effects.cratePop(at: position.scene(altitude: altitude + SupplyDrop.canopyHeight * 0.4))
        case .stickered(let vehicle, _, _):
            if let plane = sim.plane(id: vehicle) {
                effects.sparkle(at: plane.position.scene(altitude: plane.altitude), scale: plane.spec.scale)
            } else if let tank = sim.tank(id: vehicle) {
                effects.sparkle(at: tank.position.scene(altitude: tank.altitude + tank.spec.height), scale: tank.spec.scale)
            }
        case .matchStarted, .matchEnded, .spawned, .fired, .exited, .tankSpawned, .tankFired, .tankLeft,
             .dropSpawned, .dropLanded, .tookOff:
            break
        }
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
