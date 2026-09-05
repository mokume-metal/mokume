// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 立体。
extension Sketch {
    /// 立方体を置く。
    ///
    /// 中心は原点で、大きさは画素で数える。**何も指定しなければ画素の大きさで
    /// 見える** — 既定の視点は面がちょうど収まる位置に置いてあるので、`box(120)` は
    /// 120 画素の箱として出る。動かすには ``translate(_:_:_:)`` と ``rotateY(_:)``
    /// などを重ねる。
    ///
    /// ```swift
    /// func draw() {
    ///     background(20, 23, 31)
    ///     fill(242, 115, 76)
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     rotateY(0.6)
    ///     box(120)
    ///     pop()
    /// }
    /// ```
    ///
    /// - Note: 光を 1 つも置かなければ塗り 1 色で出る。立体らしく見せるには
    ///   ``lights()`` を `draw()` の中で呼ぶ。
    ///
    /// **面ごとに明るさが違う**ので、同じ塗り 1 色でも角が読める。下の絵はどれも
    /// ``lights()`` を置き、面のまん中へ運んでから斜めに回して見ている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     box(150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の立方体が斜めから見えている。3 つの面がそれぞれ違う明るさで出ている -->
    ///     ![橙色の立方体が斜めから見えている。3 つの面がそれぞれ違う明るさで出ている](https://i.gyazo.com/56a5f1c0d17a1ffbcb60318114ce1ebb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=8d592c84
    public func box(_ size: Float) { canvas.box(size) }

    /// 幅・高さ・奥行きを別々に決めた箱を置く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     box(230, 80, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横に長く薄い橙色の板。斜めから見えていて、奥行きが薄いことが分かる -->
    ///     ![横に長く薄い橙色の板。斜めから見えていて、奥行きが薄いことが分かる](https://i.gyazo.com/665028f152b9a87a181549c6754205ee.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=2553ebe3
    public func box(_ width: Float, _ height: Float, _ depth: Float) {
        canvas.box(width, height, depth)
    }

    /// 球を置く。
    ///
    /// **`detail` を落とすと面が見えてくる。** 下の 2 枚は同じ半径で、割り方だけを
    /// 変えている (既定は 24)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     sphere(110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球。左上から光が当たり、右下へ向かって暗くなっている -->
    ///     ![橙色の球。左上から光が当たり、右下へ向かって暗くなっている](https://i.gyazo.com/a41688b790f72b5f015bbd73914b8938.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     sphere(110, detail: 6)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの立体だが、面が数えられるほど粗く、丸みが多角形になっている -->
    ///     ![同じ大きさの立体だが、面が数えられるほど粗く、丸みが多角形になっている](https://i.gyazo.com/51cad4630b3a8e0811a5fa040d7da37e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 上下は半周なので、その半分で割る。
    // shot: 1 snippet=51775b2d
    // shot: 2 snippet=3c04508e
    public func sphere(_ radius: Float, detail: Int = Canvas.defaultSolidDetail) {
        canvas.sphere(radius, detail: detail)
    }

    /// 平らな面を置く。画面の側を向く。
    ///
    /// 奥行き 0 に置いた面は、同じ座標に描いた ``rect(_:_:_:_:)`` とぴったり重なる。
    /// **傾けると空間の中の 1 枚として見える** — 厚みは無いので、真横から見れば消える。
    /// 面が 1 つしか無いぶん**明るさは一様**になり、傾きは輪郭の形にだけ出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     plane(220, 160)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の 1 枚の面。面が 1 つしか無いので明るさは一様で、傾きは輪郭が長方形でないことにだけ出ている -->
    ///     ![橙色の 1 枚の面。面が 1 つしか無いので明るさは一様で、傾きは輪郭が長方形でないことにだけ出ている](https://i.gyazo.com/644b718dbb347e8337bb843acc8a84a6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3ddae47c
    public func plane(_ width: Float, _ height: Float) { canvas.plane(width, height) }

    /// 円柱を置く。軸は縦。
    ///
    /// こちらも `detail` を落とすと面が見えてくる。下の 2 枚は同じ寸法で、割り方だけを
    /// 変えている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     cylinder(80, 180)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円柱が斜めに立っていて、上の蓋が楕円に見えている -->
    ///     ![橙色の円柱が斜めに立っていて、上の蓋が楕円に見えている](https://i.gyazo.com/b54fc2f6740904ad8d6801766334053b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     cylinder(80, 180, detail: 6)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ寸法だが一周が 6 つに割られ、六角柱になっている -->
    ///     ![同じ寸法だが一周が 6 つに割られ、六角柱になっている](https://i.gyazo.com/faa3bb488c01c389af0fc11cbfaf8f4d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    // shot: 1 snippet=3382160f
    // shot: 2 snippet=14bac537
    public func cylinder(
        _ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail
    ) {
        canvas.cylinder(radius, height, detail: detail)
    }

    /// 円錐を置く。軸は縦で、先は上を向く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     cone(90, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円錐が斜めに立っていて、先が上を向き、底の円が楕円に見えている -->
    ///     ![橙色の円錐が斜めに立っていて、先が上を向き、底の円が楕円に見えている](https://i.gyazo.com/a4a2bab72baba4966ef53867169c51a4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 底の半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    // shot: 1 snippet=c6e05232
    public func cone(_ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail) {
        canvas.cone(radius, height, detail: detail)
    }

    /// 輪を置く。穴は画面の側を向く。
    ///
    /// **2 つの半径のうち、後ろが管の太さである。** 下の 2 枚は輪の大きさを変えずに、
    /// 管だけを太くしている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     torus(100, 20)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の細い輪が斜めに傾いていて、中央に大きな穴が空いている -->
    ///     ![橙色の細い輪が斜めに傾いていて、中央に大きな穴が空いている](https://i.gyazo.com/dcced26e4c6232faa9f9c2acdd4637eb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     torus(100, 50)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの輪だが管が太く、中央の穴が小さくなっている -->
    ///     ![同じ大きさの輪だが管が太く、中央の穴が小さくなっている](https://i.gyazo.com/130e20336fa72465415c533485985343.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 中心から管の中心までの距離 (画素)。
    ///   - tubeRadius: 管の半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 輪の一周も管の一周も同じ数で割る。
    // shot: 1 snippet=7978e71b
    // shot: 2 snippet=21763f89
    public func torus(
        _ radius: Float, _ tubeRadius: Float, detail: Int = Canvas.defaultSolidDetail
    ) {
        canvas.torus(radius, tubeRadius, detail: detail)
    }
}
