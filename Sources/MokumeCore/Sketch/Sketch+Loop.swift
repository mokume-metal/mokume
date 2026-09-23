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
    /// ``loop()`` / ``redraw()`` は、そこから呼ぶ。
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
    /// ## 呼べる場所
    ///
    /// **進行の 3 つの口 (これと ``loop()`` / ``redraw()``) が効くのは、``setup()``・
    /// ``draw()``・入力のコールバックの中から呼んだときだけである。** それ以外の場所から
    /// 呼ぶと何もせず、そのことを標準エラーで知らせる。
    ///
    /// **そこで起こした `Task` の中も、外に数える。** `Task` の中身が走るのは起こした
    /// コールバックが返った後で、そのときにはもう呼び出しの中ではない。
    ///
    /// 待つ読み込みの口 (``requestImage(_:)`` など) は `Task` から呼べるが、あちらは
    /// 絵を描かず値を返すだけなので `Task` へ持ち越せる。進行の口は持ち越さない —
    /// `Task` から触れると、どのフレームが描き直されるかが `Task` に番が回る時機で
    /// 決まるためである。
    ///
    /// ## 外からの停止とは別に持つ
    ///
    /// ホストが `SketchRuntime.pause()` / `resume()` で止めて再開しても、ここで止めた
    /// スケッチは止まったままである。理由は `SketchRuntime.resume()` の説明にある。
    public func noLoop() {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.noLoop.notice)
        }
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
    ///
    /// **効くのは ``setup()``・``draw()``・入力のコールバックの中から呼んだときだけ**で、
    /// そこで起こした `Task` から呼んでも回り出さない (``noLoop()`` の「呼べる場所」)。
    public func loop() {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.loop.notice)
        }
        runtime.loop()
    }

    /// ``noLoop()`` で止めている間に、``draw()`` を 1 度だけ呼ぶよう頼む。
    ///
    /// 描かれるのは次のフレームで、何度呼んでも 1 度である。コールバックから呼んだ
    /// ときは、そのコールバックと同じフレームで描かれる。
    ///
    /// **回っている間と、``draw()`` の中では何もしない** — どちらも、頼まなくても
    /// 描かれている (または描いている最中の) フレームだからである。
    ///
    /// **効くのは ``setup()``・``draw()``・入力のコールバックの中から呼んだときだけ**で、
    /// そこで起こした `Task` から呼んでも描き直さない (``noLoop()`` の「呼べる場所」)。
    public func redraw() {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.redraw.notice)
        }
        runtime.redraw()
    }
}
