// What SceneKit actually makes of an Origami Dogfight model: the node tree, the geometry and
// materials that survived the Blender → USDZ export, how the Blender axes arrive, whether every
// face is still flat, what the paper's UVs look like, whether the fire's flames pivot about
// their bases, whether a tank's turret turns cleanly about its own origin, whether a crane's
// wings and a windmill's blades turn cleanly about their hinges, and whether a parachute hangs
// from its origin. It renders each model offscreen with the axis correction the runtime uses,
// so a broken export is a picture and a FAIL line rather than a surprise inside the saver.
//
// The contract it checks is `docs/origami-plan.md` §Asset contract.
//
//   swift tools/origami-usdz-probe.swift [--out DIR] [--lined] [file.usdz ...]
//
// or, faster when probing repeatedly:
//
//   swiftc -O tools/origami-usdz-probe.swift -o /tmp/origami-usdz-probe
//   /tmp/origami-usdz-probe [--out DIR] [--lined] [file.usdz ...]
//
// With no files it probes every `Savers/OrigamiDogfight/Assets/*.usdz`. Renders go to
// `build/origami-models/scenekit/` unless `--out` says otherwise: `<name>_top.png` (straight
// down, nose up the image), `<name>_34.png` (from front-left-above), and with `--lined`
// `<name>_top_lined.png`, the paper replaced by a lined-notebook sheet so the UV layout — and
// whether SceneKit flips v — can be seen. A tank adds `<name>_top_turret_45.png` and `_90`,
// its turret turned the way the runtime turns it; a crane adds `<name>_top_flap_<deg>.png` and
// `_34_flap_<deg>`, its wings at the ends of their range; a windmill `<name>_top_blades_<deg>`
// and `_34_blades_<deg>`. A `<name>.json` manifest beside the usdz, when present, is the
// reference for the bounds, the axis verdict and every pivot. Exits nonzero if any file FAILs.
//
// Never opens a window or takes focus: `SCNRenderer` offscreen, no `NSApplication`.

import AppKit
import Foundation
import Metal
import SceneKit
import simd

// MARK: - Arguments

struct Options {
    var outDir: URL
    var lined = false
    var files: [URL] = []
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("""
        error: \(message)
        usage: swift tools/origami-usdz-probe.swift [--out DIR] [--lined] [file.usdz ...]

        """.utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options(outDir: repoRoot.appendingPathComponent("build/origami-models/scenekit"))
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--out":
            guard let dir = args.next() else { usage("--out needs a directory") }
            options.outDir = URL(fileURLWithPath: dir)
        case "--lined": options.lined = true
        case "-h", "--help": usage("help requested")
        default:
            if arg.hasPrefix("--") { usage("unknown flag \(arg)") }
            options.files.append(URL(fileURLWithPath: arg))
        }
    }
    if options.files.isEmpty {
        let assets = repoRoot.appendingPathComponent("Savers/OrigamiDogfight/Assets")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []
        options.files = names.filter { $0.hasSuffix(".usdz") }.sorted()
            .map { assets.appendingPathComponent($0) }
        if options.files.isEmpty { usage("no files given and no .usdz in \(assets.path)") }
    }
    return options
}

// MARK: - Manifest

struct Box {
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>
    var extent: SIMD3<Float> { hi - lo }
    var center: SIMD3<Float> { (lo + hi) / 2 }

    func union(_ p: SIMD3<Float>) -> Box { Box(lo: simd_min(lo, p), hi: simd_max(hi, p)) }
    static func of(_ points: [SIMD3<Float>]) -> Box? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(Box(lo: first, hi: first)) { $0.union($1) }
    }
}

/// How a hinged node moves, which decides the angles it is checked and drawn at.
enum HingePose: Hashable {
    /// A wing, which may travel from `down` to `up` degrees of lift.
    case flap(down: Float, up: Float)
    /// Blades, which turn all the way round.
    case blades

    var name: String {
        switch self {
        case .flap: return "flap"
        case .blades: return "blades"
        }
    }

    var checked: [Float] {
        switch self {
        case let .flap(down, up): return [down, up / 2, up]
        case .blades: return [22.5, 45, 90]
        }
    }

    var drawn: [Float] {
        switch self {
        case let .flap(down, up): return [down, up]
        case .blades: return [22.5, 45]
        }
    }
}

/// A node the runtime turns about its own X axis: a crane's wing, a windmill's blades.
struct Hinge {
    let node: String
    /// Its origin, in Blender axes.
    let pivot: SIMD3<Float>
    /// The sign of a turn about +X that the runtime calls positive: +1 lifts wing_l, -1 lifts
    /// wing_r; blades turn the way the wind drives them.
    let sign: Float
    let pose: HingePose
}

struct Manifest {
    let kind: String?
    let bounds: Box?
    let sheetAspect: Float?
    /// A tank's turret origin, in Blender axes.
    let turretPivot: SIMD3<Float>?
    let hinges: [Hinge]
}

/// The manifest beside the usdz, or nil when there is none. A manifest that exists but does
/// not parse is reported, since that is a broken export rather than an absent one.
func loadManifest(beside usdz: URL) -> (Manifest?, String?) {
    let url = usdz.deletingPathExtension().appendingPathExtension("json")
    guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return (nil, "manifest \(url.lastPathComponent) is not a JSON object")
    }
    func vec(_ value: Any?) -> SIMD3<Float>? {
        guard let a = value as? [NSNumber], a.count == 3 else { return nil }
        return SIMD3(a[0].floatValue, a[1].floatValue, a[2].floatValue)
    }
    var bounds: Box?
    if let b = json["bounds"] as? [String: Any], let lo = vec(b["min"]), let hi = vec(b["max"]) {
        bounds = Box(lo: lo, hi: hi)
    }
    var hinges: [Hinge] = []
    var problem: String? = bounds == nil ? "manifest has no usable bounds" : nil
    if let wings = json["wings"] as? [String: Any] {
        let range = (wings["range"] as? [NSNumber])?.map(\.floatValue) ?? []
        for entry in wings["nodes"] as? [[String: Any]] ?? [] {
            guard let node = entry["node"] as? String, let pivot = vec(entry["pivot"]),
                  let lift = (entry["lift"] as? NSNumber)?.floatValue, range.count == 2 else {
                problem = "manifest wings entry \(entry) is incomplete"
                continue
            }
            hinges.append(Hinge(node: node, pivot: pivot, sign: lift,
                                pose: .flap(down: range[0], up: range[1])))
        }
    }
    if let blades = json["blades"] as? [String: Any] {
        if let node = blades["node"] as? String, let hub = vec(blades["hub"]),
           let turn = (blades["turn"] as? NSNumber)?.floatValue {
            hinges.append(Hinge(node: node, pivot: hub, sign: turn, pose: .blades))
        } else {
            problem = "manifest blades \(blades) is incomplete"
        }
    }
    return (Manifest(kind: json["kind"] as? String, bounds: bounds,
                     sheetAspect: (json["sheetAspect"] as? NSNumber)?.floatValue,
                     turretPivot: vec((json["turret"] as? [String: Any])?["pivot"]),
                     hinges: hinges),
            problem)
}

