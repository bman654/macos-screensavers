// God rays: the shafts you see when a strong source above the water lights the matter suspended
// in it. The complement of the caustics rather than a second helping — a caustic is the surface's
// ripple still *focused* by the time it reaches the ground, and a shaft is the same light
// scattering out of the column on its way down. That is why the looks want opposite amounts: the
// deep ocean has twenty metres of scattering path and no focus left, the shallow reef has a
// backdrop far too bright and smooth for a shaft to sit on, and the aquarium is a clean box with
// a filter and nothing for one to light.
//
// **This is the second version. The first read as strips of plastic film held in front of the
// tank**, and what fixed it was four separate things, three of which came from measuring a
// photograph of the real phenomenon beside a render of this one:
//
//   1. **The shafts fan.** They were parallel, aimed along the key, and a field of parallel bands
//      crossing the frame at one angle is a texture rather than a place. Real shafts converge on
//      the patch of surface that made them, so these are aimed from a virtual source a few metres
//      overhead — a cheat, since the sun is not a few metres up, and one the eye wants badly
//      enough that it is the honest choice.
//   2. **Each shaft lives and dies on its own clock.** They used to sway together, because the
//      whole field was one translated node — a curtain moving in a draught, which is the thing it
//      most needed not to look like. Each now fades in, wanders a little, and fades out on a
//      period of its own, so some are always arriving while others leave.
//   3. **A shaft dies with depth far faster than it did.** The photograph falls to about a fifth
//      of its peak less than halfway down the frame.
//   4. **The lateral contrast came down to about a third of the local water brightness**, which is
//      what that photograph measures at every height in it — against 45–60% here before.
//
// Two properties of this saver make additive quads cheap here. **The camera never moves**, so a
// quad that faces it once faces it forever and none of this needs a billboard constraint —
// anything assuming a still camera is marked, and a saver that ever flies its camera must revisit
// them together. And the shafts are real geometry at real depths, so the fog thins them with
// distance and the depth buffer hides them behind rock without any help.

import AppKit
import Foundation
import SceneKit

/// What a look wants of its shafts, or nil for a look with none.
struct GodRays {
    /// How many shafts exist — rather more than are visible at once, since each spends roughly
    /// half its cycle faded out entirely.
    let count: Int

    /// Peak brightness of a shaft where it enters, as a fraction of white, before its own fade.
    ///
    /// It has to be baked into the texture, because **`SCNMaterial.multiply` is silently ignored
    /// once `blendMode` is `.add`** — with the multiply colour scaled to zero the shafts still
    /// drew at full strength. `SCNNode.opacity` *does* scale an additive material, exactly and
    /// linearly, and that is what carries the per-shaft fade instead.
    let brightness: CGFloat

    /// Roughly how wide one shaft is, in metres, before a per-shaft jitter either side.
    ///
    /// Got wrong by about three times to begin with. Wide shafts do not read as light: they read
    /// as bands laid over the frame, because at that size the eye reads the *edge* rather than the
    /// beam. Many narrow ones read as one shaft broken up by the surface.
    let width: Float

    /// How far above the eye the shafts are aimed from, in metres.
    ///
    /// Pure art direction and knowingly false — the sun is not eight metres up, and real sunlight
    /// arrives parallel. But this saver's field of view is narrow enough that a perspective camera
    /// converges truly parallel shafts far too weakly to see, so they read as ruled lines, while
    /// every photograph of the real thing shows a fan. Smaller values fan harder. **This is the
    /// number to reach for if the field ever looks like a fence again.**
    let sourceHeight: Float

    /// How far a shaft wanders sideways over its life, in metres. Small: this is the surface above
    /// it moving, not the shaft going anywhere.
    let ripple: Float

    /// The range of seconds a shaft takes to fade in, wander, and fade out.
    ///
    /// A *range*, and the width of it is the point. Give every shaft one period and the field
    /// pulses in unison, which reads worse than not animating at all — the failure the first
    /// version had, where a single node carried the whole field and every shaft swayed in step.
    let period: ClosedRange<Double>
}

