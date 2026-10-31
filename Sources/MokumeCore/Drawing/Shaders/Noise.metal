// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 揺らぎ (値の揺らぎ) の本体。**塗り (Common)・効果 (Effect)・計算 (Compute) の 3 本の前置きすべてに
// 入る** — Kinds.metal と同じく、どの断片からも同じ式で読める。
//
// 式を前置きごとに写さないために、ここに 1 つだけ置く (ADR-0001 原則 9)。前置きの側が持つのは、
// 種・枚数・弱まりを**自分の入れ物から取り出して、ここの `mokume_noiseSum` に渡す口**だけである
// (塗りは `Fragment`、効果は `Pixel`、計算は `Frame`)。

#include <metal_stdlib>
using namespace metal;

// MARK: - 揺らぎ
//
// **Swift の `ValueNoise` と同じ式である。** 同じ種・同じ座標なら、CPU で引いても
// ここで引いても同じ値が出る — 面と立体で同じ模様を出すのに、揺らぎを 2 つ別々に
// 持たなくて済むようにするためである (#366)。
//
// 二重管理を許すのは ADR-0001 原則 9 に反するので、**食い違いは機械が見る** —
// NoiseParityTests が代表点で両者を突き合わせ、ずれたら赤くなる。ここを触ったら
// 向こうも触ることになる。
//
// **傾き (`mokume_noiseGradient`) は塗りの前置き (Common.metal) にだけあり、`ValueNoise` に
// 対応するものは無い。** 傾きを要る作品は断片の中でしか使っておらず、CPU で傾きを引く作品はまだ
// 無いので、想定だけの口を先回りで作らない (ADR-0001 原則 4・#1141)。揃えている
// 約束は値のほうで、値の経路はここでも 1 本のままである。傾きがその値の傾きになって
// いることは、NoiseGradientTests が CPU の `noise()` の差分と突き合わせて見る。

/// 格子点の値を作る混ぜ合わせ。**Swift の `ValueNoise.hash` と 1 行ずつ対応する。**
///
/// 4 つ目の軸 (`w`) を持つ (#2425)。**`w` が 0 なら 3 次元の格子点の値とビット単位で同じ** —
/// `w` の項は 0 を `^` するだけで、残りは共有している。
static inline uint mokume_noiseHash(int x, int y, int z, int w, uint seed) {
    uint h = uint(x) * 0x27D4EB2Du;
    h ^= uint(y) * 0x165667B1u;
    h ^= uint(z) * 0x9E3779B1u;
    h ^= uint(w) * 0xC2B2AE3Du;
    h ^= seed * 0x85EBCA6Bu;
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    h ^= h >> 12;
    h *= 0x297A2D39u;
    h ^= h >> 15;
    return h;
}

/// 3 次元の呼び出し。`w` を 0 で渡したのと同じ。
static inline uint mokume_noiseHash(int x, int y, int z, uint seed) {
    return mokume_noiseHash(x, y, z, 0, seed);
}

/// 格子点の値 (0…1)。**ここまでは整数演算だけ**なので、CPU 側とビット単位で一致する。
static inline float mokume_noiseCorner(int x, int y, int z, uint seed) {
    return float(mokume_noiseHash(x, y, z, seed) >> 8) * (1.0 / 16777216.0);
}

/// 4 つ目の軸を持つ格子点の値 (0…1)。
static inline float mokume_noiseCorner(int x, int y, int z, int w, uint seed) {
    return float(mokume_noiseHash(x, y, z, w, seed) >> 8) * (1.0 / 16777216.0);
}

/// 格子を繋いだ 1 枚ぶんの揺らぎ。端で傾きが 0 になる繋ぎ方
/// (折れ目が縞として乗らないようにするため)。
static inline float mokume_noiseLayer(float3 p, uint seed) {
    // **端で切る。** 格子の番号は 32 ビット整数なので、外まで数えると変換が壊れる。
    // Swift 側の `ValueNoise.coordinateLimit` と同じ値で切るので、外に出ても一致する
    float3 c = clamp(p, -1000000.0, 1000000.0);
    float3 i = floor(c);
    float3 f = c - i;
    float3 t = f * f * (3.0 - 2.0 * f);

    int x0 = int(i.x), y0 = int(i.y), z0 = int(i.z);
    int x1 = x0 + 1, y1 = y0 + 1, z1 = z0 + 1;

    float near = mix(
        mix(mokume_noiseCorner(x0, y0, z0, seed), mokume_noiseCorner(x1, y0, z0, seed), t.x),
        mix(mokume_noiseCorner(x0, y1, z0, seed), mokume_noiseCorner(x1, y1, z0, seed), t.x),
        t.y);
    float far = mix(
        mix(mokume_noiseCorner(x0, y0, z1, seed), mokume_noiseCorner(x1, y0, z1, seed), t.x),
        mix(mokume_noiseCorner(x0, y1, z1, seed), mokume_noiseCorner(x1, y1, z1, seed), t.x),
        t.y);
    return mix(near, far, t.z);
}

