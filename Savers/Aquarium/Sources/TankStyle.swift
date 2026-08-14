// What kind of tank this is: its dimensions, how densely it is decorated, what the floor is
// made of, and how the water is lit.
//
// `docs/aquarium-plan.md` §2a is the brief. The split must not reach past the surface into the
// scene's structure — geometry, placement, population and fish behaviour are shared, and a
// style is only ever a bag of numbers handed to code that does not know which style it is.
//
// The water itself lives in `WaterLook` and the floor's surface in `Substrate`, because those
// two are one decision — see `docs/water-looks.md` — and a style is where they are paired up.

import AppKit
import Foundation
import simd

// MARK: - The style

/// Which of the looks a launch is wearing. The names are what the settings sheet persists —
/// see `AquariumSettings` — so they are stable strings rather than an ordinal, and renaming a
/// case silently resets every user who had chosen it.
enum TankStyleName: String, CaseIterable {
    case aquarium
    case shallowReef
    case deepOcean

    /// One of the three, uniformly. `next()` is a half-open [0, 1), and the clamp is for the
    /// rounding at the top of that range rather than for the mathematics.
    static func drawn(_ rand: inout Rand) -> TankStyleName {
        let all = allCases
        return all[min(Int(rand.next() * Float(all.count)), all.count - 1)]
    }
}

struct TankStyle {
    let name: TankStyleName
    let tank: Tank
    /// Props per unit of reef floor, relative to the reference tank — see `Tank.propCount`,
    /// which turns it back into a number. Stated as a density rather than as a count because
    /// the amount of floor a tank has is not proportional to how big the tank is.
    let propDensity: Float
    /// How many of the props are showpieces that anchor the frame. Its own number rather than a
    /// share of the count: an anchor claims a metre or more of clearance, so three of them in a
    /// small tank take the whole floor and leave nothing placeable behind them.
    let anchorCount: Int
    /// How much of each prop's *declared* minimum spacing is honoured — see `ReefLayout.layout`.
    /// The geometric clearance is never negotiable; this is only the breathing room.
    let spacingSlack: Float
    /// How many *distinct* models a full-tank launch may import — a load budget, not a look.
    /// Instances are clones and cost almost nothing; each new model is another 5–10 MB archive
    /// to read before the first frame.
    let distinctProps: Int
    let substrate: Substrate
    let water: WaterLook

    /// Draws the style. The ocean's dimensions are part of the draw — see `oceanTank`.
    ///
    /// `seed` is the launch's, and is *not* the same thing as `rand`: it is there for the draws
    /// that must not consume from the launch stream, which is every draw that did not exist when
    /// the seeded renders in `docs/water-looks.md` were made. Taking a number from `rand` here
    /// would leave `AQUARIUM_SEED=7` naming a different layout and a different school than it
    /// named before — silently, because both are plausible tanks.
    static func draw(_ name: TankStyleName, seed: UInt64, rand: inout Rand) -> TankStyle {
        switch name {
        case .aquarium:
            return TankStyle(
                name: name,
                // Shallow, and much narrower in depth than any ocean draw: a tank, not a
                // seascape. An ocean view has decorations receding into the distance; a glass
                // tank has a back wall two metres away. The wider field of view is the other
                // half of that — you stand close to an aquarium, not across a reef from it.
                //
                // The band is the one thing here the ocean cannot have: this is the only look
                // seen from *outside*, through a pane, so it is the only one where the gravel
                // is cut open across the bottom of the frame. Eleven percent is a real bed
                // seen from a real distance, and it is also as deep as it can go — the lowest a
                // fish is ever placed is 0.69 of the frame's half-height, and a band past about
                // 15% would start taking fish in front of gravel they are supposed to be
                // swimming behind.
                tank: Tank(fieldOfView: 26, nearDepth: 2.0, farDepth: 6.2,
                           substrateBand: 0.11),
                // Nobody keeps a sparse aquarium. Less depth, more density is the whole brief:
                // the reef band is a third of the metres across, and it holds nearly twice the
                // ornaments — which is affordable only because `propScale` shrank them all.
                // Raised from 1.7 when the pane pushed the reef's near edge back to the glass:
                // the band it stands in lost a quarter of its area, and density is per unit of
                // floor, so holding the tank as full as it was means asking for more of it.
                propDensity: 2.3,
                // One showpiece and a crowd around it. Three anchors — the wreck, the arch and
                // the pillars together — fill a tank this size on their own, and every small
                // prop drawn afterwards then fails to find room.
                anchorCount: 2,
                // Ornaments in a home tank crowd each other, and the declared minimums were
                // written for open seabed: at full slack the wreck's three metres of clearance
                // alone claim three quarters of this floor and nothing else can be seated.
                spacingSlack: 0.5,
                // Variety is most of what "stuffed" means, so the aquarium pays for more
                // distinct imports than the ocean does. It is the one place the load budget is
                // spent on a look, and it is deliberate.
                distinctProps: 11,
                // Which gravel, drawn per launch, off a stream of its own — see `draw`.
                substrate: .gravel(GravelPalette.forLaunch(seed: seed)),
                water: .aquarium)
        case .shallowReef, .deepOcean:
            // The two ocean styles are one tank seen at two depths: same dimensions, same
            // density, and every difference between them is the water and what the water has
            // already done to the sand by the time it reaches the floor.
            let deep = name == .deepOcean
            return TankStyle(
                name: name,
                tank: oceanTank(rand: &rand),
                propDensity: 1,
                anchorCount: 3,
                spacingSlack: 1,
                distinctProps: 8,
                substrate: deep ? .deepSand : .reefSand,
                water: deep ? .deepOcean : .shallowReef)
        }
    }

    /// The ocean's volume, drawn fresh each launch.
    ///
    /// Some launches close in — a smaller cube of water, fewer fish in it, each of them bigger
    /// and more detailed — and some sit back at the reference tank's reach and take in a much
    /// larger volume with less of every animal. The two knobs are the same knob seen twice: both
    /// the depth range and the field of view scale `reefFrameWidth`, and therefore `propScale`.
    /// What differs is the perspective: a long, narrow tank compresses the size difference
    /// between the near and the far reef, a short wide one exaggerates it. Drawing both
    /// independently is what gives the range its variety rather than one sliding zoom.
    ///
    /// The reference tank is the *far* end of the range, never exceeded — past it the fish are
    /// specks and the fog has eaten the reef.
    private static func oceanTank(rand: inout Rand) -> Tank {
        let reach = rand.inRange(0.58, 1.0)
        return Tank(fieldOfView: CGFloat(rand.inRange(17, 22.5)),
                    nearDepth: Tank.reference.nearDepth * reach,
                    farDepth: Tank.reference.farDepth * reach)
    }
}