/// The shafts for one look, and their independent animation.
///
/// A class rather than a function returning a node, because each shaft carries state — its own
/// clock, its own resting place — and that state is precisely what keeps the field from moving as
/// one thing.
final class GodRayField {
    let node = SCNNode()

    private struct Shaft {
        let node: SCNNode
        let restX: Float
        let fadePeriod: Double
        let fadePhase: Double
        let ripplePeriod: Double
        let ripplePhase: Double
        let rippleSpan: Float
    }

    private var shafts: [Shaft] = []

    init(_ rays: GodRays, look: WaterLook, tank: Tank, aspect: Float, rand: inout Rand) {
        // After everything opaque. An additive surface drawn before the rock behind it would
        // brighten the water and then be painted over by the rock, which is the wrong order for
        // light that is meant to be *in front of* it.
        node.renderingOrder = 100

        // Three textures at different strengths and swell offsets, so shafts differ from each
        // other without needing one texture apiece.
        let images = [(1.0, 0.0), (0.84, 2.1), (0.68, 4.3)].compactMap {
            GodRayField.shaftImage(look: look, brightness: rays.brightness * $0.0, variant: $0.1)
        }
        guard !images.isEmpty else { return }

        // Shafts live in the middle of the tank's depth: near enough that the fog has not eaten
        // them, far enough to read as part of the space rather than as something on the lens.
        let nearest = tank.nearDepth + 0.30 * (tank.farDepth - tank.nearDepth)
        let farthest = tank.nearDepth + 0.85 * (tank.farDepth - tank.nearDepth)

        for index in 0..<rays.count {
            let depth = nearest + (farthest - nearest)
                * (Float(index) + rand.inRange(0.15, 0.85)) / Float(max(1, rays.count))
            let halfWidth = tank.halfWidth(atDepth: depth)
            let halfHeight = tank.halfHeight(atDepth: depth, aspect: aspect)

            // A jittered stride rather than random offsets, which clump often enough to look like
            // a mistake. Spread wider than the frame, because a shaft aimed outward from overhead
            // has to enter from beyond the edge to cross it.
            let stride = 2.6 * halfWidth / Float(rays.count)
            let restX = -1.3 * halfWidth + stride * (Float(index) + rand.inRange(0.2, 0.8))

            let shaft = SCNPlane(width: CGFloat(rays.width * rand.inRange(0.75, 1.4)
                                                * tank.propScale),
                                 height: CGFloat(halfHeight * 4.2))
            shaft.materials = [GodRayField.material(image: images[index % images.count])]

            let shaftNode = SCNNode(geometry: shaft)
            shaftNode.position = SCNVector3(restX, halfHeight * 0.45, -depth)
            // Aimed away from the virtual source overhead. This one line is what turns a set of
            // parallel bands into a fan.
            shaftNode.eulerAngles = SCNVector3(0, 0, atan2(restX, rays.sourceHeight))
            shaftNode.opacity = 0
            node.addChildNode(shaftNode)

            shafts.append(Shaft(
                node: shaftNode,
                restX: restX,
                fadePeriod: Double(rand.inRange(Float(rays.period.lowerBound),
                                                Float(rays.period.upperBound))),
                fadePhase: Double(rand.inRange(0, 2 * Float.pi)),
                // Unrelated to the fade period on purpose, so a shaft is not at the same point of
                // its wander every time it appears.
                ripplePeriod: Double(rand.inRange(5, 13)),
                ripplePhase: Double(rand.inRange(0, 2 * Float.pi)),
                rippleSpan: rays.ripple * rand.inRange(0.5, 1.3)))
        }
    }

    /// Fades and wanders each shaft on its own clock.
    ///
    /// The fade is a *rectified* sine raised to a power, and the rectification is what gives it
    /// the shape the real thing has: a shaft is absent for about half its cycle, arrives
    /// gradually, and leaves the same way. An ordinary sine offset to stay positive would leave
    /// every shaft at least half present at all times, and the field would breathe in place
    /// instead of turning over.
    func update(time: TimeInterval) {
        for shaft in shafts {
            let cycle = sin(time * 2 * .pi / shaft.fadePeriod + shaft.fadePhase)
            shaft.node.opacity = CGFloat(pow(max(0, cycle), 1.4))
            let wander = sin(time * 2 * .pi / shaft.ripplePeriod + shaft.ripplePhase)
            shaft.node.position.x = CGFloat(shaft.restX + shaft.rippleSpan * Float(wander))
        }
    }

