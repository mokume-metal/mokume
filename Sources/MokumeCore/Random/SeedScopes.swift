// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 形の組み立ての中で書いた乱数の種を、出口で戻すための控え ([#1936])。
///
/// **規則:** 組み立ての中で種を書くと、そこから出口までは中で決めた列で引き、抜けると外の列は
/// **最初に種を書く直前**の状態から続く。種を書かずに引いた分は戻さない — 外で引いたのと同じく
/// 1 本の列を進める。入れ子は 1 段ごとに別で、内側を抜けた直後は、外側が書いた種の列の続きになる。
///
/// **控えるのは種を書く瞬間で、入口ではない。** 入口で常に写して戻すと、種を書かずに中で引いた分まで
/// 外へ残らなくなり、`createShape` を繰り返すと同じ値で同じ形を量産する (#1936 の案 C)。
///
/// 列そのものはここへ移さない。`random()` と粒の放出が引く列の持ち主はランタイムのままで、これは
/// 書く口 (``SketchRuntime/writeSeed(_:)``) と出入口 (``ShapeAssemblyListener``) の間の控えだけを持つ。
///
/// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
struct SeedScopes {
    /// 組み立ての入れ子 1 段ごとの、最初に種を書く直前の列。まだ書いていない段は `nil`。
    private var marks: [Randomness?] = []

    /// 組み立てに入る。
    mutating func enter() {
        marks.append(nil)
    }

    /// 種を書く。**組み立ての中で、その段で最初に書くときだけ、書く直前の列を控える。**
    mutating func write(seed: Int, over randomness: inout Randomness) {
        if let last = marks.indices.last, marks[last] == nil { marks[last] = randomness }
        randomness = Randomness(seed: seed)
    }

    /// 組み立てを抜ける。その段で種を書いていれば、書く直前の列へ戻す。書いていなければ何もしない。
    mutating func exit(restoring randomness: inout Randomness) {
        guard let mark = marks.popLast() else { return }
        if let mark { randomness = mark }
    }
}
