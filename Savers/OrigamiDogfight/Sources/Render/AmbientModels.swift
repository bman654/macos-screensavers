// The countryside's models — a paper crane, a windmill, a sheep, a toy car — from the Blender
// library when it has them and folded in code when it does not, as every other model here is
// (`StandIns`). Each comes back with its moving parts found: a crane's two wings and a mill's
// sails.
//
// Sized by what they must measure on screen rather than by the diorama's fifty-to-one: a sheep at
// true scale is a speck of 2.6 cm that reads as nothing at all, so the small things are drawn a
// little larger than life and the mills a little smaller, all by eye.
//
// The library's moving parts follow the asset contract (`docs/origami-plan.md`): a child object,
// origin on its pivot, turning about its own X — a crane's wings lift at +a for `wing_l` and -a
// for `wing_r`, a mill's sails turn about their axle.

import AppKit
import Foundation
import SceneKit
import simd

/// A model with the parts that move, each with its rest orientation and the axis it turns about.
struct Articulated {
    struct Part {
        let node: SCNNode
        let rest: simd_quatf
        let axis: SIMD3<Float>

        func turn(by angle: Float) {
            node.simdOrientation = rest * simd_quatf(angle: angle, axis: axis)
        }
    }

    let node: SCNNode
    let parts: [String: Part]
}

final class AmbientModels {
    private let shelf: ModelShelf
    private var cache: [String: ModelTemplate] = [:]

    /// On-screen sizes, metres. A crane spans a little under a plane; a mill stands as tall as
    /// two houses; a sheep is a quarter of a house and a car a half.
    static let craneSpan: Float = 0.17
    static let millHeight: Float = 0.2
    static let sheepLength: Float = 0.034
    static let carLength: Float = 0.062

    init(shelf: ModelShelf) { self.shelf = shelf }

    func crane(paper: PaperColor) -> Articulated {
        let template = template("crane", anchor: .center) { AmbientModels.standInCrane() }
        let node = template.instance(size: AmbientModels.craneSpan, along: .footprint)
        repaint(node, colour: paper)
        return Articulated(node: node, parts: parts(of: node, named: ["wing_l", "wing_r"]))
    }

    /// How far the library mill's axle is raised toward the sky. A real mill's tilts back a few
    /// degrees; from a camera looking almost straight down, sails on a level axle are edge-on —
    /// a white bar pulsing as it turns — and the cross only shows in their shadow. Raised this
    /// far, and the mill faced toward the bottom of the screen (`Layout.windmills`), the camera
    /// sees them turn. The stand-in is folded with its axle raised already.
    static let axleRaise: Float = 20 * .pi / 180

    func windmill() -> Articulated {
        let template = template("windmill", anchor: .base) { AmbientModels.standInMill() }
        let node = template.instance(size: AmbientModels.millHeight, along: .height)
        var parts = parts(of: node, named: ["blades"])
        if !template.isStandIn, let blades = parts["blades"] {
            // In the part's own frame, which is Blender's: +X along the axle, +Y to the left, so
            // a turn about -Y lifts the axle's front end.
            let raised = blades.rest * simd_quatf(angle: -AmbientModels.axleRaise, axis: SIMD3(0, 1, 0))
            blades.node.simdOrientation = raised
            parts["blades"] = Articulated.Part(node: blades.node, rest: raised, axis: blades.axis)
        }
        return Articulated(node: node, parts: parts)
    }

    func sheep() -> SCNNode {
        template("sheep", anchor: .base) { AmbientModels.standInSheep() }
            .instance(size: AmbientModels.sheepLength, along: .footprint)
    }

    func car(paper: PaperColor) -> SCNNode {
        let node = template("car", anchor: .base) { AmbientModels.standInCar() }
            .instance(size: AmbientModels.carLength, along: .length)
        repaint(node, colour: paper)
        return node
    }

    /// Whether the library supplied this model, for the lineup's census.
    func isFromLibrary(_ name: String) -> Bool { shelf.library.has(name) }

    // MARK: Parts

