// Headless soak of the Origami Dogfight simulation.
//
// A degenerate fight — planes circling forever, sitting on the wall, leaving the screen, all
// dying at once — is caught here by numbers rather than by luck in a screenshot. The sim has no
// rendering imports, so it compiles on its own:
//
//   swiftc -O -parse-as-library tools/origami-sim-probe.swift Shared/SaverKit/Rand.swift \
//       Savers/OrigamiDogfight/Sources/Sim/*.swift -o /tmp/origami-probe
//   /tmp/origami-probe --minutes 30 --seeds 1,2,3 --modes ffa,teams2,teams3,mixed
//
// Every number is simulated time. "out" is plane-time spent fighting with the plane's centre
// outside the camera's view at its own altitude; "edge" is the same with any of its body
// outside. Entering, exiting and downed planes are excluded — they are meant to cross the edge.

import Foundation
import simd

struct Report {
    var label = ""
    var minutes: Double = 0
    var kills = 0
    var shots = 0
    var hits = 0
    var matches = 0
    var splashes = 0
    var fightTime: Double = 0
    var outTime: Double = 0
    var edgeTime: Double = 0
    var stuckTime: Double = 0
    var longestNoShot: Double = 0
    var longestNoKill: Double = 0
    var longestCircle: Double = 0
    /// The longest one plane spent continuously with the wall in command — hugging, not turning.
    var longestWall: Double = 0
    /// Plane-steps with a NaN or infinite pose. Must be zero: a NaN heading loses a plane silently.
    var nonFinite = 0
    var maxKillsIn3s = 0
    var maxProjectiles = 0
    var fullStrengthFraction: Double = 0
    var meanAirborne: Double = 0
    /// Mean distance of fighting planes from their own centroid, metres: how spread out the fight is.
    var spread: Double = 0
    var spreadSamples: Double = 0
    var minAirborneWhileFighting = Int.max
    var hash: UInt64 = 0
    var wall: Double = 0
}

func fnv(_ hash: inout UInt64, _ value: UInt64) {
    for shift in stride(from: 0, to: 64, by: 8) {
        hash ^= (value >> UInt64(shift)) & 0xFF
        hash = hash &* 0x100_0000_01B3
    }
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
    case .hit(let victim, let by, let weapon, let position, let altitude, _):
        fnv(&hash, 5); fnv(&hash, UInt64(victim)); fnv(&hash, UInt64(by)); fnv(&hash, UInt64(weapon.rawValue))
        fnv(&hash, UInt64(position.x.bitPattern)); fnv(&hash, UInt64(position.y.bitPattern))
        fnv(&hash, UInt64(altitude.bitPattern))
    case .downed(let victim, let by):
        fnv(&hash, 6); fnv(&hash, UInt64(victim)); fnv(&hash, UInt64(by))
    case .crashed(let wreck, let position, let ground, let inWater, _):
        fnv(&hash, 7); fnv(&hash, UInt64(wreck)); fnv(&hash, UInt64(position.x.bitPattern))
        fnv(&hash, UInt64(position.y.bitPattern)); fnv(&hash, UInt64(ground.bitPattern)); fnv(&hash, inWater ? 1 : 0)
    case .exited(let plane):
        fnv(&hash, 8); fnv(&hash, UInt64(plane))
    }
}

