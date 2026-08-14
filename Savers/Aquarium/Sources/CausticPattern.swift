// The caustic tile itself: a seamlessly tiling image of the net a rippled surface focuses onto
// whatever is under it. `Caustics.swift` is what hangs it on a light; this file only draws it.
//
// **It is a sum of plane waves with integer wave vectors, and that is the whole tiling story.**
// Every term is `sin(2π(kx·x + ky·y) + φ)` with kx and ky whole numbers, so the function is
// unchanged by x → x+1 and y → y+1 *by construction*. A tile that has to be checked for seams
// is a tile that will grow one when a parameter moves; this one cannot, and the blur that
// softens it wraps for the same reason. A seam here would draw a hard grid across the whole
// aquarium floor, which is the most visible failure available in this file.
//
// **The bright filaments come from the refraction Jacobian, not from a noise function.** Light
// crossing a wavy surface is bent by the surface's slope, so a patch of surface maps to a patch
// of floor of a different size, and the brightness is the reciprocal of how much that patch
// stretched. Where neighbouring rays cross, the patch collapses to nothing and the brightness
// diverges — that fold is what a caustic filament *is*. For small angles the map's Jacobian
// determinant is `1 + (hxx + hyy) + (hxx·hyy − hxy²)` and the intensity is one over its
// magnitude. Because every second derivative of `A·sin(P)` carries the same `sin(P)`, the whole
// inner loop reduces to table lookups and there is no trigonometry per pixel at all.
//
// A cell-noise pattern gets to something that superficially resembles this much more cheaply,
// and it reads as a net rather than as light: it has no cusps, because nothing in it is
// diverging.

import Foundation

enum CausticPattern {
    /// Side of the tile, in texels.
    ///
    /// 512 rather than 256 because the filaments are the picture. At 256 they come out about a
    /// texel wide and the cusps where two of them meet merge into a blob, which is the one part
    /// of a caustic the eye actually recognises.
    static let resolution = 512

    /// How many samples per texel per axis the intensity is evaluated at before being averaged
    /// down. **Not optional, and not replaceable by blurring afterwards.** The fold lines are
    /// true singularities of the Jacobian, so a single sample per texel either lands on one or
    /// misses it, and the filaments come out visibly dashed — a bead necklace rather than a
    /// line. Blurring afterwards blurs the beads.
    private static let supersample = 3

    /// How many waves make the surface. Few enough to stay cheap, many enough that the
    /// interference never resolves into anything the eye can read as a repeat.
    private static let waveCount = 20

    /// The band of spatial frequencies, in cycles per tile. The lower bound sets the largest
    /// feature and the upper bound is where the supersampling stops keeping up.
    private static let waveNumbers = (min: 3, max: 10)

    /// How much faster the short waves die away than the long ones. Real wind chop is dominated
    /// by its longest components; a flat spectrum reads as static.
    private static let amplitudeFalloff: Double = 1.6

    /// How hard the surface folds — the single knob that decides what kind of caustic this is.
    /// Around 1.1 gives the fat, well-separated bands of a swimming-pool floor; past 2.0 it
    /// shatters into a dense boil. 1.25 is a tank's or a reef's: distinct filaments, but a
    /// network rather than a few stripes.
    private static let foldStrength: Double = 1.25

    /// Where the diverging intensity is truncated, and the curve applied after. Without a
    /// ceiling the fold lines are infinite; without the gamma they are all equally white and the
    /// pattern loses its falloff.
    private static let ceiling: Double = 48.0
    private static let contrast: Double = 1.3

    /// A texel of softening, and a wide dim halo at a third strength. The halo is what keeps the
    /// filaments from looking drawn on: real caustics sit in a general brightening of the region
    /// they are focusing light out of.
    private static let softenRadius: Double = 0.7
    private static let bloomRadius: Double = 6.0
    private static let bloomAmount: Double = 0.35

    /// What the finished tile averages to.
    ///
    /// This is the number the lamp is compensated by, so it is a real decision and not a
    /// normalisation detail: it sets how far the dark gaps fall below the lit filaments once the
    /// key has been scaled back up by 1/mean. Low means a few bright lines on a dark floor, high
    /// means a gentle mottle. 0.22 is a pool floor in sun; the looks pull it back from there with
    /// their own `strength`.
    private static let mean: Float = 0.22

    /// The tile is drawn from a fixed seed rather than from the launch stream, and it is the one
    /// thing in this tank that is deliberately the same every launch.
    ///
    /// Two reasons. It costs about 200 ms to draw, and the settings sheet rebuilds a whole tank
    /// on every click — so a per-launch pattern would be paid again on each of those, on the
    /// main thread, for a difference no one can see. And a caustic net has no identity: unlike
    /// the gravel or the roster of fish, one pseudo-random interference pattern is not
    /// distinguishable from another, so drawing it per launch would spend the budget on variety
    /// that does not exist.
    private static let seed: UInt64 = 0x0CEA_11C5_CAF7_1CED

    /// The finished tile and the mean it was normalised to.
    typealias Tile = (values: [Float], mean: Float)

