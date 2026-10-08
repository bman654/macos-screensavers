// Everything thrown: spitballs, tacks, clips, staples, bands, paper balls, confetti and pencils —
// in flight tumbling, on the ground lying still until they fade, in a lake going under.
//
// Nodes are pooled per kind, built at scale 1 and scaled to each shot's match. A fight fires a
// dozen shots a second, and a node per shot would be allocation churn for things that live a
// second in the air and a few on the grass.

import Foundation
import SceneKit
import simd

final class ProjectileField {
    let root = SCNNode()
    private let shelf: ModelShelf
    private struct Entry {
        let node: SCNNode
        let kind: WeaponKind
        /// Its trail at night (`ShotGlow`).
        let trail: SCNParticleSystem
        /// Half the model's height as drawn at scale 1, so a landed shot rests on the ground, not
        /// in it.
        let restHeight: Float
    }
    private var live: [Int: Entry] = [:]
    private var pool: [WeaponKind: [Entry]] = [:]
    private var confettiMaterials: [String: SCNMaterial] = [:]

    /// Pencils are drawn larger than their weapon size says: seen from straight above, steeply
    /// climbing, even tilted they show only part of their length.
    static let pencilBoost: Float = 1.25

    private let glow: ShotGlow

    init(shelf: ModelShelf, paint: GlowPaint) {
        self.shelf = shelf
        glow = ShotGlow(paint: paint)
    }

    func sync(_ sim: DogfightSim, alpha: Float) {
        var seen = Set<Int>()
        for p in sim.projectiles {
            seen.insert(p.id)
            let entry = live[p.id] ?? take(p)
            live[p.id] = entry
            let node = entry.node
            let position = p.previousPosition + (p.position - p.previousPosition) * alpha
            let altitude = p.previousAltitude + (p.altitude - p.previousAltitude) * alpha
            let spinRate = simd_length(p.spin)
            let axis = spinRate > 1e-4 ? p.spin / spinRate : SIMD3(0, 1, 0)
            let k = p.scale * (p.kind == .pencil ? ProjectileField.pencilBoost : 1)
            node.simdScale = SIMD3(repeating: k)
            let heading = atan2(p.velocity.y, p.velocity.x)
            switch p.state {
            case .flying:
                node.simdPosition = position.scene(altitude: altitude)
                if p.kind == .pencil {
                    // Point first along its arc, but never more than 50° off level: end-on from
                    // overhead a rising pencil is a tan dot, and the point of it is that it reads
                    // as a pencil thrown up. It turns about its own length as it goes.
                    let pitch = max(min(atan2(p.climb, max(simd_length(p.velocity), 1e-3)), 0.87), -0.87)
                    node.simdOrientation = simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
                        * simd_quatf(angle: pitch, axis: SIMD3(0, 0, 1))
                        * simd_quatf(angle: spinRate * (p.tumble + alpha * DogfightSim.step), axis: SIMD3(1, 0, 0))
                } else {
                    // Along its flight, tumbling about its own axis — a band flies stretched along
                    // its path, a clip turns over and over.
                    node.simdOrientation = simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
                        * simd_quatf(angle: spinRate * (p.tumble + alpha * DogfightSim.step), axis: axis)
                }
            case .landed:
                // At rest the way it was made to lie, turned to wherever it fell.
                node.simdPosition = position.scene(altitude: altitude + entry.restHeight * k)
                node.simdOrientation = simd_quatf(angle: Float(p.id % 360) * .pi / 180, axis: SIMD3(0, 1, 0))
            case .sinking(let at):
                // Going down through the water's surface, which hides it as it goes — the lake is
                // opaque paper, so like a wreck it needs no effect beyond the splash.
                let depth = (entry.restHeight * 2 + p.spec.size * 0.6) * k
                node.simdPosition = position.scene(altitude: altitude + entry.restHeight * k - depth * p.sinking(since: at))
                node.simdOrientation = simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: spinRate * (p.tumble + 0.15 * (p.age - at)), axis: axis)
            }
            node.opacity = CGFloat(p.opacity)
            var flying = false
            if case .flying = p.state { flying = true }
            glow.fly(entry.trail, flying: flying, colour: GlowPaint.colour(for: p.paper))
        }
        for (id, entry) in live where !seen.contains(id) {
            entry.trail.birthRate = 0
            entry.node.isHidden = true
            pool[entry.kind, default: []].append(entry)
            live[id] = nil
        }
    }

    private func take(_ p: Projectile) -> Entry {
        let entry: Entry
        if var free = pool[p.kind], let reused = free.popLast() {
            pool[p.kind] = free
            entry = reused
            entry.node.isHidden = false
        } else {
            let template = shelf.projectile(p.kind)
            glow.dress(template, kind: p.kind)
            let size = p.kind.spec(scale: 1).size
            let node = template.instance(size: size, along: .longest)
            if let bits = glow.bits(kind: p.kind, size: size, seed: p.id) { node.addChildNode(bits) }
            let trail = glow.trail(size: size)
            node.addParticleSystem(trail)
            let longest = max(template.extent.x, template.extent.y, template.extent.z, 1e-5)
            entry = Entry(node: node, kind: p.kind, trail: trail, restHeight: template.extent.y / longest * size / 2)
            if p.kind == .confetti {
                node.enumerateHierarchy { child, _ in
                    if let geometry = child.geometry, let copy = geometry.copy() as? SCNGeometry {
                        child.geometry = copy
                    }
                }
            }
            DayLight.enlist(node)
            root.addChildNode(node)
        }
        if p.kind == .confetti {
            // Hole-punch dots are punched out of the shooter's own paper.
            let material = confettiMaterial(p.paper)
            entry.node.enumerateHierarchy { child, _ in child.geometry?.materials = [material] }
        }
        return entry
    }

    private func confettiMaterial(_ paper: Paper) -> SCNMaterial {
        let key = "\(paper.kind.rawValue)-\(paper.tint)"
        if let hit = confettiMaterials[key] { return hit }
        let material = paperMaterial(PaperPalette.base(paper))
        glow.dress(confetti: material, paper: paper)
        confettiMaterials[key] = material
        return material
    }
}
