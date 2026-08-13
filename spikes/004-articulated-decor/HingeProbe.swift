// Reports the node hierarchy SceneKit actually receives from a USD export, then rotates
// the node named part_lid and renders, to confirm the pivot lands on the hinge.

import AppKit
import SceneKit

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let input = value("--input") else { fatalError("need --input") }
let outDir = value("--out-dir") ?? "/tmp/hinge-out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

guard let scene = try? SCNScene(url: URL(fileURLWithPath: input), options: nil) else {
    fatalError("could not load \(input)")
}

func describe(_ node: SCNNode, depth: Int = 0) {
    let pad = String(repeating: "  ", count: depth)
    let name = node.name ?? "<unnamed>"
    let geo = node.geometry.map { "geometry(\($0.sources(for: .vertex).first?.vectorCount ?? 0) verts)" } ?? "no-geometry"
    let p = node.position
    print(String(format: "%@%@  %@  pos(%.4f, %.4f, %.4f)", pad, name, geo, p.x, p.y, p.z))
    for child in node.childNodes { describe(child, depth: depth + 1) }
}

print("--- hierarchy ---")
describe(scene.rootNode)

let lid = scene.rootNode.childNode(withName: "part_lid", recursively: true)
let emitter = scene.rootNode.childNode(withName: "emit_bubbles", recursively: true)
print("--- lookup ---")
print("part_lid found:      \(lid != nil)")
print("emit_bubbles found:  \(emitter != nil)")
if let e = emitter {
    let world = e.convertPosition(SCNVector3Zero, to: nil)
    print(String(format: "emitter world pos:   (%.4f, %.4f, %.4f)", world.x, world.y, world.z))
}

// Frame the whole prop.
let (lo, hi) = scene.rootNode.boundingBox
let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
let radius = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))

let camera = SCNNode()
camera.camera = SCNCamera()
camera.camera!.zNear = 0.001
camera.position = SCNVector3(center.x + radius * 1.6, center.y - radius * 2.0, center.z + radius * 1.2)
camera.look(at: center)
scene.rootNode.addChildNode(camera)

let light = SCNNode()
light.light = SCNLight()
light.light!.type = .omni
light.light!.intensity = 1400
light.position = SCNVector3(center.x + radius * 2, center.y - radius * 2, center.z + radius * 3)
scene.rootNode.addChildNode(light)
let ambient = SCNNode()
ambient.light = SCNLight()
ambient.light!.type = .ambient
ambient.light!.intensity = 320
scene.rootNode.addChildNode(ambient)

let renderer = SCNRenderer(device: nil, options: nil)
renderer.scene = scene
renderer.pointOfView = camera

for (index, degrees) in [0.0, 35.0, 70.0].enumerated() {
    lid?.eulerAngles = SCNVector3(Float(degrees) * .pi / 180.0, 0, 0)
    if let e = emitter {
        let world = e.convertPosition(SCNVector3Zero, to: nil)
        print(String(format: "lid %5.1f deg -> emitter world (%.4f, %.4f, %.4f)",
                     degrees, world.x, world.y, world.z))
    }
    let image = renderer.snapshot(atTime: 0, with: CGSize(width: 600, height: 500),
                                  antialiasingMode: .multisampling4X)
    let path = "\(outDir)/hinge_\(index).png"
    if let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
