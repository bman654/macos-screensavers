// The session's weather and hour: which season the landscape is folded in, and where the sun
// is — chosen once per session, in the settings sheet's words or drawn from the seed.
//
// Pure Swift, no rendering imports, beside the sim: the season reaches the sim too, because a
// winter's frozen lakes are ground for everything that lands on them (`Terrain`). Everything
// else here is the renderer's to read.

import Foundation

/// The sheet's choice. "Surprise me" draws one per session from the seed — not per match, as the
/// fight's choices are: the landscape is built once, and a season that changed under a live
/// fight would mean refolding every field.
enum SeasonChoice: String, CaseIterable {
    case surprise, summer, autumn, winter
}

enum DayTimeChoice: String, CaseIterable {
    case surprise, morning, midday, evening
}

enum Season: String, CaseIterable {
    case summer, autumn, winter
}

enum DayTime: String, CaseIterable {
    case morning, midday, evening

    /// Where on the day's dial a session that chose this begins. Evening starts short of the end
    /// so that it, too, has somewhere to drift — into dusk, with every window lit.
    var startPhase: Double {
        switch self {
        case .morning: return 0
        case .midday: return 0.5
        case .evening: return 0.85
        }
    }
}

struct Atmosphere: Equatable {
    let season: Season
    let dayTime: DayTime

    /// How long a session takes to drift from wherever it began to dusk. An hour: slow enough
    /// that nobody watching sees the light move, fast enough that a saver left on all afternoon
    /// ends the day as the room does.
    static let driftSeconds: Double = 3600

    var frozenLakes: Bool { season == .winter }

    /// A choice made in words, resolved for one session. Drawn from the seed rather than the
    /// clock, so a seed typed into the harness names the whole picture — the season and the hour
    /// as well as the landscape — and its own stream, so adding a draw here reshuffles nothing
    /// else.
    init(season: SeasonChoice, dayTime: DayTimeChoice, seed: UInt64) {
        var rand = Rand(seed: seed ^ 0xA7_05_EA_50_17_D4)
        let drawnSeason = Season.allCases[rand.index(count: Season.allCases.count)]
        let drawnTime = DayTime.allCases[rand.index(count: DayTime.allCases.count)]
        self.season = Season(rawValue: season.rawValue) ?? drawnSeason
        self.dayTime = DayTime(rawValue: dayTime.rawValue) ?? drawnTime
    }

    /// The day's dial at a moment of the session: 0 is early morning, 0.5 midday — the look v1
    /// and v2 shipped with — 0.85 golden evening and 1 dusk. Sim time, which runs on through an
    /// idle release and a quality change, so a rebuilt scene picks the light up where it was.
    func phase(at time: Double) -> Double {
        let start = dayTime.startPhase
        return start + (1 - start) * min(max(time / Atmosphere.driftSeconds, 0), 1)
    }
}
