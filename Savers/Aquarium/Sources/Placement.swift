// Deciding what stands where. No SceneKit: this is the arithmetic of drawing an assortment
// from the library and spacing it on the sand, and `Reef` is what turns the result into nodes.
//
// The composition this aims at is a reef, which is neither a uniform scatter nor a line: a
// couple of large elements to anchor the frame, and many small ones clumped around them with
// open sand in between. Uniform scatter reads as a texture rather than as a place.

import Foundation
import simd

struct PropPlacement {
    let manifest: ModelManifest
    /// On the floor plane: x across the frame, z into it (negative is away from the camera).
    let position: SIMD2<Float>
    let yaw: Float
    /// Tilt magnitude, and the azimuth of the horizontal axis it leans about. Splitting them
    /// keeps the lean independent of the yaw, so a prop's facing and its lean are not welded
    /// together across the whole reef.
    let tilt: Float
    let tiltAxis: Float
    let scale: Float
    /// Cached from the manifest, because the conflict test runs against every prop already
    /// placed and re-deriving it there would recompute a sine per pair.
    let radius: Float
    let minSpacing: Float
}

enum ReefLayout {
    /// A prop this big anchors the frame rather than decorating it. Both tests matter: the
    /// sunken ship is wide and low, the giant kelp is narrow and tall, and each is a showpiece.
    private static let anchorFootprint: Float = 0.5
    private static let anchorHeight: Float = 0.9

    /// How far from a cluster centre its members land — roughly the frame's half-width at the
    /// middle of the reef, so a clump reads as a clump rather than as the whole tank.
    private static let clusterRadius: Float = 1.5

    /// The strip of floor the reef is scattered over. Carried as a value because its near
    /// edge depends on the drawable's shape — see `Tank.reefNearDepth(aspect:)` — and every
    /// depth in the layout is a fraction of it.
    private struct Band {
        let near: Float
        let far: Float

        init(aspect: Float) {
            near = Tank.reefNearDepth(aspect: aspect)
            far = max(Tank.reefFarDepth, near + 1)
        }

        func depth(_ low: Float, _ high: Float, rand: inout Rand) -> Float {
            near + rand.inRange(low, high) * (far - near)
        }

        func clamp(_ depth: Float) -> Float { min(max(depth, near), far) }
    }

    static func layout(props: [ModelManifest], count: Int, anchors anchorCount: Int,
                       distinct budget: Int, aspect: Float,
                       rand: inout Rand) -> [PropPlacement] {
        guard !props.isEmpty, count > 0 else { return [] }
        let band = Band(aspect: aspect)

        let anchorPool = props.filter { isAnchor($0) }
        let fillPool = props.filter { !isAnchor($0) }
        var placed: [PropPlacement] = []
        var used: [String: Int] = [:]

        // Sides alternate across every centre the layout seeds, anchors included. Drawing each
        // side independently is uniform but not balanced: six independent draws land all on one
        // side often enough to see it, and when they do, half the tank is bare sand and the
        // whole composition tips over. Alternating costs nothing and cannot produce that.
        var side: Float = rand.sign()

        // Anchors first, and each seeds a cluster: a reef grows *on* its big structures, so
        // corals gathering at the foot of the arch is both the truth and the better picture.
        var clusters: [SIMD2<Float>] = []
        for index in 0..<anchorCount {
            // Stratified across the far two-thirds of the reef. An anchor near the camera fills
            // the frame on its own — the wreck is 2.4 m across against a 2.7 m frame at 7 m.
            let stratum = Float(index) / Float(max(1, anchorCount))
            let depth = band.depth(0.4 + stratum * 0.35, 0.75 + stratum * 0.25, rand: &rand)
            defer { side = -side }
            guard let placement = attempt(pool: anchorPool, used: used, budget: budget,
                                          placed: placed, band: band, depth: depth, side: side,
                                          near: nil, rand: &rand) else { continue }
            used[placement.manifest.name, default: 0] += 1
            clusters.append(placement.position)
            placed.append(placement)
        }

        // Two or three more centres than the anchors seeded, stratified in depth so the reef
        // occupies the whole tank instead of banding at one distance.
        let extraClusters = 2 + Int(rand.next() * 2)
        for index in 0..<extraClusters {
            let low = Float(index) / Float(extraClusters)
            let depth = band.depth(low, low + 1 / Float(extraClusters), rand: &rand)
            let halfWidth = Tank.halfWidth(atDepth: depth)
            clusters.append(SIMD2<Float>(side * rand.inRange(0.1, 0.85) * halfWidth, -depth))
            side = -side
        }

        // Fill. A failed attempt costs one draw rather than the whole layout: with a tight
        // reef the last few slots are genuinely unplaceable, and forcing them in is what
        // produces interpenetration.
        var attemptsLeft = count * 3
        while placed.count < count && attemptsLeft > 0 && !fillPool.isEmpty {
            attemptsLeft -= 1
            let centre = clusters.isEmpty
                ? SIMD2<Float>(0, -band.depth(0, 1, rand: &rand))
                : clusters[Int(rand.next() * Float(clusters.count)) % clusters.count]
            guard let placement = attempt(pool: fillPool, used: used, budget: budget,
                                          placed: placed, band: band, depth: nil, side: 1,
                                          near: centre, rand: &rand) else { continue }
            used[placement.manifest.name, default: 0] += 1
            placed.append(placement)
        }
        return placed
    }

