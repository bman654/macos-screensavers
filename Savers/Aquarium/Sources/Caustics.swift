// Caustics: the moving net of focused light that a rippled surface throws on everything under
// it. Here it is a gobo on the look's key light, which is the cheapest correct place for it —
// the pattern then lands on the floor, on the props standing on it and on the backs of the fish
// swimming through it, all from one texture and with no per-object work.
//
// Four measured facts decide the whole design, and all four contradict something you would
// otherwise assume. They were established with throwaway probes against this machine's
// SceneKit; `docs/water-looks.md` §"Caustics" records them.
//
//  1. **A gobo works on a directional light.** Apple documents `SCNLight.gobo` as applying to
//     spot lights, and a spot would have meant giving the key a position and an attenuation it
//     does not want. It does not: a directional light with a gobo stamps the pattern along its
//     own axis. Probed by measuring the spatial variance of a flat lit plane — 0.0000 without a
//     gobo and 0.1669 with one, at no clipping.
//
//  2. **A gobo multiplies the light by the tile's own mean.** A 50/50 black-and-white checker
//     took a plane from 0.4000 to 0.2000, exactly half. So hanging a pattern on the key *dims
//     the whole scene* by however dark the pattern averages out, which would quietly move the
//     floor-versus-water measurement the substrate is balanced against. `compensatedIntensity`
//     divides it back out, which is what lets a look go on stating the light it delivers rather
//     than the light it would deliver if the gobo were white.
//
//  3. **The tile is colour-managed by its own tag.** An 8-bit image tagged sRGB, generic 2.2 or
//     device RGB is all decoded through a 2.2 curve, so a tile authored at mean 0.5 arrives at
//     0.22 and the compensation above would be wrong by more than a factor of two. Tagged
//     *linear*, it arrives exactly as authored — measured gamma 1.01. That is why `image` goes
//     to the trouble of building a `NSBitmapImageRep` by hand instead of using `lockFocus`,
//     which is what the rest of this saver does for generated images.
//
//  4. **One tile is `2.05 x orthographicScale` metres across**, dead linear from 0.1 to 2.0.
//     That is the only handle on how big a caustic cell is in the tank, and it is free here
//     because `orthographicScale` otherwise only shapes a directional light's shadow frustum
//     and the key does not cast one.

import AppKit
import Foundation
import SceneKit

/// What a look wants its caustics to look like, or nil for a look that should not have any.
struct Caustics {
    /// How wide one tile of the pattern is on the floor, in metres.
    ///
    /// Stated in metres rather than as a fraction of the tank, unlike almost everything else in
    /// this saver, and the exception is deliberate: a caustic cell is a fact about the *water's
    /// surface* — the ripple that focused it is centimetres across whatever the tank behind it
    /// is doing — where the fog distances and the prop sizes are facts about the tank. A cell
    /// that scaled with the tank would grow when the tank did, which is precisely wrong.
    let tileMetres: CGFloat

    /// How hard the net bites, from 0 (a flat wash, i.e. no caustics) to 1 (the pattern at the
    /// contrast it was generated with). It is applied to the tile's contrast about its own mean,
    /// so turning it down cannot change how much light the lamp delivers.
    let strength: CGFloat

    /// How far the net drifts across the floor, in tiles per second. Small: a caustic pattern
    /// crawls, and anything fast enough to read as motion reads as a projector fault.
    let drift: CGFloat
}

// MARK: - The tile

enum CausticTexture {
    /// Turns a linear float buffer into an image SceneKit will deliver *unaltered*.
    ///
    /// The linear tag is the load-bearing part — see fact 3 in this file's header — and it lives
    /// in `LinearImage`, which is where the measurements behind it are written down.
    static func image(from values: [Float],
                      size: Int = CausticPattern.resolution) -> NSImage? {
        precondition(values.count == size * size, "buffer is not \(size)x\(size)")
        return LinearImage.make(width: size, height: size) { x, y in
            let value = values[y * size + x]
            return (value, value, value)
        }
    }
}

// MARK: - Hanging it on a light

extension Caustics {
    /// `SCNLight.orthographicScale` that puts one tile at `tileMetres` on the floor. Measured
    /// rather than derived: tile width came back as 2.05x the scale at every setting from 0.1
    /// to 2.0, so the constant is the measurement and not a guess at SceneKit's convention.
    var orthographicScale: CGFloat { tileMetres / 2.05 }

    /// The factor a light's intensity must be multiplied by to deliver what it says it does
    /// once this tile is multiplying it. See fact 2 in the header: without it, adding caustics
    /// silently darkens the tank by the tile's mean and moves the floor measurement with it.
    static func compensation(forMean mean: Float) -> CGFloat {
        // A tile that averaged to nothing would ask for infinite intensity. It cannot happen
        // with a generated tile, but this is multiplying a lamp and the failure would be a
        // white screen rather than a wrong number.
        guard mean > 0.05 else { return 1 }
        return 1 / CGFloat(mean)
    }
}
