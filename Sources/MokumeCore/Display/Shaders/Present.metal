// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

struct PresentFragmentIn {
    float4 position [[position]];
    float2 texCoord;
};

// 頂点を渡さずに画面いっぱいの三角形を 1 枚作る。テクスチャを貼るだけなので、
// 頂点の並びを用意して常駐させる意味がない。
vertex PresentFragmentIn presentVertexMain(uint index [[vertex_id]]) {
    const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 corner = corners[index];

    PresentFragmentIn out;
    out.position = float4(corner, 0.0, 1.0);
    // クリップ空間 (-1…1, 上が +1) からテクスチャ座標 (0…1, 上が 0) へ
    out.texCoord = float2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
    return out;
}

fragment float4 presentFragmentMain(
    PresentFragmentIn in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler linearSampler [[sampler(0)]])
{
    return source.sample(linearSampler, in.texCoord);
}
