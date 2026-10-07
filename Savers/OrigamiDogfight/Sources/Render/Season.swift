// What a season does to the paper: the landscape's colours band by band, and the scenery's by
// material name — autumn's woods turned orange and red, winter's snow on everything that faces
// the sky.
//
// The fight is the subject in every season. So no palette here goes to the extremes its season
// suggests: winter's ground is a shaded off-white rather than paper white, which would swallow a
// white plane and its shadow alike, and autumn keeps some green in its fields so a yellow or an
// orange team never flies over its own colour everywhere.

import AppKit
import Foundation
import SceneKit
import simd

struct SeasonPalette {
    let water: PaperColor
    let shallows: PaperColor
    let shore: PaperColor
    let meadows: [PaperColor]
    let hills: [PaperColor]
    let rocks: [PaperColor]
    let snow: PaperColor
    /// How much each channel darkens on a face turned from the sun, relative to grey. Neutral is
    /// (1, 1, 1); winter's shade loses red faster than blue, so snow in shadow goes blue-grey the
    /// way real snow does, rather than dirty.
    let foldDark: SIMD3<Float>

    static func of(_ season: Season) -> SeasonPalette {
        switch season {
        case .summer: return summer
        case .autumn: return autumn
        case .winter: return winter
        }
    }

    /// v1 and v2's landscape, unchanged: a patchwork of greens and the odd ripe field, so the
    /// low ground reads as folded farmland rather than one green sheet.
    private static let summer = SeasonPalette(
        water: PaperColor(0.40, 0.66, 0.84), shallows: PaperColor(0.52, 0.74, 0.87),
        shore: PaperColor(0.88, 0.78, 0.58),
        meadows: [PaperColor(0.56, 0.76, 0.40), PaperColor(0.46, 0.69, 0.35), PaperColor(0.64, 0.80, 0.44),
                  PaperColor(0.40, 0.62, 0.33), PaperColor(0.80, 0.78, 0.44)],
        // A deeper green than the meadows rather than an olive: the hills cover a third of some
        // landscapes, and olive there read as a drab brown mass behind the fight.
        hills: [PaperColor(0.45, 0.61, 0.34), PaperColor(0.41, 0.57, 0.32)],
        rocks: [PaperColor(0.62, 0.57, 0.50), PaperColor(0.53, 0.49, 0.44)],
        // Off-white, so the sunlit face of a cap is the only one that reaches white and the
        // others show the fold. At white the whole cap clipped to one blank sheet.
        snow: PaperColor(0.84, 0.85, 0.86),
        foldDark: SIMD3(1, 1, 1))

    /// Stubble, gold and russet fields with two faded greens kept among them, and hills of
    /// bracken. The woods carry the season's colour; the ground only agrees with it.
    private static let autumn = SeasonPalette(
        water: PaperColor(0.38, 0.60, 0.78), shallows: PaperColor(0.50, 0.69, 0.82),
        shore: PaperColor(0.86, 0.76, 0.56),
        meadows: [PaperColor(0.60, 0.68, 0.37), PaperColor(0.77, 0.69, 0.38), PaperColor(0.52, 0.62, 0.33),
                  PaperColor(0.72, 0.57, 0.32), PaperColor(0.84, 0.75, 0.45)],
        // Ochre rather than brown: under the folds' shading a brown hillside went to mud.
        hills: [PaperColor(0.74, 0.61, 0.36), PaperColor(0.68, 0.56, 0.33)],
        rocks: [PaperColor(0.60, 0.55, 0.49), PaperColor(0.51, 0.47, 0.43)],
        snow: PaperColor(0.84, 0.85, 0.86),
        foldDark: SIMD3(1, 1, 1))

    /// Snow over everything but the rock, a little cooler and darker on the hills so relief
    /// still reads, and lakes of pale ice. The fields keep the faintest difference from one
    /// another — snow lies on a field's own folds.
    private static let winter = SeasonPalette(
        water: PaperColor(0.70, 0.81, 0.89), shallows: PaperColor(0.78, 0.86, 0.91),
        shore: PaperColor(0.86, 0.86, 0.85),
        meadows: [PaperColor(0.88, 0.89, 0.91), PaperColor(0.86, 0.87, 0.90), PaperColor(0.90, 0.90, 0.92),
                  PaperColor(0.85, 0.87, 0.90), PaperColor(0.89, 0.89, 0.89)],
        hills: [PaperColor(0.82, 0.85, 0.89), PaperColor(0.79, 0.82, 0.88)],
        rocks: [PaperColor(0.55, 0.54, 0.54), PaperColor(0.47, 0.47, 0.49)],
        snow: PaperColor(0.93, 0.94, 0.96),
        foldDark: SIMD3(1.25, 1.05, 0.62))
}

