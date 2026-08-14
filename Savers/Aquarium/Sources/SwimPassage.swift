// The routes *through* props, and which fish are allowed to take them.
//
// A wreck's hull is a closed mesh whether or not there is a way through it, and nothing
// downstream can infer a route from geometry — so the model states it as ordered `swim_`
// waypoints with the tightest clearance along the way. `docs/decorations.md` is the contract.
//
// The arch and the wreck exist to be swum *through*, not past. A tank of things a fish routes
// around is flat; one opening a fish commits to crossing gives the depth axis something to prove.

import Foundation
import SceneKit
import simd

struct SwimPassage {
    /// In the reef's space — x and z as the world's, y a height above the floor — so a reshape
    /// that moves the floor moves the route with it, exactly as `FishHost` does.
    let waypoints: [SIMD3<Float>]

    /// The tightest clearance anywhere along the route, at the scale this prop was actually
    /// drawn at. **This is where `Tank.propScale` bites**: a prop is shrunk to hold its angular
    /// size while fish keep their real metres, so the wreck's 0.23 m hold is a 7.6 cm hole in a
    /// glass tank. That is not a bug — it is the same asymmetry that makes a small tank read as
    /// a tank — but it is why a passage refuses most of the school in the aquarium and almost
    /// none of it in open water.
    let radius: Float

    /// Whether this route is somewhere an animal would *lurk* rather than merely pass through.
    /// A wreck's hold is a shelter; a gap between two rock pillars is a doorway.
    let isShelter: Bool

    /// Both ends, which are the only places a fish may join.
    var entrances: [SIMD3<Float>] { [waypoints.first, waypoints.last].compactMap { $0 } }

    /// Whether a fish of this girth fits.
    ///
    /// Girth, never length — see `ModelCache.LoadedModel.girth`. A moray is 1.5 m end to end and
    /// thinner through the body than a blue tang a sixth its length, so a test on length refuses
    /// exactly the animal the feature exists for.
    func admits(girth: Float) -> Bool { girth <= radius }

    /// Reads every route out of the placed reef.
    ///
    /// Waypoint nodes are found by name inside the instance and converted into the reef's space,
    /// which folds in the prop's yaw, tilt and scale in one step — deriving them by hand from
    /// `PropPlacement` would duplicate `Reef.seat` and drift from it.
    static func passages(in props: [PropInstance], reefNode: SCNNode) -> [SwimPassage] {
        var routes: [SwimPassage] = []
        for prop in props {
            for spec in prop.manifest.passages {
                let points = spec.nodes.compactMap { name -> SIMD3<Float>? in
                    guard let node = prop.root.childNode(withName: name, recursively: true)
                    else { return nil }
                    let p = node.convertPosition(SCNVector3Zero, to: reefNode)
                    return SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                }
                // A route missing a waypoint is a route with a hole in it, and steering a fish
                // through the gap would send it into whatever the missing point was avoiding.
                // Dropping it costs one feature on one prop; taking it costs a fish inside a hull.
                guard points.count == spec.nodes.count, points.count >= 2 else { continue }
                routes.append(SwimPassage(waypoints: points,
                                          radius: spec.radius * prop.placement.scale,
                                          isShelter: prop.manifest.isShelter))
            }
        }
        return routes
    }
}

extension ModelManifest {
    /// Whether this prop is somewhere to hide rather than somewhere to pass through.
    ///
    /// Hard-coded alongside `isManmade` and `isSiteAttached`, and carrying the same debt: it is
    /// authoring data and belongs in the manifest once a second prop needs it. An aquarium with a
    /// wreck in it always has something living inside the wreck, and that is the whole reason the
    /// distinction exists at all.
    var isShelter: Bool { ModelManifest.shelterProps.contains(name) }

    /// Species that would rather be under something than out in the water.
    ///
    /// The eel is the case: a moray in a tank is not a fish that crosses open water, it is a head
    /// in a hole. Without this it swims the tank like a very long tang, which is the same category
    /// of wrongness as a clownfish patrolling away from its anemone.
    var isLurker: Bool { ModelManifest.lurkingFish.contains(name) }

    private static let shelterProps: Set<String> = ["sunken_ship"]
    private static let lurkingFish: Set<String> = ["moray_eel"]
}
