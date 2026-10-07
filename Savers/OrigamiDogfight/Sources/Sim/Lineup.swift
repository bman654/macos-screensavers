// A frozen tableau of everything the renderer can draw, for looking at models rather than at a
// fight: `ORIGAMI_LINEUP=1`. Harness only — the environment is empty in the real host.
//
// It is staged *in the sim* so it goes through exactly the renderer path a fight does: if a
// plane is drawn backwards, banked the wrong way or the wrong size here, it is wrong in the fight.

import Foundation
import simd

extension DogfightSim {
    func stageLineup() {
        isFrozen = true
        isLineup = true
        planes.removeAll()
        tanks.removeAll()
        projectiles.removeAll()
        wrecks.removeAll()
        let papers: [Paper] = [Paper(kind: .notebook, tint: 0), Paper(kind: .graph, tint: 0),
                               Paper(kind: .newspaper, tint: 0), Paper(kind: .kraft, tint: 0),
                               Paper(kind: .plain, tint: 0)]
        let now = time
        for (index, type) in PlaneType.allCases.enumerated() {
            let x = -1.8 + Float(index) * 0.9
            // Top row level, heading east (screen right); second row banked into a left turn,
            // heading north (screen up), so the raised wing is on the right of the screen.
            for (row, heading, bank, paper) in [(Float(0.85), Float(0), Float(0), papers[index]),
                                                (0.2, .pi / 2, 0.8, Paper(kind: .plain, tint: index + 1))] {
                let pose = Pose(position: SIMD2(x, row), altitude: ViewRig.bandMid, heading: heading, bank: bank, pitch: 0)
                let spec = type.spec(scale: 1)
                planes.append(Plane(id: makeID(), slot: 0, side: index, type: type, weapon: spec.weapons[0],
                                    paper: paper, spec: spec, state: .fighting, stateSince: now,
                                    pose: pose, previous: pose, speed: spec.cruiseSpeed,
                                    health: spec.armour, pilot: PilotMemory(lastShotAt: now, cruiseAltitude: ViewRig.bandMid)))
            }
        }
        for (index, kind) in WeaponKind.allCases.enumerated() {
            let x = -1.9 + Float(index) * 0.48
            for landed in [false, true] {
                let p = SIMD2<Float>(x, landed ? -0.75 : -0.35)
                let altitude = landed ? terrain.surfaceHeight(at: p) : ViewRig.bandMid
                var shot = Projectile(id: makeID(), kind: kind, owner: 0, side: 0, paper: papers[index % papers.count],
                                      scale: 1, spin: SIMD3(0, 0, 1e-6), position: p, altitude: altitude,
                                      previousPosition: p, previousAltitude: altitude,
                                      velocity: SIMD2(1, 0), climb: 0)
                if landed { shot.state = .landed(at: 0); shot.age = 1 }
                projectiles.append(shot)
            }
        }
        for (index, age) in [1.0, 6.0, Wreck.fireDuration + 0.6, Wreck.fireDuration + Wreck.foldDuration + 1].enumerated() {
            let p = SIMD2<Float>(-1.5 + Float(index) * 1.0, -1.15)
            wrecks.append(Wreck(id: makeID(), model: .plane(PlaneType.allCases[index]), paper: papers[index], scale: 1,
                                position: p, ground: terrain.surfaceHeight(at: p), heading: 0, roll: 0.2,
                                crashedAt: now - age, inWater: false))
        }
        // Both tanks, one per row of team colour, turret turned off the hull's line so the
        // turret's pivot is checked too; and a knocked-out one burning.
        for (index, type) in TankType.allCases.enumerated() {
            let p = SIMD2<Float>(1.6 + Float(index) * 0.5, -1.15)
            let spec = type.spec(scale: 1)
            let altitude = terrain.surfaceHeight(at: p)
            tanks.append(Tank(id: makeID(), slot: 0, side: index, type: type, paper: Paper(kind: .plain, tint: index),
                              spec: spec, state: .patrol, stateSince: now, position: p, previousPosition: p,
                              altitude: altitude, heading: 0, previousHeading: 0, turret: 0.7, previousTurret: 0.7,
                              health: spec.armour, progressCheckAt: now, lastMovedAt: now))
        }
        let burning = SIMD2<Float>(2.6, -1.15)
        wrecks.append(Wreck(id: makeID(), model: .tank(.light), paper: Paper(kind: .plain, tint: 2), scale: 1,
                            position: burning, ground: terrain.surfaceHeight(at: burning), heading: 0.4, roll: 0.1,
                            turret: 0.9, crashedAt: now - 4, inWater: false))
    }
}
