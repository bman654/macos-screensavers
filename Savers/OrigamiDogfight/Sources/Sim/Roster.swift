// The game-design numbers: what each plane is like to fly and what each weapon does.
//
// These live in Swift rather than in the model manifests because they are balance, not geometry
// — `docs/origami-plan.md` §Roster. A model promises only its shape; how fast a dart is, or how
// far a rubber band carries, is decided here and tuned by watching the fight and by the numbers
// `tools/origami-sim-probe.swift` reports.
//
// Every length is in metres of the diorama: the arena is about four and a half metres across at
// the planes' altitude, and a plane is about 0.29 m nose to tail, so it fills roughly 6% of the
// width — see `ViewRig`. Speeds are chosen against that width, not against real paper planes:
// a real dart flies at five metres a second and would cross this screen in under a second.
//
// Everything here is pure Swift with no rendering imports, so the headless probe compiles it.

import Foundation

enum PlaneType: Int, CaseIterable {
    case dart, glider, bomber, stunt, interceptor

    /// The model's name in `Assets/index.json`, and the stand-in's when it is missing.
    var modelName: String {
        switch self {
        case .dart: return "dart"
        case .glider: return "glider"
        case .bomber: return "bomber"
        case .stunt: return "stunt"
        case .interceptor: return "interceptor"
        }
    }

    var spec: PlaneSpec {
        switch self {
        // Fastest, widest turns: a dart boom-and-zooms rather than turning with anything.
        case .dart:
            return PlaneSpec(minSpeed: 1.0, cruiseSpeed: 1.26, maxSpeed: 1.52, turnRate: 2.4,
                             armour: 5, size: 0.30, weapons: [.spitball, .thumbtack])
        // Slow and very nimble: it wins any turning fight it can stay in.
        case .glider:
            return PlaneSpec(minSpeed: 0.66, cruiseSpeed: 0.86, maxSpeed: 1.05, turnRate: 3.5,
                             armour: 6.2, size: 0.28, weapons: [.paperClip, .eraser])
        // Slowest and toughest; its weapons are the short-range heavy ones.
        case .bomber:
            return PlaneSpec(minSpeed: 0.62, cruiseSpeed: 0.78, maxSpeed: 0.95, turnRate: 2.3,
                             armour: 9, size: 0.26, weapons: [.paperBall, .confetti])
        case .stunt:
            return PlaneSpec(minSpeed: 0.84, cruiseSpeed: 1.09, maxSpeed: 1.31, turnRate: 3.2,
                             armour: 6.2, size: 0.26, weapons: [.staples])
        case .interceptor:
            return PlaneSpec(minSpeed: 0.96, cruiseSpeed: 1.22, maxSpeed: 1.48, turnRate: 2.9,
                             armour: 5, size: 0.29, weapons: [.rubberBand, .thumbtack])
        }
    }
}

struct PlaneSpec {
    let minSpeed: Float
    let cruiseSpeed: Float
    let maxSpeed: Float
    /// Radians per second, at any speed — so a plane that slows down turns tighter, which is
    /// exactly the trade a pilot makes in a turning fight and the one `Pilot` exploits.
    let turnRate: Float
    let armour: Float
    /// The plane's larger horizontal dimension on screen — nose to tail for a dart, wingtip to
    /// wingtip for the bomber and the delta, which are wider than they are long. Scaling every
    /// model by its length made those two half as large again in area as a dart, and they read
    /// as planes much nearer the camera.
    let size: Float
    let weapons: [WeaponKind]

    /// Vertical speed limit, m/s. Shared, because altitude is play rather than performance.
    var climbRate: Float { 0.32 }

    /// The radius of a plane for a projectile's hit test: a little under half the length,
    /// because a paper plane is mostly empty air beside its keel.
    var hitRadius: Float { size * 0.33 }
}

enum WeaponKind: Int, CaseIterable {
    case spitball, thumbtack, paperClip, eraser, paperBall, confetti, staples, rubberBand

    /// The projectile model's name in `Assets/index.json`. Confetti has none: it is runtime
    /// discs, per the plan.
    var modelName: String? {
        switch self {
        case .spitball: return "spitball"
        case .thumbtack: return "thumbtack"
        case .paperClip: return "paper_clip"
        case .eraser: return "eraser"
        case .paperBall: return "paper_ball"
        case .confetti: return nil
        case .staples: return "staple"
        case .rubberBand: return "rubber_band"
        }
    }

