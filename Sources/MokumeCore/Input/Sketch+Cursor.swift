// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension SketchPart {
    /// スケッチのキャンバスの上で、矢印のカーソルを隠す。
    ///
    /// 展示のように人が触らないウィンドウで、絵に矢印が重なり続けるのを消す。Processing・p5.js の
    /// `noCursor()` に当たる。全画面でもウィンドウでも同じに働く:
    ///
    /// ```swift
    /// var settings: SketchSettings { .fullScreen(2) }
    ///
    /// func setup() { noCursor() }
    /// ```
    ///
    /// ## 隠れるのは、スケッチのキャンバスの上にあるあいだだけ
    ///
    /// ウィンドウが前に出ていて、ポインタが**スケッチのキャンバスそのもの**の上にあるあいだ隠れる。ウィンドウの枠・別のウィンドウ・別の
    /// 画面へ出せば見える。`@Param` を宣言したときに重なるノブ (``Sketch/params``) の上はキャンバスに
    /// 数えない — コントロールを触るときは矢印が見える。``cursor()`` で戻る。
    ///
    /// 一度呼べば、``cursor()`` を呼ぶまで残る (`draw()` から毎フレーム呼び直す必要は無い)。
    ///
    /// ## ``requestPointerLock()`` と併せても食い違わない
    ///
    /// カーソルを捕まえる API (``requestPointerLock()``) も矢印を隠す。2 つは別々に隠した分だけを
    /// 戻すので、`noCursor()` の後に `requestPointerLock()` → ``exitPointerLock()`` としても、
    /// 放した後の矢印はキャンバスの上で隠れたままである。逆に、捕まえている間に ``cursor()`` を呼んでも、
    /// 捕まえている間の隠しは外れない。
    ///
    /// ## 絵は変わらない
    ///
    /// 変わるのはウィンドウの上のカーソルだけで、書き出す絵・フレームの状態には触れない
    /// (カーソルは絵の外にある)。
    ///
    /// ## ウィンドウの無い実行では何もしない
    ///
    /// ウィンドウを開かずに書き出す実行 (`mokume render`・参照スケッチの `--render`) や、ウィンドウを持たない
    /// `SketchRuntime` では、呼んでも何も起きず、止まりもしない。走っていないとき (`init` の中など)
    /// に呼んだときは、何もせず 1 度だけ警告する。
    ///
    /// ## `mokume watch` の下では
    ///
    /// `mokume watch` の下では、スケッチのウィンドウとプレビューのどちらのキャンバスの上でも隠れる。**ウィンドウは `mokume watch` が持つ**
    /// ので、リクエストはフレームと一緒に `mokume watch` のウィンドウへ渡され、各ウィンドウは自分が映しているプロセスのスケッチのリクエストに従う。
    /// 保存で作り直したスケッチが `noCursor()` を呼ばなければ、そこで矢印が戻る。
    public func noCursor() {
        liveRuntime()?.cursorHidingRequested = true
    }

    /// ``noCursor()`` で隠した矢印のカーソルを、スケッチのキャンバスの上でも見せる。
    ///
    /// 何も隠していないときに呼んでも、何も起きない。``requestPointerLock()`` で捕まえている間の
    /// 隠しは、これでは外れない (捕まえているあいだは隠れたまま)。ウィンドウの無い実行と、走っていない
    /// ときは何もしない。
    public func cursor() {
        liveRuntime()?.cursorHidingRequested = false
    }
}
