// The sun and the sky over the diorama, and where they stand at each hour of the session's day.
//
// The day is a dial from 0 (early morning) to 1 (dusk) and on to 1.25 (night), from
// `Atmosphere.phase`; midday, 0.5, is exactly the light v1 and v2 shipped with. Six keys and a blend between neighbours, rather than
// an astronomical sun: its shadows are the scene's main depth cue, so it never sets. It does get
// low: about 31° at dawn and 29° at evening against midday's 61°, and 23° at dusk, which throws a
// tree's shadow three to four times as far as midday's. A plane's would land 1.5–2 m away, no
// longer plainly its own, so the planes cast none from this sun and `PlaneShadows` lays theirs
// along the same bearing at about midday's reach.
//
// The three times of day are told apart by more than the sun's colour, because colour alone was
// all v3 changed and nobody could tell morning from midday:
//   - morning: a low sun from the east (right of frame), rosy-gold, a cool sky, and a pale haze
//     that lifts as the morning goes on; the last lamps of the night still lit;
//   - midday: v1's light, untouched — the reference;
//   - evening: a low deep-orange sun from the west, a much dimmer blue-violet sky, so the shade
//     is cool and dark and the sun's side warm, then dusk — red sun, dark blue shade, a dusk
//     haze, every window lit. The scene at dusk has about an eighth of midday's luminance;
//   - night: the moon, high and white-blue, under a dark blue sky — soft faint shadows, the land
//     barely readable, and what shows is light: lamps, fires, headlamps and the glow-in-the-dark
//     paint the fight is painted in (`GlowPaint`).
// The fight is kept readable through it by a fill light of its own (`fightCategory`), which
// tracks the camera and lights only planes, tanks, shots, stickers and crates.
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
    private let fill = SCNLight()
    let root = SCNNode()
    /// The fight's own fill light, from the camera. Hung on the camera by the scene, so it
    /// always comes from the viewer's side, whatever the view.
    let fillNode = SCNNode()
    private let terrain: SCNMaterial?
    private weak var scene: SCNScene?
    private let lamplight: Lamplight
    private let planeShadows: PlaneShadows
    private let paint: GlowPaint
    private let groundLights: GroundLights
    /// Materials named for a window, whose emission comes up as the evening does.
    private var windows: [SCNMaterial] = []
    private var shown: Double = -1
    /// The day's keys in this session's season (`keys(for:)`).
    private let keys: [Key]

    /// The light category the fight's models join (`enlist`), and the only one the fight fill
    /// lights. Everything is in category 1 as well, as SceneKit's default, so the sun and the sky
    /// light the fight exactly as they light the landscape. (A category does not choose what
    /// casts a light's shadow — SceneKit draws every `castsShadow` node into every shadow map —
    /// which is why the planes' shadows are `PlaneShadows`' and not a second light's.)
    static let fightCategory = 1 << 1

    /// Puts every node under `node` in the fight fill's light. Called on each model as it is
    /// built, and on each sticker as it is stuck on.
    static func enlist(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in child.categoryBitMask |= fightCategory }
    }

    private struct Key {
        let phase: Double
        /// The sun's direction of travel in sim axes, with z = -1: the horizontal part is how far
        /// a shadow lands per metre of height, so blending it blends shadow length linearly.
        let travel: SIMD3<Float>
        let colour: SIMD3<Float>
        let intensity: Float
        let skyColour: SIMD3<Float>
        let skyIntensity: Float
        /// How much of the sun a shadow takes away: deeper as the sun gets low and red, so the
        /// shade at dusk is the sky's blue rather than a dimmer orange.
        let shadow: Float
        /// The fight fill's strength (`fightCategory`).
        let fill: Float
        /// Haze: how far the ground is veiled toward `hazeColour`, as a fraction at the ground's
        /// distance from the camera. Planes, nearer the camera, take about half as much.
        let haze: Float
        let hazeColour: SIMD3<Float>
        /// Lamplight in the windows, and cars' headlamps, 0 to 1.
        let lamps: Float
        /// Glow-in-the-dark paint, 0 to 1 (`GlowPaint`).
        let glow: Float
        /// How strongly fire lights the ground round it (`GroundLights.fireStrength`).
        let fire: Float
        /// How much of their colour the unlit effects keep (`GlowPaint.ambient`).
        let ambient: Float
    }

    /// Morning comes from the right of the frame — the east, since sim x is east — evening from
    /// the left. The sky is blue all day and dims far more than the sun toward dusk, which is
    /// what makes evening dark rather than merely orange: the shade loses most of its light and
    /// what is left is blue. Not violet: a warm sun and a violet sky sum to pink, and a winter
    /// evening came out a field of pink paper rather than snow in low light.
    private static let keys: [Key] = [
        // Dawn: about 30° up, rosy-gold, a cool sky, a pearl haze; the night's lamps still on and
        // the last of the paint's glow.
        Key(phase: 0, travel: SIMD3(-1.55, -0.55, -1), colour: SIMD3(1.0, 0.80, 0.70), intensity: 900,
            skyColour: SIMD3(0.70, 0.79, 1.0), skyIntensity: 390, shadow: 0.55, fill: 110,
            haze: 0.14, hazeColour: SIMD3(0.93, 0.86, 0.88), lamps: 0.45, glow: 0.08, fire: 0.25, ambient: 1),
        // Mid-morning: the haze has lifted and the lamps are out.
        Key(phase: 0.2, travel: SIMD3(-0.70, -0.48, -1), colour: SIMD3(1.0, 0.91, 0.82), intensity: 860,
            skyColour: SIMD3(0.78, 0.84, 0.98), skyIntensity: 420, shadow: 0.46, fill: 0,
            haze: 0.04, hazeColour: SIMD3(0.90, 0.88, 0.90), lamps: 0, glow: 0, fire: 0.15, ambient: 1),
        // v1's sun: from the upper left, warm, the shadows offset down and to the right. A fire's
        // light is only a warmth on the grass round it.
        Key(phase: 0.5, travel: SIMD3(0.36, -0.42, -1), colour: SIMD3(1.0, 0.93, 0.80), intensity: 820,
            skyColour: SIMD3(0.80, 0.85, 0.96), skyIntensity: 430, shadow: 0.42, fill: 0,
            haze: 0, hazeColour: SIMD3(0.80, 0.85, 0.96), lamps: 0, glow: 0, fire: 0.15, ambient: 1),
        // Late afternoon: lower and golden, the sky starting to dim.
        Key(phase: 0.7, travel: SIMD3(0.95, -0.40, -1), colour: SIMD3(1.0, 0.85, 0.64), intensity: 840,
            skyColour: SIMD3(0.72, 0.78, 0.96), skyIntensity: 360, shadow: 0.50, fill: 40,
            haze: 0, hazeColour: SIMD3(0.60, 0.62, 0.80), lamps: 0, glow: 0, fire: 0.3, ambient: 1),
        // Evening, where an evening session begins: a low deep-orange sun, a dim blue-violet sky,
        // and the paint beginning to show.
        Key(phase: 0.85, travel: SIMD3(1.75, -0.35, -1), colour: SIMD3(1.0, 0.66, 0.38), intensity: 700,
            skyColour: SIMD3(0.50, 0.55, 0.92), skyIntensity: 300, shadow: 0.64, fill: 340,
            haze: 0.06, hazeColour: SIMD3(0.36, 0.36, 0.58), lamps: 0.9, glow: 0.3, fire: 0.65, ambient: 1),
        // Dusk: a red sun on the horizon's edge, the shade dark blue.
        Key(phase: 1, travel: SIMD3(2.30, -0.20, -1), colour: SIMD3(1.0, 0.47, 0.26), intensity: 560,
            skyColour: SIMD3(0.40, 0.45, 0.86), skyIntensity: 200, shadow: 0.66, fill: 500,
            haze: 0.14, hazeColour: SIMD3(0.24, 0.25, 0.44), lamps: 1, glow: 0.55, fire: 0.85, ambient: 0.8),
        // Nightfall: the sun gone, the moon not yet risen far — a deep blue sky and little else.
        Key(phase: 1.12, travel: SIMD3(0.40, -0.90, -1), colour: SIMD3(0.62, 0.70, 0.95), intensity: 80,
            skyColour: SIMD3(0.28, 0.36, 0.78), skyIntensity: 70, shadow: 0.5, fill: 260,
            haze: 0.12, hazeColour: SIMD3(0.08, 0.10, 0.22), lamps: 1, glow: 0.85, fire: 1, ambient: 0.55),
        // Night: a white-blue moon high in the south-east, soft faint shadows, a dark blue sky.
        // The land is barely there; the lamps, the fires and the fight's paint are what shows.
        Key(phase: 1.25, travel: SIMD3(-0.45, -0.55, -1), colour: SIMD3(0.62, 0.74, 1.0), intensity: 62,
            skyColour: SIMD3(0.20, 0.28, 0.72), skyIntensity: 40, shadow: 0.45, fill: 150,
            haze: 0.12, hazeColour: SIMD3(0.04, 0.06, 0.16), lamps: 1, glow: 1, fire: 1, ambient: 0.4),
    ]

    /// Winter's colours at the ends of the day — the sun's path and strength, the lamps and the
    /// fill are the same. Snow shows every cast, and the summer keys on it summed to pink: an
    /// orange sun and a blue-violet sky lift red and blue over green. Here the low sun is amber
    /// rather than orange, the sky a greyer blue and the dusk haze slate, so a snowfield at dusk
    /// is warm in the last light and blue-grey in the shade, never pink; and dawn's sun is a
    /// paler peach-white, so its cool sky and haze read as cold rather than lilac.
    private static let winterColours: [(colour: SIMD3<Float>, skyColour: SIMD3<Float>, haze: SIMD3<Float>)?] = [
        (SIMD3(1.0, 0.90, 0.80), SIMD3(0.74, 0.83, 0.96), SIMD3(0.86, 0.88, 0.93)),
        (SIMD3(1.0, 0.95, 0.88), SIMD3(0.80, 0.87, 0.95), SIMD3(0.88, 0.90, 0.94)),
        nil,
        (SIMD3(1.0, 0.89, 0.72), SIMD3(0.72, 0.79, 0.90), SIMD3(0.60, 0.64, 0.74)),
        (SIMD3(1.0, 0.86, 0.60), SIMD3(0.46, 0.62, 0.82), SIMD3(0.38, 0.46, 0.56)),
        // Dusk's sun dimmed in its colour, since winter shares the keys' strengths: on flat snow
        // the summer key's share outweighed the sky and summed to mauve.
        (SIMD3(0.86, 0.70, 0.46), SIMD3(0.34, 0.60, 0.82), SIMD3(0.26, 0.36, 0.46)),
        // Night on snow is blue: the moon a cold white and the sky a clear deep blue, so the
        // snowfield reads as moonlit snow and not as grey paper.
        (SIMD3(0.62, 0.72, 0.95), SIMD3(0.28, 0.42, 0.80), SIMD3(0.08, 0.12, 0.26)),
        (SIMD3(0.66, 0.78, 1.0), SIMD3(0.24, 0.38, 0.78), SIMD3(0.05, 0.09, 0.22)),
    ]

    private static func keys(for season: Season) -> [Key] {
        guard season == .winter else { return keys }
        return zip(keys, winterColours).map { key, winter in
            guard let winter else { return key }
            return Key(phase: key.phase, travel: key.travel, colour: winter.colour, intensity: key.intensity,
                       skyColour: winter.skyColour, skyIntensity: key.skyIntensity, shadow: key.shadow,
                       fill: key.fill, haze: key.haze, hazeColour: winter.haze, lamps: key.lamps, glow: key.glow,
                       fire: key.fire, ambient: key.ambient)
        }
    }

    /// The sun's direction of travel at a point on the dial — the same in every season.
    static func sunTravel(at phase: Double) -> SIMD3<Float> {
        blend(phase, keys) { $0.travel }
    }

    /// `terrain` is the landscape's material, whose fold shading follows the sun; `scene` takes
    /// the haze; `lamplight` is the glow round every lit window; `planeShadows` the planes'
    /// shadows, which follow the sun; `paint` the fight's luminous paint and `groundLights` the
    /// firelight and headlamps, which both come up as the light goes.
    init(quality: RenderQuality, season: Season, terrain: SCNMaterial?, scene: SCNScene, lamplight: Lamplight,
         planeShadows: PlaneShadows, paint: GlowPaint, groundLights: GroundLights) {
        self.terrain = terrain
        self.scene = scene
        self.lamplight = lamplight
        self.planeShadows = planeShadows
        self.paint = paint
        self.groundLights = groundLights
        keys = DayLight.keys(for: season)
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

        // A directional light pointing where the camera looks, so it falls square on every
        // plane's upper surface whatever its heading; a warm white, so team colours keep their
        // hue at dusk rather than taking the sky's blue.
        fill.type = .directional
        fill.categoryBitMask = DayLight.fightCategory
        fill.color = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.88, alpha: 1)
        fill.intensity = 0
        fillNode.light = fill
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
        func value(_ pick: (Key) -> Float) -> Float { DayLight.blend(phase, keys) { SIMD3(repeating: pick($0)) }.x }
        let travel = DayLight.sunTravel(at: phase)
        keyNode.simdLook(at: SIMD3(travel.x, travel.z, -travel.y), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        let colour = DayLight.blend(phase, keys) { $0.colour }
        let skyColour = DayLight.blend(phase, keys) { $0.skyColour }
        let intensity = value { $0.intensity }, skyIntensity = value { $0.skyIntensity }, shadow = value { $0.shadow }
        key.color = DayLight.colour(colour)
        key.intensity = CGFloat(intensity)
        key.shadowColor = NSColor(white: 0, alpha: CGFloat(shadow))
        sky.color = DayLight.colour(skyColour)
        sky.intensity = CGFloat(skyIntensity)
        // What the sun's shadow leaves of the light on level ground, channel by channel, in
        // linear light: the sky, and the part of the sun the shadow lets through.
        let sun = DayLight.linear(colour) * (intensity / simd_length(travel))
        let skyLight = DayLight.linear(skyColour) * skyIntensity
        planeShadows.light(travel: travel, keeps: (skyLight + sun * (1 - shadow)) / (skyLight + sun))
        fill.intensity = CGFloat(value { $0.fill })
        if let terrain { TerrainMesh.aim(terrain, foldsFrom: travel) }
        haze(value { $0.haze }, colour: DayLight.blend(phase, keys) { $0.hazeColour })

        // Full strength in the window itself, because a window is two or three pixels of dark
        // paper and a dim glow on it reads as no glow at all — and from above it is mostly hidden
        // under its roof, so what says "lit" is the pool of lamplight on the ground round it.
        let lamps = value { $0.lamps }
        let glow = CGFloat(min(lamps * 1.6, 1))
        for window in windows {
            window.emission.contents = NSColor(srgbRed: 1.0 * glow, green: 0.82 * glow, blue: 0.45 * glow, alpha: 1)
        }
        lamplight.glow = lamps
        // Headlamps only once it is dusky: dawn keeps the night's last lamps in the windows, but
        // a beam on a sunlit lane read as a mistake.
        groundLights.headlampStrength = smoothstep(0.5, 0.9, lamps)
        groundLights.fireStrength = value { $0.fire }
        groundLights.moonlight = 0.65 * smoothstep(1, Float(Atmosphere.nightPhase), Float(phase))
        paint.set(level: value { $0.glow }, ambient: value { $0.ambient })
    }

    /// Scene fog standing in for haze. Fog is by distance from the eye, and from straight above
    /// the ground is all at nearly one distance, so it starts a little short of the planes'
    /// band and is set to veil the ground by `amount`: the planes, nearer the camera, take about
    /// half as much, and stand out of the haze rather than into it. The scoreboard card, at the
    /// camera's near plane, takes none.
    private func haze(_ amount: Float, colour: SIMD3<Float>) {
        guard let scene else { return }
        guard amount > 0.005 else {
            scene.fogEndDistance = 0
            return
        }
        let start: Float = 3.6, ground: Float = 5.9
        scene.fogStartDistance = CGFloat(start)
        scene.fogEndDistance = CGFloat(start + (ground - start) / amount)
        scene.fogDensityExponent = 1
        scene.fogColor = DayLight.colour(colour)
    }

    /// An sRGB-encoded colour, as the keys are written, decoded to linear light.
    private static func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = linearRGBA(PaperColor(CGFloat(c.x), CGFloat(c.y), CGFloat(c.z)))
        return SIMD3(l.x, l.y, l.z)
    }

    private static func colour(_ c: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    /// A value between the two keys either side of `phase`, smoothly.
    private static func blend(_ phase: Double, _ keys: [Key], _ value: (Key) -> SIMD3<Float>) -> SIMD3<Float> {
        let p = min(max(phase, 0), Atmosphere.nightPhase)
        guard let upper = keys.firstIndex(where: { $0.phase >= p }) else { return value(keys[keys.count - 1]) }
        guard upper > 0 else { return value(keys[0]) }
        let a = keys[upper - 1], b = keys[upper]
        let t = smoothstep(0, 1, Float((p - a.phase) / (b.phase - a.phase)))
        return value(a) + (value(b) - value(a)) * t
    }
}
