// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 断片が種別として読む番号の**正本**。Swift 側はここと同じ数を渡す。
//
// 番号がずれても例外は出ない。別の種別として効くだけなので、ずれは**絵にしか現れず**、
// しかも絵に出ない番号がある — 力の attract / wander / swirl、効果の invert /
// monochrome / adjust / 縮め段、光の spot、折れ目の bevel / round は、台帳のどの
// シーンも通らない。**片方だけ直しても誰も気付かない**ので、`mokume_kindLayout` が
// この表を GPU 自身に書き出させ、Swift 側の型と突き合わせる ([#802])。
//
// **3 本の前置き (Common / Compute / Effect) すべてに入る**ので、どのライブラリからも
// 同じ名前で読める。番号を足すときはここへ足し、Swift 側の型にも同じ名前を足す —
// 検査は「両側に同じ数だけあるか」まで見るので、片方だけ足すと赤くなる。
//
// [#802]: https://github.com/mokume-metal/mokume/issues/802

#include <metal_stdlib>
using namespace metal;

// 光の種類。Swift 側は `Light.Kind`
constant uint kAmbientLight = 0;
constant uint kDirectionalLight = 1;
constant uint kPointLight = 2;
constant uint kSpotLight = 3;

// 下地との混ぜ方。Swift 側は `BlendMode.rawIndex`
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

// 基本図形の種別。Swift 側は `FormInstance.Kind`
constant uint kFormRect = 0;
constant uint kFormEllipse = 1;
constant uint kFormArc = 2;
constant uint kFormLine = 3;

// 端の形。Swift 側は `FormInstance.code(of: StrokeCap)`
constant uint kFormCapRound = 0;
constant uint kFormCapSquare = 1;
constant uint kFormCapProject = 2;

// 折れ目の形。Swift 側は `FormInstance.code(of: StrokeJoin)`
constant uint kFormJoinMiter = 0;
constant uint kFormJoinBevel = 1;
constant uint kFormJoinRound = 2;

// 塗り・輪郭を持つかの旗。Swift 側は `FormInstance.fillsFlag` / `.strokesFlag`
constant uint kFormFills = 1;
constant uint kFormStrokes = 2;

// 基本図形の縁の分類 (#2991)。**境目 (細い枝との境の測り方) と被覆 (縁 1 本を線形の渡しか面積で数えるか) の
// 両方が、この 1 つの表を読む。** Swift 側は `FormInstance.EdgeClass` (同じ表) で、`KindLayoutTests` が
// GPU 自身にこの関数を評価させて CPU と突き合わせる。
//
//   straight   角を丸めない `rect`・四角い端の線・四角い点。法線が一定の直線の縁だけ
//   curved     楕円・扇。法線が回る曲線の縁だけ
//   rounded    角の半径が 0 より大きい `rect`。辺は直線・角は曲線
//   joined     角を丸めない `rect` で、輪郭の折れ目が round / bevel。辺は直線・外縁の角が曲線 / 45° の削ぎ
//   roundLine  丸い端 (`strokeCap(.round)`) で長さのある線。辺は直線・端は曲線
//   point      丸い端で長さ 0 の線 (`point()` の丸い点)。円
constant uint kEdgeStraight = 0;
constant uint kEdgeCurved = 1;
constant uint kEdgeRounded = 2;
constant uint kEdgeJoined = 3;
constant uint kEdgeRoundLine = 4;
constant uint kEdgePoint = 5;

// 縁の被覆の数え方 (`mokume_formCoverageMode`)。0: 面積・1: 線形の渡しのまま・2: 辺は線形で、曲がった部分
// (角丸の角・丸い折れ目・削ぎ) だけ面積・3: 辺は面積で、丸い端だけ線形
constant uint kCoverageArea = 0;
constant uint kCoverageLinear = 1;
constant uint kCoverageLinearExceptCorners = 2;
constant uint kCoverageLinearExceptCaps = 3;

