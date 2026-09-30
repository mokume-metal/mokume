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
// 末尾の `mokume_keepChanged` は効果ではなく、止まっている間に書いた画素を効果を通す前の絵へ
// 写す入口である (#1524)。同じ前文の上に置けば、同じ 1 回の組み立てで済む。
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
///
/// 重みは作業空間 (線形 Display P3) の相対輝度の行。**正本は Swift 側の
/// `ColorPrimaries.luminanceWeights`** で、導き方もそこにある。sRGB の重み
/// (0.2126 / 0.7152 / 0.0722) を掛けると、彩度のある色ほど明るさがずれる (#1212)。
static inline float mokume_luminance(float3 color) {
    return dot(color, float3(0.228975, 0.691739, 0.079287));
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

/// 読んだ絵が持っていた、範囲の外の明るさ (#1638・#1817)。**色を不透明度で締める段が、入りに
/// 元からある越えを運ぶための材料**で、締める段はどれもこれを通す (拡大・色ずれ)。
///
/// 乗算済みの成分ごとに 2 つを持つ:
///
/// - `beyond`: 色が不透明度を越えていた量 (0 以上)。不透明度 0 で色を持つ光 (透明な地へ
///   加算した光) も、これで運ぶ
/// - `straight`: 不透明度のある絵の、乗算を戻した値の最大 (1 以上)。`unbounded` が立った
///   成分では使わない — 不透明度 0 で色を持つ絵の乗算を戻した値は、上限が無い
///
/// 入りが乗算済みの範囲の内 (色 0…不透明度) なら、`beyond` は 0・`straight` は 1 のままで、
/// 締めは `min(色, 不透明度)` と 1 ビットも変わらない。
struct MokumeReach {
    float3 beyond;
    float3 straight;
    float3 unbounded;
};

static inline MokumeReach mokume_reachNone() {
    MokumeReach reach;
    reach.beyond = float3(0.0);
    reach.straight = float3(1.0);
    reach.unbounded = float3(0.0);
    return reach;
}

/// 乗算済みの色 `color` (成分ごとの不透明度 `alpha`) を読んだことを、`reach` へ足す。
/// 成分ごとに別の絵から取るとき (色ずれ) は、成分ごとの不透明度を渡す。
static inline MokumeReach mokume_reachOf(MokumeReach reach, float3 color, float3 alpha) {
    reach.beyond = max(reach.beyond, color - alpha);
    bool3 opaque = alpha > 0.0;
    // 不透明度 0 の成分は割らない (選ぶ前に 1 を入れておく — 0 で割った値は選ばれなくても
    // 速い数学では NaN を持ち込みうる)
    float3 safe = select(float3(1.0), alpha, opaque);
    reach.straight = max(reach.straight, select(float3(1.0), color / safe, opaque));
    float3 transparent = select(float3(1.0), float3(0.0), opaque);
    float3 lit = select(float3(0.0), float3(1.0), color > 0.0);
    reach.unbounded = max(reach.unbounded, transparent * lit);
    return reach;
}

/// 色 `rgb` を、不透明度 `alpha` の出りへ置ける上限までに締める ([#1817])。
///
/// **上限は 2 つの小さいほう** — 「不透明度 + 越えていた量」と「不透明度 × 乗算を戻した値の
/// 最大」。前者だけでは、1 を越える光が透明と接する縁で不透明度だけが下がり、乗算を戻した色が
/// 読んだどの絵よりも明るくなる (色 4 を不透明度 1/3 で置くと、戻して 10)。後者だけでは、透明な
/// 地へ加算した光 (不透明度 0) を運べない。どちらも、入りに無い明るさを段が作らないための上限で
/// ある ([ADR-0011] 決定 1)。負の値は締めない (下からは締めない)。
static inline float3 mokume_withinReach(float3 rgb, float alpha, MokumeReach reach) {
    float3 limit = alpha + reach.beyond;
    limit = select(min(limit, alpha * reach.straight), limit, reach.unbounded > 0.5);
    return min(rgb, limit);
}

/// 描く細かさの絵を、出す細かさへ広げる (Catmull-Rom の三次補間)。
///
/// **乗算済みのまま補間する。** 掛け戻してから混ぜると、透明な画素の色 (無い) が
/// 混ざって縁が濁る — ぼかしと同じ理由 ([ADR-0011] 決定 3・4)。
///
/// `offset` は入りの絵を読む位置のずらし (0…1)。時間方向のとき、揺らして描いた分を
/// ここで戻す — 戻す場所を広げる前に置くと、余分なぼけが 1 段も入らない。
///
/// 三次補間は縁で上にも下にも行き過ぎる。**範囲の外の値を、この段が作らない** (#1638)。
/// 入りの絵が乗算済みの範囲の内 (不透明度 0…1・色 0…不透明度) なら、出りも内に置く:
///
/// - 各チャンネルを、読んだ 4×4 画素のそのチャンネルの最小・最大へ締める。不透明度は
///   1 を越えず、負にもならない。上への振れも捨てるので、負の側だけを 0 へ締めて
///   いた頃より光の量が増えにくい
/// - そのうえで、色を読んだ 16 画素の越えの範囲までに締める (`mokume_withinReach`)。
///   チャンネルごとの締めだけでは、不透明度だけが下へ振れた所 (白と黒が接する縁) で
///   色が不透明度を越える。入りが範囲の内なら、色 ≤ 不透明度になる。**入りに元からある越え
///   (1 を越える光・#1057) はそのまま運ぶ** — 一律に不透明度で締めると、作業空間が持てる
///   明るさを潰す ([ADR-0011] 決定 1)。運ぶのは読んだ範囲までで、白と光と透明が並ぶ縁で
///   負の重みが不透明度だけを下げても、乗算を戻した色は読んだ光より明るくならない (#1817)
///
/// 同じ理由で、入りにある負の値 (`.subtract` で引いた暗さ) も 0 へ切らずに運ぶ。
/// 畳むのは出力段だけで、細かさ 1 (この段が立たない) と同じ値が読み戻せる
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
    // 締める幅の初めは、読む 16 画素に含まれる中心の 1 画素 (無限大から始めない —
    // 速い数学は無限大を持たない前提で組まれる)
    float4 lowest = mokume_texel(in, int2(base));
    float4 highest = lowest;
    MokumeReach reach = mokume_reachNone();
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float4 texel = mokume_texel(in, int2(base) + int2(i - 1, j - 1));
            sum += texel * (wx[i] * wy[j]);
            lowest = min(lowest, texel);
            highest = max(highest, texel);
            reach = mokume_reachOf(reach, texel.rgb, float3(texel.a));
        }
    }
    sum = clamp(sum, lowest, highest);
    // 不透明度 0 の出りも、色をそのまま置く。**透明な地へ加算した光 (不透明度 0 で色を持つ) は
    // 運ぶ** — 畳むのは出力段だけで、色ずれ・色調整も同じく運ぶ (ADR-0011 決定 1・#1817)。
    // 入りが範囲の内なら、上の締めで不透明度 0 の所の色は 0 以下になっている
    sum.rgb = mokume_withinReach(sum.rgb, sum.a, reach);
    return sum;
}

