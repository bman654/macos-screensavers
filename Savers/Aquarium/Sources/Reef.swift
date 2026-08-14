// Turning a layout into geometry. `ReefLayout` decides what goes where; this seats it.
//
// It also hands back what it seated, which it did not use to. Three separate features need to
// know that *this* node is that chest and stands there — the bubbler cycle has to find
// `part_lid` on one instance rather than on the template every instance was cloned from, the
// clownfish has to find a placed anemone to be site-attached to, and a foraging fish has to know
// what is standing under it. Rebuilding that association by walking the node tree afterwards
// would mean recovering from geometry what the layout already knew.

import Foundation
import SceneKit
import simd

/// One prop, as it actually stands in this tank: what the library says it is, where the layout
/// put it, and the node that became of it.
struct PropInstance {
    let manifest: ModelManifest
    let placement: PropPlacement
    /// A child of the reef node, and therefore in the *seabed's* space — origin on the floor,
    /// x across the frame and z into it. Not world space: the seabed is translated down by
    /// `Tank.floorY`, and it moves when the drawable reshapes.
    let root: SCNNode

    /// Where it stands on the floor plane, in the seabed's space. `PropPlacement.position` is a
    /// 2D point in that plane and this is the same point named in the coordinates everything
    /// else uses, so that no caller has to remember which of `y` and `z` it meant.
    var groundPosition: SIMD2<Float> { placement.position }

    /// How far it reaches out from that point, and how far up. Both at the scale it was drawn
    /// at, since a prop's manifest states it untilted at scale 1.0.
    var radius: Float { (manifest.placement?.footprint ?? 0) * placement.scale }
    var height: Float { (manifest.placement?.height ?? 0) * placement.scale }
}

enum Reef {
    struct Built {
        /// Everything standing on the floor, under one node in the seabed's space — so the
        /// reef's own origin *is* the floor, and it follows the floor when the drawable
        /// changes shape.
        let node: SCNNode
        /// In layout order, and only the props that actually loaded. A model whose archive is
        /// missing is absent from both this and the node, which is what keeps a partially
        /// regenerated library rendering a tank rather than trapping.
        let props: [PropInstance]
    }

    static func build(placements: [PropPlacement], cache: ModelCache) -> Built {
        let reef = SCNNode()
        var props: [PropInstance] = []
        for placement in placements {
            guard let model = cache.model(named: placement.manifest.asset) else { continue }
            let root = seat(placement, model: model)
            reef.addChildNode(root)
            props.append(PropInstance(manifest: placement.manifest,
                                      placement: placement, root: root))
        }
        return Built(node: reef, props: props)
    }

    private static func seat(_ placement: PropPlacement, model: ModelCache.LoadedModel) -> SCNNode {
        // `clone()` copies the node *tree* while sharing geometry and materials, so a dozen
        // boulders cost a dozen transforms and one set of vertex buffers. That it copies the
        // nodes is what makes an articulated prop safe to place twice: `part_lid` is a distinct
        // node on every instance, so two chests in one tank hinge independently and the stagger
        // that keeps them from looking mechanical actually holds. Nothing here may reach for
        // `flattenedClone()`, which merges the hierarchy into one node and would take the parts
        // with it.
        //
        // Sharing materials is right for a prop, unlike a fish: no prop carries a per-instance
        // material uniform.
        let instance = model.template.clone()

        // Blender exports Z-up and `build_prop.py` seats the lowest vertex on z = 0, centred on
        // X and Y. The tank is Y-up, so the correction is the same -π/2 the school uses — and
        // because the model arrives already seated, nothing here adjusts its height. That is
        // deliberate: the manifest is the contract, and deriving a prop's extent from its
        // geometry instead would inherit the over-report that a rotated hierarchy produces.
        let pivot = SCNNode()
        pivot.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        pivot.scale = SCNVector3(placement.scale, placement.scale, placement.scale)
        pivot.addChildNode(instance)

        let yawNode = SCNNode()
        yawNode.eulerAngles = SCNVector3(0, placement.yaw, 0)
        yawNode.addChildNode(pivot)

        let root = SCNNode()
        root.addChildNode(yawNode)
        // Leaning about a horizontal axis through the base centre lifts one edge of the contact
        // patch clear of the floor by `footprint * sin(tilt)`. Sinking the prop by that much is
        // what keeps a tilted boulder in the sand rather than balanced on a corner above it —
        // 3.6 cm at the boulder's 8° limit, which is several pixels of daylight at reef depth.
        let sink = (placement.manifest.placement?.footprint ?? 0)
            * placement.scale * sin(placement.tilt)
        root.position = SCNVector3(placement.position.x, -sink, placement.position.y)
        // Tilt about a horizontal axis of its own azimuth rather than folding the lean into the
        // yaw, so that which way a prop leans is independent of which way it faces.
        root.rotation = SCNVector4(cos(placement.tiltAxis), 0, sin(placement.tiltAxis),
                                   placement.tilt)
        return root
    }
}
