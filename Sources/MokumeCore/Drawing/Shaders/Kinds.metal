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

    // 末尾の印。**個数がずれたらここが合わなくなる**
    numbers[i++] = kKindSection + 99;
}
