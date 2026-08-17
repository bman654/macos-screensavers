// The school: a mixed assortment of species drawn from the library, each at the size its
// manifest says it is and in the depth band its manifest asks for.
//
// What a fish *does* now lives in `FishBehavior` (the limits it swims under) and `FishDecision`
// (what it decides to do). This file owns the parts that are neither: building an animal out of
// a model, putting it somewhere to start, and the per-frame loop that turns an intent into a
// transform and a tail beat.
//
// **The simulation runs on a fixed step derived from absolute time, not on the frame's delta.**
// That is not a robustness flourish, it is what keeps this repo's workflow intact: a seeded
// render at four seconds has to be the same tank every time or none of the A/B comparisons in
// `docs/water-looks.md` mean anything, and a state machine integrated against a variable delta
// is reproducible only to within whatever the frame rate happened to do. Deriving the step count
// from `frame.time` rather than accumulating `deltaTime` is the whole of it — after t seconds
// exactly `floor(t / step)` steps have run, at any frame rate.

import Foundation
import SceneKit
import simd

// MARK: - Swim deformation

/// A travelling sine wave down the body, applied in the vertex stage.
///
/// Proven in `spikes/001-fish-pipeline`. It works in the mesh's own object space, which is
/// only valid because the fish is exported as a single joined mesh — reaching for world
/// space via `u_modelTransform` inside a geometry modifier produces shredded geometry and a
/// magenta surface, with no diagnostic. The `tailward²` envelope holds the head steady; a
/// fish that translates bodily side to side reads as a bar of soap.
private let swimModifier = """
#pragma arguments
float swimPhase;
float swimAmplitude;
float swimWaves;
float bodyMinX;
float bodyLength;

#pragma body
float tailward = clamp((bodyMinX + bodyLength - _geometry.position.x) / bodyLength, 0.0, 1.0);
float envelope = tailward * tailward;
_geometry.position.y += sin(tailward * swimWaves * 6.2831853 - swimPhase)
                      * swimAmplitude * envelope;
"""

// MARK: - One fish

private final class Fish {
    let node: SCNNode
    /// Held directly because the swim phase is a material uniform, and walking the hierarchy
    /// to find them again every frame would be the most expensive thing in the update.
    let materials: [SCNMaterial]
    /// World length, from the species manifest. Every margin this fish is judged by is its own
    /// size — a 6 cm gramma and a 30 cm moray cannot share one constant.
    let length: Float
    /// Fractions of the tank's depth range, from the manifest, so a species stays in the water
    /// it was written for.
    let depthBand: Span
    /// How hard this animal can turn and accelerate, from its length alone.
    let limits: SwimLimits
    /// The lanes its depth band allows. Cached because it is fixed for the life of the fish and
    /// the decision reads it on every choice.
    let laneRange: ClosedRange<Int>
    /// The swim wave's amplitude in the *model's* object space at cruise, which is where the
    /// shader works. Scaled by effort each frame.
    let baseAmplitude: Float
    /// Half the larger cross-section extent, in world metres. What decides whether this animal
    /// fits a hole — see `ModelCache.LoadedModel.girth`.
    let girth: Float
    let isLurker: Bool

    var position = SIMD3<Float>(repeating: 0)
    /// The heading, carried as angles rather than as a vector. See `Steering.shortestDelta` for
    /// why: a fish asked to reverse has two equally short answers and vector interpolation has
    /// neither.
    var yaw: Float = 0
    var pitch: Float = 0
    /// Bank. Not steered — a consequence of how hard the fish is turning, smoothed so that the
    /// per-step turn rate's own noise does not shiver the model.
    var roll: Float = 0
    var speed: Float = 0
    /// Multiplies the depth-derived cruise speed, so one fish is a little quicker than the next
    /// for its whole life rather than only at spawn.
    var pace: Float = 1
    var brain = FishBrain()

    /// Integrated rather than derived from `time * rate`, which is what the school used to do.
    /// The beat is no longer a constant — it follows how hard the fish is working — and a
    /// changing rate against an absolute clock makes the phase jump every time the rate does.
    /// Integrating and wrapping each step also disposes of the long-run precision problem that
    /// method needed a `Double` reduction to survive.
    var swimPhase: Float = 0
    var beat: Float = 1.5

    /// A small residual sway. It used to carry all of the school's vertical interest and now
    /// carries none of it, so it is much smaller than it was: with fish genuinely changing
    /// height, a bob big enough to be seen fights the controller that is holding that height.
    /// Applied to the node and never to `position`, so it cannot feed back into steering.
    var bobRate: Float = 0.3
    var bobPhase: Float = 0
    var bobAmplitude: Float = 0

    /// Whether this fish was working hard enough to be heard on the previous step, and how long
    /// it must wait before it may be heard again. Both exist so that a swish is raised on the
    /// *edge* — a fish over the threshold for half a second is one gesture, not thirty.
    var wasStraining = false
    var swishCooldown: Float = 0

    /// This step's yaw rate, kept from `steer` because the bank and the sound both want it.
    var yawRate: Float = 0

    init(node: SCNNode, materials: [SCNMaterial], length: Float, depthBand: Span,
         laneRange: ClosedRange<Int>, baseAmplitude: Float, girth: Float, isLurker: Bool) {
        self.node = node
        self.materials = materials
        self.length = length
        self.depthBand = depthBand
        self.limits = SwimLimits(length: length)
        self.laneRange = laneRange
        self.baseAmplitude = baseAmplitude
        self.girth = girth
        self.isLurker = isLurker
    }

    /// Screen-space speed is what the eye judges, and that is angular — so world speed grows
    /// with depth. Re-derived from where the fish *is* rather than fixed at spawn, now that a
    /// fish changes depth over its life: pinning it would make a fish that swims toward the
    /// camera visibly accelerate across the frame.
    var cruiseSpeed: Float { max(0.02, -position.z) * Tank.speedPerDepth * pace }
}

// MARK: - The school

final class School {
    /// One parent for every fish, so the scene root stays readable in a debugger and the
    /// school can be hidden in one move.
    let node = SCNNode()

    private var fishes: [Fish] = []
    private var rand: Rand
    private var aspect: Float
    /// The tank this school swims in. Held rather than looked up because every margin a fish is
    /// judged by — its depth band, its speed, the walls, the floor — is one of these numbers.
    private let tank: Tank
    /// What is standing under the water, for the fish that want to look at it.
    private let surface: SurfaceField
    /// The anemones a site-attached species can belong to. Empty on a launch that drew none,
    /// which is the case the clownfish falls back to ordinary swimming for.
    private let hosts: [FishHost]
    /// The routes through the reef this launch happens to have placed.
    private let passages: [SwimPassage]

    /// 60 Hz. Matching the render's own cap means the common case is exactly one step per frame
    /// — no interpolation, no catch-up — while a dropped frame still advances the simulation by
    /// the right amount instead of by however long the stall was.
    private static let step: Float = 1.0 / 60.0
    /// How many steps one frame may run. A screensaver is stopped and started at the system's
    /// convenience, and without a cap the first frame after a long pause would try to simulate
    /// the whole gap and hitch. The cost is that determinism does not survive a stall, which is
    /// a trade a stall has already lost.
    private static let maxStepsPerFrame = 6
    private var stepsRun = 0