// MARK: - Geometry reading

/// Every vector in a source, widened to Float. Nil for integer-encoded sources, which a
/// Blender export does not produce and which this probe would misread rather than decode.
func vectors(of source: SCNGeometrySource) -> [[Float]]? {
    guard source.usesFloatComponents, [4, 8].contains(source.bytesPerComponent) else { return nil }
    let width = source.bytesPerComponent
    return source.data.withUnsafeBytes { raw in
        (0..<source.vectorCount).map { i in
            let base = source.dataOffset + i * source.dataStride
            return (0..<source.componentsPerVector).map { k in
                let at = base + k * width
                return width == 4 ? raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                                  : Float(raw.loadUnaligned(fromByteOffset: at, as: Double.self))
            }
        }
    }
}

func points(of source: SCNGeometrySource) -> [SIMD3<Float>]? {
    guard source.componentsPerVector >= 3 else { return nil }
    return vectors(of: source)?.map { SIMD3($0[0], $0[1], $0[2]) }
}

func indices(of element: SCNGeometryElement) -> [Int] {
    let width = element.bytesPerIndex
    let count = element.data.count / max(width, 1)
    return element.data.withUnsafeBytes { raw in
        (0..<count).map { i in
            switch width {
            case 1: return Int(raw.load(fromByteOffset: i, as: UInt8.self))
            case 2: return Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            default: return Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
            }
        }
    }
}

func typeName(_ type: SCNGeometryPrimitiveType) -> String {
    switch type {
    case .triangles: return "triangles"
    case .triangleStrip: return "triangleStrip"
    case .line: return "line"
    case .point: return "point"
    case .polygon: return "polygon"
    @unknown default: return "unknown(\(type.rawValue))"
    }
}

/// One corner of a primitive: an index per channel. A single-channel element shares one index
/// across every source; SceneKit's USD import instead gives positions, normals and UVs their
/// own channels, so position k and texcoord k need not belong to the same corner.
typealias Corner = [Int]

/// The element as triangles of corners; polygons are fanned, lines and points dropped.
func triangles(of element: SCNGeometryElement) -> [(Corner, Corner, Corner)] {
    let all = indices(of: element)
    let n = element.primitiveCount
    let channels = max(element.indicesChannelCount, 1)
    // Polygons lead with their sizes; the corners follow.
    let sizes: [Int]
    switch element.primitiveType {
    case .triangles: sizes = Array(repeating: 3, count: n)
    case .triangleStrip: sizes = []
    case .polygon: sizes = Array(all.prefix(n))
    case .line, .point: return []
    @unknown default: return []
    }
    let start = element.primitiveType == .polygon ? n : 0
    let cornerCount = element.primitiveType == .triangleStrip ? n + 2 : sizes.reduce(0, +)
    guard all.count >= start + cornerCount * channels else { return [] }
    func corner(_ k: Int) -> Corner {
        (0..<channels).map { c in
            all[start + (element.hasInterleavedIndicesChannels ? k * channels + c : c * cornerCount + k)]
        }
    }
    if element.primitiveType == .triangleStrip {
        return (0..<n).map { (i: Int) -> (Corner, Corner, Corner) in
            i % 2 == 0 ? (corner(i), corner(i + 1), corner(i + 2)) : (corner(i + 1), corner(i), corner(i + 2))
        }
    }
    var out: [(Corner, Corner, Corner)] = []
    var cursor = 0
    for size in sizes {
        if size >= 3 {
            for k in 1..<(size - 1) { out.append((corner(cursor), corner(cursor + k), corner(cursor + k + 1))) }
        }
        cursor += size
    }
    return out
}

// MARK: - Nodes

func path(of node: SCNNode, under root: SCNNode) -> String {
    var parts: [String] = []
    var cursor: SCNNode? = node
    while let n = cursor, n !== root {
        parts.append(n.name ?? "<unnamed>")
        cursor = n.parent
    }
    return "/" + parts.reversed().joined(separator: "/")
}

func geometryNodes(under root: SCNNode) -> [SCNNode] {
    var out: [SCNNode] = []
    root.enumerateHierarchy { node, _ in if node.geometry != nil { out.append(node) } }
    return out
}

/// Box of every vertex under `node`, in `root`'s space. Transforming each node's own
/// `boundingBox` corners instead is conservative under rotation — a tilted flame's box corner
/// dips below the ground its vertices never reach — so real vertices are used where readable.
func bounds(of node: SCNNode, in root: SCNNode) -> Box? {
    var box: Box?
    for n in geometryNodes(under: node) {
        let toRoot = root.simdConvertTransform(matrix_identity_float4x4, from: n)
        var local = n.geometry?.sources(for: .vertex).first.flatMap(points(of:)) ?? []
        if local.isEmpty {
            let (a, b) = n.boundingBox
            local = [a.x, b.x].flatMap { x in [a.y, b.y].flatMap { y in [a.z, b.z].map { z in
                SIMD3(Float(x), Float(y), Float(z)) } } }
        }
        for q in local {
            let p4 = toRoot * SIMD4(q, 1)
            let p = SIMD3(p4.x, p4.y, p4.z)
            box = box?.union(p) ?? Box(lo: p, hi: p)
        }
    }
    return box
}

