// A tree the fire spread to: it catches, burns briefly, stands charred until the next match, and
// then folds back to green.
//
// The woods are one flattened node (`Scenery`), so a single tree in them cannot be recoloured.
// Instead the burnt tree is a second copy of it in char-black paper, a few percent larger, standing
// over the green one and hiding it: from above, a canopy that encloses another is all that shows.
// Folding back to green is that copy flattening down into the ground, the tree it hid unfolding
// out of it.

import AppKit
import Foundation
import SceneKit
import simd

final class TreeFires {
    let root = SCNNode()
    private let shelf: ModelShelf
    private let props: [PropSpot]
    private let lights: GroundLights
    private var visuals: [Int: Visual] = [:]

    private final class Visual {
        let node: SCNNode
        /// The charred copy of the tree, which fades in and later folds away apart from the fire.
        let overlay: SCNNode
        let char: SCNMaterial
        let fire: SCNNode
        let flames: [(node: SCNNode, base: SIMD3<Float>, axis: Int, phase: Double, rate: Double)]
        /// Where its light comes from — the middle of the burning crown — and how far it reaches.
        let glow: SIMD3<Float>
        let reach: Float
        init(node: SCNNode, overlay: SCNNode, char: SCNMaterial, fire: SCNNode,
             flames: [(node: SCNNode, base: SIMD3<Float>, axis: Int, phase: Double, rate: Double)],
             glow: SIMD3<Float>, reach: Float) {
            self.glow = glow
            self.reach = reach
            self.node = node
            self.overlay = overlay
            self.char = char
            self.fire = fire
            self.flames = flames
        }
    }

    init(shelf: ModelShelf, props: [PropSpot], lights: GroundLights) {
        self.lights = lights
        self.shelf = shelf
        self.props = props
    }

    func sync(_ marks: Marks, time: Double) {
        var seen = Set<Int>()
        for burn in marks.fires where time >= burn.catchesAt {
            seen.insert(burn.prop)
            let visual = visuals[burn.prop] ?? make(burn.prop)
            visuals[burn.prop] = visual
            animate(visual, burn, time: time)
        }
        for (prop, visual) in visuals where !seen.contains(prop) {
            visual.node.removeFromParentNode()
            visuals[prop] = nil
        }
    }

    private func make(_ index: Int) -> Visual {
        let spot = props[index]
        let templates = shelf.props(.tree)
        let template = templates[spot.variant % templates.count]
        // The tree exactly as `Scenery` drew it — the stand-in sizes are its own — then 6% over.
        let tree = template.isStandIn
            ? template.instance(size: 0.13 * spot.scale, along: .height)
            : template.instance(scale: Scenery.dioramaScale * spot.scale)
        let height = template.isStandIn ? 0.13 * spot.scale : template.extent.y * Scenery.dioramaScale * spot.scale
        let char = SCNMaterial()
        char.lightingModel = .lambert
        char.diffuse.contents = NSColor(srgbRed: 0.25, green: 0.21, blue: 0.19, alpha: 1)
        char.isDoubleSided = true
        tree.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry, let copy = geometry.copy() as? SCNGeometry else { return }
            copy.materials = geometry.materials.map { _ in char }
            child.geometry = copy
        }
        let node = SCNNode()
        node.simdPosition = spot.position.scene(altitude: spot.ground)
        node.simdOrientation = simd_quatf(angle: spot.yaw, axis: SIMD3(0, 1, 0))
        tree.simdScale = SIMD3(repeating: 1.06)
        node.addChildNode(tree)

        // A fire in the crown, as tall as the tree: a burning tree is a torch, and seen from
        // overhead its height shows only as how far its tongues splay.
        let fire = shelf.fire().instance(size: height * 0.85, along: .height)
        fire.simdPosition = SIMD3(0, height * 0.35, 0)
        fire.enumerateHierarchy { child, _ in child.castsShadow = false }
        var flames: [(SCNNode, SIMD3<Float>, Int, Double, Double)] = []
        var k = 0.0
        fire.enumerateHierarchy { child, _ in
            guard let name = child.name, name.hasPrefix("flame_") else { return }
            let (lo, hi) = child.boundingBox
            let e = SIMD3(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))
            let axis = e.z > e.y && e.z > e.x ? 2 : (e.x > e.y ? 0 : 1)
            flames.append((child, child.simdScale, axis, Double(index) * 1.3 + k * 2.1, 8 + k.truncatingRemainder(dividingBy: 3) * 2))
            k += 1
        }
        node.addChildNode(fire)
        root.addChildNode(node)
        // A burning tree is a torch: its light carries further than a wreck's low fire.
        return Visual(node: node, overlay: tree, char: char, fire: fire, flames: flames,
                      glow: spot.position.scene(altitude: spot.ground + height * 0.55), reach: 0.18 + height * 2.2)
    }

    private func animate(_ visual: Visual, _ burn: TreeFire, time: Double) {
        let age = time - burn.catchesAt
        // The fire takes hold in under a second, and dies back over the last two of its burn.
        let flame = smoothstep(0, 0.8, Float(age)) * (1 - smoothstep(Float(TreeFire.burnTime) - 2, Float(TreeFire.burnTime), Float(age)))
        visual.fire.isHidden = flame <= 0.001
        if flame > 0.001 {
            let phase = Double(burn.prop) * 0.7
            let flicker = 0.8 + 0.12 * wave(time, rate: 6.1, phase: phase) + 0.08 * wave(time, rate: 15.3, phase: phase * 1.9)
            lights.fire(at: visual.glow, radius: visual.reach, colour: WreckField.fireLight * (flame * flicker * 1.1))
        }
        for f in visual.flames where flame > 0.001 {
            let lick = 0.78 + 0.22 * wave(time, rate: f.rate, phase: f.phase) + 0.12 * wave(time, rate: f.rate * 2.3, phase: f.phase * 1.7)
            var stretch = SIMD3<Float>(repeating: (1 + 0.1 * wave(time, rate: f.rate * 0.7, phase: f.phase)) * flame)
            stretch[f.axis] = lick * flame
            f.node.simdScale = f.base * stretch
        }
        // The char spreads over the canopy as it burns, glowing at first.
        let charred = smoothstep(0, 3, Float(age))
        visual.overlay.opacity = CGFloat(charred)
        let ember = CGFloat(0.5 * flame * (1 - charred * 0.6))
        visual.char.emission.contents = NSColor(srgbRed: ember, green: ember * 0.35, blue: ember * 0.08, alpha: 1)

        // Folding back to green: the char flattens into the ground and the green tree stands up
        // out of it.
        if let from = burn.restoreFrom {
            let f = smoothstep(0, Float(TreeFire.restoreTime), Float(time - from))
            visual.overlay.simdScale = SIMD3(1.06 - 0.12 * f, max(1.06 * (1 - f), 0.01), 1.06 - 0.12 * f)
        } else {
            visual.overlay.simdScale = SIMD3(repeating: 1.06)
        }
    }
}