func soak(seed: UInt64, mode: MatchMode?, planes: Int?, minutes: Double, aspect: Float) -> Report {
    let sim = DogfightSim(seed: seed, aspect: aspect, config: SimConfig(mode: mode, planeCount: planes))
    var r = Report()
    r.label = "seed \(seed) \(mode?.rawValue ?? "mixed")\(planes.map { " n=\($0)" } ?? "")"
    r.minutes = minutes
    r.hash = 0xCBF2_9CE4_8422_2325
    let steps = Int(minutes * 60 / DogfightSim.stepSeconds)
    let dt = DogfightSim.stepSeconds
    var lastShot: Double = 0, lastKill: Double = 0
    var killTimes: [Double] = []
    var circleTime: [Int: Double] = [:]
    var circleSign: [Int: Float] = [:]
    var wallRun: [Int: Double] = [:]
    var fullStrength: Double = 0, fightingPhase: Double = 0, airborneSum: Double = 0
    let start = Date()

    for _ in 0..<steps {
        sim.advance()
        let now = sim.time
        for event in sim.drainEvents() {
            hashEvent(&r.hash, event, step: sim.steps)
            switch event {
            case .fired(_, let weapon): r.shots += weapon.spec.pellets; r.longestNoShot = max(r.longestNoShot, now - lastShot); lastShot = now
            case .hit: r.hits += 1
            case .downed:
                r.kills += 1
                r.longestNoKill = max(r.longestNoKill, now - lastKill); lastKill = now
                killTimes.append(now)
                killTimes.removeAll { now - $0 > 3 }
                r.maxKillsIn3s = max(r.maxKillsIn3s, killTimes.count)
            case .crashed(_, _, _, let inWater, _): if inWater { r.splashes += 1 }
            case .matchEnded: r.matches += 1
            default: break
            }
        }
        r.maxProjectiles = max(r.maxProjectiles, sim.projectiles.count)
        // Forget planes that have left, so half an hour of replacements does not pile up here.
        if circleTime.count > 4 * max(sim.planes.count, 1) {
            let live = Set(sim.planes.map(\.id))
            circleTime = circleTime.filter { live.contains($0.key) }
            circleSign = circleSign.filter { live.contains($0.key) }
            wallRun = wallRun.filter { live.contains($0.key) }
        }

        var airborne = 0
        let fighters = sim.planes.filter { if case .fighting = $0.state { return true }; return false }
        if fighters.count >= 3 {
            let centroid = fighters.reduce(SIMD2<Float>(0, 0)) { $0 + $1.position } / Float(fighters.count)
            r.spread += Double(fighters.reduce(Float(0)) { $0 + simd_distance($1.position, centroid) } / Float(fighters.count))
            r.spreadSamples += 1
        }
        for p in sim.planes {
            let pose = p.pose
            if ![pose.position.x, pose.position.y, pose.altitude, pose.heading, pose.bank, pose.pitch, p.speed]
                .allSatisfy(\.isFinite) { r.nonFinite += 1 }
            switch p.state {
            case .fighting:
                airborne += 1
                r.fightTime += dt
                let view = sim.rig.visible(atAltitude: p.altitude)
                let depth = view.depth(p.position)
                if depth < 0 { r.outTime += dt }
                if depth < p.spec.size * 0.5 { r.edgeTime += dt }
                if p.pilot.wallUrgency > 1 {
                    r.stuckTime += dt
                    wallRun[p.id, default: 0] += dt
                    r.longestWall = max(r.longestWall, wallRun[p.id]!)
                } else {
                    wallRun[p.id] = 0
                }
                // A circle: a hard turn held the same way without a break.
                let hard = abs(p.turnRate) > p.spec.turnRate * 0.6
                let sign: Float = p.turnRate >= 0 ? 1 : -1
                if hard && circleSign[p.id] == sign {
                    circleTime[p.id, default: 0] += dt
                    r.longestCircle = max(r.longestCircle, circleTime[p.id]!)
                } else {
                    circleTime[p.id] = 0
                    circleSign[p.id] = hard ? sign : 0
                }
            case .entering:
                airborne += 1
            case .exiting, .downed:
                break
            }
        }
        if case .fighting = sim.match.phase, now - sim.match.startedAt > 6 {
            fightingPhase += dt
            if airborne == sim.match.slots.count { fullStrength += dt }
            airborneSum += dt * Double(airborne) / Double(sim.match.slots.count)
            r.minAirborneWhileFighting = min(r.minAirborneWhileFighting, airborne)
        }
    }
    r.longestNoShot = max(r.longestNoShot, sim.time - lastShot)
    r.longestNoKill = max(r.longestNoKill, sim.time - lastKill)
    r.fullStrengthFraction = fightingPhase > 0 ? fullStrength / fightingPhase : 0
    r.meanAirborne = fightingPhase > 0 ? airborneSum / fightingPhase : 0
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
        let band = rig.visible(atAltitude: ViewRig.bandMid).bounds
        print(String(format: "  aspect %.3f  ground x[%.2f, %.2f] y[%.2f, %.2f]  band %.2f x %.2f m  %@",
                     aspect, lo.x, hi.x, lo.y, hi.y, band.max.x - band.min.x, band.max.y - band.min.y,
                     covered ? "covered" : "TERRAIN GAP"))
        ok = ok && covered
    }
    return ok
}

