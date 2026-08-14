// What the water is made of, and what lights it.
//
// One look is every number that decides how the tank reads: the water's own colour, the ramp
// down from the surface, what the metal in it reflects, the fog's shape, the three-light rig,
// the camera's post-processing and how much matter is suspended in the water. A style picks
// one — see `TankStyle` — and nothing outside `AquariumScene.buildEnvironment` and
// `buildCamera` reads a light, a tint or a fog value, so the looks stay interchangeable.
//
// `docs/water-looks.md` is the reasoning behind every value here and holds the measurements
// that justify them. The one thing that is not negotiable: **light reaching the seabed and
// light scattering in the water column come from one budget.** A substrate lit as though light
// is plentiful, seen through water tinted as though it is not, reads as a lit shelf dropping
// off into an abyss rather than as a place. Every look is tuned so the near floor is *dimmer*
// than the open water it is seen through, and the floor then brightens with distance as the fog
// carries it toward the backdrop — which is the direction real haze runs. The substrate each
// look is balanced against is named on its style, and the two cannot be retuned apart.

import AppKit
import Foundation
import SceneKit

struct WaterLook {
    /// One light, stated the way a lighting decision is actually made: how far above the horizon
    /// it sits and which way round. Euler angles are derived, because a light aimed by raw
    /// eulers cannot be read back as an elevation without doing the trigonometry by hand.
    struct Light {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let intensity: CGFloat
        /// Degrees above the horizon the light comes *from*; 90 is straight down. Ignored for
        /// the ambient light, which has no direction.
        let elevation: Float
        /// Degrees round the vertical axis; 0 sends it straight into the screen.
        let azimuth: Float

        init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, intensity: CGFloat,
             elevation: Float = 0, azimuth: Float = 0) {
            self.red = red
            self.green = green
            self.blue = blue
            self.intensity = intensity
            self.elevation = elevation
            self.azimuth = azimuth
        }

        var color: NSColor {
            NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        }

