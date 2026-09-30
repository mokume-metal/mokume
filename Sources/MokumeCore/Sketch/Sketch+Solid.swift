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
    /// - Note: ``stroke(_:)`` の線は**形の稜線**に引かれる — 隣り合う面が折れている
    ///   ところと、平らな面の縁である。箱なら 12 本で、面を三角形に割った対角線は
    ///   出ない。線は既定で有効なので、塗りだけにするには ``noStroke()`` を書く。
    ///   ``noFill()`` にすれば線だけになる。どの立体も同じ規則で線を引く。
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
    ///     ![橙色の立方体が斜めから見えている。3 つの面がそれぞれ違う明るさで出ている](https://i.gyazo.com/16de32e9973ff80b5eaa17a58e44bb4e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=8d592c84
    public func box(_ size: some ScalarConvertible) {
        let size = size.asFloat
        canvas.box(size)
    }

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
    ///     ![横に長く薄い橙色の板。斜めから見えていて、奥行きが薄いことが分かる](https://i.gyazo.com/0588a94a6d38f7ce4172ec5d1b4fd8da.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=2553ebe3
    public func box(_ width: some ScalarConvertible, _ height: some ScalarConvertible, _ depth: some ScalarConvertible) {
        let (width, height, depth) = (width.asFloat, height.asFloat, depth.asFloat)
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
    ///     ![橙色の球。左上から光が当たり、右下へ向かって暗くなっている](https://i.gyazo.com/69de88632281c662fdafba189ca0a4be.png)
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
    ///     ![同じ大きさの立体だが、面が数えられるほど粗く、丸みが多角形になっている](https://i.gyazo.com/b262b226c71daafca7700f9e74e98cc1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 上下は半周なので、その半分で割る。
    ///     3〜128 で、外の値は近い端へ丸めて 1 度だけ知らせる。
    // shot: 1 snippet=51775b2d
    // shot: 2 snippet=3c04508e
    public func sphere(_ radius: some ScalarConvertible, detail: Int = Canvas.defaultSolidDetail) {
        let radius = radius.asFloat
        canvas.sphere(radius, detail: detail)
    }

    /// 楕円体を置く。**3 つの半径を軸ごとに決めた球**である。
    ///
    /// 3 つとも同じ値なら ``sphere(_:detail:)`` と同じ形になる。**半径は x・y・z の順**で、
    /// 縦軸は下向きなので 2 つ目が背の高さにあたる。下の 2 枚は同じ割り方で、半径だけを
    /// 振っている。
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
    ///     ellipsoid(60, 120, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 縦に長い橙色の卵形。左上から光が当たり、右下へ向かって暗くなっている -->
    ///     ![縦に長い橙色の卵形。左上から光が当たり、右下へ向かって暗くなっている](https://i.gyazo.com/ed09230aa66b5a13708c36fe4509184a.png)
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
    ///     ellipsoid(120, 45, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横に広がって上下に潰れた橙色の円盤状の立体。傾いているので上面が見えている -->
    ///     ![横に広がって上下に潰れた橙色の円盤状の立体。傾いているので上面が見えている](https://i.gyazo.com/8fffaadea937a0f24e543162fdebded7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 同じ形は ``push()`` / ``scale(_:_:_:)`` / ``sphere(_:detail:)`` / ``pop()``
    ///   でも作れるが、そちらは**置き場所の変換を動かす**ので、後続へ残さないよう
    ///   挟む必要がある。`ellipsoid` は形の側が半径を持つので変換は汚れない。
    ///
    /// - Parameters:
    ///   - x: 横の半径 (画素)。
    ///   - y: 縦の半径 (画素)。
    ///   - z: 奥行きの半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 球と同じく、上下は半周なのでその半分で割る。
    ///     3〜128 で、外の値は近い端へ丸めて 1 度だけ知らせる。
    // shot: 1 snippet=b469d265
    // shot: 2 snippet=44cb3b83
    public func ellipsoid(
        _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible,
        detail: Int = Canvas.defaultSolidDetail
    ) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        canvas.ellipsoid(x, y, z, detail: detail)
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
    ///     ![橙色の 1 枚の面。面が 1 つしか無いので明るさは一様で、傾きは輪郭が長方形でないことにだけ出ている](https://i.gyazo.com/f3565074d9cc413db891e1463ad9f0c0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3ddae47c
    public func plane(_ width: some ScalarConvertible, _ height: some ScalarConvertible) {
        let (width, height) = (width.asFloat, height.asFloat)
        canvas.plane(width, height)
    }

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
    ///     ![橙色の円柱が斜めに立っていて、上の蓋が楕円に見えている](https://i.gyazo.com/00aa98c83e26888558a5a9f262ad22ed.png)
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
    ///     ![同じ寸法だが一周が 6 つに割られ、六角柱になっている](https://i.gyazo.com/d65e2c43a97449f6f03acb06e30d7725.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    ///     3〜128 で、外の値は近い端へ丸めて 1 度だけ知らせる。
    // shot: 1 snippet=3382160f
    // shot: 2 snippet=14bac537
    public func cylinder(
        _ radius: some ScalarConvertible, _ height: some ScalarConvertible, detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, height) = (radius.asFloat, height.asFloat)
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
    ///     ![橙色の円錐が斜めに立っていて、先が上を向き、底の円が楕円に見えている](https://i.gyazo.com/86b7a741b4f3e995d32c0444607576a3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 底の半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    ///     3〜128 で、外の値は近い端へ丸めて 1 度だけ知らせる。
    // shot: 1 snippet=c6e05232
    public func cone(
        _ radius: some ScalarConvertible, _ height: some ScalarConvertible,
        detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, height) = (radius.asFloat, height.asFloat)
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
    ///     ![橙色の細い輪が斜めに傾いていて、中央に大きな穴が空いている](https://i.gyazo.com/b8ac374badeafb204e71b60c3c65e05f.png)
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
    ///     ![同じ大きさの輪だが管が太く、中央の穴が小さくなっている](https://i.gyazo.com/4b550f0b7e39a7d2023f4c3cc7f3ede5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 中心から管の中心までの距離 (画素)。
    ///   - tubeRadius: 管の半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 輪の一周も管の一周も同じ数で割る。
    ///     3〜128 で、外の値は近い端へ丸めて 1 度だけ知らせる。
    // shot: 1 snippet=7978e71b
    // shot: 2 snippet=21763f89
    public func torus(
        _ radius: some ScalarConvertible, _ tubeRadius: some ScalarConvertible, detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, tubeRadius) = (radius.asFloat, tubeRadius.asFloat)
        canvas.torus(radius, tubeRadius, detail: detail)
    }
}
