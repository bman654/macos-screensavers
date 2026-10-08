// Where the camera is, and therefore what the planes may use.
//
// The sim owns the camera's geometry rather than the renderer, because "stay in view" is an AI
// rule: the soft wall the pilots steer away from is the camera's visible rectangle projected
// onto the flight band. The renderer places its `SCNCamera` from these same numbers, so the
// two cannot disagree about where the edge of the screen is.
//
// Sim axes: x east (screen right), y north (screen up), z altitude. The renderer maps
// (x, y, z) to SceneKit's Y-up space as (x, z, -y).

import Foundation
import simd

struct ViewRig {
    /// The band the planes fly in, metres above the datum. The terrain's highest peak stays
    /// well under the bottom of it (`Terrain.maxHeight`), so a live plane never meets a hill.
    static let bandLow: Float = 0.72
    static let bandHigh: Float = 1.12
    static var bandMid: Float { (bandLow + bandHigh) / 2 }

    /// Vertical field of view. Narrow enough that altitude reads as a modest change of size
    /// rather than a fisheye, wide enough that the shadow offset still separates a high plane
    /// from a low one.
    static let verticalFOV: Float = 34 * .pi / 180

    /// How far off straight down the camera looks, toward the top of the screen. A slight tilt
    /// is what lets hills read as relief instead of as a flat map.
    static let tilt: Float = 11 * .pi / 180

    /// The area of the arena at mid-band, held constant across aspect ratios.
    ///
    /// Not the width: pinning the width would leave an ultra-wide display a strip a metre high,
    /// with no room to turn, and give a portrait one a tall well. Holding the area keeps the
    /// fight equally crowded at any shape — a 16:9 frame comes out 4.6 x 2.6 m, about sixteen
    /// plane lengths across.
    static let arenaArea: Float = 12.0

    /// How far inside the visible edge the soft wall stands, so a plane turning along it keeps
    /// its whole body — and the wing it is banked onto — on screen.
    static let wallInset: Float = 0.2

    let aspect: Float
    let eye: SIMD3<Float>
    let forward: SIMD3<Float>
    let up: SIMD3<Float>
    let right: SIMD3<Float>

    /// The visible region at the top of the band, which is the smallest the planes ever see,
    /// inset by `wallInset`. Counter-clockwise from bottom-left.
    let wall: ConvexQuad

    init(aspect rawAspect: Float) {
        let aspect = rawAspect.isFinite && rawAspect > 0.1 ? min(rawAspect, 10) : 16.0 / 9.0
        self.aspect = aspect
        let tilt = ViewRig.tilt
        forward = SIMD3(0, sin(tilt), -cos(tilt))
        up = SIMD3(0, cos(tilt), sin(tilt))
        right = SIMD3(1, 0, 0)
        let halfHeight = sqrt(ViewRig.arenaArea / aspect) / 2
        let distance = halfHeight / tan(ViewRig.verticalFOV / 2)
        eye = SIMD3(0, 0, ViewRig.bandMid) - forward * distance

        let top = ViewRig.visibleQuad(eye: eye, forward: forward, up: up, right: right,
                                      aspect: aspect, altitude: ViewRig.bandHigh)
        wall = top.inset(by: ViewRig.wallInset)
    }

    /// What the camera sees on the horizontal plane at `altitude`.
    func visible(atAltitude altitude: Float) -> ConvexQuad {
        ViewRig.visibleQuad(eye: eye, forward: forward, up: up, right: right,
                            aspect: aspect, altitude: altitude)
    }

    /// Where a point at `altitude` lands in the frame: -1 to 1 across and up, the frame's edges
    /// at ±1. The inverse of `visible(atAltitude:)`'s corners.
    func screen(_ point: SIMD2<Float>, altitude: Float) -> SIMD2<Float> {
        let v = SIMD3(point.x, point.y, altitude) - eye
        let depth = max(simd_dot(v, forward), 1e-4)
        let tanV = tan(ViewRig.verticalFOV / 2)
        return SIMD2(simd_dot(v, right) / (depth * tanV * aspect), simd_dot(v, up) / (depth * tanV))
    }

    /// The point on the band the camera is centred on.
    var center: SIMD2<Float> { SIMD2(0, 0) }

    private static func visibleQuad(eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>,
                                    right: SIMD3<Float>, aspect: Float,
                                    altitude: Float) -> ConvexQuad {
        let tanV = tan(verticalFOV / 2)
        let tanH = tanV * aspect
        // Bottom-left, bottom-right, top-right, top-left: counter-clockwise seen from above.
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let points = corners.map { sx, sy -> SIMD2<Float> in
            let ray = forward + right * (sx * tanH) + up * (sy * tanV)
            // The ray always points down — the tilt is far smaller than half the field of view
            // is from horizontal — so the denominator cannot reach zero.
            let t = (altitude - eye.z) / min(ray.z, -1e-4)
            let hit = eye + ray * t
            return SIMD2(hit.x, hit.y)
        }
        return ConvexQuad(points[0], points[1], points[2], points[3])
    }
}

/// A convex quadrilateral, counter-clockwise. The view of a tilted camera on a plane is a
/// trapezoid, not a rectangle — wider at the top — so the wall is tested against its real edges.
struct ConvexQuad {
    let corners: [SIMD2<Float>]
    /// Unit inward normals, one per edge `corners[i] -> corners[i + 1]`.
    let normals: [SIMD2<Float>]

    init(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) {
        let points = [a, b, c, d]
        corners = points
        normals = (0..<4).map { i in
            let edge = simd_normalize(points[(i + 1) % 4] - points[i])
            // Counter-clockwise, so inward is the edge turned left.
            return SIMD2(-edge.y, edge.x)
        }
    }

    /// Signed distance to edge `i`, positive inside.
    func distance(_ point: SIMD2<Float>, edge i: Int) -> Float {
        simd_dot(point - corners[i], normals[i])
    }

    /// The smallest of the four edge distances: positive inside, negative outside.
    func depth(_ point: SIMD2<Float>) -> Float {
        (0..<4).map { distance(point, edge: $0) }.min() ?? 0
    }

    func contains(_ point: SIMD2<Float>, margin: Float = 0) -> Bool {
        depth(point) >= margin
    }

    var centroid: SIMD2<Float> { corners.reduce(SIMD2(0, 0), +) / 4 }

    /// Each edge moved inward by `amount`, by intersecting the shifted edge lines.
    func inset(by amount: Float) -> ConvexQuad {
        let shifted = (0..<4).map { (i: Int) -> (point: SIMD2<Float>, direction: SIMD2<Float>) in
            let point: SIMD2<Float> = corners[i] + normals[i] * amount
            let direction: SIMD2<Float> = corners[(i + 1) % 4] - corners[i]
            return (point, direction)
        }
        let points = (0..<4).map { i -> SIMD2<Float> in
            let previous = shifted[(i + 3) % 4]
            let current = shifted[i]
            return ConvexQuad.intersect(previous.point, previous.direction,
                                        current.point, current.direction) ?? current.point
        }
        return ConvexQuad(points[0], points[1], points[2], points[3])
    }

    /// Axis-aligned extent, for sizing anything that must cover the quad.
    var bounds: (min: SIMD2<Float>, max: SIMD2<Float>) {
        (corners.reduce(corners[0], simd_min), corners.reduce(corners[0], simd_max))
    }

    private static func intersect(_ p: SIMD2<Float>, _ r: SIMD2<Float>,
                                  _ q: SIMD2<Float>, _ s: SIMD2<Float>) -> SIMD2<Float>? {
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-9 else { return nil }
        let t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / denominator
        return p + r * t
    }
}
