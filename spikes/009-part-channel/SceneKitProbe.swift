import AppKit
import Foundation
import Metal
import ModelIO
import SceneKit

struct Options {
    var input: URL
    var outDir: URL
    var displacement: Float = 0.10
}

func parseOptions() throws -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    var input: URL?
    var outDir: URL?
    var displacement: Float = 0.10
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--input":
            index += 1
            input = URL(fileURLWithPath: args[index])
        case "--out-dir":
            index += 1
            outDir = URL(fileURLWithPath: args[index], isDirectory: true)
        case "--displacement":
            index += 1
            guard let value = Float(args[index]) else { throw ProbeError.message("invalid displacement") }
            displacement = value
        default:
            throw ProbeError.message("unknown argument: \(args[index])")
        }
        index += 1
    }
    guard let input, let outDir else {
        throw ProbeError.message("usage: SceneKitProbe --input model.usdz --out-dir directory [--displacement 0.10]")
    }
    return Options(input: input, outDir: outDir, displacement: displacement)
}

enum ProbeError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}

func geometryNodes(in root: SCNNode) -> [SCNNode] {
    var result: [SCNNode] = []
    root.enumerateChildNodes { node, _ in
        if node.geometry != nil { result.append(node) }
    }
    if root.geometry != nil { result.insert(root, at: 0) }
    return result
}

func readComponent(_ source: SCNGeometrySource, vector: Int, component: Int) -> Float {
    let offset = source.dataOffset + vector * source.dataStride + component * source.bytesPerComponent
    return source.data.withUnsafeBytes { raw in
        if source.usesFloatComponents {
            switch source.bytesPerComponent {
            case 2:
                return Float(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            case 4:
                return raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
            case 8:
                return Float(raw.loadUnaligned(fromByteOffset: offset, as: Double.self))
            default:
                return .nan
            }
        }
        switch source.bytesPerComponent {
        case 1:
            return Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)) / 255.0
        case 2:
            return Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) / 65535.0
        case 4:
            return Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) / Float(UInt32.max)
        default:
            return .nan
        }
    }
}

func vector(_ source: SCNGeometrySource, at index: Int) -> [Float] {
    (0..<source.componentsPerVector).map { readComponent(source, vector: index, component: $0) }
}

func format(_ values: [Float]) -> String {
    values.map { String(format: "%.6f", $0) }.joined(separator: ",")
}

