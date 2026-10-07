// What is in the air and on the ground: planes, projectiles, wrecks, and the events the world
// reports as they change.
//
// Plain value types the renderer reads each frame. Every moving thing keeps the pose it had at
// the start of the last step, so the renderer can interpolate between fixed steps instead of
// showing the 120 Hz staircase on a display that does not divide it.

import Foundation
import simd

/// Where a plane was and how it was sitting — everything the renderer interpolates.
struct Pose {
    var position: SIMD2<Float>
    var altitude: Float
    var heading: Float
    /// Radians, positive rolling into a left (counter-clockwise) turn. Unbounded while a downed
    /// plane spins, so interpolation never has to unwrap it.
    var bank: Float
    /// Radians, nose up positive.
    var pitch: Float
}

enum PlaneState: Equatable {
    /// Flying in from off-screen toward `aim`, ignoring the wall until it is inside.
    case entering(aim: SIMD2<Float>)
    case fighting
    /// The match is over; flying off the screen along `direction`.
    case exiting(direction: SIMD2<Float>)
    /// Shot down: out of control, spiralling in. `spin` is ±1, the way it turns.
    case downed(killer: Int, spin: Float)

    var isDowned: Bool {
        if case .downed = self { return true }
        return false
    }
}

/// What a pilot is doing beyond "chase the target". Each one ends on its own clock.
enum Maneuver: Equatable {
    case pursue
    /// A hard turn toward the attacker's side, to make it overshoot.
    case breakTurn(direction: Float, until: Double)
    /// Straight and fast, to open the range and come back for a head-on pass rather than
    /// circling — the cure for two equal planes chasing each other's tails forever.
    case extend(heading: Float, until: Double)
}

struct PilotMemory {
    var target: Int?
    var retargetAt: Double = 0
    var maneuver: Maneuver = .pursue
    var nextBreakAllowed: Double = 0
    /// How long the plane has been turning hard the same way, for the anti-orbit rule.
    var turnSign: Float = 0
    var sameTurnTime: Float = 0
    var lastShotAt: Double
    /// The altitude it settles at when nothing else is asking for one.
    var cruiseAltitude: Float
    var cruiseUntil: Double = 0
    /// A jink away from an attacker's altitude, held for the length of a break.
    var jinkAltitude: Float?
    /// The strongest soft-wall pull this step, kept for the probe's "stuck at the wall" count.
    var wallUrgency: Float = 0
}

struct Plane {
    let id: Int
    let slot: Int
    let side: Int
    let type: PlaneType
    let weapon: WeaponKind
    let paper: Paper
    let spec: PlaneSpec

    var state: PlaneState
    var stateSince: Double

    var pose: Pose
    var previous: Pose
    var speed: Float
    var turnRate: Float = 0
    var climb: Float = 0
    var health: Float

    var pilot: PilotMemory
    var cooldown: Float = 0.6
    var burstLeft = 0
    var burstTimer: Float = 0

    var direction: SIMD2<Float> { SIMD2(cos(pose.heading), sin(pose.heading)) }
    var velocity: SIMD2<Float> { direction * speed }
    var position: SIMD2<Float> { pose.position }
    var altitude: Float { pose.altitude }

    /// Below half armour a plane trails paper scraps.
    var isDamaged: Bool { health < spec.armour * 0.5 }
}

enum ProjectileState: Equatable {
    case flying
    /// On the ground since `age` was this; lies for `WeaponSpec.lieTime`, then fades.
    case landed(at: Float)
}

struct Projectile {
    let id: Int
    let kind: WeaponKind
    let owner: Int
    let side: Int
    /// The shooter's paper — confetti is punched out of it.
    let paper: Paper
    /// Tumble axis times rate, radians per second, so every clip turns its own way.
    let spin: SIMD3<Float>

    var position: SIMD2<Float>
    var altitude: Float
    var previousPosition: SIMD2<Float>
    var previousAltitude: Float
    var velocity: SIMD2<Float>
    var climb: Float
    var age: Float = 0
    var state: ProjectileState = .flying

    /// How far it has tumbled. Frozen on landing, so a miss lies still.
    var tumble: Float {
        if case .landed(let at) = state { return at }
        return age
    }

    /// 1 while it can be seen at full strength, falling to 0 over its fade.
    var opacity: Float {
        guard case .landed(let at) = state else { return 1 }
        let lying = age - at - WeaponSpec.lieTime
        return 1 - min(max(lying / WeaponSpec.fadeTime, 0), 1)
    }
}

struct Wreck {
    /// The fire burns this long before folding away.
    static let fireDuration: Double = 15
    static let foldDuration: Double = 1.2
    static let fadeDuration: Double = 2.5
    /// A plane in a lake goes under in this long, and that is the end of it.
    static let sinkDuration: Double = 3

    let id: Int
    let type: PlaneType
    let paper: Paper
    let position: SIMD2<Float>
    let ground: Float
    let heading: Float
    let roll: Float
    let crashedAt: Double
    let inWater: Bool

    var lifetime: Double {
        inWater ? Wreck.sinkDuration : Wreck.fireDuration + Wreck.foldDuration + Wreck.fadeDuration
    }
}

enum SimEvent {
    case matchStarted(index: Int, mode: MatchMode, planes: Int)
    case matchEnded(index: Int, kills: Int)
    case spawned(plane: Int)
    case fired(plane: Int, weapon: WeaponKind)
    case hit(victim: Int, by: Int, weapon: WeaponKind, position: SIMD2<Float>, altitude: Float, paper: Paper)
    case downed(victim: Int, by: Int)
    case crashed(wreck: Int, position: SIMD2<Float>, ground: Float, inWater: Bool, paper: Paper)
    case exited(plane: Int)
}

extension Float {
    /// Into (-π, π].
    var wrappedAngle: Float {
        var a = self.remainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi }
        return a
    }
}
