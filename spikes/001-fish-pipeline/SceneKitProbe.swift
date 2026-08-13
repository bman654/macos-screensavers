// Loads a USDZ into SceneKit, reports what actually survived the export, applies the
// sine-bend swim deformation as a geometry shader modifier, and renders frames offscreen.
//
// This is the de-risking step for the whole asset pipeline. Two things have to be true
// for the aquarium to work: the mesh and its materials have to arrive intact from
// Blender, and a fish has to be able to undulate without a skeleton. Rendering offscreen
// from a command-line tool proves both without any screensaver scaffolding in the way.

import AppKit
import Foundation
import Metal
import SceneKit

// MARK: - Arguments

struct Options {
    var input = ""
    var outDir = "out"
    var frames = 4
    var width = 900
    var height = 600
    var amplitude: CGFloat = 0.12   // fraction of body length
    var swim = true
    var topView = false
    var subdivision = 0
}

func parseOptions() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = iterator.next() {
        switch flag {
        case "--input": options.input = iterator.next() ?? ""
        case "--out-dir": options.outDir = iterator.next() ?? options.outDir
        case "--frames": options.frames = Int(iterator.next() ?? "") ?? options.frames
        case "--width": options.width = Int(iterator.next() ?? "") ?? options.width
        case "--height": options.height = Int(iterator.next() ?? "") ?? options.height
        case "--amplitude": options.amplitude = CGFloat(Double(iterator.next() ?? "") ?? 0.12)
        case "--no-swim": options.swim = false
        case "--top": options.topView = true
        case "--subdivision": options.subdivision = Int(iterator.next() ?? "") ?? 0
        default: fail("unknown argument: \(flag)")
        }
    }
    if options.input.isEmpty { fail("usage: SceneKitProbe --input <file.usdz> [--out-dir DIR]") }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - Inspection

/// Walk the imported hierarchy and report it, so a silently-empty or
/// silently-untextured import is visible rather than showing up as a blank render.
func describe(_ node: SCNNode, depth: Int = 0, stats: inout (nodes: Int, verts: Int, materials: Int)) {
    stats.nodes += 1
    let indent = String(repeating: "  ", count: depth)
    var detail = ""

    if let geometry = node.geometry {
        let vertexCount = geometry.sources(for: .vertex).first?.vectorCount ?? 0
        stats.verts += vertexCount
        stats.materials += geometry.materials.count
        detail = "  [geometry: \(vertexCount) verts, \(geometry.elements.count) elements, "
            + "\(geometry.materials.count) materials]"
    }
    print("\(indent)- \(node.name ?? "<unnamed>")\(detail)")

    if let geometry = node.geometry {
        for material in geometry.materials {
            let base = material.diffuse.contents
            let summary: String
            if let color = base as? NSColor {
                let rgb = color.usingColorSpace(.deviceRGB)
                summary = String(format: "colour(%.3f, %.3f, %.3f)",
                                 rgb?.redComponent ?? 0, rgb?.greenComponent ?? 0,
                                 rgb?.blueComponent ?? 0)
            } else if base is NSImage || base is URL {
                summary = "texture"
            } else {
                summary = base.map { "\(type(of: $0))" } ?? "none"
            }
            print("\(indent)    · material '\(material.name ?? "<unnamed>")' diffuse=\(summary)"
                + " roughness=\(material.roughness.contents ?? "none")")
        }
    }

    for child in node.childNodes { describe(child, depth: depth + 1, stats: &stats) }
}

// MARK: - Swim deformation

/// A travelling sine wave down the body, applied in the vertex stage.
///
/// The alternative is a bone chain exported from Blender. This is cheaper, has no rig to
/// survive the export, and lets every fish in a school share one geometry with a
/// different phase. Position is taken to world space first because fins and eyes are
/// separate nodes whose local origins differ from the body's.
///
/// Works in the mesh's own object space, which is only valid because the fish is
/// exported as a single joined mesh. Reaching for world space via `u_modelTransform`
/// inside a geometry modifier produced shredded geometry and a magenta surface here, so
/// the joined-mesh export is what makes this simple version correct.
let swimModifier = """
#pragma arguments
float swimPhase;
float swimAmplitude;
float swimWaves;
float bodyMinX;
float bodyLength;

#pragma body
float tailward = clamp((bodyMinX + bodyLength - _geometry.position.x) / bodyLength, 0.0, 1.0);

// Hold the head steady and let displacement grow toward the tail; a fish that
// translates bodily side to side reads as a bar of soap, not a swimming animal.
float envelope = tailward * tailward;
_geometry.position.y += sin(tailward * swimWaves * 6.2831853 - swimPhase)
                      * swimAmplitude * envelope;
"""

func applySwim(to node: SCNNode, minX: Float, length: Float, amplitude: Float) {
    node.enumerateHierarchy { child, _ in
        guard let geometry = child.geometry else { return }
        for material in geometry.materials {
            material.shaderModifiers = [.geometry: swimModifier]
            material.setValue(NSNumber(value: 0.0), forKey: "swimPhase")
            material.setValue(NSNumber(value: amplitude), forKey: "swimAmplitude")
            material.setValue(NSNumber(value: 1.15), forKey: "swimWaves")
            material.setValue(NSNumber(value: minX), forKey: "bodyMinX")
            material.setValue(NSNumber(value: length), forKey: "bodyLength")
        }
    }
}

func setPhase(_ phase: Float, on node: SCNNode) {
    node.enumerateHierarchy { child, _ in
        child.geometry?.materials.forEach {
            $0.setValue(NSNumber(value: phase), forKey: "swimPhase")
        }
    }
}

