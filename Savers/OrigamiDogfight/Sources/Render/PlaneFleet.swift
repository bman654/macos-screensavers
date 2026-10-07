// The planes in the air, as nodes: one per sim plane, posed each frame from the sim's last two
// fixed steps, banked into its turns, with a little paper flutter on top — and wearing what the
// fight has done to it: damage marks on its paper, an ace's stickers on its wings, a crumpled nose
// after a collision, and a glitter trail while a supply drop's weapon lasts.

import Foundation
import SceneKit
import simd

final class PlaneFleet {
    let root = SCNNode()
    private let shelf: ModelShelf
    private let papers: PaperMaterials
    private let effects: Effects
    let stickers = StickerMaterials()

    private final class Visual {
        let node: SCNNode
        /// The folded model, which a collision crumples.
        let model: SCNNode
        /// Every node carrying the paper, for swapping in a damaged sheet.
        let skins: [SCNNode]
        /// Where stickers are stuck: the model's own space, scaled with it.
        let stickerHolder: SCNNode
        /// Trails hang off this rather than the plane, so a crash can hand them to the scene
        /// to finish fading instead of cutting them off mid-air.
        let tail: SCNNode
        let paper: Paper
        let flutter: Float
        var scraps: SCNParticleSystem?
        var smoke: SCNParticleSystem?
        var glint: SCNParticleSystem?
        var damage = 0
        var stickerCount = 0

        init(node: SCNNode, model: SCNNode, skins: [SCNNode], stickerHolder: SCNNode, tail: SCNNode, paper: Paper,
             flutter: Float) {
            self.node = node
            self.model = model
            self.skins = skins
            self.stickerHolder = stickerHolder
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
            pose(visual, plane, alpha: alpha, time: time, terrain: sim.terrain)
            trails(visual, plane, now: sim.time)
            wear(visual, plane)
        }
        for (id, visual) in visuals where !seen.contains(id) {
            retire(visual)
            visuals[id] = nil
        }
    }

    /// A model of the plane's type folded from its paper, at its on-screen size for `scale`.
    func model(type: PlaneType, paper: Paper, scale: Float, material: SCNMaterial? = nil) -> SCNNode {
        let template = shelf.plane(type)
        let instance = template.instance(size: type.spec(scale: scale).size, along: .footprint)
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
        let model = model(type: plane.type, paper: plane.paper, scale: plane.spec.scale)
        node.addChildNode(model)
        var skins: [SCNNode] = []
        model.enumerateHierarchy { child, _ in if child.geometry != nil { skins.append(child) } }
        // The template's own space at the model's size, so a sticker spot found on the template
        // lands where it was found.
        let template = shelf.plane(plane.type)
        let holder = SCNNode()
        holder.simdScale = SIMD3(repeating: plane.spec.size / max(template.extent.x, template.extent.z, 1e-5))
        model.addChildNode(holder)
        let tail = SCNNode()
        tail.simdPosition = SIMD3(-plane.spec.size * 0.45, 0, 0)
        node.addChildNode(tail)
        root.addChildNode(node)
        return Visual(node: node, model: model, skins: skins, stickerHolder: holder, tail: tail, paper: plane.paper,
                      flutter: Float(plane.id % 97) * 0.731)
    }

    /// Marks on the paper as the armour goes, a sticker for each milestone, and a crumpled nose
    /// on a plane that ran into another.
    private func wear(_ visual: Visual, _ plane: Plane) {
        let stage = plane.damageStage
        if stage != visual.damage {
            let skin = papers.material(for: plane.paper, aspect: CGFloat(shelf.plane(plane.type).sheetAspect),
                                       damage: stage)
            for node in visual.skins { node.geometry?.materials = [skin] }
            visual.damage = stage
        }
        let earned = plane.stickers
        if earned.count > visual.stickerCount {
            let spots = shelf.stickerSpots(plane: plane.type)
            for index in visual.stickerCount..<earned.count where index < spots.count {
                visual.stickerHolder.addChildNode(StickerSpots.decal(earned[index], at: spots[index], materials: stickers))
            }
            visual.stickerCount = earned.count
        }
        // Squashed nose to tail and buckled: what a paper plane looks like after it has hit
        // something, and different enough from a clean spiral to say why it is falling.
        visual.model.simdScale = plane.crumpled ? SIMD3(0.7, 1.25, 0.85) : SIMD3(repeating: 1)
    }