func bounds(under root: SCNNode) -> Box? { bounds(of: root, in: root) }

func fmt(_ v: SIMD3<Float>, _ digits: Int = 4) -> String {
    "(" + [v.x, v.y, v.z].map { String(format: "%.\(digits)f", $0) }.joined(separator: ", ") + ")"
}

func transformSummary(_ node: SCNNode) -> String {
    var parts: [String] = []
    if simd_length(node.simdPosition) > 1e-7 { parts.append("pos \(fmt(node.simdPosition))") }
    if simd_length(node.simdEulerAngles) > 1e-6 {
        parts.append("euler° \(fmt(node.simdEulerAngles * 180 / .pi, 1))")
    }
    if simd_length(node.simdScale - 1) > 1e-6 { parts.append("scale \(fmt(node.simdScale, 3))") }
    return parts.isEmpty ? "" : "  [" + parts.joined(separator: ", ") + "]"
}

// MARK: - Materials

func describeContents(_ contents: Any?) -> String {
    guard let contents else { return "none" }
    var color: NSColor?
    if let c = contents as? NSColor {
        color = c
    } else if CFGetTypeID(contents as CFTypeRef) == CGColor.typeID {
        color = NSColor(cgColor: unsafeBitCast(contents as CFTypeRef, to: CGColor.self))
    }
    if let color {
        guard let s = color.usingColorSpace(.sRGB) else { return "colour (\(color))" }
        return String(format: "colour sRGB(%.3f, %.3f, %.3f, a %.2f) [%@]", s.redComponent,
                      s.greenComponent, s.blueComponent, s.alphaComponent,
                      color.colorSpace.localizedName ?? "?")
    }
    if contents is NSImage || contents is URL || contents is String
        || CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
        return "texture (\(type(of: contents)))"
    }
    if let n = contents as? NSNumber { return "number \(n)" }
    return "\(type(of: contents))"
}

// MARK: - Per-geometry analysis

struct GeometryReport {
    var triangles = 0
    var flat = 0
    var degenerate = 0
    /// Corner normals that disagree: the triangle is smooth-shaded.
    var smooth = 0
    /// Normals agree but leave the triangle's own plane: it is half of a non-planar polygon.
    var offPlane = 0
    var worstSpread: Float = 0
    var worstOffPlane: Float = 0
    var paperWithoutUV = false
    var paperUVOutOfRange = false
}

let flatLimitDegrees: Float = 1

func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let d = simd_dot(simd_normalize(a), simd_normalize(b))
    return acos(min(1, max(-1, d))) * 180 / .pi
}

