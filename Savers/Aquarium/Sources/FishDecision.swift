// Choosing what a fish does next.
//
// Kept apart from `FishBehavior` because the two answer different questions and change for
// different reasons: that file is the physics a fish is subject to, and this one is the taste.
// Every number below is a judgement about how a tank should read and is expected to be argued
// with in front of a render; nothing in the steering is.
//
// The weights are the whole design. A behaviour that is available everywhere and often is not a
// behaviour, it is a tic — the value of a dart is entirely in how seldom it happens — so most of
// what follows is about what a fish is *not* allowed to do, and when.

import Foundation
import simd

/// A placed anemone a site-attached fish can belong to.
struct FishHost {
    /// x and z in the seabed's space, which are the world's; y is a height **above the floor**,
    /// at about the crown rather than the holdfast, because what a clownfish sits in is the top
    /// of the animal.
    ///
    /// Floor-relative for the same reason `FishBrain.targetHeight` is: `Tank.floorY` moves when
    /// the drawable changes shape and every prop moves with it, so a host carrying a baked world
    /// height would send its fish to a depth the reef is no longer at, and only after a reshape.
    let position: SIMD3<Float>
    /// How far out the fish is willing to stray, in metres. Derived from the anemone's own
    /// footprint so a big one holds a wider territory than a small one.
    let radius: Float

    /// The anemones this launch happened to draw, from the reef it drew them into.
    ///
    /// Nothing guarantees there are any — the reef is a weighted draw and a tank can easily come
    /// out without one — which is exactly why the clownfish falls back to swimming like every
    /// other species rather than depending on one being there.
    static func hosts(in props: [PropInstance]) -> [FishHost] {
        props.compactMap { prop in
            guard prop.manifest.isHostAnemone, prop.radius > 0 else { return nil }
            return FishHost(
                position: SIMD3<Float>(prop.groundPosition.x,
                                       prop.height * 0.72,
                                       prop.groundPosition.y),
                // Wider than the animal itself. A clownfish's territory is the anemone plus the
                // water immediately over it, and a radius of exactly the footprint would keep
                // the fish inside the tentacles where it cannot be seen.
                radius: max(prop.radius * 2.2, prop.height * 1.4))
        }
    }
}

extension ModelManifest {
    /// Whether this species stays with a host rather than crossing open water.
    ///
    /// A named exception, and the only one in the school. Clownfish are site-attached in the
    /// wild, so one patrolling the tank like a tang is simply the wrong animal — and no other
    /// species in the library wants anything the shared swimming model cannot express.
    ///
    /// Hard-coded for the same reason `isManmade` is, and with the same debt: this is authoring
    /// data and `docs/decorations.md` is the contract for it. A manifest field added for a single
    /// species, before a second one needs it, would cost a pass over every model in the library
    /// to earn nothing.
    var isSiteAttached: Bool { ModelManifest.siteAttachedFish.contains(name) }

    /// Which props a site-attached fish will accept as a home.
    var isHostAnemone: Bool { ModelManifest.hostProps.contains(name) }

    private static let siteAttachedFish: Set<String> = ["clownfish"]
    private static let hostProps: Set<String> = ["anemone"]
}

/// Everything the decision needs to know about the world, gathered once per fish rather than
/// reached for one field at a time.
struct BehaviorContext {
    let position: SIMD3<Float>
    let yaw: Float
    let length: Float
    let bounds: WaterBounds
    let surface: SurfaceField
    let lanes: SwimLanes
    let laneRange: ClosedRange<Int>
    let hosts: [FishHost]
    let passages: [SwimPassage]
    /// Half the larger cross-section extent, measured from the mesh. What decides whether a
    /// passage admits this fish — never its length.
    let girth: Float
    /// Whether this species would rather be under something than out in the water.
    let isLurker: Bool

    /// Water between the fish and whatever is directly under it — gravel, or a rock, or a frond.
    var clearance: Float {
        position.y - bounds.floorY - surface.height(x: position.x, z: position.z)
    }