    /// The largest share of a tank any single species may occupy.
    private static let maxSpeciesShare: Float = 0.42

    /// The longest a fish may be, as a share of the water column it has to live in.
    ///
    /// Fish keep the real metres their manifest declares while the tank shrinks around them, and
    /// that asymmetry is deliberate — it is what makes a small tank read as a tank, and a 0.4 m
    /// angelfish beside a 0.6 m wreck is the intended result rather than a bug. This is not a
    /// retreat from it. It is the separate fact that an animal longer than its water does not fit:
    /// a 1.5 m moray drawn into a tank 0.81 m deep was seated in the gravel with no room to do
    /// anything but rotate on the spot, because the floor clearance and the ceiling clearance it
    /// needed overlapped. Generous enough that it binds hard in a glass tank and barely at all in
    /// the ocean, where the reference draw only trims the moray by about a sixth.
    private static let maxFishSpan: Float = 0.6

    /// Draws species until the tank is stocked, then a school of each.
    ///
    /// Species are drawn without replacement: two schools of the same fish is the one outcome
    /// that makes a "mixed" school look like a bug rather than a choice.
    init(library: ModelLibrary, cache: ModelCache, count: Int, tank: Tank, aspect: Float,
         surface: SurfaceField, hosts: [FishHost], passages: [SwimPassage], rand: inout Rand) {
        self.rand = rand.fork()
        self.aspect = aspect
        self.tank = tank
        self.surface = surface
        self.hosts = hosts
        self.passages = passages

        let bounds = WaterBounds(tank: tank, aspect: aspect)
        let lanes = SwimLanes(bounds: bounds)

        var pool = library.fish
        var spawned = 0
        while spawned < count, !pool.isEmpty {
            guard let index = self.rand.weightedIndex(pool, weight: { $0.fish?.weight ?? 1 }),
                  let spec = pool[index].fish
            else { break }
            let manifest = pool.remove(at: index)
            guard let model = cache.model(named: manifest.asset), model.length > 0 else { continue }

            // No one species may take the whole tank.
            //
            // School sizes are authored for open water, where a shoal of nine tangs is the point.
            // A glass tank holds ten fish in total, so the first species drawn was routinely
            // taking four to nine of them and every launch came out as "all blue tangs and three
            // others". Capping the share rather than the count is what keeps a big ocean draw
            // able to field a real shoal while a small tank gets at least three species.
            let wanted = Int(spec.school.sample(&self.rand).rounded())
            let speciesCap = max(2, Int(Float(count) * School.maxSpeciesShare))
            let size = max(1, min(min(count - spawned, wanted), speciesCap))
            for member in 0..<size {
                let fish = makeFish(from: model, spec: spec, lanes: lanes,
                                    isLurker: manifest.isLurker)
                // A site-attached species belongs to an anemone if the launch drew one, and
                // swims like anything else if it did not. Every member of the school takes the
                // same host: a shoal of clownfish spread over three anemones is three pairs,
                // which is not what one species drawn once should produce.
                if manifest.isSiteAttached, !hosts.isEmpty {
                    fish.brain.host = hostIndex()
                }
                // Depth spread within this species' own band, width spread across the whole
                // frame: left to chance, a school of a dozen routinely clumps into one corner
                // and leaves half the tank empty — and the first seconds after the screen
                // blanks are the ones that get looked at.
                place(fish, spawningOffScreen: false, bounds: bounds, lanes: lanes,
                      stratum: (Float(member) + 0.5) / Float(size), spreadIndex: spawned + member)
                // Spread the tail beats so a school of clones does not pulse in unison.
                fish.swimPhase = Float(member) / Float(size) * 2 * .pi
                fishes.append(fish)
                node.addChildNode(fish.node)
            }
            spawned += size
        }
    }

    /// Which anemone a site-attached school takes. Drawn once and shared, off this school's own
    /// forked stream.
    private func hostIndex() -> Int {
        guard hosts.count > 1 else { return 0 }
        return min(Int(rand.next() * Float(hosts.count)), hosts.count - 1)
    }

    // MARK: Per-frame update

    /// `dt` is deliberately unused. The frame's own delta is what a simulation would normally
    /// integrate against, and it is exactly what makes a seeded render irreproducible — see the
    /// note at the top of this file. It stays in the signature because it is the shape every
    /// other per-frame update in this saver takes.
    func update(time: CFTimeInterval, dt: Float) {
        let bounds = WaterBounds(tank: tank, aspect: aspect)
        let lanes = SwimLanes(bounds: bounds)

        let due = Int(max(0, time) / Double(School.step))
        // A view that was stopped and restarted hands back a clock that has run on without it.
        if stepsRun > due { stepsRun = due }
        stepsRun = max(stepsRun, due - School.maxStepsPerFrame)
        while stepsRun < due {
            simulate(bounds: bounds, lanes: lanes)
            stepsRun += 1
        }

        for fish in fishes { pose(fish, time: time) }
        census(time: time, bounds: bounds)
    }

    /// DIAGNOSTIC, `AQUARIUM_SCHOOL_STATS=<seconds>`. Prints what the school is actually doing.
    ///
    /// A still frame cannot answer the questions this feature raises. Which behaviour a fish is
    /// in is invisible — a hovering fish and a slow-cruising one are the same picture — and so is
    /// whether a state is ever entered at all, which is the failure mode that matters most: a
    /// weight or a precondition that quietly makes foraging unreachable looks exactly like a tank
    /// whose fish happen not to be foraging in the frame you rendered. It also reports fish
    /// outside the frame, which in a closed tank must always be zero.
    private func census(time: CFTimeInterval, bounds: WaterBounds) {
        guard censusEnabled, let raw = ProcessInfo.processInfo.environment["AQUARIUM_SCHOOL_STATS"],
              let period = Double(raw), period > 0 else { return }
        let bucket = Int(time / period)
        guard bucket > censusBucket else { return }
        censusBucket = bucket

        var counts: [String: Int] = [:]
        var escaped = 0
        var pitched = 0
        for fish in fishes {
            counts["\(fish.brain.behavior)", default: 0] += 1
            if abs(fish.pitch) + abs(fish.brain.inspect) > 0.2 { pitched += 1 }
            let depth = -fish.position.z
            let wall = bounds.wallX(atDepth: depth) ?? .greatestFiniteMagnitude
            if abs(fish.position.x) > wall
                || fish.position.y > bounds.ceilingY(atDepth: depth)
                || fish.position.y < bounds.floorY
                || (bounds.isEnclosed
                    && (depth < bounds.nearDepth || depth > bounds.farDepth)) {
                escaped += 1
            }
        }
        // How much of the tank's width the school is actually using, as a fraction of the wall at
        // each fish's own depth. A value near zero for a big fish is the signature of the
        // centre-trap that pinned the eel: a margin wider than the water leaves a push at every
        // x, including the middle.
        var widest: Float = 0
        var meanReach: Float = 0
        for fish in fishes {
            let wall = bounds.wallX(atDepth: -fish.position.z)
                ?? tank.halfWidth(atDepth: -fish.position.z)
            let reach = wall > 0 ? abs(fish.position.x) / wall : 0
            widest = max(widest, reach)
            meanReach += reach / Float(max(fishes.count, 1))
        }
        // Where the lurkers actually are in the column, since "the eel never goes low" is a claim
        // no behaviour count can confirm or refute.
        var lurkerHeight = ""
        for fish in fishes where fish.isLurker {
            let ceiling = bounds.ceilingY(atDepth: -fish.position.z) - bounds.floorY
            let share = ceiling > 0 ? (fish.position.y - bounds.floorY) / ceiling : 0
            lurkerHeight += String(format: "  lurker@%.2f", share)
        }
        let states = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            .joined(separator: "  ") + lurkerHeight
        let entries = (censusEntries ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: " ")
        print(String(format:
            "[school] t=%6.1f  n=%2d  %@  pitched %d  outside %d  reach mean %.2f max %.2f"
            + "  waypoints %d  crossings %d | %@",
            time, fishes.count, states, pitched, escaped, meanReach, widest,
            waypointsReached, routesCrossed, entries))
    }

