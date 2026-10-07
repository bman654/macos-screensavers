// Headless soak of the Origami Dogfight simulation.
//
// A degenerate fight — planes circling forever, sitting on the wall, leaving the screen, all
// dying at once, a tank wedged against a lake or driving into one — is caught here by numbers
// rather than by luck in a screenshot. The sim has no rendering imports, so it compiles on its
// own:
//
//   swiftc -O -parse-as-library tools/origami-sim-probe.swift Shared/SaverKit/Rand.swift \
//       Savers/OrigamiDogfight/Sources/Sim/*.swift -o /tmp/origami-probe
//   /tmp/origami-probe --minutes 20 --seeds 1,2,3 --tiers few,some,lots \
//       --modes ffa,teams,surprise --tanks off,always
//
// `--modes` takes the sheet's choices (ffa, teams, surprise) or a pinned mode (teams2, teams3);
// `--tiers` takes few, some, lots or surprise; `--tanks` off, sometimes or always.
//
// Every number is simulated time. "out" is plane-time spent fighting with the plane's centre
// outside the camera's view at its own altitude; "edge" is the same with any of its body
// outside. Entering, exiting and downed planes are excluded — they are meant to cross the edge.
// "stuck" is the longest a tank that was trying to drive went without moving; "wet" counts
// tank-steps with any of its footprint on water and must be zero, as must "nan". The footprint is
// the sim's own (`TankSpec.footprint`, the disc round hull and treads), tested face by face.
//
// Every run starts with the known regressions — fights that once broke a rule — whatever the
// flags ask for, so a change that brings one back fails here.

import Foundation
import simd

struct Report {
    var label = ""
    var minutes: Double = 0
    var planeKills = 0
    var tankKills = 0
    var planesByTanks = 0
    var shots = 0
    var hits = 0
    var pencils = 0
    var strafes = 0
    var matches = 0
    var splashes = 0
    var fightTime: Double = 0
    var outTime: Double = 0
    var edgeTime: Double = 0
    var longestNoShot: Double = 0
    var longestNoKill: Double = 0
    var longestCircle: Double = 0
    var longestWall: Double = 0
    /// The longest a tank trying to drive went without moving.
    var longestStuck: Double = 0
    var stuckEpisodes = 0
    var wetSteps = 0
    var tankTime: Double = 0
    /// Tank-time spent actually moving: a tank that is always stopped to shoot reads as a prop.
    var tankMoving: Double = 0
    /// Lowest a live plane came to the ground under it.
    var minClearance: Float = .greatestFiniteMagnitude
    var nonFinite = 0
    var maxPlanes = 0
    var maxTanks = 0
    var maxProjectiles = 0
    var maxWrecks = 0
    var hash: UInt64 = 0
    var wall: Double = 0
}

func fnv(_ hash: inout UInt64, _ value: UInt64) {
    for shift in stride(from: 0, to: 64, by: 8) {
        hash ^= (value >> UInt64(shift)) & 0xFF
        hash = hash &* 0x100_0000_01B3
    }
}

func fnv(_ hash: inout UInt64, _ v: SIMD2<Float>) {
    fnv(&hash, UInt64(v.x.bitPattern)); fnv(&hash, UInt64(v.y.bitPattern))
}

