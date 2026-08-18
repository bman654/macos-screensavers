// The volume of water everything else is placed in.
//
// Split out of `AquariumScene` because the floor, the reef and the school all measure
// themselves against these numbers, and every one of them has to take the *real* drawable's
// aspect ratio rather than assume one.
//
// A tank is a *value*, not a set of constants, because the same scene is built at several
// sizes: an ocean view whose reach is drawn fresh each launch, and a glass aquarium a few
// metres deep. Everything below is either stated as a fraction of the depth range or derived
// from it, so that changing the range moves the whole tank together instead of leaving one
// distance behind — a fixed floor depth inside a shrunken tank would put the sand line
// somewhere else entirely.
//
// The one asymmetry, and the reason this file exists: **props hold their on-screen size while
// fish hold their real size.** See `propScale`.

import AppKit
import Foundation
import simd

struct Tank {
    /// Narrow reads as near-orthographic 2.5D; wider reads as standing closer to the glass.
    let fieldOfView: CGFloat
    /// Depth range the school occupies, in metres in front of the camera. The near limit is
    /// far enough back that a fish leaving the tank does so off-screen rather than popping.
    let nearDepth: Float
    let farDepth: Float

    /// How much of the frame's height the substrate fills *in section*, pressed against the
    /// front pane. Nil for open water, which has no pane and no section.
    ///
    /// This is the one number that says the viewer is standing outside a glass box rather than
    /// swimming in the tank, and it is what puts the band of cut gravel across the bottom of an
    /// aquarium photograph. Stated as a fraction of the frame because that is what it is: see
    /// `glassDepth` for why the metres it works out to are a consequence rather than a choice.
    let substrateBand: Float?

    let halfFOVTangent: Float

    init(fieldOfView: CGFloat, nearDepth: Float, farDepth: Float, substrateBand: Float? = nil) {
        self.fieldOfView = fieldOfView
        self.nearDepth = nearDepth
        self.farDepth = max(farDepth, nearDepth + 0.5)
        // A band of half the frame or more would put the glass at infinity, and one deep enough
        // to reach the fish is a composition problem rather than an arithmetic one — see
        // `glassDepth`.
        self.substrateBand = substrateBand.map { min(max($0, 0), 0.3) }
        halfFOVTangent = Float(tan(fieldOfView * .pi / 180 / 2))
    }

    /// The tank that shipped, and the yardstick every other one is measured against — both for
    /// prop size (`propScale`) and for school size (`schoolCount`). It is also the far end of
    /// the ocean's own draw: an ocean launch reaches at most this far, never further.
    static let reference = Tank(fieldOfView: 22, nearDepth: 5.5, farDepth: 25)

    // MARK: Derived depths
    //
    // Fractions rather than metres, calibrated so `reference` reproduces the numbers the tank
    // shipped with exactly. Stating them this way is what makes a tank scale as one object.

    /// The depth at which the sand meets the bottom edge of the frame — i.e. the floor is set
    /// exactly one half-height below the eye *at this depth*, so nearer sand is below the frame
    /// and further sand climbs toward the horizon.
    ///
    /// Stating it as a depth rather than as a height is what makes the tank aspect-invariant.
    /// The sand's screen position at depth `d` works out to `-floorEntryDepth / d` in normalized
    /// device coordinates, with the aspect ratio cancelling — so a 32:9 drawable shows the same
    /// beach line as a 16:9 one instead of the reef sliding off the bottom, which is what a
    /// fixed height in metres would do. Everything standing on the floor inherits that for free.
    var floorEntryDepth: Float { nearDepth * 1.127 }

    /// Past `fogEnd`, so the far edge of the sand is fully fogged out and there is no rim where
    /// the floor simply stops. The same reason the background and the fog colour must agree.
    var floorFarDepth: Float { farDepth * 1.36 }

    /// Where the front pane of glass stands. Nil for open water.
    ///
    /// It is a *consequence* of `substrateBand`, not an independent number, and the derivation
    /// is the whole reason a cross-section can exist at all. The floor meets the bottom of the
    /// frame at `floorEntryDepth` and everything nearer is below the frame — which is why a
    /// camera sitting on the glass, as this one always did, can never see the bed in section
    /// however deep the bed is. Standing the viewer *back* from the pane is what brings the cut
    /// into shot: at depth `d` the substrate's surface lands at NDC y = `-floorEntryDepth / d`,
    /// so a pane at `floorEntryDepth / (1 - 2f)` leaves exactly `f` of the frame's height below
    /// it for the section to fill, in any tank at any drawable shape.
    ///
    /// The floor is then drawn only from here outward. Everything nearer is behind the viewer's
    /// side of the glass and must not be drawn at all, or it paints over the section it is
    /// supposed to be sitting behind.
    var glassDepth: Float? {
        substrateBand.map { floorEntryDepth / max(0.4, 1 - 2 * $0) }
    }

