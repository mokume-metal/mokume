// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 組み込みの描画。共通部分 (Common.metal) が前に付いた状態で組み立てられる。

struct ShapeVertex {
    float2 position;
    float2 uv;
    float4 color;
};

/// 平面の図形を置く 1 か所ぶん。並びは Swift 側の `FlatInstance` と一致する。
struct FlatInstance {
    float4 linear;
    float4 offset;
    float4 fill;
    float4 stroke;
};

/// 列ごとに変わらないもの。**立体は先頭の行列だけを読む**ので、後ろに足しても効かない。
struct FlatFrame {
    float4x4 projection;
    /// 輪郭の頂点が始まる番号。**ここから後ろが輪郭**で、手前が塗りである。
    /// 畳めない列は塗りしか無い扱い (置き場所の 2 色がどちらも白なので同じ)。
    uint strokeStart;
};

vertex ShapeFragmentIn shapeVertexMain(
    uint index [[vertex_id]],
    uint instance [[instance_id]],
    constant ShapeVertex *vertices [[buffer(0)]],
    constant FlatFrame &frame [[buffer(1)]],
    constant FlatInstance *instances [[buffer(10)]])
{
    ShapeVertex vertex_in = vertices[index];
    FlatInstance placement = instances[instance];

    // **形自身の座標を、置き場所の変換で描画先の座標へ移す。** 何も動かさない置き場所
    // (単位行列) を通しても値は 1 ビットも変わらないので、畳めない頂点も同じ経路を通る
    float2 placed = placement.linear.xy * vertex_in.position.x
        + placement.linear.zw * vertex_in.position.y + placement.offset.xy;

    ShapeFragmentIn out;
    out.position = frame.projection * float4(placed, 0.0, 1.0);
    out.uv = vertex_in.uv;
    // 置き場所の色は**頂点の色に掛かる**。畳んだ雛形は頂点が白、畳めない頂点は置き場所が
    // 白なので、どちらもこの 1 本で通る (立体と同じ)
    out.color = vertex_in.color
        * (index < frame.strokeStart ? placement.fill : placement.stroke);
    // 平面は光を受けない。列が「光 0 個」を渡すので、ここは 0 で足りる
    out.worldPosition = float3(0.0);
    out.normal = float3(0.0);
    out.isDerivedNormal = 0.0;
    // **利用者の断片へは 0 が届く。** 畳んだ雛形は形自身の座標を持つが、畳めない頂点
    // (字・画像・その場で並べたもの) は変換が焼き込まれていて持たない — 経路によって
    // 意味の変わる値を渡すくらいなら、平面は一貫して持たない側に置く
    out.shapePosition = float3(0.0);
    out.shapeNormal = float3(0.0);
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
    /// **形自身の座標。** 世界へ移すのは置き場所の仕事である。
    float3 position;
    /// 利用者の断片へ渡す、形自身の座標 (Swift 側の `SolidVertex` を参照)。
    /// 置き場所が変換を持つ形では `position` と同じ値で、変換を頂点へ焼き込む形
    /// (頂点を並べて作った形) だけが違う値を持つ。
    float3 shapePosition;
    /// xyz が面の向き、w が 1 なら**形から求めた向き** (Swift 側の `SolidVertex` を参照)。
    float4 normal;
    /// 利用者の断片へ渡す、形自身の座標での面の向き。
    float3 shapeNormal;
    float2 uv;
    float4 color;
};

/// 同じ形を置く 1 か所ぶん。並びは Swift 側の `SolidInstance` と一致する。
struct SolidInstance {
    float4x4 matrix;
    float4 normal0;
    float4 normal1;
    float4 normal2;
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
    uint instance [[instance_id]],
    constant SolidVertex *vertices [[buffer(0)]],
    constant float4x4 &viewProjection [[buffer(1)]],
    constant SolidInstance *instances [[buffer(10)]])
{
    SolidVertex vertex_in = vertices[index];
    SolidInstance placement = instances[instance];

    // **形自身の座標を、置き場所の変換で世界へ移す。** 何も動かさない置き場所
    // (単位行列) を通しても値は 1 ビットも変わらないので、その場で並べた頂点も
    // 同じ経路を通せる
    float4 world = placement.matrix * float4(vertex_in.position, 1.0);
    float3x3 normalMatrix = float3x3(
        placement.normal0.xyz, placement.normal1.xyz, placement.normal2.xyz);

    ShapeFragmentIn out;
    out.position = viewProjection * world;
    out.uv = vertex_in.uv;
    // 置き場所の色は**頂点の色に掛かる**。組み込みの形は頂点が白、頂点ごとに色を
    // 変えた形は置き場所が白なので、どちらもこの 1 本で通る
    out.color = vertex_in.color * placement.color;
    // 光は世界の座標で当たるので、移したあとの位置と向きを渡す
    out.worldPosition = world.xyz;
    out.normal = normalMatrix * vertex_in.normal.xyz;
    out.isDerivedNormal = vertex_in.normal.w;
    // **利用者の断片へは、移す前の値をそのまま渡す。** 置き場所を通していないので
    // 形を動かしても回しても変わらず、ここから作った模様は形の表面に留まる (#367)
    out.shapePosition = vertex_in.shapePosition;
    out.shapeNormal = vertex_in.shapeNormal;
    return out;
}
