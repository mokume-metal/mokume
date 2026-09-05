// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、座標の変換。
extension Sketch {
    /// 原点をずらす。
    ///
    /// **図形の座標は変えない。** ずらすのは原点のほうで、同じ `square(0, 0, 80)` が
    /// 違う場所に出る。下の例はどれも同じ 1 行で四角を描いていて、違うのは前に呼ぶ
    /// ``translate(_:_:)`` だけである (薄い線が原点にいたときの位置)。
    ///
    /// 横だけずらす:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(40, 110, 80)
    ///     translate(150, 0)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     square(40, 110, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠だけの四角の右に、同じ大きさの橙色の四角が並んでいる | symmetric=y -->
    ///     ![灰色の枠だけの四角の右に、同じ大きさの橙色の四角が並んでいる](https://i.gyazo.com/6b7f66c9c1fd5934b194d5a77b8a1fc8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 縦だけずらす:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(160, 30, 80)
    ///     translate(0, 140)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     square(160, 30, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠だけの四角の下に、同じ大きさの水色の四角が並んでいる | symmetric=x -->
    ///     ![灰色の枠だけの四角の下に、同じ大きさの水色の四角が並んでいる](https://i.gyazo.com/238b97fd21f3e932dfb0abec4d5cf220.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **重ねて呼ぶと足し合わさる。** 2 度呼べば 2 度ぶんずれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 97, 115)
    ///     square(30, 30, 60)
    ///     translate(100, 70)
    ///     fill(140, 153, 178)
    ///     square(30, 30, 60)
    ///     translate(100, 70)
    ///     fill(242, 217, 89)
    ///     square(30, 30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰・薄い灰・黄の四角が、左上から右下へ等間隔の階段状に並んでいる -->
    ///     ![濃い灰・薄い灰・黄の四角が、左上から右下へ等間隔の階段状に並んでいる](https://i.gyazo.com/61c3d3f1b24a6fa55c228934a366d4bb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=e1676e34
    // shot: 2 snippet=0dab2481
    // shot: 3 snippet=58a41dae
    public func translate(_ x: Float, _ y: Float) { canvas.translate(x, y) }

    /// 回す。縦軸が下向きなので、正の角度は画面の上で時計回りに見える。
    ///
    /// **回る中心は原点である。** 図形の真ん中ではないので、原点から離れた図形を回すと
    /// 位置ごと動く。真ん中で回したいときは ``translate(_:_:)`` で原点を図形の
    /// 中心へ運んでから回す — 下の例はどれもそうしている (薄い枠が回す前の位置)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-60, -60, 120)
    ///     rotate(0.26)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     square(-60, -60, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、少しだけ時計回りに傾いた橙色の正方形が重なっている -->
    ///     ![灰色の枠の正方形に、少しだけ時計回りに傾いた橙色の正方形が重なっている](https://i.gyazo.com/1ba7f44dbc590ef606af6e97647a9610.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 45 度 (`0.79` ラジアン) 回すと、正方形は菱形に見える:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-60, -60, 120)
    ///     rotate(0.79)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     square(-60, -60, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形の上に、45 度傾いて菱形に見える水色の正方形が重なっている | symmetric=xy -->
    ///     ![灰色の枠の正方形の上に、45 度傾いて菱形に見える水色の正方形が重なっている](https://i.gyazo.com/91e1a80dd3096e71aa16c1587ffadfec.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **負の角度は反対向き** (画面の上で反時計回り):
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     rect(-90, -30, 180, 60)
    ///     rotate(-0.52)
    ///     noStroke()
    ///     fill(242, 217, 89)
    ///     rect(-90, -30, 180, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の灰色の枠に、左端が上がる向きに傾いた黄色の横長の四角が重なっている -->
    ///     ![横長の灰色の枠に、左端が上がる向きに傾いた黄色の横長の四角が重なっている](https://i.gyazo.com/da6b93c581407544fc09c4c76845aae8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=27bff880
    // shot: 2 snippet=00e07a33
    // shot: 3 snippet=8ea7daa7
    public func rotate(_ radians: Float) { canvas.rotate(radians) }