float4 effect(Pixel in, Values values) {
    uint kind = uint(in.control[0].x);
    float p0 = in.control[0].y;
    float p1 = in.control[0].z;
    float p2 = in.control[0].w;

    // そのまま写す。段の連なりの最後に 1 度だけ通り、入りの絵へ書き戻す
    if (kind == kEffectCopy) { return in.color; }

    // ぼかし (横・縦)。半径は画素
    if (kind == kEffectBlurX || kind == kEffectBlurY) {
        if (p0 <= 0.0) { return in.color; }
        float2 step = kind == kEffectBlurX ? float2(1.0 / in.size.x, 0.0) : float2(0.0, 1.0 / in.size.y);
        return mokume_blurAlong(in, step, p0);
    }

    // 反転。**乗算済みなので、色はアルファから引く** — 透明なところは透明のまま
    if (kind == kEffectInvert) {
        if (p0 <= 0.0) { return in.color; }
        return float4(mix(in.color.rgb, in.color.a - in.color.rgb, p0), in.color.a);
    }

    // 単色化
    if (kind == kEffectMonochrome) {
        if (p0 <= 0.0) { return in.color; }
        float grey = mokume_luminance(in.color.rgb);
        return float4(mix(in.color.rgb, float3(grey), p0), in.color.a);
    }

    // 周辺減光。**色だけを落とし、アルファは動かさない**
    if (kind == kEffectVignette) {
        if (p0 <= 0.0) { return in.color; }
        float2 fromCentre = (in.place - 0.5) * 2.0;
        float falloff = 1.0 - p0 * smoothstep(0.4, 1.45, length(fromCentre));
        return float4(in.color.rgb * falloff, in.color.a);
    }

    // 色ずれ。赤と青を反対向きへずらす。ずれ幅は面の短辺の 2% を最大とする
    if (kind == kEffectFringe) {
        if (p0 <= 0.0) { return in.color; }
        float2 shift = (in.place - 0.5) * p0 * 0.04;
        float4 red = mokume_at(in, in.place + shift);
        float4 blue = mokume_at(in, in.place - shift);
        // **アルファは 3 枚の平均**。1 枚だけから採ると、ずらした先が透明なときに
        // 色だけが残る (乗算済みの決まりが破れる)
        float alpha = (red.a + in.color.a + blue.a) / 3.0;
        float3 mixed = float3(red.r, in.color.g, blue.b);
        // 色は、その成分を取った 1 枚の越えの範囲までに締める (`mokume_withinReach`)。入りが
        // 範囲の内なら、色 ≤ 不透明度になる。**入りに元からある越え (1 を越える光・#1057) は
        // そのまま運ぶ** — 一律に不透明度で締めると、作業空間が持てる明るさを潰す (ADR-0011
        // 決定 1・#1817)。ほかの成分を取った 1 枚の越えは使わない — 青を読んだ先の光が、白を
        // 読んだ赤の上限を持ち上げる
        MokumeReach reach = mokume_reachOf(
            mokume_reachNone(), mixed, float3(red.a, in.color.a, blue.a));
        return float4(mokume_withinReach(mixed, alpha, reach), alpha);
    }

    // 色調整。明るさ・対比・彩度。**どれも 0 で無効**
    if (kind == kEffectAdjust) {
        if (p0 == 0.0 && p1 == 0.0 && p2 == 0.0) { return in.color; }
        float alpha = in.color.a;
        // **不透明度 0 の画素はそのまま通す。** 乗算を戻せないので調整の掛けようが無く、色を
        // 持っていれば (透明な地へ加算した光) それを運ぶ — 周辺減光・単色化・反転と同じく、
        // 畳むのは出力段だけである (ADR-0011 決定 1・#1817)。入りが範囲の内なら、この画素は
        // 透明な黒で、前と同じ値になる
        if (alpha <= 0.0) { return in.color; }
        // 掛け戻してから調整する。乗算済みのまま対比を掛けると、半透明のところだけ
        // 効き方が変わる
        float3 straight = in.color.rgb / alpha;
        // 下へ押し出した値は 0 で止める。**入りに元からある負の値 (`.subtract` で引いた暗さ) は
        // 切らず、その値で止める** — 作業空間は範囲の外の値を捨てない (ADR-0011 決定 1・#1817)。
        // **止める所は段ごとに、その段の入りから決める** (`min(入り, 0)`)。元の入りから 1 度だけ
        // 決めると、明るさで 0 以上へ持ち上げた値を対比が押し下げたとき、元の入りが負だったか
        // どうかだけで答えが割れる。入りが範囲の内なら止める所はどの段も 0 で、前と同じ値になる
        straight = max(straight + p0, min(straight, 0.0));
        straight = max((straight - 0.5) * (1.0 + p1) + 0.5, min(straight, 0.0));
        straight = max(
            mix(float3(mokume_luminance(straight)), straight, 1.0 + p2), min(straight, 0.0));
        return float4(straight * alpha, alpha);
    }

    // にじみ: 明るいところだけを取り出しながら縮める (p0 しきい値・p1 縮め幅)。
    // ぼかしはこの後ろに、縮めた絵の上で横・縦 (種類 1・2) が続く
    if (kind == kEffectBloomExtract) { return mokume_brightShrink(in, p0, p1); }

    // にじみ: ぼかした明るいところを元へ足す。**足すのは色だけ**でアルファは動かさない
    if (kind == kEffectBloomCombine) {
        if (p0 <= 0.0) { return in.color; }
        float3 glow = mokume_paired(in, in.place).rgb * p0;
        return float4(in.color.rgb + glow * in.color.a, in.color.a);
    }

    // 拡大: 描く細かさの絵を、出す細かさへ広げる
    if (kind == kEffectEnlarge) { return mokume_enlarge(in, float2(p0, p1)); }

    // 縮める / 広げる (p0 は縮め幅)。大きなぼかしが縮めた絵の上で回るための段 (#755)。
    // 縮めるときは箱、広げるとき (p0 ≤ 1) は線形の読み 1 回 — 出りの画素の中心で
    // 読むので、縮めた絵が出りの大きさへ滑らかに戻る
    if (kind == kEffectResize) {
        if (p0 > 1.0) { return mokume_shrink(in, p0); }
        return mokume_at(in, in.place);
    }

    // 拡大して、前のフレームの結果と混ぜる (時間方向)。**p2 がいまのフレームの重み**で、
    // 1 なら前を捨てる (最初の 1 枚)
    if (kind == kEffectAccumulate) {
        float4 current = mokume_enlarge(in, float2(p0, p1));
        if (p2 >= 1.0) { return current; }
        return mix(mokume_paired(in, in.place), current, p2);
    }

    return in.color;
}

