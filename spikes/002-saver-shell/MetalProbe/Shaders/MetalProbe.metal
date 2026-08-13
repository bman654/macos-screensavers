#include <metal_stdlib>
using namespace metal;

struct MetalProbeUniforms {
    float2 resolution;
    float time;
    float padding;
};

vertex float4 metalProbeFullscreenVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    return float4(positions[vertexID], 0.0, 1.0);
}

fragment float4 metalProbeFragment(float4 position [[position]],
                                   constant MetalProbeUniforms &uniforms [[buffer(0)]]) {
    float2 uv = position.xy / uniforms.resolution;
    float2 p = uv * 2.0 - 1.0;
    p.x *= uniforms.resolution.x / uniforms.resolution.y;

    float waveA = sin(p.x * 3.8 + uniforms.time * 1.15);
    float waveB = sin(p.y * 5.1 - uniforms.time * 0.83);
    float waveC = sin((p.x + p.y) * 3.2 + uniforms.time * 0.57);
    float plasma = (waveA + waveB + waveC) / 3.0;

    float3 deep = float3(0.015, 0.025, 0.10);
    float3 cyan = float3(0.03, 0.78, 0.92);
    float3 violet = float3(0.62, 0.12, 0.88);
    float blend = 0.5 + 0.5 * plasma;
    float3 color = mix(deep, cyan, smoothstep(0.02, 0.72, blend));
    color = mix(color, violet, smoothstep(0.58, 0.98, blend));

    float glow = exp(-7.0 * abs(plasma - 0.18));
    color += glow * float3(0.12, 0.20, 0.32);
    return float4(color, 1.0);
}
