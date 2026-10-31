// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// `draw()` を始めた回数と、それがどの実行のものか ([#3588])。
///
/// 「次に描くフレームの頭で効く」を約束する値 (`MokumeGame` の `Scene`) が、**頼まれた時点で効くフレームを
/// 確定させる**ための目盛りである。読んだときに決める作りは、止めている間のコールバック・読まれないフレーム・
/// `Task` の中で、頼まれたフレームが割れた。
///
/// **数えるのは `draw()` を始めた回数で、``SketchPart/frameCount`` ではない。** ``SketchPart/frameCount`` は
/// 入力のコールバックと入り口の供給が走る前に進むので、そこで頼むと 1 枚遅れる。回数は `sketch.draw()` を呼ぶ
/// 直前に進むので、`draw()` の前に走るもの (入力のコールバック・供給・止めている間のコールバック・`Task`) が
/// 頼んだ切り替えは、直後の `draw()` で効く。`draw()` の中で頼んだものだけが、次の `draw()` で効く。
///
/// 実行の識別 (``run``) は、番号の大小ではなく同じ実行かどうかを見るためにある。新しい実行の最初の読みが
/// 前の回数以上でも、別の実行だと分かる。**同時に走る実行は 1 つ** (``SketchView`` の説明)。
///
/// [#3588]: https://github.com/mokume-metal/mokume/issues/3588
package struct DrawProgress: Sendable, Equatable {
    /// 実行の識別。実行を作るたびに 1 ずつ増える。0 は「実行がまだ 1 つも無い」。
    package let run: Int
    /// その実行が `draw()` を始めた回数。`setup()` と、最初の `draw()` の前は 0。
    package let draws: Int

    package init(run: Int, draws: Int) {
        self.run = run
        self.draws = draws
    }

    /// `draw()` を 1 つ始めた後の目盛り。
    func advanced() -> DrawProgress { DrawProgress(run: run, draws: draws + 1) }
}

/// いまの ``DrawProgress`` を、走っている実行の外 (`Task` の中・走る前) からも読むための窓口。
///
/// ``runningSketch`` は `setup()`・`draw()`・入力のコールバックが返ると外れる。外れた後に読まれても、
/// **最後に動いた実行の目盛り**を返す。実行は同時に 1 つなので、それが「いまの実行」である。
@MainActor
package enum DrawLedger {
    /// 最後に動いた実行の目盛り。実行が差さるたび、`draw()` を始めるたびに更新される。
    private(set) static var latest: DrawProgress?
    private static var runs = 0

    /// 走っている実行の中か (``runningSketch`` が差さっているか)。
    package static var isInsideRun: Bool { runningSketch != nil }

    /// いまの目盛り。走っていれば走っている実行の、外なら最後に動いた実行の。実行がまだ無ければ run 0・回数 0。
    package static var progress: DrawProgress {
        runningSketch?.drawProgress ?? latest ?? DrawProgress(run: 0, draws: 0)
    }

    /// 新しい実行の識別。
    static func nextRun() -> Int {
        runs += 1
        return runs
    }

    /// 実行が差さった・`draw()` を始めたことを控える。
    static func note(_ progress: DrawProgress) { latest = progress }
}
