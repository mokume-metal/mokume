// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 明るさを画面へ写す。
extension Sketch {
    /// 画面全体の明るさの倍率。既定は `1`。
    ///
    /// **画面の性質なので、材質や光と違ってフレームを越える** — 一度書けば書き換える
    /// まで残る。効くのは**画面から出て行く絵すべて**で、窓に出る絵と書き出した絵の
    /// 両方に同じだけ掛かる。``loadPixels()`` で読む画素には掛からない (そちらは
    /// 写す前の作業空間そのものである)。
    ///
    /// ```swift
    /// func setup() {
    ///     exposure(1.6)   // 全体を明るく写す。描く色は変えない
    /// }
    /// ```
    public func exposure(_ multiplier: Float) { canvas.exposure(multiplier) }

    /// 表示できる範囲を超えた明るさの丸め方。既定は ``ToneMapping/clip``。
    ///
    /// 既定では**範囲の内側の明るさを 1 ビットも変えない** — `0.5` と書いた色が
    /// 指定どおりの明るさで出る。その代わり、範囲を超えたところは端で切れるので、
    /// 強い艶や明るい光が一様な白い塊になる。``ToneMapping/roll`` を選ぶと、
    /// 明るいところがなめらかに範囲へ収まる代わりに、`0.8` より明るいところが
    /// 指定より少し暗く出る。
    ///
    /// - Note: ``exposure(_:)`` と同じく**画面の性質**で、フレームを越える。
    public func toneMapping(_ mode: ToneMapping) { canvas.toneMapping(mode) }
}