        /// A directional light aims along its own -Z. Pitching by -elevation swings that to
        /// `(0, -sin e, -cos e)`, so elevation 90 is a light travelling straight down.
        var euler: SCNVector3 {
            SCNVector3(-elevation * .pi / 180, azimuth * .pi / 180, 0)
        }
    }

    /// The water's own colour. It is the scene background *and* the fog colour *and* the
    /// clear colour, and those three must agree exactly or the deepest fish dissolve into a
    /// visible wall of a slightly different shade.
    let tint: (red: CGFloat, green: CGFloat, blue: CGFloat)

    /// The colour the water reaches at the very top of the frame.
    ///
    /// A flat backdrop states that the water is the same in every direction, which is the one
    /// thing that is never true underwater: light arrives from a surface overhead. The span is
    /// fixed at the top half of the frame rather than being a parameter, because the fog is what
    /// constrains it — the ramp has to reach `tint` exactly where the fog starts having
    /// something to fog out against, which is the horizon, and hold it below. A ramp that stops
    /// short draws a visible line across the frame where its slope changes; the aquarium look
    /// did exactly that at 0.42 of the height and it read as the seam of a badly-lit backdrop.
    let surface: (red: CGFloat, green: CGFloat, blue: CGFloat)

    /// What the tank's metal reflects: the colour above the surface, the colour of the dark
    /// water below, and how hard the whole thing is driven.
    ///
    /// Not decoration. In SceneKit's PBR a metallic surface takes almost all of its colour from
    /// what it reflects, so a scene with no `lightingEnvironment` gives metal nothing to
    /// reflect: it collapses toward its dark specular response and reads as dull stone. Three
    /// directional lights cannot substitute — they give it highlights, not an environment.
    ///
    /// It belongs to the look rather than being a shipped asset for the same reason the fog
    /// colour does: **metal must reflect the sea it is actually sitting in.** A bright
    /// fluorescent tank and a dim deep ocean have to give their brass visibly different
    /// reflections, and an HDR of somewhere else could only ever agree with one of them —
    /// besides costing bundle size the generated version does not.
    let environment: (top: (red: CGFloat, green: CGFloat, blue: CGFloat),
                      bottom: (red: CGFloat, green: CGFloat, blue: CGFloat),
                      intensity: CGFloat)

    /// How fast the water swallows distance. The fog's *distances* are the tank's business, not
    /// the look's — they are the only numbers here that would be stated in metres against a tank
    /// of a particular size, and the tank's size is drawn per launch. See `Tank.fogStart`.
    let fogDensityExponent: CGFloat

    let ambient: Light
    let key: Light
    let rim: Light

    /// A second, warmer source at a low elevation — or nil for a look that does not want one.
    ///
    /// It exists because the key cannot do this job. The key sits near the vertical, so it lands
    /// on the floor at almost its full strength and on a fish's flank or a helmet's side at
    /// about a fifth of it: warming the key warms the *ground*. An accent at a low elevation is
    /// the exact complement — it grazes everything standing up in the tank and barely touches
    /// what it stands on — which is what a warm accent has to do to be worth having, because the
    /// two things asking for one are a vertical brass helmet and a fish's flank.
    ///
    /// It is also the only warm light in a look whose water, ambient and environment are all
    /// blue, and a metal's reflection is `baseColour x environment`: a red-orange alloy in a
    /// blue tank has no red to return whatever its albedo. Nil for both ocean looks — the reef's
    /// key is already warm and the deep look is warm nowhere on purpose.
    let accent: Light?

    /// The net of focused light a rippled surface throws on what is under it, or nil for a look
    /// that should not have one. It rides the key, because the key is the light it is made of —
    /// see `Caustics`, whose header records the four measured SceneKit facts the design rests on.
    let caustics: Caustics?

    /// Shafts of light scattering out of the water column, or nil for a look with none.
    ///
    /// Deliberately the *complement* of `caustics` rather than another helping of it. Both are
    /// the same lamp seen through the same surface, but a caustic is the part still focused when
    /// it reaches the ground and a shaft is the part scattered out on the way — so a look with a
    /// short, clear column and a bright floor wants caustics, and a look with a long, dim column
    /// wants shafts. The deep ocean is the only look with no caustics at all and it is the one
    /// with the strongest rays.
    let godRays: GodRays?

    let bloomIntensity: CGFloat
    let bloomThreshold: CGFloat
    let bloomBlurRadius: CGFloat
    let vignettingIntensity: CGFloat
    let vignettingPower: CGFloat

    /// Marine snow is a property of the water, not of the tank: an open ocean is full of it, a
    /// maintained glass tank is not. Zero suppresses the emitter entirely.
    let snowBirthRate: CGFloat
    let snowAlpha: CGFloat

    var color: NSColor {
        NSColor(calibratedRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
    }

    /// What the scene's background is set to: a vertical ramp from the surface's colour at the
    /// top of the frame down to the flat water colour at the horizon, holding it below. Narrow
    /// on purpose — a background image is stretched to the viewport, so the ramp only has to be
    /// one column wide and nothing about it depends on the drawable's shape.
    var backgroundContents: Any {
        let height: CGFloat = 512
        let image = NSImage(size: CGSize(width: 2, height: height))
        image.lockFocus()
        let top = NSColor(calibratedRed: surface.red, green: surface.green,
                          blue: surface.blue, alpha: 1)
        // The horizon sits at the vertical centre of the frame: the floor plane meets the eye's
        // own height only at infinity, so NDC y = 0 is where the water stops being backdrop and
        // starts being something the fog has to match.
        NSGradient(starting: color, ending: top)?.draw(
            in: NSRect(x: 0, y: height / 2, width: 2, height: height / 2), angle: 90)
        color.setFill()
        NSRect(x: 0, y: 0, width: 2, height: height / 2).fill()
        image.unlockFocus()
        return image
    }

    /// The environment metal reflects, as an equirectangular image: a 2:1 map whose top row is
    /// straight up and whose bottom row is straight down.
    ///
    /// Two ramps meeting at the horizon rather than one running the whole way, because the knee
    /// is the whole point. A helmet's crown then reflects the bright surface, its shoulders
    /// reflect water of exactly the look's own colour, and its undersides reflect the dark below
    /// — which is what puts polished and tarnished on one object without needing two materials.
    /// A single ramp from top to bottom puts the water colour nowhere and reads as a studio
    /// gradient wrapped round the tank.
    var environmentContents: Any {
        let size = CGSize(width: 256, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        let above = NSColor(calibratedRed: environment.top.red, green: environment.top.green,
                            blue: environment.top.blue, alpha: 1)
        let below = NSColor(calibratedRed: environment.bottom.red,
                            green: environment.bottom.green,
                            blue: environment.bottom.blue, alpha: 1)
        NSGradient(starting: color, ending: above)?.draw(
            in: NSRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2),
            angle: 90)
        NSGradient(starting: below, ending: color)?.draw(
            in: NSRect(x: 0, y: 0, width: size.width, height: size.height / 2), angle: 90)
        image.unlockFocus()
        return image
    }
}

