// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 組み込みの描画。共通部分 (Common.metal) が前に付いた状態で組み立てられる。

struct ShapeVertex {
    float2 position;
    float2 uv;
    float4 color;
};

vertex ShapeFragmentIn shapeVertexMain(
    uint index [[vertex_id]],
    constant ShapeVertex *vertices [[buffer(0)]],
    constant float4x4 &projection [[buffer(1)]])
{
    ShapeFragmentIn out;
    out.position = projection * float4(vertices[index].position, 0.0, 1.0);
    out.uv = vertices[index].uv;
    out.color = vertices[index].color;
    return out;
}

/// 組み込みの塗り。
///
/// 覆っている割合の面なら、それを色に掛ける — **図形は白い区画を指すので掛けても
/// 色は変わらず**、字だけが縁で薄くなる。色そのものの面 (画像) なら、読んだ色に
/// 色掛けを掛ける。どちらも乗算済みどうしの積なので式は素直になる。
float4 paint(Fragment in, Values values) {
    return in.textureKind == kCoverage ? in.color * in.texel.r : in.texel * in.color;
}
