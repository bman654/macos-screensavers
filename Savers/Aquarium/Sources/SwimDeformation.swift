// The fish's vertex deformation, which is Metal rather than Swift and lives here rather than in
// `School` for that reason: the school decides what the animal is doing, this decides what its
// vertices do about it, and the two are edited for different reasons.
//
// **A material has exactly one `.geometry` modifier string.** Every deformation a fish needs is
// therefore composed into this one source; a second effect cannot be installed as a second
// modifier. `School` supplies the uniforms.

import Foundation

/// How the body is deformed, in the vertex stage. Three terms; the first two are keyed on
/// `tailward` and the third on the part channel the model carries.
///
/// Proven in `spikes/001-fish-pipeline`. It works in the mesh's own object space, which is
/// only valid because the fish is exported as a single joined mesh — reaching for world
/// space via `u_modelTransform` inside a geometry modifier produces shredded geometry and a
/// magenta surface, with no diagnostic. The `tailward²` envelope holds the head steady; a
/// fish that translates bodily side to side reads as a bar of soap.
///
/// **The axes are the mesh's, which is Blender's and not the tank's.** Nose is +X, up is +Z and
/// +Y is the fish's left; the pivot's -90° about X is what turns that into the tank's Y-up (see
/// `makeFish`). So the lateral axis the swim wave has always used is `y`, and the vertical axis
/// the turn arc needs is `z`.
///
/// **The terms compose, they do not replace each other.** Each is a displacement of the same
/// undeformed vertex, added:
///
/// - **the body wave** — a travelling sine down the body, which is the swimming itself;
/// - **the turn arc** — a constant-curvature bend, which is the body lying along the path the
///   head has already taken. Only a lurker ever writes a non-zero `bendYaw`/`bendPitch`, so for
///   every other species this term is exactly the zero it was built with;
/// - **the pectoral beat** — the two flank fins hinging about their roots. It is zero for every
///   vertex that is not one of those fins, which is what the part channel decides.
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
    let sample = readingPartChannel
        ? "float2 part = _geometry.texcoords[1];"
        : "float2 part = float2(0.0);   // asset predates the part channel"
    return """
#pragma arguments
float swimPhase;
float swimAmplitude;
float swimWaves;
float bodyMinX;
float bodyLength;
float bendYaw;
float bendPitch;
float finPhase;
float finAmplitude;

#pragma body
float tailward = clamp((bodyMinX + bodyLength - _geometry.position.x) / bodyLength, 0.0, 1.0);

// The body wave.
float envelope = tailward * tailward;
float wave = sin(tailward * swimWaves * 6.2831853 - swimPhase) * swimAmplitude * envelope;

// The turn arc. A body of constant curvature k, measured back a distance s along itself from
// the nose, stands k*s²/2 off the nose's own axis — toward the inside of the turn, which is
// where a chord of a circle always lies. `bendYaw` and `bendPitch` are that curvature in these
// object units, signed so that positive is toward +y (the fish's left) and +z (up).
float s = tailward * bodyLength;
float arc = 0.5 * s * s;

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

_geometry.position.y += wave + bendYaw * arc;
_geometry.position.z += bendPitch * arc;
_geometry.position.xyz += pectoral;
"""
}

/// Built twice and held, rather than per material: `makeFish` runs once per fish and a school is
/// a few dozen of them.
let swimModifier = swimModifierSource(readingPartChannel: true)
let swimModifierWithoutParts = swimModifierSource(readingPartChannel: false)
