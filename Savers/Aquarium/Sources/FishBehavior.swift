// How a fish decides where to go, and the water it is allowed to go there in.
//
// The school used to have no state at all: `place` handed a fish a constant velocity and it flew
// dead straight until it left the frame, at a height it held for the whole crossing. Changing
// lane, changing height, turning, pausing and changing speed are not five features on top of
// that — they are five symptoms of the one thing it was missing, which is that a fish had a
// launch vector and no way to steer. Everything here exists to replace that vector with an
// intent the fish turns toward at a rate its own body allows.
//
// Two consequences are load-bearing and neither is optional:
//
// - **Orientation has to come from the whole heading, not from its horizontal part.** A fish that
//   changes height while holding a level yaw reads as a model sliding along a wire. Pitch is not
//   a garnish on this feature, it is what makes vertical motion legible at all.
// - **The tail has to know how fast the fish is going.** A stopped fish still beating at 1.5 Hz
//   is the single most obvious tell that the animation and the motion are unrelated systems.

import Foundation
import simd

// MARK: - The water a fish may occupy

/// The walls, for one drawable shape.
///
/// Built fresh each frame rather than cached, because it is four divisions and a multiply and
/// caching it would mean invalidating it on every reshape — a bug that would show up as fish
/// clipping through glass on a display mode change and nowhere else.
struct WaterBounds {
    let tank: Tank
    let aspect: Float

    /// A glass tank is closed on every side; open sea is closed only underneath.
    ///
    /// This is the whole of the difference between the two, and it is a difference in *kind*
    /// rather than in numbers: a fish in a tank lives there, and a fish in the ocean is passing
    /// through. Only the first has any reason to turn round at the edge of the picture.
    var isEnclosed: Bool { tank.isEnclosed }

    var floorY: Float { tank.floorY(aspect: aspect) }

    var nearDepth: Float { tank.swimNearDepth }
    var farDepth: Float { tank.swimFarDepth }

    /// The top of the water. Follows the frustum in both looks, and differs only in how much of
    /// the frame it claims — see `Tank.ceilingY`.
    func ceilingY(atDepth depth: Float) -> Float {
        tank.ceilingY(atDepth: depth, aspect: aspect)
    }

    /// How far sideways a fish may go. Unbounded in open sea, where leaving the frame is how a
    /// crossing is supposed to end.
    func wallX(atDepth depth: Float) -> Float? {
        isEnclosed ? tank.wallX(atDepth: depth) : nil
    }
}

// MARK: - Depth lanes

/// The discrete depths the school is layered into.
///
/// Lanes rather than a continuous depth because the point of them is *occlusion*: a fish holding
/// one of a handful of depths passes cleanly in front of or behind a rock, where a continuous
/// spread produces a steady trickle of near-coplanar near-misses that read as z-fighting even
/// when they are geometrically fine. A fish is not confined to its lane — it eases between them,
/// which is what a lane change is — it simply has one to come back to.
struct SwimLanes {
    /// Six is the middle of the 5–7 the plan asks for, and it divides the aquarium's 3.3 m of
    /// water into lanes about half a metre apart — comfortably more than the depth precision the
    /// eye has at this field of view, and enough lanes that a school does not look banded.
    static let count = 6

    let near: Float
    let far: Float

    init(bounds: WaterBounds) {
        near = bounds.nearDepth
        far = max(bounds.farDepth, bounds.nearDepth + 0.5)
    }

    /// The centre depth of a lane, indexed from the front of the tank.
    func depth(_ lane: Int) -> Float {
        let clamped = min(max(lane, 0), SwimLanes.count - 1)
        return near + (Float(clamped) + 0.5) / Float(SwimLanes.count) * (far - near)
    }

    /// The lanes a species is willing to be in, from its manifest's depth band. Never empty: a
    /// band narrower than one lane still yields the lane it falls in, or a fish of that species
    /// would have nowhere to be and would sit at the front of the tank forever.
    func lanes(in band: Span) -> ClosedRange<Int> {
        let count = Float(SwimLanes.count)
        let low = Int((band.lower * count).rounded(.down))
        let high = Int((band.upper * count).rounded(.up)) - 1
        let lower = min(max(low, 0), SwimLanes.count - 1)
        let upper = min(max(max(high, lower), 0), SwimLanes.count - 1)
        return lower...upper
    }
}

