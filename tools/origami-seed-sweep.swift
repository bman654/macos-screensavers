// Every seed, or near enough: builds Origami Dogfight's whole world for a very large range of seeds
// in every season — the sim, with its landscape, props and roads, the countryside round it, and
// the airfields of both kinds of team match — and steps each a few simulated seconds, counting
// anything that traps or goes wrong.
//
// A seed is a session: the saver draws one from 100000...999999 at launch, and a seed whose
// landscape traps on construction is a black screen, every time it is drawn. The soaks
// (`origami-sim-probe.swift`, `origami-atmos-probe.swift`) run a handful of seeds for a long time;
// this runs a great many for a moment, which is where a collection that is empty for one seed in
// a hundred thousand shows up.
//
//   swiftc -O -parse-as-library tools/origami-seed-sweep.swift Shared/SaverKit/Rand.swift \
//       Savers/OrigamiDogfight/Sources/Sim/*.swift Savers/OrigamiDogfight/Sources/Countryside/*.swift \
//       -o /tmp/origami-seed-sweep
//   /tmp/origami-seed-sweep [--first 200000] [--sample 200000] [--seconds 3] [--jobs N]
//
// Sweeps seeds 0..<first, then `sample` seeds drawn at random from the saver's own range. Work is
// split into batches, each run in a child process (`--batch <seed,...>`), several at a time: a
// trap kills only its child, whose signal handler names the seed, and the batch carries on from
// the seed after it. Every trap is reported with its seed and the sweep fails.
//
// Seasons: a summer and an autumn of the same seed are the same world — the season reaches the
// fight only as `frozenLakes`, and the countryside's rules never read it — so every seed is swept
// in summer and winter, and every fiftieth in autumn too, whose world must hash the same as its
// summer's ("seasonDiff" must be zero), which keeps that claim checked rather than assumed.
//
// Besides traps, each seed in each season counts, after its few seconds: roads whose strip crosses
// a lake face, cars or sheep standing on a lake, tanks with any of their footprint on open water,
// and non-finite positions. All must be zero.

import Darwin
import Foundation
import simd

/// The seed a child is on, for its trap handler. A child is single-threaded.
nonisolated(unsafe) var currentSeed: UInt64 = 0

/// Writes "TRAP <seed> <signal>" to stderr and exits, using nothing a signal handler may not.
private let trapHandler: @convention(c) (Int32) -> Void = { signal in
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
        var length = 0
        func put(_ byte: UInt8) { buffer[length] = byte; length += 1 }
        func put(number: UInt64) {
            var divisor: UInt64 = 1
            while number / divisor >= 10 { divisor *= 10 }
            while divisor > 0 { put(UInt8(48 + (number / divisor) % 10)); divisor /= 10 }
        }
        for byte in "\nTRAP ".utf8 { put(byte) }
        put(number: currentSeed)
        put(32)
        put(number: UInt64(signal))
        put(10)
        _ = write(2, buffer.baseAddress, length)
    }
    _exit(70)
}

struct Counts {
    var seeds = 0
    var wetRoads = 0
    var wetCars = 0
    var wetSheep = 0
    var wetTanks = 0
    var nonFinite = 0
    var airfields = 0
    var seasonDiffs = 0
    var findings: [String] = []

    mutating func add(_ other: Counts) {
        seeds += other.seeds
        wetRoads += other.wetRoads
        wetCars += other.wetCars
        wetSheep += other.wetSheep
        wetTanks += other.wetTanks
        nonFinite += other.nonFinite
        airfields += other.airfields
        seasonDiffs += other.seasonDiffs
        findings += other.findings
    }

    var line: String {
        "seeds=\(seeds) wetRoads=\(wetRoads) wetCars=\(wetCars) wetSheep=\(wetSheep) wetTanks=\(wetTanks) "
            + "nonFinite=\(nonFinite) airfields=\(airfields) seasonDiff=\(seasonDiffs)"
    }

    init() {}

    init?(line: String) {
        var fields: [String: Int] = [:]
        for pair in line.split(separator: " ") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let value = Int(kv[1]) { fields[String(kv[0])] = value }
        }
        guard let seeds = fields["seeds"] else { return nil }
        self.seeds = seeds
        wetRoads = fields["wetRoads"] ?? 0
        wetCars = fields["wetCars"] ?? 0
        wetSheep = fields["wetSheep"] ?? 0
        wetTanks = fields["wetTanks"] ?? 0
        nonFinite = fields["nonFinite"] ?? 0
        airfields = fields["airfields"] ?? 0
        seasonDiffs = fields["seasonDiff"] ?? 0
    }
}

func mix(_ hash: inout UInt64, _ value: Float) {
    hash ^= UInt64(value.bitPattern)
    hash = hash &* 0x100_0000_01B3
}

