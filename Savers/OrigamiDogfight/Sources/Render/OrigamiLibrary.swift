// The Blender-built models, as the runtime sees them — or, when one is missing, nothing, and
// the caller draws a stand-in.
//
// `tools/build-origami-library.py` writes one `<name>.usdz` and `<name>.json` per model into
// `Savers/OrigamiDogfight/Assets/`, plus an `index.json`, and `build-saver.sh` copies the
// directory flat into the bundle's Resources. The contract is `docs/origami-plan.md` §Asset
// contract. Everything here fails soft: no directory, no index, a manifest that does not
// parse or names a file that is not there — each costs one model, which is then drawn in code,
// and never a black screen.

import Foundation
import SceneKit
import simd

/// A model ready to clone: in SceneKit's Y-up space, nose (or front) toward +X, anchored either
/// at its centre or with its base on y = 0, at the size it was authored.
struct ModelTemplate {
    let node: SCNNode
    /// Bounding size in the template's own space.
    let extent: SIMD3<Float>
    /// Height over width of a plane's sheet, for drawing its paper at the right proportions.
    let sheetAspect: Float
    let isStandIn: Bool

    /// A clone at a uniform scale.
    func instance(scale: Float) -> SCNNode {
        let holder = SCNNode()
        holder.simdScale = SIMD3(repeating: scale)
        holder.addChildNode(node.clone())
        let outer = SCNNode()
        outer.addChildNode(holder)
        return outer
    }

    /// A clone scaled so its `axis` extent measures `size`.
    func instance(size: Float, along axis: ModelAxis) -> SCNNode {
        let measure: Float
        switch axis {
        case .length: measure = extent.x
        case .height: measure = extent.y
        case .longest: measure = max(extent.x, extent.y, extent.z)
        case .footprint: measure = max(extent.x, extent.z)
        }
        let holder = SCNNode()
        let scale = size / max(measure, 1e-5)
        holder.simdScale = SIMD3(repeating: scale)
        holder.addChildNode(node.clone())
        let outer = SCNNode()
        outer.addChildNode(holder)
        return outer
    }
}

enum ModelAxis { case length, height, longest, footprint }
/// Where a template's origin sits: the centre of its bounds, the middle of its base, or where the
/// model itself put it — the parachute's is the knot its strings meet at, which is what ties it
/// to a crate.
enum ModelAnchor { case center, base, origin }

final class OrigamiLibrary {
    struct Entry {
        let name: String
        let kind: String
        let asset: URL
        let sheetAspect: Float?
    }

    private(set) var entries: [Entry] = []
    private var loaded: [String: ModelTemplate] = [:]
    private var failed: Set<String> = []

    /// `directory` is the bundle's Resources — always resolved from `HostContext.bundle`, never
    /// `Bundle.main`, which inside a screensaver is the host appex and finds nothing.
    init(directory: URL?) {
        guard let directory else { return }
        let fm = FileManager.default
        var manifestURLs: [URL] = []
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let json = try? JSONSerialization.jsonObject(with: data) {
            // Accept either {"models": [...]} or a bare list, of manifest file names or of
            // model names — the emitter is being written alongside this, and a format detail
            // must not cost the whole library.
            let list = (json as? [String: Any])?["models"] as? [Any] ?? json as? [Any] ?? []
            for item in list {
                let raw = (item as? String) ?? ((item as? [String: Any])?["name"] as? String) ?? ""
                guard !raw.isEmpty else { continue }
                // `lastPathComponent` keeps an entry from reaching outside the directory.
                var file = URL(fileURLWithPath: raw).lastPathComponent
                if !file.hasSuffix(".json") { file += ".json" }
                manifestURLs.append(directory.appendingPathComponent(file))
            }
        } else if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // No index: every manifest beside its model still counts.
            manifestURLs = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        for url in manifestURLs {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = manifest["name"] as? String,
                  let kind = manifest["kind"] as? String
            else { continue }
            let assetName = URL(fileURLWithPath: (manifest["asset"] as? String) ?? "\(name).usdz").lastPathComponent
            let asset = directory.appendingPathComponent(assetName)
            guard fm.fileExists(atPath: asset.path) else { continue }
            // Bounded here because it sizes a generated bitmap: a manifest that parses but says
            // something absurd would otherwise trap converting it, or allocate gigabytes, inside
            // the host. Anything outside what a sheet of paper could be falls back to letter.
            let aspect = ((manifest["sheetAspect"] as? NSNumber)?.floatValue)
                .flatMap { $0.isFinite && (0.25...4).contains($0) ? $0 : nil }
            entries.append(Entry(name: name, kind: kind, asset: asset, sheetAspect: aspect))
        }
    }

