// What the shots carry so they can be seen at night, each in a way its object could plausibly
// have been doctored: spitballs faintly luminous; a thumbtack's head an LED; a paper clip and a
// staple with an LED's bright point at one end; a rubber band a glowstick ring; a pencil's point
// glowing like a lit match; an eraser and a paper ball flecked with luminous paint; and the
// hole-punch confetti punched from glowing paint. Behind anything in flight, a short fading trail
// in the shooter's own glow colour, so a shot is a streak rather than a speck and its side reads.
//
// All of it rides `GlowPaint`'s knob: off by day, exactly — a material's emission at zero and
// every extra node hidden — and up with the dark.

import AppKit
import Foundation
import SceneKit
import simd

final class ShotGlow {
    private let paint: GlowPaint
    private let dot: CGImage?
    private var dressed = Set<WeaponKind>()
    private lazy var flecks: [SCNMaterial] = [PaperColor(0.40, 1.0, 0.55), PaperColor(1.0, 0.45, 0.90),
                                               PaperColor(0.45, 0.80, 1.0)].map { paint.dotMaterial($0, strength: 1.2) }
    private lazy var led = paint.dotMaterial(PaperColor(0.75, 0.95, 1.0), strength: 1.6)

    init(paint: GlowPaint) {
        self.paint = paint
        dot = PaperTextures.softDot()
    }

    /// Turns a kind's own materials luminous where its object would glow. Once per kind: every
    /// shot of a kind is a clone of one template, and shares its materials.
    func dress(_ template: ModelTemplate, kind: WeaponKind) {
        guard dressed.insert(kind).inserted else { return }
        for material in SeasonDress.materials(under: template.node) {
            guard let (glow, strength) = ShotGlow.glow(kind: kind, material: material.name ?? "") else { continue }
            // `nil` glows the material's own colour, whatever it was authored as.
            material.emission.contents = glow.map { $0.ns } ?? material.diffuse.contents
            paint.register(material, strength: strength)
        }
    }

    private static func glow(kind: WeaponKind, material: String) -> (PaperColor?, Float)? {
        switch kind {
        case .spitball: return (PaperColor(0.75, 1.0, 0.85), 0.45)
        case .thumbtack: return material.contains("head") ? (nil, 1.5) : nil
        case .paperClip, .staples: return (PaperColor(0.70, 0.85, 1.0), 0.25)
        case .eraser: return (nil, 0.45)
        case .paperBall: return (PaperColor(0.90, 0.95, 1.0), 0.18)
        case .rubberBand: return (PaperColor(0.55, 1.0, 0.25), 1.4)
        case .pencil:
            if material.contains("graphite") { return (PaperColor(1.0, 0.62, 0.25), 1.8) }
            return material.contains("paint") ? (nil, 0.3) : nil
        case .confetti: return nil
        }
    }

    /// The glowing extras for one shot of `kind`, `size` metres long as built at scale 1: an
    /// LED at one end of a clip or a staple, flecks of paint on an eraser or a paper ball.
    /// Nil for kinds whose glow is all in their own materials.
    func bits(kind: WeaponKind, size: Float, seed: Int) -> SCNNode? {
        let group = SCNNode()
        switch kind {
        case .paperClip, .staples:
            let light = GlowPaint.dot(led, diameter: size * 0.42)
            light.simdPosition = SIMD3(size * 0.42, 0, 0)
            group.addChildNode(light)
        case .eraser, .paperBall:
            // On the surface all round, so a tumbling one always shows some.
            var rand = Rand(seed: UInt64(seed) &* 0x9E37_79B9 ^ UInt64(kind.rawValue))
            for k in 0..<(kind == .paperBall ? 5 : 3) {
                let direction = simd_normalize(SIMD3(Float(rand.inRange(-1, 1)), Float(rand.inRange(-1, 1)),
                                                     Float(rand.inRange(-1, 1))) + SIMD3(0, 1e-3, 0))
                let fleck = GlowPaint.dot(flecks[k % flecks.count], diameter: size * (kind == .paperBall ? 0.2 : 0.32))
                fleck.simdOrientation = simd_quatf(from: SIMD3(0, 0, 1), to: direction)
                fleck.simdPosition = direction * size * (kind == .paperBall ? 0.47 : 0.36)
                group.addChildNode(fleck)
            }
        default:
            return nil
        }
        paint.glowOnly(group)
        return group
    }

    /// A short trail behind a shot in flight, emitting only while `fly` says so.
    func trail(size: Float) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = dot
        system.birthRate = 0
        system.loops = true
        system.emissionDuration = 1
        system.particleLifeSpan = 0.3
        system.particleLifeSpanVariation = 0.08
        system.particleSize = CGFloat(max(size * 0.22, 0.009))
        system.particleVelocity = 0
        system.spreadingAngle = 0
        system.isLightingEnabled = false
        // Alpha-blended, never added: a hazy evening would fog an additive sprite into a square.
        system.blendMode = .alpha
        let fade = CAKeyframeAnimation()
        fade.values = [0.85, 0.4, 0].map { NSNumber(value: $0) }
        fade.keyTimes = [0, 0.4, 1]
        let shrink = CAKeyframeAnimation()
        shrink.values = [1, 0.3].map { NSNumber(value: $0 * Double(system.particleSize)) }
        shrink.keyTimes = [0, 1]
        system.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade),
                                      .size: SCNParticlePropertyController(animation: shrink)]
        return system
    }

    /// The trail's emission for a shot this frame.
    func fly(_ trail: SCNParticleSystem, flying: Bool, colour: PaperColor) {
        let rate: CGFloat = flying && paint.isLit ? CGFloat(200 * paint.level) : 0
        if trail.birthRate != rate { trail.birthRate = rate }
        if rate > 0 { trail.particleColor = colour.ns }
    }

    /// Hole-punch dots cut from glowing paint in the shooter's colour.
    func dress(confetti material: SCNMaterial, paper: Paper) {
        material.emission.contents = GlowPaint.colour(for: paper).ns
        paint.register(material, strength: 0.8)
    }
}
