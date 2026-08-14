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

    /// How far above the sand a fish may be placed, as a multiple of its own length. Fish hold
    /// their world height for a whole crossing, so this is a spawn constraint rather than a
    /// collision response — it only has to be big enough that the bob never dips into sand.
    static let fishFloorClearance: Float = 1.6

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