    var spec: WeaponSpec {
        switch self {
        case .spitball:
            return WeaponSpec(muzzleSpeed: 2.6, dragTime: 0.45, gravity: 1.6, damage: 0.8,
                              cooldown: 0.58, range: 0.85, cone: 0.17, radius: 0.016, size: 0.061)
        case .thumbtack:
            return WeaponSpec(muzzleSpeed: 2.8, dragTime: 0.55, gravity: 1.8, damage: 1.2,
                              cooldown: 0.99, range: 0.9, cone: 0.15, radius: 0.014, size: 0.072)
        case .paperClip:
            return WeaponSpec(muzzleSpeed: 2.6, dragTime: 0.5, gravity: 1.6, damage: 1.0,
                              cooldown: 0.80, range: 0.85, cone: 0.17, radius: 0.018, size: 0.090)
        case .eraser:
            return WeaponSpec(muzzleSpeed: 2.4, dragTime: 0.45, gravity: 1.6, damage: 0.9,
                              cooldown: 0.67, range: 0.8, cone: 0.18, radius: 0.018, size: 0.072)
        // Big, slow, and it drops like the lump it is — the bomber has to be close and level.
        case .paperBall:
            return WeaponSpec(muzzleSpeed: 1.7, dragTime: 0.5, gravity: 3.6, damage: 2.4,
                              cooldown: 2.00, range: 0.6, cone: 0.24, radius: 0.04, size: 0.115)
        // A shotgun of hole-punch dots: each does little, a close spread does a lot.
        case .confetti:
            return WeaponSpec(muzzleSpeed: 2.5, dragTime: 0.3, gravity: 1.2, damage: 0.45,
                              cooldown: 1.68, range: 0.6, cone: 0.28, radius: 0.012, size: 0.036,
                              pellets: 6, spread: 0.24)
        case .staples:
            return WeaponSpec(muzzleSpeed: 3.0, dragTime: 0.5, gravity: 1.4, damage: 0.7,
                              cooldown: 1.60, range: 0.9, cone: 0.15, radius: 0.012, size: 0.054,
                              burst: 3, burstInterval: 0.085)
        // Long range: the one weapon that can reach across a fifth of the screen.
        case .rubberBand:
            return WeaponSpec(muzzleSpeed: 3.2, dragTime: 0.8, gravity: 1.0, damage: 1.5,
                              cooldown: 1.52, range: 1.35, cone: 0.12, radius: 0.02, size: 0.108)
        }
    }
}

struct WeaponSpec {
    /// Added to the shooter's own velocity, m/s.
    let muzzleSpeed: Float
    /// Horizontal speed decays as exp(-t / dragTime). Without drag a miss would sail off the
    /// screen; with it every miss comes down inside the fight, where it is seen to land.
    let dragTime: Float
    /// m/s². A toy gravity, chosen so a shot drops about its own target's thickness over its
    /// useful range — real gravity would have every spitball in the grass before it left the
    /// shooter's wingtip at these speeds.
    let gravity: Float
    let damage: Float
    let cooldown: Float
    /// How far the AI will fire from. Past this a shot has dropped below the target.
    let range: Float
    /// Half-angle, radians, the target must be inside before the trigger is pulled.
    let cone: Float
    /// Collision radius.
    let radius: Float
    /// Drawn size: the longest dimension the model is scaled to. Far larger than real — a
    /// 6 mm staple would be a pixel from up here, and even at a quarter of a plane's length a
    /// spitball is only about 25 points across a 2056-point screen.
    let size: Float
    var pellets: Int = 1
    var spread: Float = 0
    var burst: Int = 1
    var burstInterval: Float = 0

    /// How long a miss lies on the ground before it fades, and how long the fade takes.
    static let lieTime: Float = 4.0
    static let fadeTime: Float = 1.2
}

// MARK: - Paper

/// What a plane is folded from. An identity only: the textures are drawn by the renderer
/// (`PaperTextures`), so the sim never needs CoreGraphics.
enum PaperKind: Int, CaseIterable {
    case notebook, graph, newspaper, kraft, plain
}

struct Paper: Equatable {
    let kind: PaperKind
    /// Index into `PaperPalette.plain` for `.plain`; ignored otherwise.
    let tint: Int

    static let plainCount = 8
}

/// Which plain origami colours are clear enough to be a team's colour, as indices into the
/// renderer's palette (`PaperPalette.plain`): red, blue, yellow, violet — chosen to stay distinct
/// from each other, and from the green landscape under them, at 108x71 in the picker tile as well
/// as across a 4K screen.
enum TeamColours {
    static let indices = [0, 1, 2, 3]
}