    /// The nearest the substrate's *surface* is drawn. The glass where there is one, and the
    /// camera itself where there is not.
    var floorNearDepth: Float { glassDepth ?? 0 }

    /// The far end of the depth band the reef is scattered through.
    ///
    /// It stops a long way short of `fogEnd`, and that is the floor's doing rather
    /// than the fog's: perspective compresses everything past about three quarters of the tank
    /// into the last few degrees before the horizon, so the floor there crosses from lit to
    /// fully fogged within a hand's width of screen. A prop beyond that stands on ground which
    /// has already dissolved into the background, and reads as hanging in the water — the
    /// sunken ship did exactly that at 21 m in the reference tank. Keeping the reef where its
    /// own floor is still visible is what seats it.
    var reefFarDepth: Float { farDepth * 0.74 }

    var depthCullNear: Float { nearDepth * 0.836 }
    var depthCullFar: Float { farDepth * 1.08 }

    var fogStart: Float { nearDepth * 0.8 }
    var fogEnd: Float { farDepth * 1.05 }

    /// Screen-space speed is what the eye judges, and that is angular — so world speed has to
    /// grow with depth or the far fish crawl. Unitless, and therefore the same in every tank.
    static let speedPerDepth: Float = 0.023

    /// `projectionDirection` is pinned horizontal, so the horizontal extent is fixed by the
    /// field of view alone and it is the *vertical* extent that shrinks as the drawable gets
    /// wider — half-height is exactly half-width divided by the aspect ratio, verified against
    /// the matrix `SCNCamera.projectionTransform(withViewportSize:)` actually builds. Vertical
    /// placement therefore has to come from the real drawable: on a 32:9 display the visible
    /// half-height is barely half of what 16:9 gives, and fish laid out against an assumed
    /// 16:9 spend whole crossings outside the frame.
    static let verticalFill: Float = 0.62

    /// Used only for a degenerate drawable size, which `SaverView` should never hand over.
    static let fallbackAspect: Float = 16.0 / 9.0

    /// How far above the sand a fish may be placed, as a multiple of its own **girth**.
    ///
    /// Girth rather than length, and the difference is not academic. Stated in body lengths this
    /// was 1.6, which for the ordinary fish in the library works out at four to five girths and is
    /// exactly right — but a moray is twenty times its own girth end to end, so the same rule
    /// demanded three quarters of a metre of water beneath an animal 0.49 m long. That collided
    /// with the "at most half the column" clamp below it and pinned the eel at mid-height, where
    /// it could not descend and no behaviour could bring it down.
    ///
    /// The clearance a fish needs under it is set by how deep through the body it is, which is
    /// what this now says. Five girths reproduces the old numbers for every species whose length
    /// and girth track each other, and only changes the ones where they do not.
    static let fishFloorClearance: Float = 5.0

    /// The same margin for an animal that holds station on the bottom rather than cruising past
    /// it.
    ///
    /// **Five girths is a margin, not a clearance, and on a deep-bodied animal it is larger than
    /// half the water column.** `School.place` clamps the spawn height to `ceiling / 2` for
    /// safety, so a curled seahorse — as deep front to back as it is tall — came out pinned to
    /// mid-water beside the tangs, which is the one place a seahorse never is. A drifter is
    /// meant to be down among the plants, so it starts at the margin the runtime actually
    /// enforces every frame (`Avoidance.clamp`) instead of the shy one a cruiser is given.
    static let drifterFloorClearance: Float = 1.5

    // MARK: Prop scale — the invariance

    /// The width of the frame, in metres, at the middle of the band the reef stands in.
    ///
    /// This is the one length that summarizes a tank: it is what a decoration's size is
    /// actually judged against, since that is roughly where decorations stand.
    var reefFrameWidth: Float { (floorEntryDepth + reefFarDepth) * halfFOVTangent }