/// The scenery's colours for a season, applied by material name to whatever models stand on the
/// landscape — the flattened woods and hamlets and every prop drawn on its own — so a model
/// built tomorrow takes the season by being named like the ones built today.
///
/// Done in a shader rather than by repainting materials, for two things a repaint cannot do. A
/// whole wood shares one leaf material, so a repaint turns every tree the same orange; a tint
/// drawn from where each facet stands in the world turns a wood from orange to red across its
/// width. And snow lies on what faces the sky: the up-facing folds of a roof, a pine's boughs and
/// a rock's top go white while their sides keep their colour, which is what makes a snowy
/// village read as a village rather than as white boxes.
enum SeasonDress {
    private struct Look {
        /// Two colours a facet's tint is drawn between, by a slow noise over the ground.
        let tint: (PaperColor, PaperColor)?
        /// How fully snow covers an up-facing facet, and from how steep up it starts.
        let snow: Float
        let snowFrom: Float
        /// A bare crown's lace: a web of twigs drawn over it, and snow caught in the twigs as a
        /// fine dusting rather than lying in a sheet — 0 for everything else.
        var lace: Float = 0
    }

    static func dress(_ root: SCNNode, season: Season) {
        guard season != .summer else { return }
        for material in materials(under: root) { dress(material, season: season) }
    }

    /// One material, by its name. Idempotent, so a material met again is no harm.
    static func dress(_ material: SCNMaterial, season: Season) {
        guard let look = look(for: material.name ?? "", season: season) else { return }
        apply(look, to: material)
    }