func analyse(node: SCNNode, root: SCNNode, indent: String, isPlane: Bool) -> GeometryReport {
    var report = GeometryReport()
    guard let geometry = node.geometry else { return report }
    let vertexSource = geometry.sources(for: .vertex).first
    let normalSource = geometry.sources(for: .normal).first
    let uvSources = geometry.sources(for: .texcoord)
    print("\(indent)  geometry '\(geometry.name ?? "<unnamed>")': vertex \(vertexSource?.vectorCount ?? 0),"
          + " normal \(normalSource?.vectorCount ?? 0), texcoord sets \(uvSources.count)"
          + " (\(uvSources.map { "\($0.vectorCount)" }.joined(separator: ", ")))")
    for (i, element) in geometry.elements.enumerated() {
        var extra = ""
        if element.indicesChannelCount > 1 {
            extra = ", \(element.indicesChannelCount) index channels"
                + (element.hasInterleavedIndicesChannels ? " interleaved" : "")
        }
        print("\(indent)  element \(i): \(typeName(element.primitiveType)) × \(element.primitiveCount),"
              + " \(element.bytesPerIndex)-byte indices\(extra)")
    }

    var uvSets: [[SIMD2<Float>]] = []
    for (set, source) in uvSources.enumerated() {
        let uv = (vectors(of: source) ?? []).compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
        uvSets.append(uv)
        guard let first = uv.first else { continue }
        let lo = uv.reduce(first, simd_min), hi = uv.reduce(first, simd_max)
        print("\(indent)  uv set \(set): u \(String(format: "%.4f..%.4f", lo.x, hi.x)),"
              + " v \(String(format: "%.4f..%.4f", lo.y, hi.y))")
    }

    for material in geometry.materials {
        print("\(indent)  material '\(material.name ?? "<unnamed>")': lighting \(material.lightingModel.rawValue),"
              + " doubleSided \(material.isDoubleSided)")
        print("\(indent)    diffuse  \(describeContents(material.diffuse.contents))")
        print("\(indent)    emission \(describeContents(material.emission.contents))")
    }
    let isPaper = geometry.materials.contains { $0.name == "paper" }
    if isPaper {
        if let uv = uvSets.first, !uv.isEmpty {
            // Written as "not inside", because a NaN compares false against both ends of a range
            // and would otherwise count as in range.
            let unit: ClosedRange<Float> = -1e-4...(1 + 1e-4)
            report.paperUVOutOfRange = uv.contains { !(unit.contains($0.x) && unit.contains($0.y)) }
        } else {
            report.paperWithoutUV = true
        }
    }

    guard let vertexSource, let positions = points(of: vertexSource) else {
        print("\(indent)  (vertex source unreadable — flatness skipped)")
        return report
    }
    let normals = normalSource.flatMap(points(of:))
    if let mapping = geometry.geometrySourceChannels {
        let names = geometry.sources.map { $0.semantic.rawValue }
        print("\(indent)  source channels: " + zip(names, mapping).map { "\($0)→\($1)" }.joined(separator: ", "))
    }
    func channel(_ source: SCNGeometrySource?, in element: SCNGeometryElement) -> Int {
        guard let source, let mapping = geometry.geometrySourceChannels,
              let at = geometry.sources.firstIndex(where: { $0 === source }), at < mapping.count
        else { return 0 }
        return min(mapping[at].intValue, max(element.indicesChannelCount, 1) - 1)
    }
    // Position and first-set UV at every triangle corner, for locating the sheet's ends.
    var cornerUV: [(SIMD3<Float>, SIMD2<Float>)] = []
    let firstUV = uvSets.first ?? []
    for element in geometry.elements {
        let p = channel(vertexSource, in: element)
        let nc = channel(normalSource, in: element)
        let tc = channel(uvSources.first, in: element)
        for (ca, cb, cc) in triangles(of: element) {
            let (a, b, c) = (ca[p], cb[p], cc[p])
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            for corner in [ca, cb, cc] where corner[tc] < firstUV.count {
                cornerUV.append((positions[corner[p]], firstUV[corner[tc]]))
            }
            report.triangles += 1
            let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            guard simd_length(face) > 1e-12 else { report.degenerate += 1; continue }
            let ns = [ca[nc], cb[nc], cc[nc]].compactMap { k in normals.flatMap { k < $0.count ? $0[k] : nil } }
            // No normals at all: nothing guarantees a flat look.
            var spread: Float = 180, off: Float = 0
            if ns.count == 3 {
                spread = max(angleDegrees(ns[0], ns[1]), angleDegrees(ns[1], ns[2]), angleDegrees(ns[0], ns[2]))
                off = ns.map { n in
                    let toFace = angleDegrees(n, face)
                    return min(toFace, 180 - toFace)  // face normal, either sign
                }.max()!
            }
            report.worstSpread = max(report.worstSpread, spread)
            report.worstOffPlane = max(report.worstOffPlane, off)
            if spread >= flatLimitDegrees { report.smooth += 1 }
            else if off >= flatLimitDegrees { report.offPlane += 1 }
            else { report.flat += 1 }
        }
    }
    let considered = report.triangles - report.degenerate
    print("\(indent)  flatness: \(report.flat)/\(considered) triangles flat (< \(Int(flatLimitDegrees))°);"
          + " \(report.smooth) smooth-shaded (worst normal spread \(String(format: "%.2f", report.worstSpread))°),"
          + " \(report.offPlane) off their own plane (worst \(String(format: "%.2f", report.worstOffPlane))°)"
          + (report.degenerate > 0 ? ", \(report.degenerate) degenerate skipped" : ""))

    // Which end of the sheet points where, in SceneKit's own texcoords: the contract puts the
    // nose at v = 1, so this shows whether the importer flipped v in the data it hands over.
    if isPaper, let vHi = cornerUV.map(\.1.y).max(), let vLo = cornerUV.map(\.1.y).min(), vHi - vLo > 1e-4 {
        func centroid(_ keep: (Float) -> Bool) -> SIMD3<Float> {
            let picked = cornerUV.filter { keep($0.1.y) }.map { root.simdConvertPosition($0.0, from: node) }
            return picked.reduce(.zero, +) / Float(max(picked.count, 1))
        }
        let high = centroid { $0 > vHi - 1e-3 }, low = centroid { $0 < vLo + 1e-3 }
        print("\(indent)  paper v: v=\(String(format: "%.3f", vHi)) end at \(fmt(high)),"
              + " v=\(String(format: "%.3f", vLo)) end at \(fmt(low)) → high-v end lies toward"
              + " root \(dominantAxis(high - low))")
        // Read in root axes, which are Blender's: the axis verdict below confirms it per file.
        if isPlane {
            let toward = dominantAxis(high - low)
            print("\(indent)  paper v verdict: " + (toward == "-X"
                ? "SceneKit stores t = 1 - v (flipped for its top-left texture origin); the authored nose (v = 1) is t = 0"
                : toward == "+X" ? "SceneKit keeps v as authored; the nose is t = 1"
                : "the sheet's length does not lie along X — check the export"))
        }
    }
    return report
}

func dominantAxis(_ d: SIMD3<Float>) -> String {
    let axes = ["X", "Y", "Z"]
    let i = [abs(d.x), abs(d.y), abs(d.z)].enumerated().max { $0.element < $1.element }!.offset
    return (d[i] >= 0 ? "+" : "-") + axes[i]
}

// MARK: - Axis mapping

/// A proper rotation that sends Blender axes onto SceneKit root axes: root[i] = sign[i] * blender[source[i]].
struct AxisMap: Equatable {
    let source: [Int]
    let sign: [Float]

    static let identity = AxisMap(source: [0, 1, 2], sign: [1, 1, 1])
    /// The usual Z-up → Y-up conversion: (x, y, z) → (x, z, -y).
    static let yUp = AxisMap(source: [0, 2, 1], sign: [1, 1, -1])

    var matrix: simd_float3x3 {
        var m = simd_float3x3(0)
        for i in 0..<3 { m[source[i]][i] = sign[i] }  // column = Blender axis, row = root axis
        return m
    }

    var description: String {
        let names = ["X", "Y", "Z"]
        return (0..<3).map { "root \(names[$0]) = \(sign[$0] < 0 ? "-" : "+")Blender \(names[source[$0]])" }
            .joined(separator: ", ")
    }

    func apply(_ b: Box) -> Box {
        var lo = SIMD3<Float>(), hi = SIMD3<Float>()
        for i in 0..<3 {
            let j = source[i]
            lo[i] = sign[i] > 0 ? b.lo[j] : -b.hi[j]
            hi[i] = sign[i] > 0 ? b.hi[j] : -b.lo[j]
        }
        return Box(lo: lo, hi: hi)
    }

    static var properRotations: [AxisMap] {
        let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        var out: [AxisMap] = []
        for p in perms {
            for s in 0..<8 {
                let map = AxisMap(source: p, sign: (0..<3).map { s & (1 << $0) != 0 ? -1 : 1 })
                if simd_determinant(map.matrix) > 0 { out.append(map) }
            }
        }
        return out
    }
}

func deviation(_ a: Box, _ b: Box) -> Float {
    max(simd_reduce_max(simd_abs(a.lo - b.lo)), simd_reduce_max(simd_abs(a.hi - b.hi)))
}

let boundsTolerance: Float = 0.001

/// The runtime's world is Y-up with the nose at +X and the left at -Z: world = (bx, bz, -by).
/// Given how the import maps Blender to root, the pivot is whatever takes root to that.
func pivotRotation(for map: AxisMap) -> simd_quatf {
    simd_quatf(AxisMap.yUp.matrix * map.matrix.transpose)
}