    /// What every prop's own drawn scale is multiplied by, so that a decoration holds a roughly
    /// constant *angular* size no matter how big the tank is.
    ///
    /// Direct art direction, and it inverts the obvious assumption: the sunken ship should read
    /// at about the same fraction of the frame in a two-metre glass tank as in a twenty-metre
    /// seascape, which means a physically smaller boat. Fish are the opposite — they keep the
    /// real metres their manifest declares — so a smaller tank forces them nearer the camera and
    /// they grow on screen. That asymmetry is what makes an aquarium read as an aquarium: big
    /// fish among modestly sized ornaments. A 0.4 m angelfish next to a 0.6 m wreck is the
    /// intended result, not a bug.
    ///
    /// A prop's angular size is `size / (depth * tan(fov/2))`, and the depths props stand at are
    /// all proportional to the reef band, so dividing by `reefFrameWidth` cancels both the depth
    /// and the field of view in one term. It is applied *on top of* each prop's own
    /// `scaleRange` draw, never in place of it — a boulder still varies in size against its
    /// neighbours, the whole reef simply lives at a different scale.
    var propScale: Float { reefFrameWidth / Tank.reference.reefFrameWidth }

    /// How much floor the reef has to fill, measured in units of a reference-tank prop's own
    /// footprint area — so it is directly comparable between tanks of different sizes.
    ///
    /// Metres of floor are not comparable: `propScale` shrinks the props alongside the tank, so
    /// a two-metre tank's four square metres of gravel hold far more ornaments than four square
    /// metres of open seabed would. Dividing the area by `propScale²` is what makes "how full
    /// does this look" a single number. It is not purely a matter of how deep the tank is — a
    /// narrow field of view compresses more floor into the same frame, which is why a
    /// telephoto reef looks busier than a wide-angle one at the same prop count.
    func reefCapacity(aspect: Float) -> Float {
        let near = reefNearDepth(aspect: aspect)
        let far = max(reefFarDepth, near + nearDepth * 0.18)
        return halfFOVTangent * (far * far - near * near) / (propScale * propScale)
    }

    /// How many props to draw, from the count the reference tank uses and the style's declared
    /// density.
    ///
    /// Derived from the capacity rather than scaled straight off the base count, because a
    /// count the reef has no room for does not produce a denser reef — `ReefLayout` simply
    /// fails to seat the surplus and the tank comes out looking arbitrary. Density is therefore
    /// stated as props per unit of floor, and this turns it back into a number of props.
    func propCount(_ base: Int, density: Float, aspect: Float) -> Int {
        let ratio = reefCapacity(aspect: aspect)
            / Tank.reference.reefCapacity(aspect: aspect)
        return max(1, Int((Float(base) * density * ratio).rounded()))
    }

    /// How many fish a tank this size should hold, given the count the reference tank uses.
    ///
    /// Holding the count fixed would pack a small tank solid, because the fish grow on screen
    /// while the frame does not: screen coverage per fish goes as `1 / reefFrameWidth²`, so
    /// exact coverage-invariance would be an exponent of 2. The exponent is lower than that on
    /// purpose — the fish are the subject, and a close-in tank is allowed to be a little busier
    /// than a strict area argument says — and the floor keeps a tight tank from emptying out to
    /// two or three animals, which reads as a bug rather than as intimacy.
    func schoolCount(_ base: Int) -> Int {
        let scaled = Int((Float(base) * pow(propScale, 1.6)).rounded())
        return max(Int((Float(base) * 0.45).rounded(.up)), scaled)
    }

    // MARK: The floor

    /// Negative: the floor is below the eye. Derived from the drawable, never assumed.
    func floorY(aspect: Float) -> Float {
        -halfHeight(atDepth: floorEntryDepth, aspect: aspect)
    }

    /// The nearest a prop may stand, which — unlike the floor — is not aspect-invariant.
    ///
    /// On a 16:9 drawable this sits *inside* `floorEntryDepth`, so the nearest props stand on
    /// floor that is already below the frame and are cropped by the bottom edge. Stopping the
    /// reef where the floor starts leaves an empty bright apron of sand across the bottom of
    /// the frame, and something crossing that edge is what gives the tank a foreground.
    ///
    /// A wider drawable has a shorter frustum at every depth, though, and a prop's size on the
    /// floor is fixed once `propScale` has been applied. On 32:9 the reference tank's frame is
    /// only 0.77 m tall at 7 m, so a boulder that crops nicely on 16:9 is taller than the whole
    /// frame. The near limit is therefore the depth at which the frame is tall enough to hold a
    /// prop, and the fixed limit applies only once that is satisfied. The height a prop needs
    /// scales with `propScale` for the same reason the prop does — otherwise a shrunken tank
    /// would push its reef away for clearance it no longer needs.
    /// A prop may never stand nearer than the glass either. Nothing on this floor is on the
    /// viewer's side of the pane, and a prop that were would stand on floor that is not drawn
    /// and read as hovering over the cross-section band.
    func reefNearDepth(aspect: Float) -> Float {
        max(floorNearDepth,
            max(floorEntryDepth * 0.887, 0.45 * propScale * aspect / halfFOVTangent))
    }

