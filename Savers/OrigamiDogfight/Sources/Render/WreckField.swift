// What a crash leaves: a plane nose-down in the ground with an origami fire on it, smoke and
// embers rising, until the fire folds away and the wreck fades — or, in a lake, a plane going
// under.
//
// All of it is a function of the wreck's age, which comes from the sim, so a wreck that was
// already burning before this scene was built (a warmup, a wake from an idle release) picks up
// at the right point in its burn rather than starting over.

import AppKit
import Foundation
import SceneKit
import simd

final class WreckField {
    let root = SCNNode()
    private let shelf: ModelShelf
    private let papers: PaperMaterials
    private let effects: Effects
    private let fleet: PlaneFleet

    private final class Visual {
        let node: SCNNode
        let body: SCNNode
        let material: SCNMaterial
        let fire: SCNNode?
        let flames: [Flame]
        let embers: SCNParticleSystem?
        let puffs: [SCNNode]
        let restY: Float

        init(node: SCNNode, body: SCNNode, material: SCNMaterial, fire: SCNNode?,
             flames: [Flame],
             embers: SCNParticleSystem?, puffs: [SCNNode], restY: Float) {
            self.node = node
            self.body = body
            self.material = material
            self.fire = fire
            self.flames = flames
            self.embers = embers
            self.puffs = puffs
            self.restY = restY
        }
    }

    /// One tongue of a fire, and how it flickers. `axis` is its long axis in its own space —
    /// Z for a Blender flame, which keeps its authored axes inside the import's pivot, and Y
    /// for a stand-in — so a lick stretches the flame along its length whichever it is.
    private struct Flame {
        let node: SCNNode
        let base: SIMD3<Float>
        let axis: Int
        let phase: Float
        let rate: Float
    }

    private var visuals: [Int: Visual] = [:]

    /// The fire stands about this tall over a wreck — a little over half a plane.
    private static let fireHeight: Float = 0.16
    private static let noseDown: Float = 0.9

    init(shelf: ModelShelf, papers: PaperMaterials, effects: Effects, fleet: PlaneFleet) {
        self.shelf = shelf
        self.papers = papers
        self.effects = effects
        self.fleet = fleet
    }

    func sync(_ sim: DogfightSim, time: Double) {
        var seen = Set<Int>()
        for wreck in sim.wrecks {
            seen.insert(wreck.id)
            let visual = visuals[wreck.id] ?? make(wreck)
            visuals[wreck.id] = visual
            animate(visual, wreck, age: sim.time - wreck.crashedAt, time: time)
        }
        for (id, visual) in visuals where !seen.contains(id) {
            visual.node.removeFromParentNode()
            visuals[id] = nil
        }
    }