func hashEvent(_ hash: inout UInt64, _ event: SimEvent, step: Int) {
    fnv(&hash, UInt64(step))
    switch event {
    case .matchStarted(let index, let mode, let planes):
        fnv(&hash, 1); fnv(&hash, UInt64(index)); fnv(&hash, UInt64(planes))
        fnv(&hash, UInt64(MatchMode.allCases.firstIndex(of: mode)!))
    case .matchEnded(let index, let kills):
        fnv(&hash, 2); fnv(&hash, UInt64(index)); fnv(&hash, UInt64(kills))
    case .spawned(let plane):
        fnv(&hash, 3); fnv(&hash, UInt64(plane))
    case .fired(let plane, let weapon):
        fnv(&hash, 4); fnv(&hash, UInt64(plane)); fnv(&hash, UInt64(weapon.rawValue))
    case .hit(let victim, let by, let weapon, let position, let altitude, _, _):
        fnv(&hash, 5); fnv(&hash, UInt64(victim)); fnv(&hash, UInt64(by)); fnv(&hash, UInt64(weapon.rawValue))
        fnv(&hash, position); fnv(&hash, UInt64(altitude.bitPattern))
    case .downed(let victim, let by):
        fnv(&hash, 6); fnv(&hash, UInt64(victim)); fnv(&hash, UInt64(by))
    case .crashed(let wreck, let position, let ground, let inWater, _, _):
        fnv(&hash, 7); fnv(&hash, UInt64(wreck)); fnv(&hash, position)
        fnv(&hash, UInt64(ground.bitPattern)); fnv(&hash, inWater ? 1 : 0)
    case .exited(let plane):
        fnv(&hash, 8); fnv(&hash, UInt64(plane))
    case .splashed(let position, let kind, _):
        fnv(&hash, 9); fnv(&hash, position); fnv(&hash, UInt64(kind.rawValue))
    case .tankSpawned(let tank):
        fnv(&hash, 10); fnv(&hash, UInt64(tank))
    case .tankFired(let tank):
        fnv(&hash, 11); fnv(&hash, UInt64(tank))
    case .tankHit(let tank, let by, let position, _, _, _):
        fnv(&hash, 12); fnv(&hash, UInt64(tank)); fnv(&hash, UInt64(by)); fnv(&hash, position)
    case .tankDestroyed(let tank, let by, let wreck, let position, _, _, _):
        fnv(&hash, 13); fnv(&hash, UInt64(tank)); fnv(&hash, UInt64(by)); fnv(&hash, UInt64(wreck)); fnv(&hash, position)
    case .tankLeft(let tank):
        fnv(&hash, 14); fnv(&hash, UInt64(tank))
    }
}

struct RunSpec {
    var seed: UInt64
    var mode: String
    var tier: PlanesChoice
    var tanks: TanksChoice
    var aspect: Float

    var config: SimConfig {
        var c = SimConfig(teams: .surprise, planes: tier, tanks: tanks)
        switch mode {
        case "ffa": c.teams = .ffa
        case "teams": c.teams = .teams
        case "surprise", "mixed": c.teams = .surprise
        default: c.mode = MatchMode(rawValue: mode)
        }
        return c
    }

    var label: String { "s\(seed) \(tier.rawValue) \(mode) tanks=\(tanks.rawValue)" }
}

