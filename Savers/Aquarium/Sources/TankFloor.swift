// The substrate: the floor every prop stands on.
//
// Flat, and deliberately so. `build_prop.py` seats a prop's lowest vertex on z = 0, so a
// dune under the reef would leave every prop hovering or half-buried by the dune's amplitude
// unless the placement pass sampled the height field — and at these distances a 5 cm error is
// visible. Relief comes from the props and from the texture instead.
//
// The floor's geometry, extent and height are properties of the tank and are the same whatever
// it is made of; only the surface is a look. `Substrate` is that seam, and it holds every
// number the appearance depends on, so choosing sand or gravel is a value handed in by
// `TankStyle` rather than an edit through this file.

import AppKit
import Foundation
import SceneKit

/// What the floor is made of.
struct Substrate {
    /// Diffuse colour of the ground between the grains.
    let base: (red: CGFloat, green: CGFloat, blue: CGFloat)
    /// Colours the grains themselves are drawn in. Empty means "the same material as the ground
    /// between them", which is what sand is; a list is what makes aquarium gravel read as
    /// separate stones of different minerals rather than as one stone in shadow.
    let grainTints: [(red: CGFloat, green: CGFloat, blue: CGFloat)]
    /// Half-width of the per-grain shade offset either side of the grain's own colour. The blue
    /// channel takes 80% of it, which is what makes a grain read as a grain of the same
    /// material rather than as a fleck of a different one.
    let grainContrast: CGFloat
    /// Grain radius in texels of a 256² tile.
    let grainRadius: ClosedRange<CGFloat>
    let grainCount: Int
    /// Metres per tile. Small enough that the grain reads at the near edge of the floor, large
    /// enough that the far floor is not a shimmer of aliased tiles.
    let tileSize: CGFloat
    let roughness: CGFloat

    /// Sand is bright, but a seabed lit through fifteen metres of water is not. Rendered at the
    /// obvious 0.6 the near sand came out as a lit beach that the fog then had to drag all the
    /// way down to the water colour in about eight metres — a hard horizon across the frame,
    /// with the far reef apparently floating above it. The floor has to start close enough to
    /// the water it dissolves into that the fog has somewhere gentle to go.
    ///
    /// Deep water takes that further, and the reason is not artistic: the same daylight budget
    /// lights this floor and fills the water above it. If the backdrop is a dark blue, a floor
    /// that reads brighter than the backdrop is reflecting more light than the whole water
    /// column scatters, and the eye reads the mismatch immediately — as a lit shelf with an
    /// abyss beyond it. Deep sand is therefore darker *and* blue-shifted, because the red end
    /// of what reaches it has already been absorbed. Its grain contrast comes down with it: at
    /// this light level the sand's own 0.105 read as noise rather than as grain.
    static let deepSand = Substrate(base: (0.168, 0.170, 0.163),
                                    grainTints: [],
                                    grainContrast: 0.055,
                                    grainRadius: 0.6...2.0,
                                    grainCount: 2600,
                                    tileSize: 0.70,
                                    roughness: 0.92)

    /// The same sand a few metres under the surface, where there is enough light for it to keep
    /// its warmth. Brighter than `deepSand` in absolute terms and still darker than the
    /// turquoise water it is seen through, because that relationship is what makes it read as
    /// ground rather than as a light source.
    static let reefSand = Substrate(base: (0.330, 0.296, 0.236),
                                    grainTints: [],
                                    grainContrast: 0.090,
                                    grainRadius: 0.6...2.0,
                                    grainCount: 2600,
                                    tileSize: 0.70,
                                    roughness: 0.92)

    /// Aquarium gravel: separate coloured stones, not a granular surface.
    ///
    /// Three things distinguish it from sand and all three had to be pushed much further than
    /// the obvious values before any of them read.
    ///
    /// **Coverage.** At 520 grains the stones were isolated bright dots on a darker ground, and
    /// isolated dots at this scale are the definition of confetti. 1300 grains at this radius is
    /// about 1.4x overdraw — a complete mosaic, where the ground between the stones barely shows
    /// and the surface reads as *a bed of stones* rather than as speckle on dirt.
    ///
    /// **Size.** Real aquarium gravel is 3–6 mm, and at 3 mm a stone is under two pixels even in
    /// a tank seen from two metres — the near floor came back as coloured static. What the eye
    /// needs is a grain it can resolve, so this is pebble gravel: 0.55 m per 256² tile makes a
    /// 3–6.5 texel grain about 13–28 mm across, which is a size a large display tank plausibly
    /// uses and which survives the mip chain instead of shimmering through it. The tile is sized
    /// against the *aquarium* tank's two-metre reach; the same stones in an ocean tank would be
    /// too small to resolve, which is one more reason gravel is not a seabed.
    ///
    /// **Palette, in luminance and in hue.** A first pass spanned cream 0.33 down to basalt
    /// 0.075 — a four-to-one luminance range — and that is what first made it confetti rather
    /// than gravel. Compressing it to about two-to-one was not enough on its own: five tints
    /// spread round the wheel still read as rainbow speckle at full frame, because it is the
    /// *number of distinct hues* the eye counts, not their intensity. Real aquarium gravel is
    /// two or three tints plus naturals, so this is one blue family in two values, one warm
    /// accent, and two naturals. The warm accent is what keeps it from looking like blue sand;
    /// a second one is what made it confetti. Everything is muted well below what a bag of
    /// gravel looks like in air, because it is seen through saturated blue water under a hard
    /// overhead lamp.
    static let gravel = Substrate(base: (0.135, 0.150, 0.185),
                                  grainTints: [(0.098, 0.145, 0.300),   // cobalt
                                               (0.120, 0.190, 0.265),   // pale cobalt
                                               (0.205, 0.160, 0.150),   // terracotta
                                               (0.215, 0.215, 0.205),   // pale natural
                                               (0.105, 0.112, 0.125)],  // basalt
                                  grainContrast: 0.030,
                                  grainRadius: 3.0...6.5,
                                  grainCount: 1300,
                                  tileSize: 0.55,
                                  roughness: 0.62)
}