    /// The height a fish may be at, at its current depth, as a span above the floor.
    var verticalSpan: (low: Float, high: Float) {
        let ground = surface.height(x: position.x, z: position.z)
        let ceiling = bounds.ceilingY(atDepth: -position.z) - bounds.floorY
        let low = min(ground + girth * 3, ceiling * 0.5)
        return (low, max(ceiling - length * 0.6, low + length))
    }
}

extension FishBrain {
    /// How close underneath something has to be before it is worth inspecting. Generous — a fish
    /// noses at things it is swimming *over*, not only at things it is touching — and stated in
    /// body lengths because a moray's idea of close is not a gramma's.
    private static let forageReach: Float = 3.5

    /// The shortest any behaviour but a dart may last. Roughly the time the slowest turner needs
    /// to come through a right angle at cruise, which is the point: a commitment shorter than the
    /// manoeuvre it commits to is indistinguishable from indecision.
    static let minimumCommitment: Float = 1.6

    /// The highest a lurker will voluntarily go, as a fraction of the water available to it.
    /// A transit is exempt: a route through a wreck goes where the wreck's hold is.
    static let lurkerCeiling: Float = 0.32

    /// Picks the next behaviour and the intent that goes with it.
    ///
    /// Called only when the current behaviour runs out, which is what keeps a fish committed to
    /// what it is doing. Re-deciding every frame produces an animal that vibrates between
    /// plausible choices and settles on none of them.
    mutating func choose(_ context: BehaviorContext, rand: inout Rand) {
        let previous = behavior
        behavior = draw(context, rand: &rand)
        // Nothing but foraging tips a fish beyond its own path, and leaving the state has to
        // level it out again or the pose leaks into everything after it.
        inspectTarget = 0

        switch behavior {
        case .cruise:
            remaining = rand.inRange(3.0, 9.0)
            targetSpeedFactor = rand.inRange(0.85, 1.1)
            aim(along: heldCourse(context, rand: &rand))

        case .wander:
            remaining = rand.inRange(2.6, 5.5)
            targetSpeedFactor = rand.inRange(0.7, 1.15)
            // A lane change is a wander that happens to end in a different lane. Half of them
            // do, which is often enough that the school keeps re-layering and seldom enough that
            // a given fish reads as belonging somewhere.
            if rand.next() < 0.5, let next = neighbouringLane(context, rand: &rand) {
                lane = next
            }
            // The one place the fish is allowed to reverse. A fish that only ever turns through
            // small angles drifts steadily in one direction and the tank empties to one side.
            //
            // Rarer than it was. At a third of all wanders a fish reversed roughly every four
            // seconds, and with a wander lasting less than that it could reverse, be interrupted,
            // and reverse again inside a second — which is the "changed my mind" flicker rather
            // than a decision.
            let flip: Float = rand.next() < 0.18 ? -1 : 1
            aim(along: course(context, lateral: lateralSign(context) * flip, rand: &rand))
            retarget(height: rand.inRange(0, 1), context)

        case .hover:
            remaining = rand.inRange(1.5, 5.0)
            // Not zero. A fish holding station still sculls, and a speed of exactly nothing
            // stops the tail with it — see how the beat is coupled in `School`.
            targetSpeedFactor = rand.inRange(0.04, 0.1)
            targetYaw = yaw(of: context)
            pitchBias = 0

        case .forage:
            remaining = rand.inRange(2.5, 7.0)
            targetSpeedFactor = rand.inRange(0.14, 0.26)
            // Nose down, and *further* down than the path it is on. This is the difference
            // between descending toward the gravel and looking at it, and it is the whole
            // reason `inspect` is carried separately from pitch.
            inspectTarget = -rand.inRange(0.32, 0.68)
            // Barely turning: a foraging fish works along a surface rather than setting off
            // across the tank.
            targetYaw = context.yaw + rand.inRange(-0.5, 0.5) * rand.sign()
            pitchBias = -rand.inRange(0.05, 0.2)
            // Down to just above whatever it is inspecting, not onto it — and never above the
            // water it is in. A tall plant's dome reaches most of the way up a glass tank, so a
            // fish inspecting the top of one would otherwise be sent climbing at a height the
            // ceiling has already refused it.
            let ground = context.surface.height(x: context.position.x, z: context.position.z)
            let span = context.verticalSpan
            targetHeight = min(ground + context.length * rand.inRange(0.8, 1.6), span.high)

        case .dart:
            remaining = rand.inRange(0.35, 0.8)
            targetSpeedFactor = rand.inRange(2.4, 3.2)
            // A dart holds its heading. The startle is the acceleration, not a change of mind.
            targetYaw = context.yaw + rand.inRange(-0.25, 0.25)
            pitchBias = rand.inRange(-0.15, 0.15)
            // Long enough that a fish cannot chain two into a twitch, short enough that a tank
            // watched for a minute still sees several.
            dartCooldown = rand.inRange(8, 22)

        case .host:
            remaining = rand.inRange(3.2, 6.5)
            targetSpeedFactor = rand.inRange(0.25, 0.6)
            aimAtHost(context, rand: &rand)

        case .transit:
            guard let (index, atStart) = nearestPassage(context) else {
                behavior = .cruise
                remaining = rand.inRange(3.0, 9.0)
                aim(along: heldCourse(context, rand: &rand))
                break
            }
            passage = index
            passageReversed = !atStart
            waypoint = 0
            transitElapsed = 0
            // Long enough to cross the longest route at a dawdle. It is a ceiling rather than a
            // duration — `School` ends the transit when the last waypoint is reached — and it
            // exists only so a fish that cannot make progress gives up instead of pressing
            // against geometry for the rest of the launch.
            remaining = context.isLurker ? 26 : 15
            // Deliberate and unhurried. A fish that darts through a hull reads as escaping it;
            // one that eases through reads as choosing it.
            targetSpeedFactor = rand.inRange(0.45, 0.75)
            pitchBias = 0
        }

        // A fish that has just picked a heading into a wall it is already close to would
        // otherwise spend the whole of a nine-second cruise sliding along the glass while the
        // avoidance push fights its intent. Cutting the commitment lets it re-decide once it has
        // come round, which is what a real tank looks like at the ends.
        //
        // Two things keep this from becoming the flicker it originally was. It only fires when
        // the push actually *opposes* where the fish means to go — near a wall but travelling
        // away from it is not a reason to reconsider, and in a tank this small a fish is within
        // range of some wall almost always, so the unconditional version re-decided about once a
        // second for its whole life. And the floor is long enough to complete a turn in.
        let push = Avoidance.push(position: context.position, length: context.length,
                                  bounds: context.bounds, surface: context.surface)
        if behavior != .transit, simd_length(push) > 1.2 {
            let intent = SIMD3<Float>(cos(targetYaw), 0, -sin(targetYaw))
            if simd_dot(simd_normalize(push), intent) < -0.2 {
                remaining = min(remaining, rand.inRange(1.3, 2.3))
            }
        }

        // Nothing but a dart may commit for less than this. Every jarring moment in the first
        // build was some path that let a fish re-decide before it had finished acting on the
        // last decision, and the turn rate then made the correction instant. A dart is exempt
        // because being brief is the whole of what a dart is.
        if behavior != .dart, behavior != .transit {
            remaining = max(remaining, FishBrain.minimumCommitment)
        }

        // **A lurker keeps to the floor whatever it just decided to do.**
        //
        // Applying this inside `wander` alone was not enough and the failure was quiet: `cruise`
        // never touches `targetHeight`, so an eel that spawned mid-column and then mostly cruised
        // held that height for the whole launch and never showed the slightest interest in the
        // ground. The preference belongs to the animal, not to one of its behaviours, so it is
        // applied to every decision here — after the switch, where nothing can miss it.
        if context.isLurker, behavior != .transit {
            let span = context.verticalSpan
            targetHeight = min(targetHeight,
                               span.low + (span.high - span.low) * FishBrain.lurkerCeiling)
        }

        // Remember which way this decision asks the fish to turn, so the next one can prefer to
        // continue it.
        let delta = Steering.shortestDelta(from: context.yaw, to: targetYaw)
        if abs(delta) > 0.08 { turnSign = delta < 0 ? -1 : 1 }

        // Never leave a fish idling twice running. Two stationary states back to back is a fish
        // that has stopped rather than one that paused.
        if previous.isStationary && behavior.isStationary {
            remaining = min(remaining, 1.5)
        }
    }

