// The paper cranes, as nodes: a flock built when it sets off and thrown away once it has crossed,
// every bird posed from `CraneFlock`'s formula and flapping on its own beat.
//
// They cast shadows like the planes do — a crane's shadow crossing the fight is half of what
// makes a flock read as passing over it rather than as a sticker on the glass.

import AppKit
import Foundation
import SceneKit
import simd

final class CraneFlight {
    let root = SCNNode()
    private let models: AmbientModels
    private var flocks: [Double: [Articulated]] = [:]

    /// Paler than any team's paper, so a crane is never mistaken for a plane on a side: white,
    /// blush, a pale gold and a pale blue, the colours a string of folded cranes comes in.
    private static let papers = [PaperColor(0.97, 0.96, 0.93), PaperColor(0.97, 0.80, 0.82),
                                 PaperColor(0.96, 0.88, 0.62), PaperColor(0.78, 0.87, 0.96)]

    init(models: AmbientModels) { self.models = models }

    func update(_ schedule: CraneSchedule, time: Double) {
        var live = Set<Double>()
        for flock in schedule.flocks where time >= flock.start {
            live.insert(flock.start)
            let birds = flocks[flock.start] ?? make(flock)
            flocks[flock.start] = birds
            let t = time - flock.start
            for (index, bird) in birds.enumerated() {
                let pose = flock.pose(of: index, at: t)
                let member = flock.members[index]
                bird.node.simdPosition = pose.position.scene(altitude: pose.altitude)
                // Banking a touch with the formation's sway, nose a touch up on the downstroke.
                let beat = Double(member.flapRate)
                bird.node.simdOrientation = simd_quatf(angle: pose.heading, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: 0.05 * wave(time, rate: beat, phase: Double(member.flapPhase) + 1), axis: SIMD3(0, 0, 1))
                // Flapping, with a glide now and then: the beat's depth swells and fades on a slow
                // clock of its own, so a flock is never all flapping in time.
                let glide = 0.25 + 0.75 * smoothstep(-0.3, 0.6, wave(time, rate: 0.45, phase: Double(member.flapPhase) * 3))
                let flap = 0.12 + 0.55 * glide * wave(time, rate: beat, phase: Double(member.flapPhase))
                bird.parts["wing_l"]?.turn(by: flap)
                bird.parts["wing_r"]?.turn(by: -flap)
            }
        }
        for (start, birds) in flocks where !live.contains(start) {
            for bird in birds { bird.node.removeFromParentNode() }
            flocks[start] = nil
        }
    }

    private func make(_ flock: CraneFlock) -> [Articulated] {
        flock.members.map { member in
            let bird = models.crane(paper: CraneFlight.papers[member.paper % CraneFlight.papers.count])
            bird.node.simdScale *= member.size
            root.addChildNode(bird.node)
            return bird
        }
    }
}