/// 4 つ目の軸 (`w`) を持つ、格子を繋いだ 1 枚ぶんの揺らぎ (#2425)。格子の隅は 16。
/// **Swift の `ValueNoise.layer(_:_:_:_:_:)` と同じ式**で、`w` の 2 つの面を 3 次元の繋ぎ方で
/// 引き、`w` の重みで混ぜる。
static inline float mokume_noiseSlab(int x0, int y0, int z0, int w, float3 t, uint seed) {
    int x1 = x0 + 1, y1 = y0 + 1, z1 = z0 + 1;
    float near = mix(
        mix(mokume_noiseCorner(x0, y0, z0, w, seed), mokume_noiseCorner(x1, y0, z0, w, seed), t.x),
        mix(mokume_noiseCorner(x0, y1, z0, w, seed), mokume_noiseCorner(x1, y1, z0, w, seed), t.x),
        t.y);
    float far = mix(
        mix(mokume_noiseCorner(x0, y0, z1, w, seed), mokume_noiseCorner(x1, y0, z1, w, seed), t.x),
        mix(mokume_noiseCorner(x0, y1, z1, w, seed), mokume_noiseCorner(x1, y1, z1, w, seed), t.x),
        t.y);
    return mix(near, far, t.z);
}

static inline float mokume_noiseLayer(float4 p, uint seed) {
    // 端で切る。Swift 側の `ValueNoise.coordinateLimit` と同じ値で、外に出ても一致する
    float4 c = clamp(p, -1000000.0, 1000000.0);
    float4 i = floor(c);
    float4 f = c - i;
    float4 t = f * f * (3.0 - 2.0 * f);

    int x0 = int(i.x), y0 = int(i.y), z0 = int(i.z), w0 = int(i.w);
    float before = mokume_noiseSlab(x0, y0, z0, w0, t.xyz, seed);
    float after = mokume_noiseSlab(x0, y0, z0, w0 + 1, t.xyz, seed);
    return mix(before, after, t.w);
}

/// 重ねた揺らぎ (0…1)。**3 本の前置きの `mokume_noise` はどれも、入れ物から種・枚数・弱まりを
/// 取り出してこれを呼ぶ。** 枚の重ね方 (種のずらし方・弱まり・倍率) はここだけが持つ。
static inline float mokume_noiseSum(float3 p, uint seed, uint octaveCount, float falloff) {
    float sum = 0.0;
    float total = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    uint octaves = max(octaveCount, 1u);
    for (uint octave = 0; octave < octaves; octave++) {
        // 枚ごとに種をずらす。ずらさないと、倍率違いの同じ模様が重なって格子の目が見える
        uint layerSeed = seed + octave * 0x9E3779B1u;
        sum += mokume_noiseLayer(p * frequency, layerSeed) * amplitude;
        total += amplitude;
        amplitude *= falloff;
        frequency *= 2.0;
    }
    return total > 0.0 ? sum / total : 0.0;
}

/// 4 つ目の軸を持つ重ねた揺らぎ (#2425)。2 次元の場を時刻の円周でループさせる
/// (`float4(p, cos(a), sin(a))`) のに使う。`w` が 0 なら 3 次元と同じ値になる。
static inline float mokume_noiseSum(float4 p, uint seed, uint octaveCount, float falloff) {
    float sum = 0.0;
    float total = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    uint octaves = max(octaveCount, 1u);
    for (uint octave = 0; octave < octaves; octave++) {
        // 枚ごとに種をずらす。3 次元と同じ並び
        uint layerSeed = seed + octave * 0x9E3779B1u;
        sum += mokume_noiseLayer(p * frequency, layerSeed) * amplitude;
        total += amplitude;
        amplitude *= falloff;
        frequency *= 2.0;
    }
    return total > 0.0 ? sum / total : 0.0;
}
