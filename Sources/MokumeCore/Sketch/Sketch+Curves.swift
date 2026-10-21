// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、曲線の制御点。
extension SketchPart {
    /// 3 次の曲線を 1 本引く。
    ///
    /// **始点・制御点 2 つ・終点を、この順に渡す** (`x1, y1, x2, y2, x3, y3, x4, y4`)。制御点
    /// (2 つ目と 3 つ目) は通らず、曲線を引っぱる位置になる。1 本で済ませたいときの口で、
    /// ``beginShape(_:)`` と ``vertex(_:_:)`` と ``bezierVertex(_:_:_:_:_:_:)`` と ``endShape(_:)``
    /// を順に呼んだのと**同じ絵**になる — 線の太さ・色・端の形、``curveDetail(_:)`` の刻みも同じである。
    /// 曲線を繋げたり、ほかの点と混ぜて 1 つの形にしたいときは、``bezierVertex(_:_:_:_:_:_:)`` を使う。
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
    ///     bezier(60, 250, 100, 40, 200, 90, 340, 220)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が左下から右下へ弧を描き、灰色の細い線が 2 つの制御点へ伸びている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **曲線の上の点と、そこでの向きは ``bezierPoint(_:_:_:_:_:)`` と
    /// ``bezierTangent(_:_:_:_:_:)`` が返す。** 同じ 4 点を渡して、`x` と `y` を別々に読む。
    /// 曲線に沿って物を動かすときは、式を自分で展開せずにこの 2 つを使う。下の例は、
    /// 紙飛行機が始点から終点までの割合 `t` が 0.6 の所で、進む向きへ頭を向けている (`t` は 0 で始点、1 で終点で、曲線の長さの割合ではない)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(18, 20, 26)
    ///     noFill()
    ///     stroke(120)
    ///     bezier(60, 420, 260, 60, 640, 600, 900, 160)
    ///     let t: Float = 0.6
    ///     let x = bezierPoint(60, 260, 640, 900, t)
    ///     let y = bezierPoint(420, 60, 600, 160, t)
    ///     let angle = atan2(bezierTangent(420, 60, 600, 160, t), bezierTangent(60, 260, 640, 900, t))
    ///     push()
    ///     translate(x, y)
    ///     rotate(angle)
    ///     noStroke()
    ///     fill(255)
    ///     triangle(14, 0, -10, -8, -10, 8)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の細い曲線が左下から右上へ S 字に伸び、その上に白い小さな三角形が曲線の向きへ頭を向けて乗っている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 塗りの色が有効なら、手本と同じく、始点と終点を結ばない開いた形のまま塗る。曲線だけを
    /// 引きたいときは ``noFill()`` を呼ぶ。``beginShape(_:)`` と ``endShape(_:)`` の間で呼んでも、
    /// 組み立て中の形には点を足さず、その形と別の 1 本として引く。
    // shot: 後で撮る
    public func bezier(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible,
        _ x3: some ScalarConvertible, _ y3: some ScalarConvertible, _ x4: some ScalarConvertible, _ y4: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x1, y1, x2, y2, x3, y3, x4, y4) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat, x4.asFloat, y4.asFloat)
        canvas.bezier(x1, y1, x2, y2, x3, y3, x4, y4)
    }

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
    ///     ![橙色の曲線が左下から右下へ弧を描き、灰色の細い線が 2 つの制御点へ伸びている](https://i.gyazo.com/8a5460d54759da1fc0e18fcfb77fee43.png)
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
    ///     ![水色の、木の葉のようにふくらんだ閉じた形](https://i.gyazo.com/da4538c0ccbca62b1dee799af9c52cbf.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 手前に点が無いときは何もしない — 曲線は「いまの点から」繋ぐものなので、
    /// 始点が無ければ引きようがない。
    // shot: 1 snippet=0439d7b3
    // shot: 2 snippet=74fd9077
    public func bezierVertex(
        _ cx1: some ScalarConvertible, _ cy1: some ScalarConvertible, _ cx2: some ScalarConvertible, _ cy2: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (cx1, cy1, cx2, cy2, x, y) = (cx1.asFloat, cy1.asFloat, cx2.asFloat, cy2.asFloat, x.asFloat, y.asFloat)
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
    ///     ![黄色の曲線が 1 つの制御点へ引き寄せられ、灰色の細い線が両端からその点へ伸びている](https://i.gyazo.com/310a9d70f01cb35a28faedfa2c4b8fc6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=03aa6a6a
    public func quadraticVertex(_ cx: some ScalarConvertible, _ cy: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (cx, cy, x, y) = (cx.asFloat, cy.asFloat, x.asFloat, y.asFloat)
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
    ///     ![灰色の点が 4 つ散らばり、橙色の曲線は真ん中の 2 点の間にだけ引かれている](https://i.gyazo.com/b0dd6cfa6094c41d29fe328081a74c4b.png)
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
    ///     ![同じ 4 点を通る水色の曲線が、左下の端から右上の端まで引かれている](https://i.gyazo.com/9bf5b3d7afbf9be64520c51289452550.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **並びは `curveVertex` を続けて呼んでいる間だけ続く。** 次の呼び出しで切れ、
    /// それまでに置いた点は曲がり方を決めるのに使われなくなる — 次の区間は、また 4 つ
    /// 揃ってから引かれる:
    ///
    /// - 点を置く別の呼び出し: ``vertex(_:_:)`` / ``bezierVertex(_:_:_:_:_:_:)`` /
    ///   ``quadraticVertex(_:_:_:_:)``
    /// - 穴の境目: ``beginContour()`` / ``endContour()``
    ///
    /// 切れた後の並びも、最初の区間は 2 つ目に置いた点から描かれる。手前の点からその点までは
    /// 直線で繋がる (``vertex(_:_:)`` の後に置いたのと同じ)。
    ///
    /// **穴の中の曲線は、外周と独立に始まる。** 穴の中で最初に引かれる区間は、穴の中で
    /// 置いた点だけで決まり、形の中で最初に引かれる区間と同じくその始点 (2 つ目に置いた点)
    /// から描かれる。穴を閉じた後に外周へ置く `curveVertex` も、穴の点を引き継がない。
    // shot: 1 snippet=398e30fc
    // shot: 2 snippet=794ad9dd
    public func curveVertex(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x, y) = (x.asFloat, y.asFloat)
        canvas.curveVertex(x, y)
    }

    /// 曲線をいくつの直線で近似するか。
    ///
    /// **1 区間あたりの刻みの数**で、大きいほどなめらかになる (既定は 20)。
    /// ``bezierVertex(_:_:_:_:_:_:)`` / ``quadraticVertex(_:_:_:_:)`` / ``curveVertex(_:_:)``
    /// のどれにも効く。
    ///
    /// 刻みの数は 1…1024。範囲の外は端へ丸め、1 度だけ知らせる — 0 以下は 1 (区間を 1 本の
    /// 直線で結ぶ)、1024 を越える値は 1024 として刻む。上の端は、手が滑って大きな値を渡しても
    /// 点を作り続けてフレームが戻らなくならないためのもので、円・楕円・弧の一周の分割の上限と
    /// 同じ数にしてある。
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
    ///     ![刻みが粗く、黄色の曲線が数本の直線に折れて見える](https://i.gyazo.com/86f681d0bfd3513dcda3cc20a81f5b04.png)
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
    ///     ![刻みが細かく、同じ黄色の曲線がなめらかな弧に見える](https://i.gyazo.com/c836357e59633ec5e6efdb06dc128e6e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=73597f78
    // shot: 2 snippet=04b76040
    public func curveDetail(_ steps: Int) { Self.liveCanvas()?.curveDetail(steps) }

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
    ///     ![橙色の曲線が、点と点の間で既定よりも深くふくらんでいる](https://i.gyazo.com/661b1092f045a19eaa3c1095d6fa1ed5.png)
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
    ///     ![橙色の曲線が 4 つの点をなめらかに通っている (既定)](https://i.gyazo.com/da9335c289414c8f00a580fc98451842.png)
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
    ///     ![橙色の線が点と点を直線で結び、曲がりの無い折れ線になっている](https://i.gyazo.com/d4884d2919dae64ebab3f8775a41f772.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=37de9468
    // shot: 2 snippet=a33d48f9
    // shot: 3 snippet=6f809d80
    public func curveTightness(_ amount: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let amount = amount.asFloat
        canvas.curveTightness(amount)
    }
}