    private var censusBucket = -1

    /// Cumulative count of how many times each behaviour has been *entered*, which is a different
    /// question from how many fish are in it right now and the only one that can answer it for a
    /// rare, short state. Sampling occupancy every second found no darts at all in seventy
    /// seconds — correctly, because a dart lasting half a second and chosen on 1.6% of decisions
    /// occupies about two tenths of a percent of the school's time. The instrument was wrong, not
    /// the behaviour, and the shape of that mistake is worth keeping: an instantaneous census
    /// cannot distinguish "never happens" from "happens and is brief", and it fails toward the
    /// first, which is the answer that would have sent someone tuning a weight that was fine.
    private lazy var censusEntries: [String: Int]? = censusEnabled ? [:] : nil

    private let censusEnabled = ProcessInfo.processInfo.environment["AQUARIUM_SCHOOL_STATS"] != nil

    /// What actually happened on the routes, rather than how often one was chosen.
    ///
    /// **A transit entered is not a fish seen going through anything**, and counting entries was
    /// the instrument that reported this feature working for a whole session in which nobody
    /// ever saw it happen. `waypoints` counts arrivals and `crossings` counts routes finished
    /// end to end; a run whose `crossings` is zero while `transit` entries climb is the exact
    /// failure that was live, and it is invisible to every other number here.
    private var waypointsReached = 0
    private var routesCrossed = 0

    // MARK: What the fish sound like

    /// A fish working hard enough to move water audibly, at the moment it starts.
    struct SwishEvent {
        let bodyLength: Float
        /// -1 at the left edge of the frame, +1 at the right.
        let pan: Float
        /// 1 at the glass, falling toward the back wall.
        let nearness: Float
        /// How far past the threshold the fish went, clamped. A hard turn is not a bolt, and
        /// this is what carries the difference between them into the gain.
        let strength: Float
        let isDart: Bool
    }

    /// Raised when a fish begins to strain. Nil, and therefore free, when sound is off.
    var onSwish: ((SwishEvent) -> Void)?

    /// Effort — speed over cruise speed — a fish must exceed before it is heard at all.
    ///
    /// Infinite by default so that the school is silent unless something has deliberately set
    /// it. Cruising is meant to be silent: a tank in which every fish is audible all the time
    /// has nothing left to say when one of them bolts.
    var swishThreshold: Float = .greatestFiniteMagnitude

    /// How much lateral acceleration counts as a hard turn, as a fraction of what this fish
    /// makes at cruise speed turning at its own maximum rate.
    ///
    /// Speed alone will not do, and measuring showed why: of the seven behaviours only `dart`
    /// asks for more than 1.15 times cruise speed, so *any* effort threshold in the usable
    /// range means "darts only" — and darts are rare by design, four in a hundred and fifty
    /// seconds across a whole school. That measured two swishes in eighty seconds, which is a
    /// feature nobody would notice.
    ///
    /// Turning is the other half of the same physics: a fish comes round by pushing water
    /// sideways with its body, which is a tail stroke, which is the thing this sound *is*. But
    /// **yaw rate alone is not that push** — that was the next thing tried and it saturated, at
    /// fifty-three swishes in ninety seconds with more than half of them refused, which means
    /// the cooldown was setting the rate rather than the fish. A hovering fish pivoting on its
    /// pectorals moves almost no water however fast it comes round.
    ///
    /// Speed times yaw rate is the lateral acceleration, which is what actually displaces water,
    /// and it is selective for free: it is large only when the animal is both moving and
    /// turning. Normalised by the fish's own scale, because a clownfish and a moray are an
    /// order of magnitude apart in both terms.
    var swishTurnShare: Float = .greatestFiniteMagnitude
    var perFishSwishCooldown: Float = 4

    /// Edge-triggered, per fish, with a cooldown.
    ///
    /// The edge is the point. `effort` is recomputed every fixed step, so a fish that spends
    /// half a second above the threshold is above it for thirty steps, and a level test would
    /// raise thirty gestures for one flick of a tail. What a listener should hear is the
    /// beginning of the effort, once.
    private func noteSwish(_ fish: Fish, effort: Float, bounds: WaterBounds, dt: Float) {
        fish.swishCooldown = max(0, fish.swishCooldown - dt)
        let turning = abs(fish.yawRate) * fish.speed
            / max(fish.limits.yawRate * fish.cruiseSpeed * swishTurnShare, 1e-4)
        let strain = max(effort / max(swishThreshold, 1e-4), turning)
        // **Only while the fish is darting**, which is a narrowing and was asked for by name.
        // The threshold above answers "is this animal working hard", and it answered correctly:
        // most of what it caught was a hard turn during a cruise or a wander. But a hard turn is
        // not something a viewer can see happen — judged on the installed build, the sound could
        // not be tied to anything on screen — so the gesture is now spent only on the one act
        // that reads as an event. The strain test is kept rather than replaced by the decision
        // itself, because it fires when the animal is actually moving fast rather than at the
        // instant it made up its mind, and because `strength` is what separates a hard bolt from
        // a lazy one.
        let straining = fish.brain.behavior == .dart && strain >= 1
        let beginning = straining && !fish.wasStraining
        fish.wasStraining = straining

        guard beginning, fish.swishCooldown <= 0, let onSwish else { return }
        fish.swishCooldown = perFishSwishCooldown

        let depth = max(-fish.position.z, 1e-3)
        let halfWidth = tank.halfWidth(atDepth: depth)
        let span = max(bounds.farDepth - bounds.nearDepth, 1e-3)
        let recession = min(max((depth - bounds.nearDepth) / span, 0), 1)
        onSwish(SwishEvent(bodyLength: fish.length,
                           pan: halfWidth > 1e-4 ? fish.position.x / halfWidth : 0,
                           // Never all the way to zero: the tank is a metre deep and the
                           // listener is in it, so the back wall is not far away. This is a
                           // depth cue, not an attenuation model.
                           nearness: 1 - 0.6 * recession,
                           strength: min(max(strain, 0.55), 1.6),
                           isDart: fish.brain.behavior == .dart))
    }

