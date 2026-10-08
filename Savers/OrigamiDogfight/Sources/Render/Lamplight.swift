// Lamplight on the ground round every building with windows, so that "the windows are lit" can
// be seen from a camera that looks almost straight down.
//
// The windows themselves glow (`DayLight` sets their emission), but they are on the walls, and
// from above the roofs hide all of them: in a close crop of a lit evening village not one window
// pixel showed. What a lit house looks like from the air is light spilling out round it, so that
// is what is drawn — real light, falling on the grass, the lane and the house's own walls and
// roof (`GroundLights`). It was once a disc of lamp colour blended over the ground; that read as
// lamplight at dusk and as a beige blot at night, because a blend replaces the ground's colour
// where light multiplies it.
//
// The houses never move, so their light is drawn once into a map of the ground (`lampMap`), and
// any number of them cost the GPU one texture sample per fragment. The hangars come and go with
// the matches, at most four, so theirs are lamps in the frame's list instead.

import Foundation
import simd

final class Lamplight {
    private let lights: GroundLights

    /// 0 by day, 1 at dusk and through the night.
    var glow: Float = 0 {
        didSet { lights.lampStrength = min(max(glow, 0), 1) }
    }

    init(lights: GroundLights) { self.lights = lights }

    /// A pool round every house, and so round every mill, which stands in a house's place.
    func light(houses spots: [PropSpot], terrain: Terrain) {
        let houses = spots.filter { $0.kind == .house }
        let lattice = terrain.lattice
        guard !houses.isEmpty, let first = lattice.points.first else { return }
        var lo = first, hi = first
        for p in lattice.points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let size = 512
        var map = [Float](repeating: 0, count: size * size)
        let span = hi - lo
        let perPixel = span / Float(size)
        for spot in houses {
            // Reaching about a house's width beyond its walls (`ModelShelf`: 0.11 m across).
            let reach = 0.16 * spot.scale
            let centre = (spot.position - lo) / perPixel
            let radius = SIMD2(repeating: reach) / perPixel
            let x0 = max(Int(centre.x - radius.x), 0), x1 = min(Int(centre.x + radius.x) + 1, size - 1)
            let y0 = max(Int(centre.y - radius.y), 0), y1 = min(Int(centre.y + radius.y) + 1, size - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let d = (SIMD2(Float(x) + 0.5, Float(y) + 0.5) - centre) / radius
                    let r = 1 - min(simd_length_squared(d), 1)
                    map[y * size + x] += r * r
                }
            }
        }
        lights.lampMap(map, size: size, origin: lo, span: span)
    }

    /// A hangar's lamp, through the window in its back wall: `back` is the middle of that wall
    /// on the floor, `open` how far the hangar has unfolded — the light comes up with it.
    func hangar(back: SIMD3<Float>, length: Float, open: Float) {
        guard glow > 0.01, open > 0.01 else { return }
        lights.lamp(at: back + SIMD3(0, 0.02, 0), radius: length * 1.3, strength: glow * open)
    }
}
