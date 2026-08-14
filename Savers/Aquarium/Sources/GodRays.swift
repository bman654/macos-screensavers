// God rays: the shafts you see when a strong source above the water lights the matter suspended
// in it. The complement of the caustics rather than a second helping of them — a caustic is the
// surface's ripple still *focused* by the time it reaches the ground, and a shaft is the same
// light scattering out of the column on its way down. That is why the two looks want opposite
// amounts: the deep ocean has twenty metres of scattering path and no focus left, the shallow
// reef has both, and the aquarium is a clean box with a filter and has neither to speak of.
//
// They are drawn as additive quads, and two facts about this saver make that far cheaper than
// it would otherwise be:
//
//   - **The camera never moves.** It sits at the origin looking down -Z for the life of the
//     scene, so a quad that faces the camera once faces it forever and none of this needs a
//     billboard constraint. Anything here that assumes a still camera is marked; a saver that
//     ever flies the camera would have to revisit them together.
//   - **The shafts are genuinely parallel in world space**, so the perspective camera converges
//     them toward the light on its own. Nothing fans them by hand.
//
// The hazard is the one marine snow already taught: additive geometry at any real density
// saturates an HDR frame to white. These are wide, few, and faint, and the alpha that looks
// right is much lower than it seems it should be.

import AppKit
import Foundation
import SceneKit

/// What a look wants of its shafts, or nil for a look with none.
struct GodRays {
    /// How many shafts cross the frame. Few: this reads as light, and a picket fence of them
    /// reads as geometry.
    let count: Int

    /// Peak brightness of a shaft where it enters the top of the frame, as a fraction of white.
    /// Additive, so this stacks anywhere two shafts overlap — which is why it is far lower than
    /// it looks like it ought to be.
    let brightness: CGFloat

    /// Roughly how wide one shaft is, in metres, before a per-shaft jitter either side.
    ///
    /// The single most important number here and the one a first pass got wrong by about three
    /// times. Wide shafts do not read as light: they read as flat diagonal bands laid over the
    /// frame, because at that size the eye reads the *edge* rather than the beam. Many narrow
    /// shafts read as one shaft of light broken up by the surface, which is what this is.
    let width: Float

    /// How far a shaft wanders sideways, in metres, and how long a full wander takes. The
    /// surface that makes these is moving, so a shaft that stands perfectly still reads as a
    /// painted-on streak; one that moves too fast reads as a searchlight.
    let sway: Float
    let swayPeriod: Double
}

enum GodRayField {
    /// Builds the shafts for a look, already positioned in the tank, or nil if the look has none.
    ///
    /// The node is returned rather than added, so the caller decides where it sits in the scene
    /// graph — these belong to the world and not to the seabed, which moves when the drawable
    /// reshapes.
    static func node(_ rays: GodRays, look: WaterLook, tank: Tank, aspect: Float,
                     rand: inout Rand) -> SCNNode {
        let field = SCNNode()
        // After everything opaque. An additive surface drawn before the rock behind it would
        // brighten the water and then be painted over by the rock, which is the wrong order for
        // light that is supposed to be *in front of* it.
        field.renderingOrder = 100

        // Three images rather than one, so shafts differ in strength without needing a
        // per-shaft multiply — which is the property that turned out not to work here at all.
        let images = [1.0, 0.82, 0.66].compactMap {
            shaftImage(look: look, brightness: rays.brightness * $0)
        }
        guard !images.isEmpty else { return field }
        // Shafts live in the middle of the tank's depth: near enough that the fog has not eaten
        // them, far enough that they read as part of the space rather than as something on the
        // lens. The near end is also kept behind the reef's front edge so a shaft cannot appear
        // to pass in front of a rock it should be behind.
        let nearest = tank.nearDepth + 0.30 * (tank.farDepth - tank.nearDepth)
        let farthest = tank.nearDepth + 0.85 * (tank.farDepth - tank.nearDepth)

        for index in 0..<rays.count {
            let depth = nearest + (farthest - nearest)
                * (Float(index) + rand.inRange(0.15, 0.85)) / Float(max(1, rays.count))
            let halfWidth = tank.halfWidth(atDepth: depth)
            let halfHeight = tank.halfHeight(atDepth: depth, aspect: aspect)

            // Spread across the frame with a jittered stride rather than at random: a handful of
            // random x offsets clumps often enough to look like a mistake, and the whole point
            // of the field is that it is evenly lit from above.
            let stride = 2 * halfWidth / Float(rays.count)
            let x = -halfWidth + stride * (Float(index) + rand.inRange(0.2, 0.8))

            // Tall enough to leave the frame at both ends at this depth, so a shaft never shows
            // an end. Width is in metres and holds across looks, because a shaft's width is set
            // by the ripple that made it and not by how big the tank is.
            let shaft = SCNPlane(width: CGFloat(rays.width * rand.inRange(0.7, 1.45)
                                                * tank.propScale),
                                 height: CGFloat(halfHeight * 4.2))
            shaft.materials = [material(image: images[index % images.count])]

            let node = SCNNode(geometry: shaft)
            node.position = SCNVector3(x, halfHeight * 0.45, -depth)
            // Tilted off vertical by exactly as far as the key is, and in the same direction, so
            // the shafts and the light that made them agree. A quad's own plane still faces the
            // camera, which is what the fixed camera buys.
            node.eulerAngles = SCNVector3(0, 0, (90 - look.key.elevation) * .pi / 180
                                            * (look.key.azimuth < 0 ? -1 : 1))
            field.addChildNode(node)
        }
        return field
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

    /// One shaft: bright where it enters at the top and gone before the ground, with soft sides,
    /// **already carrying its look's colour and its own brightness**.
    ///
    /// Baking those in is not tidiness. `SCNMaterial.multiply` is silently ignored once
    /// `blendMode` is `.add`: with the multiply colour scaled all the way to zero the shafts
    /// still drew at full strength, which is a failure that looks exactly like a mis-tuned
    /// constant rather than like a property having no effect. Brightness has to be in the
    /// texture, and since the texture is generated per look anyway that costs nothing.
    ///
    /// The colour is the look's key seen through its own water — neither alone is right, because
    /// the light really is the key and it really has travelled through this water to get here.
    private static func shaftImage(look: WaterLook, brightness: CGFloat,
                                   width: Int = 64, height: Int = 256) -> NSImage? {
        let mix: CGFloat = 0.45
        let key = look.key, water = look.tint
        let tint = (r: Float((key.red * (1 - mix) + water.red * mix) * brightness),
                    g: Float((key.green * (1 - mix) + water.green * mix) * brightness),
                    b: Float((key.blue * (1 - mix) + water.blue * mix) * brightness))

        return LinearImage.make(width: width, height: height) { column, row in
            // A high power on the cosine, because the edge is what gives a shaft away. At 1.6
            // the sides were still crisp enough that the field read as diagonal bands ruled
            // across the frame rather than as light in the water.
            let across = (Double(column) + 0.5) / Double(width) * 2 - 1
            let sideways = pow(max(0, cos(across * Double.pi / 2)), 2.6)
            // Row 0 is the top of a bitmap rep, and the shaft is brightest where it enters.
            // Steep, so it is spent well before it reaches the ground: a shaft that survives all
            // the way down reads as a hanging curtain rather than as light entering from above,
            // because the *fading* is the evidence that it is being scattered away.
            let down = (Double(row) + 0.5) / Double(height)
            let along = pow(max(0, 1 - down), 3.2)
            let value = Float(sideways * along)
            return (tint.r * value, tint.g * value, tint.b * value)
        }
    }
}