    /// One fixed step of the whole school.
    private func simulate(bounds: WaterBounds, lanes: SwimLanes) {
        let dt = School.step
        for fish in fishes {
            fish.brain.dartCooldown = max(0, fish.brain.dartCooldown - dt)
            fish.brain.passageCooldown = max(0, fish.brain.passageCooldown - dt)
            fish.brain.remaining -= dt
            if fish.brain.behavior == .transit {
                fish.brain.transitElapsed += dt
                // Ends either by arriving or by running out of patience. Both set the cooldown,
                // because a fish that gave up on a route is the one most likely to be sitting in
                // its mouth and would otherwise re-enter on the very next decision.
                let routeActive = advanceTransit(fish, bounds: bounds)
                if !routeActive || fish.brain.remaining <= 0 {
                    // Finished, as opposed to given up on. `advanceTransit` returns false both
                    // ways, and the difference between them is the whole measurement — and it
                    // decides whether the fish is sent on out of the passage or simply released.
                    var leaving: Float?
                    if !routeActive, let index = fish.brain.passage,
                       passages.indices.contains(index),
                       fish.brain.waypoint >= passages[index].waypoints.count {
                        routesCrossed += 1
                        leaving = exitYaw(of: passages[index],
                                          reversed: fish.brain.passageReversed)
                    }
                    endTransit(fish, leaving: leaving)
                }
            }
            if fish.brain.remaining <= 0 {
                fish.brain.choose(context(for: fish, bounds: bounds, lanes: lanes), rand: &rand)
                if censusEntries != nil { censusEntries?["\(fish.brain.behavior)", default: 0] += 1 }
            }

            steer(fish, bounds: bounds, dt: dt)

            fish.position += Steering.direction(yaw: fish.yaw, pitch: fish.pitch) * fish.speed * dt
            Avoidance.clamp(position: &fish.position, girth: fish.girth, bounds: bounds)

            // Effort, not speed: the tail works hardest in a dart and idles in a hover, and the
            // ratio to cruise is what says which. Floored well above zero because a fish holding
            // station still sculls, and a tail that actually stops is the clearest possible
            // statement that the animation and the motion are unrelated systems.
            let effort = min(max(fish.speed / max(fish.cruiseSpeed, 1e-4), 0.0), 2.6)
            noteSwish(fish, effort: effort, bounds: bounds, dt: dt)
            let beatFactor = min(max(0.34 + 0.66 * effort, 0.34), 2.2)
            fish.swimPhase += fish.beat * beatFactor * 2 * .pi * dt
            if fish.swimPhase > 2 * .pi { fish.swimPhase -= 2 * .pi }

            // The nose-down inspection pose is eased in and out. Snapping it looks like a hinge,
            // and it is the one part of the attitude that is not a consequence of the path.
            let inspectStep: Float = 1.8 * dt
            let delta = fish.brain.inspectTarget - fish.brain.inspect
            fish.brain.inspect += min(max(delta, -inspectStep), inspectStep)

            // Open water only. A tank is closed on every side and its population is the
            // population; the ocean is a place fish cross, and a crossing ends by leaving.
            if !bounds.isEnclosed, hasLeftTank(fish, bounds: bounds) {
                place(fish, spawningOffScreen: true, bounds: bounds, lanes: lanes)
            }
        }
    }

    /// Steers toward the current waypoint and advances when it is reached. Returns false once the
    /// route is finished or has become invalid.
    ///
    /// The route is walked by index rather than by reversing the array, because this runs per fish
    /// per step and a route can be joined from either end.
    private func advanceTransit(_ fish: Fish, bounds: WaterBounds) -> Bool {
        guard let index = fish.brain.passage, passages.indices.contains(index) else { return false }
        let route = passages[index]
        let count = route.waypoints.count
        guard fish.brain.waypoint < count else { return false }
        let step = fish.brain.passageReversed
            ? count - 1 - fish.brain.waypoint
            : fish.brain.waypoint
        let target = route.waypoints[step]
        let world = SIMD3<Float>(target.x, bounds.floorY + target.y, target.z)
        let offset = world - fish.position

        // **Reached is a question about the route, not about absolute distance**, and getting
        // that wrong is why this feature was counted as working and never seen.
        //
        // The old test was a sphere of `max(radius * 0.9, length * 0.35)`, which for the moray is
        // 17 cm against a 4.5 cm hole. A fish flying *over* the wreck was therefore inside the
        // sphere of one waypoint after another and ticked the whole route off without ever being
        // in it — the census counted a transit, the eye saw a fish swim past a shipwreck. It is
        // the same shape of error as counting transits *entered*, one level further down.
        //
        // A waypoint counts as reached when the fish is within the route's declared clearance of
        // the route's own *axis* and has crossed the plane through the waypoint normal to it.
        // That is what threading a hole is, and it cannot be satisfied from above.
        let axis = routeAxis(route, at: step, reversed: fish.brain.passageReversed)
        let fromWaypoint = -offset
        let along = simd_dot(fromWaypoint, axis)
        let lateral = simd_length(fromWaypoint - axis * along)
        // Deliberately the full radius rather than `radius - girth`, though the fish is not a
        // point and that subtraction is what containment really means. Held to `radius - girth`
        // the eel could not satisfy it at all — crossings on `AQUARIUM_SEED=4` went from three per
        // two minutes to none — because nothing in this school tracks a line to two centimetres.
        // A fish that cannot tick off a waypoint does not go somewhere better; it sits in the hole
        // until the transit times out. The body margin is bought at admission instead, where it
        // costs a species the route rather than costing every route its fish — see
        // `SwimPassage.admits`.
        //
        // **The last waypoint is left by, not arrived at, and that is the whole of the twirl.**
        // It is an approach point in open water rather than a hole, and asking a fish to come
        // within a distance of it means a fish that has already swum clear of the prop must turn
        // round and go back for it — then overshoot, turn again, and repeat until the timeout
        // releases it. Reported as fish emerging from the wreck's breach and spinning through a
        // full circle for several seconds before wandering off, with the eel doing the same at the
        // arch and clipping the rock on the way round. Crossing the plane through it is enough:
        // the only way to satisfy that is to keep going forward, so the exit cannot ask for a
        // reversal however far off-axis the fish drifted on the way out.
        let isExit = fish.brain.waypoint == count - 1
        let reached = isExit
            ? along > 0 || simd_length(offset) < max(route.radius, fish.girth * 2)
            : (lateral < route.radius && along > 0) || simd_length(offset) < route.radius
        if reached {
            waypointsReached += 1
            fish.brain.waypoint += 1
            if fish.brain.waypoint >= count { return false }
            // Progress buys patience — see `FishBrain.transitPatience`.
            fish.brain.transitElapsed = 0
            fish.brain.remaining = FishBrain.transitPatience(isLurker: fish.isLurker)
        }

        // **Steer at the waypoint from a distance and along the route from close up.**
        //
        // This is the spin. A yaw derived from the *horizontal* part of the offset is meaningless
        // once that part is small — a fish sitting a few centimetres above a waypoint has a
        // horizontal offset of near-zero length whose direction is noise, and the old 0.1 mm
        // threshold let it through. `targetYaw` then swung across half a turn between frames and
        // the animal pirouetted: measured on the moray, yaw ran from -7.2 to -13.1 radians in
        // four seconds while its distance to the waypoint barely changed. The fish never escaped
        // because the behaviour cannot be abandoned partway, so it span for the whole 26-second
        // transit, took the cooldown, came back and did it again.
        //
        // Inside a passage there is only one direction worth having anyway, and it is the
        // passage's. Handing the fish the route axis both removes the singularity and is what
        // threading a hole actually looks like.
        // **Follow the tube, do not aim at its far end.**
        //
        // Steering straight at the next waypoint lets a fish cut the corner into whatever the
        // route bends around, and on a route that climbs it also commands a height a whole leg
        // away — so a fish arrives at the mouth off-axis and threads the geometry instead of the
        // hole. Tightening the arrival test alone made that worse rather than better: with the
        // centre held to `radius - girth` and nothing pulling it there, crossings on
        // `AQUARIUM_SEED=4` went from three per two minutes to none.
        //
        // The fish is steered at its own projection onto the current leg, carried a lookahead
        // forward — so being off-axis produces a correction toward the axis rather than a heading
        // that merely happens to end at the right place.
        let carrot = pursuitPoint(on: route, toward: world, traversal: fish.brain.waypoint,
                                  reversed: fish.brain.passageReversed, from: fish.position,
                                  floorY: bounds.floorY)
        let toCarrot = carrot - fish.position

        // Below a body's width the direction to any point is noise, and the yaw derived from it
        // spins the fish: measured on the moray, yaw ran from -7.2 to -13.1 radians in four
        // seconds while its distance to the waypoint barely changed, and it could not escape
        // because a transit may not be abandoned partway. Inside a passage there is only one
        // direction worth having anyway, and it is the passage's.
        let horizontal = SIMD2<Float>(toCarrot.x, toCarrot.z)
        let axisHorizontal = SIMD2<Float>(axis.x, axis.z)
        if simd_length(horizontal) > max(fish.girth, 1e-3) {
            fish.brain.targetYaw = atan2(-horizontal.y, horizontal.x)
        } else if simd_length(axisHorizontal) > 1e-3 {
            fish.brain.targetYaw = atan2(-axisHorizontal.y, axisHorizontal.x)
        }
        fish.brain.targetHeight = carrot.y - bounds.floorY
        return true
    }