    /// Every material on `root` and below it, once each. `enumerateHierarchy` does not visit
    /// the node it is called on, and the flattened scenery's geometry is on exactly that node.
    static func materials(under root: SCNNode) -> [SCNMaterial] {
        var seen = Set<ObjectIdentifier>()
        var found: [SCNMaterial] = []
        func take(_ node: SCNNode) {
            for material in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(material)).inserted {
                found.append(material)
            }
        }
        take(root)
        root.enumerateHierarchy { node, _ in take(node) }
        return found
    }

    private static func look(for name: String, season: Season) -> Look? {
        let leaf = name.contains("leaf")
        switch season {
        case .summer:
            return nil
        case .autumn:
            guard leaf else { return nil }
            // Pines keep their needles: a dark green among the orange is what makes the
            // orange read as a season rather than as a palette.
            if name.contains("pine") { return nil }
            if name.contains("poplar") {
                return Look(tint: (PaperColor(0.96, 0.77, 0.20), PaperColor(0.92, 0.55, 0.14)), snow: 0, snowFrom: 1)
            }
            if name.contains("bush") {
                return Look(tint: (PaperColor(0.74, 0.20, 0.14), PaperColor(0.86, 0.38, 0.12)), snow: 0, snowFrom: 1)
            }
            return Look(tint: (PaperColor(0.93, 0.50, 0.14), PaperColor(0.80, 0.24, 0.12)), snow: 0, snowFrom: 1)
        case .winter:
            // Lit windows and doors are vertical and never take snow, and a window that took a
            // tint would lose its glow at dusk.
            if name.contains("window") || name.contains("door") { return nil }
            // A sheep wears no snow, and its fleece is the cream real sheep turn against a
            // snowfield: in the white it was folded in, under winter's snow rule, a flock all but
            // vanished into the field it stood in.
            if name.contains("wool") {
                return Look(tint: (PaperColor(0.86, 0.80, 0.66), PaperColor(0.82, 0.76, 0.62)), snow: 0, snowFrom: 1)
            }
            if name.contains("sheep") { return nil }
            if leaf && name.contains("pine") {
                // Dark needles under snow: the darkest thing on a white landscape, which is
                // what a winter wood looks like from above.
                return Look(tint: (PaperColor(0.16, 0.33, 0.24), PaperColor(0.21, 0.38, 0.27)), snow: 0.85, snowFrom: 0.72)
            }
            if leaf {
                // Bare crowns under snow. A crown is a round folded blob from above, so its
                // surface is all that can say "tree": a plain dark brown crown read as a boulder
                // lying on the snow, one with whole facets white as a cut gem, and one mottled all
                // over as granite. So snow lies on the crown's upper side and thins softly down its
                // flanks into a violet-brown underside laced with darker twigs — a snow-laden tree,
                // whose shadow falls clear of it the way a rock's never does. Poplars keep a paler,
                // warmer twig and bushes the red of winter stems, so a wood still has more than
                // one kind of tree in it.
                let twigs: (PaperColor, PaperColor)
                if name.contains("poplar") {
                    twigs = (PaperColor(0.55, 0.47, 0.38), PaperColor(0.49, 0.42, 0.35))
                } else if name.contains("bush") {
                    twigs = (PaperColor(0.52, 0.30, 0.28), PaperColor(0.45, 0.26, 0.25))
                } else {
                    twigs = (PaperColor(0.45, 0.37, 0.38), PaperColor(0.38, 0.31, 0.33))
                }
                return Look(tint: twigs, snow: 0.92, snowFrom: 0.25, lace: 1)
            }
            if name.contains("roof") { return Look(tint: nil, snow: 0.95, snowFrom: 0.42) }
            return Look(tint: nil, snow: 0.9, snowFrom: 0.7)
        }
    }

    private static func apply(_ look: Look, to material: SCNMaterial) {
        func linear(_ c: PaperColor) -> SCNVector3 {
            let v = linearRGBA(c)
            return SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z))
        }
        material.shaderModifiers = [.surface: surface]
        let tint = look.tint ?? (PaperColor(1, 1, 1), PaperColor(1, 1, 1))
        material.setValue(NSValue(scnVector3: linear(tint.0)), forKey: "tintA")
        material.setValue(NSValue(scnVector3: linear(tint.1)), forKey: "tintB")
        material.setValue(NSNumber(value: look.tint == nil ? 0 : 1), forKey: "tintMix")
        material.setValue(NSNumber(value: look.snow), forKey: "snowAmount")
        material.setValue(NSNumber(value: look.snowFrom), forKey: "snowFrom")
        material.setValue(NSNumber(value: look.lace), forKey: "lace")
        material.setValue(NSValue(scnVector3: linear(snowColour)), forKey: "snowColour")
    }

    /// The snow on a prop: the winter ground's own white, so a roof's snow and the field's are
    /// one snowfall.
    private static let snowColour = PaperColor(0.94, 0.95, 0.97)

    /// World position and normal from the view-space ones the surface stage is handed. The
    /// noise is a few lines of value noise on a 0.35 m lattice — a wood a metre across gets two
    /// or three colours, a single tree one, give or take the facet that straddles a cell.
    private static let surface = """
    #pragma arguments
    float3 tintA;
    float3 tintB;
    float tintMix;
    float snowAmount;
    float snowFrom;
    float lace;
    float3 snowColour;
    #pragma body
    float4 wp = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float3 wn = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
    float2 q = wp.xz / 0.35;
    float2 i = floor(q);
    float2 f = q - i;
    f = f * f * (3.0 - 2.0 * f);
    float h00 = fract(sin(dot(i, float2(127.1, 311.7))) * 43758.5453);
    float h10 = fract(sin(dot(i + float2(1.0, 0.0), float2(127.1, 311.7))) * 43758.5453);
    float h01 = fract(sin(dot(i + float2(0.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
    float h11 = fract(sin(dot(i + float2(1.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
    float n = mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
    float3 tinted = mix(tintA, tintB, n);
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, tinted, tintMix);
    // A bare crown's snow thins over a wide band of slope, so it shades round the crown rather
    // than stopping at a fold.
    float snow = smoothstep(snowFrom, snowFrom + mix(0.12, 0.45, lace), wn.y) * snowAmount;
    if (lace > 0.0) {
        // Twigs: where a fine noise crosses its middle value it draws a wandering line, and
        // its lines together a web, seen where the snow thins. Snow: a second noise as fine,
        // which breaks the snow's lower edge into flecks caught in the twigs, so it never
        // follows a facet's edge.
        float2 tq = wp.xz / 0.006;
        float2 ti = floor(tq);
        float2 tf = tq - ti;
        tf = tf * tf * (3.0 - 2.0 * tf);
        float t00 = fract(sin(dot(ti, float2(269.5, 183.3))) * 43758.5453);
        float t10 = fract(sin(dot(ti + float2(1.0, 0.0), float2(269.5, 183.3))) * 43758.5453);
        float t01 = fract(sin(dot(ti + float2(0.0, 1.0), float2(269.5, 183.3))) * 43758.5453);
        float t11 = fract(sin(dot(ti + float2(1.0, 1.0), float2(269.5, 183.3))) * 43758.5453);
        float tn = mix(mix(t00, t10, tf.x), mix(t01, t11, tf.x), tf.y);
        float twig = 1.0 - smoothstep(0.03, 0.09, abs(tn - 0.5));
        _surface.diffuse.rgb *= mix(1.0, 0.6, twig * lace * (1.0 - snow));
        float2 sq = wp.xz / 0.006 + float2(17.0, 31.0);
        float2 si = floor(sq);
        float2 sf = sq - si;
        sf = sf * sf * (3.0 - 2.0 * sf);
        float s00 = fract(sin(dot(si, float2(127.1, 311.7))) * 43758.5453);
        float s10 = fract(sin(dot(si + float2(1.0, 0.0), float2(127.1, 311.7))) * 43758.5453);
        float s01 = fract(sin(dot(si + float2(0.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
        float s11 = fract(sin(dot(si + float2(1.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
        float sn = mix(mix(s00, s10, sf.x), mix(s01, s11, sf.x), sf.y);
        snow = mix(snow, snow * smoothstep(0.2, 0.6, sn + snow * 0.5), lace);
    }
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, snowColour, snow);
    """
}
