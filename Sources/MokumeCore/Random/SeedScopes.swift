// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 形の組み立ての中で書いた乱数の種と揺らぎの設定を、出口で戻すための控え ([#1936]・[#2041])。
///
/// **乱数の規則:** 組み立ての中で種を書くと、そこから出口までは中で決めた列で引き、抜けると外の列は
/// **最初に種を書く直前**の状態から続く。種を書かずに引いた分は戻さない — 外で引いたのと同じく
/// 1 本の列を進める。入れ子は 1 段ごとに別で、内側を抜けた直後は、外側が書いた種の列の続きになる。
///
/// **控えるのは種を書く瞬間で、入口ではない。** 入口で常に写して戻すと、種を書かずに中で引いた分まで
/// 外へ残らなくなり、`createShape` を繰り返すと同じ値で同じ形を量産する (#1936 の案 C)。
///
/// **揺らぎの規則:** 揺らぎの種と細かさ (``Sketch/noiseSeed(_:)``・``Sketch/noiseDetail(_:_:)``) は
/// 入口で控え、出口でその値へ戻す。揺らぎには引くたびに進む位置が無いので、入口で写しても乱数の
/// 案 C の破れ方は起きない。控えるのは**スケッチの揺らぎの口が書く置き場** (ランタイムの本体の面の
/// 置き場) で、組み立てている面の出口 (``Canvas/Manner``) が戻すのは組み立てている面の置き場である。
/// 直に作った面 (``Canvas/init(target:gpu:)``) とそこから作った描き場所は別の置き場を持つので、
/// 面の出口だけでは、スケッチの口で書いた設定が外へ残っていた ([#2041])。置き場を共有する面
/// (本体の面と、そこから作った描き場所) では面の出口が先に同じ値へ戻すので、ここでの戻しは同じ値の
/// 書き直しになり、何もしない (``Canvas/changeNoise(_:)`` は同じ値では列を閉じない)。
///
/// 列と設定そのものはここへ移さない。`random()` と粒の放出が引く列の持ち主はランタイムのまま、揺らぎの
/// 置き場の持ち主は面のままで、これは書く口と出入口 (``ShapeAssemblyListener``) の間の控えだけを持つ。
///
/// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
/// [#2041]: https://github.com/mokume-metal/mokume/issues/2041
struct SeedScopes {
    /// 組み立ての入れ子 1 段の控え。
    private struct Mark {
        /// 最初に乱数の種を書く直前の列。まだ書いていない段は `nil`
        var randomness: Randomness?
        /// 入口での揺らぎの設定
        let noise: ValueNoise
    }

    /// 組み立ての入れ子 1 段ごとの控え。
    private var marks: [Mark] = []

    /// 組み立てに入る。`noise` は入口での揺らぎの設定。
    mutating func enter(noise: ValueNoise) {
        marks.append(Mark(randomness: nil, noise: noise))
    }

    /// 種を書く。**組み立ての中で、その段で最初に書くときだけ、書く直前の列を控える。**
    mutating func write(seed: Int, over randomness: inout Randomness) {
        if let last = marks.indices.last, marks[last].randomness == nil {
            marks[last].randomness = randomness
        }
        randomness = Randomness(seed: seed)
    }

    /// 組み立てを抜ける。その段で種を書いていれば、書く直前の列へ戻す。書いていなければ列には触らない。
    ///
    /// - Returns: 戻す先の揺らぎの設定 (入口での値)。対になる入口が無ければ `nil`。
    mutating func exit(restoring randomness: inout Randomness) -> ValueNoise? {
        guard let mark = marks.popLast() else { return nil }
        if let line = mark.randomness { randomness = line }
        return mark.noise
    }
}