/// One seed in its seasons: the world built, both team matches' airfields planned, and a few
/// seconds of fight and countryside stepped together, the way the renderer steps them.
func sweep(seed: UInt64, seconds: Double, counts: inout Counts) {
    currentSeed = seed
    let seasons: [Season] = seed % 50 == 0 ? [.summer, .winter, .autumn] : [.summer, .winter]
    var hashes: [Season: UInt64] = [:]
    for season in seasons {
        let atmosphere = Atmosphere(season: SeasonChoice(rawValue: season.rawValue) ?? .summer, dayTime: .midday,
                                    seed: seed)
        var config = SimConfig(teams: .teams, planes: .surprise, tanks: .always)
        config.frozenLakes = atmosphere.frozenLakes
        let sim = DogfightSim(seed: seed, aspect: 16.0 / 9.0, config: config)
        let land = Countryside(sim: sim, atmosphere: atmosphere, environment: [:])
        land.catchUp(with: sim)
        counts.airfields += sim.match.bases.compactMap { $0 }.count
        // The other kind of team match, and a lots-sized one, planned over the same ground.
        for (mode, planes) in [(MatchMode.teams2, 12), (.teams3, 9)] {
            var rand = Rand(seed: seed ^ 0x5EE9)
            var pinned = config
            pinned.mode = mode
            pinned.planeCount = planes
            let match = Match.draw(index: 1, now: 0, config: pinned, rand: &rand)
            counts.airfields += sim.plannedBases(for: match, wall: sim.wall).compactMap { $0 }.count
        }
        for road in sim.roads where Roads.crossesLake(road.points, terrain: sim.terrain) {
            counts.wetRoads += 1
            counts.findings.append("WETROAD \(seed) \(season.rawValue)")
        }
        _ = land.advance(sim, steps: Int((seconds * 120).rounded()))

        for i in land.traffic.cars.indices {
            let p = land.traffic.pose(of: i, at: sim.time).position
            if !p.x.isFinite || !p.y.isFinite { counts.nonFinite += 1 }
            if sim.terrain.isLake(at: p) {
                counts.wetCars += 1
                counts.findings.append("WETCAR \(seed) \(season.rawValue)")
            }
        }
        for sheep in land.pasture.sheep {
            if !sheep.position.x.isFinite || !sheep.position.y.isFinite { counts.nonFinite += 1 }
            if sim.terrain.isLake(at: sheep.position) {
                counts.wetSheep += 1
                counts.findings.append("WETSHEEP \(seed) \(season.rawValue)")
            }
        }
        for tank in sim.tanks {
            if ![tank.position.x, tank.position.y, tank.heading, tank.altitude].allSatisfy(\.isFinite) {
                counts.nonFinite += 1
            } else if sim.terrain.isWater(underDisc: tank.position, radius: tank.spec.footprint) {
                counts.wetTanks += 1
                counts.findings.append("WETTANK \(seed) \(season.rawValue)")
            }
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for plane in sim.planes {
            let pose = plane.pose
            if ![pose.position.x, pose.position.y, pose.altitude, pose.heading, pose.bank, pose.pitch]
                .allSatisfy(\.isFinite) {
                counts.nonFinite += 1
                counts.findings.append("NAN \(seed) \(season.rawValue)")
            }
            mix(&hash, pose.position.x); mix(&hash, pose.position.y); mix(&hash, pose.altitude)
        }
        for tank in sim.tanks { mix(&hash, tank.position.x); mix(&hash, tank.position.y) }
        for sheep in land.pasture.sheep { mix(&hash, sheep.position.x); mix(&hash, sheep.position.y) }
        for car in land.traffic.cars { mix(&hash, car.along) }
        for road in sim.roads { for p in road.points { mix(&hash, p.x); mix(&hash, p.y) } }
        for base in sim.match.bases.compactMap({ $0 }) { mix(&hash, base.hangar.x); mix(&hash, base.heading) }
        hashes[season] = hash
    }
    if let autumn = hashes[.autumn], autumn != hashes[.summer] {
        counts.seasonDiffs += 1
        counts.findings.append("SEASONDIFF \(seed)")
    }
    counts.seeds += 1
}

/// A child: sweeps its seeds, printing each finding as it is found and its running counts after
/// every seed, so a trap — which ends it in the handler, naming the seed — loses nothing swept
/// before it.
func runBatch(seeds: [UInt64], seconds: Double) -> Never {
    for sig in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGABRT] { signal(sig, trapHandler) }
    var counts = Counts()
    for seed in seeds {
        sweep(seed: seed, seconds: seconds, counts: &counts)
        for finding in counts.findings { print(finding) }
        counts.findings.removeAll()
        print("SO FAR " + counts.line)
        fflush(stdout)
    }
    exit(0)
}

/// What a child reported: its counts, its findings, and the seed it trapped on, if it did.
struct BatchResult {
    var counts = Counts()
    var trapped: (seed: UInt64, signal: Int32)?
    var lastWords = ""
}