// 書き戻した画素のうち、変わった画素だけを写す (#1524)。**効果ではない** — 利用者の並びにも
// 段の並びにも現れず、効果を通したフレームの後、止まっている間に書いた画素を書き戻すたびに
// 1 度通す。入りの口は描く先 (書き戻した後)、相手の口は書き戻す前の描く先で、書き込む先は
// 効果を通す前の絵である。**同じ値 (同じビット) の画素は捨てる**ので、書き込む先の前の内容
// (効果を通す前の絵) がそのまま残る。画素の書き込みは値そのものを置く (下地と混ぜない) ので、値の差がそのまま
// 書いた画素になる。同じ値を書いた画素は「書かなかった」扱いになる — 読んで書き戻しただけの
// 画素と見分けられないためである。図形・絵・背景はここを通らず、描き切りが控えへも同じ列で描く。
//
// 断片の入口を別に立てるのは、捨てるかどうかを決めるのが `effect()` の外 (入口) だけだから
// である。前文の入口は必ず 1 色を書く
fragment float4 mokume_keepChanged(
    EffectFragmentIn in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture2d<float> paired [[texture(1)]])
{
    uint2 at = uint2(in.position.xy);
    float4 now = source.read(at);
    // **ビットで比べる** (#1524 の反証 2-5)。値で比べると、数でない値は自分とも等しくないので、
    // 数でない値を出す効果の画素がすべて「書いた画素」になり、効果を通した値が控えへ写る
    if (all(as_type<uint4>(now) == as_type<uint4>(paired.read(at)))) { discard_fragment(); }
    return now;
}
