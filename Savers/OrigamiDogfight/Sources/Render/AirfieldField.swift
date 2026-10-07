// The airfields, as nodes: a paper runway strip draped on the ground with a dashed centre line,
// and a hangar tinted in its team's colour at the end of it (`Airfield.swift` decides where).
//
// They are part of the match, not the landscape, so they arrive and leave with it: at the start
// the runway unrolls out of the hangar door like a strip of paper off a roll, and the hangar pops
// up behind it the way a pop-up book's building does; at the end, as the survivors leave, the
// hangar folds flat and the strip rolls back up. All of it is a function of the match's clock, so
// a scene rebuilt mid-match picks up where it was.

import AppKit
import CoreGraphics
import Foundation
import SceneKit
import simd

final class AirfieldField {
    let root = SCNNode()
    private let shelf: ModelShelf
    private let papers: PaperMaterials
    private var runwayMaterials: [Int: SCNMaterial] = [:]

    private final class Visual {
        let base: Airfield
        let runway: SCNNode
        let roll: SCNNode
        let hangar: SCNNode
        /// The runway as last built, so it is rebuilt only while it is moving.
        var progress: Float = -1
        init(base: Airfield, runway: SCNNode, roll: SCNNode, hangar: SCNNode) {
            self.base = base
            self.runway = runway
            self.roll = roll
            self.hangar = hangar
        }
    }

    private var visuals: [Visual] = []
    /// Which match, and which airfields, the visuals were built for.
    private var builtFor: (match: Int, bases: [Airfield?])?

    /// The strip lies this far above the ground it is draped on: clear of the facets between the
    /// samples it is draped through, under a plane's keel on its roll.
    private static let lift: Float = 0.004

    init(shelf: ModelShelf, papers: PaperMaterials) {
        self.shelf = shelf
        self.papers = papers
    }

    func sync(_ sim: DogfightSim, now: Double) {
        let match = sim.match
        if builtFor.map({ $0.match != match.index || $0.bases != match.bases }) ?? true {
            for visual in visuals {
                visual.runway.removeFromParentNode()
                visual.roll.removeFromParentNode()
                visual.hangar.removeFromParentNode()
            }
            visuals = match.bases.compactMap { $0 }.map { base in
                make(base, paper: match.slots.first { $0.side == base.side }?.paper, terrain: sim.terrain)
            }
            builtFor = (match.index, match.bases)
        }
        // How unfolded: 0 flat and rolled up, 1 standing. Out at the start, back in from the
        // moment the survivors turn for home.
        var open = Float(min(max((now - match.startedAt) / Airfield.unfoldTime, 0), 1))
        if let since = match.endingSince {
            open = min(open, 1 - Float(min(max((now - since) / Airfield.foldTime, 0), 1)))
        }
        if case .intermission = match.phase { open = 0 }
        for visual in visuals { animate(visual, open: open, terrain: sim.terrain) }
    }

