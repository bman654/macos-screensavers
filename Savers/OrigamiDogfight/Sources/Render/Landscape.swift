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
    /// light or dress: a window anywhere, and the fight's hangars, whose snow is the season's.
    private weak var scene: SCNNode?
    private var nextSweep = -Double.infinity
    private var sweeps = 0

    init(sim: DogfightSim, countryside: Countryside, shelf: ModelShelf, quality: RenderQuality, scene: SCNNode) {
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
        daylight = DayLight(quality: quality, terrain: terrain.geometry?.firstMaterial)

        for node in [terrain, RoadStrips.node(roads: countryside.roads, terrain: sim.terrain, season: season),
                     marks.root, scenery, life.root, fires.root, cranes.root, daylight.root] {
            root.addChildNode(node)
        }
        update(sim: sim, time: sim.time)
    }

    /// What the fight just did. `live` is false for what happened before this scene existed.
    func observe(_ event: SimEvent, sim: DogfightSim, live: Bool) {
        countryside.observe(event, sim: sim, live: live)
    }

    /// `time` is the sim's time at this frame, between its fixed steps.
    func update(sim: DogfightSim, time: Double) {
        countryside.advance(to: time, sim: sim)
        sweep(at: time)
        daylight.update(phase: countryside.atmosphere.phase(at: time))
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
        let season = countryside.atmosphere.season
        let ws = SeasonDress.materials(under: scene).filter { ($0.name ?? "").contains("window") }
        for material in SeasonDress.materials(under: scene) {
            let name = material.name ?? ""
            if name.contains("window") { daylight.adopt(window: material) }
            if name.contains("hangar"), material.shaderModifiers == nil { SeasonDress.dress(material, season: season) }
        }
    }

    /// For the lineup's census of which models are really the library's.
    static func census(_ shelf: ModelShelf) -> String {
        let models = AmbientModels(shelf: shelf)
        return ["crane", "windmill", "sheep", "car"]
            .map { "\($0)=\(models.isFromLibrary($0) ? "library" : "stand-in")" }.joined(separator: " ")
    }
}
