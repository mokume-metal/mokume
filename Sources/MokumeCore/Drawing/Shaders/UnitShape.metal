// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 正の寸法の球・箱・平面・円柱の塗りを、単位の形の頂点 1 組と置き場所ごとの軸の寸法で描く頂点関数
// ([#1862]・[#2386])。共通部分 (Common.metal) が前に付いた状態で組み立てられる。
//
// **Shapes.metal とは別のライブラリにする。** 同じライブラリへ関数を足すと、既存の
// `solidVertexMain` の組み上がり方が変わりうる。寸法ごとに頂点を組む従来の経路と、画素と
// 利用者の断片が読む `shapePosition`・`shapeNormal` が 1 ビットも違わないことが、この経路を採る
// 条件である。
//
// **world と投影の積和の順を明示する。** 通常の行列積に寸法の掛け算を足すだけでは、
// コンパイラが積和のまとめ方を変え、重なる半透明・鏡映・斜めの視点で `shapePosition` と
// 画素がずれた (#1862 の第 1・第 2 試作)。下の順は実測で従来経路と一致した順で、コンパイラが
// 保証するものではない。**一致は `UnitShapeTests` が同じビルドの 2 経路を比べて見張る** —
// 専用機を含む検査を回す機械ごとに確かめられ、ずれたら誤差を許さずに赤くなる。
//
// [#1862]: https://github.com/mokume-metal/mokume/issues/1862
// [#2386]: https://github.com/mokume-metal/mokume/issues/2386

// MARK: - Shapes.metal の写し (ここから)
//
// 入力の型は Shapes.metal と一字一句同じに保つ。空行で区切った塊ごとに、Shapes.metal に
// そのまま含まれることを `UnitShapeTests` が確かめる。直すときは Shapes.metal と同時に直す。

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
    /// 塗りの頂点を、置き場所ごとの記述 (`ThinFillRecord`) から頂点段で広げるか (#2208)。0 は広げない。
    /// 1 と 2 なら、`strokeStart` より前の頂点の `position` は「片の番号と角の番号」で、頂点段が片の
    /// 角を組む。2 は貼る絵があり、読み取り位置を `thinFillUV` の箱から作る。
    uint thinFill;
    /// 広げた片の貼る絵の読み取り位置を作る箱 (xy が下限・zw が幅)。`thinFill` が 2 のときだけ読む。
    float4 thinFillUV;
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

constant uint kSolidFlipsNormal = 0x80000000u;

// MARK: - Shapes.metal の写し (ここまで)

/// 単位の形の頂点を、置き場所の軸ごとの寸法 (`normal0.w`・`normal1.w`・`normal2.w`) で広げてから落とす。
///
/// **単位の形の位置 × 寸法**が、寸法ごとに組んだ形の位置と 1 ビットも違わない (Swift 側の
/// `SolidShape.unitScaling`)。球は単位球の位置が向きそのものなので、向き × 半径になる — CPU が
/// 半径ごとに組む球と同じ 1 回の掛け算である。利用者の断片へ渡す `shapePosition` もこの値にする。
/// 向きは寸法に依らないので広げない。ほかは `solidVertexMain` (Shapes.metal) と同じで、影の
/// 焼き付けもこの関数で行う。
vertex ShapeFragmentIn unitShapeVertexMain(
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
    float3 scaled = vertex_in.position
        * float3(placement.normal0.w, placement.normal1.w, placement.normal2.w);
    vertex_in.position = scaled;
    vertex_in.shapePosition = scaled;

    // 世界へ移す。`placement.matrix * float4(position, 1.0)` と同じ値を、平行移動 → x → y → z
    // の順の積和で作る (冒頭の「積和の順を明示する」)
    float4 world = fma(placement.matrix[2], vertex_in.position.z,
        fma(placement.matrix[1], vertex_in.position.y,
            fma(placement.matrix[0], vertex_in.position.x, placement.matrix[3])));
    float3x3 normalMatrix = float3x3(
        placement.normal0.xyz, placement.normal1.xyz, placement.normal2.xyz);

    ShapeFragmentIn out;
    // 投影は x の積 → y → z → w の順。world と順が違うのは、それぞれ従来経路と一致した順だから
    out.position = fma(frame.projection[3], world.w,
        fma(frame.projection[2], world.z,
            fma(frame.projection[1], world.y, frame.projection[0] * world.x)));
    // 輪郭の寄せ (ADR-0039 決定 2)。単位の形の塗りに輪郭の頂点は無いが、`solidVertexMain` と
    // 同じ式を保つ
    bool isStroke = vertex_in.stroke > 0.0;
    out.position.xy += (isStroke ? 1.0 : 0.0) * frame.strokeShift.xy * out.position.w;
    out.uv = vertex_in.uv;
    out.color = vertex_in.color * placement.color;
    out.worldPosition = world.xyz;
    out.normal = normalMatrix * vertex_in.normal.xyz;
    out.normal = flipsNormal ? -out.normal : out.normal;
    out.isDerivedNormal = vertex_in.normal.w;
    // 利用者の断片へは、移す前の値 (寸法ごとに組んだ形の座標) を渡す (#367)
    out.shapePosition = vertex_in.shapePosition;
    out.shapeNormal = flipsNormal ? -vertex_in.shapeNormal : vertex_in.shapeNormal;
    out.coverage = isStroke ? vertex_in.stroke : 1.0;
    out.particleAge = 0.0;
    return out;
}

// Common.metal の断片の入口が呼ぶ。このライブラリから使うのは頂点関数だけだが、`paint` が
// 無いと組み上がらない。式は Shapes.metal の組み込みの塗りと同じ
float4 paint(Fragment in, Values values) {
    return in.texel * in.color;
}
