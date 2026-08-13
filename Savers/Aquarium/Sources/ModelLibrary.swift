// The library the tank is populated from: every model committed under `Savers/Aquarium/Assets`
// describes itself in a JSON manifest beside its `.usdz`, and this is the decoder for that
// contract. `docs/decorations.md` is authoritative and `Models/props/_spec.py` is the emitter.
//
// Adding a decoration must not require touching Swift, which is the whole reason the placement
// data is authoring data in a file rather than a table in here. The corollary is that this
// code has to survive a manifest it has never seen: one bad file skips one model, and a
// missing index leaves an empty tank rather than a black screen.

import Foundation
import SceneKit
import simd

// MARK: - Manifest

/// A `[min, max]` pair. Decoded through a type of its own so that a malformed pair is a decode
/// error — and therefore one skipped model — rather than an index-out-of-range trap inside a
/// screensaver, where a trap takes `legacyScreenSaver` down with it.
struct Span: Decodable {
    let lower: Float
    let upper: Float

    init(_ lower: Float, _ upper: Float) {
        // Sorted, so a manifest that writes a range backwards still samples inside it.
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let first = try container.decode(Float.self)
        let second = try container.decode(Float.self)
        self.init(first, second)
    }

    var magnitude: Float { max(abs(lower), abs(upper)) }

    func sample(_ rand: inout Rand) -> Float { rand.inRange(lower, upper) }
}

enum ModelCategory: String, Decodable {
    case fish, coral, plant, rock, decoration
}

/// What a prop needs to be put somewhere, in metres and degrees.
struct PlacementSpec: Decodable {
    /// The untilted radius at scale 1.0. **The runtime adds the rest** — see `spacingRadius`.
    let footprint: Float
    let height: Float
    let yawRange: Span
    let tiltRange: Span
    let scaleRange: Span
    let weight: Float
    let minSpacing: Float
    let maxPerScene: Int?

    private enum CodingKeys: String, CodingKey {
        case footprint, height, yawRange, tiltRange, scaleRange, weight, minSpacing, maxPerScene
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        footprint = try container.decode(Float.self, forKey: .footprint)
        height = try container.decode(Float.self, forKey: .height)
        yawRange = try container.decodeIfPresent(Span.self, forKey: .yawRange) ?? Span(-180, 180)
        tiltRange = try container.decodeIfPresent(Span.self, forKey: .tiltRange) ?? Span(0, 0)
        scaleRange = try container.decodeIfPresent(Span.self, forKey: .scaleRange) ?? Span(1, 1)
        weight = try container.decodeIfPresent(Float.self, forKey: .weight) ?? 1
        // The emitter always writes this, defaulting it to twice the footprint. Defended here
        // anyway because a hand-written manifest is a supported way to add a model.
        minSpacing = try container.decodeIfPresent(Float.self, forKey: .minSpacing)
            ?? footprint * 2
        maxPerScene = try container.decodeIfPresent(Int.self, forKey: .maxPerScene)
    }

    /// The radius the placement pass must keep clear, at a given drawn scale.
    ///
    /// Every prop declares its footprint *untilted*, by design: tilting swings the top out by
    /// `height * sin(tilt)`, and adding that is deliberately the runtime's job rather than each
    /// author's, since every value it needs is already here and no render would catch the
    /// omission. It is not a small correction — a 1.35 m prop tilted 2.5° gains 59 mm of reach,
    /// and two pillars at maximum scale overlap by 14 cm without it. See `docs/decorations.md`.
    func spacingRadius(scale: Float) -> Float {
        (footprint + height * sin(tiltRange.magnitude * .pi / 180)) * scale
    }
}

/// What a species needs to be schooled.
struct FishSpec: Decodable {
    /// The world extent the whole mesh is scaled to, nose to tail tip. It is what the runtime
    /// can actually measure, so it is what the manifest number is taken to mean.
    let bodyLength: Float
    let school: Span
    /// Fractions of the tank's depth range, not metres, so a species does not have to know how
    /// deep the tank is.
    let depthBand: Span
    let weight: Float

    private enum CodingKeys: String, CodingKey {
        case bodyLength, school, depthBand, weight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bodyLength = try container.decode(Float.self, forKey: .bodyLength)
        school = try container.decodeIfPresent(Span.self, forKey: .school) ?? Span(4, 9)
        depthBand = try container.decodeIfPresent(Span.self, forKey: .depthBand) ?? Span(0, 1)
        weight = try container.decodeIfPresent(Float.self, forKey: .weight) ?? 1
    }
}

/// One model, as the tank sees it.
///
/// `parts`, `emitters`, `passages` and `cycle` are part of the manifest contract and are
/// deliberately *not* decoded here: nothing yet hinges a lid, bubbles or swims a wreck, and an
/// unread field is dead code. Unknown keys are ignored by `Decodable`, so the pass that adds
/// them is purely additive and no manifest has to change.
struct ModelManifest: Decodable {
    let name: String
    let asset: String
    let category: ModelCategory
    let placement: PlacementSpec?
    let fish: FishSpec?