    /// The point on the route a transiting fish is actually steered at.
    ///
    /// The fish's own projection onto the leg it is currently on, carried `lookahead` further
    /// along it — the standard remedy for a follower that cuts corners, and here also the thing
    /// that centres a fish in a hole it is only just thin enough for. On the first leg there is
    /// no segment behind the fish to project onto, so it simply aims at the waypoint: it is
    /// outside the prop and approaching, which is the one part of a transit where going straight
    /// at the mouth is right.
    private func pursuitPoint(on route: SwimPassage, toward world: SIMD3<Float>,
                              traversal: Int, reversed: Bool, from position: SIMD3<Float>,
                              floorY: Float) -> SIMD3<Float> {
        let count = route.waypoints.count
        guard traversal > 0 else { return world }
        let previous = reversed ? count - traversal : traversal - 1
        guard route.waypoints.indices.contains(previous) else { return world }
        let start = route.waypoints[previous]
        let from = SIMD3<Float>(start.x, floorY + start.y, start.z)

        let leg = world - from
        let legLength = simd_length(leg)
        guard legLength > 1e-5 else { return world }
        let direction = leg / legLength
        let travelled = min(max(simd_dot(position - from, direction), 0), legLength)
        // A fraction of the *leg*, never of the fish. Half a body length is 24 cm for the moray
        // against legs 7 cm long, so the carrot pinned to the far end of every segment and pure
        // pursuit silently degenerated into aiming at the waypoint — the exact behaviour it was
        // added to replace, with no symptom but an unchanged measurement.
        let lookahead = legLength * 0.4
        return from + direction * min(travelled + lookahead, legLength)
    }

    /// Which way the route is running at a given waypoint, as a unit vector in reef space.
    ///
    /// Taken forward from this waypoint to the next, and backward from the previous one at the
    /// end of the route — so every point on a route has an axis, including the one a fish leaves
    /// by. Degenerate routes fall back to world up, which no fish can cross the plane of from
    /// above and which therefore fails safe: the transit times out rather than completing on a
    /// geometry nobody authored.
    private func routeAxis(_ route: SwimPassage, at step: Int, reversed: Bool) -> SIMD3<Float> {
        let points = route.waypoints
        let ahead = reversed ? step - 1 : step + 1
        let behind = reversed ? step + 1 : step - 1
        let direction: SIMD3<Float>
        if points.indices.contains(ahead) {
            direction = points[ahead] - points[step]
        } else if points.indices.contains(behind) {
            direction = points[step] - points[behind]
        } else {
            return SIMD3<Float>(0, 1, 0)
        }
        let length = simd_length(direction)
        return length > 1e-5 ? direction / length : SIMD3<Float>(0, 1, 0)
    }

    /// - Parameter leaving: the heading the route was travelling as the fish came off the end of
    ///   it, or nil if the transit was abandoned rather than finished.
    private func endTransit(_ fish: Fish, leaving exitYaw: Float?) {
        fish.brain.passage = nil
        fish.brain.waypoint = 0
        fish.brain.transitElapsed = 0
        // A lurker comes back to its wreck quickly; anything else has had its moment. Long enough
        // that a transit reads as an event rather than as a circuit the fish is stuck in.
        fish.brain.passageCooldown = fish.isLurker
            ? rand.inRange(7, 18)
            : rand.inRange(35, 80)

        // **A fish that has just come out of a hull has to be told to keep going.**
        //
        // Ending a transit used to drop straight into a fresh decision, and a fresh decision knows
        // nothing about the wreck the animal is standing in the mouth of — so about half of them
        // pointed it back the way it came. Prop avoidance does not save it either: the term that
        // would push it clear is cut to 15% for a passable prop, precisely so that fish can get
        // near enough to use the hole. The result was the second half of the twirl, and the eel
        // clipping the arch on a 180 it should never have been allowed to start.
        //
        // Continuing along the route's own exit direction for a couple of seconds is the cheapest
        // honest answer, and it is what the animal would do: something that has committed to
        // swimming through a wreck does not change its mind in the doorway. Only on a route
        // actually completed — a transit that timed out has a fish pressed against geometry, and
        // driving it further along a line it has already failed to follow is the wrong instinct.
        if let exitYaw {
            fish.brain.behavior = .cruise
            fish.brain.targetYaw = exitYaw
            fish.brain.targetHeight = fish.position.y - tank.floorY(aspect: aspect)
            fish.brain.pitchBias = 0
            fish.brain.remaining = rand.inRange(1.8, 3.0)
            // Committed rather than merely aimed: a heading with no time on it is overwritten by
            // the next decision on the next frame, which is the behaviour being fixed.
            fish.brain.turnSign = 0
        } else {
            fish.brain.remaining = 0
        }
    }

