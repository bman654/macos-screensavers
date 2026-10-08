// A paper tank: what it is, and what it is doing. How it decides is `TankCrew.swift`.
//
// Tanks belong to a side the way planes do, live on the ground under the fight, and are scaled
// with their match like everything else that belongs to a side — a furball of small planes
// fights small tanks, so a tank never towers over the planes strafing it. They shrink less than
// the planes do (`Match.tankScale`): the landscape and its houses never change size, and a tank
// shrunk all the way with a crowd of planes reads as a toy beside a cottage.

import Foundation
import simd

enum TankType: Int, CaseIterable {
    case light, heavy

    /// The model's name in `Assets/index.json`, and the stand-in's when it is missing.
    var modelName: String {
        switch self {
        case .light: return "tank"
        case .heavy: return "tank_heavy"
        }
    }

    private var baseSpec: TankSpec {
        switch self {
        // About a house's footprint: big enough to be a tank from up here, small enough that a
        // plane passing over it still reads as the larger thing.
        case .light:
            return TankSpec(size: 0.17, breadth: 0.7, speed: 0.13, hullTurnRate: 1.6, turretTurnRate: 1.8,
                            armour: 3, cooldown: 2.6, range: 1.05, height: 0.058, barrels: [0])
        case .heavy:
            return TankSpec(size: 0.22, breadth: 0.67, speed: 0.1, hullTurnRate: 1.2, turretTurnRate: 1.3,
                            armour: 5, cooldown: 3.2, range: 1.2, height: 0.077, barrels: [0.044, -0.044])
        }
    }

    /// At the match's scale. The height scales too: it is the turret top a pencil leaves from
    /// and a strafing shot must reach, and both belong to the tank.
    func spec(scale: Float) -> TankSpec {
        let b = baseSpec
        return TankSpec(size: b.size * scale, breadth: b.breadth, speed: b.speed * scale, hullTurnRate: b.hullTurnRate,
                        turretTurnRate: b.turretTurnRate, armour: b.armour, cooldown: b.cooldown,
                        range: b.range * scale, height: b.height * scale, barrels: b.barrels, scale: scale)
    }
}

struct TankSpec {
    /// Drawn footprint, metres — hull and barrel, the longer horizontal dimension.
    let size: Float
    /// Width over length of the hull and treads — the models' bounds (`tank.json`,
    /// `tank_heavy.json`), so the footprint below encloses the tank actually drawn.
    let breadth: Float
    /// Cruising speed over flat ground, m/s. About a tenth of a plane's, so the ground war is a
    /// slow undertow to the dogfight rather than a second race.
    let speed: Float
    let hullTurnRate: Float
    let turretTurnRate: Float
    /// Low against a plane's: a tank is in a match for a minute or two, and armour that lasts
    /// longer than that is never seen to matter — the match ends and a fresh one rolls in.
    let armour: Float
    let cooldown: Float
    /// How far out, horizontally, a pencil can be thrown to meet a plane.
    let range: Float
    /// The turret top above the ground.
    let height: Float
    /// Each barrel's offset to the left of the turret's line, as a fraction of `size` — the
    /// models' muzzles (`tank.json`), which the heavy has two of and fires in turn.
    let barrels: [Float]
    var scale: Float = 1

    /// A tank is a solid lump, unlike a plane, so most of its footprint takes a hit.
    var hitRadius: Float { size * 0.4 }
    /// The radius of a disc round its centre that holds the whole hull and both treads at any
    /// heading — half the hull's diagonal — so one disc answers for every way it may turn. Water
    /// and steep ground are kept out of all of it (`Ground`).
    var footprint: Float { size * 0.5 * (1 + breadth * breadth).squareRoot() }
}

enum TankState: Equatable {
    /// Rolling in from off-screen along its route, to somewhere inside the arena.
    case entering
    /// Driving between waypoints, turret tracking whatever is in reach.
    case patrol
    /// Stopped to shoot, or to look round on arriving somewhere.
    case halted(until: Double)
    /// The match is over; driving off the nearest edge it has a road to.
    case leaving
    /// Folding away where it stands, since `since` — a tank that found no clear road out, or
    /// took too long about it. Paper folds; it does not have to drive.
    case folding(since: Double)
}

struct Tank {
    let id: Int
    let slot: Int
    let side: Int
    let type: TankType
    let paper: Paper
    let spec: TankSpec

    var state: TankState
    var stateSince: Double

    var position: SIMD2<Float>
    var previousPosition: SIMD2<Float>
    /// The ground under it, so a pencil and a strafing run know where it is in height.
    var altitude: Float
    var heading: Float
    var previousHeading: Float
    /// The turret's world heading, not relative to the hull, so the hull can turn under a
    /// turret that keeps its aim.
    var turret: Float
    var previousTurret: Float
    var speed: Float = 0
    var health: Float

    /// The legs still to drive, nearest first (`NavGrid`).
    var route: [SIMD2<Float>] = []
    var nextRouteTry: Double = 0
    /// Roads in a row it was blocked on without moving.
    var blockedCount = 0
    /// Looks in a row for a road that found none.
    var routeFailures = 0
    /// Progress toward the next leg's end, checked on a clock, so a tank nosing into something
    /// it cannot pass gives up on that road rather than pushing at it forever.
    var progressCheckAt: Double
    var progressDistance: Float = .greatestFiniteMagnitude

    var target: Int?
    var retargetAt: Double = 0
    var lastSawTargetAt: Double = 0
    var cooldown: Float = 1.2
    /// A tank that has just stopped to shoot drives a little before it may stop again, or one
    /// with planes always overhead would never be seen to move.
    var nextHaltAllowed: Double = 0
    /// When it last threw a pencil, for the turret's recoil.
    var firedAt: Double = -10
    var shotsFired = 0
    /// Planes it has thrown down, for its stickers.
    var kills = 0
    /// When it last actually moved, for the probe's "stuck" count.
    var lastMovedAt: Double

    var direction: SIMD2<Float> { SIMD2(cos(heading), sin(heading)) }
    var velocity: SIMD2<Float> { direction * speed }
    var damageStage: Int { Damage.stage(health: health, armour: spec.armour, downed: false) }
    var stickers: [Sticker] { Aces.stickers(kills: kills, id: id) }

    var isActive: Bool {
        switch state {
        case .entering, .patrol, .halted: return true
        case .leaving, .folding: return false
        }
    }
}

/// A plane's run at a tank: in toward it at cruise height, a shallow dive with the guns going,
/// and a pull back up to the band.
struct StrafeRun: Equatable {
    let tank: Int
    var phase: StrafePhase
    let startedAt: Double
    /// The lowest the dive may go, set from the tank's height and the ground on the way in.
    var floor: Float
}

enum StrafePhase: Equatable {
    case approach
    case dive(since: Double)
    case pullUp(until: Double)
}
