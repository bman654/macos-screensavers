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

    /// The layout to pin, or nil to draw a fresh tank every launch.
    ///
    /// The same number `AQUARIUM_SEED` takes, reachable without an environment — inside
    /// `legacyScreenSaver` the environment is empty, so until this existed a tank seen on the
    /// real screensaver could never be looked at again. That is the whole feature: the seed is
    /// shown in the corner of the tank (`showsSeed`), and typing it back here returns to it.
    var seed: UInt64?

    /// Whether the tank prints the seed it was drawn from in its corner.
    var showsSeed: Bool

    var soundEnabled: Bool

    /// What a machine that has never opened the sheet gets. `shallowReef` because it is the
    /// most legible of the three at a glance.
    ///
    /// `showsSeed` defaults *on* because the two halves of the feature only work together: a
    /// user who cannot see a seed has nothing to type into the field, so a default-off badge
    /// leaves the field addressing a number the user has no way to learn. It is one click to
    /// turn off, and the badge is deliberately faint.
    ///
    /// Sound defaults off as settled policy because a screensaver starts when the user walks
    /// away. Unrequested sound otherwise plays to an empty room, into a meeting they just
    /// walked into, or at 2am. Opted-in ambience is charming; the same audio uninvited is why
    /// people uninstall screensavers.
    static let `default` = AquariumSettings(style: .fixed(.shallowReef), seed: nil,
                                            showsSeed: true, soundEnabled: false)

    /// Not a `TankStyleName`, and it must stay that way — a style added under this name would
    /// be unreachable, since `StylePreference(stored:)` resolves it to `.random` first.
    static let randomStoredValue = "random"

    private static let styleKey = "TankStyle"
    private static let seedKey = "TankSeed"
    private static let showsSeedKey = "ShowsSeed"
    private static let soundEnabledKey = "SoundEnabled"

    // MARK: Persistence

    static func load(from defaults: ScreenSaverDefaults?) -> AquariumSettings {
        guard let defaults else { return .default }
        var settings = AquariumSettings.default
        if let stored = defaults.string(forKey: styleKey),
           let style = StylePreference(stored: stored) {
            settings.style = style
        }
        // Stored as a string, not as an integer: `UInt64` has no `UserDefaults` accessor that
        // round-trips the top of its range, and an absent key has to be distinguishable from a
        // pinned zero — `integer(forKey:)` returns 0 for both.
        settings.seed = defaults.string(forKey: seedKey).flatMap(UInt64.init)
        if defaults.object(forKey: showsSeedKey) != nil {
            settings.showsSeed = defaults.bool(forKey: showsSeedKey)
        }
        if defaults.object(forKey: soundEnabledKey) != nil {
            settings.soundEnabled = defaults.bool(forKey: soundEnabledKey)
        }
        return settings
    }

    func write(to defaults: ScreenSaverDefaults?) {
        guard let defaults else { return }
        defaults.set(style.storedValue, forKey: AquariumSettings.styleKey)
        if let seed {
            defaults.set(String(seed), forKey: AquariumSettings.seedKey)
        } else {
            // Removed rather than written empty, so "no seed" reads the same whether the user
            // has never pinned one or has just cleared the field.
            defaults.removeObject(forKey: AquariumSettings.seedKey)
        }
        defaults.set(showsSeed, forKey: AquariumSettings.showsSeedKey)
        defaults.set(soundEnabled, forKey: AquariumSettings.soundEnabledKey)
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
        var settings = load(from: defaults)
        if let pinned = ProcessInfo.processInfo.environment["AQUARIUM_STYLE"],
           let style = StylePreference(stored: pinned) {
            settings.style = style
        }
        // The badge is a debugging aid in this repo's render loop and a stored preference on a
        // user's machine, so the environment has to be able to turn it off as well as on —
        // otherwise every screenshot taken for `docs/water-looks.md` would carry a seed on it.
        if let shown = ProcessInfo.processInfo.environment["AQUARIUM_SHOW_SEED"] {
            settings.showsSeed = (shown as NSString).boolValue
        }
        // The environment is how this repo's render and record loop reaches settings, since
        // `tools/run-saver.swift` cannot click a sheet.
        if let enabled = ProcessInfo.processInfo.environment["AQUARIUM_SOUND"] {
            settings.soundEnabled = (enabled as NSString).boolValue
        }
        return settings
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
