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
    ///     push {
    ///         translate(x, y)
    ///         rotate(angle)
    ///         noStroke()
    ///         fill(255)
    ///         triangle(14, 0, -10, -8, -10, 8)
    ///     }
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
        guard let canvas = liveCanvas() else { return }
        let (x1, y1, x2, y2, x3, y3, x4, y4) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat, x4.asFloat, y4.asFloat)
        canvas.bezier(x1, y1, x2, y2, x3, y3, x4, y4)
    }

    /// 3 次の曲線を 1 本引く。始点・制御点 2 つ・終点を `Vector2` で、ラベルを付けて渡す。
    ///
    /// ``bezier(_:_:_:_:_:_:_:_:)`` に 4 つの点の成分を同じ順で渡すのと同じ曲線になる。塗り方・
    /// 形の組み立ての中での扱いもそちらと同じで、違うのは**どの点が端でどれが制御点かを呼び出しの
    /// 行で読める**ことだけである。
    ///
    /// ```swift
    /// // bezier(40, 200, 120, 40, 280, 40, 360, 200) と同じ曲線
    /// noFill()
    /// bezier(from: Vector2(40, 200), control1: Vector2(120, 40), control2: Vector2(280, 40), to: Vector2(360, 200))
    /// ```
    ///
    /// - Parameters:
    ///   - start: 始点。
    ///   - control1: 始点の側の制御点。
    ///   - control2: 終点の側の制御点。
    ///   - end: 終点。
    // shot: 参照 bezier(_:_:_:_:_:_:_:_:)
    public func bezier(from start: Vector2, control1: Vector2, control2: Vector2, to end: Vector2) {
        guard let canvas = liveCanvas() else { return }
        canvas.bezier(from: start, control1: control1, control2: control2, to: end)
    }

    /// 立体の空間に 3 次の曲線を 1 本引く。**視点と奥行きを通る。**
    ///
    /// 始点・制御点 2 つ・終点を、それぞれ `x, y, z` の順に渡す (`x1, y1, z1, …, x4, y4, z4`)。8 つの数の
    /// ``bezier(_:_:_:_:_:_:_:_:)`` も視点を通るが、平面の図形なので奥行きを読み書きしない。12 の数で書くと、
    /// 曲線を刻んだ点はどれも奥行きを持つ点になり、立体の線として ``camera(_:_:_:_:_:_:_:_:_:)`` や
    /// ``orbitControl(_:_:_:)`` の視点から見た位置に引かれる — 同じ名前で、引数の数によって変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 斜め上から見下ろす
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     // 2 つの制御点を奥へ引き、曲線が奥へふくらむ
    ///     bezier(80, 150, 60, 140, 150, -260, 260, 150, -260, 320, 150, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が手前の左右の端から、奥へ弧を描いてふくらんでいる -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``beginShape(_:)`` と ``vertex(_:_:_:)`` と ``bezierVertex(_:_:_:_:_:_:_:_:_:)`` と ``endShape(_:)`` を
    /// 順に呼んだのと**同じ絵**になる。線の色・太さ・端の形、``curveDetail(_:)`` の刻みも平面の曲線と同じに効く。
    /// 塗りの色が有効なら、始点と終点を結ばない開いた形のまま塗る。``beginShape(_:)`` と ``endShape(_:)`` の間で
    /// 呼んでも、組み立て中の形には点を足さず、その形と別の 1 本として引く。
    // shot: 後で撮る
    public func bezier(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ z1: some ScalarConvertible,
        _ x2: some ScalarConvertible, _ y2: some ScalarConvertible, _ z2: some ScalarConvertible,
        _ x3: some ScalarConvertible, _ y3: some ScalarConvertible, _ z3: some ScalarConvertible,
        _ x4: some ScalarConvertible, _ y4: some ScalarConvertible, _ z4: some ScalarConvertible
    ) {
        guard let canvas = liveCanvas() else { return }
        let (x1, y1, z1, x2, y2, z2) = (x1.asFloat, y1.asFloat, z1.asFloat, x2.asFloat, y2.asFloat, z2.asFloat)
        let (x3, y3, z3, x4, y4, z4) = (x3.asFloat, y3.asFloat, z3.asFloat, x4.asFloat, y4.asFloat, z4.asFloat)
        canvas.bezier(x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4)
    }

    /// 立体の空間に 3 次の曲線を 1 本引く。始点・制御点 2 つ・終点を `Vector3` で、ラベルを付けて渡す。
    ///
    /// 12 の数の ``bezier(_:_:_:_:_:_:_:_:_:_:_:_:)`` に 4 つの点の成分を同じ順で渡すのと同じ曲線になる。
    /// ラベルは平面の形 (`Vector2` を取る形) と同じである。
    ///
    /// ```swift
    /// // bezier(80, 150, 60, 140, 150, -260, 260, 150, -260, 320, 150, 60) と同じ曲線
    /// camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    /// noFill()
    /// bezier(
    ///     from: Vector3(80, 150, 60), control1: Vector3(140, 150, -260),
    ///     control2: Vector3(260, 150, -260), to: Vector3(320, 150, 60))
    /// ```
    ///
    /// - Parameters:
    ///   - start: 始点。
    ///   - control1: 始点の側の制御点。
    ///   - control2: 終点の側の制御点。
    ///   - end: 終点。
    // shot: 参照 bezier(_:_:_:_:_:_:_:_:_:_:_:_:)
    public func bezier(from start: Vector3, control1: Vector3, control2: Vector3, to end: Vector3) {
        guard let canvas = liveCanvas() else { return }
        canvas.bezier(from: start, control1: control1, control2: control2, to: end)
    }

    /// 通過点を結ぶ曲線の 1 区間を引く。
    ///
    /// **4 つの点を順に渡し (`x1, y1, x2, y2, x3, y3, x4, y4`)、引かれるのは 2 つ目から 3 つ目までの
    /// 1 区間だけである。** 1 つ目と 4 つ目の点は通らず、両端での曲がり方を決める。
    /// ``beginShape(_:)`` と ``curveVertex(_:_:)`` を同じ 4 点で 4 回と ``endShape(_:)`` を順に呼んだのと
    /// **同じ絵**になる — 線の太さ・色・端の形、``curveDetail(_:)`` の刻み、``curveTightness(_:)`` の
    /// 張りも同じに効く。3 つ以上の点を続けて通したいときは ``curveVertex(_:_:)`` を並べる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     circle(60, 230, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     curve(60, 230, 140, 80, 260, 220, 350, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が 2 つの灰色の点の間ではなく、その内側の 2 点の間に S 字を描いている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **曲線の上の点と、そこでの向きは ``curvePoint(_:_:_:_:_:)`` と ``curveTangent(_:_:_:_:_:)`` が
    /// 返す。** 同じ 4 点を、`x` と `y` に分けて渡す。
    ///
    /// 塗りの色が有効なら、``bezier(_:_:_:_:_:_:_:_:)`` と同じく、始点と終点を結ばない開いた形のまま塗る。
    /// 曲線だけを引きたいときは ``noFill()`` を呼ぶ。``beginShape(_:)`` と ``endShape(_:)`` の間で呼んでも、
    /// 組み立て中の形には点を足さず、その形と別の 1 本として引く。
    // shot: 後で撮る
    public func curve(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible,
        _ x3: some ScalarConvertible, _ y3: some ScalarConvertible, _ x4: some ScalarConvertible, _ y4: some ScalarConvertible
    ) {
        guard let canvas = liveCanvas() else { return }
        let (x1, y1, x2, y2, x3, y3, x4, y4) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat, x4.asFloat, y4.asFloat)
        canvas.curve(x1, y1, x2, y2, x3, y3, x4, y4)
    }

    /// 通過点を結ぶ曲線の 1 区間を `start` から `end` まで引く。4 つの点を `Vector2` で、ラベルを付けて渡す。
    ///
    /// **`control1` は `start` の手前、`control2` は `end` の先にある点**で、どちらも通らずに両端での
    /// 曲がり方を決める。``curve(_:_:_:_:_:_:_:_:)`` に `control1`・`start`・`end`・`control2` の成分を
    /// この順で渡すのと同じ曲線になる。並べる順が位置引数の形と違うのは、ラベルの綴りを
    /// ``bezier(from:control1:control2:to:)-(Vector2,_,_,_)`` に揃え、描く区間の両端を `from:`・`to:` で読めるようにしたからである。
    ///
    /// ```swift
    /// // curve(60, 230, 140, 80, 260, 220, 350, 60) と同じ曲線
    /// noFill()
    /// curve(from: Vector2(140, 80), control1: Vector2(60, 230), control2: Vector2(350, 60), to: Vector2(260, 220))
    /// ```
    ///
    /// - Parameters:
    ///   - start: 描く区間の始点。
    ///   - control1: 始点の手前の点。曲線はここを通らない。
    ///   - control2: 終点の先の点。曲線はここを通らない。
    ///   - end: 描く区間の終点。
    // shot: 参照 curve(_:_:_:_:_:_:_:_:)
    public func curve(from start: Vector2, control1: Vector2, control2: Vector2, to end: Vector2) {
        guard let canvas = liveCanvas() else { return }
        canvas.curve(from: start, control1: control1, control2: control2, to: end)
    }

    /// 立体の空間に、通過点を結ぶ曲線の 1 区間を引く。**視点と奥行きを通る。**
    ///
    /// 4 つの点を、それぞれ `x, y, z` の順に渡す (`x1, y1, z1, …, x4, y4, z4`)。引かれるのは 8 つの数の
    /// ``curve(_:_:_:_:_:_:_:_:)`` と同じく 2 つ目から 3 つ目までの 1 区間で、1 つ目と 4 つ目の点は通らない。
    /// 8 つの数の形は平面の図形で奥行きを読み書きしないが、12 の数で書くと、刻んだ点はどれも奥行きを持つ
    /// 点になり、立体の線として視点から見た位置に引かれる — 同じ名前で、引数の数によって変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     // 4 つの点 (灰色)。曲線は両端の 2 つを通らない
    ///     stroke(89, 97, 115)
    ///     strokeWeight(12)
    ///     point(60, 40, 100)
    ///     point(100, 150, 60)
    ///     point(300, 150, -200)
    ///     point(340, 260, -100)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     curve(60, 40, 100, 100, 150, 60, 300, 150, -200, 340, 260, -100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 4 つの灰色の点のうち、内側の 2 点の間にだけ、手前の左下から奥の右上へ橙色の曲線が引かれている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``beginShape(_:)`` と ``curveVertex(_:_:_:)`` を同じ 4 点で 4 回と ``endShape(_:)`` を順に呼んだのと
    /// **同じ絵**になる — ``curveDetail(_:)`` の刻み、``curveTightness(_:)`` の張りも同じに効く。塗り方・
    /// 組み立て中の形の中での扱いは 8 つの数の形と同じである。
    // shot: 後で撮る
    public func curve(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ z1: some ScalarConvertible,
        _ x2: some ScalarConvertible, _ y2: some ScalarConvertible, _ z2: some ScalarConvertible,
        _ x3: some ScalarConvertible, _ y3: some ScalarConvertible, _ z3: some ScalarConvertible,
        _ x4: some ScalarConvertible, _ y4: some ScalarConvertible, _ z4: some ScalarConvertible
    ) {
        guard let canvas = liveCanvas() else { return }
        let (x1, y1, z1, x2, y2, z2) = (x1.asFloat, y1.asFloat, z1.asFloat, x2.asFloat, y2.asFloat, z2.asFloat)
        let (x3, y3, z3, x4, y4, z4) = (x3.asFloat, y3.asFloat, z3.asFloat, x4.asFloat, y4.asFloat, z4.asFloat)
        canvas.curve(x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4)
    }

    /// 立体の空間に、通過点を結ぶ曲線の 1 区間を `start` から `end` まで引く。4 つの点を `Vector3` で、
    /// ラベルを付けて渡す。
    ///
    /// ラベルと並びは平面の形 (`Vector2` を取る形) と同じで、**`control1` は `start` の手前、`control2` は
    /// `end` の先にある点**である。12 の数の ``curve(_:_:_:_:_:_:_:_:_:_:_:_:)`` に `control1`・`start`・`end`・
    /// `control2` の成分をこの順で渡すのと同じ曲線になる。
    ///
    /// ```swift
    /// // curve(60, 40, 100, 100, 150, 60, 300, 150, -200, 340, 260, -100) と同じ曲線
    /// camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    /// noFill()
    /// curve(
    ///     from: Vector3(100, 150, 60), control1: Vector3(60, 40, 100),
    ///     control2: Vector3(340, 260, -100), to: Vector3(300, 150, -200))
    /// ```
    ///
    /// - Parameters:
    ///   - start: 描く区間の始点。
    ///   - control1: 始点の手前の点。曲線はここを通らない。
    ///   - control2: 終点の先の点。曲線はここを通らない。
    ///   - end: 描く区間の終点。
    // shot: 参照 curve(_:_:_:_:_:_:_:_:_:_:_:_:)
    public func curve(from start: Vector3, control1: Vector3, control2: Vector3, to end: Vector3) {
        guard let canvas = liveCanvas() else { return }
        canvas.curve(from: start, control1: control1, control2: control2, to: end)
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
        guard let canvas = liveCanvas() else { return }
        let (cx1, cy1, cx2, cy2, x, y) = (cx1.asFloat, cy1.asFloat, cx2.asFloat, cy2.asFloat, x.asFloat, y.asFloat)
        canvas.bezierVertex(cx1, cy1, cx2, cy2, x, y)
    }

    /// 3 次の曲線で、いまの点から `end` まで繋ぐ。制御点 2 つと終点を `Vector2` で、ラベルを付けて渡す。
    ///
    /// ``bezierVertex(_:_:_:_:_:_:)`` に 3 つの点の成分を同じ順で渡すのと同じ形になる。始点が無いとき・
    /// 形の外で呼んだときの扱いもそちらと同じで、違うのは**どの点が制御点でどれが終点かを呼び出しの
    /// 行で読める**ことだけである。
    ///
    /// ```swift
    /// // bezierVertex(100, 40, 200, 90, 340, 220) と同じ形
    /// beginShape()
    /// vertex(60, 250)
    /// bezierVertex(control1: Vector2(100, 40), control2: Vector2(200, 90), to: Vector2(340, 220))
    /// endShape()
    /// ```
    ///
    /// - Parameters:
    ///   - control1: いまの点の側の制御点。
    ///   - control2: 終点の側の制御点。
    ///   - end: 終点。次の区間の始点になる。
    // shot: 参照 bezierVertex(_:_:_:_:_:_:)
    public func bezierVertex(control1: Vector2, control2: Vector2, to end: Vector2) {
        guard let canvas = liveCanvas() else { return }
        canvas.bezierVertex(control1: control1, control2: control2, to: end)
    }

    /// 奥行きを持つ 3 次の曲線で、いまの点から `x`・`y`・`z` まで繋ぐ。**視点と奥行きを通る。**
    ///
    /// 制御点 2 つと終点を、それぞれ `x, y, z` の順に渡す (`cx1, cy1, cz1, cx2, cy2, cz2, x, y, z`)。6 つの数の
    /// ``bezierVertex(_:_:_:_:_:_:)`` は平面の点を刻むが、9 つの数で書くと、刻んだ点はどれも
    /// ``vertex(_:_:_:)`` で置いたのと同じ奥行きを持つ点になり、形は立体として視点から見た位置に描かれる
    /// — 同じ名前で、引数の数によって変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     noFill()
    ///     stroke(89, 191, 242)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     vertex(80, 150, 0)
    ///     // 奥へふくらみ、手前へ戻る
    ///     bezierVertex(120, 150, -240, 280, 150, -240, 320, 150, 0)
    ///     // 続けて手前へふくらむ
    ///     bezierVertex(320, 150, 120, 80, 150, 120, 80, 150, 0)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の線が奥と手前へふくらみ、斜め上から見た輪のような閉じた線になっている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 始点は手前に置いた点で、平面の点 (``vertex(_:_:)`` で置いた点) なら `z` を 0 として読む —
    /// ``vertex(_:_:)`` と ``vertex(_:_:_:)`` を 1 つの形に混ぜたときと同じ読み方である。刻み (``curveDetail(_:)``)・
    /// 手前に点が無いときの扱い・``curveVertex(_:_:)`` の並びを切ることは、6 つの数の形と同じ。
    // shot: 後で撮る
    public func bezierVertex(
        _ cx1: some ScalarConvertible, _ cy1: some ScalarConvertible, _ cz1: some ScalarConvertible,
        _ cx2: some ScalarConvertible, _ cy2: some ScalarConvertible, _ cz2: some ScalarConvertible,
        _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        guard let canvas = liveCanvas() else { return }
        let (cx1, cy1, cz1) = (cx1.asFloat, cy1.asFloat, cz1.asFloat)
        let (cx2, cy2, cz2) = (cx2.asFloat, cy2.asFloat, cz2.asFloat)
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        canvas.bezierVertex(cx1, cy1, cz1, cx2, cy2, cz2, x, y, z)
    }

    /// 奥行きを持つ 3 次の曲線で、いまの点から `end` まで繋ぐ。制御点 2 つと終点を `Vector3` で、ラベルを付けて渡す。
    ///
    /// 9 つの数の ``bezierVertex(_:_:_:_:_:_:_:_:_:)`` に 3 つの点の成分を同じ順で渡すのと同じ形になる。
    /// ラベルは平面の形 (`Vector2` を取る形) と同じである。
    ///
    /// ```swift
    /// // bezierVertex(120, 150, -240, 280, 150, -240, 320, 150, 0) と同じ形
    /// beginShape()
    /// vertex(80, 150, 0)
    /// bezierVertex(control1: Vector3(120, 150, -240), control2: Vector3(280, 150, -240), to: Vector3(320, 150, 0))
    /// endShape()
    /// ```
    ///
    /// - Parameters:
    ///   - control1: いまの点の側の制御点。
    ///   - control2: 終点の側の制御点。
    ///   - end: 終点。次の区間の始点になる。
    // shot: 参照 bezierVertex(_:_:_:_:_:_:_:_:_:)
    public func bezierVertex(control1: Vector3, control2: Vector3, to end: Vector3) {
        guard let canvas = liveCanvas() else { return }
        canvas.bezierVertex(control1: control1, control2: control2, to: end)
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
        guard let canvas = liveCanvas() else { return }
        let (cx, cy, x, y) = (cx.asFloat, cy.asFloat, x.asFloat, y.asFloat)
        canvas.quadraticVertex(cx, cy, x, y)
    }

    /// 2 次の曲線で、いまの点から `end` まで繋ぐ。制御点と終点を `Vector2` で、ラベルを付けて渡す。
    ///
    /// ``quadraticVertex(_:_:_:_:)`` に 2 つの点の成分を同じ順で渡すのと同じ形になる。始点が無いとき・
    /// 形の外で呼んだときの扱いもそちらと同じで、違うのは**どの点が制御点でどれが終点かを呼び出しの
    /// 行で読める**ことだけである。
    ///
    /// ```swift
    /// beginShape()
    /// vertex(60, 250)
    /// quadraticVertex(control: Vector2(200, 30), to: Vector2(340, 250))
    /// endShape()
    /// ```
    ///
    /// - Parameters:
    ///   - control: 制御点。
    ///   - end: 終点。次の区間の始点になる。
    // shot: 参照 quadraticVertex(_:_:_:_:)
    public func quadraticVertex(control: Vector2, to end: Vector2) {
        guard let canvas = liveCanvas() else { return }
        canvas.quadraticVertex(control: control, to: end)
    }

    /// 奥行きを持つ 2 次の曲線で、いまの点から `x`・`y`・`z` まで繋ぐ。**視点と奥行きを通る。**
    ///
    /// 制御点と終点を、それぞれ `x, y, z` の順に渡す (`cx, cy, cz, x, y, z`)。4 つの数の
    /// ``quadraticVertex(_:_:_:_:)`` は平面の点を刻むが、6 つの数で書くと、刻んだ点はどれも
    /// ``vertex(_:_:_:)`` で置いたのと同じ奥行きを持つ点になる — 同じ名前で、引数の数によって変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     noFill()
    ///     stroke(242, 217, 89)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     vertex(80, 150, 60)
    ///     // 制御点を奥へ置き、奥へ引き寄せる
    ///     quadraticVertex(200, 150, -300, 320, 150, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色の曲線が手前の左右の端から、奥に置いた 1 つの制御点へ引き寄せられて弧を描いている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 始点の読み方・刻み・手前に点が無いときの扱いは、9 つの数の ``bezierVertex(_:_:_:_:_:_:_:_:_:)`` と同じ。
    // shot: 後で撮る
    public func quadraticVertex(
        _ cx: some ScalarConvertible, _ cy: some ScalarConvertible, _ cz: some ScalarConvertible,
        _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        guard let canvas = liveCanvas() else { return }
        let (cx, cy, cz, x, y, z) = (cx.asFloat, cy.asFloat, cz.asFloat, x.asFloat, y.asFloat, z.asFloat)
        canvas.quadraticVertex(cx, cy, cz, x, y, z)
    }

    /// 奥行きを持つ 2 次の曲線で、いまの点から `end` まで繋ぐ。制御点と終点を `Vector3` で、ラベルを付けて渡す。
    ///
    /// 6 つの数の ``quadraticVertex(_:_:_:_:_:_:)`` に 2 つの点の成分を同じ順で渡すのと同じ形になる。
    /// ラベルは平面の形 (`Vector2` を取る形) と同じである。
    ///
    /// ```swift
    /// beginShape()
    /// vertex(80, 150, 60)
    /// quadraticVertex(control: Vector3(200, 150, -300), to: Vector3(320, 150, 60))
    /// endShape()
    /// ```
    ///
    /// - Parameters:
    ///   - control: 制御点。
    ///   - end: 終点。次の区間の始点になる。
    // shot: 参照 quadraticVertex(_:_:_:_:_:_:)
    public func quadraticVertex(control: Vector3, to end: Vector3) {
        guard let canvas = liveCanvas() else { return }
        canvas.quadraticVertex(control: control, to: end)
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
        guard let canvas = liveCanvas() else { return }
        let (x, y) = (x.asFloat, y.asFloat)
        canvas.curveVertex(x, y)
    }

    /// 奥行きを持つ通過点を置く。**視点と奥行きを通る。**
    ///
    /// 2 つの数の ``curveVertex(_:_:)`` と同じく 4 つ揃って初めて 1 区間が引け、並びは `curveVertex` を続けて
    /// 呼んでいる間だけ続く。3 つの数で書くと、刻んだ点はどれも ``vertex(_:_:_:)`` で置いたのと同じ奥行きを持つ
    /// 点になり、形は立体として視点から見た位置に描かれる — 同じ名前で、引数の数によって変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 150, 100)
    ///     curveVertex(60, 150, 100)
    ///     curveVertex(160, 150, -150)
    ///     curveVertex(240, 150, 60)
    ///     curveVertex(340, 150, -200)
    ///     curveVertex(340, 150, -200)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が手前と奥を行き来しながら、左から右へ折り返して通っている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **平面の点と混ぜてよい。** 1 区間の 4 点に奥行きを持つ点が 1 つでもあれば、平面の点 (2 つの数で置いた点)
    /// を `z` が 0 の点として読む — ``vertex(_:_:)`` と ``vertex(_:_:_:)`` を 1 つの形に混ぜたときと同じ読み方である。
    /// 4 点がどれも平面の点なら、これまでどおり平面の曲線として刻む。
    // shot: 後で撮る
    public func curveVertex(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        guard let canvas = liveCanvas() else { return }
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        canvas.curveVertex(x, y, z)
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
    public func curveDetail(_ steps: Int) { liveCanvas()?.curveDetail(steps) }

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
        guard let canvas = liveCanvas() else { return }
        let amount = amount.asFloat
        canvas.curveTightness(amount)
    }

    /// 通過点を結ぶ曲線の上の点を、1 つの軸について返す。
    ///
    /// 下の例は、``curve(_:_:_:_:_:_:_:_:)`` で引いた区間の上の `t` が 0.4 の所に、``curveTangent(_:_:_:_:_:)``
    /// で求めた進む向きへ頭を向けた三角形を置いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(18, 20, 26)
    ///     noFill()
    ///     stroke(120)
    ///     strokeWeight(2)
    ///     curve(60, 230, 140, 80, 260, 220, 350, 60)
    ///     let t: Float = 0.4
    ///     let x = curvePoint(60, 140, 260, 350, t)
    ///     let y = curvePoint(230, 80, 220, 60, t)
    ///     let angle = atan2(curveTangent(230, 80, 220, 60, t), curveTangent(60, 140, 260, 350, t))
    ///     push {
    ///         translate(x, y)
    ///         rotate(angle)
    ///         noStroke()
    ///         fill(255)
    ///         triangle(14, 0, -10, -8, -10, 8)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の細い曲線が左上から右下へ弧を描き、その途中に白い小さな三角形が曲線の向きへ頭を向けて乗っている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 引数は手本と同じ並びで、``curve(_:_:_:_:_:_:_:_:)`` に渡す 4 つの点の 1 つの軸の値 (`a, b, c, d`) と、
    /// 曲線の上の位置 `t` である。平面の曲線なら、`x` の 4 つと `y` の 4 つで 2 回呼ぶ。
    /// **`t` が 0 なら `b` (2 つ目の点)、1 なら `c` (3 つ目の点) がちょうど返る** — 描かれる区間の両端である。
    /// `curvePoint(60, 140, 260, 350, 0)` は 140 を返す。
    ///
    /// **いまの張り (``curveTightness(_:)``) を読む** (Processing と同じ)。だから ``bezierPoint(_:_:_:_:_:)``
    /// と違って、スケッチのメソッドである。`curveTightness(1)` の後なら点と点を直線で結んだ上の値になり、
    /// `curvePoint(60, 140, 260, 350, 0.5)` は真ん中の 200 を返す。`createGraphics(_:_:)` で作った描画先の
    /// 張りで読むときは、その描画先の `curvePoint` を呼ぶ。
    ///
    /// **`t` は曲線の長さの割合ではなく、0…1 の外は締めずに曲線を延ばす** (``bezierPoint(_:_:_:_:_:)`` と同じ)。
    /// 数でない値・無限の値が混じったときは `b` を返し (`b` も数でないときは 0)、注意は 1 度だけ言う。
    /// `setup()`・`draw()`・入力のコールバックの外 (部品の `init()` など) で呼ぶと、張りを読む先が無いので、
    /// 1 度だけ知らせて既定の張り 0 で求めた値を返す。
    // shot: 後で撮る
    public func curvePoint(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ t: some ScalarConvertible
    ) -> Float {
        guard let canvas = liveCanvas(.read(returning: "the value at the default curve tightness 0")) else {
            return curvePointValue(a.asFloat, b.asFloat, c.asFloat, d.asFloat, t.asFloat, tightness: 0)
        }
        return canvas.curvePoint(a, b, c, d, t)
    }

    /// 通過点を結ぶ曲線の、1 つの軸についての傾き (`t` で微分した値) を返す。
    ///
    /// ```swift
    /// // 曲線 curve(60, 230, 140, 80, 260, 220, 350, 60) の上で、進む向きへ頭を向ける
    /// let t: Float = 0.5
    /// let angle = atan2(curveTangent(230, 80, 220, 60, t), curveTangent(60, 140, 260, 350, t))
    /// rotate(angle)
    /// ```
    ///
    /// 引数は ``curvePoint(_:_:_:_:_:)`` と同じ。**`x` の傾きと `y` の傾きを別々に求め、
    /// `atan2(y の傾き, x の傾き)` で向きにする。** 返るのは向きではなく `t` を 1 進めたときの進み量で、
    /// 張りも ``curvePoint(_:_:_:_:_:)`` と同じく、いまの ``curveTightness(_:)`` を読む。張りが 0 なら、
    /// 区間の始点 (`t` が 0) での傾きは `(c - a) / 2` になる。
    ///
    /// **0…1 の外は締めない。** 数でない値・無限の値が混じったときは 0 を返し、注意は 1 度だけ言う。
    /// `setup()`・`draw()`・入力のコールバックの外で呼ぶと、1 度だけ知らせて既定の張り 0 で求めた値を返す。
    // shot: 参照 curvePoint(_:_:_:_:_:)
    public func curveTangent(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ t: some ScalarConvertible
    ) -> Float {
        guard let canvas = liveCanvas(.read(returning: "the value at the default curve tightness 0")) else {
            return curveTangentValue(a.asFloat, b.asFloat, c.asFloat, d.asFloat, t.asFloat, tightness: 0)
        }
        return canvas.curveTangent(a, b, c, d, t)
    }
}
