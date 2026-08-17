// The moving decorations and the bubble streams authored into them.
//
// A stream has two deliberately separate nodes. Its source is the named empty inside the model,
// where Blender put it and whatever articulated part carries it. Its anchor is an unrotated child
// of the reef. The source supplies only a position; the anchor supplies the coordinate system in
// which SceneKit simulates the particles. That separation is what keeps "up" aligned with the
// tank after prop yaw, tilt, Blender's axis correction and instance scale have all had their say.

import AppKit
import SceneKit

final class Bubbler {
    private let streams: [BubbleStream]
    private let cycle: PropCyclePlayer?

    init(prop: PropInstance, reefNode: SCNNode, particlesEnabled: Bool, rand: inout Rand) {
        var parts: [String: MovingPart] = [:]
        for spec in prop.manifest.parts {
            guard let node = prop.root.childNode(withName: spec.node, recursively: true) else {
                continue
            }
            let part = MovingPart(spec: spec, node: node)
            part.set(normalized: 0)
            parts[spec.node] = part
        }

        var streamsByName: [String: BubbleStream] = [:]
        if particlesEnabled {
            for spec in prop.manifest.emitters {
                guard let source = prop.root.childNode(withName: spec.node, recursively: true) else {
                    continue
                }
                streamsByName[spec.node] = BubbleStream(
                    spec: spec, scale: prop.placement.scale, source: source, reefNode: reefNode)
            }
        }
        streams = Array(streamsByName.values)

        if prop.manifest.cycle.isEmpty {
            cycle = nil
        } else {
            cycle = PropCyclePlayer(phases: prop.manifest.cycle, parts: parts,
                                    streams: streamsByName, rand: &rand)
        }

        streams.forEach { $0.trackSource() }
    }

    func update(dt: Float) {
        cycle?.update(dt: dt)
        // The part has already reached this frame's pose, so the first bubble born from an opening
        // lid leaves its new position rather than trailing the hinge by one frame.
        streams.forEach { $0.trackSource() }
    }

    /// Particles per second this prop is emitting right now, summed over its live streams.
    ///
    /// The audio bed's density is derived from this rather than from a constant, which is what
    /// makes the sound belong to the tank that was actually drawn: a launch with a thermal vent
    /// bubbles continuously, one with only a treasure chest is quiet between its puffs, and one
    /// with neither gets nothing but the ambient trickle. The declared birth rate is the honest
    /// unit here — it is what the picture is doing — and `AquariumSound` decides what fraction
    /// of it is audible, since most of what an aerator releases is too small to hear.
    var emissionRate: Float {
        streams.reduce(0) { $0 + $1.liveRate }
    }
}

private final class MovingPart {
    let spec: PartSpec
    private let node: SCNNode
    private(set) var normalized: Float = 0

    init(spec: PartSpec, node: SCNNode) {
        self.spec = spec
        self.node = node
    }

    func set(normalized: Float) {
        self.normalized = min(max(normalized, 0), 1)
        node.rotation = SCNVector4(spec.axis.x, spec.axis.y, spec.axis.z,
                                   self.normalized * spec.openRadians)
    }
}

private final class BubbleStream {
    private let spec: EmitterSpec
    private let source: SCNNode
    private let reefNode: SCNNode
    private let anchor = SCNNode()
    private let particles = SCNParticleSystem()

    init(spec: EmitterSpec, scale: Float, source: SCNNode, reefNode: SCNNode) {
        self.spec = spec
        self.source = source
        self.reefNode = reefNode
        // A prop with no authored cycle is never told to start, so its opening state has to
        // agree with the birth rate set below or the sound would report silence over a visibly
        // running vent.
        isActive = spec.continuous

        let lowerSize = max(0, spec.size.lower * scale)
        let upperSize = max(lowerSize, spec.size.upper * scale)
        let speed = max(0, spec.speed * scale)

        particles.particleImage = BubbleStream.sprite
        particles.birthRate = spec.continuous ? CGFloat(max(0, spec.rate)) : 0
        particles.particleLifeSpan = 11
        particles.particleLifeSpanVariation = 2.5
        particles.particleSize = CGFloat((lowerSize + upperSize) / 2)
        particles.particleSizeVariation = CGFloat((upperSize - lowerSize) / 2)
        particles.particleColor = NSColor(calibratedRed: 0.76, green: 0.91, blue: 1,
                                          alpha: 0.82)
        particles.particleColorVariation = SCNVector4(0.04, 0.03, 0, 0.18)
        particles.particleVelocity = CGFloat(speed)
        particles.particleVelocityVariation = CGFloat(speed * 0.24)
        particles.emittingDirection = SCNVector3(0, 1, 0)
        particles.spreadingAngle = 13
        particles.emitterShape = SCNSphere(radius: CGFloat(max(0, spec.radius * scale)))
        particles.birthLocation = .volume
        particles.loops = true
        particles.isLightingEnabled = false
        particles.isAffectedByGravity = false
        // SceneKit's default is world-space simulation, but stating it is load-bearing here: a
        // local stream would drag every emitted bubble sideways whenever a lid moved its source.
        particles.isLocal = false
        // A narrow cone is still a rigid cone unless the particles lose some launch speed. Mild
        // damping turns it into the widening, lingering plume visible above an aerator without
        // letting a short burst fill the whole water column for the rest of the cycle.
        particles.dampingFactor = 0.08
        particles.blendMode = .alpha

        anchor.addParticleSystem(particles)
        reefNode.addChildNode(anchor)
    }

