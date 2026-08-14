// The floor's surface, generated rather than shipped.
//
// Same reason the marine snow sprite and the lighting environment are generated: an asset that
// has to stay in the bundle *and* in step with the code is a second thing to get wrong, and a
// gravel bed that is drawn per launch in one of twenty-eight palettes could not be shipped as
// an image anyway.
//
// Two paths, because sand and gravel are not the same surface with different numbers.
//
// **Sand is granular.** No grain is ever resolved; what the eye sees is a *material*, and the
// tile is a few thousand soft ellipses of the ground's own colour, laid down short of opaque so
// they blend into it. This path is unchanged from the one the two ocean looks were art-directed
// and measured against, and it must stay that way — `docs/water-looks.md` records the floor
// luminance ratios those looks were signed off on.
//
// **Gravel is a bed of objects.** Every stone has a silhouette, a colour of its own, and a lit
// side and a shaded side, and it is the *relief* that does most of the work: stones are splatted
// through a height buffer, so one that lands lower is occluded by the one already there instead
// of painted over it, and the finished height field becomes a normal map that the tank's lamp
// actually lights. The first gravel was flat ellipses and no palette could rescue it, because a
// flat disc of colour is not a pebble no matter what colour it is.
//
// Nothing low-frequency may go in either tile. Blotches wider than a few texels are the
// frequency the eye locks onto, and these tiles repeat about twenty-five times across the floor:
// a first pass with 20–50 px blotches drew unmistakable stripes converging into the distance.
// Anything broad the floor wants has to come from geometry or from a second, unrepeated layer.

import AppKit
import CoreGraphics
import Foundation
import simd

enum SubstrateTexture {
    /// A generated surface: what it looks like, and which way it faces.
    struct Maps {
        let diffuse: NSImage
        /// Nil for sand, which has no relief worth carrying at this tiling.
        let normal: NSImage?
    }

    /// Which face of the bed is being drawn.
    enum Face {
        /// Seen from above: the top of the bed, where the light lands.
        case surface
        /// Seen through the front glass: the same stones in section, pressed flat against the
        /// pane and lit only by what works its way down between them.
        case crossSection

        /// How much of the stones' relief survives. A stone against glass is a stone with its
        /// near face cut off, so it is close to flat — but not flat, because what makes the
        /// band read as stones rather than as a printed strip is that some of them still catch
        /// a little light.
        var relief: CGFloat { self == .surface ? 1.0 : 0.45 }

        /// Extra coverage. The section through a bed is solid by definition — there is no gap
        /// between the stones, only the shadow where two of them meet.
        var coverage: CGFloat { self == .surface ? 1.0 : 1.45 }

        /// What the finished tile's mean luminance is aimed at, as a multiple of
        /// `GravelPalette.targetLuminance`.
        ///
        /// One for the surface, which is what that target was measured against. Well over one
        /// for the section, and the reason is geometric rather than artistic: this look's key
        /// is within twelve degrees of vertical and the section stands very nearly on end, so
        /// it receives around a third of the light per unit area that the surface does. Left at
        /// parity it renders at 0.22 of the water backdrop against the surface's 0.74 and the
        /// bottom of the frame goes to a black bar. The albedo is standing in for a light the
        /// tank does not have — a real one is lit by the room through the same pane you are
        /// looking through — and it is the honest place to put it, because inventing a lamp
        /// aimed at the glass would relight every prop in the front row too.
        var exposure: Float { self == .surface ? 1.0 : 3.30 }
    }

    // MARK: - Entry point

    static func maps(_ substrate: Substrate, face: Face = .surface) -> Maps {
        guard let palette = substrate.palette else {
            return Maps(diffuse: granular(substrate), normal: nil)
        }
        return bed(substrate, palette: palette, face: face)
    }

    // MARK: - Gravel: a packed bed of stones

