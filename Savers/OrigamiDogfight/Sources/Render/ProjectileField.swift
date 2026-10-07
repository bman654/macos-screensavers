// Everything thrown: spitballs, tacks, clips, staples, bands, paper balls and confetti — in
// flight tumbling, and on the ground lying still until they fade.
//
// Nodes are pooled per kind. A fight fires a dozen shots a second, and a node per shot would be
// allocation churn for things that live a second in the air and a few on the grass.

import Foundation
import SceneKit
import simd

final class ProjectileField {
    let root = SCNNode()
    private let shelf: ModelShelf
    private struct Entry {
        let node: SCNNode
        let kind: WeaponKind
        /// Half the model's height as drawn, so a landed shot rests on the ground, not in it.
        let restHeight: Float
    }
    private var live: [Int: Entry] = [:]
    private var pool: [WeaponKind: [Entry]] = [:]
    private var confettiMaterials: [String: SCNMaterial] = [:]

    init(shelf: ModelShelf) { self.shelf = shelf }

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
            switch p.state {
            case .flying:
                node.simdPosition = position.scene(altitude: altitude)
                let heading = atan2(p.velocity.y, p.velocity.x)
                // Along its flight, tumbling about its own axis — a band flies stretched along
                // its path, a clip turns over and over.
                node.simdOrientation = simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: spinRate * (p.tumble + alpha * DogfightSim.step), axis: axis)
            case .landed:
                // At rest the way it was made to lie, turned to wherever it fell.
                node.simdPosition = position.scene(altitude: altitude + entry.restHeight)
                node.simdOrientation = simd_quatf(angle: Float(p.id % 360) * .pi / 180, axis: SIMD3(0, 1, 0))
            }
            node.opacity = CGFloat(p.opacity)
        }
        for (id, entry) in live where !seen.contains(id) {
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
            let node = template.instance(size: p.kind.spec.size, along: .longest)
            let longest = max(template.extent.x, template.extent.y, template.extent.z, 1e-5)
            entry = Entry(node: node, kind: p.kind, restHeight: template.extent.y / longest * p.kind.spec.size / 2)
            if p.kind == .confetti {
                node.enumerateHierarchy { child, _ in
                    if let geometry = child.geometry, let copy = geometry.copy() as? SCNGeometry {
                        child.geometry = copy
                    }
                }
            }
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
        confettiMaterials[key] = material
        return material
    }
}
