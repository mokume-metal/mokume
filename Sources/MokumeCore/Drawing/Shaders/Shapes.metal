// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

struct ShapeVertex {
    float2 position;
    float4 color;
};

struct ShapeFragmentIn {
    float4 position [[position]];
    float4 color;
};

vertex ShapeFragmentIn shapeVertexMain(
    uint index [[vertex_id]],
    constant ShapeVertex *vertices [[buffer(0)]],
    constant float4x4 &projection [[buffer(1)]])
{
    ShapeFragmentIn out;
    out.position = projection * float4(vertices[index].position, 0.0, 1.0);
    out.color = vertices[index].color;
    return out;
}

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

/// アルファの乗算を戻す。完全に透明な画素には戻すべき色が無いので 0 を返す。
static inline float3 straighten(float4 color) {
    return color.a > 0.0 ? color.rgb / color.a : float3(0.0);
}

fragment float4 shapeFragmentMain(
    ShapeFragmentIn in [[stage_in]],
    constant uint &mode [[buffer(2)]],
    float4 destination [[color(0)]])
{
    float4 source = in.color;

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