    /// Whether the eye reads this prop as *made* rather than grown, which is what decides how
    /// closely `ReefLayout` lets it stand to its neighbours.
    ///
    /// The category is almost the whole answer: rock, coral and plant grow into each other and
    /// look better for it, while a skeleton, a chest or a wreck was put there and has to clear
    /// what is around it. `thermal_vent` is the exception the category cannot express — it is
    /// filed as a decoration because it is animated, but it is a geological feature and is
    /// happier growing out of the rocks than standing clear of them.
    ///
    /// One day the manifest should say this itself, since it is authoring data and
    /// `docs/decorations.md` is the contract for it. A field added for a single prop, before a
    /// second one needs it, would cost a pass over every model in the library to earn nothing.
    var isManmade: Bool {
        category == .decoration && !ModelManifest.grownDecorations.contains(name)
    }

    private static let grownDecorations: Set<String> = ["thermal_vent"]
}

// MARK: - Library

struct ModelLibrary {
    /// Everything that stands on the floor, in manifest order.
    let props: [ModelManifest]
    /// Everything that swims.
    let fish: [ModelManifest]

    /// Reads `index.json` and every manifest it names.
    ///
    /// `directory` is the *bundle's* resource directory. Inside a screensaver `Bundle.main` is
    /// `legacyScreenSaver.appex`, so a path resolved any other way silently finds nothing —
    /// see `AquariumScene.modelURL(in:)`, which is where this directory comes from.
    ///
    /// Every failure here is survivable and none of them trap: no index, or an index naming a
    /// manifest that is not there, yields an empty library and a tank of open water.
    static func load(from directory: URL) -> ModelLibrary {
        struct Index: Decodable { let models: [String] }

        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return ModelLibrary(props: [], fish: []) }

        var props: [ModelManifest] = []
        var fish: [ModelManifest] = []
        for entry in index.models {
            // `lastPathComponent` keeps an entry from reaching outside the resource directory.
            let url = directory.appendingPathComponent(
                URL(fileURLWithPath: entry).lastPathComponent)
            guard let payload = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(ModelManifest.self, from: payload),
                  FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(manifest.asset).path)
            else { continue }

            if manifest.category == .fish {
                if manifest.fish != nil { fish.append(manifest) }
            } else if manifest.placement != nil {
                props.append(manifest)
            }
        }
        return ModelLibrary(props: props, fish: fish)
    }
}

// MARK: - Loading geometry

/// An imported `.usdz` and the extent it actually arrived at.
///
/// Loading is the expensive part of a launch — a baked prop is an 8–10 MB archive with a 2048²
/// atlas — so an asset is imported once and cloned per instance. `SCNNode.clone()` shares
/// vertex buffers and textures with the original, which is what makes a dozen boulders cheap.
final class ModelCache {
    private var loaded: [String: LoadedModel] = [:]
    private let directory: URL

    struct LoadedModel {
        let template: SCNNode
        let minBound: SIMD3<Float>
        let maxBound: SIMD3<Float>

        /// Blender exports Z-up with a fish's nose at +X, and `build_prop.py` seats a prop's
        /// lowest vertex on z = 0. The tank is Y-up, so X is the long axis of a fish and Z is
        /// the standing height of a prop, both before the -π/2 correction.
        var length: Float { maxBound.x - minBound.x }
        var center: SIMD3<Float> { (minBound + maxBound) / 2 }
    }

    init(directory: URL) { self.directory = directory }

    /// Nil when the asset is missing or unreadable, which drops one model from the tank.
    func model(named asset: String) -> LoadedModel? {
        if let cached = loaded[asset] { return cached }
        let url = directory.appendingPathComponent(asset)
        guard let imported = try? SCNScene(url: url, options: nil),
              let (minBound, maxBound) = ModelCache.bounds(of: imported.rootNode)
        else { return nil }
        let model = LoadedModel(template: imported.rootNode, minBound: minBound, maxBound: maxBound)
        ModelCache.forceMetalnessIfRequested(imported.rootNode)
        loaded[asset] = model
        return model
    }

    /// DIAGNOSTIC, `AQUARIUM_FORCE_METALNESS=<0…1>`. Not a feature and not a fix.
    ///
    /// It exists to answer one question with a picture: metal in the tank reads as rock, and the
    /// candidate causes are "the scene has no environment to reflect" and "the material is not
    /// metallic". The first is fixed — see `WaterLook.environment`. This tests the second, by
    /// forcing every material in the library metallic, which is wrong for coral and wood and is
    /// exactly why it is a diagnostic. If brass appears under this and not without it, the
    /// missing piece is a metalness map out of the bake, which no lighting can substitute for.
    /// `docs/water-looks.md` records what it showed.
    private static func forceMetalnessIfRequested(_ root: SCNNode) {
        guard let raw = ProcessInfo.processInfo.environment["AQUARIUM_FORCE_METALNESS"],
              let metalness = Double(raw) else { return }
        root.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { $0.metalness.contents = metalness }
        }
    }

    /// Union of every geometry node's box, expressed in the root's space.
    ///
    /// `SCNNode.boundingBox` on the root reports only that node's own geometry in some import
    /// layouts, which yields a zero extent for a hierarchy whose meshes all live in children —
    /// and a zero extent would make the swim envelope divide by zero.
    private static func bounds(of root: SCNNode) -> (SIMD3<Float>, SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false

        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] {
                for y in [a.y, b.y] {
                    for z in [a.z, b.z] {
                        let p = root.convertPosition(SCNVector3(x, y, z), from: node)
                        lo = simd_min(lo, SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)))
                        hi = simd_max(hi, SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)))
                        found = true
                    }
                }
            }
        }
        return found ? (lo, hi) : nil
    }
}
