// Reports the node hierarchy SceneKit actually receives from a USD export, then rotates a
// named part and renders, to confirm the pivot lands on the hinge.
//
//   swiftc -O spikes/004-articulated-decor/HingeProbe.swift -o /tmp/hingeprobe \
//       -framework SceneKit -framework AppKit
//   /tmp/hingeprobe --input /tmp/chest.usdz --part part_lid --angles 0,-40,-80
//
// The emitter's distance from the pivot is the real test and it is checked here rather than
// left to the eye: a rigid rotation holds that radius exactly, while a part that inherited a
// non-uniform parent scale shears instead of turning and the radius drifts. That failure
// looks plausible in a render, so the number is what settles it.

import AppKit
import SceneKit

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let input = value("--input") else { fatalError("need --input") }
let outDir = value("--out-dir") ?? "/tmp/hinge-out"
let partName = value("--part") ?? "part_lid"
let emitterName = value("--emitter") ?? "emit_bubbles"

// Props hinge in whichever direction their pivot sits, so a fixed positive sweep only ever
// suits half of them: a lid hinged at +Y opens through negative angles and the default
// would render it closing into its own back wall.
let angles = (value("--angles") ?? "0,35,70")
    .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
guard !angles.isEmpty else { fatalError("--angles parsed to nothing") }

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

let part = scene.rootNode.childNode(withName: partName, recursively: true)
let emitter = scene.rootNode.childNode(withName: emitterName, recursively: true)
print("--- lookup ---")
print("\(partName) found:  \(part != nil)")
print("\(emitterName) found:  \(emitter != nil)")
guard let part else { fatalError("no node named \(partName)") }

// Frame the whole prop. Blender's USD export applies no axis conversion, so the model
// arrives Z-up and the camera has to be told that or every render comes out rolled.
let (lo, hi) = scene.rootNode.boundingBox
let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
let radius = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))

let camera = SCNNode()
camera.camera = SCNCamera()
camera.camera!.zNear = 0.001
camera.position = SCNVector3(center.x + radius * 1.5, center.y - radius * 2.0, center.z + radius * 1.0)
camera.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
scene.rootNode.addChildNode(camera)

// Directional, not omni. An omni light in SceneKit does not attenuate unless you set an
// attenuation distance, so moving it away does nothing and the obvious intensities blow a
// pale prop — a shell, a bone, a diving helmet — to a white silhouette in which nothing
// about the hinge is legible. Directional light is independent of the prop's size, which
// also means these numbers hold for a 0.2 m clam and a 2 m wreck alike.
let brightness = CGFloat(value("--light").flatMap { Double($0) } ?? 1.0)

let key = SCNNode()
key.light = SCNLight()
key.light!.type = .directional
key.light!.intensity = 380 * brightness
key.position = SCNVector3(center.x + radius, center.y - radius * 2, center.z + radius * 2)
key.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
scene.rootNode.addChildNode(key)

let fill = SCNNode()
fill.light = SCNLight()
fill.light!.type = .directional
fill.light!.intensity = 150 * brightness
fill.position = SCNVector3(center.x - radius * 2, center.y - radius, center.z)
fill.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
scene.rootNode.addChildNode(fill)

let ambient = SCNNode()
ambient.light = SCNLight()
ambient.light!.type = .ambient
ambient.light!.intensity = 90 * brightness
scene.rootNode.addChildNode(ambient)

// A dark backdrop, because a pale prop on the default white is invisible.
scene.background.contents = NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.12, alpha: 1)

let renderer = SCNRenderer(device: nil, options: nil)
renderer.scene = scene
renderer.pointOfView = camera

let pivot = part.convertPosition(SCNVector3Zero, to: nil)
print(String(format: "--- %@ pivot world (%.4f, %.4f, %.4f) ---", partName, pivot.x, pivot.y, pivot.z))

var radii: [Double] = []
for (index, degrees) in angles.enumerated() {
    part.eulerAngles = SCNVector3(Float(degrees) * .pi / 180.0, 0, 0)
    if let e = emitter {
        let world = e.convertPosition(SCNVector3Zero, to: nil)
        let dx = Double(world.x - pivot.x), dy = Double(world.y - pivot.y), dz = Double(world.z - pivot.z)
        let r = (dx * dx + dy * dy + dz * dz).squareRoot()
        radii.append(r)
        print(String(format: "%@ %7.1f deg -> emitter world (%.4f, %.4f, %.4f)  r=%.5f",
                     partName, degrees, world.x, world.y, world.z, r))
    }
    let image = renderer.snapshot(atTime: 0, with: CGSize(width: 700, height: 560),
                                  antialiasingMode: .multisampling4X)
    let path = "\(outDir)/hinge_\(index).png"
    if let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

if let first = radii.first, let worst = radii.map({ abs($0 - first) }).max() {
    print(String(format: "--- pivot radius drift %.7f m over %d angles ---", worst, radii.count))
    print(worst < 1e-5
          ? "RIGID: the part rotates about its origin."
          : "SHEARED: radius is not constant — check for scale left on a parent.")
}
