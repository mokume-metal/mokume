// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

struct ShapeVertex {
    float2 position;
    float4 color;
};

struct ShapeFragmentIn {
    float4 position [[position]];
    float4 color;
};

vertex ShapeFragmentIn shapeVertexMain(
    uint index [[vertex_id]],
    constant ShapeVertex *vertices [[buffer(0)]],
    constant float4x4 &projection [[buffer(1)]])
{
    ShapeFragmentIn out;
    out.position = projection * float4(vertices[index].position, 0.0, 1.0);
    out.color = vertices[index].color;
    return out;
}

fragment float4 shapeFragmentMain(ShapeFragmentIn in [[stage_in]]) {
    return in.color;
}