// MARK: - The three looks

extension WaterLook {
    /// Deep ocean: dim, blue-shifted, and coherent about it.
    ///
    /// The water is dark, so the ground has to be dark — that is the whole correction. What
    /// keeps the scene from going dead is that the *contrast* is carried by proximity rather
    /// than by a bright floor: the fog starts early, so a near prop is the only thing in the
    /// frame still holding its own colour and everything behind it is on its way to the
    /// backdrop.
    ///
    /// The key is blue-white rather than warm. Twenty metres of water has taken the red out of
    /// daylight long before it reaches this seabed; a warm key at depth is the single detail
    /// that says "studio lamp" loudest. It is also at little more than half the intensity the
    /// tank shipped with, because that intensity is most of what over-lit the floor.
    static let deepOcean = WaterLook(
        // Darker than the look originally shipped with, because the *bottom* of the frame is
        // where depth is stated: the tint is the fog and the below-horizon backdrop, so it is
        // the single number that sets the lower half's brightness. The reference photograph's
        // water keeps falling all the way down — 2% of its top brightness at the frame's foot —
        // while this look used to flatten out near 20% and read as a lit shelf. The top of the
        // frame was judged right and is held by `surface`; the tint dropping is what stretches
        // the contrast between them.
        tint: (0.030, 0.090, 0.144),
        // Much stronger than the tint, and the reason is the shafts. Measured against a
        // photograph of real god rays, the water in that picture falls to a fifth of its
        // top-of-frame brightness by the horizon — the shafts need a bright surface to emerge
        // *from*, and the gradient the eye reads as belonging to the ray mostly belongs to the
        // water. The ramp does it, so the fog still meets the background exactly at the horizon.
        // Trimmed a notch below where it was signed off, because the curtain's own mean light
        // now sits on top of it and the *sum* at the top of the frame is what was approved.
        surface: (0.114, 0.330, 0.522),
        environment: (top: (0.105, 0.270, 0.420), bottom: (0.010, 0.027, 0.046),
                      intensity: 0.85),
        // The steepest of the three. Depth is sold by how fast things leave, not by how dark
        // the backdrop is.
        fogDensityExponent: 1.55,
        // All three lights follow the tint down at the same ratio, because the floor and the
        // water above it come from one budget: darker water over a floor lit as before would
        // out-brighten the very thing it is seen through.
        ambient: Light(0.21, 0.40, 0.60, intensity: 215),
        key: Light(0.70, 0.86, 1.0, intensity: 390, elevation: 74, azimuth: 20),
        rim: Light(0.28, 0.56, 0.88, intensity: 180, elevation: -20, azimuth: 143),
        // Warm nowhere, on purpose: twenty metres of water is what takes the red out, and a
        // warm accent here would say "studio lamp" as loudly as a warm key would.
        accent: nil,
        // No caustics either, and for the same reason the key is not warm. A caustic net is a
        // shallow-water phenomenon: it is the surface's own ripple focused onto the ground, and
        // twenty metres of water diffuses that focus away long before it arrives. Dappling this
        // seabed would be the same lie as warming its key.
        caustics: nil,
        // The strongest of the three, and the look shafts exist for. Twenty metres of water is
        // a long scattering path and this is the only look whose backdrop is dark enough for a
        // shaft to read against it — the same darkness that makes it the wrong place for
        // caustics makes it the right place for these.
        godRays: GodRays(brightness: 1.35, sourceHeight: 7.5, drift: 1.0),
        // A strong vignette makes the frame edges darker than the middle, which *adds* to the
        // shelf-and-cliff read rather than hiding it, and at the old 0.55 it swamped the
        // surface ramp completely.
        bloomIntensity: 0.25, bloomThreshold: 0.95, bloomBlurRadius: 12,
        vignettingIntensity: 0.36, vignettingPower: 1.25,
        // Densest of the three: open ocean at depth is full of it, and it is free particulate
        // evidence that the water is a volume.
        snowBirthRate: 46, snowAlpha: 0.30)

