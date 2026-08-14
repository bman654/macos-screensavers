// The substrate's geometry: the floor every prop stands on, and — where the tank has a front
// pane — the band of it you see in section through the glass.
//
// Flat, and deliberately so. `build_prop.py` seats a prop's lowest vertex on z = 0, so a dune
// under the reef would leave every prop hovering or half-buried by the dune's amplitude unless
// the placement pass sampled the height field — and at these distances a 5 cm error is visible.
// Relief comes from the props and from the texture instead.
//
// What the floor is *made of* lives in `Substrate`, and what that looks like in
// `SubstrateTexture`; the extent and height here are properties of the tank and are the same
// whatever it is made of.

import AppKit
import Foundation
import SceneKit

enum TankFloor {
    /// The substrate, as one node: the surface, plus its cross-section where the tank has a
    /// front pane to press it against.
    ///
    /// Both sit in the seabed node's own space, whose origin is the top of the bed — the parent
    /// carries the height, which is where the drawable's aspect ratio gets into it. See
    /// `Tank.floorY(aspect:)`.
    static func node(_ substrate: Substrate, tank: Tank) -> SCNNode {
        let maps = SubstrateTexture.maps(substrate)
        let node = SCNNode()
        node.addChildNode(surface(substrate, maps: maps, tank: tank))
        if let glassDepth = tank.glassDepth {
            node.addChildNode(section(substrate, tank: tank, glassDepth: glassDepth))
        }
        return node
    }

    // MARK: - The surface