func inspect(scene: SCNScene, loader: String) {
    print("LOADER \(loader)")
    let nodes = geometryNodes(in: scene.rootNode)
    print("GEOMETRY_NODES \(nodes.count)")
    for node in nodes {
        guard let geometry = node.geometry else { continue }
        let sources = geometry.sources
        let sourceSummary = sources.map {
            "\($0.semantic.rawValue){count=\($0.vectorCount),components=\($0.componentsPerVector),bytes=\($0.bytesPerComponent),float=\($0.usesFloatComponents),offset=\($0.dataOffset),stride=\($0.dataStride)}"
        }.joined(separator: " ")
        let primitives = geometry.elements.map { "\($0.primitiveType.rawValue):\($0.primitiveCount)" }.joined(separator: ",")
        print("GEOMETRY node=\(node.name ?? "<unnamed>") sources=\(sourceSummary) elements=\(primitives)")
        for (index, material) in geometry.materials.enumerated() {
            let diffuse = material.diffuse.contents.map { String(describing: type(of: $0)) } ?? "nil"
            print("MATERIAL index=\(index) name=\(material.name ?? "<unnamed>") lighting=\(material.lightingModel.rawValue) diffuse=\(diffuse)")
        }
        let texcoords = geometry.sources(for: .texcoord)
        for (texcoordIndex, texcoord) in texcoords.enumerated() {
            var minimum = [Float](repeating: .greatestFiniteMagnitude, count: texcoord.componentsPerVector)
            var maximum = [Float](repeating: -.greatestFiniteMagnitude, count: texcoord.componentsPerVector)
            var uniqueU = Set<Int>()
            var samples: [(String, Int)] = []
            var body = -1
            var middle = (Float.greatestFiniteMagnitude, -1)
            var tip = (Float.greatestFiniteMagnitude, -1)
            for index in 0..<texcoord.vectorCount {
                let value = vector(texcoord, at: index)
                for component in value.indices {
                    minimum[component] = min(minimum[component], value[component])
                    maximum[component] = max(maximum[component], value[component])
                }
                if !value.isEmpty { uniqueU.insert(Int(round(value[0] * 1_000_000))) }
                if value.count >= 2 {
                    if value[0] < 0.01 && value[1] < 0.01 && body < 0 { body = index }
                    if value[0] > 0.99 {
                        if abs(value[1] - 0.5) < middle.0 { middle = (abs(value[1] - 0.5), index) }
                        if abs(value[1] - 1.0) < tip.0 { tip = (abs(value[1] - 1.0), index) }
                    }
                }
            }
            if body >= 0 { samples.append(("zero", body)) }
            if middle.1 >= 0 { samples.append(("u1-middle", middle.1)) }
            if tip.1 >= 0 { samples.append(("u1-tip", tip.1)) }
            print("TEXCOORD index=\(texcoordIndex) count=\(texcoord.vectorCount) components=\(texcoord.componentsPerVector) bytes=\(texcoord.bytesPerComponent) float=\(texcoord.usesFloatComponents) uniqueU=\(uniqueU.count) min=[\(format(minimum))] max=[\(format(maximum))]")
            for (label, index) in samples {
                print("TEXCOORD_SAMPLE index=\(texcoordIndex) \(label) vertex=\(index) value=[\(format(vector(texcoord, at: index)))]")
            }
        }
        guard let colors = geometry.sources(for: .color).first else {
            print("COLOR node=\(node.name ?? "<unnamed>") absent")
            continue
        }
        let positions = geometry.sources(for: .vertex).first
        var minimum = [Float](repeating: .greatestFiniteMagnitude, count: colors.componentsPerVector)
        var maximum = [Float](repeating: -.greatestFiniteMagnitude, count: colors.componentsPerVector)
        var chosen: [(String, Int)] = []
        var bestRoot = (Float.greatestFiniteMagnitude, -1)
        var bestMiddle = (Float.greatestFiniteMagnitude, -1)
        var bestTip = (Float.greatestFiniteMagnitude, -1)
        var body = -1
        for index in 0..<colors.vectorCount {
            let value = vector(colors, at: index)
            for component in value.indices {
                minimum[component] = min(minimum[component], value[component])
                maximum[component] = max(maximum[component], value[component])
            }
            let r = value.indices.contains(0) ? value[0] : 0
            let g = value.indices.contains(1) ? value[1] : 0
            if r < 0.01 && g < 0.01 && body < 0 { body = index }
            if r > 0.99 {
                if g < bestRoot.0 { bestRoot = (g, index) }
                if abs(g - 0.5) < bestMiddle.0 { bestMiddle = (abs(g - 0.5), index) }
                if abs(g - 1.0) < bestTip.0 { bestTip = (abs(g - 1.0), index) }
            }
        }
        if body >= 0 { chosen.append(("body", body)) }
        if bestRoot.1 >= 0 { chosen.append(("fin-root", bestRoot.1)) }
        if bestMiddle.1 >= 0 { chosen.append(("fin-middle", bestMiddle.1)) }
        if bestTip.1 >= 0 { chosen.append(("fin-tip", bestTip.1)) }
        print("COLOR node=\(node.name ?? "<unnamed>") count=\(colors.vectorCount) components=\(colors.componentsPerVector) bytes=\(colors.bytesPerComponent) float=\(colors.usesFloatComponents) min=[\(format(minimum))] max=[\(format(maximum))]")
        for (label, index) in chosen {
            let color = vector(colors, at: index)
            let position = positions.flatMap { index < $0.vectorCount ? vector($0, at: index) : nil }
            print("COLOR_SAMPLE \(label) index=\(index) value=[\(format(color))] position=[\(position.map(format) ?? "unavailable")]")
        }
    }
}

