#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

float brieflyNoise(float2 point) {
    return fract(sin(dot(point, float2(12.9898, 78.233))) * 43758.5453);
}

[[ stitchable ]] half4 grainyGradient(
    float2 position,
    half4 currentColor,
    float2 size,
    float seed,
    float baseHue,
    float hueVariation
) {
    float2 uv = position / max(size, float2(1.0));
    float angle = seed * 6.2831853;
    float2 direction = float2(cos(angle), sin(angle));
    float sweep = dot(uv - 0.5, direction) + 0.5;
    float2 focus = float2(fract(seed * 7.13), fract(seed * 11.71));
    float glow = exp(-5.0 * distance(uv, focus));
    float hue = fract(baseHue + hueVariation * 0.05 + sweep * 0.16 + glow * 0.06);
    float3 color = 0.5 + 0.5 * cos(
        6.2831853 * (hue + float3(0.0, 0.33, 0.67))
    );
    color = mix(color, color.bgr, smoothstep(0.2, 0.9, glow) * 0.28);
    float grain = brieflyNoise(floor(position * 1.35) + seed * 8192.0) - 0.5;
    return half4(half3(clamp(color * 0.74 + 0.12 + grain * 0.12, 0.0, 1.0)), 1.0);
}