    /// The weighted draw. Availability comes first and weight second: a behaviour with no
    /// preconditions met is not made unlikely, it is made impossible.
    private func draw(_ context: BehaviorContext, rand: inout Rand) -> Behavior {
        var options: [(Behavior, Float)] = []

        if host != nil, !context.hosts.isEmpty {
            // A site-attached fish is not a cruising fish that happens to like an anemone. It
            // gets the same idling states as anything else and nothing that would take it away.
            options.append((.host, 6.0))
            options.append((.hover, 0.9))
        } else if context.bounds.isEnclosed {
            // In a tank the fish lives here, so it has no reason to be going anywhere and every
            // reason to potter. Wandering and cruising are level.
            options.append((.cruise, 3.0))
            options.append((.wander, 3.0))
            options.append((.hover, 1.0))
        } else {
            // In open water a fish is passing through, and the crossing is what puts it on and
            // off the screen. Weighting cruise heavily is what keeps the ocean's composition
            // working the way it already did.
            options.append((.cruise, 5.0))
            options.append((.wander, 2.0))
            options.append((.hover, 0.35))
        }

        if context.clearance < context.length * FishBrain.forageReach {
            options.append((.forage, context.bounds.isEnclosed ? 2.2 : 1.2))
        }
        if dartCooldown <= 0 {
            options.append((.dart, 0.15))
        }
        if passageCooldown <= 0, nearestPassage(context) != nil {
            // A lurker is here for this. For everything else a swim-through is a diversion it
            // takes when one happens to be in front of it, which is why the weight is modest and
            // the cooldown afterwards is long: the value of watching a fish commit to a hole is
            // in it being a moment, not a circuit.
            options.append((.transit, context.isLurker ? 5.0 : 1.2))
        }

        guard let index = rand.weightedIndex(options, weight: { $0.1 }) else { return .cruise }
        return options[index].0
    }

