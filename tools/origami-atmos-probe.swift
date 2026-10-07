// Headless soak of Origami Dogfight's seasons and countryside: what winter's frozen lakes do to
// the fight, and whether the life around the fight keeps its own rules.
//
// The fight's own soak is `tools/origami-sim-probe.swift`; this one runs the same sim with the
// countryside stepped beside it, the way the renderer steps it, and counts:
//
//   splash   shots that splashed into a lake — must be 0 in winter
//   iceShot  shots that came to rest on a lake's ice — winter's must be well above 0
//   iceCrash wrecks that burn on the ice rather than sinking
//   iceTank  tank-time with a tank's centre over a frozen lake — tanks may cross
//   sheepWet sheep-steps on a lake, frozen or not; sheepTight the closest two sheep came, as a
//            fraction of their spacing — neither may go wrong
//   roadWet  road points over a lake — must be 0
//   onRwy    sheep-steps with a sheep's centre on a standing airfield, and car-steps with a car on
//            one — both must be 0; "airfields" the airfields stood, to show the rule was tested
//   flocks   crane flocks that set off; scorch / trees the marks and fires the fight left
//   hash     everything the countryside drew, for determinism: two runs of a seed must agree
//
//   swiftc -O -parse-as-library tools/origami-atmos-probe.swift Shared/SaverKit/Rand.swift \
//       Savers/OrigamiDogfight/Sources/Sim/*.swift Savers/OrigamiDogfight/Sources/Countryside/*.swift \
//       -o /tmp/origami-atmos-probe
//   /tmp/origami-atmos-probe --minutes 10 --seeds 1,2,3,42 [--teams surprise|teams|ffa]
//
// Every seed runs in every season; `--teams teams` makes every match a team match, so every
// match has airfields for the flocks and the cars to keep off.

import Foundation
import simd

struct Tally {
    var splash = 0, iceShot = 0, landShot = 0, iceCrash = 0, crashes = 0, kills = 0
    var iceTank: Double = 0, tankTime: Double = 0
    var sheepWet = 0, sheepTight: Float = .infinity, sheep = 0
    var roadWet = 0, roads = 0, cars = 0, mills = 0
    var sheepOnAirfield = 0, carsOnAirfield = 0, airfields = Set<String>()
    var flocks = Set<Double>(), scorches = Set<Int>(), trees = Set<Int>()
    var nonFinite = 0
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    var seconds: Double = 0
}

func mix(_ h: inout UInt64, _ v: Float) {
    h ^= UInt64(v.bitPattern)
    h = h &* 0x100_0000_01B3
}

/// The airfields actually standing — unfolding, up, or folding — which is every phase but the
/// intermission between matches.
func standing(_ sim: DogfightSim) -> [Airfield] {
    if case .intermission = sim.match.phase { return [] }
    return sim.match.bases.compactMap { $0 }
}

func soak(seed: UInt64, season: Season, teams: TeamsChoice, minutes: Double) -> Tally {
    let atmosphere = Atmosphere(season: SeasonChoice(rawValue: season.rawValue)!, dayTime: .midday, seed: seed)
    var config = SimConfig(teams: teams, planes: .surprise, tanks: .always)
    config.frozenLakes = atmosphere.frozenLakes
    let sim = DogfightSim(seed: seed, aspect: 16.0 / 9.0, config: config)
    let land = Countryside(sim: sim, atmosphere: atmosphere, environment: [:])
    var t = Tally()
    t.roads = land.roads.count
    t.cars = land.traffic.cars.count
    t.mills = land.windmills.count
    t.sheep = land.pasture.sheep.count
    for road in land.roads { t.roadWet += road.points.filter { sim.terrain.isLake(at: $0) }.count }
    let start = Date()
    var settled = Set<Int>()
    let steps = Int(minutes * 60 / DogfightSim.stepSeconds)
    for step in 0..<steps {
        sim.advance()
        for event in sim.drainEvents() {
            switch event {
            case .splashed: t.splash += 1
            case .crashed(_, let p, _, let inWater, _, _):
                t.crashes += 1
                if !inWater && sim.terrain.isLake(at: p) { t.iceCrash += 1 }
            case .downed: t.kills += 1
            default: break
            }
            land.observe(event, sim: sim, live: true)
        }
        for p in sim.projectiles {
            guard case .landed = p.state, settled.insert(p.id).inserted else { continue }
            if sim.terrain.isLake(at: p.position) { t.iceShot += 1 } else { t.landShot += 1 }
        }
        if settled.count > 4000 { settled = Set(sim.projectiles.map(\.id)) }
        for tank in sim.tanks where tank.isActive {
            t.tankTime += DogfightSim.stepSeconds
            if sim.terrain.isLake(at: tank.position) { t.iceTank += DogfightSim.stepSeconds }
        }
        // The renderer advances the countryside once a frame; every fourth step is 30 fps.
        guard step % 4 == 0 else { continue }
        land.advance(to: sim.time, sim: sim)
        let flock = land.pasture.sheep
        for (i, s) in flock.enumerated() {
            if !s.position.x.isFinite || !s.position.y.isFinite { t.nonFinite += 1 }
            if sim.terrain.isLake(at: s.position) { t.sheepWet += 1 }
            for j in (i + 1)..<flock.count {
                t.sheepTight = min(t.sheepTight, simd_distance(s.position, flock[j].position) / Pasture.spacing)
            }
            mix(&t.hash, s.position.x); mix(&t.hash, s.position.y)
        }
        for i in land.traffic.cars.indices { mix(&t.hash, land.traffic.cars[i].along) }
        let bases = standing(sim)
        for base in bases { t.airfields.insert("\(sim.match.index)-\(base.side)") }
        t.sheepOnAirfield += flock.filter { s in bases.contains { $0.covers(s.position) } }.count
        t.carsOnAirfield += land.traffic.cars.indices.filter { i in
            let p = land.traffic.pose(of: i, at: sim.time).position
            return bases.contains { $0.covers(p) }
        }.count
        for flock in land.cranes.flocks { t.flocks.insert(flock.start) }
        for mark in land.marks.scorches { t.scorches.insert(mark.id) }
        for fire in land.marks.fires { t.trees.insert(fire.prop) }
    }
    t.seconds = Date().timeIntervalSince(start)
    return t
}