    /// The direction a completed route was travelling as the fish left it, as a yaw.
    ///
    /// Taken from the last two waypoints in *traversal* order, so it points out of the passage
    /// whichever end the fish went in.
    private func exitYaw(of route: SwimPassage, reversed: Bool) -> Float? {
        let count = route.waypoints.count
        guard count >= 2 else { return nil }
        let last = reversed ? 0 : count - 1
        let before = reversed ? 1 : count - 2
        let direction = route.waypoints[last] - route.waypoints[before]
        let horizontal = SIMD2<Float>(direction.x, direction.z)
        guard simd_length(horizontal) > 1e-5 else { return nil }
        return atan2(-horizontal.y, horizontal.x)
    }

    /// Turns the brain's intent into a heading, subject to the walls and to what the animal can
    /// physically do.
    private func steer(_ fish: Fish, bounds: WaterBounds, dt: Float) {
        // Vertical is a controller on a height rather than a commanded angle: the pitch that
        // gets a fish to where it wants to be is proportional to how far off it is, and falls to
        // nothing as it arrives. Commanding the angle directly makes a fish sail through its own
        // target and correct, which reads as a submarine.
        let error = (bounds.floorY + fish.brain.targetHeight) - fish.position.y
        // The error at which full pitch is commanded — and the third place a length-derived
        // number ran away for a long thin animal. Six body lengths is 2.9 m for the moray in a
        // tank 0.8 m deep, so the largest height error the tank can physically hold commanded it
        // 2.4° of pitch and it descended at half a centimetre a second. Its target was right, the
        // field had stopped fighting it, and it still took half a minute to fall 12 cm — which on
        // screen is an eel that never goes anywhere near the floor.
        //
        // Capped against the water actually available. A fish cannot be more wrong about its
        // height than the column is deep, so a gain distance larger than the column describes a
        // controller that can never leave its linear region. Ordinary fish are unaffected: six
        // lengths is already within the cap for everything shorter than about 13 cm.
        let column = max(bounds.ceilingY(atDepth: -fish.position.z) - bounds.floorY, 1e-3)
        let climb = error / max(min(fish.length * 6, column * 0.75), 0.05) + fish.brain.pitchBias
        let wanted = min(max(climb, -fish.limits.maxPitch), fish.limits.maxPitch)

        // A fish threading a hull must not be shoved out of it by the same term that keeps every
        // other fish from swimming into one.
        let push = Avoidance.push(position: fish.position, length: fish.length,
                                  girth: fish.girth, bounds: bounds, surface: surface,
                                  avoidingProps: fish.brain.behavior != .transit)
        var desired = Steering.direction(yaw: fish.brain.targetYaw, pitch: wanted) + push
        // A push that exactly cancels the intent leaves nothing to steer by. Falling back to the
        // current heading makes that frame a straight line rather than a spin.
        if simd_length(desired) < 1e-4 {
            desired = Steering.direction(yaw: fish.yaw, pitch: fish.pitch)
        }

        let targetYaw = Steering.yaw(of: desired)
        let targetPitch = min(max(Steering.pitch(of: desired), -fish.limits.maxPitch),
                              fish.limits.maxPitch)
        // How hard the fish is working decides how hard it may turn. A hovering or foraging fish
        // has almost no authority and comes round slowly; a darting one has more than its cruise
        // allowance, which is what lets a startle change direction sharply while an idling fish
        // cannot. Applied to pitch as well, or a stationary fish would still snap vertically.
        let authority = SwimLimits.authority(
            effort: fish.speed / max(fish.cruiseSpeed, 1e-4))
        let yawRate = Steering.turn(&fish.yaw, toward: targetYaw,
                                    rate: fish.limits.yawRate * authority, dt: dt)
        // Kept, because the sound wants it as well as the bank does. A tail stroke is what a
        // turn is made of, so how hard a fish is turning is the other half of how loud it is —
        // see `noteSwish`.
        fish.yawRate = yawRate
        _ = Steering.turn(&fish.pitch, toward: targetPitch,
                          rate: fish.limits.pitchRate * authority, dt: dt)

        // Bank into the turn. A fish rolls its back toward the inside of a curve, and without
        // it a hard turn reads as the model being spun about a pole. The sign follows from the
        // model's axes: nose +X and up +Y put the fish's left along +Z, a positive yaw rate
        // turns it to its right, and a positive roll about the nose tips its up-vector toward
        // +Z — the wrong way — so the rate is negated.
        let bank = min(max(-yawRate * 0.42, -0.5), 0.5)
        fish.roll += (bank - fish.roll) * min(1, 6 * dt)

        // **A fish deflected by a wall adopts the heading the wall gave it.**
        //
        // Without this the intent and the push form a limit cycle, and it is the ugliest motion
        // in the tank. The intent goes on pointing at the glass for the whole of a behaviour
        // while the push turns the fish away from it; the fish clears the wall, the push decays,
        // the unchanged intent brings it straight back, and the two alternate about twice a
        // second. It reads as an animal changing its mind constantly, which is exactly what it is
        // — the mind simply is not the one making the decisions.
        //
        // Rewriting the target to wherever the fish has actually been turned converts a transient
        // deflection into a committed course change, so a fish that meets the front pane turns
        // once and swims away along its new heading. It is also what a fish does.
        if simd_length(push) > 0.35 {
            fish.brain.targetYaw = fish.yaw
        }

        let target = fish.cruiseSpeed * fish.brain.targetSpeedFactor
        let limit = fish.cruiseSpeed * fish.limits.acceleration * dt
        fish.speed += min(max(target - fish.speed, -limit), limit)
    }

