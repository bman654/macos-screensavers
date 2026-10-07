// The planes in the air, as nodes: one per sim plane, posed each frame from the sim's last two
// fixed steps, banked into its turns, with a little paper flutter on top.

import Foundation
import SceneKit
import simd

final class PlaneFleet {
    let root = SCNNode()
    private let shelf: ModelShelf
    private let papers: PaperMaterials
    private let effects: Effects

    private final class Visual {
        let node: SCNNode
        /// Trails hang off this rather than the plane, so a crash can hand them to the scene
        /// to finish fading instead of cutting them off mid-air.
        let tail: SCNNode
        let paper: Paper
        let flutter: Float
        var scraps: SCNParticleSystem?
        var smoke: SCNParticleSystem?

        init(node: SCNNode, tail: SCNNode, paper: Paper, flutter: Float) {
            self.node = node
            self.tail = tail
            self.paper = paper
            self.flutter = flutter
        }
    }

    private var visuals: [Int: Visual] = [:]

    init(shelf: ModelShelf, papers: PaperMaterials, effects: Effects) {
        self.shelf = shelf
        self.papers = papers
        self.effects = effects
    }

    func sync(_ sim: DogfightSim, alpha: Float, time: Double) {
        var seen = Set<Int>()
        for plane in sim.planes {
            seen.insert(plane.id)
            let visual = visuals[plane.id] ?? make(plane)
            visuals[plane.id] = visual
            pose(visual, plane, alpha: alpha, time: time)
            trails(visual, plane)
        }
        for (id, visual) in visuals where !seen.contains(id) {
            retire(visual)
            visuals[id] = nil
        }
    }

    /// A model of the plane's type folded from its paper, at its on-screen size.
    func model(type: PlaneType, paper: Paper, material: SCNMaterial? = nil) -> SCNNode {
        let template = shelf.plane(type)
        let instance = template.instance(size: type.spec.size, along: .footprint)
        let skin = material ?? papers.material(for: paper, aspect: CGFloat(template.sheetAspect))
        instance.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry, let copy = geometry.copy() as? SCNGeometry else { return }
            // The runtime replaces the plane's material outright (the asset contract): the
            // model promises its folds and its sheet coordinates, and the paper is drawn here.
            copy.materials = [skin]
            node.geometry = copy
        }
        return instance
    }

    private func make(_ plane: Plane) -> Visual {
        let node = SCNNode()
        node.addChildNode(model(type: plane.type, paper: plane.paper))
        let tail = SCNNode()
        tail.simdPosition = SIMD3(-plane.spec.size * 0.45, 0, 0)
        node.addChildNode(tail)
        root.addChildNode(node)
        return Visual(node: node, tail: tail, paper: plane.paper, flutter: Float(plane.id % 97) * 0.731)
    }

    private func pose(_ visual: Visual, _ plane: Plane, alpha: Float, time: Double) {
        let a = plane.previous, b = plane.pose
        let position = a.position + (b.position - a.position) * alpha
        let altitude = a.altitude + (b.altitude - a.altitude) * alpha
        let heading = a.heading + (b.heading - a.heading).wrappedAngle * alpha
        let bank = a.bank + (b.bank - a.bank) * alpha
        let pitch = a.pitch + (b.pitch - a.pitch) * alpha

        // Paper is light: a plane in the air never sits quite still on its line.
        let t = time + Double(visual.flutter)
        let flutterRoll = 0.07 * wave(t, rate: 6.1) + 0.03 * wave(t, rate: 13.7)
        let flutterPitch = 0.04 * wave(t, rate: 4.3, phase: 1.1)
        let bob = 0.006 * wave(t, rate: 3.1)

        visual.node.simdPosition = position.scene(altitude: altitude + bob)
        // Yaw about +Y takes the model's nose (+X) to the sim heading; pitch about the model's
        // own +Z lifts the nose; and its left wing is -Z, so a positive roll about +X *raises*
        // the left wing — a left turn (positive bank) therefore rolls by -bank.
        visual.node.simdOrientation =
            simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: pitch + flutterPitch, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: -bank + flutterRoll, axis: SIMD3(1, 0, 0))
    }

    private func trails(_ visual: Visual, _ plane: Plane) {
        if (plane.isDamaged || plane.state.isDowned), visual.scraps == nil {
            let system = effects.scrapTrail(color: PaperPalette.base(plane.paper))
            visual.tail.addParticleSystem(system)
            visual.scraps = system
        }
        if plane.state.isDowned, visual.smoke == nil {
            let system = effects.smokeTrail()
            visual.tail.addParticleSystem(system)
            visual.smoke = system
        }
    }

    /// The plane has crashed or flown off: its trail stays where it was drawn and fades out.
    ///
    /// The node itself is kept, with the model hidden and emission stopped, because a particle
    /// system's live particles go with the node it hangs on.
    private func retire(_ visual: Visual) {
        guard visual.scraps != nil || visual.smoke != nil else {
            visual.node.removeFromParentNode()
            return
        }
        for child in visual.node.childNodes where child !== visual.tail { child.isHidden = true }
        visual.scraps?.birthRate = 0
        visual.smoke?.birthRate = 0
        effects.hold(visual.node, for: 2)
    }
}
