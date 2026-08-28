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

// MARK: - 立体
//
// 立体の頂点も**平面と同じ塗りを通る**。ここが出すのは平面と同じ `ShapeFragmentIn` で、
// 混ぜ方も利用者が書いた断片も、平面のときとまったく同じ経路で効く。だから塗りを
// 2 本に分けない — 分ければ、片方にだけ効く性質がいずれ生まれる。

struct SolidVertex {
    float3 position;
    float3 normal;
    float2 uv;
    float4 color;
};

vertex ShapeFragmentIn solidVertexMain(
    uint index [[vertex_id]],
    constant SolidVertex *vertices [[buffer(0)]],
    constant float4x4 &viewProjection [[buffer(1)]])
{
    ShapeFragmentIn out;
    out.position = viewProjection * float4(vertices[index].position, 1.0);
    out.uv = vertices[index].uv;
    out.color = vertices[index].color;
    return out;
}
