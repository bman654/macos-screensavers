// Supply drops, as nodes: a paper crate under a tissue-paper parachute, drifting down into the
// fight, swaying under its canopy and slowly turning — which, seen from overhead where the canopy
// hides the crate, is what makes it read as falling rather than hanging. On the ground the canopy
// slumps over beside the crate, and both fade; in a lake they go under.
//
// A taken crate simply disappears from the sim, and the scene's reaction to the event bursts it
// into confetti where it was (`Effects.cratePop`).

import Foundation
import SceneKit
import simd

final class SupplyField {
    let root = SCNNode()
    private let shelf: ModelShelf

    private final class Visual {
        let node: SCNNode
        /// The knot where the strings meet the crate's top: the pivot the pair sways about.
        let knot: SCNNode
        let canopy: SCNNode
        let phase: Double
        init(node: SCNNode, knot: SCNNode, canopy: SCNNode, phase: Double) {
            self.node = node
            self.knot = knot
            self.canopy = canopy
            self.phase = phase
        }
    }

    private var visuals: [Int: Visual] = [:]

    /// Both models drawn a quarter over their authored size: at the library's 5 cm a crate under
    /// an 11 cm canopy was a pale speck from up here. The sim's reach for a grab is set from the
    /// same heights (`SupplyDrop.canopyHeight`).
    static let modelScale: Float = 1.25

    init(shelf: ModelShelf) { self.shelf = shelf }

    func sync(_ sim: DogfightSim, alpha: Float, time: Double) {
        let now = sim.time + Double(alpha) * DogfightSim.stepSeconds
        var seen = Set<Int>()
        for drop in sim.drops {
            seen.insert(drop.id)
            let visual = visuals[drop.id] ?? make(drop)
            visuals[drop.id] = visual
            pose(visual, drop, alpha: alpha, now: now, time: time)
        }
        for (id, visual) in visuals where !seen.contains(id) {
            visual.node.removeFromParentNode()
            visuals[id] = nil
        }
    }

    private func make(_ drop: SupplyDrop) -> Visual {
        let crate = shelf.crate()
        let crateNode = crate.instance(scale: SupplyField.modelScale)
        let top = crate.extent.y * SupplyField.modelScale
        let knot = SCNNode()
        knot.simdPosition = SIMD3(0, top, 0)
        crateNode.simdPosition = SIMD3(0, -top, 0)
        knot.addChildNode(crateNode)
        let canopy = shelf.parachute().instance(scale: SupplyField.modelScale)
        knot.addChildNode(canopy)
        let node = SCNNode()
        node.addChildNode(knot)
        root.addChildNode(node)
        return Visual(node: node, knot: knot, canopy: canopy, phase: Double(drop.id % 89) * 0.37)
    }

    private func pose(_ visual: Visual, _ drop: SupplyDrop, alpha: Float, now: Double, time: Double) {
        let position = drop.previousPosition + (drop.position - drop.previousPosition) * alpha
        let altitude = drop.previousAltitude + (drop.altitude - drop.previousAltitude) * alpha
        visual.node.simdPosition = position.scene(altitude: altitude)
        visual.node.opacity = CGFloat(drop.opacity(at: now))

        switch drop.state {
        case .falling:
            // A slow pendulum about the knot, on two axes at different rates so it never settles
            // into a line, and a slow turn about the vertical that shows the canopy's stripe going
            // round from overhead.
            let swayX = 0.16 * wave(time, rate: 1.3, phase: visual.phase)
            let swayZ = 0.12 * wave(time, rate: 0.9, phase: visual.phase * 1.7)
            let turn = Float((time * 0.5 + visual.phase).truncatingRemainder(dividingBy: 2 * .pi))
            visual.knot.simdOrientation = simd_quatf(angle: swayX, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: swayZ, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: turn, axis: SIMD3(0, 1, 0))
            visual.canopy.simdScale = SIMD3(repeating: 1)
            visual.canopy.simdPosition = .zero
            visual.canopy.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        case .landed(let at), .sinking(let at):
            // The crate settles upright; the canopy, with nothing holding it up, slumps over
            // downwind and lies flat beside it.
            let t = smoothstep(0, 1, Float((now - at) / 0.9))
            let downwind = unit(drop.drift, or: SIMD2(1, 0))
            let tilt = simd_quatf(angle: -1.35 * t, axis: SIMD3(-downwind.y, 0, -downwind.x))
            visual.knot.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
            visual.canopy.simdOrientation = tilt
            visual.canopy.simdScale = SIMD3(1, 1 - 0.55 * t, 1)
            if case .sinking = drop.state {
                // Through the water's opaque surface, which hides it as it goes.
                visual.node.simdPosition.y -= 0.12 * Float(min(max((now - at) / SupplyDrop.sinkTime, 0), 1))
            }
        }
    }
}
