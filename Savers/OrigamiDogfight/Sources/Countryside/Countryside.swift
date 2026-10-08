// Everything around the fight that has a life of its own: the season and the hour, the mills and
// the boats, the sheep, the cranes, and the marks the fight leaves on the land.
//
// One per session, beside the sim and kept with it — through an idle release and a quality
// change the view hands both to the rebuilt scene, so the sheep are where they were and the
// scorches are still on the ground. No rendering imports: the renderer reads this, and this reads
// the sim, and nothing flows back. A summer fight with all of it running is the same fight, event
// for event, as one with none of it.

import Foundation
import simd

final class Countryside {
    let atmosphere: Atmosphere
    let windmills: [Windmill]
    let moorings: [Mooring]
    let roads: [Road]
    private(set) var pasture: Pasture
    private(set) var marks = Marks()
    private(set) var cranes: CraneSchedule
    private(set) var traffic: Traffic
    private let seed: UInt64

    /// The sim's props a windmill stands in place of, which the scenery must not also draw.
    let replacedProps: Set<Int>

    init(sim: DogfightSim, atmosphere: Atmosphere,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.atmosphere = atmosphere
        seed = sim.seed
        windmills = Layout.windmills(props: sim.props, terrain: sim.terrain, seed: sim.seed)
        replacedProps = Set(windmills.map(\.prop))
        moorings = Layout.moorings(props: sim.props, terrain: sim.terrain, seed: sim.seed)
        roads = sim.roads
        pasture = Pasture(terrain: sim.terrain, props: sim.props, seed: sim.seed, airfields: sim.airfieldsAhead)
        // `ORIGAMI_CRANES_AT`: seconds of sim time at which the first flock sets off — a harness
        // override, like every `ORIGAMI_*`, empty under `legacyScreenSaver`.
        let first = environment["ORIGAMI_CRANES_AT"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        cranes = CraneSchedule(seed: sim.seed, firstAt: first)
        traffic = Traffic(roads: roads, seed: sim.seed)
    }

    /// Something the fight did. `live` is false for events drained when a scene is built — a
    /// warmup's — whose moment is not now; those take their time from the sim's own record.
    func observe(_ event: SimEvent, sim: DogfightSim, live: Bool) {
        switch event {
        case .crashed(let wreck, let position, _, let inWater, _, let scale):
            guard !inWater else { return }
            burned(wreck: wreck, at: position, size: 0.21 * scale, sim: sim, live: live)
        case .tankDestroyed(_, _, let wreck, let position, _, _, let scale):
            burned(wreck: wreck, at: position, size: 0.22 * scale, sim: sim, live: live)
        case .matchStarted(let index, _, _):
            // The first match is the session starting, with nothing on the ground to clear.
            guard index > 0 else { return }
            marks.matchBegan(at: index == sim.match.index ? sim.match.startedAt : sim.time)
        case .matchEnded(let index, _):
            cranes.matchEnded(index: index, at: sim.time)
        default:
            break
        }
    }

    private func burned(wreck: Int, at position: SIMD2<Float>, size: Float, sim: DogfightSim, live: Bool) {
        // A wreck the sim has already let go of burned long ago: its mark is full-grown.
        let time = sim.wrecks.first { $0.id == wreck }?.crashedAt ?? (live ? sim.time : sim.time - 60)
        marks.burned(at: position, size: size, time: time, id: wreck, props: sim.props, seed: seed)
    }

    /// Steps the fight `count` times and the countryside with it, a step at a time: each of the
    /// fight's steps is heard as it happens, and the flocks and the cars step at their own
    /// boundaries with the tanks and the airfields as they stood at that very step. So where a
    /// sheep is after four minutes is the seed's to say, not the display's — fed one snapshot per
    /// frame instead, a 15 Hz frame stepped a flock twice against the same tanks and a 120 Hz one
    /// once each, and the two drifted apart. Returns what the fight did, for the renderer.
    func advance(_ sim: DogfightSim, steps count: Int) -> [SimEvent] {
        var happened: [SimEvent] = []
        for _ in 0..<max(count, 0) {
            sim.advance()
            let events = sim.drainEvents()
            for event in events { observe(event, sim: sim, live: true) }
            catchUp(with: sim)
            happened += events
        }
        return happened
    }

    /// Brings everything with a clock of its own up to the sim's time, and no further — the
    /// renderer draws between the last two steps and never steps anything itself. Called by
    /// `advance` after every sim step, and once when a scene is built, to pick up a sim that ran
    /// on before there was a countryside (a warmup).
    func catchUp(with sim: DogfightSim) {
        let time = sim.time
        marks.forget(before: time)
        cranes.advance(to: time)
        // The tanks and airfields are gathered only on a step that needs them: this runs at the
        // sim's 120 Hz, and the flocks and cars step at 30.
        guard pasture.isDue(at: time) || traffic.isDue(at: time) else { return }
        let tanks = sim.tanks.map(\.position)
        pasture.advance(to: time, tanks: tanks, airfields: sim.airfieldsAhead)
        traffic.advance(to: time, tanks: tanks)
    }
}