    private func template(_ name: String, anchor: ModelAnchor, standIn: () -> ModelTemplate) -> ModelTemplate {
        if let hit = cache[name] { return hit }
        let made = shelf.library.names(ofKind: name).first.flatMap { shelf.library.template(named: $0, anchor: anchor) }
            ?? shelf.library.template(named: name, anchor: anchor) ?? standIn()
        cache[name] = made
        return made
    }

    /// The paper of a crane or a car is its own colour, like a plane's: every material named
    /// `paper` takes it, and whatever else the model has keeps the colour it was authored in.
    private func repaint(_ node: SCNNode, colour: PaperColor) {
        let skin = paperMaterial(colour)
        skin.name = "paper"
        node.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry, geometry.materials.contains(where: { $0.name == "paper" }),
                  let copy = geometry.copy() as? SCNGeometry else { return }
            copy.materials = geometry.materials.map { $0.name == "paper" ? skin : $0 }
            child.geometry = copy
        }
    }

    /// The named parts, each turning about its own X — the contract's axis, and the stand-ins'.
    private func parts(of node: SCNNode, named names: [String]) -> [String: Articulated.Part] {
        var found: [String: Articulated.Part] = [:]
        for name in names {
            guard let part = node.childNode(withName: name, recursively: true) else { continue }
            found[name] = Articulated.Part(node: part, rest: part.simdOrientation, axis: SIMD3(1, 0, 0))
        }
        return found
    }

    // MARK: Stand-ins

    /// Built in SceneKit's axes directly — front +X, up +Y, left -Z — at unit size.
    private static func standInCrane() -> ModelTemplate {
        let root = SCNNode()
        let paper = paperMaterial(PaperColor(0.96, 0.95, 0.92))
        paper.name = "paper"
        var body = FacetMesh()
        // The folded body: a flat diamond with a ridge, the neck and tail rising off its points.
        let nose = SIMD3<Float>(0.18, 0.02, 0), tail = SIMD3<Float>(-0.18, 0.02, 0)
        let ridge = SIMD3<Float>(0, 0.09, 0), keel = SIMD3<Float>(0, -0.06, 0)
        let l = SIMD3<Float>(0, 0.01, -0.06), r = SIMD3<Float>(0, 0.01, 0.06)
        for (a, b) in [(nose, l), (l, tail), (tail, r), (r, nose)] {
            body.triangle(a, b, ridge)
            body.triangle(b, a, keel)
        }
        let neckTip = SIMD3<Float>(0.42, 0.26, 0), head = SIMD3<Float>(0.50, 0.21, 0)
        body.triangle(nose, SIMD3(0.12, 0.05, -0.012), neckTip)
        body.triangle(SIMD3(0.12, 0.05, 0.012), nose, neckTip)
        body.triangle(neckTip, SIMD3(0.40, 0.25, 0.01), head)
        let tailTip = SIMD3<Float>(-0.46, 0.24, 0)
        body.triangle(SIMD3(-0.12, 0.05, -0.012), tail, tailTip)
        body.triangle(tail, SIMD3(-0.12, 0.05, 0.012), tailTip)
        root.addChildNode(SCNNode(geometry: body.geometry(materials: [paper])))
        // The wings: long folded triangles hinged along the body's ridge, swept back a little.
        for (name, side) in [("wing_l", Float(-1)), ("wing_r", Float(1))] {
            var wing = FacetMesh()
            let front = SIMD3<Float>(0.1, 0, 0), back = SIMD3<Float>(-0.1, 0, 0)
            let mid = SIMD3<Float>(-0.04, 0.025, side * 0.24), tip = SIMD3<Float>(-0.16, 0.0, side * 0.5)
            wing.triangle(front, back, mid)
            wing.triangle(back, tip, mid)
            wing.triangle(front, mid, tip)
            let node = SCNNode(geometry: wing.geometry(materials: [paper]))
            node.name = name
            node.simdPosition = SIMD3(0, 0.06, 0)
            root.addChildNode(node)
        }
        return ModelTemplate(node: root, extent: SIMD3(0.96, 0.4, 1.0), sheetAspect: 1, isStandIn: true)
    }

    /// A tower mill: a tapering paper tower, a cap, and four sails on an axle tilted up toward
    /// the sky, so a camera looking down sees them turn rather than a line.
    private static func standInMill() -> ModelTemplate {
        var tower = FacetMesh()
        let wall = linearRGBA(PaperColor(0.95, 0.92, 0.84))
        let sides = 6
        for k in 0..<sides {
            let a0 = Float(k) / Float(sides) * 2 * .pi, a1 = Float(k + 1) / Float(sides) * 2 * .pi
            let b0 = SIMD3(cos(a0) * 0.16, 0, sin(a0) * 0.16), b1 = SIMD3(cos(a1) * 0.16, 0, sin(a1) * 0.16)
            let t0 = SIMD3(cos(a0) * 0.1, 0.72, sin(a0) * 0.1), t1 = SIMD3(cos(a1) * 0.1, 0.72, sin(a1) * 0.1)
            tower.quad(b1, b0, t0, t1, color: wall)
        }
        StandIns.addCone(&tower, sides: 6, radius: 0.13, bottom: 0.7, apex: 0.9,
                         color: linearRGBA(PaperColor(0.62, 0.30, 0.22)))
        let white = paperMaterial(PaperColor(1, 1, 1))
        let root = SCNNode(geometry: tower.geometry(materials: [white]))

        var sails = FacetMesh()
        let cloth = linearRGBA(PaperColor(0.97, 0.96, 0.92))
        for k in 0..<4 {
            let a = Float(k) * .pi / 2
            let along = SIMD3<Float>(0, cos(a), sin(a)), across = SIMD3<Float>(0, -sin(a), cos(a))
            let inner = along * 0.06, outer = along * 0.46
            sails.quad(inner, inner + across * 0.09, outer + across * 0.09, outer, color: cloth)
            sails.quad(inner, outer, outer + across * 0.09, inner + across * 0.09, color: cloth)
        }
        let blades = SCNNode(geometry: sails.geometry(materials: [white]))
        blades.name = "blades"
        blades.simdPosition = SIMD3(0.17, 0.74, 0)
        // Axle along +X, raised 35° toward the sky.
        blades.simdOrientation = simd_quatf(angle: 0.6, axis: SIMD3(0, 0, 1))
        root.addChildNode(blades)
        return StandIns.based(root)
    }

    private static func standInSheep() -> ModelTemplate {
        var mesh = FacetMesh()
        // A fleece longer than it is wide: two crumpled balls run together, and a dark face.
        let fleece = linearRGBA(PaperColor(0.95, 0.94, 0.90))
        for (x, seed) in [(Float(-0.13), UInt64(41)), (0.1, 42)] {
            StandIns.addIcosphere(&mesh, center: SIMD3(x, 0.42, 0), radius: 0.3, subdivisions: 1, crumple: 0.12,
                                  seed: seed, color: fleece, squash: 0.85)
        }
        StandIns.addIcosphere(&mesh, center: SIMD3(0.5, 0.5, 0), radius: 0.15, subdivisions: 0, crumple: 0.1,
                              seed: 43, color: linearRGBA(PaperColor(0.20, 0.18, 0.17)))
        return StandIns.based(SCNNode(geometry: mesh.geometry(materials: [paperMaterial(PaperColor(1, 1, 1))])))
    }

    private static func standInCar() -> ModelTemplate {
        var body = FacetMesh()
        StandIns.addBox(&body, min: SIMD3(-0.5, 0.06, -0.21), max: SIMD3(0.5, 0.3, 0.21))
        StandIns.addBox(&body, min: SIMD3(-0.28, 0.3, -0.18), max: SIMD3(0.18, 0.5, 0.18), bevelTop: 0.25)
        let paper = paperMaterial(PaperColor(0.9, 0.3, 0.25))
        paper.name = "paper"
        var wheels = FacetMesh()
        for x: Float in [-0.3, 0.3] {
            for z: Float in [-0.22, 0.17] {
                StandIns.addBox(&wheels, min: SIMD3(x - 0.1, 0, z), max: SIMD3(x + 0.1, 0.16, z + 0.05))
            }
        }
        let root = SCNNode(geometry: body.geometry(materials: [paper]))
        root.addChildNode(SCNNode(geometry: wheels.geometry(materials: [paperMaterial(PaperColor(0.2, 0.2, 0.22))])))
        return StandIns.based(root)
    }
}