    private static func bed(_ substrate: Substrate, palette: GravelPalette,
                            face: Face) -> Maps {
        let size = substrate.tileTexels
        let texels = size * size
        // Seeded, and with the face in the seed: the surface and the section are the same bed
        // seen twice, and drawing them from the same stream would put the identical arrangement
        // of stones on both, which reads as a mirror rather than as a cut.
        var rand = Rand(seed: face == .surface ? 0x5A_4D_10 : 0x5A_4D_11)

        var height = [Float](repeating: 0, count: texels)
        // Linear light throughout. Every step below is a multiplication, and a multiplication
        // through a gamma curve is not the operation anybody intended.
        let stones = palette.linearStones
        // The bed starts as the shadow down a crevice, so anywhere the stones fail to cover
        // reads as a gap between them rather than as bare ground of some other colour.
        var colour = [SIMD3<Float>](repeating: palette.linearInterstice, count: texels)

        let count = Int((CGFloat(substrate.grainCount) * face.coverage).rounded())
        let relief = Float(substrate.relief * face.relief)
        let contrast = Float(substrate.grainContrast)
        for _ in 0..<count {
            let stone = stones[min(stones.count - 1,
                                   Int(rand.next() * Float(stones.count)))]
            // Multiplicative, so a darker stone is the same dye seen with less light on it
            // rather than a different dye. Additive would drag every hue toward grey at the
            // dark end, which is what makes a single-colour bed look dirty.
            let value = rand.inRange(1 - contrast, 1 + contrast)
            splat(&rand, into: &height, colour: &colour, size: size,
                  substrate: substrate, relief: relief, tint: stone * value)
        }

        shade(&colour, height: height, size: size,
              radius: Float(substrate.grainRadius.upperBound), relief: relief)
        normalise(&colour,
                  to: GravelPalette.targetLuminance * palette.brightness * face.exposure)

        return Maps(diffuse: diffuseImage(colour, size: size),
                    normal: normalImage(height, size: size))
    }

    /// One stone, splatted into the height buffer.
    ///
    /// It writes only where it stands *above* what is already there, which is the whole reason
    /// there is a height buffer: overlapping stones then occlude one another the way stones in a
    /// bag do, and coverage past 1x buys packing instead of the later stone simply winning.
    private static func splat(_ rand: inout Rand, into height: inout [Float],
                              colour: inout [SIMD3<Float>], size: Int,
                              substrate: Substrate, relief: Float, tint: SIMD3<Float>) {
        let centreX = rand.next() * Float(size)
        let centreY = rand.next() * Float(size)
        let major = rand.inRange(Float(substrate.grainRadius.lowerBound),
                                 Float(substrate.grainRadius.upperBound))
        // Gravel is crushed, not tumbled, so the stones are chipped and oblong rather than
        // round. A bed of circles reads as bubble wrap.
        let minor = major * rand.inRange(0.58, 0.95)
        let angle = rand.inRange(0, 2 * .pi)
        let cosA = cos(angle), sinA = sin(angle)

        // The silhouette. Three low harmonics is enough to make an outline that is clearly not
        // an ellipse and still clearly one stone; more turns it into a splash.
        var lobes = [Float](repeating: 1, count: SubstrateTexture.lobeSamples)
        var maxLobe: Float = 0
        let a2 = rand.inRange(0.04, 0.15), p2 = rand.inRange(0, 2 * .pi)
        let a3 = rand.inRange(0.03, 0.13), p3 = rand.inRange(0, 2 * .pi)
        let a5 = rand.inRange(0.02, 0.08), p5 = rand.inRange(0, 2 * .pi)
        for index in 0..<SubstrateTexture.lobeSamples {
            let theta = 2 * Float.pi * Float(index) / Float(SubstrateTexture.lobeSamples)
            let lobe = 1 + a2 * cos(2 * theta + p2) + a3 * cos(3 * theta + p3)
                + a5 * cos(5 * theta + p5)
            lobes[index] = lobe
            maxLobe = max(maxLobe, lobe)
        }

        // How deep in the bed this stone is bedded. Without it every stone crests at the same
        // height and the bed reads as one embossed sheet; with it, some stones sit proud and
        // others are half buried by their neighbours.
        let bedZ = rand.inRange(0, major * relief * 0.85)
        let dome = major * relief

        let reach = Int((major * maxLobe).rounded(.up)) + 1
        let x0 = Int(centreX.rounded(.down)) - reach, x1 = Int(centreX.rounded(.down)) + reach
        let y0 = Int(centreY.rounded(.down)) - reach, y1 = Int(centreY.rounded(.down)) + reach

        for py in y0...y1 {
            // Unbounded coordinates wrapped on write, rather than the stone being redrawn at
            // every edge it crosses. Without a wrap the tile's own edges clip every stone that
            // crosses them, and because the texture repeats about twenty-five times across the
            // floor those clipped edges line up into a visible grid — the one artefact that
            // gives a tiled ground plane away instantly.
            let row = ((py % size) + size) % size * size
            let dy = Float(py) + 0.5 - centreY
            for px in x0...x1 {
                let dx = Float(px) + 0.5 - centreX
                let u = (dx * cosA + dy * sinA) / major
                let v = (-dx * sinA + dy * cosA) / minor
                let rho = (u * u + v * v).squareRoot()
                if rho > maxLobe { continue }
                var bucket = Int(atan2(v, u) * Float(SubstrateTexture.lobeSamples)
                    / (2 * .pi))
                bucket = ((bucket % SubstrateTexture.lobeSamples)
                    + SubstrateTexture.lobeSamples) % SubstrateTexture.lobeSamples
                let lobe = lobes[bucket]
                if rho > lobe { continue }
                let t = rho / lobe
                let z = bedZ + dome * (1 - t * t).squareRoot()
                let index = row + ((px % size) + size) % size
                if z > height[index] {
                    height[index] = z
                    colour[index] = tint
                }
            }
        }
    }