func loadDirect(_ url: URL) throws -> SCNScene {
    try SCNScene(url: url, options: nil)
}

func loadModelIO(_ url: URL) throws -> SCNScene {
    let asset = MDLAsset(url: url)
    asset.loadTextures()
    let selector = NSSelectorFromString("sceneWithMDLAsset:")
    guard let unmanaged = SCNScene.perform(selector, with: asset),
          let scene = unmanaged.takeUnretainedValue() as? SCNScene else {
        throw ProbeError.message("SceneKit ModelIO bridge unavailable")
    }
    return scene
}

func applyDisplacement(to scene: SCNScene, amount: Float) {
    let source = """
    #pragma body
    _geometry.position.z += _geometry.color.g * \(amount);
    """
    for node in geometryNodes(in: scene.rootNode) {
        for material in node.geometry?.materials ?? [] {
            material.shaderModifiers = [.geometry: source]
        }
    }
}

func applyTexcoordDisplacement(to scene: SCNScene, index: Int, amount: Float) {
    let source = """
    #pragma body
    _geometry.position.z += _geometry.texcoords[\(index)].y * \(amount);
    """
    for node in geometryNodes(in: scene.rootNode) {
        for material in node.geometry?.materials ?? [] {
            material.shaderModifiers = [.geometry: source]
        }
    }
}

func modelBounds(_ scene: SCNScene) -> (SCNVector3, SCNVector3) {
    var low = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
    var high = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
    for node in geometryNodes(in: scene.rootNode) {
        guard let geometry = node.geometry else { continue }
        let bounds = geometry.boundingBox
        for x in [bounds.min.x, bounds.max.x] {
            for y in [bounds.min.y, bounds.max.y] {
                for z in [bounds.min.z, bounds.max.z] {
                    let point = node.convertPosition(SCNVector3(x, y, z), to: nil)
                    low.x = min(low.x, point.x); low.y = min(low.y, point.y); low.z = min(low.z, point.z)
                    high.x = max(high.x, point.x); high.y = max(high.y, point.y); high.z = max(high.z, point.z)
                }
            }
        }
    }
    return (low, high)
}

func addCameraAndLights(to scene: SCNScene) -> SCNNode {
    let bounds = modelBounds(scene)
    let center = SCNVector3(
        (bounds.0.x + bounds.1.x) * 0.5,
        (bounds.0.y + bounds.1.y) * 0.5,
        (bounds.0.z + bounds.1.z) * 0.5
    )
    let extent = max(bounds.1.x - bounds.0.x, max(bounds.1.y - bounds.0.y, bounds.1.z - bounds.0.z))
    let camera = SCNCamera()
    camera.usesOrthographicProjection = true
    camera.orthographicScale = Double(extent * 1.25)
    camera.zNear = 0.001
    camera.zFar = Double(extent * 20)
    let cameraNode = SCNNode()
    cameraNode.name = "ProbeCamera"
    cameraNode.camera = camera
    cameraNode.position = SCNVector3(center.x, center.y + extent * 2.1, center.z + extent * 1.25)
    cameraNode.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
    scene.rootNode.addChildNode(cameraNode)

    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 120
    ambient.color = NSColor(calibratedWhite: 0.8, alpha: 1)
    let ambientNode = SCNNode()
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)

    let key = SCNLight()
    key.type = .omni
    key.intensity = 220
    key.color = NSColor.white
    let keyNode = SCNNode()
    keyNode.light = key
    keyNode.position = SCNVector3(center.x + extent, center.y + extent, center.z + extent * 2)
    scene.rootNode.addChildNode(keyNode)
    return cameraNode
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ProbeError.message("could not encode PNG")
    }
    try png.write(to: url)
}

