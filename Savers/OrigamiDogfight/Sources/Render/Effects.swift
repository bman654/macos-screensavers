// The short-lived things: confetti from a hit, a smoke trail, embers, a splash.
//
// Particle systems run on SceneKit's clock, which `SceneKitHost` drives from `FrameContext.time`
// as an absolute timeline, so they stay in step with the sim through a stop and a start. Every
// size is in metres of the diorama, not pixels, so nothing here moves with the backing scale or
// with a `.reduced` tier's resolution cap.

import AppKit
import Foundation
import QuartzCore
import SceneKit
import simd

final class Effects {
    let root = SCNNode()
    private let square: CGImage?
    private let dot: CGImage?

    /// Nodes that remove themselves on a clock, each with an optional per-frame animation
    /// taking the fraction of its life gone.
    private var transients: [(node: SCNNode, start: Double, duration: Double, update: ((Float) -> Void)?)] = []
    private var now: Double = 0

    init() {
        square = PaperTextures.square()
        dot = PaperTextures.softDot()
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

    /// A puff of paper bits in the victim's colour where a shot connected.
    func confetti(at position: SIMD3<Float>, color: PaperColor) {
        let system = paperBits(color: color, count: 14, speed: 0.22, size: 0.012, life: 0.7)
        burst(system, at: position, life: 1.4)
    }

    /// The moment a plane is shot down: a bigger burst of its own paper.
    func shootDown(at position: SIMD3<Float>, color: PaperColor) {
        let system = paperBits(color: color, count: 22, speed: 0.26, size: 0.014, life: 0.9)
        burst(system, at: position, life: 1.8)
    }

    /// Hitting the ground: dust and scraps thrown out low.
    func crash(at position: SIMD3<Float>, color: PaperColor) {
        let scraps = paperBits(color: color, count: 24, speed: 0.3, size: 0.013, life: 0.9)
        scraps.emittingDirection = SCNVector3(0, 1, 0)
        scraps.spreadingAngle = 70
        burst(scraps, at: position, life: 1.5)
        let dust = puffs(color: PaperColor(0.62, 0.58, 0.5), alpha: 0.55, count: 10, size: 0.05, growTo: 0.12, life: 1.1)
        dust.particleVelocity = 0.18
        dust.spreadingAngle = 80
        burst(dust, at: position, life: 1.6)
    }

    /// A plane going into a lake: a crown of droplets and a ring spreading on the water.
    func splash(at position: SIMD3<Float>) {
        let drops = paperBits(color: PaperColor(0.88, 0.95, 1.0), count: 30, speed: 0.45, size: 0.011, life: 0.7)
        drops.emittingDirection = SCNVector3(0, 1, 0)
        drops.spreadingAngle = 35
        drops.acceleration = SCNVector3(0, -2.4, 0)
        burst(drops, at: position, life: 1.3)

        for (delay, reach) in [(0.0, Float(0.22)), (0.25, 0.14)] {
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 1, pipeRadius: 0.06))
            ring.geometry?.materials = [paperMaterial(PaperColor(0.92, 0.97, 1.0), glow: 0.2)]
            ring.simdPosition = position + SIMD3(0, 0.003, 0)
            ring.simdScale = SIMD3(repeating: 0.001)
            ring.castsShadow = false
            hold(ring, for: 1.6 + delay) { [weak ring] t in
                let local = max(0, (t * Float(1.6 + delay) - Float(delay)) / 1.6)
                let r = 0.02 + reach * sqrt(local)
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
    func scrapTrail(color: PaperColor) -> SCNParticleSystem {
        let system = paperBits(color: color, count: 0, speed: 0.08, size: 0.011, life: 1.4)
        system.birthRate = 7
        system.loops = true
        system.emissionDuration = 1
        return system
    }

    /// The black-grey trail of a plane going down.
    func smokeTrail() -> SCNParticleSystem {
        let system = puffs(color: PaperColor(0.30, 0.29, 0.28), alpha: 0.75, count: 0, size: 0.035, growTo: 0.1, life: 1.3)
        system.birthRate = 45
        system.loops = true
        system.emissionDuration = 1
        system.particleVelocity = 0.03
        system.acceleration = SCNVector3(0, 0.12, 0)
        return system
    }

    /// Sparks lifting off a burning wreck.
    func embers() -> SCNParticleSystem {
        let system = paperBits(color: PaperColor(1.0, 0.62, 0.16), count: 0, speed: 0.12, size: 0.008, life: 1.5)
        system.birthRate = 9
        system.loops = true
        system.emissionDuration = 1
        system.emittingDirection = SCNVector3(0, 1, 0)
        system.spreadingAngle = 25
        system.acceleration = SCNVector3(0, 0.18, 0)
        system.particleColorVariation = SCNVector4(0.06, 0, 0.1, 0)
        system.emitterShape = SCNSphere(radius: 0.035)
        return system
    }

    // MARK: Particle templates

    private func paperBits(color: PaperColor, count: Int, speed: CGFloat, size: CGFloat, life: CGFloat) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = square
        system.birthRate = CGFloat(count) / 0.06
        system.particleLifeSpan = life
        system.particleLifeSpanVariation = life * 0.35
        system.particleSize = size
        system.particleSizeVariation = size * 0.4
        system.particleVelocity = speed
        system.particleVelocityVariation = speed * 0.6
        system.spreadingAngle = 180
        system.emittingDirection = SCNVector3(0, 1, 0)
        system.acceleration = SCNVector3(0, -1.2, 0)
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

    private func puffs(color: PaperColor, alpha: CGFloat, count: Int, size: CGFloat, growTo: CGFloat,
                       life: CGFloat) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = dot
        system.birthRate = CGFloat(count) / 0.06
        system.particleLifeSpan = life
        system.particleLifeSpanVariation = life * 0.25
        system.particleSize = size
        system.particleColor = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: alpha)
        system.particleColorVariation = SCNVector4(0, 0, 0.08, 0)
        system.spreadingAngle = 180
        system.isLightingEnabled = false
        system.blendMode = .alpha
        system.dampingFactor = 1
        system.propertyControllers = [
            .opacity: fade(values: [0, 1, 0], times: [0, 0.15, 1]),
            .size: fade(values: [size, growTo], times: [0, 1]),
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
