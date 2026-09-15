// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 進行を止める・戻す・1 枚だけ描き直す。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    /// 以後 ``draw()`` を呼ばない。
    ///
    /// ```swift
    /// func setup() {
    ///     noLoop()
    /// }
    ///
    /// func draw() {
    ///     background(0, 0, 0)
    ///     line(0, height / 2, width, height / 2)  // 1 度だけ描かれて止まる
    /// }
    /// ```
    ///
    /// **`setup()` で呼んでも、``draw()`` は 1 度だけ呼ばれる。** 何も描かないまま
    /// 止まると絵が出ないためで、手本と同じ振る舞いである。``draw()`` の中で呼べば、
    /// そのフレームを描き切ってから止まる。
    ///
    /// 止まっている間、絵は変わらない — フレーム番号も時刻も進まず、続けて書き出した
    /// 絵は同じバイト列になる。
    ///
    /// ## 止まっていても入力は届く
    ///
    /// ``mousePressed()`` などのコールバックは呼ばれ続ける。止めたスケッチを動かし直す
    /// ``loop()`` / ``redraw()`` は、ふつうそこから呼ぶ。
    ///
    /// ```swift
    /// func mousePressed() {
    ///     redraw()  // 押すたびに 1 枚だけ描き直す
    /// }
    /// ```
    ///
    /// ただし止まっている間のコールバックは**フレームの外**で呼ばれる。そこで置いた図形は
    /// 次に描くフレームまで出ず、``translate(_:_:)`` などの変換は効かない。描くのは
    /// ``draw()`` に任せる。
    ///
    /// ## 外からの停止とは別に持つ
    ///
    /// ホストが `SketchRuntime.pause()` / `resume()` で止めて再開しても、ここで止めた
    /// スケッチは止まったままである。理由は `SketchRuntime.resume()` の説明にある。
    public func noLoop() {
        guard let runtime = runningSketch else { return warnNotRunning("noLoop()") }
        runtime.noLoop()
    }

    /// ``noLoop()`` で止めた進行を戻す。回っている間に呼んでも何もしない。
    ///
    /// ```swift
    /// func mousePressed() {
    ///     loop()
    /// }
    /// ```
    ///
    /// 戻った後の最初の ``deltaTime`` に、止まっていた間の時間は乗らない。
    public func loop() {
        guard let runtime = runningSketch else { return warnNotRunning("loop()") }
        runtime.loop()
    }

    /// ``noLoop()`` で止めている間に、``draw()`` を 1 度だけ呼ぶよう頼む。
    ///
    /// 描かれるのは次のフレームで、何度呼んでも 1 度である。コールバックから呼んだ
    /// ときは、そのコールバックと同じフレームで描かれる。
    ///
    /// **回っている間と、``draw()`` の中では何もしない** — どちらも、頼まなくても
    /// 描かれている (または描いている最中の) フレームだからである。
    public func redraw() {
        guard let runtime = runningSketch else { return warnNotRunning("redraw()") }
        runtime.redraw()
    }

    private func warnNotRunning(_ call: String) {
        Diagnostics.warn("\(call): the sketch is not running, so there is nothing to control")
    }
}
