#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

float brieflyNoise(float2 point) {
    return fract(sin(dot(point, float2(12.9898, 78.233))) * 43758.5453);
}

float organicNoise(float2 point) {
    float2 cell = floor(point);
    float2 local = fract(point);
    local = local * local * (3.0 - 2.0 * local);
    float a = brieflyNoise(cell);
    float b = brieflyNoise(cell + float2(1.0, 0.0));
    float c = brieflyNoise(cell + float2(0.0, 1.0));
    float d = brieflyNoise(cell + float2(1.0, 1.0));
    return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
}

float organicFbm(float2 point) {
    float value = 0.0;
    float amplitude = 0.55;
    for (int octave = 0; octave < 4; octave++) {
        value += organicNoise(point) * amplitude;
        point = point * 2.03 + float2(7.1, 3.7);
        amplitude *= 0.48;
    }
    return value;
}

[[ stitchable ]] half4 organicAtmosphere(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float darkMode
) {
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 point = float2((uv.x - 0.5) * aspect, uv.y - 0.5);
    float drift = time * 0.018;
    float warpA = organicFbm(point * 1.35 + float2(drift, -drift * 0.55));
    float warpB = organicFbm(point * 2.1 + float2(-drift * 0.38, drift * 0.62) + warpA);
    float contour = sin((point.x + warpA * 0.38) * 3.2 +
                        (point.y + warpB * 0.28) * 2.4 - drift) * 0.5 + 0.5;
    contour = smoothstep(0.18, 0.86, contour);

    float clayField = exp(-2.4 * distance(point, float2(-0.48, 0.34))) *
                      (0.52 + warpA * 0.48);
    float mossField = exp(-2.0 * distance(point, float2(0.52, -0.28))) *
                      (0.48 + warpB * 0.52);
    float stoneField = smoothstep(0.32, 0.88, warpA * 0.55 + warpB * 0.45);

    float3 darkBase = float3(0.038, 0.037, 0.034);
    float3 darkClay = float3(0.205, 0.112, 0.070);
    float3 darkMoss = float3(0.105, 0.145, 0.092);
    float3 darkStone = float3(0.155, 0.142, 0.115);
    float3 lightBase = float3(0.875, 0.850, 0.785);
    float3 lightClay = float3(0.650, 0.445, 0.315);
    float3 lightMoss = float3(0.455, 0.535, 0.385);
    float3 lightStone = float3(0.685, 0.645, 0.555);

    float3 base = mix(lightBase, darkBase, darkMode);
    float3 clay = mix(lightClay, darkClay, darkMode);
    float3 moss = mix(lightMoss, darkMoss, darkMode);
    float3 stone = mix(lightStone, darkStone, darkMode);
    float3 color = mix(base, stone, stoneField * (darkMode > 0.5 ? 0.28 : 0.22));
    color = mix(color, clay, clamp(clayField * contour, 0.0, 0.40));
    color = mix(color, moss, clamp(mossField * (1.0 - contour * 0.45), 0.0, 0.36));

    float grain = brieflyNoise(floor(position * 0.72) + 311.0) - 0.5;
    color += grain * (darkMode > 0.5 ? 0.012 : 0.018);
    return half4(half3(clamp(color, 0.0, 1.0)), 1.0);
}
