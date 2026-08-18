// A fish keeps the atlas baked into its model unless its manifest offers alternate base-colour
// maps. Those maps are decoded here rather than while an individual is built: a school can use
// one colourway many times, and every material can safely share the same immutable image.
//
// **The swap is photometrically neutral, and that was worth checking rather than assuming.**
// `LinearImage.swift` documents what this scene has already paid for once — SceneKit colour-
// manages an image by its own tag, and the same buffer tagged wrongly arrives at a quarter of
// what it says. A colourway PNG carries no colour-space chunk at all, so the answer depends on
// what the decoder infers. Measured on the real path: a colourway byte-identical to the atlas
// inside the model renders to the same mean, 1.0000 on all three channels, because
// `NSBitmapImageRep` reads an untagged PNG as sRGB and that is what the USD importer gives the
// embedded one. Anything that changes how these are written should re-measure it.

import AppKit
import CoreGraphics
import Foundation

final class FishColorwayCache {
    private let directory: URL
    private var images: [String: CGImage] = [:]
    private var failed: Set<String> = []
    private var reportedFailure = false

    init(directory: URL) { self.directory = directory }

    func baseColor(manifestName: String, colorway: String) -> CGImage? {
        let filename = "\(manifestName)_\(colorway)_base_color.png"
        if let image = images[filename] { return image }
        guard !failed.contains(filename) else { return nil }

        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let representation = NSBitmapImageRep(data: data),
              let image = representation.cgImage
        else {
            failed.insert(filename)
            if !reportedFailure {
                // Once per scene, and said so: a half-generated library is missing colourways by
                // the dozen, and a bare filename would have a reader hunting for one bad file.
                print("[aquarium] could not load \(filename); using the model's baked base "
                      + "colour. Further colourway load failures are not reported.")
                reportedFailure = true
            }
            return nil
        }

        images[filename] = image
        return image
    }
}