    /// 伸ばす・縮める。
    ///
    /// **基準は原点で、図形の中心ではない。** 倍率は軸ごとに別々に決まるので、片方だけ
    /// 渡せば片方だけ伸びる。下の例は原点を面の中央へ運んでから掛けている (薄い枠が
    /// 等倍のときの位置)。
    ///
    /// 横だけ 2 倍:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-45, -45, 90)
    ///     scale(2, 1)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形をまたいで、横に 2 倍伸びた橙色の長方形が重なっている | symmetric=xy -->
    ///     ![灰色の枠の正方形をまたいで、横に 2 倍伸びた橙色の長方形が重なっている](https://i.gyazo.com/1ab5ed147baaabe2437c3bdd0e13038e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 縦だけ半分:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-45, -45, 90)
    ///     scale(1, 0.5)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形の中に、縦が半分に潰れた水色の横長の四角が収まっている | symmetric=xy -->
    ///     ![灰色の枠の正方形の中に、縦が半分に潰れた水色の横長の四角が収まっている](https://i.gyazo.com/06b01ca7c797cf14e41a0ab56a6eadfe.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **線の太さも一緒に掛かる。** 掛けた後に引く線は、倍率のぶん太く (細く) 見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-45, -45, 90)
    ///     scale(1.6, 1.6)
    ///     stroke(242, 217, 89)
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 細い灰色の枠の正方形の外側に、一回り大きく線も太い黄色の枠の正方形がある | symmetric=xy -->
    ///     ![細い灰色の枠の正方形の外側に、一回り大きく線も太い黄色の枠の正方形がある](https://i.gyazo.com/56248ec967bb5061f49f3a581e03bd2c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=6b558fd6
    // shot: 2 snippet=2941aa4a
    // shot: 3 snippet=5ae25e26
    public func scale(_ x: Float, _ y: Float) { canvas.scale(x, y) }

    /// 原点を奥行きも含めてずらす。
    ///
    /// **奥行きは見ている側が正。** 正の値を渡すと手前へ、負の値を渡すと奥へ動く
    /// (手本のある向きに合わせてある)。
    ///
    /// **平面版との違いは、大きさが変わること。** 既定の視点は遠近が付くので、
    /// まったく同じ球でも手前に置いたほうが大きく見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, depth) in [Float(-110), 0, 80].enumerated() {
    ///         push()
    ///         translate(90 + Float(index) * 105, 150, depth)
    ///         sphere(28)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ半径の橙色の球が 3 つ。左から右へ、奥から手前へ置いてあり、右へ行くほど大きく見える -->
    ///     ![同じ半径の橙色の球が 3 つ。左から右へ、奥から手前へ置いてあり、右へ行くほど大きく見える](https://i.gyazo.com/7c4da0e9ed15bfc9959122a25a5e16b7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=ceef2b2d
    public func translate(_ x: Float, _ y: Float, _ z: Float) { canvas.translate(x, y, z) }

    /// 横軸まわりに回す。
    ///
    /// 縦軸が下向きなので、正の角度は**上の面が奥へ倒れる**向きに見える。
    /// 下の 3 段階は同じ板で、**縦が詰まっていく**。横幅は軸に沿っているので変わらない
    /// はずだが、傾いた板の上の辺が手前へ来るぶん**遠近で少しだけ広がる**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, angle) in [Float(0), 0.6, 1.2].enumerated() {
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         rotateX(angle)
    ///         box(100, 44, 8)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の横長の板が 3 つ。左から右へ、縦だけが詰まって奥へ倒れていく -->
    ///     ![橙色の横長の板が 3 つ。左から右へ、縦だけが詰まって奥へ倒れていく](https://i.gyazo.com/0b718b9946a4d0a2bd7ea3ea7650edf4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=54abaf07
    public func rotateX(_ radians: Float) { canvas.rotateX(radians) }

    /// 縦軸まわりに回す。
    ///
    /// 正の角度は、右の面が奥へ回る向きに見える。
    /// ``rotateX(_:)`` とまったく同じ板を同じ角度で回しているが、**詰まるのは横のほう**
    /// である。こちらも縦が遠近で少しだけ伸びる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, angle) in [Float(0), 0.6, 1.2].enumerated() {
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         rotateY(angle)
    ///         box(100, 44, 8)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ橙色の板が 3 つ。左から右へ、横だけが詰まって右の面が奥へ回っていく | symmetric=y -->
    ///     ![同じ橙色の板が 3 つ。左から右へ、横だけが詰まって右の面が奥へ回っていく](https://i.gyazo.com/7bbfaf01e374dbcb4ca4664b377a3fb1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=d031c80c
    public func rotateY(_ radians: Float) { canvas.rotateY(radians) }

