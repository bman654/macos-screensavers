// Light thrown on the land by things that burn or shine: a wreck's fire, a burning tree, a
// crash's flash, a car's headlamps, a lit house or hangar. Each frame the fight lists them here,
// and the ground, the roads, the runways and the UV-mapped models light themselves from the list.
//
// Not SceneKit lights. Fifteen fires and a dozen headlamp beams would be thirty forward lights on
// every lit fragment in the scene, planes included, and a forward light's cost is paid by every
// material whether it is near the light or not. Not a pool of colour blended over the ground
// either, which is what the house lamps once were: a pool *replaces* the ground's colour, where
// light *multiplies* it — firelight on a dark meadow should show a lit meadow, its folds and its grass,
// not an orange disc. So the list is written into a tiny float texture once a frame, and a
// fragment shader modifier on each enlisted material adds `albedo × light` for every entry —
// a few dozen arithmetic operations per fragment, and nothing at all while the list is empty,
// which by day it nearly always is.
//
// The texture is one row: texel 0 holds the count and the lamps' strength, texel 1 where the
// houses' lamp map lies on the ground; each light then takes three texels —
//   position (scene metres) and radius; colour × strength (linear) and 0;
//   for a beam, its direction across the ground (scene x, z) and the cosines of its outer and
//   inner half-angles; for a point light, zeros.
// Written in place, so a frame the GPU is still reading may see the next one's flicker — the
// only thing that can tear is a flame's brightness for one frame.
//
// The houses' lamplight is a second texture, a map of the ground drawn once (`Lamplight`).

import Foundation
import Metal
import SceneKit
import simd

final class GroundLights {
    /// More than a crowded fight ever lights at once: the most fires found burning together over
    /// sixty seeds was twelve, beside up to four hangars, a few cars' beams and a flash or two.
    static let capacity = 40
    private static let header = 2
    private static let width = header + capacity * 3

    private let texture: MTLTexture?
    private let property: SCNMaterialProperty?
    private let device: MTLDevice?
    /// The houses' lamplight, drawn once; a blank texel until it is.
    private let lampProperty: SCNMaterialProperty?
    private var texels: [SIMD4<Float>]
    private var lights: [(a: SIMD4<Float>, b: SIMD4<Float>, c: SIMD4<Float>, weight: Float)] = []
    /// Weakly: hangars' materials come and go with the matches, and an identity kept past its
    /// object's life would pass over a new material that happened to reuse its address.
    private let enlisted = NSHashTable<SCNMaterial>.weakObjects()
    private var written = 0

    /// How strongly fire shows on the ground at this hour, 0 to 1: a faint warmth on the grass
    /// at midday, a pool of light at night. Set by `DayLight`.
    var fireStrength: Float = 0.15
    /// Headlamps, which are only switched on toward evening (`DayLight`'s lamps).
    var headlampStrength: Float = 0
    /// Lamplight in the houses and hangars, the same knob (`Lamplight.glow`).
    var lampStrength: Float = 0
    /// How far the world has gone to moonlight, 0 to 1: its lit colour drained toward a cool
    /// blue, as colour goes from the eye at night, before any lamp or fire is added and leaving
    /// any glow alone — both keep their colour. Without it a moonlit meadow was a dim green
    /// field, not a night. A uniform on each graded material, not a texel, so it reaches the
    /// flat-coloured props that cannot read the light list (`enlist(under:)`).
    var moonlight: Float = 0 {
        didSet {
            guard abs(moonlight - gradedAt) > 0.002 || (moonlight == 0) != (gradedAt == 0) else { return }
            gradedAt = moonlight
            for case let material as SCNMaterial in graded.keyEnumerator() {
                let weight = graded.object(forKey: material)?.floatValue ?? 1
                material.setValue(NSNumber(value: moonlight * weight), forKey: "moonGrade")
            }
        }
    }
    private var gradedAt: Float = 0
    /// Every graded material, weakly, with how much of the moonlight it takes.
    private let graded = NSMapTable<SCNMaterial, NSNumber>.weakToStrongObjects()