enum TankFloor {
    /// A plane in the XZ plane at the seabed node's own origin, running from the camera out
    /// past the fog. Its parent carries the height, which is where the drawable's aspect ratio
    /// gets into it — see `Tank.floorY(aspect:)`.
    static func node(_ substrate: Substrate, tank: Tank) -> SCNNode {
        let depth = CGFloat(tank.floorFarDepth)
        // Comfortably wider than the frustum is at the floor's far edge, so the floor never
        // ends inside the frame — on any drawable shape, since a wider one only makes the
        // frustum shorter. Derived rather than fixed because a two-metre tank given the
        // reference tank's seventeen metres of floor would tile its grain sixty times across
        // four metres of visible sand. Cheap either way: two triangles per segment.
        let width = CGFloat(2.5 * tank.halfWidth(atDepth: tank.floorFarDepth))
        let plane = SCNPlane(width: width, height: depth)
        // A single quad would take its lighting from four corners spread across the whole
        // tank, which under a directional key reads as a flat wash. A segment count rather
        // than a spacing, so it stays proportional as the floor scales with the tank.
        plane.widthSegmentCount = 12
        plane.heightSegmentCount = 24

        let material = plane.firstMaterial ?? SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = tile(substrate)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.mipFilter = .linear
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(
            width / substrate.tileSize, depth / substrate.tileSize, 1)
        material.roughness.contents = substrate.roughness
        material.metalness.contents = 0.0
        // The floor is lit from above and never from behind; a back face would only ever be
        // seen through it by a bug, and culling it halves the fill for the largest surface in
        // the tank.
        material.isDoubleSided = false
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        // The plane is authored in XY; -π/2 about X lays it down with its own +Y running into
        // the screen, so offsetting by half its depth puts its near edge under the camera.
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0, -Float(depth) / 2)
        return node
    }

    /// A seamless tile of grain.
    ///
    /// Generated rather than shipped for the same reason the marine snow sprite is: an asset
    /// that has to stay in the bundle and in step with the code is a second thing to get wrong,
    /// and this one is a few thousand ellipses.
    ///
    /// Grain only, and deliberately no broad mottling. Blotches wider than a few texels are the
    /// frequency the eye locks onto, and this tile repeats about twenty-five times across the
    /// floor: a first pass with 20–50 px blotches drew unmistakable stripes converging into the
    /// distance. Anything low-frequency the floor wants has to come from geometry or from a
    /// second, unrepeated layer — never from inside the tile.
    private static func tile(_ substrate: Substrate, size: CGFloat = 256) -> NSImage {
        var rand = Rand(seed: 0x5A_4D_10)
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
    ///
    /// Without the wrap the tile's own edges clip every grain that crosses them, and because the
    /// texture repeats about twenty-five times across the floor the clipped edges line up into a
    /// visible grid — the one artefact that gives a tiled ground plane away instantly.
    private static func grain(_ rand: inout Rand, _ substrate: Substrate, size: CGFloat,
                              radius: CGFloat, shade: CGFloat) {
        let x = CGFloat(rand.next()) * size
        let y = CGFloat(rand.next()) * size
        let tint = substrate.grainTints.isEmpty
            ? substrate.base
            : substrate.grainTints[min(substrate.grainTints.count - 1,
                                       Int(rand.next() * Float(substrate.grainTints.count)))]
        // A gravel stone is opaque; a sand grain is a shade of the ground it sits in, so it is
        // laid down short of opaque and allowed to blend with it.
        let alpha: CGFloat = substrate.grainTints.isEmpty ? 0.8 : 1.0
        NSColor(calibratedRed: max(0, tint.red + shade),
                green: max(0, tint.green + shade),
                blue: max(0, tint.blue + shade * 0.8), alpha: alpha).setFill()
        for dx in [-size, 0, size] where abs(x + dx - size / 2) < size / 2 + radius {
            for dy in [-size, 0, size] where abs(y + dy - size / 2) < size / 2 + radius {
                NSBezierPath(ovalIn: NSRect(x: x + dx - radius, y: y + dy - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
        }
    }
}