func anglesCode(_ e: SIMD3<Float>) -> String {
    func term(_ a: Float) -> String {
        let quarters = (a / (.pi / 2)).rounded()
        guard abs(a - quarters * .pi / 2) < 1e-4 else { return String(format: "%.6f", a) }
        switch Int(quarters) {
        case 0: return "0"
        case 1: return "Float.pi / 2"
        case -1: return "-Float.pi / 2"
        case 2: return "Float.pi"
        case -2: return "-Float.pi"
        default: return "\(Int(quarters)) * Float.pi / 2"
        }
    }
    return "SCNVector3(\(term(e.x)), \(term(e.y)), \(term(e.z)))"
}

// MARK: - Rendering

let renderSize = CGSize(width: 800, height: 600)
let background = NSColor(srgbRed: 0x6f / 255.0, green: 0x8a / 255.0, blue: 0x5e / 255.0, alpha: 1)

func writePNG(_ image: NSImage, to url: URL) -> Bool {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: url)) != nil
}

/// A sheet of lined notebook paper in the USD texture convention: v = 0 is the image's bottom
/// row, so the unruled header band at v near 1 is drawn at the top of the image.
func linedPaper(aspect: Float) -> NSImage? {
    let width = 1024, height = Int((Float(width) * aspect).rounded())
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let w = CGFloat(width), h = CGFloat(height)
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.96, blue: 0.91, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // CG's origin is bottom-left, so y = v * h.
    ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.66, blue: 0.92, alpha: 1))
    ctx.setLineWidth(h * 0.004)
    var v: CGFloat = 0.025
    while v < 0.88 {
        ctx.move(to: CGPoint(x: 0, y: v * h)); ctx.addLine(to: CGPoint(x: w, y: v * h))
        v += 0.025
    }
    ctx.strokePath()
    ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1))
    ctx.setLineWidth(w * 0.006)
    ctx.move(to: CGPoint(x: 0.15 * w, y: 0)); ctx.addLine(to: CGPoint(x: 0.15 * w, y: h))
    ctx.strokePath()
    guard let image = ctx.makeImage() else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: width, height: height))
}

struct Stage {
    let renderer: SCNRenderer
    let top: SCNNode
    let threeQuarter: SCNNode
}

