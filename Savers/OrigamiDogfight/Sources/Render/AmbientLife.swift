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
    private var cars: [(node: SCNNode, lamps: SCNNode)] = []
    private let lights: GroundLights
    /// Headlamps and tail-lights, shared by every car and turned up with the dusk.
    private let headlamp = GlowPaint.dotMaterial(PaperColor(1.0, 0.95, 0.80))
    private let tailLight = GlowPaint.dotMaterial(PaperColor(1.0, 0.16, 0.10))

    /// Soft paper colours for the cars, none of them a team's, so a car is never read as a side.
    private static let carPapers = [PaperColor(0.95, 0.92, 0.84), PaperColor(0.58, 0.74, 0.88),
                                    PaperColor(0.62, 0.82, 0.66), PaperColor(0.94, 0.62, 0.52),
                                    PaperColor(0.90, 0.80, 0.46), PaperColor(0.56, 0.58, 0.66)]

    init(countryside: Countryside, sim: DogfightSim, shelf: ModelShelf, models: AmbientModels,
         lights: GroundLights) {
        terrain = sim.terrain
        self.lights = lights
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
            let lamps = AmbientLife.lamps(headlamp: headlamp, tail: tailLight)
            node.addChildNode(lamps)
            root.addChildNode(node)
            cars.append((node, lamps))
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

        let lampsOn = lights.headlampStrength > 0.01
        headlamp.emission.intensity = CGFloat(lights.headlampStrength)
        tailLight.emission.intensity = CGFloat(lights.headlampStrength)
        for (index, car) in cars.enumerated() {
            let pose = countryside.traffic.pose(of: index, at: time)
            car.node.simdPosition = Drape.point(pose.position, on: terrain)
            car.node.simdOrientation = TankField.sitting(on: terrain, at: pose.position, heading: pose.heading,
                                                         size: AmbientModels.carLength)
            // Off while it is parked in the village; on again as it turns to set off.
            let driving = time >= countryside.traffic.cars[index].parkedUntil - 1.5
            car.lamps.isHidden = !(lampsOn && driving)
            guard lampsOn, driving else { continue }
            let forward = SIMD2(cos(pose.heading), sin(pose.heading)), left = SIMD2(-forward.y, forward.x)
            let ground = terrain.surfaceHeight(at: pose.position)
            for side: Float in [-1, 1] {
                let lamp = pose.position + forward * (AmbientModels.carLength * 0.5) + left * (side * 0.009)
                lights.beam(from: lamp.scene(altitude: ground + 0.012), direction: SIMD2(forward.x, -forward.y),
                            reach: AmbientLife.beamReach, colour: AmbientLife.beamColour)
            }
        }
    }

    /// Five car lengths of lane lit ahead, in a warm white.
    private static let beamReach: Float = 0.32
    private static let beamColour = SIMD3<Float>(1.0, 0.84, 0.58) * 1.6

    /// Two headlamps on the front and two tail-lights behind, as dots on the car's own frame —
    /// the car's model faces +X and stands on y = 0 at its real 6 cm.
    private static func lamps(headlamp: SCNMaterial, tail: SCNMaterial) -> SCNNode {
        let group = SCNNode()
        let half = AmbientModels.carLength * 0.5
        for side: Float in [-1, 1] {
            let front = GlowPaint.dot(headlamp, diameter: 0.009)
            front.simdPosition = SIMD3(half + 0.001, 0.013, side * 0.009)
            let back = GlowPaint.dot(tail, diameter: 0.006)
            back.simdPosition = SIMD3(-half - 0.001, 0.013, side * 0.009)
            group.addChildNode(front)
            group.addChildNode(back)
        }
        group.isHidden = true
        return group
    }
}