func launch(seeds: [UInt64], seconds: Double) -> BatchResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--seconds", String(seconds), "--batch", seeds.map(String.init).joined(separator: ",")]
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    var result = BatchResult()
    do {
        try process.run()
    } catch {
        result.lastWords = "could not launch: \(error)"
        return result
    }
    // Read both to the end before waiting, so a chatty child cannot fill a pipe and stall.
    let group = DispatchGroup()
    var outData = Data(), errData = Data()
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.wait()
    process.waitUntilExit()
    let stdout = String(decoding: outData, as: UTF8.self), stderr = String(decoding: errData, as: UTF8.self)
    var findings: [String] = []
    for line in stdout.split(separator: "\n") {
        if line.hasPrefix("SO FAR "), let counts = Counts(line: String(line.dropFirst(7))) {
            result.counts = counts
        } else if !line.isEmpty {
            findings.append(String(line))
        }
    }
    result.counts.findings = findings
    if let trap = stderr.split(separator: "\n").last(where: { $0.hasPrefix("TRAP ") }) {
        let parts = trap.split(separator: " ")
        if parts.count >= 3, let seed = UInt64(parts[1]), let sig = Int32(parts[2]) { result.trapped = (seed, sig) }
    }
    if result.trapped == nil, process.terminationStatus != 0 || process.terminationReason != .exit {
        // Died without naming a seed: its first seed stands in, and the batch is reported whole.
        result.trapped = (seeds.first ?? 0, process.terminationStatus)
    }
    result.lastWords = stderr.split(separator: "\n").filter { $0.contains("Fatal error") }.last.map(String.init) ?? ""
    return result
}

/// Runs a batch to its end however many of its seeds trap: each trap is recorded, and the batch
/// is relaunched from the seed after it.
func runToEnd(seeds: [UInt64], seconds: Double) -> (counts: Counts, traps: [String]) {
    var remaining = seeds[...]
    var counts = Counts()
    var traps: [String] = []
    while !remaining.isEmpty {
        let result = launch(seeds: Array(remaining), seconds: seconds)
        counts.add(result.counts)
        guard let trapped = result.trapped else { break }
        traps.append("TRAP seed=\(trapped.seed) signal=\(trapped.signal) \(result.lastWords)")
        guard let at = remaining.firstIndex(of: trapped.seed) else { break }
        remaining = remaining[(at + 1)...]
    }
    return (counts, traps)
}

@main
struct SeedSweep {
    static func main() {
        var first = 200_000
        var sample = 200_000
        var seconds = 3.0
        var jobs = ProcessInfo.processInfo.activeProcessorCount
        var batch: [UInt64]?
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            let value = arguments.isEmpty ? "" : arguments.removeFirst()
            switch flag {
            case "--first": first = Int(value) ?? first
            case "--sample": sample = Int(value) ?? sample
            case "--seconds": seconds = Double(value).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? seconds
            case "--jobs": jobs = max(Int(value) ?? jobs, 1)
            case "--batch": batch = value.split(separator: ",").compactMap { UInt64($0) }
            default: print("unknown flag \(flag)"); exit(2)
            }
        }
        if let batch { runBatch(seeds: batch, seconds: seconds) }

        // The saver's own range (`LaunchOptions.fromEnvironment`), sampled by a fixed stream so a
        // rerun sweeps the same seeds.
        var draw = Rand(seed: 0x5EED_5EE9)
        let sampled = (0..<sample).map { _ in UInt64(100_000 + draw.index(count: 900_000)) }
        let seeds = (0..<UInt64(first)) + sampled
        let batchSize = 200
        let batches = stride(from: 0, to: seeds.count, by: batchSize).map { Array(seeds[$0..<min($0 + batchSize, seeds.count)]) }
        print("sweeping \(first) seeds from 0 and \(sample) sampled from 100000...999999, in summer and winter "
              + "(autumn on every 50th, checked identical to summer), "
              + "\(seconds) s each, \(batches.count) batches on \(jobs) processes")

        let start = Date()
        let lock = NSLock()
        var total = Counts()
        var traps: [String] = []
        var done = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = jobs
        for seeds in batches {
            queue.addOperation {
                let (counts, found) = runToEnd(seeds: seeds, seconds: seconds)
                lock.lock()
                total.add(counts)
                traps += found
                done += 1
                if done % 50 == 0 || !found.isEmpty {
                    let elapsed = Date().timeIntervalSince(start)
                    print(String(format: "  %d/%d batches, %d seeds, %d traps, %.0f s", done, batches.count, total.seeds,
                                 traps.count, elapsed))
                    for trap in found { print("  " + trap) }
                    fflush(stdout)
                }
                lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        let elapsed = Date().timeIntervalSince(start)
        for finding in total.findings.prefix(40) { print("  " + finding) }
        print(String(format: "swept %d seeds in %.0f s (%.1f ms a seed, all its seasons, on one process)", total.seeds,
                     elapsed, 1000 * elapsed * Double(jobs) / Double(max(total.seeds, 1))))
        print(total.line + " traps=\(traps.count)")
        for trap in traps { print(trap) }
        let clean = traps.isEmpty && total.wetRoads == 0 && total.wetCars == 0 && total.wetSheep == 0
            && total.wetTanks == 0 && total.nonFinite == 0 && total.seasonDiffs == 0 && total.seeds == seeds.count
        print(clean ? "every seed held" : "FAILED")
        exit(clean ? 0 : 1)
    }
}
