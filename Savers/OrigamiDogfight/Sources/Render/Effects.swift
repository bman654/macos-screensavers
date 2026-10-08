// The short-lived things: confetti from a hit, a smoke trail, embers, a splash.
//
// Particle systems run on SceneKit's clock, which `SceneKitHost` drives from `FrameContext.time`
// as an absolute timeline, so they stay in step with the sim through a stop and a start. Every
// size is in metres of the diorama, not pixels, so nothing here moves with the backing scale or
// with a `.reduced` tier's resolution cap — and every one takes the match scale of whatever made
// it, so a furball of small planes throws small confetti.

import AppKit
import Foundation
import QuartzCore
import SceneKit
import simd

final class Effects {
    let root = SCNNode()
    /// The night: unlit effects are dimmed by its `ambient`, which by day is 1 and changes
    /// nothing, and glowing ones are added while its paint is lit.
    private let paint: GlowPaint
    private let square: CGImage?
    private let dot: CGImage?
    /// Shared by every shot's splash ring: a splash a second at "lots" is not worth a fresh
    /// torus and material each.
    private let ringGeometry: SCNGeometry

    /// Nodes that remove themselves on a clock, each with an optional per-frame animation
    /// taking the fraction of its life gone.
    private var transients: [(node: SCNNode, start: Double, duration: Double, update: ((Float) -> Void)?)] = []
    private var now: Double = 0

    init(paint: GlowPaint) {
        self.paint = paint
        square = PaperTextures.square()
        dot = PaperTextures.softDot()
        ringGeometry = SCNTorus(ringRadius: 1, pipeRadius: 0.06)
        ringGeometry.materials = [paperMaterial(PaperColor(0.92, 0.97, 1.0), glow: 0.2)]
    }

    func update(time: Double) {
        now = time
        transients.removeAll { item in
            let t = Float((time - item.start) / item.duration)
            if t >= 1 {
                item.node.removeFromParentNode()
                return true
            }
            item.update?(max(t, 0))
            return false
        }
    }

    /// Keeps `node` in the scene for `duration` seconds, then removes it.
    func hold(_ node: SCNNode, for duration: Double, update: ((Float) -> Void)? = nil) {
        if node.parent == nil { root.addChildNode(node) }
        transients.append((node, now, duration, update))
    }

    // MARK: Bursts

    /// A puff of paper bits in the victim's colour where a shot connected — and at night, flecks
    /// of its glowing paint among them, `glow`.
    func confetti(at position: SIMD3<Float>, color: PaperColor, glow: PaperColor, scale k: Float) {
        let system = paperBits(color: color, count: 14, speed: 0.22 * k, size: 0.012 * k, life: 0.7, scale: k)
        burst(system, at: position, life: 1.4)
        if paint.isLit {
            let flecks = paperBits(color: glow, count: 7, speed: 0.22 * k, size: 0.011 * k, life: 0.7, scale: k, glows: true)
            burst(flecks, at: position, life: 1.4)
        }
    }

    /// The moment a plane is shot down: a bigger burst of its own paper, and at night a burst of
    /// sparks — the brightest thing in the sky for a moment.
    func shootDown(at position: SIMD3<Float>, color: PaperColor, glow: PaperColor, scale k: Float) {
        let system = paperBits(color: color, count: 22, speed: 0.26 * k, size: 0.014 * k, life: 0.9, scale: k)
        burst(system, at: position, life: 1.8)
        if paint.isLit {
            let flecks = paperBits(color: glow, count: 10, speed: 0.26 * k, size: 0.012 * k, life: 0.9, scale: k, glows: true)
            burst(flecks, at: position, life: 1.8)
            sparks(at: position, scale: k)
        }
    }

    /// Hitting the ground: dust and scraps thrown out low, and at night sparks.
    func crash(at position: SIMD3<Float>, color: PaperColor, scale k: Float) {
        if paint.isLit { sparks(at: position, scale: k) }
        let scraps = paperBits(color: color, count: 24, speed: 0.3 * k, size: 0.013 * k, life: 0.9, scale: k)
        scraps.emittingDirection = SCNVector3(0, 1, 0)
        scraps.spreadingAngle = 70
        burst(scraps, at: position, life: 1.5)
        let dust = puffs(color: PaperColor(0.62, 0.58, 0.5), alpha: 0.55, count: 10, size: 0.05 * k,
                         growTo: 0.12 * k, life: 1.1)
        dust.particleVelocity = CGFloat(0.18 * k)
        dust.spreadingAngle = 80
        burst(dust, at: position, life: 1.6)
    }

    /// A plane going into a lake: a crown of droplets and a ring spreading on the water.
    func splash(at position: SIMD3<Float>, scale k: Float) {
        let drops = paperBits(color: PaperColor(0.88, 0.95, 1.0), count: 30, speed: 0.45 * k, size: 0.011 * k,
                              life: 0.7, scale: k)
        drops.emittingDirection = SCNVector3(0, 1, 0)
        drops.spreadingAngle = 35
        drops.acceleration = SCNVector3(0, CGFloat(-2.4 * k), 0)
        burst(drops, at: position, life: 1.3)
        rings(at: position, reaches: [(0.0, 0.22 * k), (0.25, 0.14 * k)])
    }

