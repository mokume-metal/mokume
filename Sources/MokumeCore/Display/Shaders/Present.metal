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

// 丸め方の番号は ToneMapping と対応する。
constant uint kClip = 0;
constant uint kRoll = 1;

/// 明るさを画面へ写す段の設定。**曲線の正本は Swift 側の `Brightness`** で、
/// ここはその写しである。折れ始める明るさまで向こうから受け取るのは、定数を
/// 二重に持たないため。写しがずれていないことは検査が突き合わせる。
struct Brightness {
    float exposure;
    float knee;
    uint toneMapping;
};

/// 乗算を戻した色 1 つを、表示へ向けて写す (出力段の手 2)。
///
/// **2 本の断片が共有する。** 画面へ差し出す側と、面に描かずに取り出す側で
/// 曲線が食い違うと、同じフレームなのに出口ごとに違う絵が出る ([ADR-0023] 決定 2)。
inline float3 mokumeMapBrightness(float3 straight, constant Brightness &brightness) {
    float3 lifted = straight * brightness.exposure;
    if (brightness.toneMapping == kRoll) {
        // **どれか 1 つでも有限でなければ丸めない。** Swift 側の `Brightness.map` と
        // 同じ規則である。ここを `max` の結果 1 つで判定すると、数でない値の落とし方が
        // 言語ごとに違うため、同じ画素が経路によって丸まったり丸まらなかったりする
        bool finite = isfinite(lifted.x) && isfinite(lifted.y) && isfinite(lifted.z);
        // 色みを変えないため、いちばん明るい成分で全体を縮める
        float peak = max(lifted.x, max(lifted.y, lifted.z));
        if (finite && peak > brightness.knee) {
            float over = (peak - brightness.knee) / (1.0 - brightness.knee);
            float rolled = brightness.knee + (1.0 - brightness.knee) * (1.0 - exp(-over));
            lifted *= rolled / peak;
        }
    }
    return lifted;
}

/// 標準レンジへ収める (出力段の手 2 の一部)。
///
/// **NaN は 0 へ倒す。** 比較がすべて false になるので `clamp` では落ちない —
/// Swift 側の `OutputStage.clampToStandardRange` と同じ扱いにする。
inline float mokumeClampToStandardRange(float value) {
    return isnan(value) ? 0.0 : clamp(value, 0.0, 1.0);
}

/// 線形 → ディスプレイのエンコード (出力段の手 3)。
///
/// **曲線の正本は Swift 側の `TransferFunction`** で、ここはその写しである。
/// ずれていないことは検査が突き合わせる (`OutputStageTests`)。
inline float mokumeEncodeTransfer(float linear) {
    if (linear <= 0.0031308) {
        return 12.92 * linear;
    }
    return 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
}

fragment float4 presentFragmentMain(
    PresentFragmentIn in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant Brightness &brightness [[buffer(0)]])
{
    float4 color = source.sample(linearSampler, in.texCoord);

    // **何も変えない設定では画素に触らない。** 乗算を戻して掛け直すだけでも
    // 半透明の画素は最下位ビットが動くので、既定の絵を動かさないために外す
    if (brightness.exposure == 1.0 && brightness.toneMapping == kClip) {
        return color;
    }

    // 丸めは色そのものに掛かる。乗算済みのまま曲げると、薄い色が暗い色として丸まる
    float3 straight = color.a > 0.0 ? color.rgb / color.a : float3(0.0);
    return float4(mokumeMapBrightness(straight, brightness) * color.a, color.a);
}

/// 出力段の 4 手をすべて通して、外へ出せる形の絵を書く。
///
/// 画面へ差し出す断片との違いは**後半 2 手を自分で行うこと**である。画面の面は
/// 線形の広い形式なので伝達関数と量子化を土台 (CoreAnimation) が行うが、外へ
/// 渡す絵にはその土台がいない。書き先が `rgba8Unorm` なので、手 4 の量子化だけは
/// 書き込みの丸めが担う。
///
/// **アルファは乗算を戻して返す** ([ADR-0011] 決定 4 の境界)。画面へ差し出す側が
/// 乗算済みのまま返すのは、下地へ合成されるのがその場だからである。
///
/// 拾い方が `sample` ではなく `read` なのは、書き先と大きさが同じで**画素が
/// 1 対 1 に対応する**ため。標本化を挟むと、境目の画素だけが混ざりうる。
fragment float4 presentEncodeFragmentMain(
    PresentFragmentIn in [[stage_in]],
    texture2d<float, access::read> source [[texture(0)]],
    constant Brightness &brightness [[buffer(0)]])
{
    float4 color = source.read(uint2(in.position.xy));

    // 手 1: 乗算を戻す。戻してからでないと、次の写しが「暗い半透明」と「暗い色」を
    // 区別できない
    float alpha = mokumeClampToStandardRange(color.a);
    float3 straight = alpha > 0.0
        ? float3(color.r / alpha, color.g / alpha, color.b / alpha)
        : float3(0.0);

    // 手 2: 明るさを画面へ写す
    float3 mapped = mokumeMapBrightness(straight, brightness);

    // 手 3: ディスプレイのエンコードを掛ける。手 4 (量子化) は書き込みが行う
    return float4(
        mokumeEncodeTransfer(mokumeClampToStandardRange(mapped.x)),
        mokumeEncodeTransfer(mokumeClampToStandardRange(mapped.y)),
        mokumeEncodeTransfer(mokumeClampToStandardRange(mapped.z)),
        alpha);
}