    /// 奥行きの軸まわりに回す。``rotate(_:)`` と同じ。
    ///
    /// **こちらは画面の中で回るだけ** — 板が傾いても、こちらを向いた面が奥へ倒れない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, angle) in [Float(0), 0.6, 1.2].enumerated() {
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         rotateZ(angle)
    ///         box(100, 44, 8)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ橙色の板が 3 つ。左から右へ画面の中で傾いていくが、奥へは倒れない -->
    ///     ![同じ橙色の板が 3 つ。左から右へ画面の中で傾いていくが、奥へは倒れない](https://i.gyazo.com/021262387681ab64202dd35e05b95479.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=7f65053a
    public func rotateZ(_ radians: Float) { canvas.rotateZ(radians) }

    /// 奥行きも含めて伸ばす・縮める。
    ///
    /// **奥行きだけを伸ばした立体は、正面からでは分からない。** 下の 3 つは同じ場所・
    /// 同じ向きに置いてあり、変えたのは伸ばす軸だけ — 横へ伸ばすと横幅がそのまま倍に
    /// なるが、奥へ伸ばしたぶんは**回してある角度のぶんだけ**しか横幅に出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     push()
    ///     translate(200, 55, 0)
    ///     rotateY(0.35)
    ///     box(50)
    ///     pop()
    ///     push()
    ///     translate(200, 150, 0)
    ///     rotateY(0.35)
    ///     scale(2, 1, 1)
    ///     box(50)
    ///     pop()
    ///     push()
    ///     translate(200, 245, 0)
    ///     rotateY(0.35)
    ///     scale(1, 1, 2)
    ///     box(50)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の箱が縦に 3 つ。上は立方体、真ん中は横へ広く、下は奥へ伸びていて上より少しだけ広い -->
    ///     ![橙色の箱が縦に 3 つ。上は立方体、真ん中は横へ広く、下は奥へ伸びていて上より少しだけ広い](https://i.gyazo.com/1672ffc1b39a19db5c84caea42525d89.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=e3260042
    public func scale(_ x: Float, _ y: Float, _ z: Float) { canvas.scale(x, y, z) }

    /// 横方向へ斜めに歪める。
    ///
    /// **縦の辺だけが傾く。** 横の辺は水平のまま残るので、正方形は平行四辺形になる。
    /// ずれる量は原点からの縦の距離に比例するので、**正の角度では下の辺ほど右へ**動く
    /// (薄い枠が歪める前の位置)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearX(0.5)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、下辺が右へずれた橙色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、下辺が右へずれた橙色の平行四辺形が重なっている](https://i.gyazo.com/7d5ea847ced83942e0aa7a94d742d8eb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **負の角度は反対へ倒れる**:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearX(-0.5)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、下辺が左へずれた水色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、下辺が左へずれた水色の平行四辺形が重なっている](https://i.gyazo.com/3df067879805ccbc71ac945d4a4aa427.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=ecea4b47
    // shot: 2 snippet=1e816167
    public func shearX(_ radians: Float) { canvas.shearX(radians) }

    /// 縦方向へ斜めに歪める。
    ///
    /// ``shearX(_:)`` と軸が入れ替わる — **横の辺だけが傾き**、縦の辺は垂直のまま残る。
    /// ずれる量は原点からの横の距離に比例するので、**正の角度では右の辺ほど下へ**動く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearY(0.5)
    ///     noStroke()
    ///     fill(242, 217, 89)
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、右辺が下へずれた黄色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、右辺が下へずれた黄色の平行四辺形が重なっている](https://i.gyazo.com/f52d5f4d2c00bed5bccf11df5831479d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **負の角度は反対へ倒れる**:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearY(-0.5)
    ///     noStroke()
    ///     fill(140, 217, 140)
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、右辺が上へずれた緑色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、右辺が上へずれた緑色の平行四辺形が重なっている](https://i.gyazo.com/f57c9f495ec581e2ffb032b8c7ce4e0e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=e8584e7d
    // shot: 2 snippet=305667e2
    public func shearY(_ radians: Float) { canvas.shearY(radians) }
}