    /// Lamplight, linear: a warm, slightly orange white, gentler than a fire.
    static let lampColour = SIMD3<Float>(1.0, 0.58, 0.26) * 1.0

    /// Brief flashes — a crash, a plane blown apart — still fading, in frame time.
    private var flashes: [(position: SIMD3<Float>, radius: Float, born: Double, life: Double, strength: Float)] = []

    init(device: MTLDevice?) {
        texels = Array(repeating: .zero, count: GroundLights.width)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: GroundLights.width,
                                                                  height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        texture = device?.makeTexture(descriptor: descriptor)
        property = texture.map { SCNMaterialProperty(contents: $0) }
        self.device = device
        lampProperty = GroundLights.mapTexture(device: device, values: [0], size: 1).map { SCNMaterialProperty(contents: $0) }
        upload()
    }

    /// The houses' lamplight as a `size`-square map of the ground, `origin` its corner and `span`
    /// its extent in sim metres; 1 is a full lamp's light. Read with linear filtering, so the
    /// map can be coarse — a house's pool is a dozen texels across.
    func lampMap(_ values: [Float], size: Int, origin: SIMD2<Float>, span: SIMD2<Float>) {
        guard let texture = GroundLights.mapTexture(device: device, values: values, size: size) else { return }
        lampProperty?.contents = texture
        mapRect = SIMD4(origin.x, origin.y, 1 / span.x, 1 / span.y)
    }

    private var mapRect = SIMD4<Float>(0, 0, 0, 0)