    /// Two planes meeting: scraps of both their papers burst out together, with a grey puff of
    /// crumpled paper — bigger than a hit, so a collision is never mistaken for one.
    func collision(at position: SIMD3<Float>, colors: [PaperColor], scale k: Float) {
        for color in colors {
            let scraps = paperBits(color: color, count: 26, speed: 0.34 * k, size: 0.016 * k, life: 1.1, scale: k)
            burst(scraps, at: position, life: 2)
        }
        let puff = puffs(color: PaperColor(0.84, 0.82, 0.78), alpha: 0.5, count: 8, size: 0.04 * k,
                         growTo: 0.12 * k, life: 0.9)
        puff.particleVelocity = CGFloat(0.12 * k)
        burst(puff, at: position, life: 1.4)
    }

    /// A supply crate taken: it bursts into paper confetti of every colour.
    func cratePop(at position: SIMD3<Float>) {
        let colours = [PaperColor(0.74, 0.56, 0.36), PaperColor(0.88, 0.20, 0.18), PaperColor(0.18, 0.42, 0.86),
                       PaperColor(0.99, 0.80, 0.16), PaperColor(0.98, 0.96, 0.94)]
        for color in colours {
            let bits = paperBits(color: color, count: 7, speed: 0.2, size: 0.011, life: 0.9, scale: 0.8)
            burst(bits, at: position, life: 2)
        }
    }

    /// A sticker earned: a quick twinkle of gold over the ace.
    func sparkle(at position: SIMD3<Float>, scale k: Float) {
        let bits = paperBits(color: PaperColor(1.0, 0.86, 0.3), count: 14, speed: 0.2 * k, size: 0.012 * k, life: 0.8,
                             scale: k * 0.3)
        bits.particleColorVariation = SCNVector4(0.04, 0.2, 0.2, 0)
        burst(bits, at: position, life: 1.4)
    }

    /// A shot coming down in a lake: the same splash in miniature — a few blue paper bits and
    /// one small ring, sized to the shot rather than to a plane.
    func shotSplash(at position: SIMD3<Float>, size: Float) {
        let drops = paperBits(color: PaperColor(0.62, 0.80, 0.94), count: 9, speed: 2.4 * size, size: 0.16 * size,
                              life: 0.5, scale: size / 0.06)
        drops.emittingDirection = SCNVector3(0, 1, 0)
        drops.spreadingAngle = 40
        drops.acceleration = SCNVector3(0, CGFloat(-30 * size), 0)
        burst(drops, at: position, life: 0.9)
        rings(at: position, reaches: [(0.0, 0.9 * size)])
    }

    private func rings(at position: SIMD3<Float>, reaches: [(Double, Float)]) {
        for (delay, reach) in reaches {
            let ring = SCNNode(geometry: ringGeometry)
            ring.simdPosition = position + SIMD3(0, 0.003, 0)
            ring.simdScale = SIMD3(repeating: 0.001)
            ring.castsShadow = false
            hold(ring, for: 1.6 + delay) { [weak ring] t in
                let local = max(0, (t * Float(1.6 + delay) - Float(delay)) / 1.6)
                let r = reach * (0.09 + 0.91 * sqrt(local))
                ring?.simdScale = SIMD3(r, r * 0.6, r)
                ring?.opacity = CGFloat(local > 0 ? 1 - local : 0)
            }
        }
    }

    private func burst(_ system: SCNParticleSystem, at position: SIMD3<Float>, life: Double) {
        system.loops = false
        system.emissionDuration = 0.06
        let node = SCNNode()
        node.simdPosition = position
        node.addParticleSystem(system)
        hold(node, for: life)
    }

    // MARK: Continuous

    /// Scraps shed by a damaged plane. Left in world space, so they fall away behind it.
    func scrapTrail(color: PaperColor, scale k: Float) -> SCNParticleSystem {
        let system = paperBits(color: color, count: 0, speed: 0.08 * k, size: 0.011 * k, life: 1.4, scale: k)
        system.birthRate = 7
        system.loops = true
        system.emissionDuration = 1
        return system
    }

    /// Glitter behind a plane carrying a supply drop's weapon: gold for triple shot, a cool white
    /// for rapid fire, so the two read differently at a glance. Left in world space, so it
    /// streams out behind.
    func glintTrail(_ kind: PowerUpKind, scale k: Float) -> SCNParticleSystem {
        let color = kind == .tripleShot ? PaperColor(1.0, 0.82, 0.24) : PaperColor(0.82, 0.92, 1.0)
        let system = paperBits(color: color, count: 0, speed: 0.04 * k, size: 0.011 * k, life: 0.8, scale: k * 0.2,
                               glows: true)
        system.birthRate = 30
        system.loops = true
        system.emissionDuration = 1
        system.particleColorVariation = SCNVector4(0.03, 0.1, 0.15, 0)
        // Glitter catches the light: a little glow, so it reads over the meadow as well as the lake.
        system.blendMode = .additive
        return system
    }