// MARK: - Staging

func addLighting(to scene: SCNScene) {
    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.color = NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.52, alpha: 1)
    ambient.intensity = 420
    scene.rootNode.addChildNode(node(with: ambient))

    let key = SCNLight()
    key.type = .directional
    key.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.88, alpha: 1)
    key.intensity = 1250
    key.castsShadow = false
    let keyNode = node(with: key)
    keyNode.eulerAngles = SCNVector3(-1.05, 0.42, 0)
    scene.rootNode.addChildNode(keyNode)

    let rim = SCNLight()
    rim.type = .directional
    rim.color = NSColor(calibratedRed: 0.42, green: 0.72, blue: 0.9, alpha: 1)
    rim.intensity = 620
    let rimNode = node(with: rim)
    rimNode.eulerAngles = SCNVector3(0.5, 2.6, 0)
    scene.rootNode.addChildNode(rimNode)
}

func node(with light: SCNLight) -> SCNNode {
    let n = SCNNode()
    n.light = light
    return n
}

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode \(url.lastPathComponent)")
    }
    do { try data.write(to: url) } catch { fail("could not write \(url.path): \(error)") }
}

// MARK: - Main

let options = parseOptions()
let inputURL = URL(fileURLWithPath: options.input)

guard let scene = try? SCNScene(url: inputURL, options: [.checkConsistency: true]) else {
    fail("SceneKit could not open \(inputURL.path)")
}

print("=== imported hierarchy ===")
var stats = (nodes: 0, verts: 0, materials: 0)
describe(scene.rootNode, stats: &stats)
print("=== \(stats.nodes) nodes, \(stats.verts) vertices, \(stats.materials) materials ===")

/// Union of every geometry node's box, expressed in the root's space.
///
/// `SCNNode.boundingBox` on the root reports only that node's own geometry in some
/// import layouts, which silently yields a zero extent for a hierarchy whose meshes all
/// live in children — and a zero extent would make the swim envelope divide by zero.
func worldBounds(of root: SCNNode) -> (SCNVector3, SCNVector3)? {
    var lo = SCNVector3(Float.greatestFiniteMagnitude,
                        Float.greatestFiniteMagnitude,
                        Float.greatestFiniteMagnitude)
    var hi = SCNVector3(-Float.greatestFiniteMagnitude,
                        -Float.greatestFiniteMagnitude,
                        -Float.greatestFiniteMagnitude)
    var found = false

    root.enumerateHierarchy { node, _ in
        guard node.geometry != nil else { return }
        let (a, b) = node.boundingBox
        for x in [a.x, b.x] {
            for y in [a.y, b.y] {
                for z in [a.z, b.z] {
                    let p = root.convertPosition(SCNVector3(x, y, z), from: node)
                    lo = SCNVector3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                    hi = SCNVector3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
                    found = true
                }
            }
        }
    }
    return found ? (lo, hi) : nil
}

guard let (minBound, maxBound) = worldBounds(of: scene.rootNode) else {
    fail("imported scene contains no geometry")
}
let length = Float(maxBound.x - minBound.x)
let height = Float(maxBound.z - minBound.z)
print(String(format: "bounds: x %.4f..%.4f (length %.4f)  z-height %.4f",
             Float(minBound.x), Float(maxBound.x), length, height))
guard length > 0 else { fail("imported scene has zero extent — nothing was loaded") }

if options.subdivision > 0 {
    scene.rootNode.enumerateHierarchy { node, _ in
        node.geometry?.subdivisionLevel = options.subdivision
    }
}

if options.swim {
    applySwim(to: scene.rootNode, minX: Float(minBound.x), length: length,
              amplitude: Float(options.amplitude) * length)
}

// Fixed camera with a narrow field of view: near-orthographic, which is the 2.5D look
// the screensaver is aiming for, with just enough perspective to give depth lanes parallax.
let camera = SCNCamera()
camera.fieldOfView = 22
camera.zNear = 0.01
camera.zFar = 100
camera.wantsHDR = true
camera.bloomIntensity = 0.25
camera.bloomThreshold = 0.85
let cameraNode = SCNNode()
cameraNode.camera = camera
let center = SCNVector3((minBound.x + maxBound.x) / 2,
                        (minBound.y + maxBound.y) / 2,
                        (minBound.z + maxBound.z) / 2)
let distance = CGFloat(length) * 3.4
if options.topView {
    // Looking straight down. The swim wave displaces along Y, so a side-on camera looks
    // directly along the axis of motion and shows almost nothing — the deformation can
    // appear broken when it is simply edge-on.
    cameraNode.position = SCNVector3(center.x, center.y, center.z + distance)
    cameraNode.eulerAngles = SCNVector3(0, 0, 0)
} else {
    cameraNode.position = SCNVector3(center.x, center.y - distance, center.z)
    cameraNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
}
scene.rootNode.addChildNode(cameraNode)

addLighting(to: scene)
scene.background.contents = NSColor(calibratedRed: 0.035, green: 0.10, blue: 0.145, alpha: 1)

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = cameraNode
renderer.autoenablesDefaultLighting = false

try? FileManager.default.createDirectory(atPath: options.outDir,
                                         withIntermediateDirectories: true)

let size = CGSize(width: options.width, height: options.height)
for frame in 0..<options.frames {
    let phase = Float(frame) / Float(options.frames) * 2 * .pi
    setPhase(phase, on: scene.rootNode)
    let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    let url = URL(fileURLWithPath: options.outDir)
        .appendingPathComponent(String(format: "swim_%02d.png", frame))
    writePNG(image, to: url)
    print("rendered \(url.lastPathComponent)")
}