func render(scene: SCNScene, to url: URL, size: CGSize = CGSize(width: 900, height: 600)) throws -> NSImage {
    for node in geometryNodes(in: scene.rootNode) {
        for material in node.geometry?.materials ?? [] {
            material.lightingModel = .constant
        }
    }
    scene.background.contents = NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.065, alpha: 1)
    scene.lightingEnvironment.contents = nil
    let camera = addCameraAndLights(to: scene)
    guard let device = MTLCreateSystemDefaultDevice() else { throw ProbeError.message("Metal device unavailable") }
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    renderer.autoenablesDefaultLighting = false
    let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    try writePNG(image, to: url)
    return image
}

func centroid(of image: NSImage) -> Double? {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    var weightedX = 0.0
    var weight = 0.0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let value = Double(max(color.redComponent, max(color.greenComponent, color.blueComponent)))
            if value > 0.15 {
                weightedX += Double(x) * value
                weight += value
            }
        }
    }
    return weight > 0 ? weightedX / weight : nil
}

func absentColorScene(displaced: Bool) -> SCNScene {
    let vertices: [SCNVector3] = [
        SCNVector3(-0.35, -0.25, 0), SCNVector3(0.35, -0.25, 0), SCNVector3(0, 0.35, 0),
    ]
    let source = SCNGeometrySource(vertices: vertices)
    let indices: [UInt16] = [0, 1, 2]
    let data = indices.withUnsafeBytes { Data($0) }
    let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: 1, bytesPerIndex: 2)
    let geometry = SCNGeometry(sources: [source], elements: [element])
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = NSColor.white
    material.isDoubleSided = true
    geometry.materials = [material]
    if displaced {
        geometry.shaderModifiers = [.geometry: "#pragma body\n_geometry.position.x += dot(_geometry.color, float4(0.25)) * 0.10;"]
    }
    let node = SCNNode(geometry: geometry)
    let scene = SCNScene()
    scene.rootNode.addChildNode(node)
    return scene
}

func run() throws {
    let options = try parseOptions()
    try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)

    let direct = try loadDirect(options.input)
    inspect(scene: direct, loader: "SCNScene(url:)")
    let modelIO = try loadModelIO(options.input)
    inspect(scene: modelIO, loader: "MDLAsset -> SCNScene")

    let baseline = try loadDirect(options.input)
    _ = try render(scene: baseline, to: options.outDir.appendingPathComponent("baseline.png"))
    let displaced = try loadDirect(options.input)
    applyDisplacement(to: displaced, amount: options.displacement)
    _ = try render(scene: displaced, to: options.outDir.appendingPathComponent("color-displaced.png"))
    for index in 0..<2 {
        let uvDisplaced = try loadDirect(options.input)
        let hasSource = geometryNodes(in: uvDisplaced.rootNode).contains {
            ($0.geometry?.sources(for: .texcoord).count ?? 0) > index
        }
        if hasSource {
            applyTexcoordDisplacement(to: uvDisplaced, index: index, amount: options.displacement)
            _ = try render(scene: uvDisplaced, to: options.outDir.appendingPathComponent("texcoord\(index)-displaced.png"))
        }
    }

    let absentBaseline = try render(
        scene: absentColorScene(displaced: false),
        to: options.outDir.appendingPathComponent("absent-baseline.png"),
        size: CGSize(width: 500, height: 500)
    )
    let absentDisplaced = try render(
        scene: absentColorScene(displaced: true),
        to: options.outDir.appendingPathComponent("absent-displaced.png"),
        size: CGSize(width: 500, height: 500)
    )
    let before = centroid(of: absentBaseline)
    let after = centroid(of: absentDisplaced)
    print("ABSENT_COLOR centroid_baseline=\(before.map { String(format: "%.3f", $0) } ?? "none") centroid_modifier=\(after.map { String(format: "%.3f", $0) } ?? "none") delta=\((before != nil && after != nil) ? String(format: "%.3f", after! - before!) : "none")")
}

do {
    try run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
