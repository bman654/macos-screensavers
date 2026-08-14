// What the user chose in the settings sheet, and how a launch turns that into a style.
//
// The sheet itself is `AquariumSettingsSheet`; this is the part of it that the tank sees, and
// it is deliberately a plain value so that the scene can be handed one without knowing whether
// it came from a saved preference, from the environment, or from the sheet's live preview.

import Foundation
import ScreenSaver

/// Which look the tank wears, as the user expressed it: one of the three, or "whichever".
///
/// Persisted as a string rather than as an ordinal, because the stored value outlives this
/// build — inserting a style would silently re-point every existing user's saved ordinal at a
/// different look.
enum StylePreference: Equatable {
    case fixed(TankStyleName)
    case random

    var storedValue: String {
        switch self {
        case .fixed(let name): return name.rawValue
        case .random: return AquariumSettings.randomStoredValue
        }
    }

    /// Nil for anything unrecognised — a value written by a future build, or by hand. The
    /// caller falls back to the default rather than treating it as a reason to fail.
    init?(stored: String) {
        if stored == AquariumSettings.randomStoredValue {
            self = .random
        } else if let name = TankStyleName(rawValue: stored) {
            self = .fixed(name)
        } else {
            return nil
        }
    }
}

struct AquariumSettings: Equatable {
    var style: StylePreference

    /// What a machine that has never opened the sheet gets. `shallowReef` because it is the
    /// most legible of the three at a glance.
    static let `default` = AquariumSettings(style: .fixed(.shallowReef))

    /// Not a `TankStyleName`, and it must stay that way — a style added under this name would
    /// be unreachable, since `StylePreference(stored:)` resolves it to `.random` first.
    static let randomStoredValue = "random"

    private static let styleKey = "TankStyle"

    // MARK: Persistence

    static func load(from defaults: ScreenSaverDefaults?) -> AquariumSettings {
        guard let stored = defaults?.string(forKey: styleKey),
              let style = StylePreference(stored: stored)
        else { return .default }
        return AquariumSettings(style: style)
    }

    func write(to defaults: ScreenSaverDefaults?) {
        guard let defaults else { return }
        defaults.set(style.storedValue, forKey: AquariumSettings.styleKey)
        // Screensaver defaults are conventionally synchronized on write: the sheet runs inside
        // `legacyScreenSaver`, which System Settings kills freely, and an unflushed preference
        // is one the user set and then watched not happen.
        defaults.synchronize()
    }

    /// The settings this launch runs under.
    ///
    /// `AQUARIUM_STYLE` still wins, because the environment is how this repo's render loop
    /// pins a look — `tools/run-saver.swift` cannot click a sheet — and because the
    /// environment is empty under `legacyScreenSaver`, so it costs nothing where it matters.
    /// It accepts `random` as well as the three style names, so the drawn path is reachable
    /// from a build loop too.
    static func forLaunch(defaults: ScreenSaverDefaults?) -> AquariumSettings {
        if let pinned = ProcessInfo.processInfo.environment["AQUARIUM_STYLE"],
           let style = StylePreference(stored: pinned) {
            return AquariumSettings(style: style)
        }
        return load(from: defaults)
    }

    // MARK: Drawing a style

    /// Which style this launch actually wears, drawn from a stream of its own.
    ///
    /// Deliberately not drawn from the tank's stream. Every seeded render this repo has ever
    /// tuned against was made when the style was picked before the first number was consumed,
    /// so taking one here would leave `AQUARIUM_SEED=7` naming a *different* tank than the one
    /// in `docs/water-looks.md` — and the failure would be silent, because both are plausible
    /// tanks. The launch stream therefore stays byte-identical to what it was, and the draw
    /// takes its own stream off the same seed so that "surprise me" is still reproducible.
    func styleName(seed: UInt64) -> TankStyleName {
        switch style {
        case .fixed(let name):
            return name
        case .random:
            var draw = Rand(seed: seed ^ 0x517E_5D0B_1A5E)
            return TankStyleName.drawn(&draw)
        }
    }
}