@main
struct Probe {
    static func main() {
        var minutes = 30.0
        var seeds: [UInt64] = [1, 2, 3]
        var modes: [MatchMode?] = [.ffa, .teams2, .teams3, nil]
        var planes: Int?
        var aspect: Float = 1.778
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            let value = arguments.isEmpty ? "" : arguments.removeFirst()
            switch flag {
            case "--minutes": minutes = Double(value) ?? minutes
            case "--seeds": seeds = value.split(separator: ",").compactMap { UInt64($0) }
            case "--modes": modes = value.split(separator: ",").map { MatchMode(rawValue: String($0)) }
            case "--planes": planes = Int(value)
            case "--aspect": aspect = Float(value) ?? aspect
            default: print("unknown flag \(flag)"); exit(2)
            }
        }

        print("terrain coverage:")
        let covered = checkTerrainCoverage()

        print(String(format: "\n%-22@ %6@ %5@ %7@ %5@ %6@ %6@ %6@ %7@ %6@ %6@ %6@ %5@ %5@ %5@ %5@ %5@ %5@ %4@ %5@",
                     "run", "k/min", "match", "acc", "splsh", "out%", "edge%", "wall%", "wallRun", "noShot", "noKill",
                     "circle", "k/3s", "proj", "full%", "air%", "minAir", "sprd", "sec", "hash"))
        var all: [Report] = []
        for seed in seeds {
            for mode in modes {
                let r = soak(seed: seed, mode: mode, planes: planes, minutes: minutes, aspect: aspect)
                all.append(r)
                print(String(format: "%-22@ %6.2f %5d %6.1f%% %5d %5.2f%% %5.2f%% %5.2f%% %6.1fs %5.1fs %5.1fs %5.1fs %5d %5d %5.1f%% %5.1f%% %5d %5.2f %4.1f %016llx",
                             r.label, Double(r.kills) / minutes, r.matches,
                             r.shots > 0 ? 100 * Double(r.hits) / Double(r.shots) : 0, r.splashes,
                             100 * r.outTime / max(r.fightTime, 1e-9), 100 * r.edgeTime / max(r.fightTime, 1e-9),
                             100 * r.stuckTime / max(r.fightTime, 1e-9), r.longestWall, r.longestNoShot, r.longestNoKill,
                             r.longestCircle, r.maxKillsIn3s, r.maxProjectiles, 100 * r.fullStrengthFraction, 100 * r.meanAirborne,
                             r.minAirborneWhileFighting == Int.max ? -1 : r.minAirborneWhileFighting,
                             r.spread / max(r.spreadSamples, 1), r.wall, r.hash))
            }
        }

        // Determinism: the same seed must name the same fight, event for event.
        let first = soak(seed: seeds.first ?? 1, mode: nil, planes: planes, minutes: min(minutes, 10), aspect: aspect)
        let second = soak(seed: seeds.first ?? 1, mode: nil, planes: planes, minutes: min(minutes, 10), aspect: aspect)
        let nonFinite = all.reduce(0) { $0 + $1.nonFinite }
        print("\nnon-finite plane poses across every run: \(nonFinite)")
        print(String(format: "determinism: %016llx vs %016llx  %@", first.hash, second.hash,
                     first.hash == second.hash ? "SAME" : "DIFFERENT"))
        if !covered || first.hash != second.hash || nonFinite > 0 { exit(1) }
    }
}
