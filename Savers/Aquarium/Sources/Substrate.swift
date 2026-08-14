// What the floor is made of.
//
// Split out of `TankFloor` when gravel stopped being sand with different colours. The two are
// genuinely different surfaces and are drawn by different code: sand is a *granular* material,
// where a grain is a shade of the ground it sits in and the eye never resolves one, and gravel
// is a *bed of stones*, where every stone is a separate object with its own colour, its own
// silhouette and its own lit and shaded sides. `SubstrateTexture` has one path for each, and
// this is the value that selects between them.
//
// The geometry, extent and height of the floor are properties of the tank and are the same
// whatever it is made of; only the surface is a look.

import CoreGraphics
import Foundation

struct Substrate {
    /// The stones, if this is a bed of them. Nil is sand: no separate stones, no relief, and
    /// the granular path in `SubstrateTexture`.
    let palette: GravelPalette?

    /// Diffuse colour of the ground the grains sit in. Sand only — a gravel bed takes its
    /// interstices from the palette, because a crevice between coloured stones is those stones
    /// in shadow and cannot be a colour chosen independently of them.
    let base: (red: CGFloat, green: CGFloat, blue: CGFloat)

    /// How much lighter or darker one grain is than another.
    ///
    /// Additive for sand, where it is a shade *offset* — the blue channel takes 80% of it,
    /// which is what makes a grain read as the same material in shadow rather than as a fleck
    /// of a different one. Multiplicative for stones, where it scales the stone's own colour in
    /// linear light and therefore holds the hue: a darker red stone is the same dye, less lit,
    /// which is exactly what a single-colour bed looks like in the bag.
    let grainContrast: CGFloat

    /// Grain radius, in texels of the tile.
    let grainRadius: ClosedRange<CGFloat>
    let grainCount: Int

    /// The tile's resolution. Sand is fine enough that 256 resolves it; a stone needs to carry
    /// a silhouette and a normal, and at 256 the whole stone is six texels across.
    let tileTexels: Int

    /// Metres per tile. Small enough that the grain reads at the near edge of the floor, large
    /// enough that the far floor is not a shimmer of aliased tiles.
    let tileSize: CGFloat

    let roughness: CGFloat

    /// How far a stone stands proud of the bed, as a multiple of its own radius. This is what
    /// the normal map is built from, and it is the single number that decides whether the floor
    /// reads as a photograph of gravel or as a bed of actual stones under the tank's lamp —
    /// nothing else in the tile responds to the light at all. Zero for sand, whose relief is
    /// far below what a normal map at this tiling could carry without shimmering.
    let relief: CGFloat

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
    static let deepSand = Substrate(palette: nil,
                                    base: (0.168, 0.170, 0.163),
                                    grainContrast: 0.055,
                                    grainRadius: 0.6...2.0,
                                    grainCount: 2600,
                                    tileTexels: 256,
                                    tileSize: 0.70,
                                    roughness: 0.92,
                                    relief: 0)

    /// The same sand a few metres under the surface, where there is enough light for it to keep
    /// its warmth. Brighter than `deepSand` in absolute terms and still darker than the
    /// turquoise water it is seen through, because that relationship is what makes it read as
    /// ground rather than as a light source.
    static let reefSand = Substrate(palette: nil,
                                    base: (0.330, 0.296, 0.236),
                                    grainContrast: 0.090,
                                    grainRadius: 0.6...2.0,
                                    grainCount: 2600,
                                    tileTexels: 256,
                                    tileSize: 0.70,
                                    roughness: 0.92,
                                    relief: 0)

    /// Aquarium gravel: a packed bed of separate coloured stones.
    ///
    /// **Size.** Real aquarium gravel is 3–6 mm, and at 3 mm a stone is under two pixels even in
    /// a tank seen from two metres — the near floor comes back as coloured static. What the eye
    /// needs is a grain it can resolve, so this is pebble gravel: 0.55 m per tile makes a
    /// 12–26 texel grain about 13–28 mm across, which is a size a large display tank plausibly
    /// uses and which survives the mip chain instead of shimmering through it. The tile is sized
    /// against the *aquarium* tank's two-metre reach; the same stones in an ocean tank would be
    /// too small to resolve, which is one more reason gravel is not a seabed.
    ///
    /// **Coverage.** 2200 stones at this radius is a little over twice the tile's own area. A
    /// bed is *packed* — there is no ground between the stones, only the shadow down the gap
    /// where two of them meet — and the overdraw is what closes it. The earlier tile drew each
    /// grain over the last, so more overdraw only meant later grains winning; these are splatted
    /// through a height buffer, so a stone that lands lower is *occluded* by the one already
    /// there rather than painted over it, and the extra coverage buys packing instead of noise.
    ///
    /// **Relief, which is the whole difference.** The stones carry a normal map, so the tank's
    /// near-overhead lamp lights each one's upper face and shades its lower — which is what the
    /// eye actually uses to count objects on a surface. Without it, no palette reads as stones:
    /// the first gravel was flat-shaded ellipses and no amount of colour tuning could make a
    /// flat disc look like a pebble.
    static func gravel(_ palette: GravelPalette) -> Substrate {
        Substrate(palette: palette,
                  base: (0, 0, 0),
                  grainContrast: 0.30,
                  grainRadius: 6.0...13.0,
                  grainCount: 2200,
                  tileTexels: 512,
                  tileSize: 0.55,
                  roughness: 0.55,
                  relief: 0.62)
    }
}