@main
struct AtmosProbe {
    static func main() {
        var minutes = 10.0
        var seeds: [UInt64] = [1, 2, 3, 42]
        var teams = TeamsChoice.surprise
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let flag = arguments.next() {
            switch flag {
            case "--minutes": minutes = arguments.next().flatMap(Double.init) ?? minutes
            case "--seeds": seeds = (arguments.next() ?? "").split(separator: ",").compactMap { UInt64($0) }
            case "--teams": teams = arguments.next().flatMap(TeamsChoice.init(rawValue:)) ?? teams
            default: print("unknown flag \(flag)"); exit(2)
            }
        }

        print("run                 kills crash iceCrash splash iceShot landShot iceTank%  sheep wet tight  roads wet cars mills flocks scorch trees fields onRwy nan   sec hash")
        var failures: [String] = []
        for seed in seeds {
            for season in Season.allCases {
                let a = soak(seed: seed, season: season, teams: teams, minutes: minutes)
                let b = soak(seed: seed, season: season, teams: teams, minutes: min(minutes, 2))
                let c = soak(seed: seed, season: season, teams: teams, minutes: min(minutes, 2))
                let label = "s\(seed) \(season.rawValue)"
                print(String(format: "%-19@ %5d %5d %8d %6d %7d %8d %7.2f%%  %5d %3d %5.2f  %5d %3d %4d %5d %6d %6d %5d %6d %2d/%-2d %3d %5.1f %016llx",
                             label as NSString, a.kills, a.crashes, a.iceCrash, a.splash, a.iceShot, a.landShot,
                             a.tankTime > 0 ? 100 * a.iceTank / a.tankTime : 0, a.sheep, a.sheepWet, a.sheepTight,
                             a.roads, a.roadWet, a.cars, a.mills, a.flocks.count, a.scorches.count, a.trees.count,
                             a.airfields.count, a.sheepOnAirfield, a.carsOnAirfield, a.nonFinite, a.seconds, a.hash))
                if b.hash != c.hash { failures.append("\(label): countryside not deterministic") }
                if a.sheepWet > 0 || a.roadWet > 0 || a.nonFinite > 0 { failures.append("\(label): sheep or road on a lake, or NaN") }
                if a.sheepOnAirfield > 0 || a.carsOnAirfield > 0 {
                    failures.append("\(label): \(a.sheepOnAirfield) sheep-steps and \(a.carsOnAirfield) car-steps on an airfield")
                }
                if a.sheepTight < 0.5 { failures.append("\(label): two sheep stacked (\(a.sheepTight))") }
                if season == .winter && a.splash > 0 { failures.append("\(label): \(a.splash) splashes on a frozen lake") }
            }
        }
        print(failures.isEmpty ? "all rules held" : "FAILED:\n  " + failures.joined(separator: "\n  "))
        exit(failures.isEmpty ? 0 : 1)
    }
}