    // MARK: The walls

    /// Whether this water is a closed glass box rather than open sea.
    ///
    /// It is the same fact as `substrateBand`, asked the other way round. A tank is seen from
    /// outside through a pane — which is what puts the cut gravel across the bottom of the frame
    /// — and a pane is a wall, so the look that has one is exactly the look a fish cannot leave.
    /// The ocean has neither.
    var isEnclosed: Bool { glassDepth != nil }

    /// The nearest a fish may swim.
    ///
    /// In a glass tank this is the *pane*, not `nearDepth`, and the difference is a real one:
    /// `nearDepth` is 2.0 m in the aquarium and the pane stands at 2.89 m, so the depth range
    /// the school used to be placed through began almost a metre in front of the glass. A fish
    /// there is on the viewer's side of the window, swimming over the cross-section band instead
    /// of behind it, and the band was capped at 11% partly to keep that from being visible.
    var swimNearDepth: Float { glassDepth ?? nearDepth }

    /// The furthest a fish may swim. The back wall of a glass tank, and in the ocean simply the
    /// far end of the depth range the school was always drawn through.
    ///
    /// It is `farDepth` in both cases, and for the tank that is a choice rather than a
    /// coincidence: the fog reaches 1.05 × `farDepth`, so a fish against the back wall is very
    /// nearly gone into the water colour. That is what the back of a real tank looks like, and
    /// it is also why the wall needs no geometry to read.
    var swimFarDepth: Float { farDepth }

    /// How far to the side, and how far up, a fish may swim at a given depth.
    ///
    /// **The tank is the frustum.** Its side walls and its ceiling are the edges of the picture,
    /// so in plan it is a trapezoid whose sides splay outward with depth, and in elevation
    /// another one. That is not a glass box — a real one has parallel walls — and it is the
    /// right answer anyway for one reason: no wall is drawn, so the only way to observe the
    /// shape of one is by where fish turn round. The requirement is that a fish never leaves the
    /// frame, and the frame is a frustum.
    ///
    /// A parallel-walled box cannot satisfy that requirement and also use the picture, and the
    /// aquarium's 26° is wide enough to make the gap large. Sized to the frustum at the pane the
    /// box is 0.67 m half-wide, which at the back wall is 47% of the visible width — a corridor
    /// down the middle of the frame with dead water either side of it. Sized to the frustum at
    /// the back wall it is 1.43 m half-wide, and a fish out at that x anywhere near the pane is
    /// off the edge of the screen. Matching the frustum is the only shape that is both fully
    /// used and fully visible, and the price is that a fish turns round sooner when it is near
    /// the front — which reads as glass.
    ///
    /// The floor is the exception and stays a true horizontal plane, because the floor is the
    /// one wall that is actually *drawn*. A substrate that flared with the frustum would be a
    /// bowl, and `TankFloor` would have to be rebuilt to draw one.
    func wallX(atDepth depth: Float) -> Float { halfWidth(atDepth: depth) }

    /// The top of the water, as a height at a given depth.
    ///
    /// It follows the frustum for the same reason the side walls do, and applying the trapezoid
    /// to only one axis was a real omission: the frame at the back wall is 2.8 times taller than
    /// it is at the pane, so a waterline stated as one horizontal plane would have left the top
    /// half of the back of the frame as water no fish is allowed into. Nothing draws a waterline,
    /// so there is nothing to contradict.
    ///
    /// The two fills differ because the two looks want different things from the top of the
    /// frame. A tank is bounded by the picture and wants to use it. Open sea has no surface in
    /// shot at all — the shallow reef's is above the frame and the deep ocean's is twenty metres
    /// up — so its ceiling is purely a composition limit, and a low one keeps the school off the
    /// top edge instead of against it.
    func ceilingY(atDepth depth: Float, aspect: Float) -> Float {
        halfHeight(atDepth: depth, aspect: aspect)
            * (isEnclosed ? Tank.tankCeilingFill : Tank.verticalFill)
    }

    /// Short of 1 by about a fish, so an animal holding the ceiling is inside the frame rather
    /// than sliced by its top edge.
    static let tankCeilingFill: Float = 0.88

    // MARK: Frustum

    func halfWidth(atDepth depth: Float) -> Float { depth * halfFOVTangent }

    func halfHeight(atDepth depth: Float, aspect: Float) -> Float {
        halfWidth(atDepth: depth) / aspect
    }

    static func aspect(of drawableSize: CGSize) -> Float {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return fallbackAspect }
        return Float(drawableSize.width / drawableSize.height)
    }
}
