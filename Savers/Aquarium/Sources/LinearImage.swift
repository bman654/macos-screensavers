// Building an image SceneKit will use *as authored*.
//
// Every generated image in this saver that is meant to carry a number rather than a picture has
// to go through here, because **SceneKit colour-manages an image by its own tag.** The same
// buffer tagged sRGB, generic 2.2 or device RGB is decoded through a 2.2 curve and arrives at
// less than a quarter of what it says; tagged linear it arrives exactly. That was measured
// against the real render path — a uniform grey delivered an implied gamma of 1.01 when tagged
// linear and 2.23 under every other tag — and then confirmed end to end with a real caustic
// tile, whose delivered mean came back at 1.0002 times the mean it was authored to.
//
// It is the reason this exists rather than `NSImage.lockFocus`, which is what the rest of the
// saver uses for images that only have to look right: `lockFocus` gives an image in the
// calibrated space, which measured as gamma 1.8 — neither of the two answers anyone would guess.
//
// Sixteen bits, because the buffers that come through here are light: a caustic's dark gaps and
// a shaft's tail both live at the bottom of the range, where linear 8-bit steps are coarsest and
// this scene already has visible banding.

import AppKit
import Foundation

enum LinearImage {
    /// An image whose texel values are exactly the linear numbers `sample` returns.
    ///
    /// Returns nil rather than falling back to an untagged image, because an untagged one is
    /// silently gamma-decoded — a caller that wanted a mean of 0.5 would get 0.22 and never be
    /// told. Every caller here treats nil as "do without the effect", which is a visible absence
    /// rather than a wrong number.
    static func make(width: Int, height: Int,
                     _ sample: (_ x: Int, _ y: Int) -> (r: Float, g: Float, b: Float)) -> NSImage? {
        guard width > 0, height > 0,
              let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
              let linear = NSColorSpace(cgColorSpace: linearSpace),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 16, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 6, bitsPerPixel: 48),
              let data = rep.bitmapData
        else { return nil }

        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = sample(x, y)
                let byte = (y * width + x) * 6
                for (channel, value) in [r, g, b].enumerated() {
                    let level = UInt16((max(0, min(1, value)) * 65535).rounded())
                    data[byte + channel * 2] = UInt8(level & 0xFF)
                    data[byte + channel * 2 + 1] = UInt8(level >> 8)
                }
            }
        }

        guard let tagged = rep.retagging(with: linear) else { return nil }
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(tagged)
        return image
    }
}
