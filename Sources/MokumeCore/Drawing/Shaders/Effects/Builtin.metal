// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 組み込みの効果。**利用者の効果とまったく同じ規約で書いてある** — 前文が用意する
// `float4 effect(Pixel in, Values values)` 1 本だけで、7 つぶんを `in.control` の
// 種類で分ける。規約が足りているかは、ここが書けているかで分かる。
//
// 設定の並び (Swift 側の `Effect` が正本):
//   control[0] = (種類, p0, p1, p2)
//   control[1] = (p3, 0, 0, 0)
//
// **無効の値では入りをそのまま返す。** 「0 なら効かない」を式の丸めに任せず、分岐で
// 返しているのは、検査が「1 ビットも変わらない」を見るためである。

/// ぼかしの片道ぶん。**アルファを掛けたまま平均する** — 掛けずに平均すると、透明な
/// 画素の色が混ざって縁が濁る (作業空間は乗算済み・ADR-0011 決定 3)。
static inline float4 mokume_blurAlong(Pixel in, float2 step, float radius) {
    // 重みは半径から決まる釣鐘。**足して 1 に正規化する**ので、半径を変えても明るさが
    // 変わらない
    float sigma = max(radius, 1e-4) * 0.5;
    float total = 0.0;
    float4 sum = float4(0.0);
    for (int i = -8; i <= 8; i++) {
        float offset = float(i) * radius / 8.0;
        float weight = exp(-0.5 * (offset * offset) / (sigma * sigma));
        sum += mokume_at(in, in.place + step * offset) * weight;
        total += weight;
    }
    return sum / max(total, 1e-6);
}

/// 明るさ (乗算済みのまま測る)。
static inline float mokume_luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float4 effect(Pixel in, Values values) {
    uint kind = uint(in.control[0].x);
    float p0 = in.control[0].y;
    float p1 = in.control[0].z;
    float p2 = in.control[0].w;

    // そのまま写す。段の連なりの最後に 1 度だけ通り、入りの絵へ書き戻す
    if (kind == 0) { return in.color; }

    // ぼかし (横・縦)。半径は画素
    if (kind == 1 || kind == 2) {
        if (p0 <= 0.0) { return in.color; }
        float2 step = kind == 1 ? float2(1.0 / in.size.x, 0.0) : float2(0.0, 1.0 / in.size.y);
        return mokume_blurAlong(in, step, p0);
    }

    // 反転。**乗算済みなので、色はアルファから引く** — 透明なところは透明のまま
    if (kind == 3) {
        if (p0 <= 0.0) { return in.color; }
        return float4(mix(in.color.rgb, in.color.a - in.color.rgb, p0), in.color.a);
    }

    // 単色化
    if (kind == 4) {
        if (p0 <= 0.0) { return in.color; }
        float grey = mokume_luminance(in.color.rgb);
        return float4(mix(in.color.rgb, float3(grey), p0), in.color.a);
    }

    // 周辺減光。**色だけを落とし、アルファは動かさない**
    if (kind == 5) {
        if (p0 <= 0.0) { return in.color; }
        float2 fromCentre = (in.place - 0.5) * 2.0;
        float falloff = 1.0 - p0 * smoothstep(0.4, 1.45, length(fromCentre));
        return float4(in.color.rgb * falloff, in.color.a);
    }

    // 色ずれ。赤と青を反対向きへずらす。ずれ幅は面の短辺の 2% を最大とする
    if (kind == 6) {
        if (p0 <= 0.0) { return in.color; }
        float2 shift = (in.place - 0.5) * p0 * 0.04;
        float4 red = mokume_at(in, in.place + shift);
        float4 blue = mokume_at(in, in.place - shift);
        // **アルファは 3 枚の平均**。1 枚だけから採ると、ずらした先が透明なときに
        // 色だけが残る (乗算済みの決まりが破れる)
        float alpha = (red.a + in.color.a + blue.a) / 3.0;
        float3 mixed = float3(red.r, in.color.g, blue.b);
        return float4(min(mixed, float3(alpha)), alpha);
    }

    // 色調整。明るさ・対比・彩度。**どれも 0 で無効**
    if (kind == 7) {
        if (p0 == 0.0 && p1 == 0.0 && p2 == 0.0) { return in.color; }
        float alpha = in.color.a;
        // 掛け戻してから調整する。乗算済みのまま対比を掛けると、半透明のところだけ
        // 効き方が変わる
        float3 straight = alpha > 0.0 ? in.color.rgb / alpha : float3(0.0);
        straight = max(straight + p0, 0.0);
        straight = max((straight - 0.5) * (1.0 + p1) + 0.5, 0.0);
        straight = max(mix(float3(mokume_luminance(straight)), straight, 1.0 + p2), 0.0);
        return float4(straight * alpha, alpha);
    }

    // にじみ: 明るいところだけを取り出して横へぼかす
    if (kind == 8) {
        float4 bright = float4(0.0);
        float total = 0.0;
        float sigma = max(p1, 1e-4) * 0.5;
        for (int i = -8; i <= 8; i++) {
            float offset = float(i) * p1 / 8.0;
            float weight = exp(-0.5 * (offset * offset) / (sigma * sigma));
            float4 sample = mokume_at(in, in.place + float2(offset / in.size.x, 0.0));
            float over = max(mokume_luminance(sample.rgb) - p0, 0.0);
            bright += float4(sample.rgb * over, 0.0) * weight;
            total += weight;
        }
        return bright / max(total, 1e-6);
    }

    // にじみ: ぼかした明るいところを元へ足す。**足すのは色だけ**でアルファは動かさない
    if (kind == 9) {
        if (p0 <= 0.0) { return in.color; }
        float3 glow = mokume_paired(in, in.place).rgb * p0;
        return float4(in.color.rgb + glow * in.color.a, in.color.a);
    }

    return in.color;
}