    private static func material(image: NSImage) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .constant
        material.isDoubleSided = true
        // Additive, because light is additive: a shaft brightens what is behind it and can never
        // darken it. Alpha blending would let a shaft sit *over* a fish as a grey film.
        material.blendMode = .add
        material.writesToDepthBuffer = false
        // But it still *reads* depth, so a rock in front of a shaft occludes it. Without this
        // every shaft paints over the whole reef and the tank loses its depth entirely.
        material.readsFromDepthBuffer = true
        return material
    }

    /// One shaft: brightest where it enters and gone well before the ground, with soft sides,
    /// **already carrying its look's colour and its own brightness** — see `GodRays.brightness`
    /// for why that cannot be a material property.
    ///
    /// The colour is mostly the *water's*, not the lamp's. Additive light is added to whatever is
    /// behind it, so a shaft carrying a pale blue-white pushes dark blue water toward white, and a
    /// region that has changed hue as well as brightness reads as a different substance laid over
    /// the sea rather than as more light within it.
    private static func shaftImage(look: WaterLook, brightness: CGFloat, variant: Double,
                                   width: Int = 64, height: Int = 256) -> NSImage? {
        let mix: CGFloat = 0.72
        let key = look.key, water = look.tint
        let tint = (r: Float((key.red * (1 - mix) + water.red * mix) * brightness),
                    g: Float((key.green * (1 - mix) + water.green * mix) * brightness),
                    b: Float((key.blue * (1 - mix) + water.blue * mix) * brightness))

        return LinearImage.make(width: width, height: height) { column, row in
            let across = (Double(column) + 0.5) / Double(width) * 2 - 1
            let down = (Double(row) + 0.5) / Double(height)

            // The shaft swells and thins along its length rather than being a ruled strip. **It
            // may only ever widen.** Letting it narrow symmetrically was the obvious choice and is
            // wrong in a way no still frame shows: a narrower Gaussian is a *steeper* one, so the
            // thin part of every shaft carried the hardest edge in the picture — measured, that
            // version had sharper edges than the raised cosine it replaced while also being
            // dimmer, which is exactly the combination that reads as film.
            let phase = down * 2 * Double.pi
            let swell = 1 + 0.20 * (1 + sin(phase * 1.3 + variant))
                          + 0.10 * (1 + sin(phase * 2.7 + variant * 1.7))
            // A Gaussian, spent well inside the quad it is drawn on. A raised cosine reads as a
            // *strip*: its shoulder is flat and its falloff has a corner where the slope changes,
            // and the eye finds that corner and calls it an edge even where the value there is
            // already tiny. A Gaussian has no corner anywhere, so there is no edge to find — the
            // shaft simply stops being there. The pedestal subtraction makes it reach exactly zero
            // before the quad's own boundary, so the geometry never shows either.
            let sigma = 0.26 * swell
            let bell = exp(-across * across / (2 * sigma * sigma))
            let floor = exp(-1 / (2 * sigma * sigma))
            let sideways = max(0, (bell - floor) / (1 - floor))

            // Row 0 is the top of a bitmap rep, and the shaft is brightest where it enters. The
            // exponent is matched against a photograph rather than guessed: the real thing is down
            // to about a fifth of its peak less than halfway down the frame, and a shaft that
            // survives to the ground reads as a hanging curtain rather than as light entering from
            // above — the *fading* is the evidence that it is being scattered away.
            let along = pow(max(0, 1 - down), 4.6)
                * (0.72 + 0.28 * sin(phase * 0.9 + variant * 2.3))
            let value = Float(sideways * along)
            return (tint.r * value, tint.g * value, tint.b * value)
        }
    }
}
