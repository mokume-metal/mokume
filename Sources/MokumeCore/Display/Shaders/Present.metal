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
/// 二重に持たないため。
///
/// 並びは Swift 側の `PackedBrightness` と一致し、`ShaderInterfaceTests` が反射で
/// 突き合わせる。取り出す断片が CPU の出力段と同じバイトを出すことは
/// `OutputAgreementTests` が絵で、`OutputFunctionAgreementTests` が関数の答えで突き合わせる。
/// 画面へ差し出す断片の明るさは `BrightnessTests` が相対の差で見る (こちらはビットの一致を約束しない)。
struct Brightness {
    float exposure;
    float knee;
    uint toneMapping;
};

// ここから下の共有の関数と、取り出す断片は **速さより正しさを取る組み方 (safe math)** で組む
// (#1762)。取り出す断片は CPU の出力段と同じバイトを出さなければならず (ADR-0023 決定 2)、
// 既定の組み方では割り算が近似になり、式も並べ替えられる。画面へ差し出す断片はビット単位の
// 一致を約束しない (面は線形の広い形式で、土台が仕上げる) ので、既定の組み方のまま置く —
// library ごと safe にすると、露出を掛けた画面が毎フレーム 4K で約 0.1 ms 重くなった。
#pragma METAL fp math_mode(safe)

/// `exp(-over)` (over > 0)。**正本は Swift 側の `Brightness.decay`** で、1 演算ずつ同じ
/// 手順を踏む。`exp` を呼ばないのは、GPU の `exp` と CPU の数学ライブラリが最下位の桁で
/// 食い違い、roll の出口どうしが 1 段ずれていたため (#1762)。積に和が続く所は `fma` を
/// 明示し、組み立て器が融合するかどうかに結果を預けない。係数は Swift 側と同じ 16 進。
inline float mokumeDecay(float over) {
    if (over >= 20.0) {
        return 0.0;
    }
    float n = round(over * 0x1.715476p+0f);
    float r = fma(-n, 0x1.7f7d1cp-20f, fma(-n, 0x1.62e4p-1f, over));
    float t = -r;
    float p = 0x1.a01a02p-16f;
    p = fma(p, t, 0x1.a01a02p-13f);
    p = fma(p, t, 0x1.6c16c2p-10f);
    p = fma(p, t, 0x1.111112p-7f);
    p = fma(p, t, 0x1.555556p-5f);
    p = fma(p, t, 0x1.555556p-3f);
    p = fma(p, t, 0x1p-1f);
    p = fma(p, t, 1.0f);
    p = fma(p, t, 1.0f);
    // 2⁻ⁿ は指数の欄を直に組む (n は 0…29 なので正規数に収まり、掛けても丸まらない)
    return p * as_type<float>(uint(127 - int(n)) << 23);
}

/// 範囲へ寄せた明るさ。**正本は Swift 側の `Brightness.rolled`**。
inline float mokumeRolled(float peak, float knee) {
    float over = (peak - knee) / (1.0 - knee);
    return fma(1.0 - knee, 1.0 - mokumeDecay(over), knee);
}

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
            lifted *= mokumeRolled(peak, brightness.knee) / peak;
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

/// 線形の値を、しきい値の表で 8 bit の段へ落とす (出力段の手 3・4)。
///
/// **表の正本は Swift 側の `OutputStage.quantizeThresholds`** で、CPU の伝達関数と量子化から
/// 求めたものを置き場で受け取る。伝達関数の `pow` と書き込みの丸めは CPU とビット単位では
/// 揃わず、境目のほぼ真上の値だけが出口によって 1 段ずれていた (#1762)。比較には丸めが
/// 入らないので、表で決めた段は CPU の段と食い違わない。
///
/// 段の見当は近似の `pow` で付け、表で確かめて直す。**答えを決めるのは表との比較だけ**で、
/// 見当が外れても直す回数が増えるだけである (ふつうは 1〜2 回の比較で済む)。表を二分探索すると
/// 比較が 8 回連なり、4K で出力段が倍の重さになった。値でないものと 0 以下は段 0、1 以上は段 255。
inline float mokumeQuantizeLinear(float linear, constant float *thresholds) {
    if (!(linear > 0.0)) {
        return 0.0;
    }
    if (linear >= 1.0) {
        return 1.0;
    }
    float guess = linear <= 0.0031308
        ? 12.92 * linear
        : 1.055 * fast::pow(linear, 1.0 / 2.4) - 0.055;
    int level = clamp(int(rint(guess * 255.0)), 0, 255);
    // 段 k に届くのは thresholds[k - 1] 以上のとき
    while (level > 0 && linear < thresholds[level - 1]) {
        level -= 1;
    }
    while (level < 255 && linear >= thresholds[level]) {
        level += 1;
    }
    return float(level) / 255.0;
}

// 画面へ差し出す断片は既定の組み方に戻す (上の safe math の注記)
#pragma METAL fp math_mode(fast)

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

// 取り出す断片は、共有の関数と同じく safe math で組む
#pragma METAL fp math_mode(safe)

/// 出力段の 4 手をすべて通して、外へ出せる形の絵を書く。
///
/// 画面へ差し出す断片との違いは**後半 2 手を自分で行うこと**である。画面の面は
/// 線形の広い形式なので伝達関数と量子化を土台 (CoreAnimation) が行うが、外へ
/// 渡す絵にはその土台がいない。**段は断片が決め、書き先 (`rgba8Unorm`) には段そのもの
/// (k / 255) を書く** — 書き込みの丸めに段を決めさせると、CPU の `rounded()` と境目で
/// 食い違う (#1762)。
///
/// **アルファは乗算を戻して返す** ([ADR-0011] 決定 4 の境界)。画面へ差し出す側が
/// 乗算済みのまま返すのは、下地へ合成されるのがその場だからである。
///
/// 拾い方が `sample` ではなく `read` なのは、書き先と大きさが同じで**画素が
/// 1 対 1 に対応する**ため。標本化を挟むと、境目の画素だけが混ざりうる。
fragment float4 presentEncodeFragmentMain(
    PresentFragmentIn in [[stage_in]],
    texture2d<float, access::read> source [[texture(0)]],
    constant Brightness &brightness [[buffer(0)]],
    constant float *thresholds [[buffer(1)]])
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

    // 手 3・4: ディスプレイのエンコードと量子化を、しきい値の表で 1 度に行う。
    // 不透明度は光の量ではないので、伝達関数を掛けずに CPU と同じ丸め (0 から遠い側) で量子化する
    return float4(
        mokumeQuantizeLinear(mapped.x, thresholds),
        mokumeQuantizeLinear(mapped.y, thresholds),
        mokumeQuantizeLinear(mapped.z, thresholds),
        round(alpha * 255.0) / 255.0);
}