    /// Sparks flung out by an explosion in the dark: hot, bright and short.
    private func sparks(at position: SIMD3<Float>, scale k: Float) {
        let system = paperBits(color: PaperColor(1.0, 0.78, 0.36), count: Int(10 + 16 * paint.level), speed: 0.4 * k,
                               size: 0.009 * k, life: 0.55, scale: k, glows: true)
        system.particleColorVariation = SCNVector4(0.05, 0.25, 0.2, 0)
        burst(system, at: position, life: 1)
    }

    /// The black-grey trail of a plane going down.
    func smokeTrail(scale k: Float) -> SCNParticleSystem {
        let system = puffs(color: PaperColor(0.30, 0.29, 0.28), alpha: 0.75, count: 0, size: 0.035 * k,
                           growTo: 0.1 * k, life: 1.3)
        system.birthRate = 45
        system.loops = true
        system.emissionDuration = 1
        system.particleVelocity = CGFloat(0.03 * k)
        system.acceleration = SCNVector3(0, CGFloat(0.12 * k), 0)
        return system
    }

    /// Sparks lifting off a burning wreck.
    func embers(scale k: Float) -> SCNParticleSystem {
        let system = paperBits(color: PaperColor(1.0, 0.62, 0.16), count: 0, speed: 0.12 * k, size: 0.008 * k,
                               life: 1.5, scale: k, glows: true)
        system.birthRate = 9
        system.loops = true
        system.emissionDuration = 1
        system.emittingDirection = SCNVector3(0, 1, 0)
        system.spreadingAngle = 25
        system.acceleration = SCNVector3(0, CGFloat(0.18 * k), 0)
        system.particleColorVariation = SCNVector4(0.06, 0, 0.1, 0)
        system.emitterShape = SCNSphere(radius: CGFloat(0.035 * k))
        return system
    }

    // MARK: Particle templates

    /// `scale` shrinks the fall with the bits, so a small burst arcs the way a big one does.
    /// Particles are unlit, so a paper bit is as bright at night as at noon unless it is dimmed
    /// to the hour; `glows` says it is light itself — an ember, a spark — and keeps its colour.
    private func paperBits(color: PaperColor, count: Int, speed: Float, size: Float, life: CGFloat,
                           scale: Float, glows: Bool = false) -> SCNParticleSystem {
        let color = glows ? color : color.scaled(CGFloat(paint.ambient))
        let system = SCNParticleSystem()
        system.particleImage = square
        system.birthRate = CGFloat(count) / 0.06
        system.particleLifeSpan = life
        system.particleLifeSpanVariation = life * 0.35
        system.particleSize = CGFloat(size)
        system.particleSizeVariation = CGFloat(size * 0.4)
        system.particleVelocity = CGFloat(speed)
        system.particleVelocityVariation = CGFloat(speed * 0.6)
        system.spreadingAngle = 180
        system.emittingDirection = SCNVector3(0, 1, 0)
        system.acceleration = SCNVector3(0, CGFloat(-1.2 * scale), 0)
        system.particleAngularVelocity = 540
        system.particleAngularVelocityVariation = 360
        system.particleColor = color.ns
        system.particleColorVariation = SCNVector4(0, 0, 0.12, 0)
        system.isLightingEnabled = false
        system.blendMode = .alpha
        system.dampingFactor = 1.5
        system.propertyControllers = [.opacity: fade(values: [1, 1, 0], times: [0, 0.7, 1])]
        return system
    }

    private func puffs(color: PaperColor, alpha: CGFloat, count: Int, size: Float, growTo: Float,
                       life: CGFloat) -> SCNParticleSystem {
        let color = color.scaled(CGFloat(paint.ambient))
        let system = SCNParticleSystem()
        system.particleImage = dot
        system.birthRate = CGFloat(count) / 0.06
        system.particleLifeSpan = life
        system.particleLifeSpanVariation = life * 0.25
        system.particleSize = CGFloat(size)
        system.particleColor = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: alpha)
        system.particleColorVariation = SCNVector4(0, 0, 0.08, 0)
        system.spreadingAngle = 180
        system.isLightingEnabled = false
        system.blendMode = .alpha
        system.dampingFactor = 1
        system.propertyControllers = [
            .opacity: fade(values: [0, 1, 0], times: [0, 0.15, 1]),
            .size: fade(values: [CGFloat(size), CGFloat(growTo)], times: [0, 1]),
        ]
        return system
    }

    private func fade(values: [CGFloat], times: [NSNumber]) -> SCNParticlePropertyController {
        let animation = CAKeyframeAnimation()
        animation.values = values.map { NSNumber(value: Double($0)) }
        animation.keyTimes = times
        return SCNParticlePropertyController(animation: animation)
    }
}

extension SIMD2 where Scalar == Float {
    /// Sim ground coordinates to SceneKit's Y-up space at an altitude.
    func scene(altitude: Float) -> SIMD3<Float> { SIMD3(x, altitude, -y) }
}