    /// Shallow reef: the snorkelling look. The surface is a few metres up, so the key is nearly
    /// overhead and still carries its warmth, and the water is a real turquoise rather than a
    /// near-black. The flattest fog of the three, because shallow water is clearer and the far
    /// reef should stay legible rather than dissolve.
    ///
    /// This is the look where the one-budget rule buys brightness rather than costing it: the
    /// sand is warmer and barely darker than the sand that shipped, and still sits well under
    /// its own backdrop, because the water rose so much further.
    static let shallowReef = WaterLook(
        tint: (0.105, 0.385, 0.470),
        // Trimmed slightly below where it was signed off, because the curtain's mean light now
        // sits on top of it and the *sum* at the top of the frame is what was approved.
        surface: (0.207, 0.552, 0.612),
        environment: (top: (0.440, 0.870, 0.940), bottom: (0.045, 0.150, 0.185),
                      intensity: 1.0),
        fogDensityExponent: 1.05,
        // A shallow water column really is scattering this much. A first pass ran it cyan
        // enough to drain the warmth out of the sand and make it read grey.
        ambient: Light(0.42, 0.68, 0.72, intensity: 440),
        // Still warm — at 3–5 m there is not enough water to take the red out — and pitched
        // nearly overhead, which is where the sun is when the surface is right above you.
        key: Light(1.0, 0.97, 0.86, intensity: 820, elevation: 82, azimuth: 12),
        rim: Light(0.46, 0.80, 0.94, intensity: 300, elevation: -20, azimuth: 143),
        // The key is already warm at this depth, which is the whole difference between this
        // look and the deep one. A second warm source would be warmth with nothing to fix.
        accent: nil,
        // The look caustics exist for. A few metres of water under a bright sun is exactly the
        // condition that focuses a surface ripple into a net on the sand, and it is the one
        // thing this look was missing that a snorkeller would notice immediately. The largest
        // cells of the three, because the shallower the water the wider the net it throws.
        caustics: Caustics(tileMetres: 2.6, strength: 0.45, drift: 0.010),
        // Faint — well under half the deep ocean's strength — and that it exists at all is the
        // curtain rewrite's doing. The quad-era shafts were tried here at six brightnesses from
        // 0.20 down to 0.055 and failed at every one: an additive band on the brightest,
        // smoothest backdrop of the three shows its own edge however softly it is drawn, and
        // turning it down only made the stripes fainter, which is the tell that brightness was
        // never the problem. But that was a fact about *objects*, and the curtain has none — a
        // continuous ripple gives the bright water no boundary to betray. What a snorkeller
        // actually sees is both halves of the same lamp through the same surface, split by where
        // the light lands: dappled sand below, and a broad faint shimmer in the column above —
        // not the deep's theatrical fingers.
        godRays: GodRays(brightness: 0.75, sourceHeight: 7.5, drift: 1.0),
        // Most bloom, least vignette: sunny and open.
        bloomIntensity: 0.45, bloomThreshold: 0.88, bloomBlurRadius: 12,
        vignettingIntensity: 0.32, vignettingPower: 1.2,
        snowBirthRate: 16, snowAlpha: 0.20)

