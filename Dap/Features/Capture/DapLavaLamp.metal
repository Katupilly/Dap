#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float dapHash1(float value) {
    return fract(sin(value * 127.1 + 311.7) * 43758.5453123);
}

static float dapNoise1(float value) {
    float base = floor(value);
    float fraction = fract(value);
    float t = fraction * fraction * fraction
        * (fraction * (fraction * 6.0 - 15.0) + 10.0);

    return mix(dapHash1(base), dapHash1(base + 1.0), t);
}

static float dapSignedNoise(float value) {
    return dapNoise1(value) * 2.0 - 1.0;
}

static float dapBlobField(float2 uv, float2 center, float radius, float aspect) {
    float2 delta = (uv - center) * float2(aspect, 1.0);
    return (radius * radius) / (dot(delta, delta) + 0.08);
}

[[ stitchable ]]
half4 dapLavaLamp(
    float2 position,
    half4 sourceColor,
    float4 bounds,
    float time,
    half4 background,
    half4 blobA,
    half4 blobB,
    half4 blobC,
    half4 blobD
) {
    (void)sourceColor;

    float2 size = max(bounds.zw, float2(1.0));
    float2 uv = (position - bounds.xy) / size;
    float aspect = size.x / size.y;

    half4 blobE = mix(blobA, blobC, half(0.5));
    half4 blobF = mix(blobB, blobD, half(0.5));

    float centerAX = 0.08 + 0.07 * dapSignedNoise(time * 0.047 + 11.3);
    float centerAY = 0.35 + 0.05 * dapSignedNoise(time * 0.033 + 23.7);
    float centerBX = 0.26 + 0.08 * dapSignedNoise(time * 0.058 + 37.1);
    float centerBY = 0.67 + 0.05 * dapSignedNoise(time * 0.041 + 41.9);
    float centerCX = 0.43 + 0.07 * dapSignedNoise(time * 0.071 + 53.2);
    float centerCY = 0.42 + 0.06 * dapSignedNoise(time * 0.052 + 67.4);
    float centerDX = 0.60 + 0.08 * dapSignedNoise(time * 0.049 + 79.8);
    float centerDY = 0.62 + 0.05 * dapSignedNoise(time * 0.036 + 83.6);
    float centerEX = 0.77 + 0.07 * dapSignedNoise(time * 0.063 + 163.7);
    float centerEY = 0.36 + 0.05 * dapSignedNoise(time * 0.044 + 177.4);
    float centerFX = 0.94 + 0.06 * dapSignedNoise(time * 0.054 + 205.9);
    float centerFY = 0.69 + 0.04 * dapSignedNoise(time * 0.039 + 219.8);

    float radiusA = 0.94 + 0.05 * dapSignedNoise(time * 0.019 + 97.2);
    float radiusB = 0.88 + 0.04 * dapSignedNoise(time * 0.022 + 109.5);
    float radiusC = 0.84 + 0.05 * dapSignedNoise(time * 0.027 + 127.8);
    float radiusD = 0.90 + 0.04 * dapSignedNoise(time * 0.021 + 149.1);
    float radiusE = 0.82 + 0.05 * dapSignedNoise(time * 0.024 + 191.6);
    float radiusF = 0.92 + 0.04 * dapSignedNoise(time * 0.018 + 233.1);

    float2 centerA = float2(centerAX, centerAY);
    float2 centerB = float2(centerBX, centerBY);
    float2 centerC = float2(centerCX, centerCY);
    float2 centerD = float2(centerDX, centerDY);
    float2 centerE = float2(centerEX, centerEY);
    float2 centerF = float2(centerFX, centerFY);

    float fieldA = dapBlobField(uv, centerA, radiusA, aspect);
    float fieldB = dapBlobField(uv, centerB, radiusB, aspect);
    float fieldC = dapBlobField(uv, centerC, radiusC, aspect);
    float fieldD = dapBlobField(uv, centerD, radiusD, aspect);
    float fieldE = dapBlobField(uv, centerE, radiusE, aspect);
    float fieldF = dapBlobField(uv, centerF, radiusF, aspect);
    float total = max(
        fieldA + fieldB + fieldC +
        fieldD + fieldE + fieldF,
        0.0001
    );

    half4 mixedBlobs = (
        blobA * half(fieldA) +
        blobB * half(fieldB) +
        blobC * half(fieldC) +
        blobD * half(fieldD) +
        blobE * half(fieldE) +
        blobF * half(fieldF)
    ) / half(total);

    float fill = smoothstep(0.45, 1.65, total);
    half4 result = mix(background, mixedBlobs, half(fill));
    result.a = 1.0h;
    return result;
}