    /// The light-independent half of the shading: crevices darken, crests lift.
    ///
    /// This is curvature rather than true occlusion, and it is baked into the albedo on purpose
    /// — it is the part of a bed's appearance that does not depend on where the lamp is, so it
    /// stays right when the look changes and when a caustic gobo starts modulating the key. The
    /// directional half is the normal map's job and is deliberately *not* baked, or a floor lit
    /// from a new angle would carry the old angle's shadows.
    private static func shade(_ colour: inout [SIMD3<Float>], height: [Float], size: Int,
                              radius: Float, relief: Float) {
        let blurred = blur(height, size: size, radius: max(2, Int(radius.rounded())))
        let scale = max(0.001, radius * relief)
        for index in 0..<colour.count {
            let above = (height[index] - blurred[index]) / scale
            let curvature = min(max(0.42 + 0.62 * (above + 0.5), 0.42), 1.18)
            colour[index] *= curvature
        }
    }

    /// Puts the finished tile's mean luminance on the number the look was measured against.
    ///
    /// The last step, and the one that makes a palette safe to add. Everything before it —
    /// which stones were drawn, how much they overlapped, how deep the crevices came out —
    /// moves a tile's average brightness by amounts nobody can predict from the palette alone,
    /// and the tank's coherence rule is a statement about the delivered floor. Contrast within
    /// the tile is untouched: this is one scalar over the whole buffer.
    private static func normalise(_ colour: inout [SIMD3<Float>], to target: Float) {
        let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        var total: Float = 0
        for value in colour { total += simd_dot(value, weights) }
        let mean = total / Float(max(1, colour.count))
        guard mean > 1e-6 else { return }
        let factor = target / mean
        for index in 0..<colour.count { colour[index] *= factor }
    }

    /// Separable box blur, wrapped at the tile's edges so the blur does not darken a border the
    /// stones were carefully drawn across.
    private static func blur(_ source: [Float], size: Int, radius: Int) -> [Float] {
        let span = Float(radius * 2 + 1)
        var pass = [Float](repeating: 0, count: source.count)
        for y in 0..<size {
            let row = y * size
            for x in 0..<size {
                var total: Float = 0
                for offset in -radius...radius {
                    total += source[row + (((x + offset) % size) + size) % size]
                }
                pass[row + x] = total / span
            }
        }
        var result = [Float](repeating: 0, count: source.count)
        for x in 0..<size {
            for y in 0..<size {
                var total: Float = 0
                for offset in -radius...radius {
                    total += pass[((((y + offset) % size) + size) % size) * size + x]
                }
                result[y * size + x] = total / span
            }
        }
        return result
    }

    private static let lobeSamples = 64

    // MARK: - Sand: a granular material
    //
    // Unchanged in behaviour from the tile the two ocean looks were measured against. It is not
    // the stone path with `relief: 0` — that path splats through a height buffer and would
    // resolve every grain as a separate object, which is precisely what sand is not.