    /// A plane in the XZ plane running from the front pane — or from the camera, in open water
    /// — out past the fog.
    private static func surface(_ substrate: Substrate, maps: SubstrateTexture.Maps,
                                tank: Tank) -> SCNNode {
        let near = CGFloat(tank.floorNearDepth)
        let depth = CGFloat(tank.floorFarDepth) - near
        // Comfortably wider than the frustum is at the floor's far edge, so the floor never
        // ends inside the frame — on any drawable shape, since a wider one only makes the
        // frustum shorter. Derived rather than fixed because a two-metre tank given the
        // reference tank's seventeen metres of floor would tile its grain sixty times across
        // four metres of visible sand. Cheap either way: two triangles per segment.
        let width = CGFloat(2.5 * tank.halfWidth(atDepth: tank.floorFarDepth))
        let plane = SCNPlane(width: width, height: depth)
        // A single quad would take its lighting from four corners spread across the whole
        // tank, which under a directional key reads as a flat wash. A segment count rather
        // than a spacing, so it stays proportional as the floor scales with the tank.
        plane.widthSegmentCount = 12
        plane.heightSegmentCount = 24

        let material = plane.firstMaterial ?? SCNMaterial()
        apply(maps, to: material, tiles: (width / substrate.tileSize,
                                         depth / substrate.tileSize))
        material.roughness.contents = substrate.roughness
        // The floor is lit from above and never from behind; a back face would only ever be
        // seen through it by a bug, and culling it halves the fill for the largest surface in
        // the tank.
        material.isDoubleSided = false
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        // The plane is authored in XY; -π/2 about X lays it down with its own +Y running into
        // the screen, so offsetting by half its depth puts its near edge at the pane.
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0, -Float(near + depth / 2))
        return node
    }

    // MARK: - The cross-section

    /// The bed in section, standing against the front pane.
    ///
    /// This is the detail that says "aquarium" faster than anything else in the tank: in a
    /// photograph of a real one, the bottom of the frame is not the *top* of the gravel but a
    /// band of it cut open where it meets the glass. `Tank.glassDepth` explains why it needs the
    /// viewer to stand back from the pane; this is what fills the gap that leaves.
    ///
    /// Its own geometry rather than a textured plane, for the crest. A dead-straight top edge
    /// reads as a printed strip laid across the frame — the one thing a bed of loose stones
    /// never has — and the crest can only ever rise, never dip. A dip would expose the water
    /// behind it, because every part of the surface that is drawn at all projects *above* this
    /// line; a rise is just gravel heaped against the pane, which is what it is.
    private static func section(_ substrate: Substrate, tank: Tank,
                                glassDepth: Float) -> SCNNode {
        let maps = SubstrateTexture.maps(substrate, face: .crossSection)
        let width = CGFloat(2.5 * tank.halfWidth(atDepth: glassDepth))
        let height: CGFloat = CGFloat(sectionHeight(tank: tank, glassDepth: glassDepth))
        // About one stone. Enough that the top edge is loose gravel rather than a ruled line,
        // and no more — the crest eats the band it sits on top of, and at twice this it cost a
        // fifth of the band's height and started to read as a scalloped border.
        let crestCeiling: CGFloat = substrate.tileSize * 0.025
        let crest: CGFloat = min(height * 0.1, crestCeiling)

        let geometry = strip(width: width, height: height, crest: crest)
        let material = geometry.firstMaterial ?? SCNMaterial()
        apply(maps, to: material, tiles: (width / substrate.tileSize,
                                         height / substrate.tileSize))
        // Stones against wet glass are the glossiest surface in the tank's lower half, and the
        // small amount of specular this buys is most of what stops the band reading as a matte
        // painted skirting board.
        material.roughness.contents = substrate.roughness * 0.78
        material.isDoubleSided = false
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        // Leaned back a little. A bed does slump where it meets the glass, and — the reason it
        // is worth doing — this look's key is within twelve degrees of vertical, so a truly
        // vertical face would take almost none of it and the band would go to a black bar.
        node.eulerAngles = SCNVector3(sectionLean, 0, 0)
        node.position = SCNVector3(0, 0, -glassDepth)
        return node
    }

    /// Enough to lift the face out of the key's shadow without turning the cut into a ramp. A
    /// bed does slump where it meets the glass, so some of this is real; past about twenty
    /// degrees it stops reading as a section through gravel and starts reading as a bank of it.
    private static let sectionLean: Float = 16 * .pi / 180

    /// How far down the band has to reach.
    ///
    /// It has to clear the bottom of the frame, and where that is depends on the drawable's
    /// shape: a *narrower* drawable has a taller frustum and needs more of it. The height is
    /// therefore sized for a drawable far taller than any this will meet, because the
    /// alternative is rebuilding this geometry on every reshape — and everything below the
    /// frame is outside the frustum and costs nothing to carry.
    private static func sectionHeight(tank: Tank, glassDepth: Float) -> Float {
        let drop = (glassDepth - tank.floorEntryDepth) * tank.halfFOVTangent
        return drop / 0.55 / cos(sectionLean)
    }

    /// A quad with a lumpy top edge, authored with its top at y = 0 so the node's own rotation
    /// leans it about that edge rather than about its middle.
    private static func strip(width: CGFloat, height: CGFloat, crest: CGFloat) -> SCNGeometry {
        var rand = Rand(seed: 0x6C_3E_A1)
        // Enough columns that the crest is a lumpy edge rather than a scalloped one. Only about
        // a quarter of the width is ever on screen, so this is finer than it looks.
        let columns = 160
        // Incommensurable wavelengths, so the crest does not repeat across the visible width
        // and give the strip away as a waveform.
        let waves = (0..<4).map { index in
            (frequency: Float(2.3 + 3.1 * Float(index) + rand.inRange(0, 1.7)),
             phase: rand.inRange(0, 2 * .pi),
             amplitude: rand.inRange(0.35, 1.0) / Float(index + 1))
        }
        let total = waves.reduce(Float(0)) { $0 + $1.amplitude }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [Int32] = []
        for column in 0...columns {
            let along = Float(column) / Float(columns)
            var wave: Float = 0
            for entry in waves {
                wave += entry.amplitude * sin(entry.frequency * along * 2 * .pi + entry.phase)
            }
            // Mapped to [0, 1] and never below it, plus a little per-column noise so the edge
            // is grainy rather than smooth. Only up: see the note on `section`.
            let lift = min(max((wave / total + 1) * 0.5, 0), 1)
                * (1 - 0.35 * rand.next())
            let x = Float(width) * (along - 0.5)
            let top = Float(crest) * lift
            vertices.append(SCNVector3(x, top, 0))
            vertices.append(SCNVector3(x, -Float(height), 0))
            normals.append(SCNVector3(0, 0, 1))
            normals.append(SCNVector3(0, 0, 1))
            // v runs 0 at the nominal top to 1 at the bottom, so once the material's tiling is
            // applied the stones are anchored to the bed rather than stretched by the crest.
            uvs.append(CGPoint(x: CGFloat(along), y: CGFloat(-top / Float(height))))
            uvs.append(CGPoint(x: CGFloat(along), y: 1))
            if column < columns {
                let base = Int32(column * 2)
                indices += [base, base + 1, base + 2, base + 2, base + 1, base + 3]
            }
        }

        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                     SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)],
                           elements: [SCNGeometryElement(indices: indices,
                                                         primitiveType: .triangles)])
    }

    // MARK: - Materials

    /// Wires a generated surface onto a material, tiled so its stones come out the size the
    /// substrate says they are whatever the geometry's own extent happens to be.
    private static func apply(_ maps: SubstrateTexture.Maps, to material: SCNMaterial,
                              tiles: (across: CGFloat, along: CGFloat)) {
        let transform = SCNMatrix4MakeScale(tiles.across, tiles.along, 1)
        material.lightingModel = .physicallyBased
        tile(material.diffuse, with: maps.diffuse, transform: transform)
        if let normal = maps.normal { tile(material.normal, with: normal, transform: transform) }
        material.metalness.contents = 0.0
    }

    /// The floor is seen almost edge-on, so its texture is compressed to a fraction of its
    /// height on screen while keeping its full width. Isotropic mip selection has to pick one
    /// level for both axes and picks the blurrier one, which erased the near gravel completely:
    /// the stones the tile went to such lengths to draw arrived as horizontal smears. This is
    /// the single line that decides whether any of that work is visible.
    private static func tile(_ property: SCNMaterialProperty, with contents: NSImage,
                             transform: SCNMatrix4) {
        property.contents = contents
        property.wrapS = .repeat
        property.wrapT = .repeat
        property.mipFilter = .linear
        property.maxAnisotropy = 16
        property.contentsTransform = transform
    }
}
