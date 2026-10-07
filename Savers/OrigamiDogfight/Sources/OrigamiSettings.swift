// What the user chose in the settings sheet, and how a launch reads it.
//
// A plain value, so the scene can be handed one without knowing whether it came from the saved
// preferences, the environment, or the sheet's live preview — the Aquarium's pattern
// (`AquariumSettings`).

import Foundation
import ScreenSaver

struct OrigamiSettings: Equatable {
    var teams: TeamsChoice
    var planes: PlanesChoice
    var tanks: TanksChoice
    var showsScoreboard: Bool

    /// What a machine that has never opened the sheet gets: every match drawn afresh, tanks in
    /// about half of them, and the card in the corner.
    static let `default` = OrigamiSettings(teams: .surprise, planes: .surprise, tanks: .sometimes,
                                           showsScoreboard: true)

    // Stored as the choices' raw strings, not ordinals: the stored value outlives this build,
    // and an ordinal would silently re-point if a choice were ever inserted.
    private static let teamsKey = "Teams"
    private static let planesKey = "Planes"
    private static let tanksKey = "Tanks"
    private static let scoreboardKey = "Scoreboard"

    var simConfig: SimConfig { SimConfig(teams: teams, planes: planes, tanks: tanks) }

    // MARK: Persistence

    /// Anything unrecognised — a value from a future build, or typed by hand — falls back to
    /// the default for that one setting rather than failing.
    static func load(from defaults: ScreenSaverDefaults?) -> OrigamiSettings {
        guard let defaults else { return .default }
        var settings = OrigamiSettings.default
        if let stored = defaults.string(forKey: teamsKey).flatMap(TeamsChoice.init(rawValue:)) { settings.teams = stored }
        if let stored = defaults.string(forKey: planesKey).flatMap(PlanesChoice.init(rawValue:)) { settings.planes = stored }
        if let stored = defaults.string(forKey: tanksKey).flatMap(TanksChoice.init(rawValue:)) { settings.tanks = stored }
        if defaults.object(forKey: scoreboardKey) != nil { settings.showsScoreboard = defaults.bool(forKey: scoreboardKey) }
        return settings
    }

    func write(to defaults: ScreenSaverDefaults?) {
        guard let defaults else { return }
        defaults.set(teams.rawValue, forKey: OrigamiSettings.teamsKey)
        defaults.set(planes.rawValue, forKey: OrigamiSettings.planesKey)
        defaults.set(tanks.rawValue, forKey: OrigamiSettings.tanksKey)
        defaults.set(showsScoreboard, forKey: OrigamiSettings.scoreboardKey)
        // Synchronised on write: the sheet runs inside `legacyScreenSaver`, which System Settings
        // kills freely, and an unflushed preference is one the user set and then watched not happen.
        defaults.synchronize()
    }

    /// The settings this launch runs under: the stored ones, with the harness's overrides on top.
    /// `tools/run-saver.swift` cannot click a sheet, so the environment is how the render loop
    /// reaches every setting — and it is empty under `legacyScreenSaver`, so it costs nothing
    /// where it matters. `ORIGAMI_TEAMS` (ffa / teams / surprise), `ORIGAMI_PLANES_TIER`
    /// (few / some / lots / surprise), `ORIGAMI_TANKS` (off / sometimes / always) and
    /// `ORIGAMI_SCOREBOARD` (0 / 1).
    static func forLaunch(defaults: ScreenSaverDefaults?,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> OrigamiSettings {
        var settings = load(from: defaults)
        if let pinned = environment["ORIGAMI_TEAMS"].flatMap({ TeamsChoice(rawValue: $0.lowercased()) }) {
            settings.teams = pinned
        }
        if let pinned = environment["ORIGAMI_PLANES_TIER"].flatMap({ PlanesChoice(rawValue: $0.lowercased()) }) {
            settings.planes = pinned
        }
        if let pinned = environment["ORIGAMI_TANKS"].flatMap({ TanksChoice(rawValue: $0.lowercased()) }) {
            settings.tanks = pinned
        }
        if let shown = environment["ORIGAMI_SCOREBOARD"] {
            settings.showsScoreboard = (shown as NSString).boolValue
        }
        return settings
    }
}
