// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 光。
extension Sketch {
    /// 全体を底上げする光を置く。向きを持たないので、どの面も同じだけ明るくなる。
    ///
    /// **色そのものが明るさの倍率**である。`1.0` は「その光を正面から受けた白い面が
    /// 白として出る」明るさで、それより明るい光は 1 を超える色で書く
    /// (`.linear(red: 2, green: 2, blue: 2)`)。強さを表す別の数は持たない。
    ///
    /// **向きを持たないので、丸いものも丸く見えない。** 下は同じ球を、底上げの光の
    /// 明るさだけ変えて 3 つ描いたもの — どれも塗り 1 色の円板で、変わるのは明るさ
    /// だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, level) in [Float(0.15), 0.4, 0.9].enumerated() {
    ///         noLights()
    ///         ambientLight(.linear(red: level, green: level, blue: level))
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円が 3 つ。左から右へ明るくなるが、どれも陰影が無く塗りつぶした円板に見える | symmetric=y -->
    ///     ![橙色の円が 3 つ。左から右へ明るくなるが、どれも陰影が無く塗りつぶした円板に見える](https://i.gyazo.com/971b738c795d1905e28fd7c6c5d174bd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。初期化の
    ///   ときに置いた光はどのフレームにも属さないので、警告して無視される。
    // shot: 1 snippet=5e98096a
    public func ambientLight(_ color: LinearRGBA) { canvas.ambientLight(color) }

    /// 向きだけを持つ光を置く (無限に遠くから差す光)。
    ///
    /// 渡すのは**光が進む向き**である。縦軸は下向きなので、`(0, 1, 0)` が真上から
    /// 差す光になる。斜めの成分を入れると、陰の境目が左右どちらかへ寄る。
    ///
    /// 下は同じ球を、光が進む向きだけ変えて 3 つ描いたもの。**明るくなるのは光が
    /// 入ってくる側**である — 右へ進む光 `(1, …)` は球の左側を、下へ進む光 `(…, 1, …)`
    /// は上側を照らす。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     let ways: [(Float, Float, Float)] = [(1, 0.25, -0.3), (0, 1, -0.3), (-1, -1, -0.3)]
    ///     for (index, way) in ways.enumerated() {
    ///         noLights()
    ///         ambientLight(.linear(red: 0.12, green: 0.12, blue: 0.12))
    ///         directionalLight(.linear(red: 0.95, green: 0.95, blue: 0.95), way.0, way.1, way.2)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。明るい側が左・上・右下と移り、反対側が暗く落ちている -->
    ///     ![橙色の球が 3 つ。明るい側が左・上・右下と移り、反対側が暗く落ちている](https://i.gyazo.com/0e2db7dd10c5fe0a5902f8304dec7eb6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=97d91466
    public func directionalLight(_ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float) {
        canvas.directionalLight(color, x, y, z)
    }

    /// 位置を持つ光を置く。面から光源へ向かう向きで明るさが決まる。
    ///
    /// **平行光と違い、当たり方が場所によって変わる。** 下は平らな面 1 枚を、左上に
    /// 置いた光で照らしたもの — いちばん明るいのは光源の真下で、そこから四方へ
    /// なだらかに暗くなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     ambientLight(.linear(red: 0.12, green: 0.12, blue: 0.12))
    ///     // 面より手前 (z = 160) の、左上に置く
    ///     pointLight(.linear(red: 1.1, green: 1.1, blue: 1.1), 110, 90, 160)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の面。左上が最も明るく、右下へ向かってなだらかに暗くなっている -->
    ///     ![橙色の面。左上が最も明るく、右下へ向かってなだらかに暗くなっている](https://i.gyazo.com/2062f8a8326572d835d52626245b33ee.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=ebd428d6
    public func pointLight(_ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float) {
        canvas.pointLight(color, x, y, z)
    }

