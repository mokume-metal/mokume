// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

vertex float4 imageInputVertex(uint index [[vertex_id]]) {
    const float2 corners[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
    return float4(corners[index], 0, 1);
}

// OutputStage の転送関数・アルファの CPU Float 表を受け、半精度へ丸めるのは最後の一度だけ。
fragment half4 imageInputFragment(
    float4 position [[position]],
    device const uchar4* source [[buffer(0)]],
    constant float* lookup [[buffer(1)]],
    constant uint2& size [[buffer(2)]]) {
    uchar4 value = source[uint(position.y) * size.x + uint(position.x)];
    float alpha = lookup[256 + value.a];
    float3 linear = float3(lookup[value.r], lookup[value.g], lookup[value.b]);
    return half4(float4(linear * alpha, alpha));
}

// 面 (BGRA の 8 bit) の色を、詰めた表 (PixelSurface.ColorTable) で Display P3 の 8 bit へ写し、上と同じ
// 表で線形にする。不透明として書く (上の不透明度 255 と同じ値: lookup[256 + 255] は 1)。表の並びは
// ColorTable の説明: 赤と緑 [g][r] の 2 バイト・32 色ごとの青の頭・青の段差の印 (32 bit)。
fragment half4 imageSurfaceFragment(
    float4 position [[position]],
    texture2d<float, access::read> source [[texture(0)]],
    device const uchar* table [[buffer(0)]],
    constant float* lookup [[buffer(1)]]) {
    constexpr uint blueBaseOffset = 256 * 256 * 2;
    constexpr uint maskOffset = blueBaseOffset + 256 * 256 * 8;
    uint3 rgb = uint3(round(source.read(uint2(position.xy)).rgb * 255.0f));
    uint pair = (rgb.g * 256 + rgb.r) * 2;
    uint block = (rgb.b * 256 + rgb.g) * 8 + rgb.r / 32;
    device const uint* masks = reinterpret_cast<device const uint*>(table + maskOffset);
    uint blue = uint(table[blueBaseOffset + block]) + popcount(masks[block] & ((1u << (rgb.r % 32)) - 1u));
    float alpha = lookup[256 + 255];
    float3 linear = float3(lookup[table[pair]], lookup[table[pair + 1]], lookup[blue]);
    return half4(float4(linear * alpha, alpha));
}

struct ImagePatch { uint index; uint padding; half4 value; };
struct ImagePatchOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    half4 value [[flat]];
};

vertex ImagePatchOut imagePatchVertex(
    uint index [[vertex_id]], device const ImagePatch* source [[buffer(0)]],
    constant uint2& size [[buffer(2)]]) {
    ImagePatch patch = source[index];
    float2 pixel = float2(patch.index % size.x, patch.index / size.x) + 0.5f;
    float2 position = pixel / float2(size) * float2(2, -2) + float2(-1, 1);
    return { float4(position, 0, 1), 1.0f, patch.value };
}

fragment half4 imagePatchFragment(ImagePatchOut in [[stage_in]]) { return in.value; }