    /// The tile at a look's own contrast.
    ///
    /// `contrast` scales the pattern about its mean, which is exactly why it is safe: the mean
    /// is what the lamp's intensity is compensated by, and scaling about it leaves it untouched.
    /// So a look can dial its caustics from a hard net to nothing at all without moving how much
    /// light reaches its floor, and without invalidating the substrate measurement that light
    /// was balanced against. Values only ever move *toward* the mean, so nothing can clip.
    static func tile(contrast: CGFloat) -> Tile {
        let strength = Float(max(0, min(1, contrast)))
        guard strength < 1 else { return (base, mean) }
        return (base.map { mean + ($0 - mean) * strength }, mean)
    }

    /// Drawn once per process. `static let` is lazy and its initialisation is thread-safe, so
    /// the first tank built pays for it and every later one — including every click in the
    /// settings sheet — gets it free.
    private static let base: [Float] = draw()

    // MARK: Drawing

    /// One wave of the surface, with its curvature coefficients already carrying the depth
    /// factor so the inner loop has nothing left to scale.
    private struct Wave {
        let xx: Double
        let yy: Double
        let xy: Double
        /// Radians per second, quantised so the loop closes exactly.
        let omega: Double
        let phase: Double
        let kx: Int
        let ky: Int
    }

    private static func waves() -> [Wave] {
        var rand = Rand(seed: seed)
        var raw: [Wave] = []
        var taken: [(Int, Int)] = []
        let lowest = Double(waveNumbers.min)

        var attempts = 0
        while raw.count < waveCount && attempts < 10_000 {
            attempts += 1
            let limit = Float(waveNumbers.max) + 0.5
            let kx = Int(rand.inRange(-limit, limit).rounded())
            let ky = Int(rand.inRange(-limit, limit).rounded())
            let k = (Double(kx * kx + ky * ky)).squareRoot()
            guard k >= lowest - 0.001, k <= Double(waveNumbers.max) + 0.001 else { continue }
            // Reject a repeat, and reject the exact opposite vector: k and −k on one line make
            // a standing wave, and enough standing waves read as plaid rather than as water.
            guard !taken.contains(where: { $0 == (kx, ky) || $0 == (-kx, -ky) }) else { continue }
            taken.append((kx, ky))

            let amplitude = pow(k / lowest, -amplitudeFalloff)
            // Deep-water dispersion — longer waves travel slower — rounded to a whole number of
            // cycles per loop so the animation closes on itself exactly.
            let cycles = max(1, ((k / lowest).squareRoot() * 2).rounded())
            let direction: Double = rand.sign() < 0 ? -1 : 1
            let tx = 2 * Double.pi * Double(kx)
            let ty = 2 * Double.pi * Double(ky)
            raw.append(Wave(xx: -amplitude * tx * tx,
                            yy: -amplitude * ty * ty,
                            xy: -amplitude * tx * ty,
                            omega: direction * cycles * 2 * Double.pi / loopPeriod,
                            phase: Double(rand.inRange(0, 2 * Float.pi)),
                            kx: kx, ky: ky))
        }

        // One depth factor over the whole set, chosen so the RMS of the surface's Laplacian is
        // `foldStrength`. Setting the fold from the finished spectrum rather than per wave is
        // what makes that knob mean the same thing however the spectrum is retuned.
        let sumSquares = raw.reduce(0.0) { total, wave in
            let trace = wave.xx + wave.yy
            return total + trace * trace
        }
        let rms = (sumSquares / 2).squareRoot()
        let depth = rms > 0 ? foldStrength / rms : 0
        return raw.map {
            Wave(xx: $0.xx * depth, yy: $0.yy * depth, xy: $0.xy * depth,
                 omega: $0.omega, phase: $0.phase, kx: $0.kx, ky: $0.ky)
        }
    }

    /// Seconds for the pattern to return to exactly where it started. Unused while the net only
    /// drifts, and kept because the wave speeds are quantised against it — the tile is already
    /// a closed loop, so a future pass that pre-bakes frames of the *boil* gets a seamless cycle
    /// for free rather than having to re-derive the speeds.
    private static let loopPeriod: Double = 12

    private static func draw(time: Double = 0) -> [Float] {
        let waves = waves()
        var buffer = intensity(waves: waves, time: time)
        blurWrapping(&buffer, sigma: softenRadius)
        var halo = buffer
        blurWrapping(&halo, sigma: bloomRadius)
        for index in 0..<buffer.count { buffer[index] += Float(bloomAmount) * halo[index] }
        return normalised(buffer, to: mean)
    }