func soak(_ run: RunSpec, minutes: Double) -> Report {
    let sim = DogfightSim(seed: run.seed, aspect: run.aspect, config: run.config)
    var r = Report()
    r.label = run.label
    r.minutes = minutes
    r.hash = 0xCBF2_9CE4_8422_2325
    let steps = Int(minutes * 60 / DogfightSim.stepSeconds)
    let dt = DogfightSim.stepSeconds
    var lastShot: Double = 0, lastKill: Double = 0
    var circleTime: [Int: Double] = [:]
    var circleSign: [Int: Float] = [:]
    var wallRun: [Int: Double] = [:]
    var strafing = Set<Int>()
    var tankIDs = Set<Int>()
    var stuck: [Int: Double] = [:]
    let start = Date()

    for _ in 0..<steps {
        sim.advance()
        let now = sim.time
        for event in sim.drainEvents() {
            hashEvent(&r.hash, event, step: sim.steps)
            switch event {
            case .fired(_, let weapon):
                r.shots += weapon.spec(scale: 1).pellets
                r.longestNoShot = max(r.longestNoShot, now - lastShot); lastShot = now
            case .tankFired:
                r.pencils += 1
                r.longestNoShot = max(r.longestNoShot, now - lastShot); lastShot = now
            case .hit: r.hits += 1
            case .downed(_, let by):
                r.planeKills += 1
                if tankIDs.contains(by) { r.planesByTanks += 1 }
                r.longestNoKill = max(r.longestNoKill, now - lastKill); lastKill = now
            case .tankDestroyed:
                r.tankKills += 1
                r.longestNoKill = max(r.longestNoKill, now - lastKill); lastKill = now
            case .splashed: r.splashes += 1
            case .matchEnded: r.matches += 1
            case .tankSpawned(let id): tankIDs.insert(id)
            default: break
            }
        }
        r.maxPlanes = max(r.maxPlanes, sim.planes.count)
        r.maxTanks = max(r.maxTanks, sim.tanks.count)
        r.maxProjectiles = max(r.maxProjectiles, sim.projectiles.count)
        r.maxWrecks = max(r.maxWrecks, sim.wrecks.count)
        // Forget planes that have left, so twenty minutes of replacements does not pile up here.
        if circleTime.count > 4 * max(sim.planes.count, 1) {
            let live = Set(sim.planes.map(\.id))
            circleTime = circleTime.filter { live.contains($0.key) }
            circleSign = circleSign.filter { live.contains($0.key) }
            wallRun = wallRun.filter { live.contains($0.key) }
            strafing = strafing.filter { live.contains($0) }
            let liveTanks = Set(sim.tanks.map(\.id))
            stuck = stuck.filter { liveTanks.contains($0.key) }
        }
        if sim.steps % 120 == 0 {
            for tank in sim.tanks { fnv(&r.hash, tank.position) }
        }

        for p in sim.planes {
            let pose = p.pose
            if ![pose.position.x, pose.position.y, pose.altitude, pose.heading, pose.bank, pose.pitch, p.speed]
                .allSatisfy(\.isFinite) { r.nonFinite += 1 }
            if !p.state.isDowned {
                r.minClearance = min(r.minClearance, pose.altitude - sim.terrain.surfaceHeight(at: pose.position))
            }
            if p.pilot.strafe != nil {
                if !strafing.contains(p.id) { r.strafes += 1; strafing.insert(p.id) }
            } else {
                strafing.remove(p.id)
            }
            switch p.state {
            case .fighting:
                r.fightTime += dt
                let depth = sim.rig.visible(atAltitude: p.altitude).depth(p.position)
                if depth < 0 { r.outTime += dt }
                if depth < p.spec.size * 0.5 { r.edgeTime += dt }
                if p.pilot.wallUrgency > 1 {
                    wallRun[p.id, default: 0] += dt
                    r.longestWall = max(r.longestWall, wallRun[p.id]!)
                } else {
                    wallRun[p.id] = 0
                }
                let hard = abs(p.turnRate) > p.spec.turnRate * 0.6
                let sign: Float = p.turnRate >= 0 ? 1 : -1
                if hard && circleSign[p.id] == sign {
                    circleTime[p.id, default: 0] += dt
                    r.longestCircle = max(r.longestCircle, circleTime[p.id]!)
                } else {
                    circleTime[p.id] = 0
                    circleSign[p.id] = hard ? sign : 0
                }
            case .entering, .exiting, .downed:
                break
            }
        }
        for tank in sim.tanks {
            r.tankTime += dt
            if simd_distance(tank.position, tank.previousPosition) > 1e-6 { r.tankMoving += dt }
            if ![tank.position.x, tank.position.y, tank.heading, tank.turret, tank.altitude].allSatisfy(\.isFinite) {
                r.nonFinite += 1
            }
            if sim.terrain.isWater(underDisc: tank.position, radius: tank.spec.footprint) { r.wetSteps += 1 }
            // Standing still while trying to drive. Stopping to shoot or to look round is the
            // tank's choice, and resets the clock.
            switch tank.state {
            case .patrol, .entering, .leaving:
                if simd_distance(tank.position, tank.previousPosition) > 1e-6 {
                    stuck[tank.id] = 0
                } else {
                    stuck[tank.id, default: 0] += dt
                    let still = stuck[tank.id]!
                    r.longestStuck = max(r.longestStuck, still)
                    if still > 10, still - dt <= 10 { r.stuckEpisodes += 1 }
                }
            case .halted, .folding:
                stuck[tank.id] = 0
            }
        }
    }
    r.longestNoShot = max(r.longestNoShot, sim.time - lastShot)
    r.longestNoKill = max(r.longestNoKill, sim.time - lastKill)
    r.wall = Date().timeIntervalSince(start)
    return r
}

func checkTerrainCoverage() -> Bool {
    var ok = true
    for aspect: Float in [0.5, 0.75, 1, 1.333, 1.521, 1.6, 1.778, 2.37, 3.0, 3.56, 4.0] {
        let rig = ViewRig(aspect: aspect)
        let ground = rig.visible(atAltitude: 0)
        let (lo, hi) = ground.bounds
        let covered = lo.x > -Terrain.halfExtent && lo.y > -Terrain.halfExtent
            && hi.x < Terrain.halfExtent && hi.y < Terrain.halfExtent
        ok = ok && covered
        if !covered { print(String(format: "  aspect %.3f TERRAIN GAP", aspect)) }
    }
    return ok
}

