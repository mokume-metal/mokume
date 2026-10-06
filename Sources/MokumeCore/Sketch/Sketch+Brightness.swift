// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 明るさを画面へ写す。
extension Sketch {
    /// 画面全体の明るさの倍率。既定は `1`。
    ///
    /// **画面の性質なので、材質や光と違ってフレームを越える** — 一度書けば書き換える
    /// まで残る。効くのは**画面から出て行く絵すべて**で、窓に出る絵と書き出した絵の
    /// 両方に同じだけ掛かる。``loadPixels()`` で読む画素には掛からない (そちらは
    /// 写す前の作業空間そのものである)。描く色は変えない。
    ///
    /// 下は同じ白い球を、光を正面から受けた面が `1.5` (白を越える明るさ) になるように
    /// 照らし、倍率だけ変えて 3 枚描いたもの。**倍率を上げるほど、一様な白に飛ぶところが
    /// 広がる** (球のうち、なし → 半分ほど → 8 割ほど)。掛かるのは画面全体なので、陰の側も
    /// 下地も倍率どおりに明るくなる (陰の側は線形の値で 0.05 → 0.1 → 0.2)。
    ///
    /// `0.5` では白を越えていた明るさも範囲へ戻り、いちばん明るいところまで明暗が残る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     func setup() {
    ///         exposure(0.5)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         ambientLight(.linear(red: 0.1, green: 0.1, blue: 0.1))
    ///         directionalLight(.linear(red: 1.4, green: 1.4, blue: 1.4), -0.4, 0.5, -0.6)
    ///         fill(255)
    ///         noStroke()
    ///         translate(200, 150, 0)
    ///         sphere(100, detail: 64)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い球が 1 つ。下地も球も暗めに写り、いちばん明るい右上も白に届かず、左下から右上までなだらかに明るくなる -->
    ///     ![白い球が 1 つ。下地も球も暗めに写り、いちばん明るい右上も白に届かず、左下から右上までなだらかに明るくなる](https://i.gyazo.com/464ddd2df23abf99e47b7e721c9a28df.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `1` (既定) では、右上の半分ほどが一様な白に飛ぶ。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     func setup() {
    ///         exposure(1)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         ambientLight(.linear(red: 0.1, green: 0.1, blue: 0.1))
    ///         directionalLight(.linear(red: 1.4, green: 1.4, blue: 1.4), -0.4, 0.5, -0.6)
    ///         fill(255)
    ///         noStroke()
    ///         translate(200, 150, 0)
    ///         sphere(100, detail: 64)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い球が 1 つ。右上の半分ほどが一様な白に飛び、明暗は左下の側にだけ残る -->
    ///     ![白い球が 1 つ。右上の半分ほどが一様な白に飛び、明暗は左下の側にだけ残る](https://i.gyazo.com/6ed25039ca04ab191f84a667d8212d48.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `2` では、白に飛ぶところが球の 8 割ほどまで広がる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     func setup() {
    ///         exposure(2)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         ambientLight(.linear(red: 0.1, green: 0.1, blue: 0.1))
    ///         directionalLight(.linear(red: 1.4, green: 1.4, blue: 1.4), -0.4, 0.5, -0.6)
    ///         fill(255)
    ///         noStroke()
    ///         translate(200, 150, 0)
    ///         sphere(100, detail: 64)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い球が 1 つ。球の 8 割ほどが一様な白に飛び、明暗は左下の縁に沿った三日月にだけ残る。下地も明るい -->
    ///     ![白い球が 1 つ。球の 8 割ほどが一様な白に飛び、明暗は左下の縁に沿った三日月にだけ残る。下地も明るい](https://i.gyazo.com/57cdbf98c5caccbdca8c5188913020f0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a7caa890
    // shot: 2 snippet=64e28a7d
    // shot: 3 snippet=47e0d876
    public func exposure(_ multiplier: some ScalarConvertible) {
        let multiplier = multiplier.asFloat
        canvas.exposure(multiplier)
    }

    /// 表示できる範囲を超えた明るさの丸め方。既定は ``ToneMapping/clip``。
    ///
    /// 既定では**範囲の内側の明るさを 1 ビットも変えない** — `0.5` と書いた色が
    /// 指定どおりの明るさで出る。その代わり、範囲を超えたところは端で切れるので、
    /// 強い艶や明るい光が一様な白い塊になる。``ToneMapping/roll`` を選ぶと、
    /// 明るいところがなめらかに範囲へ収まる代わりに、`0.8` より明るいところが
    /// 指定より少し暗く出る。
    ///
    /// 下は ``exposure(_:)`` の倍率 `1` の絵と同じ球を、丸め方だけ変えて 2 枚描いたもの。
    /// ``ToneMapping/clip`` の絵は、あちらの倍率 `1` の絵と画素まで同じになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     func setup() {
    ///         toneMapping(.clip)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         ambientLight(.linear(red: 0.1, green: 0.1, blue: 0.1))
    ///         directionalLight(.linear(red: 1.4, green: 1.4, blue: 1.4), -0.4, 0.5, -0.6)
    ///         fill(255)
    ///         noStroke()
    ///         translate(200, 150, 0)
    ///         sphere(100, detail: 64)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い球が 1 つ。右上の半分ほどが 1 色の白い塊になり、その中には明暗が無い -->
    ///     ![白い球が 1 つ。右上の半分ほどが 1 色の白い塊になり、その中には明暗が無い](https://i.gyazo.com/6ed25039ca04ab191f84a667d8212d48.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ToneMapping/roll`` では白に届く画素が無くなり、上の絵で白に飛んでいたところにも、
    /// 右上へ向かって明るくなる階調が残る。`0.8` より暗いところ (球の左下の側) は、上の絵と
    /// 画素まで同じである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     func setup() {
    ///         toneMapping(.roll)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         ambientLight(.linear(red: 0.1, green: 0.1, blue: 0.1))
    ///         directionalLight(.linear(red: 1.4, green: 1.4, blue: 1.4), -0.4, 0.5, -0.6)
    ///         fill(255)
    ///         noStroke()
    ///         translate(200, 150, 0)
    ///         sphere(100, detail: 64)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い球が 1 つ。白に届くところが無く、左下から右上までなだらかに明るくなり続ける -->
    ///     ![白い球が 1 つ。白に届くところが無く、左下から右上までなだらかに明るくなり続ける](https://i.gyazo.com/f12dd16b1ca1134e810b973d35044226.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: ``exposure(_:)`` と同じく**画面の性質**で、フレームを越える。
    // shot: 1 snippet=26a7b873
    // shot: 2 snippet=f52b49c4
    public func toneMapping(_ mode: ToneMapping) { canvas.toneMapping(mode) }
}
