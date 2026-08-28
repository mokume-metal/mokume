// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// すべてのフラグメントに**無条件で**前置きされる共通部分。
//
// 前置きを「利用者の断片が既に持っていれば足さない」形の条件分岐にはしない。
// コメントの中に書かれた宣言にまで反応して絵が消えるためで、二重に足されても
// 壊れない形にするほうが安全である。
//
// ここに混ぜ方の全部が入っているので、**組み込みも利用者の断片も同じ合成を通る**。
// 利用者が書くのは「その画素の色」だけで、下地との混ぜ方は書かなくてよい。

#include <metal_stdlib>
using namespace metal;

struct ShapeFragmentIn {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

// 面の中身の種類。TextureKind と対応する
constant uint kCoverage = 0;

// 混ぜ方の番号は BlendMode.rawIndex と対応する。ここを増やしたら向こうも増やす。
constant uint kBlend = 0;
constant uint kAdd = 1;
constant uint kSubtract = 2;
constant uint kLightest = 3;
constant uint kDarkest = 4;
constant uint kDifference = 5;
constant uint kExclusion = 6;
constant uint kMultiply = 7;
constant uint kScreen = 8;
constant uint kReplace = 9;

// 字形を焼いた面の読み取り方。字の縁を滑らかにするため線形に読み、
// 端では外側へはみ出さない
constexpr sampler kGlyphSampler(
    coord::normalized, filter::linear, address::clamp_to_edge);

/// フレームを通して変わらない値。
struct Uniforms {
    float time;
    float2 resolution;
};

/// 1 画素ぶんの入力。**利用者の断片が受け取るのはこれだけ。**
struct Fragment {
    /// 面の中の位置 (画素・左上が原点)。
    float2 position;
    /// 面の中の位置を 0…1 で表したもの。
    float2 place;
    /// 読む面の中の、この画素が指す位置 (0…1)。
    float2 uv;
    /// 図形が持っている色 (線形・アルファ乗算済み)。
    float4 color;
    /// 読む面から読んだ値。
    float4 texel;
    /// 読む面の中身の種類。`kCoverage` なら覆っている割合。
    uint textureKind;
    /// スケッチが始まってからの秒数。
    float time;
    /// 面の大きさ (画素)。
    float2 resolution;
};

/// アルファの乗算を戻す。完全に透明な画素には戻すべき色が無いので 0 を返す。
static inline float3 straighten(float4 color) {
    return color.a > 0.0 ? color.rgb / color.a : float3(0.0);
}

/// 出した色を下地と混ぜる。
static inline float4 mokume_composite(float4 source, float4 destination, uint mode) {
    // 置き換えるモードだけは下地を見ない
    if (mode == kReplace) {
        return source;
    }

    // 重ねるモードは、乗算済みのまま素直に足せる
    if (mode == kBlend) {
        return source + destination * (1.0 - source.a);
    }

    // 以降は「色そのもの」どうしを混ぜるので、両方の乗算を戻してから計算する。
    // 乗算済みのまま混ぜると、半透明の色が暗い色として扱われてしまう
    float3 s = straighten(source);
    float3 d = straighten(destination);
    float3 mixed;

    switch (mode) {
        case kAdd: mixed = s + d; break;
        case kSubtract: mixed = d - s; break;
        case kLightest: mixed = max(s, d); break;
        case kDarkest: mixed = min(s, d); break;
        case kDifference: mixed = abs(d - s); break;
        case kExclusion: mixed = s + d - 2.0 * s * d; break;
        case kMultiply: mixed = s * d; break;
        case kScreen: mixed = s + d - s * d; break;
        default: mixed = s; break;
    }

    // 結果として出す値は飽和させる。作業空間は範囲外を許すが、
    // ここで抑えないと混ぜた結果が下地を壊す
    mixed = clamp(mixed, 0.0, 1.0);

    // **どれだけ効かせるかはアルファが決める。** これを全モードで揃えるので、
    // アルファ 0 の色はどのモードでも下地を変えない
    float3 result = mix(d, mixed, source.a);
    float outAlpha = destination.a + source.a * (1.0 - destination.a);
    return float4(result * outAlpha, outAlpha);
}

/// 画素の色を出す。**組み込みも利用者の断片も、書くのはこれ 1 本。**
float4 paint(Fragment in, Values values);

fragment float4 mokume_fragmentMain(
    ShapeFragmentIn in [[stage_in]],
    constant uint &mode [[buffer(2)]],
    constant uint &textureKind [[buffer(3)]],
    constant Uniforms &uniforms [[buffer(4)]],
    constant Values &values [[buffer(5)]],
    texture2d<float> source_texture [[texture(0)]],
    float4 destination [[color(0)]])
{
    Fragment f;
    f.position = in.position.xy;
    f.place = in.position.xy / uniforms.resolution;
    f.uv = in.uv;
    f.color = in.color;
    f.texel = source_texture.sample(kGlyphSampler, in.uv);
    f.textureKind = textureKind;
    f.time = uniforms.time;
    f.resolution = uniforms.resolution;

    return mokume_composite(paint(f, values), destination, mode);
}