/// 基本図形 1 つの縁の分類。引数は `FormInstance` の同じ名前の項目 (`halfLength` は半幅 = `size.x`・線では
/// 半分の長さ、`strokes` は輪郭を持つか)。**輪郭を持たない `rect` は折れ目を読まない。**
static inline uint mokume_formEdgeClass(
    uint kind, float halfLength, float cornerRadius, bool strokes, uint cap, uint join)
{
    if (kind == kFormEllipse || kind == kFormArc) { return kEdgeCurved; }
    if (kind == kFormLine) {
        if (cap != kFormCapRound) { return kEdgeStraight; }
        return halfLength > 0.0 ? kEdgeRoundLine : kEdgePoint;
    }
    if (cornerRadius > 0.0) { return kEdgeRounded; }
    if (strokes && (join == kFormJoinRound || join == kFormJoinBevel)) { return kEdgeJoined; }
    return kEdgeStraight;
}

/// 細い枝の境目を測る幅の、行ノルム (向きによらない) の割合 (0 なら画素の法線向きの幅 = 行の絶対値の和・
/// 1 なら行ノルム)。塗りと線の太さの境目が読む。**曲線の縁は 1・直線の縁は 0。** 丸い端の線は、半分の長さが
/// 太さの半分の 1/4 までは丸い点から直線の線へつなぐ (点と長さ 1e-3 の線の間で境目が跳ばない。辺が画素ほど
/// 長い線は和で測る — 辺が短いのに行ノルムで測ると、両縁が 1 つの画素に入る帯を縁 1 本の式が数えすぎる)。
/// 角丸の `rect` は曲線 (円と同じ)。
static inline float mokume_formReachCurved(uint edgeClass, float halfLength, float halfWeight) {
    if (edgeClass == kEdgeCurved || edgeClass == kEdgeRounded || edgeClass == kEdgePoint) { return 1.0; }
    if (edgeClass == kEdgeRoundLine) { return 1.0 - saturate(halfLength / max(0.25 * halfWeight, 1e-30)); }
    return 0.0;
}

/// 輪郭の帯の穴の境目を、行ノルムで測るか (曲線の縁の穴か)。楕円・扇の穴と、内縁に丸い角が残る `rect`
/// (角の半径が太さの半分より大きい) の穴。
static inline bool mokume_formHoleCurved(uint edgeClass, float cornerRadius, float halfWeight) {
    return edgeClass == kEdgeCurved || (edgeClass == kEdgeRounded && cornerRadius > halfWeight);
}

/// 縁の被覆の数え方。`aligned` は、形の軸が描く画素の軸に沿うか (`mokume_rowsAlignToPixels`)。
/// **点は回転によらず常に線形** (`point()` の例外)。丸い端は、辺が面積になる場合でも端は線形。
static inline uint mokume_formCoverageMode(uint edgeClass, bool aligned) {
    if (edgeClass == kEdgePoint) { return kCoverageLinear; }
    if (aligned) {
        if (edgeClass == kEdgeCurved) { return kCoverageArea; }
        if (edgeClass == kEdgeRounded || edgeClass == kEdgeJoined) { return kCoverageLinearExceptCorners; }
        return kCoverageLinear;
    }
    return edgeClass == kEdgeRoundLine ? kCoverageLinearExceptCaps : kCoverageArea;
}

// 組み込みの効果。Swift 側は `BuiltinEffectKind`
//
// **10 は欠番で、再利用してよい。** かつて中間段が使っていた番号で、#755 が大きな
// ぼかしを縮めた絵の上で回す形へ変えたときに空いた。飛んでいるのは歴史の跡であって、
// 空き番号を避ける決まりがあるわけではない
constant uint kEffectCopy = 0;
constant uint kEffectBlurX = 1;
constant uint kEffectBlurY = 2;
constant uint kEffectInvert = 3;
constant uint kEffectMonochrome = 4;
constant uint kEffectVignette = 5;
constant uint kEffectFringe = 6;
constant uint kEffectAdjust = 7;
constant uint kEffectBloomExtract = 8;
constant uint kEffectBloomCombine = 9;
constant uint kEffectEnlarge = 11;
constant uint kEffectAccumulate = 12;
constant uint kEffectResize = 13;