    private static func isAnchor(_ manifest: ModelManifest) -> Bool {
        guard let placement = manifest.placement else { return false }
        let scale = placement.scaleRange.upper
        return placement.footprint * scale >= anchorFootprint
            || placement.height * scale >= anchorHeight
    }

    /// Draws one prop and hunts for somewhere it fits. Nil when the draw is exhausted or the
    /// reef has no room left for what was drawn.
    ///
    /// `side` places an anchor left or right of centre; it is ignored when a cluster centre is
    /// given, since the cluster already decided which half of the tank this prop is in.
    private static func attempt(pool: [ModelManifest], used: [String: Int], budget: Int,
                                placed: [PropPlacement], band: Band, depth fixedDepth: Float?,
                                side: Float, near centre: SIMD2<Float>?,
                                rand: inout Rand) -> PropPlacement? {
        // Once the launch has spent its budget of *distinct* models, the reef is filled from
        // the ones already loaded. This is a load-time cap, not a look: an instance is a clone
        // sharing its template's vertex buffers and its 2048² atlas, but every new model is
        // another 5–10 MB archive to import before the first frame, and a screensaver that
        // takes seconds to appear has failed at the one moment anybody watches it.
        let spent = used.count >= budget
        let available = pool.filter { manifest in
            if spent && used[manifest.name] == nil { return false }
            guard let cap = manifest.placement?.maxPerScene else { return true }
            return used[manifest.name, default: 0] < cap
        }
        // Diminishing returns on repeats. `maxPerScene` is declared only by the showpieces, so
        // a heavy weight on an everyday prop is otherwise unbounded: the boulder's 2.4 took
        // eleven of thirty slots and the reef came out as a rockery. The weights still order
        // the draw — a boulder remains twice as likely as a kelp — they just stop compounding.
        guard let index = rand.weightedIndex(available, weight: { manifest in
            (manifest.placement?.weight ?? 1)
                * pow(0.72, Float(used[manifest.name, default: 0]))
        }), let spec = available[index].placement
        else { return nil }
        let manifest = available[index]

        let scale = spec.scaleRange.sample(&rand)
        let radius = spec.spacingRadius(scale: scale)

        for _ in 0..<14 {
            let depth: Float
            let x: Float
            if let centre {
                // `u^0.65` biases toward the middle of a clump without the long tail a normal
                // distribution would give, which would put strays out on empty sand.
                let angle = rand.inRange(0, 2 * .pi)
                let distance = clusterRadius * pow(rand.next(), 0.65)
                depth = band.clamp(-centre.y + sin(angle) * distance)
                x = centre.x + cos(angle) * distance
            } else {
                depth = fixedDepth ?? band.depth(0, 1, rand: &rand)
                // Never dead centre: the middle of the frame is where the school reads best.
                x = side * rand.inRange(0.12, 0.8) * Tank.halfWidth(atDepth: depth)
            }
            // Half a footprint of overhang is allowed, so the reef runs off the sides of the
            // frame rather than stopping politely inside it.
            let edge = Tank.halfWidth(atDepth: depth) + spec.footprint * scale * 0.5
            let position = SIMD2<Float>(min(max(x, -edge), edge), -depth)
            guard clears(position: position, radius: radius,
                         minSpacing: spec.minSpacing * scale, against: placed) else { continue }

            return PropPlacement(
                manifest: manifest,
                position: position,
                yaw: spec.yawRange.sample(&rand) * .pi / 180,
                tilt: abs(spec.tiltRange.sample(&rand)) * .pi / 180,
                tiltAxis: rand.inRange(0, 2 * .pi),
                scale: scale,
                radius: radius,
                minSpacing: spec.minSpacing * scale)
        }
        return nil
    }

    /// Two props clear each other when they are further apart than both their combined tilted
    /// radii and either one's declared centre-to-centre minimum.
    ///
    /// `minSpacing` is not redundant with the radii: it is where a prop states a need the
    /// geometry does not show. The arch's is more than twice its footprint because a fish has
    /// to line up on the passage before it commits to swimming through, and the treasure chest's
    /// covers the arc its lid sweeps when it opens — neither is visible in a footprint.
    private static func clears(position: SIMD2<Float>, radius: Float, minSpacing: Float,
                               against placed: [PropPlacement]) -> Bool {
        for other in placed {
            let required = max(radius + other.radius, max(minSpacing, other.minSpacing))
            if simd_distance(position, other.position) < required { return false }
        }
        return true
    }
}
