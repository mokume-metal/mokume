// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 描画を止めずに、時刻だけを止める・再開する・飛ぶ ([#1286])。**説明文の正本はこちら**
// ([ADR-0020] 決定 4)。
//
// 手本 (Processing / p5) の本体には無い口で、同義の手本は Processing Video の
// `Movie.pause()` / `play()` / `jump()` である。`Sketch` の上で裸の `pause()` / `play()` は
// 描画を止める・音を鳴らすと読み違えるので、手本の動詞に対象の `Time` を付けた
// (ADR-0020 決定 1 — 手本の無いものは Swift の慣行に従う)。
//
// [#1286]: https://github.com/mokume-metal/mokume/issues/1286
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    /// 次のフレームから、``time`` を止める。**描画は止めない** — ``draw()`` は回り続け、
    /// ``frameCount`` も進む。
    ///
    /// 絵を ``time`` の関数として書いておけば、再生位置を自分の変数で持たずに、止める・
    /// 飛ぶ・擦ることができる。物差し (秒か拍か) と操作は作品の側で決める。
    ///
    /// ```swift
    /// var paused = false
    /// let acts: [Float] = [0, 2.0, 6.5, 11.0]  // 幕の頭 (秒)
    ///
    /// func draw() {
    ///     background(0)
    ///     circle(width / 2 + sin(time) * 200, height / 2, 40)  // time だけを読む
    /// }
    ///
    /// func keyPressed() {
    ///     switch keyCode {
    ///     case .space:
    ///         paused.toggle()
    ///         if paused { pauseTime() } else { playTime() }
    ///     case .arrowLeft: jumpTime(time - 0.25)
    ///     case .arrowRight: jumpTime(time + 0.25)
    ///     case .digit1: jumpTime(acts[0])
    ///     case .digit2: jumpTime(acts[1])
    ///     default: break
    ///     }
    /// }
    ///
    /// func mouseDragged(deltaX: Float, deltaY: Float) {
    ///     jumpTime(mouseX / width * 12)  // 横位置を 0–12 秒に写して擦る
    /// }
    /// ```
    ///
    /// 止めている間の ``time`` は、**呼んだフレームの値のまま**で、``deltaTime`` は 0 である。
    /// ``deltaTime`` で積んで動かすものも、時刻と一緒に止まる。``playTime()`` で再開すると、
    /// 止めた秒から続ける (止めていた間の実時間へ跳ね戻らない)。既に止めていれば何もしない。
    ///
    /// ## ``noLoop()`` との違い
    ///
    /// ``noLoop()`` は ``draw()`` ごと止める。こちらは時刻だけを止め、描画と入力は回り続ける —
    /// 止めた絵の上で擦る UI を動かせる。
    ///
    /// ## 書き出しと作り直し
    ///
    /// 固定の fps で書き出している最中 (`mokume render`) も効く。書き出す枚数は変わらず、
    /// 止めている間の枚は同じ ``time`` の絵が並ぶ。
    ///
    /// **作り直し (watch の世代の乗り換え) をまたいで、止めた秒や飛んだ先は運ばない。**
    /// 作り直した後も同じ位置で見たいなら、``setup()`` で ``jumpTime(_:)`` を呼ぶ。
    ///
    /// ## 呼べる場所
    ///
    /// 進行の口 (``noLoop()`` の「呼べる場所」) と同じで、``setup()``・``draw()``・入力の
    /// コールバックの中から呼んだときだけ効く。それ以外の場所から呼ぶと何もせず、そのことを
    /// 標準エラーで知らせる。
    // shot: 撮れない 時刻の進み方を変える口で、1 枚の絵では違いが出ない
    public func pauseTime() {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.pauseTime.notice)
        }
        runtime.pauseTime()
    }

    /// ``pauseTime()`` で止めた ``time`` を、次のフレームから進め直す。
    ///
    /// ```swift
    /// func mouseReleased() {
    ///     playTime()
    /// }
    /// ```
    ///
    /// 再開した最初の 1 枚の ``time`` は、**止めた秒から 1 フレームぶん**進んだ値である
    /// (止めていた間の実時間は乗らない)。``deltaTime`` もふつうの 1 枚ぶんに戻る。
    /// 止めていなければ何もしない。呼べる場所は ``pauseTime()`` と同じ。
    // shot: 撮れない 時刻の進み方を変える口で、1 枚の絵では違いが出ない
    public func playTime() {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.playTime.notice)
        }
        runtime.playTime()
    }

    /// 次のフレームの ``time`` を `seconds` 秒にする。
    ///
    /// ```swift
    /// func keyPressed() {
    ///     if keyCode == .digit0 { jumpTime(0) }  // 頭へ戻る
    /// }
    /// ```
    ///
    /// 飛んだ枚の ``deltaTime`` は 0 で、次の枚からは `seconds` から元の刻みで進む。
    /// ``pauseTime()`` で止めている間なら、`seconds` で止まり続ける。同じフレームで何度
    /// 呼んでも、効くのは最後の 1 回である。負の秒も受ける。
    ///
    /// 描いている最中のフレームの ``time`` は変えない — 1 枚の中で時刻が 2 つあると、
    /// 前半と後半で違う時刻の絵が混ざる。呼べる場所は ``pauseTime()`` と同じ。
    // shot: 撮れない 時刻の進み方を変える口で、1 枚の絵では違いが出ない
    public func jumpTime(_ seconds: Float) {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.jumpTime.notice)
        }
        runtime.jumpTime(seconds)
    }
}
