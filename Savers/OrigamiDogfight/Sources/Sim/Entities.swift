// What is in the air and on the ground: planes, projectiles, wrecks, and the events the world
// reports as they change. Tanks are in `Tank.swift`.
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
    /// A strafing run on a tank, while one is on.
    var strafe: StrafeRun?
    var nextStrafeAllowed: Double = 0
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
    /// A burst aimed down at a tank keeps the first round's aim for the rest.
    var burstClimb: Float?

    var direction: SIMD2<Float> { SIMD2(cos(pose.heading), sin(pose.heading)) }
    var velocity: SIMD2<Float> { direction * speed }
    var position: SIMD2<Float> { pose.position }
    var altitude: Float { pose.altitude }

    /// Below half armour a plane trails paper scraps.
    var isDamaged: Bool { health < spec.armour * 0.5 }

    /// Its weapon at its own scale.
    var gun: WeaponSpec { weapon.spec(scale: spec.scale) }
}

enum ProjectileState: Equatable {
    case flying
    /// On the ground since `age` was this; lies for `WeaponSpec.lieTime`, then fades.
    case landed(at: Float)
    /// Came down in a lake when `age` was this, and is going under: a crashed plane's end in
    /// miniature, rather than a spitball lying on top of the water.
    case sinking(at: Float)
}

struct Projectile {
    let id: Int
    let kind: WeaponKind
    let owner: Int
    let side: Int
    /// The shooter's paper — confetti is punched out of it.
    let paper: Paper
    /// The shooter's match scale, which sizes it and everything it does.
    let scale: Float
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

    var spec: WeaponSpec { kind.spec(scale: scale) }

    /// How far it has tumbled. Frozen on landing, so a miss lies still.
    var tumble: Float {
        switch state {
        case .flying: return age
        case .landed(let at), .sinking(let at): return at
        }
    }

    /// 1 while it can be seen at full strength, falling to 0 over its fade.
    var opacity: Float {
        switch state {
        case .flying:
            return 1
        case .landed(let at):
            let lying = age - at - WeaponSpec.lieTime
            return 1 - min(max(lying / WeaponSpec.fadeTime, 0), 1)
        case .sinking(let at):
            return 1 - smoothstep(0.5, 1, sinking(since: at))
        }
    }

    /// 0 at the splash, 1 once it has gone under.
    func sinking(since at: Float) -> Float { min(max((age - at) / WeaponSpec.sinkTime, 0), 1) }

    var isSettled: Bool {
        if case .flying = state { return false }
        return true
    }
}

/// What crashed or was knocked out — the wreck path draws both, a tank at its own scale.
enum WreckModel: Equatable {
    case plane(PlaneType)
    case tank(TankType)
}

struct Wreck {
    /// The fire burns this long before folding away.
    static let fireDuration: Double = 15
    static let foldDuration: Double = 1.2
    static let fadeDuration: Double = 2.5
    /// A plane in a lake goes under in this long, and that is the end of it.
    static let sinkDuration: Double = 3

    let id: Int
    let model: WreckModel
    let paper: Paper
    /// The match scale it crashed at, kept across a match boundary: a wreck from a match of
    /// big planes still burning as a furball of small ones begins is the size it was.
    let scale: Float
    let position: SIMD2<Float>
    let ground: Float
    let heading: Float
    let roll: Float
    /// A tank's turret, relative to its hull, as it was knocked out.
    var turret: Float = 0
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
    case hit(victim: Int, by: Int, weapon: WeaponKind, position: SIMD2<Float>, altitude: Float, paper: Paper,
             scale: Float)
    case downed(victim: Int, by: Int)
    case crashed(wreck: Int, position: SIMD2<Float>, ground: Float, inWater: Bool, paper: Paper, scale: Float)
    case exited(plane: Int)
    /// A shot came down in a lake.
    case splashed(position: SIMD2<Float>, kind: WeaponKind, scale: Float)
    case tankSpawned(tank: Int)
    case tankFired(tank: Int)
    case tankHit(tank: Int, by: Int, position: SIMD2<Float>, altitude: Float, paper: Paper, scale: Float)
    case tankDestroyed(tank: Int, by: Int, wreck: Int, position: SIMD2<Float>, ground: Float, paper: Paper,
                       scale: Float)
    case tankLeft(tank: Int)
}

/// `sin(time × rate + phase)`, with the argument formed in `Double`.
///
/// Every oscillation here — a flame's lick, a plane's flutter, a downed plane's rocking — runs
/// off an absolute clock, and in `Float` that clock's resolution coarsens as it grows: by ten
/// hours a step of the argument is several milliseconds' worth, and the motion visibly steps.
/// Forming the argument in `Double` keeps it smooth however long the saver has been running.
func wave(_ time: Double, rate: Double, phase: Double = 0) -> Float {
    Float(sin(time * rate + phase))
}

extension Float {
    /// Into (-π, π].
    var wrappedAngle: Float {
        var a = self.remainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi }
        return a
    }
}