    // MARK: Aiming

    /// Turns a horizontal travel direction into a target yaw, and points the pitch at whatever
    /// height the fish is currently after.
    private mutating func aim(along direction: SIMD2<Float>) {
        targetYaw = atan2(-direction.y, direction.x)
        pitchBias = 0
    }

    /// A course that keeps the fish going roughly the way it already was.
    private func heldCourse(_ context: BehaviorContext, rand: inout Rand) -> SIMD2<Float> {
        course(context, lateral: lateralSign(context), rand: &rand)
    }

    /// The horizontal direction to travel, as `(x, z)`.
    ///
    /// The depth component is never zero, and that is inherited from the crossing this replaced
    /// for exactly the reason it was written there: a fish angled into the tank changes size and
    /// fog as it goes, which is what sells the depth axis, and it keeps the tail sweep off the
    /// view direction where the swim deformation is invisible. What is new is that its *sign* is
    /// no longer random — it points at the lane the fish means to be in, so a lane change is a
    /// course rather than a jump.
    private func course(_ context: BehaviorContext, lateral: Float,
                        rand: inout Rand) -> SIMD2<Float> {
        let target = context.lanes.depth(lane)
        let error = target - (-context.position.z)
        // Deeper is z more negative. A fish already in its lane picks a side at random rather
        // than travelling exactly parallel to the frame.
        let towardLane: Float = abs(error) < context.length
            ? rand.sign()
            : (error > 0 ? -1 : 1)
        let tilt = rand.inRange(0.18, 0.5)
        return SIMD2<Float>(lateral * cos(tilt), towardLane * sin(tilt))
    }

    /// The lane next door, within the ones this species will accept, or nil when its band is
    /// only one lane wide.
    ///
    /// Adjacent rather than anywhere: a fish that can jump from the front of the tank to the
    /// back in one decision crosses every other lane on the way at whatever angle the course
    /// happens to give it, and the layering the lanes exist to produce never settles.
    private func neighbouringLane(_ context: BehaviorContext, rand: inout Rand) -> Int? {
        let range = context.laneRange
        guard range.lowerBound < range.upperBound else { return nil }
        let step = rand.sign() > 0 ? 1 : -1
        let next = lane + step
        return range.contains(next) ? next : lane - step
    }