/// Puts the model under the runtime's pivot, centres it, and adds lights and both cameras.
func stage(scene: SCNScene, pivotRotation: simd_quatf, device: MTLDevice) -> Stage? {
    let pivot = SCNNode()
    pivot.name = "probe_pivot"
    pivot.simdOrientation = pivotRotation
    for child in scene.rootNode.childNodes { pivot.addChildNode(child) }
    let holder = SCNNode()
    holder.addChildNode(pivot)
    scene.rootNode.addChildNode(holder)
    guard let box = bounds(under: holder) else { return nil }
    pivot.simdPosition = -box.center
    let extent = box.extent
    let radius = max(simd_length(extent) / 2, 1e-4)

    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 350
    ambient.color = NSColor.white
    let ambientNode = SCNNode()
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)

    let sun = SCNLight()
    sun.type = .directional
    sun.intensity = 1000
    sun.color = NSColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 1)
    let sunNode = SCNNode()
    sunNode.light = sun
    // Above, front (+X) and left (-Z in the runtime's world), about 50° up.
    sunNode.simdPosition = simd_normalize(SIMD3<Float>(0.6, 1.0, -0.5)) * radius * 10
    sunNode.simdLook(at: .zero, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    scene.rootNode.addChildNode(sunNode)

    // Straight down, nose (+X) up the image: the image's vertical is X, its horizontal is Z.
    let topCamera = SCNCamera()
    topCamera.usesOrthographicProjection = true
    let aspect = Float(renderSize.width / renderSize.height)
    topCamera.orthographicScale = Double(max(extent.x / 2, extent.z / 2 / aspect) / 0.7)
    topCamera.zNear = Double(radius) * 0.1
    topCamera.zFar = Double(radius) * 40
    let top = SCNNode()
    top.camera = topCamera
    top.simdPosition = SIMD3(0, radius * 10, 0)
    top.simdLook(at: .zero, up: SIMD3(1, 0, 0), localFront: SIMD3(0, 0, -1))
    scene.rootNode.addChildNode(top)

    let fov: Float = 30
    let perspective = SCNCamera()
    perspective.fieldOfView = CGFloat(fov)
    perspective.zNear = Double(radius) * 0.05
    perspective.zFar = Double(radius) * 40
    let threeQuarter = SCNNode()
    threeQuarter.camera = perspective
    let distance = radius / (0.7 * tan(fov / 2 * .pi / 180))
    threeQuarter.simdPosition = simd_normalize(SIMD3<Float>(1, 0.85, -0.9)) * distance
    threeQuarter.simdLook(at: .zero, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    scene.rootNode.addChildNode(threeQuarter)

    scene.background.contents = background
    scene.lightingEnvironment.contents = nil
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.autoenablesDefaultLighting = false
    return Stage(renderer: renderer, top: top, threeQuarter: threeQuarter)
}

/// How the import mapped the Blender axes, judged against the manifest's bounds (which are in
/// Blender axes). Identity when there is nothing to judge by or nothing fits.
func axisVerdict(box: Box, manifest: Manifest?, failures: inout [String]) -> AxisMap {
    var map = AxisMap.identity
    if let reference = manifest?.bounds {
        print("  manifest (Blender axes): min \(fmt(reference.lo, 6)) max \(fmt(reference.hi, 6))")
        let fits = AxisMap.properRotations.filter { deviation($0.apply(reference), box) <= boundsTolerance }
        if fits.contains(.identity) {
            print("  verdict: SceneKit keeps the Blender axes — no Z-up→Y-up conversion"
                  + " (X = nose, Y = left, Z = up)"
                  + (fits.count > 1 ? "; \(fits.count) rotations fit these symmetric bounds, identity among them" : ""))
        } else if let first = fits.first {
            map = fits.contains(.yUp) ? .yUp : first
            print("  verdict: SceneKit remaps the Blender axes: \(map.description)"
                  + (fits.count > 1 ? " (\(fits.count) rotations fit)" : ""))
        } else {
            let best = AxisMap.properRotations.min {
                deviation($0.apply(reference), box) < deviation($1.apply(reference), box)
            }!
            let off = deviation(best.apply(reference), box)
            print(String(format: "  verdict: no axis mapping matches the manifest within 1 mm;"
                         + " closest is %@ at %.2f mm; keeping Blender axes for the pivot", best.description, off * 1000))
            failures.append(String(format: "bounds mismatch vs manifest (%.2f mm)", off * 1000))
        }
        let off = deviation(map.apply(reference), box)
        print(String(format: "  max deviation from manifest under that mapping: %.4f mm", off * 1000))
    } else {
        print("  verdict: no manifest bounds to compare; assuming the import keeps the Blender axes")
    }
    return map
}

/// Every `flame_<n>` node, each checked for an origin at its base: local min z of 0, and — for an
/// upright flame — a lowest point that holds still when the node is scaled.
func checkFlames(root: SCNNode, map: AxisMap, failures: inout [String]) -> [SCNNode] {
    var flames: [SCNNode] = []
    root.enumerateHierarchy { node, _ in
        if let n = node.name, n.range(of: #"^flame_\d+$"#, options: .regularExpression) != nil {
            flames.append(node)
        }
    }
    if !flames.isEmpty {
        let axes = ["X", "Y", "Z"]
        let upAxis = map.source.firstIndex(of: 2)!
        print("-- flames (root-space up axis is \(axes[upAxis]))")
        for flame in flames {
            let localMin = flame.geometry.flatMap { g in
                g.sources(for: .vertex).first.flatMap(points(of:)).flatMap { $0.map(\.z).min() }
            }
            let original = flame.simdScale
            let before = bounds(of: flame, in: root)
            flame.simdScale = original * 1.5
            let after = bounds(of: flame, in: root)
            flame.simdScale = original
            print("  \(path(of: flame, under: root))  pos \(fmt(flame.simdPosition))"
                  + " euler° \(fmt(flame.simdEulerAngles * 180 / .pi, 1)) scale \(fmt(flame.simdScale, 3))")
            print("    geometry local min z: "
                  + (localMin.map { String(format: "%.6f", $0) } ?? "no geometry on this node"))
            if let localMin, abs(localMin) > boundsTolerance {
                failures.append("\(flame.name!) origin is not at its base")
            }
            guard let before, let after else { continue }
            print("    root-space box \(fmt(before.lo, 6)) .. \(fmt(before.hi, 6))")
            // Scaling about the origin moves nothing on the plane through the origin. That plane is
            // the flame's base when local min z is 0, so the lowest point holds still — exactly for
            // an upright flame; a tilted base plane is not level, so its low edge moves inward.
            let up = SIMD3<Float>(0, 0, 1)
            let localUp = simd_normalize(root.simdConvertVector(up, from: flame))
            let tilt = angleDegrees(localUp, map.matrix * up)
            let shift = abs(after.lo[upAxis] - before.lo[upAxis])
            print(String(format: "    root-space min %@ at scale 1: %.6f, at 1.5: %.6f (shift %.4f mm);"
                         + " max %@ %.6f → %.6f; tilt %.1f°", axes[upAxis], before.lo[upAxis],
                         after.lo[upAxis], shift * 1000, axes[upAxis], before.hi[upAxis],
                         after.hi[upAxis], tilt))
            if tilt < 0.5, shift > boundsTolerance {
                failures.append("\(flame.name!) does not scale about its base")
            }
        }
    }
    return flames
}

/// A tank's `turret` node: where it pivots, whether its own z is the model's up, which way the
/// barrel points, and whether turning it about its own z keeps it seated on its ring. The
/// runtime aims a turret exactly so — `turret.simdOrientation = rest * quat(angle, (0, 0, 1))`.
func checkTurret(root: SCNNode, map: AxisMap, manifest: Manifest?, failures: inout [String]) -> SCNNode? {
    var turrets: [SCNNode] = []
    root.enumerateHierarchy { node, _ in if node.name == "turret" { turrets.append(node) } }
    guard let turret = turrets.first else {
        if manifest?.kind == "tank" { failures.append("tank has no node named turret") }
        return nil
    }
    if turrets.count > 1 { failures.append("\(turrets.count) nodes named turret") }
    let axes = ["X", "Y", "Z"]
    let upAxis = map.source.firstIndex(of: 2)!
    let pivot = root.simdConvertPosition(.zero, from: turret)
    let localMin = turret.geometry.flatMap { g in
        g.sources(for: .vertex).first.flatMap(points(of:)).flatMap { $0.map(\.z).min() }
    }
    let tilt = angleDegrees(root.simdConvertVector(SIMD3(0, 0, 1), from: turret), map.matrix * SIMD3(0, 0, 1))
    print("-- turret (root-space up axis is \(axes[upAxis]))")
    print("  \(path(of: turret, under: root))  pivot \(fmt(pivot, 6))\(transformSummary(turret))")
    print("    geometry local min z: " + (localMin.map { String(format: "%.6f", $0) } ?? "no geometry on this node")
          + String(format: "; own z vs Blender up: %.2f°", tilt))
    if turret.geometry == nil { failures.append("turret node carries no geometry") }
    if let localMin, abs(localMin) > boundsTolerance { failures.append("turret origin is not at its foot") }
    if tilt > 0.5 { failures.append("turret's own z is not the model's up") }
    if let expected = manifest?.turretPivot {
        let off = simd_length(pivot - map.matrix * expected)
        print(String(format: "    manifest pivot (Blender axes) %@, off by %.4f mm", fmt(expected, 6), off * 1000))
        if off > boundsTolerance { failures.append(String(format: "turret pivot %.2f mm from the manifest's", off * 1000)) }
    } else if manifest?.kind == "tank" {
        failures.append("manifest has no turret pivot")
    }
    guard let rest = bounds(of: turret, in: root) else { return turret }
    var reach = rest.center - pivot
    reach[upAxis] = 0
    let forward = dominantAxis(map.matrix * SIMD3(1, 0, 0))
    print("    barrel points toward root \(dominantAxis(reach)) (Blender +X is root \(forward))")
    if dominantAxis(reach) != forward { failures.append("turret's barrel does not point along Blender +X") }

    let original = turret.simdOrientation
    for degrees: Float in [45, 90, 180] {
        turret.simdOrientation = original * simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 0, 1))
        let drift = simd_length(root.simdConvertPosition(.zero, from: turret) - pivot)
        guard let box = bounds(of: turret, in: root) else { continue }
        let foot = abs(box.lo[upAxis] - rest.lo[upAxis]), top = abs(box.hi[upAxis] - rest.hi[upAxis])
        print(String(format: "    turned %3.0f°: pivot drift %.4f mm, foot moved %.4f mm, top moved %.4f mm",
                     degrees, drift * 1000, foot * 1000, top * 1000))
        if max(drift, foot, top) > boundsTolerance {
            failures.append(String(format: "turret does not turn cleanly about its origin at %.0f°", degrees))
        }
    }
    turret.simdOrientation = original
    return turret
}