// MARK: - What a fish is doing

enum Behavior {
    /// Hold course. The default, and most of what is on screen at any moment.
    case cruise
    /// Ease onto a new heading. This is the one that changes direction, changes height and
    /// changes lane — they are the same act, differing only in which component of the new
    /// heading is the interesting one.
    case wander
    /// Almost stationary, sculling. A fish that never stops reads as a toy on a track.
    case hover
    /// Nose-down over whatever is underneath, working along it. Only ever entered with a
    /// surface actually in reach — see `SurfaceField`.
    case forage
    /// A short burst. Rare by design: the value of a dart is entirely in how seldom it happens,
    /// and a school that darts often reads as panicked rather than alive.
    case dart
    /// Stay with a host anemone. Replaces cruising outright for a site-attached species rather
    /// than competing with it, because a clownfish that patrols the tank like a tang is simply
    /// the wrong animal.
    case host
    /// Following a route through a prop, waypoint by waypoint.
    ///
    /// The one behaviour that cannot be abandoned partway. Everything else here is a preference
    /// the walls and the reef are allowed to argue with; a fish halfway inside a hull that
    /// changes its mind is a fish embedded in the hull.
    case transit

    /// Whether the fish is idling in place, which is what decides if it may pick a new lane on
    /// the way out of this state.
    var isStationary: Bool {
        switch self {
        case .hover, .forage: return true
        case .cruise, .wander, .dart, .host, .transit: return false
        }
    }
}

/// The per-fish state that used to not exist.
struct FishBrain {
    var behavior: Behavior = .cruise
    /// Seconds left in the current behaviour.
    var remaining: Float = 0

    /// Where the fish is steering. Horizontally that is a heading rather than a point — a target
    /// point would make a fish that overshoots turn back on itself, which no fish does.
    var targetYaw: Float = 0

    /// Vertically it *is* a point, and the asymmetry is deliberate. Height is the axis a fish is
    /// actually trying to hold: it wants to be at a depth in the water column, not to be
    /// climbing at an angle. Carrying it as a height and deriving the pitch from the error every
    /// frame is what makes a fish level off as it arrives instead of sailing through its own
    /// target and correcting. Above the floor, so it survives a reshape.
    var targetHeight: Float = 0

    /// Pitch asked for on top of whatever reaching `targetHeight` implies — a dart's slight
    /// nose-up, a forager's shallow descent. Zero for anything just going somewhere.
    var pitchBias: Float = 0

    /// A fraction of the fish's own cruise speed, so every behaviour is stated in terms of the
    /// animal rather than in metres per second.
    var targetSpeedFactor: Float = 1

    /// The lane it means to be in. A lane change is a change to this plus a `wander` that
    /// carries the fish there; nothing teleports.
    var lane: Int = 0

    /// Nose-down attitude *beyond* what the heading implies, which is what foraging looks like:
    /// a fish inspecting the gravel is tipped further over than its actual path is. Eased rather
    /// than snapped, or entering the state would look like a hinge.
    var inspect: Float = 0
    var inspectTarget: Float = 0

    /// Which placed anemone this fish belongs to, for a site-attached species. An index into the
    /// scene's host list rather than a reference, so the brain stays a value.
    var host: Int?

    /// Where the fish currently is around its host, as an angle it *advances* rather than
    /// redraws. Drawing a fresh orbit point every few seconds is what made the clownfish jerk:
    /// an orbit picked uniformly at random is not an orbit, it is a sequence of unrelated
    /// destinations, and a small fish has enough turning authority to snap onto each one.
    var orbitAngle: Float = 0

