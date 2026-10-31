// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 計算の断片に**無条件で**前置きされる共通部分。
//
// 塗りの共通部分 (Common.metal) と違って、ここは入口の関数を用意しない。塗りは
// 「その画素の色」を返すだけで済むが、計算は**どの並びを読み書きするかが断片ごとに
// 違う**ので、口の数と並びを仕組みが決めてしまうと、決めた数を超えた瞬間に使えなく
// なる。書く側が入口ごと書く形にしてある。
//
// 束ねる先の番号は呼ぶ側が決める — compute(_:over:reads:writes:) に渡した
// reads + writes の並びが、そのまま buffer(0), buffer(1), … になる。

#include <metal_stdlib>
using namespace metal;

// 利用者が渡した値 (Values) が載る口。**番号を書き写さずに済むよう名前で配る** —
// 番号は仕組みの都合で動きうるが、この名前は動かない。
#define MOKUME_VALUES 15

// 計算の頼みごとに添えて届く、時刻と揺らぎの設定。
//
// **利用者の `Values` ではなく、名前で配る口から読む。** `Values` に予約の欄を差し込むと入口の
// 署名は変わらずに済むが、利用者が宣言した名前と衝突しうる (`time` は利用者が自分の値の名前として
// 既に使っている)。入口に書かなければ何も変わらない。入口に
// `constant Frame &frame [[buffer(MOKUME_FRAME)]]` と書くと読める。**番号は仕組みの都合で動き
// うるので名前で配る** (`MOKUME_VALUES` と同じ)。
#define MOKUME_FRAME 16

struct Frame {
    /// スケッチが始まってからの秒数。**頼んだ時点**のもの (値と同じく、溜めた頼みは頼んだ時の秒数を
    /// 持つ)。
    float time;
    /// 揺らぎの種と細かさ。**頼んだ時点**に `noiseSeed()` / `noiseDetail()` が決めていたもの。
    /// ``mokume_noise`` が読む。
    uint noiseSeed;
    uint noiseOctaves;
    float noiseFalloff;
};

/// その座標の揺らぎ (0…1)。**種と細かさは `Frame` が持っている**ので、渡すのは座標だけ。
/// 同じ座標・同じ種・同じ枚数なら、CPU で引く `noise()` と塗りの断片の `mokume_noise` と同じ値になる。
///
/// ```metal
/// kernel void grain(device float *out [[buffer(0)]],
///                   constant Frame &frame [[buffer(MOKUME_FRAME)]],
///                   uint id [[thread_position_in_grid]])
/// {
///     out[id] = mokume_noise(frame, float3(float(id) * 0.1, frame.time, 0.0));
/// }
/// ```
///
/// 座標は `float4` まで取れ、時刻を円周に載せた `float4(p, cos(a), sin(a))` で場をループさせられる。
static inline float mokume_noise(constant Frame &frame, float3 p) {
    return mokume_noiseSum(p, frame.noiseSeed, frame.noiseOctaves, frame.noiseFalloff);
}

static inline float mokume_noise(constant Frame &frame, float4 p) {
    return mokume_noiseSum(p, frame.noiseSeed, frame.noiseOctaves, frame.noiseFalloff);
}

static inline float mokume_noise(constant Frame &frame, float2 p) {
    return mokume_noise(frame, float3(p, 0.0));
}

static inline float mokume_noise(constant Frame &frame, float x) {
    return mokume_noise(frame, float3(x, 0.0, 0.0));
}
