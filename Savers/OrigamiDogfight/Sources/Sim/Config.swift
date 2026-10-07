// What a run is asked to stage, in the settings sheet's own words, and what a match makes of it.
//
// Pure Swift with no `ScreenSaver` import, so the headless probe compiles it: persisting these
// is `OrigamiSettings`, which sits beside the view.

import Foundation

/// Free-for-all, teams, or a fresh draw every match.
enum TeamsChoice: String, CaseIterable {
    case ffa, teams, surprise
}

/// How crowded the sky is. "Surprise me" draws a tier afresh every match.
enum PlanesChoice: String, CaseIterable {
    case few, some, lots, surprise

    var tier: PlaneTier? {
        switch self {
        case .few: return .few
        case .some: return .some
        case .lots: return .lots
        case .surprise: return nil
        }
    }
}

enum TanksChoice: String, CaseIterable {
    case off, sometimes, always
}

/// The three crowd sizes a match can draw.
enum PlaneTier: Int, CaseIterable {
    case few, some, lots

    /// Plane counts per mode. A team fight wants counts its sides divide evenly — a 2-on-1 is a
    /// rout rather than a fight — so the team modes take the even (or threefold) members of the
    /// tier's range.
    func counts(for mode: MatchMode) -> [Int] {
        switch (self, mode) {
        case (.few, .ffa): return [3, 4]
        case (.few, .teams2): return [4]
        case (.few, .teams3): return [3]
        case (.some, .ffa): return [5, 6, 7]
        case (.some, .teams2): return [6]
        case (.some, .teams3): return [6]
        case (.lots, .ffa): return [8, 9, 10, 11, 12]
        case (.lots, .teams2): return [8, 10, 12]
        case (.lots, .teams3): return [9, 12]
        }
    }

    init(planes: Int) {
        self = planes <= 4 ? .few : (planes <= 7 ? .some : .lots)
    }
}

/// Everything a sim is told before it starts. The choices come from the settings sheet; the
/// pins are harness overrides (`ORIGAMI_MODE`, `ORIGAMI_PLANES`), empty in a real run, and
/// win over the choices when set.
struct SimConfig {
    var teams: TeamsChoice = .surprise
    var planes: PlanesChoice = .surprise
    var tanks: TanksChoice = .sometimes
    /// An exact mode, three-way team fights included.
    var mode: MatchMode?
    /// An exact plane count, 2 to 12.
    var planeCount: Int?
    /// A winter's: the lakes are ice, and ground for everything (`Terrain`).
    var frozenLakes = false
}