    /// Aquarium: a lit glass tank. A fluorescent blue-white key from almost directly overhead —
    /// a hood lamp has all but no angle — and water tinted a far more saturated blue than either
    /// ocean look, blue at double the green and eight times the red.
    ///
    /// It carries **more** fill than either ocean look, which is the opposite of the obvious
    /// reading and was arrived at the hard way. A hard single source from straight overhead
    /// models terrain beautifully — bright horizontal tops, dark undersides — and a first pass
    /// leant on exactly that with the dimmest ambient of the three. But a fish is seen *side-on*,
    /// and its flank is both the entire visible surface and the only part carrying the markings:
    /// under a vertical key with no fill the tangs went blue-grey while the same fish stayed
    /// vivid in the reef look. A home aquarium is the one place that failure is fatal, because
    /// showing off vivid fish is what the thing is for. It is also the least physical of the
    /// three: a small glass box is a bounce environment, every wall returning light, so a
    /// generous fill and the strongest rim of the three are what a tank actually has.
    static let aquarium = WaterLook(
        tint: (0.070, 0.265, 0.560),
        // Mild. A tank's backdrop is a lit panel, not a sky.
        surface: (0.105, 0.350, 0.665),
        environment: (top: (0.235, 0.600, 1.000), bottom: (0.022, 0.080, 0.180),
                      intensity: 1.25),
        fogDensityExponent: 1.35,
        ambient: Light(0.46, 0.68, 0.94, intensity: 620),
        // Warm rather than the cool white a hood lamp literally is, and the intensity is the
        // cool white's divided by this colour's own luminance, so what changed between the two
        // is the colour of the light and not how much of it there is. The floor is what moves:
        // at elevation 78 the key lands on the bed at N·L 0.98 and on a fish's flank at 0.21,
        // so warming it warms the gravel about five times as hard as it warms the fish — the
        // near band went from blue-dominant (0.247, 0.302, 0.388) to red-dominant
        // (0.333, 0.294, 0.282) while flank chroma held at 0.047 against 0.049.
        key: Light(1.0, 0.95, 0.82, intensity: 1316, elevation: 78, azimuth: 8),
        rim: Light(0.42, 0.68, 1.0, intensity: 430, elevation: -20, azimuth: 143),
        accent: Light(1.0, 0.72, 0.42, intensity: 260, elevation: 18, azimuth: -38),
        // Broader and fainter than the reef's, which is the opposite of what a tank's shorter,
        // busier surface ripple would suggest, and the reason is the floor rather than the
        // water: this bed is *gravel*, a field of resolved stones with its own light and shade
        // at exactly the scale a tight caustic net would land on. A first pass at 1.1 m cells
        // disappeared into it — the two patterns competed and the result read as noise. Wide
        // cells sit on the bed instead of arguing with it, and what actually carries the
        // caustics in this look is the rock and coral standing in them. The reef's sand has no
        // such problem, which is why it takes the tighter, stronger net.
        caustics: Caustics(tileMetres: 2.8, strength: 0.45, drift: 0.017),
        // None. A shaft is only visible because of what the light hits on the way down, and a
        // maintained tank has a filter — this is the look whose marine snow is nearly zero for
        // exactly that reason, and shafts through clean water in a two-metre box would be
        // lighting nothing. It is also the only look lit from *inside* the room's own eyeline,
        // where a visible shaft would read as a dirty lens rather than as water.
        godRays: nil,
        // Least vignette of the three — glass and a lamp, not a diver's mask.
        bloomIntensity: 0.40, bloomThreshold: 0.90, bloomBlurRadius: 12,
        vignettingIntensity: 0.30, vignettingPower: 1.2,
        // Nearly none. A maintained tank has a filter.
        snowBirthRate: 8, snowAlpha: 0.14)
}
