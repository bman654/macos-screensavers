// What colour the gravel is.
//
// A bag of aquarium gravel is a *set* of colours chosen together, not a colour — the naturals
// that came out of a river, a single dyed hue, a two-tone contrast mix, or the full neon
// rainbow. Which set a tank is filled with is most of what makes one launch look like a
// different aquarium, so it is drawn per launch the same way the layout and the species are.
//
// Two rules hold this together, and both exist because of failures already paid for in
// `docs/water-looks.md`.
//
// **Value is governed; hue is free.** The tank's coherence rule — the ground may not
// out-brighten the water it is seen through — is a statement about the floor's brightness and
// nothing else, so brightness is the only thing about a palette that is not the author's to
// choose. It is not *pinned*, which was the first attempt and made every bed the same grey; it
// follows the bag's own luminance through a hard compression that keeps the whole catalogue
// inside the rule. See `brightness`. Contrast *within* a palette survives untouched — black and
// white keeps its full spread — because the correction is one scalar over the finished tile.
//
// **Hue count is a decision, not an accident.** The first gravel read as confetti because five
// hues spread round the wheel is what speckle looks like at this scale. The answer is not
// "fewer hues" — a rainbow bed is a real thing people buy — it is that each palette commits to
// a scheme the eye can name: one hue, two hues in opposition, a family of neighbours, or the
// deliberate riot. What produced confetti was a palette that was none of these.

import CoreGraphics
import Foundation
import simd

/// One stone colour, as it looks dry in daylight. What reaches the screen is this after
/// normalisation, after the tank's blue water and after its lamp; authoring in air is the only
/// way these stay comparable to a photograph of the real thing.
struct StoneColour {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Perceived luminance, in *linear* light. sRGB values cannot be averaged directly — doing
    /// so overstates the dark end badly enough that a black-and-white mix would normalise to
    /// roughly half the brightness of a mid-grey one.
    var luminance: CGFloat {
        0.2126 * StoneColour.linear(red)
            + 0.7152 * StoneColour.linear(green)
            + 0.0722 * StoneColour.linear(blue)
    }