    private func pose(_ visual: Visual, _ plane: Plane, alpha: Float, time: Double, terrain: Terrain) {
        let a = plane.previous, b = plane.pose
        let position = a.position + (b.position - a.position) * alpha
        let altitude = a.altitude + (b.altitude - a.altitude) * alpha
        let heading = a.heading + (b.heading - a.heading).wrappedAngle * alpha
        let bank = a.bank + (b.bank - a.bank) * alpha
        let pitch = a.pitch + (b.pitch - a.pitch) * alpha

        // Paper is light: a plane in the air never sits quite still on its line. One rolling down
        // a runway does — it is on the ground — and the flutter comes in as it climbs away, or a
        // wingtip would dip through the strip it is rolling on.
        let t = time + Double(visual.flutter)
        let aloft: Float = plane.state.isTakingOff
            ? smoothstep(0.02, 0.15, altitude - terrain.surfaceHeight(at: position)) : 1
        let flutterRoll = (0.07 * wave(t, rate: 6.1) + 0.03 * wave(t, rate: 13.7)) * aloft
        let flutterPitch = 0.04 * wave(t, rate: 4.3, phase: 1.1) * aloft
        let bob = 0.006 * wave(t, rate: 3.1) * aloft

        visual.node.simdPosition = position.scene(altitude: altitude + bob)
        // Yaw about +Y takes the model's nose (+X) to the sim heading; pitch about the model's
        // own +Z lifts the nose; and its left wing is -Z, so a positive roll about +X *raises*
        // the left wing — a left turn (positive bank) therefore rolls by -bank.
        visual.node.simdOrientation =
            simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: pitch + flutterPitch, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: -bank + flutterRoll, axis: SIMD3(1, 0, 0))
    }

    private func trails(_ visual: Visual, _ plane: Plane, now: Double) {
        // A supply drop's better weapon glitters behind the plane for as long as it lasts.
        let powered = plane.powerUp(at: now)
        if let powered, visual.glint == nil, !plane.state.isDowned {
            let system = effects.glintTrail(powered, scale: plane.spec.scale)
            visual.tail.addParticleSystem(system)
            visual.glint = system
        } else if (powered == nil || plane.state.isDowned), let glint = visual.glint {
            glint.birthRate = 0
            visual.glint = nil
        }
        if (plane.isDamaged || plane.state.isDowned), visual.scraps == nil {
            let system = effects.scrapTrail(color: PaperPalette.base(plane.paper), scale: plane.spec.scale)
            visual.tail.addParticleSystem(system)
            visual.scraps = system
        }
        if plane.state.isDowned, visual.smoke == nil {
            let system = effects.smokeTrail(scale: plane.spec.scale)
            visual.tail.addParticleSystem(system)
            visual.smoke = system
        }
    }

    /// The plane has crashed or flown off: its trail stays where it was drawn and fades out.
    ///
    /// The node itself is kept, with the model hidden and emission stopped, because a particle
    /// system's live particles go with the node it hangs on.
    private func retire(_ visual: Visual) {
        guard visual.scraps != nil || visual.smoke != nil || visual.glint != nil else {
            visual.node.removeFromParentNode()
            return
        }
        for child in visual.node.childNodes where child !== visual.tail { child.isHidden = true }
        visual.scraps?.birthRate = 0
        visual.smoke?.birthRate = 0
        visual.glint?.birthRate = 0
        effects.hold(visual.node, for: 2)
    }
}
