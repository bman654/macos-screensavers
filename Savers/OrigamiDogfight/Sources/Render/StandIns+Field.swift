// Code-built supply crate, parachute and hangar, for a library that lacks them.
//
// Authored to the same contract as the Blender ones (`docs/origami-plan.md`, asset contract):
// the crate stands on its base; the parachute's origin is the knot where its strings meet, the
// canopy above it; the hangar opens toward +X with its team stripe in material `paper`. So the
// renderer places and tints either the same way.

import AppKit
import Foundation
import SceneKit
import simd

extension StandIns {

    /// A kraft-paper box with a darker strap round it, at its authored size.
    static func crate() -> ModelTemplate {
        var mesh = FacetMesh()
        let kraft = linearRGBA(PaperColor(0.74, 0.56, 0.36))
        let strap = linearRGBA(PaperColor(0.52, 0.36, 0.22))
        let h: Float = 0.026, top: Float = 0.044
        addBox(&mesh, min: SIMD3(-h, 0, -h), max: SIMD3(h, top, h), color: kraft)
        addBox(&mesh, min: SIMD3(-h * 1.02, 0, -0.005), max: SIMD3(h * 1.02, top * 1.02, 0.005), color: strap)
        addBox(&mesh, min: SIMD3(-0.005, 0, -h * 1.02), max: SIMD3(0.005, top * 1.02, h * 1.02), color: strap)
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = NSColor.white
        return based(SCNNode(geometry: mesh.geometry(materials: [material])))
    }

    /// A tissue-paper canopy of alternating pale gores over four strings, its origin at the knot.
    static func parachute() -> ModelTemplate {
        var mesh = FacetMesh()
        let gores = 8
        let radius: Float = 0.056, rim: Float = 0.105, crown: Float = 0.14
        let light = linearRGBA(PaperColor(0.98, 0.96, 0.94)), stripe = linearRGBA(PaperColor(0.96, 0.62, 0.66))
        for k in 0..<gores {
            let a0 = Float(k) / Float(gores) * 2 * .pi, a1 = Float(k + 1) / Float(gores) * 2 * .pi
            let p0 = SIMD3(cos(a0) * radius, rim, sin(a0) * radius), p1 = SIMD3(cos(a1) * radius, rim, sin(a1) * radius)
            let mid = SIMD3(cos((a0 + a1) / 2) * radius * 0.7, crown - 0.01, sin((a0 + a1) / 2) * radius * 0.7)
            let colour = k % 2 == 0 ? light : stripe
            mesh.triangle(p0, mid, p1, color: colour)
            mesh.triangle(mid, SIMD3(0, crown, 0), p1, color: colour)
            mesh.triangle(p0, SIMD3(0, crown, 0), mid, color: colour)
        }
        let canopy = SCNMaterial()
        canopy.lightingModel = .lambert
        canopy.diffuse.contents = NSColor.white
        canopy.isDoubleSided = true
        let node = SCNNode(geometry: mesh.geometry(materials: [canopy]))
        // Strings from the knot to four points of the rim.
        var lines: [SIMD3<Float>] = []
        for k in 0..<4 {
            let a = Float(k) * .pi / 2 + .pi / 8
            lines += [.zero, SIMD3(cos(a) * radius, rim, sin(a) * radius)]
        }
        let source = SCNGeometrySource(vertices: lines.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: Array(0..<UInt16(lines.count)), primitiveType: .line)
        let strings = SCNGeometry(sources: [source], elements: [element])
        strings.materials = [paperMaterial(PaperColor(0.85, 0.84, 0.80))]
        node.addChildNode(SCNNode(geometry: strings))
        // The knot is the origin, not the base of the bounds: wrap without re-anchoring.
        let holder = SCNNode()
        holder.addChildNode(node)
        return ModelTemplate(node: holder, extent: SIMD3(radius * 2, crown, radius * 2), sheetAspect: 1, isStandIn: true)
    }

    /// A round-roofed hangar, open toward +X, its ridge stripe in material `paper`.
    static func hangar() -> ModelTemplate {
        let length: Float = 1.4, width: Float = 1.02, height: Float = 0.5
        let sides = 8
        var roof = FacetMesh(), stripe = FacetMesh(), inside = FacetMesh()
        func arch(_ k: Int) -> (Float, Float) {
            let a = Float.pi * Float(k) / Float(sides)
            return (cos(a) * width / 2, sin(a) * height)
        }
        for k in 0..<sides {
            let (z0, y0) = arch(k), (z1, y1) = arch(k + 1)
            let quad = (SIMD3(-length / 2, y0, z0), SIMD3(length / 2, y0, z0), SIMD3(length / 2, y1, z1),
                        SIMD3(-length / 2, y1, z1))
            if k == sides / 2 - 1 || k == sides / 2 {
                stripe.quad(quad.0, quad.1, quad.2, quad.3)
            } else {
                roof.quad(quad.0, quad.1, quad.2, quad.3)
            }
            // The back wall, and a dark inside seen through the open front.
            inside.triangle(SIMD3(-length / 2, 0, 0), SIMD3(-length / 2, y1, z1), SIMD3(-length / 2, y0, z0))
        }
        inside.quad(SIMD3(-length / 2, 0.002, -width / 2), SIMD3(length / 2, 0.002, -width / 2),
                    SIMD3(length / 2, 0.002, width / 2), SIMD3(-length / 2, 0.002, width / 2))
        let paper = SCNMaterial()
        paper.name = "paper"
        paper.lightingModel = .lambert
        paper.diffuse.contents = NSColor(white: 0.8, alpha: 1)
        paper.isDoubleSided = true
        let node = SCNNode()
        node.addChildNode(SCNNode(geometry: roof.geometry(materials: [paperMaterial(PaperColor(0.86, 0.85, 0.80))])))
        node.addChildNode(SCNNode(geometry: stripe.geometry(materials: [paper])))
        node.addChildNode(SCNNode(geometry: inside.geometry(materials: [paperMaterial(PaperColor(0.32, 0.30, 0.28))])))
        return based(node)
    }
}