    /// 位置と向きと広がりを持つ光を置く。広がりの外へは当たらない。
    ///
    /// - Parameters:
    ///   - color: 光の色 (明るさの倍率を兼ねる)。
    ///   - x: 光源の位置。
    ///   - y: 光源の位置。
    ///   - z: 光源の位置。
    ///   - directionX: 光が進む向き。
    ///   - directionY: 光が進む向き。
    ///   - directionZ: 光が進む向き。
    ///   - angle: 広がりの半分の角 (ラジアン)。
    ///
    /// 下の 2 枚は同じ面を、同じ位置・同じ向きの光で照らしている。**違うのは広がりの
    /// 角だけ**で、当たる輪の大きさがそれについて変わる。輪の外は底上げの光しか
    /// 届かないので暗いままである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     ambientLight(.linear(red: 0.12, green: 0.12, blue: 0.12))
    ///     // 狭い光 (半分の角 15 度)
    ///     spotLight(
    ///         .linear(red: 1.2, green: 1.2, blue: 1.2),
    ///         160, 120, 200,
    ///         0, 0, -1,
    ///         angle: .pi / 12)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 暗い橙色の面の左上寄りに、明るい小さな円が浮かんでいる -->
    ///     ![暗い橙色の面の左上寄りに、明るい小さな円が浮かんでいる](https://i.gyazo.com/321061ddff57f0145fd76203e114f530.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     ambientLight(.linear(red: 0.12, green: 0.12, blue: 0.12))
    ///     // 広い光 (半分の角 25.7 度)
    ///     spotLight(
    ///         .linear(red: 1.2, green: 1.2, blue: 1.2),
    ///         160, 120, 200,
    ///         0, 0, -1,
    ///         angle: .pi / 7)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ面の同じ場所だが、明るい円がひとまわり以上大きく広がっている -->
    ///     ![同じ面の同じ場所だが、明るい円がひとまわり以上大きく広がっている](https://i.gyazo.com/d878e17cf6be30fff494b806fb03b894.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=983fe8fa
    // shot: 2 snippet=86fdc61c
    public func spotLight(
        _ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float,
        _ directionX: Float, _ directionY: Float, _ directionZ: Float,
        angle: Float = .pi / 6
    ) {
        canvas.spotLight(color, x, y, z, directionX, directionY, directionZ, angle: angle)
    }

    /// ひととおりの光を置く — 底上げの光と、斜め上から差す光。
    ///
    /// 立体を「とりあえず立体らしく」見せるための組み合わせ。細かく決めたくなったら
    /// ``ambientLight(_:)-fvb5`` と ``directionalLight(_:_:_:_:)`` を自分で並べる。
    ///
    /// **中身は絵で確かめられる。** 下は左から、底上げの光だけ・斜め上から差す光だけ・
    /// ``lights()`` の 3 つ。3 つ目には前の 2 つが両方出ている — **暗い側は 1 つ目と
    /// 同じ明るさで止まり** (底上げの光がそこまでは持ち上げる)、明るい側には 2 つ目と
    /// 同じ向きの傾きが出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     // ① 底上げの光だけ
    ///     ambientLight(.linear(red: 0.35, green: 0.35, blue: 0.35))
    ///     push()
    ///     translate(70, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     // ② 斜め上から差す光だけ
    ///     noLights()
    ///     directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.35, 0.75, -0.55)
    ///     push()
    ///     translate(200, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     // ③ lights() = ① と ②
    ///     noLights()
    ///     lights()
    ///     push()
    ///     translate(330, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左は陰影の無い円板、中央は右下が黒く落ちた球、右はその 2 つを重ねたように暗い側も残った球 -->
    ///     ![橙色の球が 3 つ。左は陰影の無い円板、中央は右下が黒く落ちた球、右はその 2 つを重ねたように暗い側も残った球](https://i.gyazo.com/32875bdcdbe626d723c0fc0e95f5f9d0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=44052481
    public func lights() { canvas.lights() }

    /// 置いた光をすべて取り除く。以降の立体は塗り 1 色で描かれる。
    ///
    /// **効くのはこれより後に置いたものだけ。** 光を取り除くと列がその場で閉じるので、
    /// 既に置いた立体は光が当たったまま残る。下は同じ球を、取り除く前と後に 1 つずつ
    /// 描いたものである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     lights()
    ///     push()
    ///     translate(120, 150, 0)
    ///     sphere(70)
    ///     pop()
    ///     // ここから先は塗り 1 色になる
    ///     noLights()
    ///     push()
    ///     translate(280, 150, 0)
    ///     sphere(70)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左は陰影の付いた橙色の球、右は同じ大きさだが影も艶も無い、のっぺりした橙色の円 -->
    ///     ![左は陰影の付いた橙色の球、右は同じ大きさだが影も艶も無い、のっぺりした橙色の円](https://i.gyazo.com/5a39d483beceaa7b529cba56af940aba.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a55d02ef
    public func noLights() { canvas.noLights() }
}