    private(set) var isActive: Bool

    func setActive(_ active: Bool) {
        isActive = active
        particles.birthRate = active ? CGFloat(max(0, spec.rate)) : 0
    }

    var liveRate: Float { isActive ? max(0, spec.rate) : 0 }

    func trackSource() {
        anchor.position = source.convertPosition(SCNVector3Zero, to: reefNode)
    }

    private static let sprite: NSImage = {
        let diameter: CGFloat = 64
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()

        let rimRect = NSRect(x: 7, y: 7, width: diameter - 14, height: diameter - 14)
        let rim = NSBezierPath(ovalIn: rimRect)
        rim.lineWidth = 4
        NSColor(calibratedRed: 0.75, green: 0.9, blue: 1, alpha: 0.68).setStroke()
        rim.stroke()

        // The broken bright arc is what reads as a reflecting rim at particle size. Filling the
        // centre, even faintly, turns the same sprite into marine snow once bloom softens it.
        let highlight = NSBezierPath()
        highlight.appendArc(withCenter: NSPoint(x: diameter * 0.45, y: diameter * 0.54),
                            radius: diameter * 0.31, startAngle: 82, endAngle: 158)
        highlight.lineWidth = 6
        highlight.lineCapStyle = .round
        NSColor(calibratedWhite: 1, alpha: 0.96).setStroke()
        highlight.stroke()

        image.unlockFocus()
        return image
    }()
}

private final class PropCyclePlayer {
    private let phases: [CyclePhase]
    private let parts: [String: MovingPart]
    private let streams: [String: BubbleStream]
    private var rand: Rand

    private var phaseIndex: Int
    private var phaseDuration: Float = 0
    private var elapsed: Float = 0
    private var moveStart: Float = 0

    /// DIAGNOSTIC, `AQUARIUM_BUBBLER_RUSH=1`. It collapses idle phases to 0.18 seconds so a
    /// four-second capture exercises several complete cycles; the movement and emission timing
    /// remain authored values, since speeding those up would make the diagnostic judge a motion
    /// the saver never performs.
    private static let rush = ProcessInfo.processInfo.environment["AQUARIUM_BUBBLER_RUSH"] == "1"

    init(phases: [CyclePhase], parts: [String: MovingPart],
         streams: [String: BubbleStream], rand: inout Rand) {
        self.phases = phases
        self.parts = parts
        self.streams = streams
        self.rand = rand

        let draw = Int(self.rand.next() * Float(phases.count))
        phaseIndex = min(draw, phases.count - 1)

        parts.values.forEach { $0.set(normalized: 0) }
        for index in 0..<phaseIndex { complete(phases[index]) }
        beginCurrentPhase()
        if phaseDuration > 0 {
            elapsed = self.rand.inRange(0, phaseDuration)
            applyCurrentPhase()
        }

        rand = self.rand
    }

    func update(dt: Float) {
        var remaining = max(0, dt)
        var transitions = 0

        while remaining > 0 || phaseDuration <= 0 {
            if phaseDuration > 0 {
                let step = min(remaining, max(0, phaseDuration - elapsed))
                elapsed += step
                remaining -= step
                applyCurrentPhase()
                if elapsed < phaseDuration { break }
            } else {
                applyCurrentPhase(completed: true)
            }

            advancePhase()
            transitions += 1
            // A malformed all-zero cycle must not spin forever inside legacyScreenSaver. One
            // complete pass leaves every phase represented and bounds the work to manifest size.
            if transitions > phases.count { break }
        }
    }

    private func advancePhase() {
        complete(phases[phaseIndex])
        phaseIndex = (phaseIndex + 1) % phases.count
        beginCurrentPhase()
    }

    private func beginCurrentPhase() {
        let phase = phases[phaseIndex]
        if phase.phase == .idle { parts.values.forEach { $0.set(normalized: 0) } }
        phaseDuration = PropCyclePlayer.rush && phase.phase == .idle
            ? 0.18
            : phase.duration.sample(&rand)
        elapsed = 0
        moveStart = phase.part.flatMap { parts[$0]?.normalized } ?? 0
        setEmission(for: phase)
        applyCurrentPhase()
    }

    private func applyCurrentPhase(completed: Bool = false) {
        let phase = phases[phaseIndex]
        guard phase.phase == .move,
              let name = phase.part,
              let part = parts[name]
        else { return }

        let progress = completed || phaseDuration <= 0 ? 1 : elapsed / phaseDuration
        let target = min(max(phase.to ?? part.normalized, 0), 1)
        part.set(normalized: moveStart + (target - moveStart) * phase.ease.apply(progress))
    }

    private func complete(_ phase: CyclePhase) {
        switch phase.phase {
        case .idle:
            parts.values.forEach { $0.set(normalized: 0) }
        case .move:
            guard let name = phase.part, let part = parts[name] else { return }
            part.set(normalized: phase.to ?? part.normalized)
        case .emit:
            break
        }
    }

    private func setEmission(for phase: CyclePhase) {
        for (name, stream) in streams {
            let isCycleEmitter = phase.phase == .emit && phase.emitter == name
            stream.setActive(stream.specIsContinuous || isCycleEmitter)
        }
    }
}

private extension BubbleStream {
    var specIsContinuous: Bool { spec.continuous }
}