    /// Which way across the frame the fish is currently going, so that holding a course means
    /// holding it. Fish pointed almost straight into or out of the tank get a coin toss, since
    /// their lateral sign carries no information.
    private func lateralSign(_ context: BehaviorContext) -> Float {
        cos(context.yaw) < 0 ? -1 : 1
    }

    private func yaw(of context: BehaviorContext) -> Float { context.yaw }

    /// Picks a height, as a fraction of the water available at this depth.
    private mutating func retarget(height fraction: Float, _ context: BehaviorContext) {
        let span = context.verticalSpan
        // A lurker never picks the top of the water. An eel that wanders the whole column is a
        // very long tang; the animal reads correctly only if it stays down among the things it
        // could be under.
        let reach = context.isLurker ? fraction * 0.3 : fraction
        targetHeight = span.low + min(max(reach, 0), 1) * (span.high - span.low)
    }

    /// The nearest route this fish both fits and is close enough to be tempted by, and which end
    /// it would join at.
    ///
    /// Attraction range scales with the fish and with the hole — a big opening advertises itself
    /// further — and a lurker is drawn from much further off, which is most of what makes the
    /// wreck read as its home rather than as scenery it occasionally passes through.
    func nearestPassage(_ context: BehaviorContext) -> (index: Int, atStart: Bool)? {
        var best: (index: Int, atStart: Bool)?
        var bestDistance = Float.greatestFiniteMagnitude
        let floor = context.bounds.floorY
        for (index, route) in context.passages.enumerated() {
            guard route.admits(girth: context.girth), let first = route.waypoints.first,
                  let last = route.waypoints.last else { continue }
            let reach = max(context.length * 6, route.radius * 8)
                * (context.isLurker ? 2.6 : 1)
            for (point, atStart) in [(first, true), (last, false)] {
                let world = SIMD3<Float>(point.x, floor + point.y, point.z)
                let distance = simd_length(world - context.position)
                if distance < reach, distance < bestDistance {
                    bestDistance = distance
                    best = (index, atStart)
                }
            }
        }
        return best
    }

    /// Steers to a point around the host rather than at it, so the fish orbits and hangs about
    /// instead of converging on one spot and stopping there.
    private mutating func aimAtHost(_ context: BehaviorContext, rand: inout Rand) {
        guard let index = host, context.hosts.indices.contains(index) else {
            behavior = .cruise
            return
        }
        let anemone = context.hosts[index]
        // Well inside the territory: a fish that aims at the edge of its range spends its life
        // at the edge of its range.
        let reach = anemone.radius * rand.inRange(0.25, 0.8)
        // Advanced, never redrawn. A step of a fifth to four fifths of a turn in the direction
        // the fish is already going keeps successive goals adjacent, so the fish rounds its host
        // instead of being flung between opposite sides of it. The bias toward its current turn
        // direction is what makes the path an arc.
        orbitAngle += turnSign * rand.inRange(0.2, 0.8) * 2 * .pi / 3
        let angle = orbitAngle
        let goal = SIMD3<Float>(anemone.position.x + cos(angle) * reach,
                                anemone.position.y + rand.inRange(-0.25, 0.9) * anemone.radius,
                                anemone.position.z + sin(angle) * reach)
        // Only the horizontal part is compared against the fish's own position, which is in
        // world coordinates; the vertical part is handed to `targetHeight`, which is not.
        let offset = goal - context.position
        let horizontal = SIMD2<Float>(offset.x, offset.z)
        // Already there: turn on the spot rather than converging on a point it is standing on,
        // which would otherwise divide by a vanishing length.
        if simd_length(horizontal) < context.length * 0.5 {
            // Standing on the goal. Ease round in the direction already being turned rather than
            // picking a fresh angle either side, which at close range is a coin toss between two
            // opposite headings taken every few seconds.
            targetYaw = context.yaw + turnSign * rand.inRange(0.3, 0.9)
        } else {
            targetYaw = atan2(-horizontal.y, horizontal.x)
        }
        targetHeight = goal.y
    }
}
