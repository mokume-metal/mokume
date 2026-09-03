// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 組み込みの効果と、段そのものが使う変換。**利用者の効果とまったく同じ規約で書いて
// ある** — 前文が用意する `float4 effect(Pixel in, Values values)` 1 本だけで、
// 全部を `in.control` の種類で分ける。規約が足りているかは、ここが書けているかで分かる。
//
// 拡大 (種類 11・12) だけは利用者の並びに現れない — 解像度の決め方の一部であって
// 後処理の 1 つではないため (ADR-0015 決定 1)。**通る道は同じ段**なので、ここに置く。
// 縮める / 広げる (種類 13) も利用者の並びには現れない — 大きなぼかしが縮めた絵の上で
// 回るための内側の段で、Swift 側の `Effect.passes` が組む (#755)。
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

/// 箱で縮める。`factor` は縮め幅 (2 のべき)。
///
/// **2×2 の箱 1 つを線形の読み 1 回で取る** — 縮めた画素の中心は元の 2×2 の境目に
/// 落ちるので、線形補間がそのまま 4 画素の平均になる。縮め幅が 4・8 なら、その箱を
/// (factor / 2)² 個並べて平均する。読む回数は元の画素数の 1/4 で済む。
static inline float4 mokume_shrink(Pixel in, float factor) {
    float2 sourceSize = float2(in.source.get_width(), in.source.get_height());
    float2 centre = in.place * sourceSize;
    int boxes = max(int(factor) / 2, 1);
    float4 sum = float4(0.0);
    for (int j = 0; j < boxes; j++) {
        for (int i = 0; i < boxes; i++) {
            float2 offset = float2(2 * i + 1 - boxes, 2 * j + 1 - boxes);
            sum += mokume_at(in, (centre + offset) / sourceSize);
        }
    }
    return sum / float(boxes * boxes);
}

/// にじみの種: 明るいところだけを取り出しながら、箱で縮める。
///
/// **しきい値は元の画素ごとに掛ける。** 平均してから掛けると、小さな明点 (にじみの種
/// そのもの) が周りの暗さに薄められてしきい値を越えず、光を漏らさなくなる。だから
/// 線形の読みでは済まず、factor² 画素を 1 つずつ読む — それでも読む回数は元の画素数と
/// 同じで、全解像度で 17 タップ読んでいた頃の 1/17 である。
static inline float4 mokume_brightShrink(Pixel in, float threshold, float factor) {
    float2 sourceSize = float2(in.source.get_width(), in.source.get_height());
    int size = max(int(factor), 1);
    int2 origin = int2(floor(in.place * sourceSize - float(size) * 0.5 + 0.5));
    float3 sum = float3(0.0);
    for (int j = 0; j < size; j++) {
        for (int i = 0; i < size; i++) {
            float4 sample = mokume_texel(in, origin + int2(i, j));
            float over = max(mokume_luminance(sample.rgb) - threshold, 0.0);
            sum += sample.rgb * over;
        }
    }
    // アルファは持たない。合成の段は色だけを足し、アルファは元の絵のものを使う
    return float4(sum / float(size * size), 0.0);
}

/// 描く細かさの絵を、出す細かさへ広げる (Catmull-Rom の三次補間)。
///
/// **乗算済みのまま補間する。** 掛け戻してから混ぜると、透明な画素の色 (無い) が
/// 混ざって縁が濁る — ぼかしと同じ理由 ([ADR-0011] 決定 3・4)。
///
/// `offset` は入りの絵を読む位置のずらし (0…1)。時間方向のとき、揺らして描いた分を
/// ここで戻す — 戻す場所を広げる前に置くと、余分なぼけが 1 段も入らない。
///
/// 三次補間は縁で行き過ぎる (負へ振れる) ことがある。作業空間の値は光の量なので、
/// **負にはしない**。
static inline float4 mokume_enlarge(Pixel in, float2 offset) {
    float2 size = float2(in.source.get_width(), in.source.get_height());
    float2 coord = (in.place + offset) * size - 0.5;
    float2 base = floor(coord);
    float2 f = coord - base;

    // Catmull-Rom の重み (a = -0.5)
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float wx[4] = { w0.x, w1.x, w2.x, w3.x };
    float wy[4] = { w0.y, w1.y, w2.y, w3.y };

    float4 sum = float4(0.0);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            sum += mokume_texel(in, int2(base) + int2(i - 1, j - 1)) * (wx[i] * wy[j]);
        }
    }
    sum = max(sum, float4(0.0));
    // 乗算済みの決まりを保つ — 不透明度が無いところに色は残らない
    if (sum.a <= 0.0) { return float4(0.0); }
    return sum;
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

    // にじみ: 明るいところだけを取り出しながら縮める (p0 しきい値・p1 縮め幅)。
    // ぼかしはこの後ろに、縮めた絵の上で横・縦 (種類 1・2) が続く
    if (kind == 8) { return mokume_brightShrink(in, p0, p1); }

    // にじみ: ぼかした明るいところを元へ足す。**足すのは色だけ**でアルファは動かさない
    if (kind == 9) {
        if (p0 <= 0.0) { return in.color; }
        float3 glow = mokume_paired(in, in.place).rgb * p0;
        return float4(in.color.rgb + glow * in.color.a, in.color.a);
    }

    // 拡大: 描く細かさの絵を、出す細かさへ広げる
    if (kind == 11) { return mokume_enlarge(in, float2(p0, p1)); }

    // 縮める / 広げる (p0 は縮め幅)。大きなぼかしが縮めた絵の上で回るための段 (#755)。
    // 縮めるときは箱、広げるとき (p0 ≤ 1) は線形の読み 1 回 — 出りの画素の中心で
    // 読むので、縮めた絵が出りの大きさへ滑らかに戻る
    if (kind == 13) {
        if (p0 > 1.0) { return mokume_shrink(in, p0); }
        return mokume_at(in, in.place);
    }

    // 拡大して、前のフレームの結果と混ぜる (時間方向)。**p2 がいまのフレームの重み**で、
    // 1 なら前を捨てる (最初の 1 枚)
    if (kind == 12) {
        float4 current = mokume_enlarge(in, float2(p0, p1));
        if (p2 >= 1.0) { return current; }
        return mix(mokume_paired(in, in.place), current, p2);
    }

    return in.color;
}