// 粒に掛ける力。Swift 側は `ForceKind`
constant uint kForceGravity = 0;
constant uint kForceAttract = 1;
constant uint kForceWander = 2;
constant uint kForceSwirl = 3;
constant uint kForceDrag = 4;

/// 区画の境に置く印。**系統ごとに違う数**を置くので、系統がまるごと入れ替わっても
/// 気付ける — 光と基本図形はどちらも 0…3 で、並べただけでは入れ替えを見分けられない。
constant uint kKindSection = 9000;

/// 自分が見ている番号を書き出す。**検査だけが呼ぶ** (`KindLayoutTests`)。
///
/// 両側に手で書いた表を突き合わせる形では、両方が同時にずれたときに黙って通る。
/// ここは GPU 自身にこの表を書かせ、CPU が並びとして読み比べる — 値が変われば
/// もちろん、系統の順序が入れ替わっても区画の印が合わなくなる。
///
/// 並びは `KindLayoutTests` が組む期待値と同じ順で、系統ごとに `kKindSection + 通し番号`
/// を先に置く。
kernel void mokume_kindLayout(
    device uint *numbers [[buffer(0)]],
    uint id [[thread_position_in_grid]])
{
    uint i = 0;

    numbers[i++] = kKindSection + 0;
    numbers[i++] = kAmbientLight;
    numbers[i++] = kDirectionalLight;
    numbers[i++] = kPointLight;
    numbers[i++] = kSpotLight;

    numbers[i++] = kKindSection + 1;
    numbers[i++] = kBlend;
    numbers[i++] = kAdd;
    numbers[i++] = kSubtract;
    numbers[i++] = kLightest;
    numbers[i++] = kDarkest;
    numbers[i++] = kDifference;
    numbers[i++] = kExclusion;
    numbers[i++] = kMultiply;
    numbers[i++] = kScreen;
    numbers[i++] = kReplace;

    numbers[i++] = kKindSection + 2;
    numbers[i++] = kFormRect;
    numbers[i++] = kFormEllipse;
    numbers[i++] = kFormArc;
    numbers[i++] = kFormLine;

    numbers[i++] = kKindSection + 3;
    numbers[i++] = kFormCapRound;
    numbers[i++] = kFormCapSquare;
    numbers[i++] = kFormCapProject;

    numbers[i++] = kKindSection + 4;
    numbers[i++] = kFormJoinMiter;
    numbers[i++] = kFormJoinBevel;
    numbers[i++] = kFormJoinRound;

    numbers[i++] = kKindSection + 5;
    numbers[i++] = kFormFills;
    numbers[i++] = kFormStrokes;

    numbers[i++] = kKindSection + 6;
    numbers[i++] = kEffectCopy;
    numbers[i++] = kEffectBlurX;
    numbers[i++] = kEffectBlurY;
    numbers[i++] = kEffectInvert;
    numbers[i++] = kEffectMonochrome;
    numbers[i++] = kEffectVignette;
    numbers[i++] = kEffectFringe;
    numbers[i++] = kEffectAdjust;
    numbers[i++] = kEffectBloomExtract;
    numbers[i++] = kEffectBloomCombine;
    numbers[i++] = kEffectEnlarge;
    numbers[i++] = kEffectAccumulate;
    numbers[i++] = kEffectResize;

    numbers[i++] = kKindSection + 7;
    numbers[i++] = kForceGravity;
    numbers[i++] = kForceAttract;
    numbers[i++] = kForceWander;
    numbers[i++] = kForceSwirl;
    numbers[i++] = kForceDrag;

    numbers[i++] = kKindSection + 8;
    numbers[i++] = kEdgeStraight;
    numbers[i++] = kEdgeCurved;
    numbers[i++] = kEdgeRounded;
    numbers[i++] = kEdgeJoined;
    numbers[i++] = kEdgeRoundLine;
    numbers[i++] = kEdgePoint;
    numbers[i++] = kCoverageArea;
    numbers[i++] = kCoverageLinear;
    numbers[i++] = kCoverageLinearExceptCorners;
    numbers[i++] = kCoverageLinearExceptCaps;

    // 末尾の印。**個数がずれたらここが合わなくなる**
    numbers[i++] = kKindSection + 99;
}