func row(_ r: Report, minutes: Double) -> String {
    pad(r.label, 34) + String(
        format: " %6.2f %6.2f %5d %6.2f %5d %5.1f%% %5.2f%% %5.2f%% %6.1fs %5.1fs %5.1fs %5.1fs %5.1fs %5d %4.0f%% %3d %6.3f %5d %4d %7d %5d %5.1f %016llx",
        Double(r.planeKills) / minutes, Double(r.tankKills) / minutes, r.planesByTanks,
        Double(r.strafes) / minutes, r.matches,
        r.shots > 0 ? 100 * Double(r.hits) / Double(r.shots + r.pencils) : 0,
        100 * r.outTime / max(r.fightTime, 1e-9), 100 * r.edgeTime / max(r.fightTime, 1e-9),
        r.longestNoShot, r.longestNoKill, r.longestCircle, r.longestWall, r.longestStuck,
        r.stuckEpisodes, 100 * r.tankMoving / max(r.tankTime, 1e-9), r.wetSteps,
        r.minClearance == .greatestFiniteMagnitude ? -1 : r.minClearance,
        r.maxPlanes, r.maxTanks, r.maxProjectiles, r.maxWrecks, r.wall, r.hash)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

@main
struct Probe {
    static func main() {
        var minutes = 20.0
        var seeds: [UInt64] = [1, 2, 3]
        var modes = ["ffa", "teams", "surprise"]
        var tiers: [PlanesChoice] = [.few, .some, .lots]
        var tanks: [TanksChoice] = [.off, .always]
        var aspect: Float = 1.778
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            let value = arguments.isEmpty ? "" : arguments.removeFirst()
            switch flag {
            case "--minutes":
                guard let parsed = Double(value), parsed.isFinite, parsed > 0, parsed <= 60 * 24 * 30 else {
                    print("--minutes needs a positive number of minutes, at most 30 days"); exit(2)
                }
                minutes = parsed
            case "--seeds": seeds = value.split(separator: ",").compactMap { UInt64($0) }
            case "--modes": modes = value.split(separator: ",").map(String.init)
            case "--tiers": tiers = value.split(separator: ",").compactMap { PlanesChoice(rawValue: String($0)) }
            case "--tanks": tanks = value.split(separator: ",").compactMap { TanksChoice(rawValue: String($0)) }
            case "--aspect":
                guard let parsed = Float(value), parsed.isFinite, parsed > 0 else {
                    print("--aspect needs a positive width / height ratio"); exit(2)
                }
                aspect = parsed
            default: print("unknown flag \(flag)"); exit(2)
            }
        }

        let covered = checkTerrainCoverage()
        print("terrain coverage: \(covered ? "every aspect covered" : "GAP")")
        print(pad("run", 34) + " pk/min tk/min byTnk strf/m match   acc   out%  edge%  noShot noKill circle wallRn"
              + " stuck st>10 mov% wet  minClr  maxP maxT maxProj maxWr   sec hash")
        var all: [Report] = []
        // A light tank turned so a rear tread corner hung over a lake (step 13989, ~117 s in),
        // between the five points the old check sampled.
        let regressions = [(RunSpec(seed: 7, mode: "teams", tier: .few, tanks: .always, aspect: 16 / 9), 2.5)]
        for (run, length) in regressions {
            var r = soak(run, minutes: length)
            r.label = "regression " + r.label
            all.append(r)
            print(row(r, minutes: length))
        }
        for seed in seeds {
            for tier in tiers {
                for mode in modes {
                    for tank in tanks {
                        let r = soak(RunSpec(seed: seed, mode: mode, tier: tier, tanks: tank, aspect: aspect),
                                     minutes: minutes)
                        all.append(r)
                        print(row(r, minutes: minutes))
                    }
                }
            }
        }

        // Determinism: the same seed must name the same fight, event for event and tank for tank.
        let pin = RunSpec(seed: seeds.first ?? 1, mode: "surprise", tier: .surprise, tanks: .always, aspect: aspect)
        let first = soak(pin, minutes: min(minutes, 10))
        let second = soak(pin, minutes: min(minutes, 10))
        let nonFinite = all.reduce(0) { $0 + $1.nonFinite }
        let wet = all.reduce(0) { $0 + $1.wetSteps }
        let fightTime = all.reduce(0) { $0 + $1.fightTime }
        let outTime = all.reduce(0) { $0 + $1.outTime }
        print("\nnon-finite poses across every run: \(nonFinite)")
        print("tank-steps on water across every run: \(wet)")
        print(String(format: "planes' centre off-screen while fighting, all runs: %.3f%%", 100 * outTime / max(fightTime, 1e-9)))
        print(String(format: "determinism: %016llx vs %016llx  %@", first.hash, second.hash,
                     first.hash == second.hash ? "SAME" : "DIFFERENT"))
        if !covered || first.hash != second.hash || nonFinite > 0 || wet > 0 { exit(1) }
    }
}