    /// Writes the frame. Everything above runs on the fixed step; this runs once per frame,
    /// because a transform written twice in one frame is a transform written once.
    private func pose(_ fish: Fish, time: CFTimeInterval) {
        let bob = sin(School.wrappedPhase(time, rate: fish.bobRate, offset: fish.bobPhase))
            * fish.bobAmplitude
        fish.node.simdPosition = fish.position + SIMD3<Float>(0, bob, 0)

        // Yaw about world up, then pitch about the body's lateral axis, then roll about the
        // nose. Composed as quaternions rather than as Euler angles because `eulerAngles`
        // fixes an order this does not want and gets silently reinterpreted the moment a
        // second axis becomes non-zero — which, before this change, none of them was.
        let yaw = simd_quatf(angle: fish.yaw + 0.10 * sin(fish.swimPhase),
                             axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: fish.pitch + fish.brain.inspect,
                               axis: SIMD3<Float>(0, 0, 1))
        let roll = simd_quatf(angle: fish.roll, axis: SIMD3<Float>(1, 0, 0))
        fish.node.simdOrientation = yaw * pitch * roll

        // The recoil in the yaw above: the wave displaces the body laterally, which for a fish
        // swimming across the frame is almost straight into the camera and therefore nearly
        // invisible. Real fish yaw their heads in recoil against the tail, and borrowing that is
        // what makes the deformation read from the front-on view of the tank.
        let effort = min(max(fish.speed / max(fish.cruiseSpeed, 1e-4), 0.25), 1.8)
        let amplitude = fish.baseAmplitude * min(max(0.45 + 0.55 * effort, 0.45), 1.6)
        for material in fish.materials {
            material.setValue(NSNumber(value: fish.swimPhase), forKey: "swimPhase")
            material.setValue(NSNumber(value: amplitude), forKey: "swimAmplitude")
        }
    }

    private func context(for fish: Fish, bounds: WaterBounds,
                         lanes: SwimLanes) -> BehaviorContext {
        BehaviorContext(position: fish.position, yaw: fish.yaw, length: fish.length,
                        bounds: bounds, surface: surface, lanes: lanes,
                        laneRange: fish.laneRange, hosts: hosts, passages: passages,
                        girth: fish.girth, isLurker: fish.isLurker)
    }

    /// Evaluates `time * rate + offset` in `Double` and reduces it into one period before it
    /// is narrowed to the `Float` the sine carries.
    ///
    /// A screensaver on an unattended machine runs for days, and an ever-growing `Float` clock
    /// loses timing resolution as it does: at 48 hours its ULP is already 1/64 s, so the
    /// fastest rates start advancing in visibly uneven steps, and by a week barely a quarter of
    /// the frames at 60 Hz land on a distinct value. Wrapping after the conversion cannot
    /// recover precision the conversion already discarded, so the reduction has to happen here,
    /// in `Double`. It is seamless because a phase is periodic.
    ///
    /// Only the bob still needs this. The tail beat is integrated instead, because its rate
    /// changes with what the fish is doing and an absolute clock cannot express that.
    private static func wrappedPhase(_ time: CFTimeInterval, rate: Float, offset: Float) -> Float {
        let phase = time * Double(rate) + Double(offset)
        return Float(phase.truncatingRemainder(dividingBy: 2 * .pi))
    }

    // MARK: Fish construction and motion

    /// How long a fish may be and still fit the water, measured at the middle of the swim range.
    ///
    /// Taken once, at construction, and not revisited on a reshape — a fish's geometry scale is
    /// fixed when it is built, exactly as the reef keeps the layout it was born with.
    private var lengthCap: Float {
        let bounds = WaterBounds(tank: tank, aspect: aspect)
        let middle = (bounds.nearDepth + bounds.farDepth) / 2
        let span = bounds.ceilingY(atDepth: middle) - bounds.floorY
        return max(span * School.maxFishSpan, 0.02)
    }

    private func makeFish(from model: ModelCache.LoadedModel, spec: FishSpec,
                          lanes: SwimLanes, isLurker: Bool) -> Fish {
        let instance = model.template.clone()

        // `clone()` shares geometry *and* materials with the original. Each fish needs its
        // own materials because the swim phase is a material uniform — sharing them would
        // make the whole school beat as one animal. Copying the geometry is cheap: the
        // vertex buffers stay shared, only the material list is duplicated.
        var materials: [SCNMaterial] = []
        instance.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let copy = geometry.copy() as? SCNGeometry else { return }
            copy.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
            for material in copy.materials {
                material.shaderModifiers = [.geometry: swimModifier]
                material.setValue(NSNumber(value: 0.0), forKey: "swimPhase")
                // Amplitude is in the model's own object space, so it scales with the source
                // mesh, not with the fish's world size.
                material.setValue(NSNumber(value: model.length * 0.11), forKey: "swimAmplitude")
                material.setValue(NSNumber(value: 1.15), forKey: "swimWaves")
                material.setValue(NSNumber(value: model.minBound.x), forKey: "bodyMinX")
                material.setValue(NSNumber(value: model.length), forKey: "bodyLength")
            }
            node.geometry = copy
            materials.append(contentsOf: copy.materials)
        }

        // Blender exports Z-up with the nose at +X; the tank is Y-up. The pivot carries that
        // correction plus the scale, and the model is offset inside it so the fish turns
        // about its own centre rather than about the origin of the export.
        //
        // The scale comes from the manifest's `bodyLength` against the mesh's measured extent,
        // so a species that is re-exported slightly longer still swims at the size the library
        // says it is.
        //
        // The correction being on the *pivot* is what lets the fish node be oriented in three
        // axes: in the fish node's space the model's nose is +X, its up is +Y and its left is
        // +Z, which is the frame every angle in this file is stated in.
        let pivot = SCNNode()
        pivot.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        let bodyLength = min(spec.bodyLength, lengthCap)
        let scale = bodyLength / model.length
        pivot.scale = SCNVector3(scale, scale, scale)
        let center = model.center
        instance.position = SCNVector3(-center.x, -center.y, -center.z)
        pivot.addChildNode(instance)

