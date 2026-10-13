// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
// #1862 isolated prototype: separate library to preserve existing shader compilation.
// Shapes.metal stays byte-identical to main 1fcc4ab0. These declarations are copied
// only for this experiment; a production implementation needs a maintenance decision.
struct FlatFrame {
    float4x4 projection;
    /// 輪郭の頂点が始まる番号。**ここから後ろが輪郭**で、手前が塗りである。
    /// 畳めない列は塗りしか無い扱い (置き場所の 2 色がどちらも白なので同じ)。
    uint strokeStart;
    /// 立体の輪郭の頂点を画面で (+0.5, +0.5) 画素寄せる量 (切り取り座標。`w` を掛けて足す)。
    float4 strokeShift;
    /// 描く画素 1 つが描画先の座標でいくらか (x, y)。細かさ 1 ならちょうど 1
    /// (`formVertexMain`・[#1488])。
    ///
    /// [#1488]: https://github.com/mokume-metal/mokume/issues/1488
    float2 unitsPerDrawnPixel;
    /// 平面の頂点ごとの被覆 (`coverages`) を読むか。0 なら読まずに 1 とする (#1637)。
    uint readsCoverage;
};

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
    /// 0 でなければ**輪郭の頂点**で、値はその被覆 (Swift 側の `SolidVertex` を参照)。頂点関数が
    /// 画面で半画素寄せる
    float stroke;
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

/// 添字の最上位の桁。**立っていれば、桁を外した番号の頂点を読み、向きを裏返して出す**
/// ([#2222])。
///
/// 裏 → 表を 1 回で描く添字の列 (Swift 側の `SolidSweep.flipsNormal`) が、巻き方を入れ替えた
/// 写しの三角形のうち、形から求めた向きを持つ頂点にだけ立てる。写しは元が裏を向いているときだけ
/// 表を向いて残るので、断片は向きを裏返さない (`front_facing` が表)。そこで頂点の側で裏返し、
/// 元を置き場所ごとに描いたとき断片が裏返すのと同じ向きで光を当てる。**桁の立たない添字** (ほかの
/// 全部の描画・影の焼き付け・書かれた向きの写し) は、読む頂点も出す値も今までと変わらない。
///
/// [#2222]: https://github.com/mokume-metal/mokume/issues/2222
constant uint kSolidFlipsNormal = 0x80000000u;

/// 立体の頂点を落とす。
///
/// **影の焼き付けもこの関数で行う** — 渡す行列だけが光から見たものになり、断片は
/// 付けない (奥行きの面へは前後判定が書く)。焼き付けた形と画面に出る形が違って
/// しまわないよう、経路を分けない。
vertex ShapeFragmentIn unitSphereVertexMain(
    uint index [[vertex_id]],
    uint instance [[instance_id]],
    constant SolidVertex *vertices [[buffer(0)]],
    constant FlatFrame &frame [[buffer(1)]],
    constant SolidInstance *instances [[buffer(10)]])
{
    // 添字の最上位の桁は、向きを裏返す写しの印 (`kSolidFlipsNormal`)。読む番号は桁を外したもの
    bool flipsNormal = (index & kSolidFlipsNormal) != 0u;
    SolidVertex vertex_in = vertices[index & ~kSolidFlipsNormal];
    SolidInstance placement = instances[instance];
    float3 scaled = vertex_in.normal.xyz * placement.normal0.w;
    vertex_in.position = scaled;
    vertex_in.shapePosition = scaled;

    // **形自身の座標を、置き場所の変換で世界へ移す。** 何も動かさない置き場所
    // (単位行列) を通しても値は 1 ビットも変わらないので、その場で並べた頂点も
    // 同じ経路を通せる
    // #1862: On the measured M3 Max/compiler, this explicit order matches the
    // original pipeline. A plain matrix multiply in this new entrypoint does not.
    // This is a measured compatibility result, not a guarantee for other compilers.
    float4 world = fma(placement.matrix[2], vertex_in.position.z,
        fma(placement.matrix[1], vertex_in.position.y,
            fma(placement.matrix[0], vertex_in.position.x, placement.matrix[3])));
    float3x3 normalMatrix = float3x3(
        placement.normal0.xyz, placement.normal1.xyz, placement.normal2.xyz);

    ShapeFragmentIn out;
    // Projection uses a different accumulation order. Oblique views expose the
    // difference even when the default camera's rendered colors are identical.
    out.position = fma(frame.projection[3], world.w,
        fma(frame.projection[2], world.z,
            fma(frame.projection[1], world.y, frame.projection[0] * world.x)));
    // **輪郭だけを画面で半画素寄せる** (ADR-0039 決定 2)。立体の頂点は投影の後でしか
    // 画面の位置が決まらないので、切り取り座標で `w` を掛けて足す。影の焼き付けは
    // 寄せ 0 を渡す
    // 寄せは輪郭なら被覆によらず 1 画素の半分 (`stroke` は被覆を兼ねる・#1637)
    bool isStroke = vertex_in.stroke > 0.0;
    out.position.xy += (isStroke ? 1.0 : 0.0) * frame.strokeShift.xy * out.position.w;
    out.uv = vertex_in.uv;
    // 置き場所の色は**頂点の色に掛かる**。組み込みの形は頂点が白、頂点ごとに色を
    // 変えた形は置き場所が白なので、どちらもこの 1 本で通る
    out.color = vertex_in.color * placement.color;
    // 光は世界の座標で当たるので、移したあとの位置と向きを渡す
    out.worldPosition = world.xyz;
    out.normal = normalMatrix * vertex_in.normal.xyz;
    // 写しの向きは、移した後で符号だけを裏返す。断片が `-in.normal` で裏返すのと同じ値になる。
    // 形から求めたかの印 (`w`) はそのまま渡す
    out.normal = flipsNormal ? -out.normal : out.normal;
    out.isDerivedNormal = vertex_in.normal.w;
    // **利用者の断片へは、移す前の値をそのまま渡す。** 置き場所を通していないので
    // 形を動かしても回しても変わらず、ここから作った模様は形の表面に留まる (#367)
    out.shapePosition = vertex_in.shapePosition;
    out.shapeNormal = flipsNormal ? -vertex_in.shapeNormal : vertex_in.shapeNormal;
    out.coverage = isStroke ? vertex_in.stroke : 1.0;
    return out;
}


float4 paint(Fragment in, Values values) { return in.texel * in.color; }
