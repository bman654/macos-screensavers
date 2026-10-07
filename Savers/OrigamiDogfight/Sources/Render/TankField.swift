// The tanks on the ground, as nodes: folded from their side's paper, sitting on the slope under
// them, their turrets swung to wherever the sim is aiming.

import Foundation
import SceneKit
import simd

final class TankField {
    let root = SCNNode()
    private let shelf: ModelShelf
    private let papers: PaperMaterials

    /// A tank model and the turret inside it, ready to pose.
    struct Model {
        let node: SCNNode
        let turret: SCNNode?
        /// The turret's authored orientation, which every aim is applied on top of.
        let rest: simd_quatf
    }

    private final class Visual {
        let model: Model
        let size: Float
        init(model: Model, size: Float) {
            self.model = model
            self.size = size
        }
    }

    private var visuals: [Int: Visual] = [:]

    init(shelf: ModelShelf, papers: PaperMaterials) {
        self.shelf = shelf
        self.papers = papers
    }

    /// A tank of `type` folded from `paper`, its footprint `size` metres. `material` replaces the
    /// paper's shared one — a wreck scorches its own copy.
    func model(type: TankType, paper: Paper, size: Float, material: SCNMaterial? = nil) -> Model {
        let template = shelf.tank(type)
        let instance = template.instance(size: size, along: .footprint)
        let skin = material ?? papers.material(for: paper, aspect: CGFloat(template.sheetAspect))
        instance.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  geometry.materials.contains(where: { $0.name == "paper" }),
                  let copy = geometry.copy() as? SCNGeometry else { return }
            // Only the paper takes the side's colour (the asset contract); treads keep theirs.
            copy.materials = geometry.materials.map { $0.name == "paper" ? skin : $0 }
            node.geometry = copy
        }
        let turret = instance.childNode(withName: "turret", recursively: true)
        return Model(node: instance, turret: turret, rest: turret?.simdOrientation ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    /// Turns the turret `angle` radians to the tank's left — counter-clockwise from above, the
    /// sim's sense. The models turn about their own z, which the import's pivot makes world up.
    static func aim(_ model: Model, at angle: Float) {
        model.turret?.simdOrientation = model.rest * simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
    }

    func sync(_ sim: DogfightSim, alpha: Float) {
        var seen = Set<Int>()
        let now = sim.time + Double(alpha) * DogfightSim.stepSeconds
        for tank in sim.tanks {
            seen.insert(tank.id)
            let visual = visuals[tank.id] ?? make(tank)
            visuals[tank.id] = visual
            pose(visual, tank, alpha: alpha, terrain: sim.terrain, now: now)
        }
        for (id, visual) in visuals where !seen.contains(id) {
            visual.model.node.removeFromParentNode()
            visuals[id] = nil
        }
    }

    private func make(_ tank: Tank) -> Visual {
        let model = model(type: tank.type, paper: tank.paper, size: tank.spec.size)
        root.addChildNode(model.node)
        return Visual(model: model, size: tank.spec.size)
    }

    private func pose(_ visual: Visual, _ tank: Tank, alpha: Float, terrain: Terrain, now: Double) {
        let position = tank.previousPosition + (tank.position - tank.previousPosition) * alpha
        let heading = tank.previousHeading + (tank.heading - tank.previousHeading).wrappedAngle * alpha
        let turret = tank.previousTurret + (tank.turret - tank.previousTurret).wrappedAngle * alpha
        let node = visual.model.node
        node.simdPosition = position.scene(altitude: terrain.surfaceHeight(at: position))
        node.simdOrientation = TankField.sitting(on: terrain, at: position, heading: heading, size: visual.size)
        // A thrown pencil kicks the turret back a fraction for an instant.
        let kick = Float(max(0, 1 - (now - tank.firedAt) / 0.25))
        TankField.aim(visual.model, at: (turret - heading).wrappedAngle)
        visual.model.turret?.simdScale = SIMD3(repeating: 1 - 0.06 * kick)

        if case .folding(let since) = tank.state {
            // Flattening down into the ground and fading, the way the fire folds away.
            let f = Float(min(max((now - since) / DogfightSim.foldTime, 0), 1))
            node.simdScale = SIMD3(1, max(1 - smoothstep(0, 1, f), 0.02), 1)
            node.opacity = CGFloat(1 - smoothstep(0.3, 1, f))
        } else {
            node.simdScale = SIMD3(repeating: 1)
            node.opacity = 1
        }
    }

    /// Yawed to `heading`, then pitched and rolled to the ground under its treads — sampled
    /// fore, aft and to each side, so a tank on a hillside leans with it rather than floating
    /// level with one tread in the air.
    static func sitting(on terrain: Terrain, at p: SIMD2<Float>, heading: Float, size: Float) -> simd_quatf {
        let forward = SIMD2(cos(heading), sin(heading)), left = SIMD2(-forward.y, forward.x)
        let a = size * 0.4, b = size * 0.3
        let pitch = atan2(terrain.surfaceHeight(at: p + forward * a) - terrain.surfaceHeight(at: p - forward * a), 2 * a)
        let roll = atan2(terrain.surfaceHeight(at: p + left * b) - terrain.surfaceHeight(at: p - left * b), 2 * b)
        // The same frame `PlaneFleet` flies in: yaw about +Y, nose up about +Z, and a positive
        // turn about +X raises the left side, which is what higher ground to the left asks for.
        return simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: roll, axis: SIMD3(1, 0, 0))
    }
}
