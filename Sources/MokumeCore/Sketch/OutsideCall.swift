// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// スケッチの呼び出しの外から頼まれて、断った口。**何を断ったか**を表す。
///
/// 進行の口 (``Sketch/noLoop()`` など) と書き出しの口 (``Sketch/save(_:)`` など) は、
/// ``runningSketch`` が差さっている間 — `setup()`・`draw()`・入力のコールバックの中 —
/// にしか頼めない。差すのは `SketchRuntime.withActiveRuntime(_:)` だけで、返れば外れる。
/// 中で起こした `Task` の中身が走るのはその後なので、そこからの頼みは必ずここへ来る。
///
/// **「走っていない」とは言わない** ([#1322])。かつての文面は「the sketch is not running」
/// で、`draw()` が回り続けている最中に `Task` から頼むとそれが出た。呼ぶ側は起動の失敗や
/// 終了を疑って、見当違いのところを探すことになる。ただし本当に走っていない場合
/// (`init` から・終わった後) とも見分けられないので、**どちらでも事実である
/// 「どこからなら受け付けるか」**を言う。
///
/// [#1322]: https://github.com/mokume-metal/mokume/issues/1322
enum OutsideCall: CaseIterable {
    case noLoop
    case loop
    case redraw
    case save
    case beginRecord
    case endRecord

    /// 言う中身。**6 通を完全な文として持つ** (ADR-0038 決定 3・``Canvas/OutsideFrame`` と同じ形)。
    ///
    /// 書き出しの 3 つは行き先 (`save("…")` の引数) を名乗らない。断る理由は呼んだ場所で、
    /// 行き先ではないためである。例に挙げるコールバックは、進行の口が `mousePressed()`
    /// (手本の Redraw / Loop の形)、書き出しの口が `keyPressed()` (キーで撮る形)。
    var notice: String {
        switch self {
        case .noLoop:
            "noLoop() is only accepted from inside setup(), draw() or an input callback such as "
                + "mousePressed(). This call was made from outside them, so it was ignored. A Task "
                + "started in one of them runs after it returns, and counts as outside"
        case .loop:
            "loop() is only accepted from inside setup(), draw() or an input callback such as "
                + "mousePressed(). This call was made from outside them, so it was ignored. A Task "
                + "started in one of them runs after it returns, and counts as outside"
        case .redraw:
            "redraw() is only accepted from inside setup(), draw() or an input callback such as "
                + "mousePressed(). This call was made from outside them, so it was ignored. A Task "
                + "started in one of them runs after it returns, and counts as outside"
        case .save:
            "save() is only accepted from inside setup(), draw() or an input callback such as "
                + "keyPressed(). This call was made from outside them, so nothing was saved. A Task "
                + "started in one of them runs after it returns, and counts as outside"
        case .beginRecord:
            "beginRecord() is only accepted from inside setup(), draw() or an input callback such "
                + "as keyPressed(). This call was made from outside them, so recording did not "
                + "start. A Task started in one of them runs after it returns, and counts as outside"
        case .endRecord:
            "endRecord() is only accepted from inside setup(), draw() or an input callback such as "
                + "keyPressed(). This call was made from outside them, so no recording was stopped. "
                + "A Task started in one of them runs after it returns, and counts as outside"
        }
    }
}
