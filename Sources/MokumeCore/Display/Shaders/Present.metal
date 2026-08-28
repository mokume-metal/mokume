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
    float3 lifted = straight * brightness.exposure;
    if (brightness.toneMapping == kRoll) {
        // 色みを変えないため、いちばん明るい成分で全体を縮める
        float peak = max(lifted.x, max(lifted.y, lifted.z));
        if (isfinite(peak) && peak > brightness.knee) {
            float over = (peak - brightness.knee) / (1.0 - brightness.knee);
            float rolled = brightness.knee + (1.0 - brightness.knee) * (1.0 - exp(-over));
            lifted *= rolled / peak;
        }
    }
    return float4(lifted * color.a, color.a);
}