    private func make(_ base: Airfield, paper: Paper?, terrain: Terrain) -> Visual {
        let team = paper ?? Paper(kind: .plain, tint: base.side)
        let runway = SCNNode()
        runway.castsShadow = false
        root.addChildNode(runway)

        let roll = SCNNode(geometry: SCNCylinder(radius: 1, height: CGFloat(base.runwayWidth)))
        roll.geometry?.materials = [runwayMaterial(team)]
        roll.castsShadow = false
        root.addChildNode(roll)

        let template = shelf.hangar()
        let hangar = template.instance(size: base.hangarLength, along: .length)
        let skin = papers.material(for: team, aspect: CGFloat(template.sheetAspect))
        hangar.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry, geometry.materials.contains(where: { $0.name == "paper" }),
                  let copy = geometry.copy() as? SCNGeometry else { return }
            // Only the stripe takes the team's colour (the asset contract); roof, walls and door
            // keep their authored materials, which the seasons recolour by name.
            copy.materials = geometry.materials.map { $0.name == "paper" ? skin : $0 }
            node.geometry = copy
        }
        // Sitting on the highest ground under its corners, so no corner is buried.
        let d = base.direction, n = SIMD2(-d.y, d.x)
        let along = d * (base.hangarLength / 2), across = n * (base.hangarWidth / 2)
        let corners: [SIMD2<Float>] = [base.hangar + along + across, base.hangar + along - across,
                                       base.hangar - along + across, base.hangar - along - across]
        let ground = corners.map(terrain.surfaceHeight(at:)).max() ?? terrain.surfaceHeight(at: base.hangar)
        hangar.simdPosition = base.hangar.scene(altitude: ground)
        hangar.simdOrientation = simd_quatf(angle: base.heading, axis: SIMD3(0, 1, 0))
        root.addChildNode(hangar)
        return Visual(base: base, runway: runway, roll: roll, hangar: hangar)
    }

    private func animate(_ visual: Visual, open: Float, terrain: Terrain) {
        // The runway unrolls over the first two thirds; the hangar pops up over the rest, with a
        // little overshoot, the way card springs up off a page. Folding runs the same backwards.
        let unrolled = smoothstep(0, 0.68, open)
        let popped = Float(min(max((open - 0.4) / 0.6, 0), 1))
        let overshoot = 1 + 0.12 * sin(.pi * popped) * popped
        visual.hangar.isHidden = popped <= 0
        visual.hangar.simdScale = SIMD3(1, max(popped * overshoot, 0.01), 1)

        visual.runway.isHidden = unrolled <= 0
        let progress = (unrolled * 50).rounded() / 50
        if progress != visual.progress, progress > 0 {
            visual.runway.geometry = strip(visual.base, progress: progress, terrain: terrain,
                                           material: visual.roll.geometry?.firstMaterial)
            visual.progress = progress
        }
        // The roll still to unwind sits at the strip's front edge, thinner as it goes.
        let base = visual.base
        visual.roll.isHidden = unrolled <= 0 || unrolled >= 1
        if !visual.roll.isHidden {
            let radius = base.runwayWidth * (0.04 + 0.11 * (1 - unrolled))
            let front = base.door + base.direction * base.runwayLength * unrolled
            visual.roll.simdScale = SIMD3(radius, 1, radius)
            visual.roll.simdPosition = front.scene(altitude: terrain.surfaceHeight(at: front) + radius + AirfieldField.lift)
            let across = SIMD3(-base.direction.y, 0, -base.direction.x)
            visual.roll.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: across)
        }
    }

    /// The first `progress` of the strip, draped over the ground: a quad strip down its length,
    /// three vertices across, each lifted a little off the terrain under it.
    private func strip(_ base: Airfield, progress: Float, terrain: Terrain, material: SCNMaterial?) -> SCNGeometry {
        var mesh = FacetMesh()
        let d = base.direction, n = SIMD2(-d.y, d.x)
        let length = base.runwayLength * progress
        let segments = max(Int(ceil(length / 0.035)), 1)
        func vertex(_ s: Float, _ t: Float) -> (SIMD3<Float>, SIMD2<Float>) {
            let p = base.door + d * s + n * t * base.runwayWidth / 2
            // u across the strip, v along it in the strip's own length, so the dashes do not
            // stretch as it unrolls.
            return (p.scene(altitude: terrain.surfaceHeight(at: p) + AirfieldField.lift),
                    SIMD2(0.5 + t / 2, s / base.runwayLength))
        }
        for k in 0..<segments {
            let s0 = length * Float(k) / Float(segments), s1 = length * Float(k + 1) / Float(segments)
            for (t0, t1) in [(Float(-1), Float(0)), (0, 1)] {
                let a = vertex(s0, t0), b = vertex(s0, t1), c = vertex(s1, t1), e = vertex(s1, t0)
                // Counter-clockwise seen from above.
                mesh.triangle(a.0, c.0, b.0, uv: (a.1, c.1, b.1))
                mesh.triangle(a.0, e.0, c.0, uv: (a.1, e.1, c.1))
            }
        }
        return mesh.geometry(materials: [material ?? paperMaterial(PaperColor(0.36, 0.36, 0.38))])
    }

    /// Charcoal card with a dashed white centre line, white edges, and the team's colour across
    /// both ends, drawn once per team.
    private func runwayMaterial(_ paper: Paper) -> SCNMaterial {
        let key = paper.kind.rawValue * 100 + paper.tint
        if let hit = runwayMaterials[key] { return hit }
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = true
        if let image = AirfieldField.runwayImage(team: PaperPalette.base(paper)) {
            material.diffuse.contents = image
            material.diffuse.mipFilter = .linear
            material.diffuse.maxAnisotropy = 8
        } else {
            material.diffuse.contents = PaperColor(0.36, 0.36, 0.38).ns
        }
        runwayMaterials[key] = material
        return material
    }

    private static func runwayImage(team: PaperColor, width: Int = 64, height: Int = 512) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(PaperColor(0.36, 0.36, 0.38).cg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Construction-paper grain, so the strip is paper and not tarmac.
        var rand = Rand(seed: 0x52_55_4E_57)
        for _ in 0..<500 {
            ctx.setFillColor(PaperColor(0.36, 0.36, 0.38).scaled(CGFloat(rand.inRange(0.88, 1.12))).cg)
            ctx.fill(CGRect(x: CGFloat(rand.next()) * w, y: CGFloat(rand.next()) * h, width: 2, height: 2))
        }
        let white = PaperColor(0.96, 0.95, 0.90).cg
        ctx.setFillColor(white)
        ctx.fill(CGRect(x: w * 0.07, y: 0, width: w * 0.05, height: h))
        ctx.fill(CGRect(x: w * 0.88, y: 0, width: w * 0.05, height: h))
        // The dashed centre line.
        let dashes = 9
        let run = h * 0.74 / CGFloat(dashes)
        for k in 0..<dashes {
            ctx.fill(CGRect(x: w * 0.46, y: h * 0.13 + CGFloat(k) * run, width: w * 0.08, height: run * 0.55))
        }
        // Threshold bars and the team's colour at both ends, so it reads the same either way up.
        for end in [CGFloat(0), 1] {
            ctx.setFillColor(team.cg)
            ctx.fill(CGRect(x: 0, y: end == 0 ? 0 : h * 0.965, width: w, height: h * 0.035))
            ctx.setFillColor(white)
            for k in 0..<4 {
                let x = w * (0.17 + CGFloat(k) * 0.18)
                ctx.fill(CGRect(x: x, y: end == 0 ? h * 0.045 : h * 0.905, width: w * 0.09, height: h * 0.05))
            }
        }
        return ctx.makeImage()
    }
}
