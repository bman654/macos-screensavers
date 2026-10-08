// Everything in the scene that is not the fight: the folded landscape in its season, the sun at
// its hour, and the countryside living on it — mills, boats, sheep, cars, cranes, and the marks
// the fight leaves behind.
//
// `DogfightScene` builds one of these, hangs its root, and hands it each frame and each event;
// everything else about the world around the fight is decided here and in `Countryside`.

import Foundation
import SceneKit
import simd

final class Landscape {
    let root = SCNNode()
    private let countryside: Countryside
    private let daylight: DayLight
    private let life: AmbientLife
    private let cranes: CraneFlight
    private let marks: GroundMarks
    private let fires: TreeFires
    /// The whole scene, swept now and then for models this file did not build but must still
    /// light: a window anywhere, the fight's hangars' among them.
    private weak var scene: SCNScene?
    /// The fight's fill light, for the scene to hang on its camera (`DayLight.fillNode`).
    var fightFill: SCNNode { daylight.fillNode }
    private var nextSweep = -Double.infinity
    private var sweeps = 0
    /// `ORIGAMI_PHASE`: the day's dial held at one point (0 dawn … 1 dusk) — a harness override,
    /// like every `ORIGAMI_*`, empty under `legacyScreenSaver`. The drift takes an hour to reach
    /// dusk and a warmup stops at ten minutes, so this is the only way to see dusk in a still,
    /// or two hours of the day on one frame of one fight.
    private let pinnedPhase = ProcessInfo.processInfo.environment["ORIGAMI_PHASE"].flatMap(Double.init)
        .flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }

    init(sim: DogfightSim, countryside: Countryside, shelf: ModelShelf, quality: RenderQuality, scene: SCNScene,
         lamplight: Lamplight, planeShadows: PlaneShadows) {
        self.countryside = countryside
        self.scene = scene
        let season = countryside.atmosphere.season
        let terrain = TerrainMesh.node(for: sim.terrain, seed: sim.seed, season: season)
        // Boats ride and mills turn, so neither can be part of the one flattened node the rest of
        // the scenery is; the mills stand in place of the props they replace.
        let still = sim.props.indices
            .filter { sim.props[$0].kind != .boat && !countryside.replacedProps.contains($0) }
            .map { sim.props[$0] }
        // Dressed before flattening, on the templates: the flattened node is filled in lazily,
        // and has neither geometry nor materials to dress until it has first been drawn.
        for kind in PropKind.allCases { for template in shelf.props(kind) { SeasonDress.dress(template.node, season: season) } }
        let scenery = Scenery.node(spots: still, shelf: shelf)
        let models = AmbientModels(shelf: shelf)
        life = AmbientLife(countryside: countryside, sim: sim, shelf: shelf, models: models)
        cranes = CraneFlight(models: models)
        marks = GroundMarks(terrain: sim.terrain)
        fires = TreeFires(shelf: shelf, props: sim.props)
        SeasonDress.dress(life.root, season: season)
        daylight = DayLight(quality: quality, season: season, terrain: terrain.geometry?.firstMaterial, scene: scene,
                            lamplight: lamplight, planeShadows: planeShadows)
        lamplight.light(houses: sim.props, terrain: sim.terrain)

        let roads = RoadStrips.node(roads: countryside.roads, terrain: sim.terrain, season: season)
        // Drawn before the planes' shadows, which are laid over them (`PlaneShadows`).
        for ground in [terrain, roads] { ground.renderingOrder = PlaneShadows.groundOrder }
        for node in [terrain, roads,
                     marks.root, lamplight.houses, scenery, life.root, fires.root, cranes.root, daylight.root] {
            root.addChildNode(node)
        }
        countryside.catchUp(with: sim)
        update(sim: sim, time: sim.time)
    }

    /// Steps the fight and the countryside together (`Countryside.advance`), and returns what
    /// the fight did.
    func advance(_ sim: DogfightSim, steps count: Int) -> [SimEvent] {
        countryside.advance(sim, steps: count)
    }

    /// What the fight just did. `live` is false for what happened before this scene existed.
    func observe(_ event: SimEvent, sim: DogfightSim, live: Bool) {
        countryside.observe(event, sim: sim, live: live)
    }

    /// `time` is the sim's time at this frame, between its fixed steps. Draws only: everything
    /// with a clock of its own was stepped with the sim.
    func update(sim: DogfightSim, time: Double) {
        sweep(at: time)
        daylight.update(phase: pinnedPhase ?? countryside.atmosphere.phase(at: time))
        life.update(countryside, time: time)
        cranes.update(countryside.cranes, time: time)
        marks.sync(countryside.marks, time: time)
        fires.sync(countryside.marks, time: time)
    }

    /// Quickly at first, while the flattened scenery fills in on its first draws, then every two
    /// seconds — soon enough for a hangar built as a match begins, and a few hundred nodes' walk
    /// is nothing at that rate.
    private func sweep(at time: Double) {
        guard time >= nextSweep || time < nextSweep - 10, let scene else { return }
        sweeps += 1
        nextSweep = time + (sweeps < 8 ? 0.25 : 2)
        for material in SeasonDress.materials(under: scene.rootNode) where (material.name ?? "").contains("window") {
            daylight.adopt(window: material)
        }
    }

    /// For the lineup's census of which models are really the library's.
    static func census(_ shelf: ModelShelf) -> String {
        let models = AmbientModels(shelf: shelf)
        return ["crane", "windmill", "sheep", "car"]
            .map { "\($0)=\(models.isFromLibrary($0) ? "library" : "stand-in")" }.joined(separator: " ")
    }
}