    /// Which way the fish was last asked to turn. Carried so a new heading can be biased to
    /// continue the way it is already going: fish arc, and a choice made without reference to
    /// the turn in progress produces the reversal-within-half-a-second that reads as indecision
    /// rather than as an animal. It is a bias and not a rule, so a fish can still change its mind
    /// — and a run of same-sign choices still occasionally sends one round in a full circle,
    /// which is worth keeping.
    var turnSign: Float = 1

    /// Suppresses a second dart immediately after the first. Two in a row is the difference
    /// between a startle and a twitch.
    var dartCooldown: Float = 0

    /// The route being followed, as an index into the scene's list, and how far along it is.
    var passage: Int?
    var waypoint: Int = 0
    /// Routes are ordered but not directed — a wreck can be entered from either end — so a fish
    /// joining at the far waypoint walks the list backwards.
    var passageReversed = false
    /// How long this transit has been going. A fish that cannot reach its next waypoint must give
    /// up rather than press against geometry forever, and only a clock can tell the difference
    /// between slow progress and none.
    var transitElapsed: Float = 0

    /// Stops a fish from re-entering a route it has just left. Without it a passage is an
    /// attractor a fish falls into and never escapes: it exits, is immediately within range of
    /// the entrance it just used, and turns straight back in.
    var passageCooldown: Float = 0
}

// MARK: - Steering

/// The turn-rate and acceleration limits one fish is subject to, derived from its size.
///
/// Everything here scales off body length because that is the only thing the manifest says about
/// an animal's manoeuvrability, and it is very nearly the right thing: a 6 cm gramma pivots on
/// the spot and a 1.5 m moray commits to a turn. The relation is not linear — a twenty-five-fold
/// length ratio does not mean a twenty-five-fold turn ratio, and using one makes the big fish
/// look becalmed — so it is stated as a reciprocal with an offset, which flattens at both ends.
struct SwimLimits {
    let yawRate: Float
    let pitchRate: Float
    let acceleration: Float
    let maxPitch: Float

    /// The ceiling on how fast anything may turn, whatever the reciprocal below works out to.
    ///
    /// Without it the relation runs away at the small end: an 8 cm clownfish comes out at 5.1 rad
    /// per second, which is 293° — it completes a right-angle turn in a third of a second and the
    /// result does not read as a turn at all, it reads as the model being re-pointed between two
    /// frames. That was the single worst artifact in the first build, and it was worst on the
    /// smallest fish precisely because they had the most authority.
    private static let maxYawRate: Float = 2.9

    /// How much of its turning a fish keeps when it is barely moving.
    ///
    /// **Turn authority scales with speed**, and this is the floor rather than the whole story.
    /// A fish turns by pushing water with its body, so one that has slowed to a hover cannot whip
    /// round — and a hovering fish that snapped to a new heading was the same jarring artifact
    /// arriving by a second route. It is a floor rather than zero because a real fish holding
    /// station still reorients slowly on its pectorals, which this saver does not animate yet.
    private static let pivotFloor: Float = 0.18

    init(length: Float) {
        yawRate = min(2.2 / (0.35 + length), SwimLimits.maxYawRate)
        // Fish pitch more slowly than they yaw and through a much smaller arc. Letting pitch run
        // at the yaw rate produces a fish that porpoises on every lane change.
        pitchRate = yawRate * 0.45
        // In multiples of cruise speed per second: a fish reaches cruise from rest in about half
        // a second and stops in about the same, which is the difference between easing and
        // snapping without being slow enough to read as drag.
        acceleration = 2.0
        maxPitch = 0.62
    }

    /// The share of its turning a fish has available at a given fraction of its cruise speed.
    /// Rises above 1 in a dart, which is what makes a startle able to change direction sharply
    /// while an idling fish cannot.
    static func authority(effort: Float) -> Float {
        pivotFloor + (1 - pivotFloor) * min(max(effort, 0), 1.4)
    }
}

