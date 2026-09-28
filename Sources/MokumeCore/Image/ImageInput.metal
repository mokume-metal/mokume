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