    private func make(_ wreck: Wreck) -> Visual {
        let node = SCNNode()
        node.simdPosition = wreck.position.scene(altitude: wreck.ground)
        node.simdOrientation = simd_quatf(angle: wreck.heading, axis: SIMD3(0, 1, 0))

        // Its own copy of the paper, because this one scorches and fades and the planes still
        // flying in the same paper must not.
        let shared = papers.material(for: wreck.paper, aspect: CGFloat(shelf.plane(wreck.type).sheetAspect))
        let material = (shared.copy() as? SCNMaterial) ?? shared
        let body = fleet.model(type: wreck.type, paper: wreck.paper, material: material)
        // Nose-down in the ground, buried a little, at the bank it came in on.
        let length = wreck.type.spec.size
        let restY = sin(WreckField.noseDown) * length * 0.32
        body.simdPosition = SIMD3(0, restY, 0)
        body.simdOrientation = simd_quatf(angle: -WreckField.noseDown, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: wreck.roll, axis: SIMD3(1, 0, 0))
        node.addChildNode(body)

        var fire: SCNNode?
        var flames: [Flame] = []
        var embers: SCNParticleSystem?
        var puffs: [SCNNode] = []
        if !wreck.inWater {
            let template = shelf.fire()
            let instance = template.instance(size: WreckField.fireHeight, along: .height)
            // Just behind where the nose went in, so the fire wraps the crumpled body.
            instance.simdPosition = SIMD3(length * 0.05, 0, 0)
            instance.enumerateHierarchy { child, _ in child.castsShadow = false }
            node.addChildNode(instance)
            fire = instance
            var index: Float = 0
            instance.enumerateHierarchy { child, _ in
                guard let name = child.name, name.hasPrefix("flame_") else { return }
                let (lo, hi) = child.boundingBox
                let extent = SIMD3(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))
                let axis = extent.z > extent.y && extent.z > extent.x ? 2 : (extent.x > extent.y ? 0 : 1)
                flames.append(Flame(node: child, base: child.simdScale, axis: axis,
                                    phase: Float(wreck.id) * 1.7 + index * 2.3,
                                    rate: 7 + index.truncatingRemainder(dividingBy: 3) * 2.5))
                index += 1
            }
            let emitter = SCNNode()
            emitter.simdPosition = SIMD3(0, WreckField.fireHeight * 0.6, 0)
            let system = effects.embers()
            emitter.addParticleSystem(system)
            node.addChildNode(emitter)
            embers = system
            puffs = (0..<4).map { _ in smokePuff(parent: node) }
        }
        root.addChildNode(node)
        return Visual(node: node, body: body, material: material, fire: fire, flames: flames,
                      embers: embers, puffs: puffs, restY: restY)
    }

    /// A folded grey cloud — the Blender puff if there is one, else a crumpled ball.
    private func smokePuff(parent: SCNNode) -> SCNNode {
        let puff: SCNNode
        if let template = shelf.smoke() {
            puff = template.instance(size: 0.07, along: .longest)
        } else {
            let geometry = StandIns.icosphere(radius: 0.022, crumple: 0.15, seed: 3,
                                              material: paperMaterial(PaperColor(0.70, 0.69, 0.68)))
            puff = SCNNode(geometry: geometry)
        }
        puff.castsShadow = false
        puff.opacity = 0
        parent.addChildNode(puff)
        return puff
    }

    private func animate(_ visual: Visual, _ wreck: Wreck, age: Double, time: Double) {
        let t = Float(time)
        if wreck.inWater {
            // Down through the water's surface, which hides it as it goes — the lake is opaque
            // paper, so the sinking reads with no special effect at all.
            let sink = smoothstep(0, 1, Float(age / Wreck.sinkDuration))
            visual.body.simdPosition = SIMD3(0, visual.restY - 0.2 * sink, 0)
            visual.node.opacity = CGFloat(1 - smoothstep(0.7, 1, Float(age / Wreck.sinkDuration)))
            return
        }

        let burning = age < Wreck.fireDuration
        let folding = Float((age - Wreck.fireDuration) / Wreck.foldDuration)
        // The fire catches over half a second, burns, then folds down flat and away.
        let catchUp = smoothstep(0, 0.5, Float(age))
        let fold = burning ? 1 : max(0, 1 - smoothstep(0, 1, folding))
        for flame in visual.flames {
            let lick = 0.78 + 0.22 * sin(t * flame.rate + flame.phase) + 0.12 * sin(t * flame.rate * 2.3 + flame.phase * 1.7)
            let sway = 1 + 0.1 * sin(t * flame.rate * 0.7 + flame.phase)
            let k = max(catchUp * fold, 0.001)
            var stretch = SIMD3<Float>(repeating: sway * k)
            stretch[flame.axis] = lick * k
            flame.node.simdScale = flame.base * stretch
        }
        visual.embers?.birthRate = burning ? 9 : 0

        // Smoke: puffs on a loop, each rising, swelling, thinning out and drifting downwind.
        // The drift is not decoration — the camera is overhead, so smoke rising straight up
        // would sit between it and the fire and hide the flames entirely.
        let cycle: Float = 2.8
        let count = Float(visual.puffs.count)
        for (index, puff) in visual.puffs.enumerated() {
            let phase = (Float(age) + Float(index) * cycle / count).truncatingRemainder(dividingBy: cycle) / cycle
            let alive = burning || folding < 1
            let drift = SIMD3<Float>(0.75, 0, 0.35) * (0.05 + 0.3 * phase)
            let wobble = SIMD3<Float>(0.015 * sin(t * 1.3 + Float(index) * 2), 0, 0.015 * cos(t + Float(index)))
            // Rotated out of the wreck's own heading, so every fire's smoke leans the same way.
            let world = simd_quatf(angle: -wreck.heading, axis: SIMD3(0, 1, 0)).act(drift + wobble)
            puff.simdPosition = world + SIMD3(0, WreckField.fireHeight * (0.7 + 1.6 * phase), 0)
            puff.simdScale = SIMD3(repeating: 0.7 + 1.8 * phase)
            puff.opacity = alive ? CGFloat(0.6 * sin(.pi * phase) * min(Float(age), 1) * fold) : 0
        }

        // The paper scorches while it burns.
        let char = smoothstep(0, 9, Float(age))
        let shade = 1 - 0.45 * CGFloat(char)
        visual.material.multiply.contents = NSColor(srgbRed: shade, green: shade * 0.93, blue: shade * 0.86, alpha: 1)

        let fading = Float((age - Wreck.fireDuration - Wreck.foldDuration) / Wreck.fadeDuration)
        visual.body.opacity = CGFloat(1 - smoothstep(0, 1, fading))
    }
}