enum Steering {
    /// The unit heading for a yaw and a pitch.
    ///
    /// The convention is the model's: nose along +X, up along +Y, so a yaw about +Y sends the
    /// nose to `(cos, 0, -sin)` — which is where the negated z comes from, and it matches the
    /// yaw the school has always used.
    static func direction(yaw: Float, pitch: Float) -> SIMD3<Float> {
        SIMD3<Float>(cos(pitch) * cos(yaw), sin(pitch), -cos(pitch) * sin(yaw))
    }

    static func yaw(of direction: SIMD3<Float>) -> Float {
        atan2(-direction.z, direction.x)
    }

    static func pitch(of direction: SIMD3<Float>) -> Float {
        let horizontal = sqrt(direction.x * direction.x + direction.z * direction.z)
        return atan2(direction.y, max(horizontal, 1e-5))
    }

    /// The shortest way round from `angle` to `target`, which is the whole reason yaw is carried
    /// as an angle and turned component-wise rather than as a vector and slerped. A fish asked to
    /// reverse has two equally short answers and a vector interpolation has neither — it passes
    /// through the zero vector and the heading falls apart for a frame.
    static func shortestDelta(from angle: Float, to target: Float) -> Float {
        var delta = (target - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// Moves `angle` toward `target` by at most `rate * dt`, and reports how fast it actually
    /// turned. The rate is what the caller banks on — literally: a fish rolls into a turn in
    /// proportion to how hard it is turning, and the only honest source for that is here.
    static func turn(_ angle: inout Float, toward target: Float, rate: Float,
                     dt: Float) -> Float {
        let delta = shortestDelta(from: angle, to: target)
        let step = min(abs(delta), rate * dt) * (delta < 0 ? -1 : 1)
        angle += step
        return dt > 0 ? step / dt : 0
    }
}

// MARK: - Avoidance

enum Avoidance {
    /// How strongly a wall bends a fish away from it, relative to whatever it wanted to do.
    /// Above about 2 the behaviour stops being visible near an edge; below about 1 a darting
    /// fish reaches the glass before the push has turned it.
    private static let strength: Float = 2.4

    /// A push away from every boundary the fish is close to, in world space and unnormalized.
    ///
    /// Ramped rather than switched, so the turn away from a wall is a turn and not a bounce.
    /// It reaches full strength at the wall and keeps growing past it, which is what recovers a
    /// fish that a reshape or a dart has already put outside.
    /// `avoidingProps` is false only for a fish inside a passage. The reef's own outward shove is
    /// correct for every other moment and exactly wrong here: the wreck a fish is threading is a
    /// prop, so the term that keeps fish from swimming into hulls is also the term that would
    /// push one out of the hole it is aiming at. The route's declared clearance is what keeps it
    /// off the geometry instead, which is what the declaration is for.
    static func push(position: SIMD3<Float>, length: Float, bounds: WaterBounds,
                     surface: SurfaceField, avoidingProps: Bool = true) -> SIMD3<Float> {
        // The distance over which a wall makes itself felt. Its own body length is the natural
        // unit — a moray has to start its turn much earlier than a gramma does — and a little
        // over two of them is far enough that even the slowest turner comes round in time.
        let want = max(length * 2.4, 0.08)
        var push = SIMD3<Float>(repeating: 0)
        let depth = -position.z

        // Underneath, always, in both looks. The floor is the one wall the ocean has too.
        let ceiling = bounds.ceilingY(atDepth: depth)
        let column = max(ceiling - bounds.floorY, 1e-3)
        let vertical = Avoidance.margin(want, within: column)
        push.y += ramp(position.y - bounds.floorY, vertical)
        push.y -= ramp(ceiling - position.y, vertical)

        // The reef, which is not the floor and must not be treated as it. A prop contributes a
        // *bounded* lift and a shove to the side, and which of the two dominates is the prop's
        // own proportions — see `SurfaceField.Mound.steepness`. A fish goes over a boulder and
        // round a stand of kelp.
        if avoidingProps {
            let ground = surface.sample(x: position.x, z: position.z)
            if ground.height > 0 {
                let clearance = position.y - bounds.floorY - ground.height
                push.y += min(ramp(clearance, vertical), Avoidance.maxPropLift)
            }
            push.x += ground.outward.x * Avoidance.propSideStrength
            push.z += ground.outward.y * Avoidance.propSideStrength
        }

        // The glass. Open sea has none of this: a crossing is *supposed* to end by leaving.
        if bounds.isEnclosed {
            let span = max(bounds.farDepth - bounds.nearDepth, 1e-3)
            let alongDepth = Avoidance.margin(want, within: span)
            push.z -= ramp(depth - bounds.nearDepth, alongDepth)
            push.z += ramp(bounds.farDepth - depth, alongDepth)
            if let wall = bounds.wallX(atDepth: depth) {
                let lateral = Avoidance.margin(want, within: wall * 2)
                let side: Float = position.x < 0 ? 1 : -1
                push.x += side * ramp(wall - abs(position.x), lateral)
            }
        }
        return push * strength
    }

    /// A margin can never claim so much of an axis that there is no free water left on it.
    ///
    /// This is what trapped the eel. The margin is a multiple of body length, and a fish keeps
    /// its real metres while the tank shrinks around it — so in a glass tank a 0.6 m eel asked
    /// for 1.46 m of clearance from side walls only 1.04 m from the centre. The ramp was then
    /// positive at *every* x including zero, pushing left of centre and right of it, and the
    /// animal was pinned on the axis with only depth free to move in. It swam forward and back
    /// for its whole life, which is exactly what was reported.
    ///
    /// Capping at a third leaves at least a third of every axis with no push on it at all, which
    /// is the property that matters: there has to be somewhere a fish can simply be.
    private static func margin(_ want: Float, within extent: Float) -> Float {
        min(want, extent * 0.33)
    }

    /// The most a prop may push a fish upward, whatever its height.
    ///
    /// Unbounded, this is the term that fires a fish off the top of a tall plant. It is capped
    /// rather than removed because a low wide rock genuinely is something to rise over.
    private static let maxPropLift: Float = 0.9

    /// How hard a tall prop shoves a fish aside relative to a wall. Below 1 because going round
    /// a plant is a preference, where going through glass is not a possibility.
    private static let propSideStrength: Float = 0.75

    /// 0 while the gap is comfortable, 1 at the wall, and unbounded past it.
    private static func ramp(_ gap: Float, _ margin: Float) -> Float {
        margin > 0 ? max(0, 1 - gap / margin) : 0
    }

    /// The backstop. Steering is a force and a force can be outrun, so a closed tank also
    /// clamps — otherwise one dart taken at the wrong moment, or a live reshape that moves the
    /// walls under a fish, puts an animal through the glass and it never comes back.
    ///
    /// It only ever fires for a fish already outside, so it costs the behaviour nothing.
    static func clamp(position: inout SIMD3<Float>, girth: Float, bounds: WaterBounds) {
        // **The floor, and only the floor.** The reef is not clamped against, and that is the
        // fix for the worst artifact this system produced: a hard positional clamp is a teleport,
        // which is harmless as a few-centimetre wall correction and catastrophic against a prop
        // metres tall. Giant kelp is tall and narrow, so a fish crossing its footprint had the
        // ground under it rise by metres over a few centimetres of travel, and the clamp lifted
        // it every frame — following the dome upward and firing the animal off the top of the
        // frame faster than it could pitch to meet its own heading. Props steer a fish now; they
        // never move it.
        //
        // Set by how deep through the body the animal is, never by how long it is — the same
        // distinction that decides whether it fits through a wreck. A moray asked for half its
        // *length* of clearance could not lie anywhere near the gravel.
        let clearance = girth * 1.5
        position.y = max(position.y, bounds.floorY + clearance)

        guard bounds.isEnclosed else { return }
        position.y = min(position.y, bounds.ceilingY(atDepth: -position.z) - clearance)
        let depth = min(max(-position.z, bounds.nearDepth + clearance),
                        bounds.farDepth - clearance)
        position.z = -depth
        if let wall = bounds.wallX(atDepth: depth) {
            let limit = max(0, wall - clearance)
            position.x = min(max(position.x, -limit), limit)
        }
    }
}