        let node = SCNNode()
        node.addChildNode(pivot)
        return Fish(node: node, materials: materials, length: bodyLength,
                    depthBand: spec.depthBand, laneRange: lanes.lanes(in: spec.depthBand),
                    baseAmplitude: model.length * 0.11,
                    // Girth is measured in the model's own units, so it takes the same scale the
                    // body does — including the cap that shrinks an eel to fit a glass tank,
                    // which is what lets the capped animal through holes the declared one could
                    // not enter.
                    girth: model.girth * scale, isLurker: isLurker)
    }

    /// Puts a fish somewhere to begin, and — in open water only — puts it back when it leaves.
    ///
    /// The heading is deliberately never parallel to the frame: a fish angled in depth changes
    /// size and fog as it crosses, which is what sells the depth axis, and it keeps the tail
    /// sweep off the view direction. In a closed tank this is a spawn and nothing more, because
    /// nothing is ever placed twice.
    ///
    /// `stratum` and `spreadIndex` are set only for the opening layout. Respawns are
    /// unconstrained; by then the school has mixed.
    private func place(_ fish: Fish, spawningOffScreen: Bool, bounds: WaterBounds,
                       lanes: SwimLanes, stratum: Float? = nil, spreadIndex: Int = 0) {
        let band = fish.depthBand
        // The near limit is the *pane* in a glass tank, not the tank's near depth. They are not
        // the same number — the aquarium's water starts at 2.0 m and its glass stands at 2.89 m
        // — and the difference is the better part of a metre of water on the viewer's side of
        // the window, which is where the school used to be allowed to spawn.
        let low = bounds.nearDepth
        let high = bounds.farDepth
        let near = low + band.lower * (high - low)
        let far = low + band.upper * (high - low)
        // Jittered off the stratum by a fraction of one stratum's width, so the opening layout
        // is spread without being a visible ladder of evenly spaced depths.
        let fraction = stratum.map { min(max($0 + rand.inRange(-0.035, 0.035), 0), 1) }
            ?? rand.next()
        let depth = near + fraction * (far - near)

        fish.pace = rand.inRange(0.75, 1.3)
        // The lane nearest where it actually starts, so its first course is a short correction
        // rather than a march across the tank.
        fish.brain.lane = nearestLane(to: depth, in: fish.laneRange, lanes: lanes)

        let tilt = rand.inRange(0.22, 0.52)
        let towardFar: Float = depth < (near + far) / 2 ? -1 : 1
        let horizontal = rand.sign()
        fish.yaw = Steering.yaw(of: SIMD3<Float>(horizontal * cos(tilt), 0,
                                                 towardFar * sin(tilt)))
        fish.pitch = 0
        fish.roll = 0

        let margin = fish.length * 1.05
        // In a tank the walls are the frame, so a fish must start inside them. In open water the
        // edge is where a crossing begins and ends, and a fish is placed just beyond it.
        //
        // The floor under the max is a *fraction of the wall*, never a body length. A fish that
        // is long compared to the water it is in — which is the normal case here, since fish keep
        // their real metres while the tank shrinks around them — would otherwise be handed a
        // spawn range wider than the tank and start outside the glass, to be dragged back in by
        // the clamp on the first frame.
        let edge = (bounds.wallX(atDepth: depth).map { max($0 - margin, $0 * 0.25) }
            ?? tank.halfWidth(atDepth: depth) + margin)
        // Golden-ratio stride: consecutive fish land far apart horizontally even though their
        // depths are adjacent, so the opening frame reads as a spread school. Indexed across
        // the whole tank rather than within one species, or two species would stack.
        let spread = stratum.map { _ in
            ((Float(spreadIndex) * 0.618_034 + 0.31).truncatingRemainder(dividingBy: 1) * 2 - 1)
                * edge
        }
        let x = spawningOffScreen ? -horizontal * edge : (spread ?? rand.inRange(-edge, edge))

        let halfHeight = tank.halfHeight(atDepth: depth, aspect: aspect)
        fish.bobAmplitude = halfHeight * 0.028
        let ceiling = bounds.ceilingY(atDepth: depth) - bounds.floorY
        // The clearance a fish needs over whatever is under it, plus the sway it is about to do.
        let ground = surface.height(x: x, z: -depth)
        // A fish keeps the real metres its manifest declares while the tank shrinks around it,
        // so in a small tank that clearance is most of the visible water and every fish spawns
        // at exactly the ceiling — a flat line of animals along the top of the frame. Spending
        // at most half the water on it keeps the school spread, and a big fish cruising low over
        // the gravel is what a small tank actually looks like.
        let sand = min(ground + fish.girth * Tank.fishFloorClearance + fish.bobAmplitude,
                       ceiling / 2)
        // A lurker begins where it belongs. Spawning it uniformly through the column and waiting
        // for the behaviour to bring it down wastes the opening seconds — which are the ones that
        // get looked at — on an eel descending from mid-water like everything else.
        let top = fish.isLurker
            ? min(sand, ceiling) + (ceiling - min(sand, ceiling)) * FishBrain.lurkerCeiling
            : ceiling
        let height = rand.inRange(min(sand, ceiling), max(top, min(sand, ceiling)))
        fish.position = SIMD3<Float>(x, bounds.floorY + height, -depth)
        fish.brain.targetHeight = height
        fish.speed = fish.cruiseSpeed
        fish.brain.targetYaw = fish.yaw
        fish.brain.targetSpeedFactor = 1
        fish.brain.pitchBias = 0
        fish.brain.inspect = 0
        fish.brain.inspectTarget = 0
        // Staggered, so a school placed in one loop does not all re-decide on the same frame
        // for the rest of the run.
        fish.brain.behavior = .cruise
        fish.brain.remaining = rand.inRange(0.2, 6.0)

        fish.beat = rand.inRange(1.15, 1.75)
        fish.bobRate = rand.inRange(0.18, 0.42)
        fish.bobPhase = rand.inRange(0, 2 * .pi)
    }

    private func nearestLane(to depth: Float, in range: ClosedRange<Int>,
                             lanes: SwimLanes) -> Int {
        var best = range.lowerBound
        var bestGap = Float.greatestFiniteMagnitude
        for lane in range {
            let gap = abs(lanes.depth(lane) - depth)
            if gap < bestGap { bestGap = gap; best = lane }
        }
        return best
    }

    /// Rescales the school when the drawable changes shape.
    ///
    /// Half-height is inversely proportional to the aspect ratio at every depth, so scaling
    /// each fish by the ratio of the two aspects leaves it exactly where it was in the frame.
    /// Clamping instead would pile the school onto the new edges. The floor moves by the same
    /// factor, so a fish that cleared the sand still clears it — and the height each fish is
    /// *aiming* at has to move with it, or every fish would spend the frames after a reshape
    /// climbing back to a height that no longer means what it did.
    func adoptAspect(_ newAspect: Float) {
        guard newAspect != aspect, newAspect > 0 else { return }
        let oldFloor = tank.floorY(aspect: aspect)
        let scale = aspect / newAspect
        aspect = newAspect
        let newFloor = tank.floorY(aspect: aspect)
        for fish in fishes {
            fish.position.y = newFloor + (fish.position.y - oldFloor) * scale
            fish.brain.targetHeight *= scale
            fish.bobAmplitude *= scale
        }
    }

    private func hasLeftTank(_ fish: Fish, bounds: WaterBounds) -> Bool {
        let depth = -fish.position.z
        if depth < tank.depthCullNear || depth > tank.depthCullFar { return true }
        // Vertical as well as horizontal. A fish holds no fixed height any more, but it can
        // still climb out of the top of a frustum that is much shorter near the camera than it
        // is at the back, and a crossing only ever *ends* horizontally — so without this it
        // would stay invisible for the rest of one and the school would silently look thinner.
        //
        // **Only upward.** The obvious symmetric test — `abs(y)` against the half-height — is
        // wrong now and was merely unreachable before: at any depth nearer than
        // `floorEntryDepth` the frustum is shorter than the floor is deep, so a fish resting
        // just above the sand there satisfies it. Nothing used to put a fish there. Foraging
        // does, and the fish would vanish and respawn while sitting on the gravel in shot.
        if fish.position.y > tank.halfHeight(atDepth: depth, aspect: aspect)
            + fish.length { return true }
        if fish.position.y < bounds.floorY - fish.length { return true }
        let edge = tank.halfWidth(atDepth: depth) + fish.length * 1.25
        // Heading out, not merely outside: a fish that has turned back is on its way in.
        let outward = fish.position.x * cos(fish.yaw)
        return abs(fish.position.x) > edge && outward > 0
    }
}
