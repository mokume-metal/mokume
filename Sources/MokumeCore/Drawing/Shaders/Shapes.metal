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
    // 平面は光を受けない。列が「光 0 個」を渡すので、ここは 0 で足りる
    out.worldPosition = float3(0.0);
    out.normal = float3(0.0);
    out.isDerivedNormal = 0.0;
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
    /// xyz が面の向き、w が 1 なら**形から求めた向き** (Swift 側の `SolidVertex` を参照)。
    float4 normal;
    float2 uv;
    float4 color;
};

/// 光から見た奥行きを焼き付ける。
///
/// 頂点を落とすのは**画面と同じ関数**で、渡す行列だけが光から見たものになる —
/// 焼き付けた形と画面に出る形が違ってしまわないよう、経路を分けない。
fragment float4 mokume_shadowFragment(ShapeFragmentIn in [[stage_in]]) {
    // 落とした後の奥行き (0…1)。読む側は同じ数と比べる
    return float4(in.position.z, 0.0, 0.0, 1.0);
}

vertex ShapeFragmentIn solidVertexMain(
    uint index [[vertex_id]],
    constant SolidVertex *vertices [[buffer(0)]],
    constant float4x4 &viewProjection [[buffer(1)]])
{
    ShapeFragmentIn out;
    out.position = viewProjection * float4(vertices[index].position, 1.0);
    out.uv = vertices[index].uv;
    out.color = vertices[index].color;
    // 光は世界の座標で当たるので、変換を掛けたあとの位置と向きを渡す
    out.worldPosition = vertices[index].position;
    out.normal = vertices[index].normal.xyz;
    out.isDerivedNormal = vertices[index].normal.w;
    return out;
}
