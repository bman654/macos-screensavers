// Turning a layout into geometry. `ReefLayout` decides what goes where; this seats it.

import Foundation
import SceneKit

enum Reef {
    /// Everything standing on the floor, under one node in the seabed's space — so the reef's
    /// own origin *is* the floor, and it follows the floor when the drawable changes shape.
    static func node(placements: [PropPlacement], cache: ModelCache) -> SCNNode {
        let reef = SCNNode()
        for placement in placements {
            guard let model = cache.model(named: placement.manifest.asset) else { continue }
            reef.addChildNode(seat(placement, model: model))
        }
        return reef
    }

    private static func seat(_ placement: PropPlacement, model: ModelCache.LoadedModel) -> SCNNode {
        // `clone()` shares geometry and materials with the template, so a dozen boulders cost a
        // dozen transforms and one set of vertex buffers. Unlike a fish, a prop has no
        // per-instance material uniform, so sharing materials is exactly what is wanted here.
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
