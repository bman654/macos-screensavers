// God rays: the shafts you see when a strong source above the water lights the matter suspended
// in it. The complement of the caustics rather than a second helping — a caustic is the surface's
// ripple still *focused* by the time it reaches the ground, and a shaft is the same light
// scattering out of the column on its way down. That is why the looks want opposite amounts: the
// deep ocean has twenty metres of scattering path and no focus left, the shallow reef has a
// backdrop far too bright and smooth for a shaft to sit on, and the aquarium is a clean box with
// a filter and nothing for one to light.
//
// **This is the third version, and it abandons the idea the first two shared: that a field of
// shafts is a set of objects.** Both earlier versions drew N separate quads, and both failed the
// same way however the quads were shaped — a quad has a lateral extent, an extent has an edge,
// and the eye finds the edge no matter how soft the falloff inside it is, because the flat water
// on either side states exactly where the shaft stops. Measured against a reference photograph
// the failure is unambiguous: the photograph's rays are a *smooth modulation of the whole
// backdrop* — about a 25% ripple over the local water brightness at the top of the frame, with a
// dominant fold about 12% of the frame wide and no identifiable boundary anywhere — while the
// quads produced flat-topped bands of near-constant brightness that met the water in under a
// fold's width.
//
// So the field is now what the photograph is: a **curtain**. One continuous brightness function
// over the whole frame, evaluated per fragment, whose folds are a sum of a few sinusoids in
// fan-angle space. A sum of smooth waves has no edge to find — a crest simply becomes the next
// valley — and overlap cannot stack, because there are no parts to overlap: the field *is* its
// own sum. The motion falls out of the same structure. Pairs of components at nearby fold counts
// travelling in opposite directions interfere, so what the eye sees is what a shaken curtain
// does: folds brighten, exchange places with their neighbours and die over ten-odd seconds while
// drifting almost nowhere, nearby folds moving loosely together and distant ones out of step.
// No per-shaft clocks, no fades — turnover is interference, not animation.
//
// Two properties of this saver make the evaluation cheap. **The camera never moves**, so view
// space is world space and the fan geometry can be baked into the shader as constants — anything
// assuming a still camera is marked, and a saver that ever flies its camera must revisit them
// together. And the curtain is real geometry at a real depth, so the depth buffer hides it
// behind rock without any help.

import AppKit
import Foundation
import SceneKit

/// What a look wants of its curtain, or nil for a look with none.
struct GodRays {
    /// Overall strength of the additive field, tuned against the reference photograph's ~25%
    /// ripple over the local water at the top of the frame. Dimming was measured (twice) never
    /// to fix a shape problem — this number is only for holding that ratio.
    let brightness: CGFloat

    /// How far above the eye the folds converge, in metres.
    ///
    /// Pure art direction and knowingly false — the sun is not eight metres up, and real
    /// sunlight arrives parallel. But this saver's field of view is narrow enough that a
    /// perspective camera converges truly parallel shafts far too weakly to see, so they read
    /// as ruled lines, while every photograph of the real thing shows a fan. Smaller values fan
    /// harder.
    let sourceHeight: Float

    /// Scales every component's speed at once: how hard the curtain is being shaken.
    let drift: Float
}

/// The curtain for one look: two full-frame layers at different depths, each carrying the
/// interference field as a fragment shader modifier.
///
/// Two layers rather than one because the fog is depth-aware and the folds are not: the far
/// layer arrives dimmer and flatter through the fog, which is the one part of "nearer shafts
/// read stronger" that a single sheet cannot fake. Their fold sets are drawn independently, so
/// the two never beat in step.
final class GodRayField {
    let node = SCNNode()

    private var materials: [SCNMaterial] = []

    init(_ rays: GodRays, look: WaterLook, tank: Tank, aspect: Float, rand: inout Rand) {
        // After everything opaque. An additive surface drawn before the rock behind it would
        // brighten the water and then be painted over by the rock, which is the wrong order for
        // light that is meant to be *in front of* it.
        node.renderingOrder = 100

        let span = tank.farDepth - tank.nearDepth
        for layer in [(depth: tank.nearDepth + 0.38 * span, share: 0.58),
                      (depth: tank.nearDepth + 0.68 * span, share: 0.42)] {
            let halfWidth = tank.halfWidth(atDepth: layer.depth)
            let halfHeight = tank.halfHeight(atDepth: layer.depth, aspect: aspect)

            // Wider than the frustum so the quad's lateral edges are never in shot — the field
            // itself has no edge, and the geometry must not introduce one. Vertically it runs
            // from above the frame to past the horizon, and the fall-off below reaches exactly
            // zero at the quad's bottom edge for the same reason.
            let top = 1.12 * halfHeight
            let bottom = -0.60 * halfHeight
            let plane = SCNPlane(width: CGFloat(2.7 * halfWidth),
                                 height: CGFloat(top - bottom))
            let material = GodRayField.material(
                shader: GodRayField.curtainShader(
                    rays, look: look, rand: &rand,
                    halfWidth: halfWidth, top: top, bottom: bottom,
                    share: CGFloat(layer.share)))
            plane.materials = [material]
            materials.append(material)

            let layerNode = SCNNode(geometry: plane)
            layerNode.position = SCNVector3(0, (top + bottom) / 2, -layer.depth)
            node.addChildNode(layerNode)
        }
    }

    /// Advances the curtain's clock. The shader owns all the motion; this is only the tick,
    /// and it uses the scene's own time so a seeded render at a given second is reproducible.
    func update(time: TimeInterval) {
        let now = NSNumber(value: Float(time))
        for material in materials { material.setValue(now, forKey: "rayTime") }
    }

