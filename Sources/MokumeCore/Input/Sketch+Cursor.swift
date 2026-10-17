// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension SketchPart {
    /// 作品の面の上で、矢印のカーソルを隠す。
    ///
    /// 展示のように人が触らない窓で、絵に矢印が重なり続けるのを消す。手本 (Processing・p5.js) の
    /// `noCursor()` に当たる。全画面でも窓でも同じに働く:
    ///
    /// ```swift
    /// var settings: SketchSettings { .fullScreen(2) }
    ///
    /// func setup() { noCursor() }
    /// ```
    ///
    /// ## 隠れるのは、作品の面の上にあるあいだだけ
    ///
    /// 窓が前に出ていて、ポインタが**作品の面そのもの**の上にあるあいだ隠れる。窓の枠・別の窓・別の
    /// 画面へ出せば見える。`@Param` を宣言したときに重なるつまみ (``Sketch/params``) の上は面に
    /// 数えない — つまみを触るときは矢印が見える。``cursor()`` で戻る。
    ///
    /// 一度呼べば、``cursor()`` を呼ぶまで残る (`draw()` から毎フレーム呼び直す必要は無い)。
    ///
    /// ## ``requestPointerLock()`` と併せても食い違わない
    ///
    /// カーソルを捕まえる口 (``requestPointerLock()``) も矢印を隠す。2 つは別々に隠した分だけを
    /// 戻すので、`noCursor()` の後に `requestPointerLock()` → ``exitPointerLock()`` としても、
    /// 放した後の矢印は面の上で隠れたままである。逆に、捕まえている間に ``cursor()`` を呼んでも、
    /// 捕まえている間の隠しは外れない。
    ///
    /// ## 絵は変わらない
    ///
    /// 変わるのは窓の上のカーソルだけで、書き出す絵・フレームの状態には触れない
    /// (カーソルは絵の外にある)。
    ///
    /// ## 窓の無い実行では何もしない
    ///
    /// 窓を開かずに書き出す実行 (`mokume render`・参照スケッチの `--render`) や、窓を持たない
    /// `SketchRuntime` では、呼んでも何も起きず、止まりもしない。走っていないとき (`init` の中など)
    /// に呼んだときは、何もせず 1 度だけ警告する。
    ///
    /// ## 見張りの下では
    ///
    /// `mokume watch` の下では、作品の窓とプレビューのどちらの面の上でも隠れる。**窓は道具が持つ**
    /// ので、頼みは絵と一緒に道具の窓へ渡され、各窓は自分が映している世代のスケッチの頼みに従う。
    /// 保存で作り直したスケッチが `noCursor()` を呼ばなければ、そこで矢印が戻る。
    public func noCursor() {
        Self.liveRuntime()?.cursorHidingRequested = true
    }

    /// ``noCursor()`` で隠した矢印のカーソルを、作品の面の上でも見せる。
    ///
    /// 何も隠していないときに呼んでも、何も起きない。``requestPointerLock()`` で捕まえている間の
    /// 隠しは、これでは外れない (捕まえているあいだは隠れたまま)。窓の無い実行と、走っていない
    /// ときは何もしない。
    public func cursor() {
        Self.liveRuntime()?.cursorHidingRequested = false
    }
}
