// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 効果の断片に**無条件で**前置きされる共通部分。
//
// 効果は「絵から絵への変換」1 種類である ([ADR-0023] 決定 1)。組み込みの効果も利用者の
// 効果も、書くのは `float4 effect(Pixel in, Values values)` 1 本だけで、入りの絵と出りの
// 絵をつなぐ配線はこちらが持つ。**組み込みも同じ規約で書いてある** (Effects/Builtin.metal)
// ので、規約が足りているかはそこで分かる。
//
// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md

#include <metal_stdlib>
using namespace metal;

struct EffectFragmentIn {
    float4 position [[position]];
    /// 面の中の位置 (0…1)。
    float2 place;
};

// 頂点を渡さずに画面いっぱいの三角形を 1 枚作る。絵を写すだけなので、頂点の並びを
// 用意して常駐させる意味がない (表示の段と同じ形)。
vertex EffectFragmentIn mokume_effectVertexMain(uint index [[vertex_id]]) {
    const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 corner = corners[index];

    EffectFragmentIn out;
    out.position = float4(corner, 0.0, 1.0);
    out.place = float2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
    return out;
}

/// 1 画素ぶんの入力。**利用者の効果が受け取るのはこれだけ。**
///
/// **画素はスケッチの座標と同じ出す画素** (#1639)。細かさ (`pixelDensity`) を下げても、
/// `position` / `size` で刻んだ模様は出す画素で見て同じ大きさに出る。面そのもの (`source`)
/// は描く細かさで刻まれているので、その画素を索引で読む ``mokume_texel`` だけは描く画素で
/// 数える。位置で読むなら ``mokume_at`` (`place` は細かさによらない) を使う。
struct Pixel {
    /// 面の中の位置を 0…1 で表したもの。
    float2 place;
    /// 面の中の位置 (出す画素・左上が原点)。描いている画素の中心を指す。細かさ 1 では
    /// 整数 + 0.5 の値になり、1 未満では描く画素の中心を出す画素へ換算した値になる。
    float2 position;
    /// 面の大きさ (出す画素)。スケッチの `width` / `height` と同じで、細かさによらない。
    float2 size;
    /// この画素の色 (線形・アルファ乗算済み)。
    ///
    /// **読み取りであって拾い読みではない。** 同じ画素をそのまま返す効果は、絵を
    /// 1 ビットも変えない ([#391] の「無効の値では絵が変わらない」がこれに乗る)。
    ///
    /// [#391]: https://github.com/mokume-metal/mokume/issues/391
    float4 color;
    /// スケッチが始まってからの秒数。
    float time;
    /// 入りの絵。``mokume_at`` から読む。
    texture2d<float> source;
    /// 組み合わせる相手の絵。**組み込みのにじみだけが使う** — 渡されていないときは
    /// 入りと同じ絵が入っている (束ねない口を作らないため)。
    texture2d<float> paired;
    /// 組み込みの効果に効く設定。**利用者の効果は `values` を使う。**
    constant float4 *control;
};

/// 入りの絵の 1 画素を、そのまま読む。**面の外は端の画素**になる。
///
/// 拾い読み (``mokume_at``) と違って混ぜない。段の入りと出りで大きさが違うとき
/// (拡大がそれ) に、入りの画素そのものを取るためにある。
///
/// **索引は入りの面の画素** (細かさ 1 未満では描く画素) で数える。出す画素の
/// ``Pixel/position`` をそのまま渡すと、細かさ 1 未満では食い違う。
static inline float4 mokume_texel(Pixel in, int2 coord) {
    int2 last = int2(int(in.source.get_width()) - 1, int(in.source.get_height()) - 1);
    return in.source.read(uint2(clamp(coord, int2(0), last)));
}

/// 入りの絵のほかの場所を読む。**面の外は端の色**になる。
static inline float4 mokume_at(Pixel in, float2 place) {
    constexpr sampler reader(coord::normalized, filter::linear, address::clamp_to_edge);
    return in.source.sample(reader, place);
}

/// 組み合わせる相手の絵を読む。
static inline float4 mokume_paired(Pixel in, float2 place) {
    constexpr sampler reader(coord::normalized, filter::linear, address::clamp_to_edge);
    return in.paired.sample(reader, place);
}

/// 画素 1 つぶんの色を出す。**組み込みも利用者の効果も、書くのはこれ 1 本。**
float4 effect(Pixel in, Values values);

fragment float4 mokume_effectMain(
    EffectFragmentIn in [[stage_in]],
    constant Values &values [[buffer(0)]],
    constant float4 *control [[buffer(1)]],
    constant float4 *frame [[buffer(2)]],
    texture2d<float> source [[texture(0)]],
    texture2d<float> paired [[texture(1)]])
{
    // frame[0] = (段の面の幅, 高さ, 秒数, 0)・frame[1] = (出す幅, 高さ, 0, 0)。
    // **位置と大きさは出す画素で渡す** (#1639)。ラスタの位置は段の面の画素なので、出す
    // 大きさとの比を掛ける。細かさ 1 の全面の段では比がちょうど 1 で、1 ビットも変わらない
    Pixel p;
    p.size = frame[1].xy;
    p.place = in.place;
    p.position = in.position.xy * (frame[1].xy / frame[0].xy);
    p.time = frame[0].z;
    p.source = source;
    p.paired = paired;
    p.control = control;
    // **拾い読みではなく読み取り。** 変換を挟まないので、そのまま返す効果は絵を
    // 1 ビットも変えない。
    //
    // 入りと出りで大きさが違う段 (拡大) では出りのほうが広いので、端で丸める —
    // 面の外を読んだ値は決まっていない。大きさが同じ段では 1 画素も丸まらない
    uint2 last = uint2(source.get_width() - 1, source.get_height() - 1);
    p.color = source.read(min(uint2(in.position.xy), last));
    return effect(p, values);
}
