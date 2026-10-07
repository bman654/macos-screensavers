// The countryside going about its business, as nodes: mills turning, boats riding at their
// moorings, sheep grazing, cars on the lanes. Each is posed every frame from `Countryside`, which
// owns where they are; this file only says how they look doing it.
//
// A handful of nodes each — three mills, half a dozen boats, a score of sheep, three cars — so
// none of it is batched: a node apiece is a few dozen draw calls, and they move.

import AppKit
import Foundation
import SceneKit
import simd

final class AmbientLife {
    let root = SCNNode()
    private let terrain: Terrain
    private let frozen: Bool
    private var mills: [(node: SCNNode, sails: Articulated.Part?, mill: Windmill)] = []
    private var boats: [(node: SCNNode, mooring: Mooring, home: SIMD2<Float>, yaw: Float)] = []
    private var flock: [SCNNode] = []
    private var cars: [SCNNode] = []

    /// Soft paper colours for the cars, none of them a team's, so a car is never read as a side.
    private static let carPapers = [PaperColor(0.95, 0.92, 0.84), PaperColor(0.58, 0.74, 0.88),
                                    PaperColor(0.62, 0.82, 0.66), PaperColor(0.94, 0.62, 0.52),
                                    PaperColor(0.90, 0.80, 0.46), PaperColor(0.56, 0.58, 0.66)]

    init(countryside: Countryside, sim: DogfightSim, shelf: ModelShelf, models: AmbientModels) {
        terrain = sim.terrain
        frozen = countryside.atmosphere.frozenLakes

        for mill in countryside.windmills {
            let model = models.windmill()
            let node = SCNNode()
            node.simdPosition = mill.position.scene(altitude: mill.ground)
            node.simdOrientation = simd_quatf(angle: mill.yaw, axis: SIMD3(0, 1, 0))
            model.node.simdScale *= mill.scale
            node.addChildNode(model.node)
            root.addChildNode(node)
            mills.append((node, model.parts["blades"], mill))
        }

        let boatTemplates = shelf.props(.boat)
        for mooring in countryside.moorings where !boatTemplates.isEmpty {
            let spot = sim.props[mooring.prop]
            let template = boatTemplates[spot.variant % boatTemplates.count]
            // As `Scenery` would have drawn it: its stand-in size is the one there.
            let boat = template.isStandIn
                ? template.instance(size: 0.1 * spot.scale, along: .footprint)
                : template.instance(scale: Scenery.dioramaScale * spot.scale)
            let node = SCNNode()
            node.addChildNode(boat)
            root.addChildNode(node)
            boats.append((node, mooring, spot.position, spot.yaw))
        }

        for _ in countryside.pasture.sheep {
            let node = models.sheep()
            root.addChildNode(node)
            flock.append(node)
        }
        for car in countryside.traffic.cars {
            let node = models.car(paper: AmbientLife.carPapers[car.paper % AmbientLife.carPapers.count])
            root.addChildNode(node)
            cars.append(node)
        }
    }

    func update(_ countryside: Countryside, time: Double) {
        for mill in mills {
            mill.sails?.turn(by: Float((time * Double(mill.mill.rate)).truncatingRemainder(dividingBy: 2 * .pi))
                             + mill.mill.phase)
        }

        for boat in boats {
            let m = boat.mooring
            if frozen {
                // Frozen in: still, and listing a little, the way a boat caught by the ice sits.
                boat.node.simdPosition = boat.home.scene(altitude: Terrain.waterLevel)
                boat.node.simdOrientation = simd_quatf(angle: boat.yaw, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: 0.09, axis: SIMD3(1, 0, 0))
                continue
            }
            // Drifting round its mooring on two slow clocks, nosing round with the drift, and
            // bobbing on a quicker one.
            let drift = SIMD2(wave(time, rate: Double(m.rates.x), phase: Double(m.phases.x)),
                              wave(time, rate: Double(m.rates.y), phase: Double(m.phases.y))) * m.reach
            let bob = wave(time, rate: Double(m.rates.z), phase: Double(m.phases.z))
            boat.node.simdPosition = (boat.home + drift).scene(altitude: Terrain.waterLevel + 0.002 * bob)
            boat.node.simdOrientation = simd_quatf(angle: boat.yaw + 0.35 * wave(time, rate: Double(m.rates.x) * 0.7,
                                                                                  phase: Double(m.phases.y)),
                                                   axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: 0.05 * bob, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: 0.03 * wave(time, rate: Double(m.rates.z) * 0.8, phase: Double(m.phases.x)),
                             axis: SIMD3(0, 0, 1))
        }

        for (index, node) in flock.enumerated() {
            let pose = countryside.pasture.pose(of: index, at: time)
            let sheep = countryside.pasture.sheep[index]
            // A grazing nod while standing: the head goes down to the grass and up again.
            let nod: Float = sheep.target == nil ? 0.08 * max(wave(time, rate: 1.7, phase: Double(index) * 2.3), 0) : 0
            node.simdPosition = pose.position.scene(altitude: terrain.surfaceHeight(at: pose.position))
            node.simdOrientation = simd_quatf(angle: pose.heading, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: -nod, axis: SIMD3(0, 0, 1))
            node.simdScale = SIMD3(repeating: sheep.size)
        }

        for (index, node) in cars.enumerated() {
            let pose = countryside.traffic.pose(of: index, at: time)
            node.simdPosition = Drape.point(pose.position, on: terrain)
            node.simdOrientation = TankField.sitting(on: terrain, at: pose.position, heading: pose.heading,
                                                     size: AmbientModels.carLength)
        }
    }
}
