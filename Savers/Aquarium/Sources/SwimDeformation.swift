// The fish's vertex deformation, which is Metal rather than Swift and lives here rather than in
// `School` for that reason: the school decides what the animal is doing, this decides what its
// vertices do about it, and the two are edited for different reasons.
//
// **A material has exactly one `.geometry` modifier string.** Every deformation a fish needs is
// therefore composed into this one source; a second effect cannot be installed as a second
// modifier. `School` supplies the uniforms.

import Foundation

/// How the body is deformed, in the vertex stage. Three terms keyed on `tailward` and the part
/// channel, and for a lurker a spine that the whole result is then laid along.
///
/// Proven in `spikes/001-fish-pipeline`. It works in the mesh's own object space, which is
/// only valid because the fish is exported as a single joined mesh — reaching for world
/// space via `u_modelTransform` inside a geometry modifier produces shredded geometry and a
/// magenta surface, with no diagnostic. The `tailward²` envelope holds the head steady; a
/// fish that translates bodily side to side reads as a bar of soap.
///
/// **The axes are the mesh's, which is Blender's and not the tank's.** Nose is +X, up is +Z and
/// +Y is the fish's left; the pivot's -90° about X is what turns that into the tank's Y-up (see
/// `makeFish`). So the lateral axis the swim wave has always used is `y`.
///
/// **The terms compose, they do not replace each other.** Each is a displacement of the same
/// undeformed vertex, added:
///
/// - **the body wave** — a travelling sine down the body, which is the swimming itself;
/// - **the pectoral beat** — the two flank fins hinging about their roots. It is zero for every
///   vertex that is not one of those fins, which is what the part channel decides.
///
/// **The spine, for a lurker only.** `spineOn` is written once, at construction, and is 1 for
/// a lurker and 0 for everything else, so for every other species this whole branch is the dead
/// code it was built as. When it is on, the vertex is not displaced from its rest position but
/// *placed*: `SpineTrail` supplies sixteen points along the path the head has taken, in
/// this mesh's own space with the head at the nose, and the vertex goes to the point at its own
/// distance behind the nose plus its lateral offsets carried in the path's local frame — the
/// tangent, the left that is perpendicular to it and to the mesh's up, and the up that
/// completes them. The cross-section therefore stays normal to the curve however hard it
/// bends, which the old constant-curvature arc could not do past about a right angle, and the
/// normal is carried through the same frame so the lighting bends with the body. The wave and
/// the pectoral beat compose on top, in that frame.
///
/// **Sixteen samples arrive as three `float4x4`s, three floats to a sample.** Measured on this
/// machine, all of it: a SceneKit shader modifier will not compile an array argument in any form
/// (`float vals[4]`, `float3`, `float4`, via `NSData`), nor a helper function declared between
/// the pragmas — both go magenta silently. A `float4x4` set from `NSValue(scnMatrix4:)` does
/// bind, its columns are `mat[i]`, and a column and a component may both be indexed
/// dynamically. **And the block of custom arguments has a size limit, silently enforced:** with
/// eleven floats and eight matrices (556 bytes) declared, some materials — the eel among them,
/// deterministically, and two more with a diagnostic argument added — receive *zeros* for every
/// custom vertex-stage argument, while the fragment stage still sees the right values; and with
/// six matrices declared and read, every argument **past byte 256 of the block reads garbage**
/// (the fourth matrix, at offset 240–303, blew the eel up to fill the screen; three read
/// cleanly). Both measurements and their reproduction recipe are
/// `spikes/010-shader-uniform-block/README.md`.
///
/// So the samples are packed three floats to a sample straight through the matrix columns, three
/// matrices for sixteen samples, and the whole block is **240 bytes — 16 of headroom against the
/// 256-byte cliff**. Eleven floats pad to 48 before the matrices' 16-byte alignment, so a twelfth
/// float is free and the four after it would land the block on exactly 256; the argument that
/// read garbage *straddled* that byte, so 256 is not proved usable and the number to hold under
/// is the block's, not any one argument's. The failure mode is a fish that neither waves nor
/// beats its fins, or a mesh exploded to the horizon, and neither logs a word.
///
/// Sixteen samples are enough because the shader draws a Catmull-Rom spline through them rather
/// than a polygon, and all sixteen are read: `SpineTrail.coverage` is derived so that the tail
/// tip lands on sample `tipSample` and the two behind it are the spline's lookbehind for the
/// final segment. Coverage stated as a round 1.2 instead left the sixteenth sample unreachable —
/// the tip fell at u=12.5 and the deepest read was sample 14 — which is a wasted sixteenth of a
/// block that cannot be made bigger.
///
/// **The part channel is a second UV set, `st1`, authored by `build_fish.py`.** Its U is a part
/// id and its V is the vertex's distance from that part's hinge as a fraction of the model's own
/// length — so `V * bodyLength` is the lever arm in these object units, and `finAmplitude` is a
/// true angle in radians. Vertex colour cannot carry this: SceneKit drops it on macOS 26, and an
/// absent `_geometry.color` reads as *white* rather than zero, which would move the whole fish
/// (`spikes/009-part-channel`).
///
/// `readingPartChannel` is false for a stale asset built before that channel existed, and the
/// fallback is load-bearing rather than defensive. **Measured:** pointing this modifier at a
/// model with only one texcoord source makes every fish in the tank vanish outright — the props
/// and the water render normally and the school is simply not there, with nothing logged. So an
/// absent `texcoords[1]` is not a term that quietly reads zero, and the sample is what varies
/// between the two variants rather than the term that uses it.
func swimModifierSource(readingPartChannel: Bool) -> String {
    // The samples go three floats to a sample straight through the matrices' columns, so the
    // matrices have to be able to hold them. Stated here because the two counts are declared in
    // `SpineTrail` and consumed as generated Metal below: a mismatch would otherwise read off
    // the end of a `float4x4` array with no diagnostic at all.
    precondition(SpineTrail.sampleCount * 3 <= SpineTrail.matrixCount * 16,
                 "\(SpineTrail.sampleCount) spine samples need "
                 + "\(SpineTrail.sampleCount * 3) floats; \(SpineTrail.matrixCount) matrices "
                 + "carry \(SpineTrail.matrixCount * 16)")
    let sample = readingPartChannel
        ? "float2 part = _geometry.texcoords[1];"
        : "float2 part = float2(0.0);   // asset predates the part channel"
    // Generated from `SpineTrail`'s own constants rather than spelled out, because the count of
    // matrices, the count of columns copied out of them and the sample the tail tip lands on are
    // three statements of one number and a silent mismatch between them is a fish of NaNs.
    let spineArguments = (0..<SpineTrail.matrixCount)
        .map { "float4x4 spine\($0);" }.joined(separator: "\n")
    let columnCount = SpineTrail.matrixCount * 4
    let unpackColumns = (0..<columnCount)
        .map { "    col[\($0)] = spine\($0 / 4)[\($0 % 4)];" }.joined(separator: "\n")
    return """
#pragma arguments
float swimPhase;
float swimAmplitude;
float swimWaves;
float bodyMinX;
float bodyLength;
float finPhase;
float finAmplitude;
float spineOn;
float spineSpacing;
float spineY;
float spineZ;
\(spineArguments)

#pragma body
float tailward = clamp((bodyMinX + bodyLength - _geometry.position.x) / bodyLength, 0.0, 1.0);

// The body wave.
float envelope = tailward * tailward;
float wave = sin(tailward * swimWaves * 6.2831853 - swimPhase) * swimAmplitude * envelope;

// The pectoral beat. Each fin is rotated from its rest offset rather than slid along a tangent,
// so the hinge preserves its authored lever arm at every stroke angle.
//
// The ids and the reserved values are `_PECTORAL_IDS` in `build_fish.py`: 0.25 left, 0.35 right,
// with 0 meaning "no part" and 1 reserved for a mesh that reached the join without the channel.
// They are matched with a window rather than by equality, because they arrive as interpolated
// floats.
\(sample)
float pectoralLeft = step(abs(part.x - 0.25), 0.04);
float pectoralRight = step(abs(part.x - 0.35), 0.04);
float reach = part.y * bodyLength;

// `_build_fins` uses out_dir (-0.20, ±0.92, -0.32). Normalizing gives the two `out` constants
// below. Gram-Schmidt orthogonalizing normalized (0.94, 0, 0.34) against each `out`, then
// normalizing again, gives the corresponding `flap` constants. The +Z component is a visible
// 20° row-and-lift stroke rather than a flat fan.
float3 outLeft = float3(-0.201129497,  0.925195685, -0.321807195);
float3 outRight = float3(-0.201129497, -0.925195685, -0.321807195);
float3 flapLeft = float3(0.922399983,  0.289464862, 0.255711488);
float3 flapRight = float3(0.922399983, -0.289464862, 0.255711488);

// The two sides beat in antiphase — one forward while the other is back. In phase they read as
// a single symmetric fan opening and closing; alternating reads as an animal rowing.
float leftAngle = sin(finPhase) * finAmplitude * pectoralLeft;
float rightAngle = -sin(finPhase) * finAmplitude * pectoralRight;
float3 pectoral = reach * (
    pectoralLeft * (sin(leftAngle) * flapLeft + (cos(leftAngle) - 1.0) * outLeft)
    + pectoralRight * (sin(rightAngle) * flapRight + (cos(rightAngle) - 1.0) * outRight)
);

if (spineOn > 0.5) {
    // Sample coordinate: how many spine samples back from the nose this vertex sits. The tail
    // tip lands on `SpineTrail.tipSample` by construction — `coverage` is chosen for it — so the
    // spline below always has two samples behind the segment it is evaluating.
    float u = clamp(tailward * bodyLength / spineSpacing, 0.0, \(Float(SpineTrail.tipSample)));
    int i0 = int(floor(u));
    float f = u - float(i0);
    int ia = max(i0 - 1, 0);
    int ib = i0;
    int ic = i0 + 1;
    int id = i0 + 2;
    // The unpack. Sample i is floats 3i..3i+2 of the run through the matrices' columns, and
    // there is no way to write that as a function here — see the header — so it is spelled out
    // through a local copy of the columns, which the compiler indexes in place.
    float4 col[\(columnCount)];
\(unpackColumns)
    int fa = 3 * ia;
    int fb = 3 * ib;
    int fc = 3 * ic;
    int fd = 3 * id;
    float3 pa = float3(col[fa >> 2][fa & 3], col[(fa + 1) >> 2][(fa + 1) & 3], col[(fa + 2) >> 2][(fa + 2) & 3]);
    float3 pb = float3(col[fb >> 2][fb & 3], col[(fb + 1) >> 2][(fb + 1) & 3], col[(fb + 2) >> 2][(fb + 2) & 3]);
    float3 pc = float3(col[fc >> 2][fc & 3], col[(fc + 1) >> 2][(fc + 1) & 3], col[(fc + 2) >> 2][(fc + 2) & 3]);
    float3 pd = float3(col[fd >> 2][fd & 3], col[(fd + 1) >> 2][(fd + 1) & 3], col[(fd + 2) >> 2][(fd + 2) & 3]);

    // In front of the nose there is no sample, and clamping `ia` to 0 makes `pa == pb`, which
    // halves `c1` — so the first segment of the curve is drawn at half its proper length and
    // the head end of the body is visibly compressed. A phantom point reflected through the
    // nose is the standard endpoint for this, and it costs one subtract.
    if (i0 == 0) { pa = 2.0 * pb - pc; }

    // A Catmull-Rom spline through the four bracketing samples, and its derivative for the
    // tangent — so sixteen samples give a smooth curve rather than a polygon, and the frame
    // turns continuously through a sample instead of snapping at it. `tangent` points from
    // nose to tail; the straight body has it along -x, which puts `left` on +y and `up` on +z,
    // the rest frame.
    float3 c1 = 0.5 * (pc - pa);
    float3 c2 = 0.5 * (2.0 * pa - 5.0 * pb + 4.0 * pc - pd);
    float3 c3 = 0.5 * (-pa + 3.0 * pb - 3.0 * pc + pd);
    float3 spine = pb + (c1 + (c2 + c3 * f) * f) * f;

    // **Every normalize here is guarded, and the blast radius is why.** A NaN in this frame is
    // not a wrong vertex, it is the whole fish: the position and the normal both go through it,
    // and one degenerate step of the trail takes out the animal for as long as it lasts. The
    // derivative is zero whenever the four samples coincide — a trail that has not been seeded,
    // or a head that has not moved for sixteen spacings — and the rest pose's answer is the
    // tailward axis, which in mesh space is -x.
    float3 d = c1 + (2.0 * c2 + 3.0 * c3 * f) * f;
    float dLength = length(d);
    float3 tangent = dLength > 1e-6 ? d / dLength : float3(-1.0, 0.0, 0.0);
    // The up-reference cannot be the tangent. Mesh +z is the fish's own up, so an eel swimming
    // straight up or down the tank has its path along it and the cross product collapses; +y is
    // perpendicular to the tangent in exactly that case. Rotated between the two rather than
    // switched: a hard `abs(tangent.z) > 0.99` is a discontinuity in the frame, and two adjacent
    // cross-sections that land either side of it are drawn a quarter turn apart — a crease in
    // the body wherever the path passes vertical.
    float3 reference = normalize(mix(float3(0.0, 0.0, 1.0), float3(0.0, 1.0, 0.0),
                                     smoothstep(0.9, 0.99, abs(tangent.z))));
    float3 side = cross(tangent, reference);
    float sideLength = length(side);
    float3 left = sideLength > 1e-6 ? side / sideLength : float3(0.0, 1.0, 0.0);
    float3 up = cross(left, tangent);
    float3 forward = -tangent;

    // The vertex's own offset from the rest axis, plus the wave and the beat, carried in that
    // frame. The distance along the axis is what the spine sample already accounts for.
    float3 local = float3(0.0, _geometry.position.y - spineY + wave, _geometry.position.z - spineZ)
        + pectoral;
    _geometry.position.xyz = spine + local.x * forward + local.y * left + local.z * up;
    float3 n = _geometry.normal;
    _geometry.normal = n.x * forward + n.y * left + n.z * up;
} else {
    _geometry.position.y += wave;
    _geometry.position.xyz += pectoral;
}
"""
}

/// Built twice and held, rather than per material: `makeFish` runs once per fish and a school is
/// a few dozen of them.
let swimModifier = swimModifierSource(readingPartChannel: true)
let swimModifierWithoutParts = swimModifierSource(readingPartChannel: false)