    private static func mapTexture(device: MTLDevice?, values: [Float], size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard values.count == size * size, let texture = device?.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: base,
                            bytesPerRow: size * MemoryLayout<Float>.stride)
        }
        return texture
    }

    /// Lights `material` from the list from now on. Idempotent; a material without a texture to
    /// read (no device) is left exactly as it was.
    func enlist(_ material: SCNMaterial) {
        guard let property, !enlisted.contains(material) else { return }
        enlisted.add(material)
        // A lit material only: a constant one is a glow or a card, and light on it is meaningless.
        guard material.lightingModel != .constant else { return }
        var modifiers = material.shaderModifiers ?? [:]
        modifiers[.fragment] = GroundLights.fragment
        material.shaderModifiers = modifiers
        material.setValue(property, forKey: "groundLights")
        material.setValue(lampProperty, forKey: "lampMap")
        register(material, weight: 1)
    }

    /// Grades `material` with the moonlight, taking `weight` of it, without lighting it from the
    /// list. A material already lit keeps its fuller modifier, which grades too.
    func grade(_ material: SCNMaterial, weight: Float) {
        guard material.lightingModel != .constant, graded.object(forKey: material) == nil else { return }
        if !enlisted.contains(material) || material.shaderModifiers?[.fragment] == nil {
            var modifiers = material.shaderModifiers ?? [:]
            modifiers[.fragment] = GroundLights.moonOnly
            material.shaderModifiers = modifiers
        }
        register(material, weight: weight)
    }

    private func register(_ material: SCNMaterial, weight: Float) {
        graded.setObject(NSNumber(value: weight), forKey: material)
        material.setValue(NSNumber(value: moonlight * weight), forKey: "moonGrade")
    }

    /// Every material under `root`, the root's own included, that only ever dresses geometry
    /// with texture coordinates. SceneKit binds a shader modifier's texture argument as it binds
    /// a material's own textures, through a UV channel, and a mesh without one fails to build a
    /// pipeline at all — measured: the flat-coloured trees, houses and sheep vanished, their
    /// shadows still drawn. So the light falls on the ground, the roads, the runways and the
    /// UV-mapped models (hangars, cars), and the flat-coloured props stand dark in it.
    func enlist(under root: SCNNode) {
        var mapped: [SCNMaterial] = []
        var unmapped = Set<ObjectIdentifier>()
        func visit(_ node: SCNNode) {
            guard let geometry = node.geometry else { return }
            if geometry.sources(for: .texcoord).isEmpty {
                for material in geometry.materials { unmapped.insert(ObjectIdentifier(material)) }
            } else {
                mapped.append(contentsOf: geometry.materials)
            }
        }
        visit(root)
        root.enumerateHierarchy { node, _ in visit(node) }
        for material in mapped where !unmapped.contains(ObjectIdentifier(material)) { enlist(material) }
        for material in SeasonDress.materials(under: root) where unmapped.contains(ObjectIdentifier(material)) {
            grade(material, weight: 1)
        }
    }

    // MARK: The frame's list

    func begin() { lights.removeAll(keepingCapacity: true) }

    /// A fire's glow, `colour` linear and already at its flickered strength, from `position`
    /// (scene axes) out to `radius`.
    func fire(at position: SIMD3<Float>, radius: Float, colour: SIMD3<Float>) {
        add(position: position, radius: radius, colour: colour * fireStrength, beam: .zero)
    }

    /// A headlamp beam from `position` along `direction` (scene x, z), `reach` metres long.
    func beam(from position: SIMD3<Float>, direction: SIMD2<Float>, reach: Float, colour: SIMD3<Float>) {
        guard headlampStrength > 0.001 else { return }
        // About 11° either side at full strength, softening out to 20°.
        add(position: position, radius: reach, colour: colour * headlampStrength,
            beam: SIMD4(direction.x, direction.y, cos(0.35), cos(0.19)))
    }

    /// A lamp's light — a hangar's — from `position`, at `strength` of a full lamp.
    func lamp(at position: SIMD3<Float>, radius: Float, strength: Float) {
        add(position: position, radius: radius, colour: GroundLights.lampColour * strength, beam: .zero)
    }

    /// A flash where something blew up, fading over `life` seconds of frame time. Brightest at
    /// night, when it is the brightest thing on the ground, and a faint warmth by day.
    func flash(at position: SIMD3<Float>, radius: Float, time: Double, life: Double = 0.7, strength: Float = 1) {
        flashes.append((position, radius, time, life, strength))
    }

    /// Writes the frame's list for the GPU.
    func commit(time: Double) {
        flashes.removeAll { time - $0.born > $0.life || time < $0.born - 1 }
        for f in flashes {
            let t = Float((time - f.born) / f.life)
            let fade = (1 - t) * (1 - t)
            add(position: f.position, radius: f.radius * (0.7 + 0.3 * t),
                colour: SIMD3(1.0, 0.62, 0.30) * (2.6 * fade * f.strength * max(fireStrength, 0.12)), beam: .zero)
        }
        if lights.count > GroundLights.capacity {
            lights.sort { $0.weight > $1.weight }
            lights.removeLast(lights.count - GroundLights.capacity)
        }
        let count = lights.count
        texels[0] = SIMD4(Float(count), lampStrength > 0.005 ? lampStrength : 0, 0, 0)
        texels[1] = mapRect
        for (i, light) in lights.enumerated() {
            texels[GroundLights.header + i * 3] = light.a
            texels[GroundLights.header + 1 + i * 3] = light.b
            texels[GroundLights.header + 2 + i * 3] = light.c
        }
        // Only what changed since the last upload: by day, an empty list is just the header.
        let span = GroundLights.header + max(count, written) * 3
        written = count
        upload(texels: span)
    }

    private func add(position: SIMD3<Float>, radius: Float, colour: SIMD3<Float>, beam: SIMD4<Float>) {
        let weight = max(colour.x, colour.y, colour.z) * radius
        guard weight > 1e-4 else { return }
        lights.append((SIMD4(position, radius), SIMD4(colour, 0), beam, weight))
    }

    private func upload(texels span: Int = GroundLights.width) {
        guard let texture else { return }
        texels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, span, 1), mipmapLevel: 0, withBytes: base,
                            bytesPerRow: GroundLights.width * MemoryLayout<SIMD4<Float>>.stride)
        }
    }

    /// World position and normal from the view-space ones the fragment is handed, as
    /// `SeasonDress` does. Each light's falloff is a smooth (1 - d²/r²)², gone at its radius, and
    /// its angle to the surface only half matters — a fire is low, so pure Lambert would light a
    /// level field barely a step from the flames, and the folds still show by the half that is
    /// kept. A beam is cut to its cone across the ground and does not light the car under it.
    private static let fragment = fragmentSource
        .replacingOccurrences(of: "MOONLIGHT", with: moonlightSource)
        .replacingOccurrences(of: "LAMP_R", with: String(lampColour.x))
        .replacingOccurrences(of: "LAMP_G", with: String(lampColour.y))
        .replacingOccurrences(of: "LAMP_B", with: String(lampColour.z))

    private static let moonOnly = """
    #pragma arguments
    float moonGrade;
    #pragma body

    """ + moonlightSource

    /// What the light leaves of a colour by moonlight: its luminance, tinted a cool blue. Taken
    /// from the lit colour only — emission is set aside and put back — so luminous paint, a lit
    /// window and the shots' glow keep their colour in the dark.
    private static let moonlightSource = """
    if (moonGrade > 0.0) {
        float3 moonLit = _output.color.rgb - _surface.emission.rgb;
        float moonY = dot(moonLit, float3(0.2126, 0.7152, 0.0722));
        _output.color.rgb = mix(moonLit, moonY * float3(0.62, 0.86, 1.55), moonGrade) + _surface.emission.rgb;
    }
    """

    private static let fragmentSource = """
    #pragma arguments
    float moonGrade;
    texture2d<float> groundLights;
    texture2d<float> lampMap;
    #pragma body
    MOONLIGHT
    float4 groundHead = groundLights.read(uint2(0, 0));
    int groundCount = int(groundHead.x);
    if (groundCount > 0 || groundHead.y > 0.0) {
        float3 gp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
        float3 gn = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
        float3 glow = float3(0.0);
        if (groundHead.y > 0.0) {
            // The map is in sim axes: x east, y north, which is scene -z.
            float4 rect = groundLights.read(uint2(1, 0));
            constexpr sampler lampSampler(filter::linear, address::clamp_to_zero);
            float2 uv = (float2(gp.x, -gp.z) - rect.xy) * rect.zw;
            glow += float3(LAMP_R, LAMP_G, LAMP_B) * (groundHead.y * lampMap.sample(lampSampler, uv).r);
        }
        for (int i = 0; i < groundCount; i++) {
            float4 a = groundLights.read(uint2(2 + i * 3, 0));
            float3 d = a.xyz - gp;
            float d2 = dot(d, d);
            float r = 1.0 - min(d2 / (a.w * a.w), 1.0);
            if (r <= 0.0) { continue; }
            float4 b = groundLights.read(uint2(3 + i * 3, 0));
            float4 c = groundLights.read(uint2(4 + i * 3, 0));
            float dist = sqrt(d2);
            float facing = 0.45 + 0.55 * saturate(dot(gn, d / max(dist, 1e-4)));
            float cone = 1.0;
            if (c.z > 0.0) {
                float2 h = gp.xz - a.xz;
                float hl = length(h);
                cone = smoothstep(c.z, c.w, dot(h / max(hl, 1e-4), c.xy)) * smoothstep(0.004, 0.03, hl);
            }
            glow += b.rgb * (r * r * facing * cone);
        }
        // Lit through a paler albedo than the paper's own: firelight multiplied by a saturated
        // meadow green came out lime, and the eye reads light by its colour, not the grass's.
        float3 lightAlbedo = mix(_surface.diffuse.rgb,
                                 float3(dot(_surface.diffuse.rgb, float3(0.2126, 0.7152, 0.0722))), 0.45);
        _output.color.rgb += lightAlbedo * glow;
    }
    """
}
