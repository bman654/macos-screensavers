// Code-built tanks and pencils, for a library that lacks them.
//
// Authored the way the Blender ones are — Blender axes, front toward +X, the turret a child named
// `turret` with its origin on its turning axis, under a -90° X pivot — so `TankField` turns the
// turret about the same axis whichever it was handed, and nothing downstream can tell.

import AppKit
import Foundation
import SceneKit
import simd

extension StandIns {

    static func tank(_ type: TankType) -> ModelTemplate {
        let heavy = type == .heavy
        let length: Float = heavy ? 0.192 : 0.142
        let width: Float = heavy ? 0.128 : 0.1
        let hullLength = length * 0.8
        let tread = linearRGBA(PaperColor(0.24, 0.22, 0.21))

        // Treads in their authored colour; hull and turret in `paper`, which the runtime tints.
        var treads = FacetMesh()
        for side: Float in [-1, 1] {
            let y = side * width * 0.38
            addBox(&treads, min: SIMD3<Float>(-hullLength / 2, y - width * 0.12, 0),
                   max: SIMD3<Float>(hullLength / 2, y + width * 0.12, width * 0.2), color: tread)
        }
        var hull = FacetMesh()
        addBox(&hull, min: SIMD3<Float>(-hullLength / 2 * 0.95, -width * 0.3, width * 0.1),
               max: SIMD3<Float>(hullLength / 2 * 0.9, width * 0.3, width * 0.3), bevelTop: 0.15)
        let paper = SCNMaterial()
        paper.name = "paper"
        paper.lightingModel = .lambert
        paper.diffuse.contents = NSColor(white: 0.8, alpha: 1)
        let treadMaterial = SCNMaterial()
        treadMaterial.lightingModel = .lambert
        treadMaterial.diffuse.contents = NSColor.white

        let body = SCNNode()
        body.addChildNode(SCNNode(geometry: treads.geometry(materials: [treadMaterial])))
        body.addChildNode(SCNNode(geometry: hull.geometry(materials: [paper])))

        // The turret's own origin is its pivot; its parts are built round it.
        let pivotX = -length * 0.12
        let turret = SCNNode()
        turret.name = "turret"
        turret.simdPosition = SIMD3(pivotX, 0, width * 0.3)
        var dome = FacetMesh()
        addPrism(&dome, sides: 8, radius: width * (heavy ? 0.24 : 0.2), bottom: 0, top: width * 0.14, color: nil)
        let domeNode = SCNNode(geometry: dome.geometry(materials: [paper]))
        // `addPrism` builds about +Y; the turret is Z-up like everything in this pivot.
        domeNode.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        turret.addChildNode(domeNode)
        let reach = length / 2 - pivotX
        for offset in heavy ? [width * 0.066, -width * 0.066] : [Float(0)] {
            var barrel = FacetMesh()
            addBox(&barrel, min: SIMD3(0, -width * 0.025, -width * 0.025), max: SIMD3(reach, width * 0.025, width * 0.025))
            let node = SCNNode(geometry: barrel.geometry(materials: [paper]))
            node.simdPosition = SIMD3(0, offset, width * 0.07)
            turret.addChildNode(node)
        }
        body.addChildNode(turret)

        let pivot = SCNNode()
        pivot.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        pivot.addChildNode(body)
        let template = based(pivot)
        return ModelTemplate(node: template.node, extent: template.extent, sheetAspect: 1, isStandIn: true)
    }

    /// A pencil stub, along +X: painted yellow hexagon, a bare-wood cone and a graphite point.
    static func pencil() -> SCNNode {
        var mesh = FacetMesh()
        let paint = linearRGBA(PaperColor(0.98, 0.78, 0.14))
        let wood = linearRGBA(PaperColor(0.90, 0.74, 0.52))
        let lead = linearRGBA(PaperColor(0.22, 0.22, 0.24))
        let pink = linearRGBA(PaperColor(0.94, 0.56, 0.60))
        addPrism(&mesh, sides: 6, radius: 0.11, bottom: -0.5, top: 0.25, color: paint)
        addPrism(&mesh, sides: 6, radius: 0.11, bottom: -0.62, top: -0.5, color: pink)
        addCone(&mesh, sides: 6, radius: 0.11, bottom: 0.25, apex: 0.5, color: wood)
        addCone(&mesh, sides: 6, radius: 0.04, bottom: 0.41, apex: 0.5, color: lead)
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = NSColor.white
        let node = SCNNode(geometry: mesh.geometry(materials: [material]))
        // Built along +Y; the projectile frame wants +X.
        node.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1))
        return node
    }
}