    func names(ofKind kind: String) -> [String] {
        entries.filter { $0.kind == kind }.map(\.name)
    }

    func has(_ name: String) -> Bool { entries.contains { $0.name == name } }

    /// Nil when the model is absent or unreadable; the caller draws a stand-in.
    func template(named name: String, anchor: ModelAnchor) -> ModelTemplate? {
        let key = "\(name)#\(anchor)"
        if let cached = loaded[key] { return cached }
        guard !failed.contains(key), let entry = entries.first(where: { $0.name == name }),
              let imported = try? SCNScene(url: entry.asset, options: nil)
        else {
            failed.insert(key)
            return nil
        }

        // Blender exports Z-up with the nose at +X, and the import keeps Blender's axes — the
        // Aquarium's fish arrive the same way (`School.swift`). -90° about X sends the model's
        // up (+Z) to +Y and its left (+Y) to -Z, the frame every orientation in this saver is
        // stated in.
        let pivot = SCNNode()
        pivot.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        for child in imported.rootNode.childNodes { pivot.addChildNode(child) }
        // Matte paper, lit like everything built here. The import arrives physically based,
        // and with no environment to reflect PBR paper goes dark and waxy beside the lambert
        // landscape; the base colour is the one channel the bake carries, and lambert keeps it.
        pivot.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                material.lightingModel = .lambert
                material.isDoubleSided = true
            }
        }
        let holder = SCNNode()
        holder.addChildNode(pivot)
        guard let (lo, hi) = OrigamiLibrary.bounds(of: holder) else {
            failed.insert(key)
            return nil
        }
        let center = (lo + hi) / 2
        switch anchor {
        case .center: pivot.simdPosition = -center
        case .base: pivot.simdPosition = -SIMD3(center.x, lo.y, center.z)
        case .origin: break
        }
        let template = ModelTemplate(node: holder, extent: hi - lo,
                                     sheetAspect: entry.sheetAspect ?? StandIns.letterAspect,
                                     isStandIn: false)
        loaded[key] = template
        return template
    }

    /// The extent of every vertex under `root`, in the root's space.
    ///
    /// Vertices, not each node's bounding box transformed: the box of a rotated box is larger
    /// than what is in it, and the fire's flames are rotated — measured that way the fire's
    /// base came out about 11 mm below its real base. The root's own `boundingBox` is no
    /// better: in some import layouts it reports only its own geometry, which is zero for a
    /// hierarchy whose meshes all live in children.
    static func bounds(of root: SCNNode) -> (SIMD3<Float>, SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let transform = root.simdConvertTransform(matrix_identity_float4x4, from: node)
            for source in geometry.sources(for: .vertex) {
                // Only float vectors are read; anything else is skipped rather than guessed at.
                guard source.usesFloatComponents, source.bytesPerComponent == 4,
                      source.componentsPerVector >= 3 else { continue }
                source.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    for index in 0..<source.vectorCount {
                        let offset = source.dataOffset + index * source.dataStride
                        guard offset + 12 <= raw.count else { break }
                        let v = SIMD3(raw.loadUnaligned(fromByteOffset: offset, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
                        let p = transform * SIMD4(v, 1)
                        lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                        hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                        found = true
                    }
                }
            }
        }
        return found && hi.x > lo.x ? (lo, hi) : nil
    }
}
