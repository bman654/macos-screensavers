// The substrate: the floor every prop stands on.
//
// Flat, and deliberately so. `build_prop.py` seats a prop's lowest vertex on z = 0, so a
// dune under the reef would leave every prop hovering or half-buried by the dune's amplitude
// unless the placement pass sampled the height field — and at these distances a 5 cm error is
// visible. Relief comes from the props and from the texture instead.
//
// The floor's geometry, extent and height are properties of the tank and are the same whatever
// it is made of; only the surface is a look. `Substrate` is that seam, and it holds every
// number the appearance depends on so a second one — the aquarium style's coloured gravel — is
// a value rather than an edit through this file. It has exactly one instance today, and one
// call site: choosing between them is a later phase's job and nothing here anticipates it.

import AppKit
import Foundation
import SceneKit

/// What the floor is made of.
struct Substrate {
    /// Diffuse colour of the ground between the grains.
    let base: (red: CGFloat, green: CGFloat, blue: CGFloat)
    /// Half-width of the per-grain shade offset either side of `base`. The blue channel takes
    /// 80% of it, which is what makes a grain read as a grain of the same material rather than
    /// as a fleck of a different one.
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
    static let sand = Substrate(base: (0.36, 0.33, 0.26),
                                grainContrast: 0.105,
                                grainRadius: 0.6...2.0,
                                grainCount: 2600,
                                tileSize: 0.70,
                                roughness: 0.92)
}

enum TankFloor {
    /// Wider than the frustum is at `Tank.floorFarDepth`, so the floor never ends inside the
    /// frame. Cheap: the whole floor is two triangles per segment.
    private static let width: CGFloat = 17

    /// A plane in the XZ plane at the seabed node's own origin, running from the camera out
    /// past the fog. Its parent carries the height, which is where the drawable's aspect ratio
    /// gets into it — see `Tank.floorY(aspect:)`.
    static func node(_ substrate: Substrate) -> SCNNode {
        let depth = CGFloat(Tank.floorFarDepth)
        let plane = SCNPlane(width: width, height: depth)
        // One segment per ~1.5 m. A single quad would take its lighting from four corners
        // spread over 34 m, which under a directional key reads as a flat wash.
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
        NSColor(calibratedRed: max(0, substrate.base.red + shade),
                green: max(0, substrate.base.green + shade),
                blue: max(0, substrate.base.blue + shade * 0.8), alpha: 0.8).setFill()
        for dx in [-size, 0, size] where abs(x + dx - size / 2) < size / 2 + radius {
            for dy in [-size, 0, size] where abs(y + dy - size / 2) < size / 2 + radius {
                NSBezierPath(ovalIn: NSRect(x: x + dx - radius, y: y + dy - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
        }
    }
}