/// Every node the manifest says turns about its own X axis — a crane's wings, a windmill's
/// blades — checked the way the runtime turns it: `node.simdOrientation = rest * quat(angle,
/// (1, 0, 0))`. Its origin must be where the manifest puts the pivot, its own X must be the
/// model's X, and at every angle each vertex must keep both its place along the axis and its
/// distance from it: anything else is a wobble, a shear or a pivot off the hinge line.
func checkHinges(root: SCNNode, map: AxisMap, manifest: Manifest?,
                 failures: inout [String]) -> [(SCNNode, Hinge)] {
    guard let hinges = manifest?.hinges, !hinges.isEmpty else { return [] }
    let axis = map.matrix * SIMD3<Float>(1, 0, 0)
    print("-- hinges (turned about their own X; Blender +X is root \(dominantAxis(axis)))")
    var found: [(SCNNode, Hinge)] = []
    for hinge in hinges {
        guard let node = root.childNode(withName: hinge.node, recursively: true) else {
            failures.append("no node named \(hinge.node)")
            continue
        }
        guard let local = node.geometry?.sources(for: .vertex).first.flatMap(points(of:)),
              !local.isEmpty else {
            failures.append("\(hinge.node) carries no readable geometry")
            continue
        }
        let pivot = root.simdConvertPosition(.zero, from: node)
        let off = simd_length(pivot - map.matrix * hinge.pivot)
        let tilt = angleDegrees(root.simdConvertVector(SIMD3(1, 0, 0), from: node), axis)
        print("  \(path(of: node, under: root))  pivot \(fmt(pivot, 6))\(transformSummary(node))")
        print(String(format: "    manifest pivot (Blender axes) %@, off by %.4f mm; own X vs Blender X: %.2f°",
                     fmt(hinge.pivot, 6), off * 1000, tilt))
        if off > boundsTolerance { failures.append(String(format: "\(hinge.node) pivot %.2f mm from the manifest's", off * 1000)) }
        if tilt > 0.5 { failures.append("\(hinge.node)'s own X is not the model's X") }

        let rest = node.simdOrientation
        let before = local.map { root.simdConvertPosition($0, from: node) }
        func radius(_ p: SIMD3<Float>) -> Float {
            let d = p - pivot
            return simd_length(d - simd_dot(d, axis) * axis)
        }
        let reach = before.map(radius).max() ?? 0
        for degrees in hinge.pose.checked {
            node.simdOrientation = rest * simd_quatf(angle: hinge.sign * degrees * .pi / 180, axis: SIMD3(1, 0, 0))
            let drift = simd_length(root.simdConvertPosition(.zero, from: node) - pivot)
            var along: Float = 0, across: Float = 0
            for (q, b) in zip(local, before) {
                let a = root.simdConvertPosition(q, from: node)
                along = max(along, abs(simd_dot(a - b, axis)))
                across = max(across, abs(radius(a) - radius(b)))
            }
            print(String(format: "    %@ %5.1f°: pivot drift %.4f mm, worst shift along the axis %.4f mm,"
                         + " worst change of reach %.4f mm (reach %.4f m)",
                         hinge.pose.name, degrees, drift * 1000, along * 1000, across * 1000, reach))
            if max(drift, along, across) > boundsTolerance {
                failures.append(String(format: "\(hinge.node) does not turn cleanly about its hinge at %.1f°", degrees))
            }
        }
        node.simdOrientation = rest
        found.append((node, hinge))
    }
    return found
}

/// A parachute hangs from its origin: its lowest points are the knot, on its up axis.
func checkKnot(root: SCNNode, map: AxisMap, failures: inout [String]) {
    let up = map.matrix * SIMD3<Float>(0, 0, 1)
    var all: [SIMD3<Float>] = []
    for node in geometryNodes(under: root) {
        for p in node.geometry?.sources(for: .vertex).first.flatMap(points(of:)) ?? [] {
            all.append(root.simdConvertPosition(p, from: node))
        }
    }
    guard let lowest = all.map({ simd_dot($0, up) }).min() else { return }
    let knot = all.filter { simd_dot($0, up) < lowest + 1e-4 }
    let worst = knot.map { simd_length($0 - simd_dot($0, up) * up) }.max() ?? 0
    print(String(format: "-- knot: lowest point %.6f m up, %d vertices there, furthest %.4f mm off the axis",
                 lowest, knot.count, worst * 1000))
    if abs(lowest) > boundsTolerance || worst > boundsTolerance {
        failures.append("the parachute does not hang from its origin")
    }
}

// MARK: - Probe one file

