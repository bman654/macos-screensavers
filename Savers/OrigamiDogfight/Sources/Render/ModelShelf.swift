// Every model the scene asks for, from the Blender library when it has one and from
// `StandIns` when it does not — and the props laid out on the landscape from them.

import Foundation
import SceneKit
import simd

final class ModelShelf {
    let library: OrigamiLibrary
    private var cache: [String: ModelTemplate] = [:]
    private var propCache: [PropKind: [ModelTemplate]] = [:]

    init(library: OrigamiLibrary) { self.library = library }

    func plane(_ type: PlaneType) -> ModelTemplate {
        cached("plane-\(type.modelName)") {
            library.template(named: type.modelName, anchor: .center) ?? StandIns.plane(type)
        }
    }

    func projectile(_ kind: WeaponKind) -> ModelTemplate {
        cached("shot-\(kind.rawValue)") {
            kind.modelName.flatMap { library.template(named: $0, anchor: .center) } ?? StandIns.projectile(kind)
        }
    }

    func fire() -> ModelTemplate {
        cached("fire") {
            library.names(ofKind: "fire").first.flatMap { library.template(named: $0, anchor: .base) }
                ?? StandIns.fire()
        }
    }

    /// The Blender smoke puff, or nil — the caller then folds one from an icosphere.
    func smoke() -> ModelTemplate? {
        if let hit = cache["smoke"] { return hit }
        guard let name = library.names(ofKind: "smoke").first,
              let template = library.template(named: name, anchor: .center) else { return nil }
        cache["smoke"] = template
        return template
    }

    /// Every model of a prop kind; a spot's `variant` picks among them.
    func props(_ kind: PropKind) -> [ModelTemplate] {
        if let hit = propCache[kind] { return hit }
        var templates = library.names(ofKind: kind.rawValue).compactMap { library.template(named: $0, anchor: .base) }
        if templates.isEmpty {
            let variants: Int
            switch kind {
            case .tree: variants = 6
            case .rock: variants = 3
            case .house: variants = 3
            case .boat: variants = 1
            }
            templates = (0..<variants).map { StandIns.prop(kind, variant: $0) }
        }
        propCache[kind] = templates
        return templates
    }

    private func cached(_ key: String, _ make: () -> ModelTemplate) -> ModelTemplate {
        if let hit = cache[key] { return hit }
        let template = make()
        cache[key] = template
        return template
    }
}

enum Scenery {
    /// The library's props are authored at their real size in metres — a 6 m tree, a 4 m boat
    /// — and the landscape is a diorama under planes a third of a metre long. One factor for all
    /// of them keeps their sizes relative to each other: a bush stays a bush beside a poplar.
    /// A 6 m tree comes out at 0.12 m, a little under half a plane.
    static let dioramaScale: Float = 0.02

    /// Drawn size of each stand-in prop kind, metres, before a spot's own scale. Stand-ins are
    /// built at unit size, so they have no real size to scale from.
    private static func size(_ kind: PropKind) -> (Float, ModelAxis) {
        switch kind {
        case .tree: return (0.13, .height)
        case .rock: return (0.075, .footprint)
        case .house: return (0.11, .footprint)
        case .boat: return (0.1, .footprint)
        }
    }

    /// All props in one node, flattened: four hundred trees as one geometry per material rather
    /// than four hundred draw calls. Nothing on the landscape moves, so nothing is lost by it.
    ///
    /// Every geometry is first lifted out into a direct child carrying its whole transform.
    /// Flattening the nested instances as built put every prop at the origin at its authored
    /// size — the scale and offset of the holders above each geometry were simply not applied.
    static func node(spots: [PropSpot], shelf: ModelShelf) -> SCNNode {
        let staging = SCNNode()
        let flat = SCNNode()
        for spot in spots {
            let templates = shelf.props(spot.kind)
            guard !templates.isEmpty else { continue }
            let template = templates[spot.variant % templates.count]
            let prop: SCNNode
            if template.isStandIn {
                let (base, axis) = size(spot.kind)
                prop = template.instance(size: base * spot.scale, along: axis)
            } else {
                prop = template.instance(scale: dioramaScale * spot.scale)
            }
            prop.simdPosition = SIMD3(spot.position.x, spot.ground, -spot.position.y)
            prop.simdOrientation = simd_quatf(angle: spot.yaw, axis: SIMD3(0, 1, 0))
            staging.addChildNode(prop)
            prop.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry else { return }
                let leaf = SCNNode(geometry: geometry)
                leaf.simdTransform = staging.simdConvertTransform(matrix_identity_float4x4, from: node)
                flat.addChildNode(leaf)
            }
            prop.removeFromParentNode()
        }
        let merged = flat.flattenedClone()
        merged.name = "scenery"
        return merged
    }
}
