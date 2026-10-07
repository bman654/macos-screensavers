// The sun and the sky over the diorama, and where they stand at each hour of the session's day.
//
// The day is a dial from 0 (early morning) to 1 (dusk), from `Atmosphere.phase`; midday, 0.5, is
// exactly the light v1 and v2 shipped with. Four keys and a blend between neighbours, rather than
// an astronomical sun: the sun here has a job — its shadows are the scene's main depth cue — and
// a real one would set, and take the shadows with it. So the sun never drops much below 50°, and
// a plane's shadow at dusk lands at most about 0.7 m from it, where at midday it lands 0.5 m:
// longer, as an evening's are, and still plainly that plane's.
//
// Changes arrive with the drift — an hour from morning to dusk — so the lights are re-aimed only
// when the dial has moved enough to show, not every frame.

import AppKit
import Foundation
import SceneKit
import simd

final class DayLight {
    private let key = SCNLight()
    private let sky = SCNLight()
    private let keyNode = SCNNode()
    let root = SCNNode()
    private let terrain: SCNMaterial?
    /// Materials named for a window, whose emission comes up as the evening does.
    private var windows: [SCNMaterial] = []
    private var shown: Double = -1

    private struct Key {
        let phase: Double
        /// The sun's direction of travel in sim axes, mostly down.
        let travel: SIMD3<Float>
        let colour: SIMD3<Float>
        let intensity: Float
        let skyColour: SIMD3<Float>
        let skyIntensity: Float
    }

    /// Morning comes from the right of the frame — the east, since sim x is east — evening
    /// from the left, each warmer and dimmer at the ends of the day; the sky stays a blue, deeper
    /// toward dusk, which keeps the shaded side of every fold a colour rather than a darkness.
    /// Not violet: a warm sun and a violet sky sum to pink, and a winter evening came out a
    /// field of pink paper rather than snow in low light.
    private static let keys: [Key] = [
        Key(phase: 0, travel: SIMD3(-0.56, -0.30, -1), colour: SIMD3(1.0, 0.92, 0.82), intensity: 780,
            skyColour: SIMD3(0.80, 0.86, 0.98), skyIntensity: 460),
        // v1's sun: from the upper left, warm, the shadows offset down and to the right.
        Key(phase: 0.5, travel: SIMD3(0.36, -0.42, -1), colour: SIMD3(1.0, 0.93, 0.80), intensity: 820,
            skyColour: SIMD3(0.80, 0.85, 0.96), skyIntensity: 430),
        Key(phase: 0.85, travel: SIMD3(0.64, -0.18, -1), colour: SIMD3(1.0, 0.80, 0.58), intensity: 800,
            skyColour: SIMD3(0.64, 0.73, 0.95), skyIntensity: 370),
        Key(phase: 1, travel: SIMD3(0.70, -0.10, -1), colour: SIMD3(0.98, 0.69, 0.47), intensity: 660,
            skyColour: SIMD3(0.52, 0.61, 0.90), skyIntensity: 320),
    ]

    /// The sun's direction of travel at a point on the dial.
    static func sunTravel(at phase: Double) -> SIMD3<Float> {
        blend(phase) { $0.travel }
    }

    /// `terrain` is the landscape's material, whose fold shading follows the sun.
    init(quality: RenderQuality, terrain: SCNMaterial?) {
        self.terrain = terrain
        key.type = .directional
        key.castsShadow = true
        // The one fidelity knob a `.reduced` tile may turn: the shadow map does not shrink with
        // the resolution cap, and a two-inch tile cannot show a 2048-texel map's edges anyway.
        let map: CGFloat = quality == .reduced ? 1024 : 2048
        key.shadowMapSize = CGSize(width: map, height: map)
        key.shadowSampleCount = 8
        key.shadowRadius = 2.0
        key.shadowColor = NSColor(white: 0, alpha: 0.42)
        key.shadowMode = .forward
        key.automaticallyAdjustsShadowProjection = true
        key.maximumShadowDistance = 16
        keyNode.light = key
        root.addChildNode(keyNode)

        // Skylight: cool and soft, so a shadow is a cooler, dimmer paper rather than a hole.
        sky.type = .ambient
        let skyNode = SCNNode()
        skyNode.light = sky
        root.addChildNode(skyNode)

    }

    /// A window found in the scene, lit from the next update with the rest. Windows arrive late
    /// and from anywhere — the flattened scenery is filled in on its first draw, and the fight
    /// builds its hangars when a match begins — so `Landscape` looks for them as they appear.
    func adopt(window material: SCNMaterial) {
        guard !windows.contains(where: { $0 === material }) else { return }
        windows.append(material)
        shown = -1
    }

    func update(phase: Double) {
        // A thousandth of the day is three and a half seconds of drift: well under anything seen.
        guard abs(phase - shown) > 0.001 else { return }
        shown = phase
        let travel = DayLight.sunTravel(at: phase)
        keyNode.simdLook(at: SIMD3(travel.x, travel.z, -travel.y), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        key.color = DayLight.colour(DayLight.blend(phase) { $0.colour })
        key.intensity = CGFloat(DayLight.blend(phase) { SIMD3(repeating: $0.intensity) }.x)
        sky.color = DayLight.colour(DayLight.blend(phase) { $0.skyColour })
        sky.intensity = CGFloat(DayLight.blend(phase) { SIMD3(repeating: $0.skyIntensity) }.x)
        if let terrain { TerrainMesh.aim(terrain, foldsFrom: travel) }

        // Lamps are lit as the sun goes: none by day, most by golden evening, all at dusk. Full
        // strength, because a window is two or three pixels of dark paper and a dim glow on it
        // reads as no glow at all.
        let glow = CGFloat(smoothstep(0.7, 0.92, Float(phase)))
        for window in windows {
            window.emission.contents = NSColor(srgbRed: 1.0 * glow, green: 0.82 * glow, blue: 0.45 * glow, alpha: 1)
        }
    }

    private static func colour(_ c: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    /// A value between the two keys either side of `phase`, smoothly.
    private static func blend(_ phase: Double, _ value: (Key) -> SIMD3<Float>) -> SIMD3<Float> {
        let p = min(max(phase, 0), 1)
        guard let upper = keys.firstIndex(where: { $0.phase >= p }) else { return value(keys[keys.count - 1]) }
        guard upper > 0 else { return value(keys[0]) }
        let a = keys[upper - 1], b = keys[upper]
        let t = smoothstep(0, 1, Float((p - a.phase) / (b.phase - a.phase)))
        return value(a) + (value(b) - value(a)) * t
    }
}
