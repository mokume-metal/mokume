// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、曲線の制御点。
extension Sketch {
    /// 3 次の曲線で、いまの点から `x`・`y` まで繋ぐ。
    ///
    /// **2 つの制御点は通らない** — 曲線を引っぱる位置である。下の例では灰色の丸が
    /// 制御点で、細い線がどちらの端から引っぱっているかを示している。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(60, 250, 100, 40)
    ///     line(340, 220, 200, 90)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(100, 40, 12)
    ///     circle(200, 90, 12)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     vertex(60, 250)
    ///     bezierVertex(100, 40, 200, 90, 340, 220)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が左下から右下へ弧を描き、灰色の細い線が 2 つの制御点へ伸びている -->
    ///     ![橙色の曲線が左下から右下へ弧を描き、灰色の細い線が 2 つの制御点へ伸びている](https://i.gyazo.com/4aebe18f7d672ce9909b0f0433f4a44b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **繋げて呼べば、閉じた形も作れる。** 前の区間の終点が次の区間の始点になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     beginShape()
    ///     vertex(180, 50)
    ///     bezierVertex(340, 70, 320, 230, 210, 260)
    ///     bezierVertex(90, 230, 60, 110, 180, 50)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の、木の葉のようにふくらんだ閉じた形 -->
    ///     ![水色の、木の葉のようにふくらんだ閉じた形](https://i.gyazo.com/2f70a2339d3ed646904439376d90e4ea.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 手前に点が無いときは何もしない — 曲線は「いまの点から」繋ぐものなので、
    /// 始点が無ければ引きようがない。
    // shot: 1 snippet=0439d7b3
    // shot: 2 snippet=74fd9077
    public func bezierVertex(
        _ cx1: Float, _ cy1: Float, _ cx2: Float, _ cy2: Float, _ x: Float, _ y: Float
    ) {
        canvas.bezierVertex(cx1, cy1, cx2, cy2, x, y)
    }

    /// 2 次の曲線で、いまの点から `x`・`y` まで繋ぐ。
    ///
    /// **制御点は 1 つ。** ``bezierVertex(_:_:_:_:_:_:)`` より書くことが少ない代わりに、
    /// 両端で別々の曲がり方を与えることはできない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(60, 250, 260, 40)
    ///     line(340, 210, 260, 40)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(260, 40, 12)
    ///     noFill()
    ///     stroke(242, 217, 89)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     vertex(60, 250)
    ///     quadraticVertex(260, 40, 340, 210)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色の曲線が 1 つの制御点へ引き寄せられ、灰色の細い線が両端からその点へ伸びている -->
    ///     ![黄色の曲線が 1 つの制御点へ引き寄せられ、灰色の細い線が両端からその点へ伸びている](https://i.gyazo.com/6568a2ea60f2657f9040541f38cca68f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=03aa6a6a
    public func quadraticVertex(_ cx: Float, _ cy: Float, _ x: Float, _ y: Float) {
        canvas.quadraticVertex(cx, cy, x, y)
    }

    /// 通過点を結ぶ曲線の制御点を置く。
    ///
    /// **4 つ揃って初めて 1 区間が引ける。** 最初と最後の点は曲がり方を決めるためだけに
    /// 使われ、その間だけが描かれる。下の 4 点 (灰色の丸) で引かれるのは、真ん中の
    /// 2 点を結ぶ 1 区間だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の点が 4 つ散らばり、橙色の曲線は真ん中の 2 点の間にだけ引かれている -->
    ///     ![灰色の点が 4 つ散らばり、橙色の曲線は真ん中の 2 点の間にだけ引かれている](https://i.gyazo.com/3640f28b150b4326142e1d3c91fd9e85.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **端まで描きたいときは端の点を 2 度置く。** 点の位置は変えていない — 増やしたのは
    /// 「曲がり方を決めるためだけの点」のほうである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(89, 191, 242)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 4 点を通る水色の曲線が、左下の端から右上の端まで引かれている -->
    ///     ![同じ 4 点を通る水色の曲線が、左下の端から右上の端まで引かれている](https://i.gyazo.com/280c2c590340ab4bea27568dd270688a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=398e30fc
    // shot: 2 snippet=794ad9dd
    public func curveVertex(_ x: Float, _ y: Float) { canvas.curveVertex(x, y) }

    /// 曲線をいくつの直線で近似するか。
    ///
    /// **1 区間あたりの刻みの数**で、大きいほどなめらかになる (既定は 20)。
    /// ``bezierVertex(_:_:_:_:_:_:)`` / ``quadraticVertex(_:_:_:_:)`` / ``curveVertex(_:_:)``
    /// のどれにも効く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     curveDetail(2)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(242, 217, 89)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 刻みが粗く、黄色の曲線が数本の直線に折れて見える -->
    ///     ![刻みが粗く、黄色の曲線が数本の直線に折れて見える](https://i.gyazo.com/71287196821956aef25f3375c2bf47de.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     curveDetail(20)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(242, 217, 89)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 刻みが細かく、同じ黄色の曲線がなめらかな弧に見える -->
    ///     ![刻みが細かく、同じ黄色の曲線がなめらかな弧に見える](https://i.gyazo.com/8872d068b4236c5f8eb9347e3e99f91e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=73597f78
    // shot: 2 snippet=04b76040
    public func curveDetail(_ steps: Int) { canvas.curveDetail(steps) }

    /// 通過点を結ぶ曲線の張り具合。**0 が既定で、1 にすると点と点が直線で結ばれる。**
    ///
    /// 大きくするほど曲線は点の並び (折れ線) へ近づき、負にするほど**点と点の間での
    /// ふくらみが深くなる**。通る点は変わらない — 変わるのは間の通り方だけで、
    /// 負にしても通過点より外へは出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     curveTightness(-1)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が、点と点の間で既定よりも深くふくらんでいる -->
    ///     ![橙色の曲線が、点と点の間で既定よりも深くふくらんでいる](https://i.gyazo.com/590b35296709642ec563cce2f892b8aa.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     curveTightness(0)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が 4 つの点をなめらかに通っている (既定) -->
    ///     ![橙色の曲線が 4 つの点をなめらかに通っている (既定)](https://i.gyazo.com/26f4c0101556920ffba94dd1ff85d56a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     curveTightness(1)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の線が点と点を直線で結び、曲がりの無い折れ線になっている -->
    ///     ![橙色の線が点と点を直線で結び、曲がりの無い折れ線になっている](https://i.gyazo.com/7fee9a3b7726cc6749f5fd307659baf6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=37de9468
    // shot: 2 snippet=a33d48f9
    // shot: 3 snippet=6f809d80
    public func curveTightness(_ amount: Float) { canvas.curveTightness(amount) }
}