    private static func material(shader: String) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black
        // Additive, because light is additive: a shaft brightens what is behind it and can never
        // darken it. Alpha blending would let the curtain sit *over* a fish as a grey film.
        material.blendMode = .add
        material.writesToDepthBuffer = false
        // But it still *reads* depth, so a rock in front of the curtain occludes it. Without
        // this the field paints over the whole reef and the tank loses its depth entirely.
        material.readsFromDepthBuffer = true
        material.shaderModifiers = [.fragment: shader]
        return material
    }

    /// The interference field, as Metal source with this layer's fan geometry and fold set
    /// baked in as literals. **`_surface.position` is view space, and view space is world space
    /// here** because the camera sits at the origin unrotated — the one assumption of a still
    /// camera this file makes.
    ///
    /// The fold set is six sinusoids in `u`, the fan angle normalised so the visible frame spans
    /// about [-1, 1]. The counts bracket the photograph's dominant fold (~8 across the frame),
    /// and the two pairs at nearby counts moving in opposite directions are what make the field
    /// *turn over* rather than travel: their interference beats on a 10–15 s period, so a fold
    /// brightens, hands its light to a neighbour and dies, having drifted only a few percent of
    /// the frame — which is what the real thing does, and what no amount of per-quad fading ever
    /// produced. The exponential at the end sharpens crests and broadens valleys without ever
    /// creating a corner: it is the smooth analogue of "the bright fold is narrower than the
    /// dark water between folds", and its slope is gentle enough that no isoline of it reads as
    /// a boundary.
    private static func curtainShader(_ rays: GodRays, look: WaterLook, rand: inout Rand,
                                      halfWidth: Float, top: Float, bottom: Float,
                                      share: CGFloat) -> String {
        // The colour is mostly the *water's*, not the lamp's. Additive light is added to
        // whatever is behind it, so a curtain carrying a pale blue-white pushes dark blue water
        // toward white, and a region that has changed hue as well as brightness reads as a
        // different substance laid over the sea rather than as more light within it.
        let mix: CGFloat = 0.72
        let key = look.key, water = look.tint
        let strength = rays.brightness * share
        let tint = (r: (key.red * (1 - mix) + water.red * mix) * strength,
                    g: (key.green * (1 - mix) + water.green * mix) * strength,
                    b: (key.blue * (1 - mix) + water.blue * mix) * strength)

        // The fan: folds converge on a virtual source overhead, jittered off-centre so the two
        // layers' fans never share an axis exactly.
        let sourceX = rand.inRange(-0.8, 0.8) * halfWidth * 0.25
        let sourceY = rays.sourceHeight
        let psiHalf = atan(halfWidth / (sourceY - (top + bottom) / 2))

        let counts: [Float] = [3.0, 5.2, 8.1, 9.4, 14.7, 23.0]
        let amps: [Float] = [0.42, 0.30, 0.50, 0.35, 0.25, 0.18]
        let speeds: [Float] = [0.31, -0.23, 0.17, -0.28, 0.40, -0.52]
        // One draw decides which way this layer's whole set leans, then each component keeps
        // its own alternation — the rod is being shaken from one end, not the same end twice.
        let lean: Float = rand.inRange(0, 1) < 0.5 ? -1 : 1
        var terms: [String] = []
        var ampSum: Float = 0
        for i in counts.indices {
            let count = counts[i] * rand.inRange(0.90, 1.10)
            let omega = speeds[i] * lean * rays.drift * rand.inRange(0.8, 1.25)
            let phase = rand.inRange(0, 2 * .pi)
            ampSum += amps[i]
            terms.append(String(format: "%.4f * sin(%.4f * u + %.4f * rayTime + %.4f)",
                                amps[i], count * .pi, omega, phase))
        }
        let wobblePhase = rand.inRange(0, 2 * .pi)

        return """
        uniform float rayTime;
        #pragma body
        float2 p = _surface.position.xy;
        float psi = atan2(p.x - \(fmt(sourceX)), \(fmt(sourceY)) - p.y);
        float u = psi / \(fmt(psiHalf));
        // The hand on the curtain rod: a slow common sway whose phase varies gently with u, so
        // nearby folds move together, distant ones with increasing error.
        u += 0.012 * sin(0.23 * rayTime + 2.0 * u + \(fmt(wobblePhase)));
        float s = \(terms.joined(separator: "\n                + "));
        // exp() sharpens crests into folds and flattens valleys into open water, staying smooth
        // everywhere; normalised so s at its ceiling maps to 1.
        float crest = exp(0.85 * (s - \(fmt(ampSum))));
        // The curtain is strongest under its source and eases toward the frame edges, as the
        // photograph's does — never to zero, so the corners still ripple faintly.
        float envelope = 0.35 + 0.65 * exp(-0.5 * (u / 0.75) * (u / 0.75));
        // Depth kills a shaft fast: the photograph's water holds only a sixth of its surface
        // brightness by mid-frame and the folds fade with it. Exactly zero at the quad's bottom
        // edge, so the geometry never shows.
        float down = clamp((\(fmt(top)) - p.y) / \(fmt(top - bottom)), 0.0, 1.0);
        float fall = pow(1.0 - down, 3.5);
        float3 shaft = float3(\(fmt(Float(tint.r))), \(fmt(Float(tint.g))), \(fmt(Float(tint.b))))
            * (crest * envelope * fall);
        _output.color = float4(shaft, 1.0);
        """
    }

    private static func fmt(_ value: Float) -> String {
        String(format: "%.5f", value)
    }
}