    /// The refraction Jacobian, supersampled and averaged down.
    private static func intensity(waves: [Wave], time: Double) -> [Float] {
        let n = resolution
        let s = supersample
        let fine = n * s
        let count = waves.count

        // Per-wave, per-column tables of sin and cos. The phase's time term is folded in here,
        // which is what leaves the inner loop free of trigonometry entirely.
        var sinX = [Double](repeating: 0, count: count * fine)
        var cosX = [Double](repeating: 0, count: count * fine)
        var sinY = [Double](repeating: 0, count: count * fine)
        var cosY = [Double](repeating: 0, count: count * fine)
        for (w, wave) in waves.enumerated() {
            let stepX = 2 * Double.pi * Double(wave.kx) / Double(fine)
            let stepY = 2 * Double.pi * Double(wave.ky) / Double(fine)
            let start = wave.phase + wave.omega * time
            for i in 0..<fine {
                let ax = stepX * Double(i) + start
                sinX[w * fine + i] = sin(ax)
                cosX[w * fine + i] = cos(ax)
                let ay = stepY * Double(i)
                sinY[w * fine + i] = sin(ay)
                cosY[w * fine + i] = cos(ay)
            }
        }

        let xx = waves.map(\.xx), yy = waves.map(\.yy), xy = waves.map(\.xy)
        let inverseSamples = 1.0 / Double(s * s)
        let inverseCeiling = 1.0 / ceiling

        var out = [Float](repeating: 0, count: n * n)
        var row = [Double](repeating: 0, count: n)

        out.withUnsafeMutableBufferPointer { out in
        row.withUnsafeMutableBufferPointer { row in
        sinX.withUnsafeBufferPointer { sinX in cosX.withUnsafeBufferPointer { cosX in
        sinY.withUnsafeBufferPointer { sinY in cosY.withUnsafeBufferPointer { cosY in
        xx.withUnsafeBufferPointer { xx in yy.withUnsafeBufferPointer { yy in
        xy.withUnsafeBufferPointer { xy in
            var current = -1
            for j in 0..<fine {
                let target = j / s
                if target != current {
                    if current >= 0 {
                        for x in 0..<n { out[current * n + x] = Float(row[x] * inverseSamples) }
                    }
                    for x in 0..<n { row[x] = 0 }
                    current = target
                }
                for i in 0..<fine {
                    var hxx = 0.0, hyy = 0.0, hxy = 0.0
                    for w in 0..<count {
                        let base = w * fine
                        // sin(a + b) for a the column's angle and b the row's.
                        let sine = sinX[base + i] * cosY[base + j] + cosX[base + i] * sinY[base + j]
                        hxx += xx[w] * sine
                        hyy += yy[w] * sine
                        hxy += xy[w] * sine
                    }
                    let determinant = 1 + (hxx + hyy) + (hxx * hyy - hxy * hxy)
                    var value = 1 / abs(determinant)
                    // Written as a failed `<` so that a determinant of exactly zero, which
                    // gives infinity or NaN rather than a large number, is caught here too.
                    if !(value < ceiling) { value = ceiling }
                    row[i / s] += pow(value * inverseCeiling, contrast)
                }
            }
            if current >= 0 {
                for x in 0..<n { out[current * n + x] = Float(row[x] * inverseSamples) }
            }
        }}}}}}}}}

        return out
    }

    /// Separable Gaussian that wraps at the edges, so softening cannot break the tiling the
    /// integer wave vectors guarantee.
    private static func blurWrapping(_ buffer: inout [Float], sigma: Double) {
        guard sigma > 0 else { return }
        let n = resolution
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        var total = 0.0
        for i in -radius...radius {
            let weight = exp(-Double(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = weight
            total += weight
        }
        for i in kernel.indices { kernel[i] /= total }

        var pass = [Float](repeating: 0, count: buffer.count)
        for y in 0..<n {
            for x in 0..<n {
                var sum = 0.0
                for i in -radius...radius {
                    sum += kernel[i + radius] * Double(buffer[y * n + ((x + i) % n + n) % n])
                }
                pass[y * n + x] = Float(sum)
            }
        }
        for y in 0..<n {
            for x in 0..<n {
                var sum = 0.0
                for i in -radius...radius {
                    sum += kernel[i + radius] * Double(pass[(((y + i) % n + n) % n) * n + x])
                }
                buffer[y * n + x] = Float(sum)
            }
        }
    }

    /// Scales the buffer so that, once clipped to [0, 1], it averages to `target`.
    ///
    /// **Dividing by the mean does not do this**, and getting it wrong would quietly mis-set the
    /// lamp compensation that keeps the floor measurement stable. The bright fold cores overshoot
    /// 1 and are clipped, and the light clipped off them is missing from the average — so the
    /// realised mean lands under the target by however much was lost, which depends on the
    /// pattern. Bisection is the honest way to a scale factor whose *clipped* mean is right.
    private static func normalised(_ values: [Float], to target: Float) -> [Float] {
        func meanAfterClipping(at scale: Double) -> Double {
            var total = 0.0
            for value in values { total += min(1, max(0, Double(value) * scale)) }
            return total / Double(values.count)
        }
        var low = 0.0, high = 1.0
        while meanAfterClipping(at: high) < Double(target) && high < 1e9 { high *= 2 }
        for _ in 0..<80 {
            let middle = (low + high) / 2
            if meanAfterClipping(at: middle) < Double(target) { low = middle } else { high = middle }
        }
        let scale = (low + high) / 2
        return values.map { Float(min(1, max(0, Double($0) * scale))) }
    }
}