    static func linear(_ value: CGFloat) -> CGFloat {
        let v = max(0, min(1, value))
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func encode(_ value: CGFloat) -> CGFloat {
        let v = max(0, min(1, value))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

// MARK: - The bag colours

/// The colours gravel is actually sold in. Named once and composed into palettes below, so that
/// "the blue in the blue-and-white mix" is the same blue as the all-blue tank.
///
/// Saturations are high — higher than the muted first pass — because everything here is seen
/// through water tinted `0.070, 0.265, 0.560` under a blue-white lamp, and that water is a
/// stronger desaturating filter than any amount of authored restraint. Muting them twice is
/// what made the first gravel read as coloured dirt.
enum StoneColours {
    // Dyed, as in the jars: primaries plus the two achromatics.
    static let red = StoneColour(0.760, 0.105, 0.115)
    static let orange = StoneColour(0.910, 0.400, 0.055)
    static let yellow = StoneColour(0.900, 0.780, 0.110)
    static let green = StoneColour(0.140, 0.580, 0.190)
    static let blue = StoneColour(0.105, 0.230, 0.740)
    static let cyan = StoneColour(0.090, 0.520, 0.830)
    static let violet = StoneColour(0.420, 0.180, 0.700)
    static let orchid = StoneColour(0.700, 0.270, 0.700)
    static let black = StoneColour(0.075, 0.075, 0.085)
    static let white = StoneColour(0.930, 0.930, 0.905)

    // The fluorescent set, which is its own product and its own colours — a neon pink is not a
    // brighter red, and mixing the two families is what makes a rainbow bed look muddy.
    static let neonPink = StoneColour(0.960, 0.110, 0.520)
    static let neonOrange = StoneColour(0.990, 0.360, 0.060)
    static let neonYellow = StoneColour(0.940, 0.930, 0.150)
    static let neonGreen = StoneColour(0.240, 0.870, 0.220)
    static let neonBlue = StoneColour(0.110, 0.280, 0.880)
    static let neonCyan = StoneColour(0.120, 0.720, 0.900)

    // Undyed. A natural bed is several minerals at once, which is why there are four of them
    // and why they sit close together in hue — that closeness is what reads as "stone".
    static let quartz = StoneColour(0.880, 0.855, 0.780)
    static let sandstone = StoneColour(0.740, 0.615, 0.420)
    static let flint = StoneColour(0.520, 0.495, 0.455)
    static let ironstone = StoneColour(0.430, 0.300, 0.205)
    static let slate = StoneColour(0.300, 0.310, 0.330)
    static let basalt = StoneColour(0.120, 0.120, 0.130)
}

// MARK: - The palettes

/// A named set of stone colours, and how often a launch should draw it.
struct GravelPalette {
    let name: String
    /// The stones, before normalisation. Repetition is the mixing ratio: a colour listed twice
    /// is drawn twice as often, which is how a two-tone bag that is mostly black with white
    /// through it is stated without a second parallel array of weights.
    let stones: [StoneColour]
    /// Relative likelihood of being drawn. The quiet beds are commoner than the loud ones for
    /// the same reason a shop sells more natural gravel than fluorescent: a tank that is
    /// startling every launch is not startling.
    let weight: Float

    /// The mean linear luminance a tile is scaled to, before the palette's own `brightness`.
    ///
    /// It is calibrated against the palette this replaced, whose floor-versus-water ratio was
    /// measured at 0.68–0.74 against the aquarium's water and recorded in `docs/water-looks.md`.
    /// Together with the clamp on `brightness` it is what lets a palette be added without
    /// re-running that measurement.
    ///
    /// It is applied to the finished tile rather than to the palette, which matters more than it
    /// sounds: the crevice shading and the coverage both darken a tile by amounts that depend on
    /// the stone size and the packing, so normalising the *palette* leaves the delivered floor
    /// wherever those happen to put it. Normalising the tile makes the number mean what it says.
    static let targetLuminance: Float = 0.0348

    /// How far the stones are pushed away from grey before they are painted, and how much of
    /// the blue fill they sit in is taken back out of them first.
    ///
    /// Both exist for one measured reason. The near floor's own colour is a *small* part of what
    /// reaches the eye there: it is the darkest surface in the tank, and on top of it sit the
    /// look's blue ambient, its blue lighting environment and a sixth of a metre-for-metre fog
    /// toward water tinted `0.070, 0.265, 0.560`. Those three are additive and they do not care
    /// what the stones are, so a bed painted at a bag's real saturation arrives washed: a
    /// fluorescent-pink stone measured out at a dull maroon and a neon yellow at olive.
    ///
    /// The luminance is not the lever. The tank's coherence rule pins the floor at about 0.7 of
    /// the water above it and there is no room there at all — but it is a rule about brightness
    /// and it says nothing whatever about chroma, which is free. So the correction is made
    /// entirely in chroma, at constant luminance, which is also why it cannot break the floor
    /// measurement however far it is pushed.
    ///
    /// `chroma` is the push away from grey. `warmth` is the same idea aimed at one axis: the
    /// wash is blue, so the red end of every stone is the part of it that is disappearing, and
    /// this is put back before the push rather than after so that a red stone comes back red
    /// rather than merely less blue. Both are held well short of undoing the tank — the gravel
    /// is meant to be gravel *in this water*, not gravel cut out of a catalogue and pasted in.
    static let chroma: Float = 1.75
    static let warmth = SIMD3<Float>(1.30, 1.03, 0.86)

    /// How bright this bed is, as a multiple of `targetLuminance`.
    ///
    /// Pinning *every* palette to one mean was the first design and it is wrong, in a way that
    /// only a contact sheet of all of them shows: a white-quartz bed and a black-basalt bed
    /// normalise to the same number and both come out the same mid-grey. The two are then
    /// indistinguishable, which is absurd — a bag of white gravel is brighter than a bag of
    /// black gravel, and that *is* the difference between them. It costs the bright hues too:
    /// there is no such thing as a dark yellow that reads as yellow, so a sunflower bed pinned
    /// to a dark mean arrives as mustard.
    ///
    /// So the bed's brightness follows the bag's, compressed hard and clamped. The compression
    /// is what keeps the coherence rule intact: a 120:1 spread of in-air luminance between the
    /// whitest and blackest palettes comes out as barely 2:1 on the floor, and the clamp is what
    /// the whole catalogue's coherence actually rests on — measured, `quartz` and `sunflower` are
    /// two that reach it and they land at 0.88 and 0.84 of the water above them, against
    /// `river`'s 0.72 and `obsidian`'s 0.47. The upper end came down from 1.40 because there the
    /// white bed measured 0.99 and was one rounding away from out-brightening its own water.
    ///
    /// The reference is chosen so that `river`, the commonest bed and the one the tile numbers
    /// were tuned against, lands on the 0.72 the look was signed off at.
    static let referenceAir: Float = 0.22
    static let compression: Float = 0.35
    static let brightnessRange: ClosedRange<Float> = 0.55...1.20

    var brightness: Float {
        let air = stones.reduce(Float(0)) { $0 + Float($1.luminance) }
            / Float(max(1, stones.count))
        guard air > 1e-5 else { return GravelPalette.brightnessRange.lowerBound }
        let raw = pow(air / GravelPalette.referenceAir, GravelPalette.compression)
        return min(max(raw, GravelPalette.brightnessRange.lowerBound),
                   GravelPalette.brightnessRange.upperBound)
    }

    /// The stones in linear light, which is the only space the tile may be assembled in: every
    /// step that follows — the per-stone value spread, the crevice shading, the normalisation
    /// of the finished tile — is a multiplication, and a multiplication through a gamma curve
    /// is not the operation anybody intended. They come back to sRGB once, at the encode.
    ///
    /// Not normalised here. The tile is normalised as a whole once it is drawn, because what
    /// has to land on the target is the *floor*, and by then the shading and the coverage have
    /// both had their say — see `SubstrateTexture`.
    var linearStones: [SIMD3<Float>] {
        stones.map { stone in
            let linear = SIMD3<Float>(Float(StoneColour.linear(stone.red)),
                                      Float(StoneColour.linear(stone.green)),
                                      Float(StoneColour.linear(stone.blue)))
            return GravelPalette.styled(linear)
        }
    }

    /// Warms a colour and pushes it away from grey, both at constant luminance.
    ///
    /// It works on the colour's *tint* — what is left after its own grey is subtracted — and
    /// never on the grey itself, which is what makes it safe for the achromatic palettes. The
    /// first version warmed the whole colour and renormalised, and the quartz bed came out
    /// olive: an off-white stone is a neutral with a very slight warm bias, and warming that
    /// bias and then amplifying it 1.75x is a recipe for turning white gravel yellow. A neutral
    /// has no tint, so this leaves it exactly where it was.
    ///
    /// The push is *capped at the gamut* rather than clamped after it, and that distinction is
    /// the difference between orange gravel and red gravel. Clamping a channel to zero rescales
    /// the colour unevenly, which is a hue change: an orange stone pushed 1.75x has its green
    /// driven negative, clamps to zero, and arrives as a pure saturated red — so the whole
    /// `tangerine` and `ember` end of the catalogue came out looking like `cherry`. Scaling the
    /// tint by whatever factor keeps every channel in gamut preserves the hue exactly, and it
    /// says the right thing besides: a colour already at the edge of the gamut cannot be made
    /// more saturated, and the naturals — which is where the wash actually does its damage —
    /// still get the full push.
    private static func styled(_ colour: SIMD3<Float>) -> SIMD3<Float> {
        let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        let grey = simd_dot(colour, weights)
        // Luminance-free by construction, because the weights sum to one.
        var tint = colour - SIMD3<Float>(repeating: grey)
        tint *= warmth
        // Warming tilted it off the luminance-free plane; put it back, so the whole operation
        // is a hue and saturation move and the brightness lever stays `brightness`.
        tint -= SIMD3<Float>(repeating: simd_dot(tint, weights))
        let deepest = -tint.min()
        let inGamut = deepest > 1e-6 ? grey / deepest : chroma
        return SIMD3<Float>(repeating: grey) + tint * min(chroma, inGamut)
    }

    /// The ground showing through between the stones, in linear light. Derived rather than
    /// declared: the bed is packed, so this is only ever seen down a crevice, and a crevice is
    /// the palette's own colour in shadow. Declaring it separately invites a base that belongs
    /// to a different bag than the stones on top of it.
    var linearInterstice: SIMD3<Float> {
        let stones = linearStones
        guard !stones.isEmpty else { return SIMD3<Float>(repeating: 0) }
        let mean = stones.reduce(SIMD3<Float>(repeating: 0), +) / Float(stones.count)
        return mean * 0.30
    }

    // MARK: The catalogue
    //
    // Grouped by colour scheme, because the scheme is the thing that decides whether a bed
    // reads as designed or as spilled. Each group says what it is doing and why it works.

    /// Undyed stone. Neighbouring hues, wide value range, and the only palettes here that a
    /// reef or a riverbed could also plausibly wear.
    static let naturals: [GravelPalette] = [
        GravelPalette(name: "river",
                      stones: [StoneColours.sandstone, StoneColours.quartz,
                               StoneColours.flint, StoneColours.ironstone,
                               StoneColours.sandstone],
                      weight: 3.0),
        GravelPalette(name: "slate",
                      stones: [StoneColours.slate, StoneColours.flint, StoneColours.basalt,
                               StoneColours.slate],
                      weight: 1.6),
        GravelPalette(name: "obsidian",
                      stones: [StoneColours.black, StoneColours.basalt, StoneColours.black],
                      weight: 1.4),
        GravelPalette(name: "quartz",
                      stones: [StoneColours.quartz, StoneColours.white, StoneColours.quartz],
                      weight: 1.4),
    ]

    /// One hue, one bed — the jars in the reference photograph. There is no hue contrast at all
    /// here, so every bit of the surface's legibility comes from the per-stone value spread and
    /// from the relief; these are the palettes that prove the texture works.
    static let monochromes: [GravelPalette] = [
        GravelPalette(name: "cobalt", stones: [StoneColours.blue], weight: 1.3),
        GravelPalette(name: "lagoon", stones: [StoneColours.cyan], weight: 1.3),
        GravelPalette(name: "emerald", stones: [StoneColours.green], weight: 1.2),
        GravelPalette(name: "cherry", stones: [StoneColours.red], weight: 1.0),
        GravelPalette(name: "tangerine", stones: [StoneColours.orange], weight: 1.0),
        GravelPalette(name: "sunflower", stones: [StoneColours.yellow], weight: 0.9),
        GravelPalette(name: "orchid", stones: [StoneColours.orchid], weight: 1.0),
        GravelPalette(name: "amethyst", stones: [StoneColours.violet], weight: 1.0),
    ]

    /// Two colours chosen for contrast, which is what most mixed bags are.
    ///
    /// Three kinds, and the distinction matters because they fail differently. **Achromatic
    /// pairs** (a hue against black or white) contrast in value alone and are the safest: the
    /// eye reads them as one bed of light and dark stones. **Complementary pairs** sit opposite
    /// each other on the wheel and contrast in hue as well, which is the loudest a two-colour
    /// bed gets. **Analogous pairs** are neighbours and barely contrast at all — they read as
    /// one colour with depth, which is the reason to have them.
    static let duos: [GravelPalette] = [
        // Achromatic. Uneven ratios, because an even split of black and white reads as a
        // chessboard and every bag of it in a shop is mostly one or the other.
        GravelPalette(name: "monochrome",
                      stones: [StoneColours.black, StoneColours.black, StoneColours.white],
                      weight: 2.0),
        GravelPalette(name: "snowfall",
                      stones: [StoneColours.white, StoneColours.white, StoneColours.black],
                      weight: 1.6),
        GravelPalette(name: "arctic",
                      stones: [StoneColours.cyan, StoneColours.white, StoneColours.white],
                      weight: 2.0),
        GravelPalette(name: "midnight",
                      stones: [StoneColours.blue, StoneColours.blue, StoneColours.black],
                      weight: 1.8),
        GravelPalette(name: "jungle",
                      stones: [StoneColours.green, StoneColours.green, StoneColours.black],
                      weight: 1.8),
        GravelPalette(name: "bubblegum",
                      stones: [StoneColours.neonPink, StoneColours.white, StoneColours.white],
                      weight: 1.4),
        GravelPalette(name: "ember",
                      stones: [StoneColours.orange, StoneColours.black, StoneColours.black],
                      weight: 1.3),
        // Complementary: opposite hues, so the contrast is in colour as well as value.
        GravelPalette(name: "harbour",
                      stones: [StoneColours.blue, StoneColours.blue, StoneColours.orange],
                      weight: 1.5),
        GravelPalette(name: "carnival",
                      stones: [StoneColours.violet, StoneColours.violet, StoneColours.yellow],
                      weight: 1.2),
        GravelPalette(name: "watermelon",
                      stones: [StoneColours.green, StoneColours.green, StoneColours.red],
                      weight: 1.0),
        // Analogous: neighbours, so the bed reads as one colour that happens to have depth.
        GravelPalette(name: "tidepool",
                      stones: [StoneColours.blue, StoneColours.cyan, StoneColours.cyan],
                      weight: 1.8),
        GravelPalette(name: "sunset",
                      stones: [StoneColours.orange, StoneColours.yellow, StoneColours.red],
                      weight: 1.4),
    ]

    /// Three or more hues. Past two colours the only thing keeping a bed from reading as
    /// speckle is that the hues are *related* — a triad is evenly spaced round the wheel and an
    /// analogous run is a continuous arc — with the last entry as the deliberate exception.
    static let multis: [GravelPalette] = [
        GravelPalette(name: "primary",
                      stones: [StoneColours.red, StoneColours.yellow, StoneColours.blue],
                      weight: 1.2),
        GravelPalette(name: "reefmix",
                      stones: [StoneColours.blue, StoneColours.cyan, StoneColours.green,
                               StoneColours.white],
                      weight: 1.6),
        GravelPalette(name: "confetti",
                      stones: [StoneColours.orchid, StoneColours.orange, StoneColours.cyan,
                               StoneColours.white, StoneColours.white],
                      weight: 1.2),
        // The fluorescent bag, and the only palette here that is meant to shout. It is the one
        // place the hue-count rule is broken on purpose: six saturated hues at even weight is
        // exactly what makes it recognisable as that product rather than as a mistake.
        GravelPalette(name: "neon",
                      stones: [StoneColours.neonPink, StoneColours.neonOrange,
                               StoneColours.neonYellow, StoneColours.neonGreen,
                               StoneColours.neonBlue, StoneColours.neonCyan],
                      weight: 1.2),
    ]

    static let all: [GravelPalette] = naturals + monochromes + duos + multis

    /// What this launch fills the tank with.
    ///
    /// Drawn rather than fixed, and weighted, so the tank is a different tank each time in the
    /// way the layout and the species already are. It takes a stream of its own off the launch
    /// seed rather than a number from the tank's, for the reason spelled out in
    /// `TankStyle.draw`: a draw taken from the launch stream reshuffles everything drawn after
    /// it, and every seeded render this repo has tuned against was made before this existed.
    ///
    /// `AQUARIUM_GRAVEL` pins it, exactly as `AQUARIUM_STYLE` pins the look and for the same
    /// reason — a build loop cannot click a sheet, and the environment is empty under
    /// `legacyScreenSaver`, so it costs nothing where it matters. An unknown name falls back to
    /// the draw rather than failing, because a typo in a render command should cost one look at
    /// a PNG and not a debugging session.
    static func forLaunch(seed: UInt64) -> GravelPalette {
        if let pinned = ProcessInfo.processInfo.environment["AQUARIUM_GRAVEL"],
           let palette = named(pinned) {
            return palette
        }
        var draw = Rand(seed: seed ^ 0x67_2A_7E_1B_5C_0D)
        guard let index = draw.weightedIndex(all, weight: { $0.weight }) else { return all[0] }
        return all[index]
    }

    /// Nil for an unknown name, so the caller can fall back to the draw rather than trap on a
    /// typo in an environment variable.
    static func named(_ name: String) -> GravelPalette? {
        all.first { $0.name == name }
    }
}