func probe(_ url: URL, options: Options, device: MTLDevice) -> [String] {
    var failures: [String] = []
    let name = url.deletingPathExtension().lastPathComponent
    print("\n=== \(url.path)")
    let scene: SCNScene
    do {
        scene = try SCNScene(url: url, options: [.checkConsistency: true])
    } catch {
        print("  load failed: \(error.localizedDescription)")
        return ["did not load"]
    }
    let (manifest, manifestProblem) = loadManifest(beside: url)
    if let manifestProblem { failures.append(manifestProblem) }
    let root = scene.rootNode

    print("-- node tree")
    var reports: [GeometryReport] = []
    root.enumerateHierarchy { node, _ in
        var depth = 0
        var cursor = node.parent
        while let c = cursor { depth += 1; cursor = c.parent }
        let indent = String(repeating: "  ", count: depth + 1)
        print("\(indent)\(node === root ? "<scene root>" : path(of: node, under: root))"
              + "\(node.geometry == nil ? "" : "  (geometry)")\(transformSummary(node))")
        if node.geometry != nil { reports.append(analyse(node: node, root: root, indent: indent, isPlane: manifest?.kind == "plane")) }
    }
    guard !reports.isEmpty, let box = bounds(under: root) else {
        print("  no geometry")
        return failures + ["no geometry"]
    }

    let considered = reports.reduce(0) { $0 + $1.triangles - $1.degenerate }
    let flat = reports.reduce(0) { $0 + $1.flat }
    print(String(format: "-- flatness: %d/%d triangles flat (%.1f%%)", flat, considered,
                 considered > 0 ? 100 * Double(flat) / Double(considered) : 0))
    let smooth = reports.reduce(0) { $0 + $1.smooth }
    let offPlane = reports.reduce(0) { $0 + $1.offPlane }
    if smooth > 0 { failures.append("\(smooth) smooth-shaded triangles") }
    if offPlane > 0 {
        failures.append(String(format: "%d triangles off their face normal — non-planar polygons, worst %.2f°",
                               offPlane, reports.map(\.worstOffPlane).max() ?? 0))
    }
    if reports.contains(where: \.paperWithoutUV) { failures.append("paper material has no UVs") }
    if reports.contains(where: \.paperUVOutOfRange) { failures.append("paper UVs outside [0,1]") }

    print("-- bounds in SceneKit root space")
    let axes = ["X", "Y", "Z"]
    for i in 0..<3 {
        print(String(format: "  %@: %.6f .. %.6f  (extent %.6f)", axes[i], box.lo[i], box.hi[i], box.extent[i]))
    }

    let map = axisVerdict(box: box, manifest: manifest, failures: &failures)

    let isFire = name == "fire" || manifest?.kind == "fire"
    let flames = checkFlames(root: root, map: map, failures: &failures)
    if isFire && flames.isEmpty { failures.append("fire model has no flame_<n> nodes") }
    let turret = checkTurret(root: root, map: map, manifest: manifest, failures: &failures)
    let hinged = checkHinges(root: root, map: map, manifest: manifest, failures: &failures)
    if manifest?.kind == "bird", hinged.count != 2 { failures.append("a bird needs wing_l and wing_r") }
    if manifest?.kind == "parachute" { checkKnot(root: root, map: map, failures: &failures) }

    // Rendering: the runtime renders paper double-sided, so the probe does too.
    let rotation = pivotRotation(for: map)
    let shown = SCNNode()
    shown.simdOrientation = rotation
    print("-- runtime pivot: pivot.eulerAngles = \(anglesCode(shown.simdEulerAngles))")
    geometryNodes(under: root).forEach { $0.geometry?.materials.forEach { $0.isDoubleSided = true } }
    guard let staged = stage(scene: scene, pivotRotation: rotation, device: device) else {
        return failures + ["could not stage the render"]
    }
    try? FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
    func render(_ camera: SCNNode, _ suffix: String) {
        staged.renderer.pointOfView = camera
        let image = staged.renderer.snapshot(atTime: 0, with: renderSize, antialiasingMode: .multisampling4X)
        let out = options.outDir.appendingPathComponent("\(name)_\(suffix).png")
        if writePNG(image, to: out) { print("  rendered \(out.path)") } else { failures.append("could not write \(out.lastPathComponent)") }
    }
    render(staged.top, "top")
    render(staged.threeQuarter, "34")
    if let turret {
        let rest = turret.simdOrientation
        for degrees in [45, 90] {
            turret.simdOrientation = rest * simd_quatf(angle: Float(degrees) * .pi / 180, axis: SIMD3(0, 0, 1))
            render(staged.top, "top_turret_\(degrees)")
        }
        turret.simdOrientation = rest
    }
    // Every hinge of one pose together, as the runtime drives them: both wings, or the blades.
    let poses = Dictionary(grouping: hinged, by: { $0.1.pose })
    for (pose, members) in poses.sorted(by: { $0.key.name < $1.key.name }) {
        let rests = members.map { $0.0.simdOrientation }
        for degrees in pose.drawn {
            for (node, hinge) in members {
                node.simdOrientation = node.simdOrientation * simd_quatf(angle: hinge.sign * degrees * .pi / 180, axis: SIMD3(1, 0, 0))
            }
            render(staged.top, "top_\(pose.name)_\(Int(degrees))")
            render(staged.threeQuarter, "34_\(pose.name)_\(Int(degrees))")
            for (k, (node, _)) in members.enumerated() { node.simdOrientation = rests[k] }
        }
    }
    if options.lined {
        let papers = geometryNodes(under: scene.rootNode).flatMap { $0.geometry!.materials }.filter { $0.name == "paper" }
        if papers.isEmpty {
            print("  --lined: no material named 'paper'; skipped")
        } else if let sheet = linedPaper(aspect: manifest?.sheetAspect ?? 11 / 8.5) {
            for material in papers {
                material.diffuse.contents = sheet
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.diffuse.mipFilter = .linear
            }
            render(staged.top, "top_lined")
        }
    }
    return failures
}

// MARK: - Main

let options = parseOptions()
guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("error: no Metal device\n".utf8))
    exit(1)
}
var summary: [String] = []
for file in options.files {
    let failures = probe(file, options: options, device: device)
    summary.append((failures.isEmpty ? "OK   " : "FAIL ") + file.lastPathComponent
                   + (failures.isEmpty ? "" : " — " + failures.joined(separator: "; ")))
}
print("\n=== summary")
summary.forEach { print($0) }
exit(summary.allSatisfy { $0.hasPrefix("OK") } ? 0 : 1)