    private static func granular(_ substrate: Substrate) -> NSImage {
        var rand = Rand(seed: 0x5A_4D_10)
        let size = CGFloat(substrate.tileTexels)
        let image = NSImage(size: CGSize(width: size, height: size))
        image.lockFocus()

        NSColor(calibratedRed: substrate.base.red, green: substrate.base.green,
                blue: substrate.base.blue, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        for _ in 0..<substrate.grainCount {
            let radius = CGFloat(rand.inRange(Float(substrate.grainRadius.lowerBound),
                                              Float(substrate.grainRadius.upperBound)))
            let shade = CGFloat(rand.inRange(Float(-substrate.grainContrast),
                                             Float(substrate.grainContrast)))
            grain(&rand, substrate, size: size, radius: radius, shade: shade)
        }

        image.unlockFocus()
        return image
    }

    /// Draws one grain, repeated across whichever edges of the tile it overlaps.
    private static func grain(_ rand: inout Rand, _ substrate: Substrate, size: CGFloat,
                              radius: CGFloat, shade: CGFloat) {
        let x = CGFloat(rand.next()) * size
        let y = CGFloat(rand.next()) * size
        // A sand grain is a shade of the ground it sits in, so it is laid down short of opaque
        // and allowed to blend with it.
        NSColor(calibratedRed: max(0, substrate.base.red + shade),
                green: max(0, substrate.base.green + shade),
                blue: max(0, substrate.base.blue + shade * 0.8), alpha: 0.8).setFill()
        for dx in [-size, 0, size] where abs(x + dx - size / 2) < size / 2 + radius {
            for dy in [-size, 0, size] where abs(y + dy - size / 2) < size / 2 + radius {
                NSBezierPath(ovalIn: NSRect(x: x + dx - radius, y: y + dy - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
        }
    }

    // MARK: - Buffers to images

    /// Linear buffer to an sRGB image. The one place the gamma curve is applied, and the reason
    /// everything upstream can be plain multiplication.
    private static func diffuseImage(_ colour: [SIMD3<Float>], size: Int) -> NSImage {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for index in 0..<colour.count {
            let value = colour[index]
            let encoded = SIMD3<Float>(Float(StoneColour.encode(CGFloat(value.x))),
                                       Float(StoneColour.encode(CGFloat(value.y))),
                                       Float(StoneColour.encode(CGFloat(value.z))))
            let clamped = simd_clamp(encoded, SIMD3<Float>(repeating: 0),
                                     SIMD3<Float>(repeating: 1)) * 255
            pixels[index * 4] = UInt8(clamped.x.rounded())
            pixels[index * 4 + 1] = UInt8(clamped.y.rounded())
            pixels[index * 4 + 2] = UInt8(clamped.z.rounded())
        }
        return image(pixels, size: size, colourSpace: CGColorSpaceCreateDeviceRGB())
            ?? NSImage(size: CGSize(width: size, height: size))
    }

    /// A tangent-space normal map from the height field.
    ///
    /// Heights are already in texels, so a central difference *is* the slope and no unit
    /// conversion is needed. It is tagged with a linear colour space rather than sRGB because
    /// these bytes are a vector, not a colour: put through a gamma curve they would decode to a
    /// surface that is nearly flat in the middle and creased at the edges.
    private static func normalImage(_ height: [Float], size: Int) -> NSImage? {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            let up = ((y - 1 + size) % size) * size
            let down = ((y + 1) % size) * size
            let row = y * size
            for x in 0..<size {
                let left = (x - 1 + size) % size
                let right = (x + 1) % size
                let dzdx = (height[row + right] - height[row + left]) * 0.5
                let dzdy = (height[down + x] - height[up + x]) * 0.5
                let normal = simd_normalize(SIMD3<Float>(-dzdx, dzdy, 1))
                let encoded = simd_clamp(normal * 0.5 + 0.5, SIMD3<Float>(repeating: 0),
                                         SIMD3<Float>(repeating: 1)) * 255
                let index = (row + x) * 4
                pixels[index] = UInt8(encoded.x.rounded())
                pixels[index + 1] = UInt8(encoded.y.rounded())
                pixels[index + 2] = UInt8(encoded.z.rounded())
            }
        }
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        return image(pixels, size: size, colourSpace: linear)
    }

    private static func image(_ pixels: [UInt8], size: Int,
                              colourSpace: CGColorSpace) -> NSImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size * 4, space: colourSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: size, height: size))
    }
}
