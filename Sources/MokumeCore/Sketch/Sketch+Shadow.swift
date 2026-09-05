// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 影。
extension Sketch {
    /// 影を落とすかどうか。既定は落とさない。
    ///
    /// 落とすのは**置いてあるうちの最初の向きを持つ光** (``directionalLight(_:_:_:_:)``)
    /// で、その光から見た奥行きを 1 枚焼いてから画面を描く。
    ///
    /// ```swift
    /// func draw() {
    ///     lights()
    ///     shadows(true)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     push()
    ///     translate(width / 2, height * 0.8, 0)
    ///     box(400, 10, 400)
    ///     pop()
    ///     castShadow(true)
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     sphere(80)
    ///     pop()
    /// }
    /// ```
    ///
    /// **影が減らすのは直接の光だけ**である。影の中でも、``ambientLight(_:)-fvb5`` の光・
    /// ``surroundings(_:)`` の光・``emissive(_:)-uyuh`` の自発光は残り、``ambient(_:)-9anin`` は
    /// 影の内外を問わず効く。
    ///
    /// 下はこのあとの 3 枚と同じ場面で、影の設定を何も足していないもの。比べるときの
    /// 基準になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(191, 191, 199)
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(242, 115, 64)
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 見下ろした灰色の床の上に橙色の球が浮かび、床の左奥にその影が落ちている -->
    ///     ![見下ろした灰色の床の上に橙色の球が浮かび、床の左奥にその影が落ちている](https://i.gyazo.com/7ad07dae8af9bc1fa9ba80b50ff260a3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 影は**フレームを越えない**。`draw()` の中で毎フレーム書く。毎フレーム
    ///   書いても焼き付け先は作り直さないので、繰り返しの負担にはならない。
    // shot: 1 snippet=1a72b4f9
    public func shadows(_ enabled: Bool) { canvas.shadows(enabled) }

    /// 影を焼き付ける範囲の一辺 (世界の長さ)。
    ///
    /// **影の細かさは世界の大きさに依る。** 焼き付け先の広さは決まっているので、
    /// 広い範囲を焼けばそのぶん粗くなる。何も指定しなければ**面の対角の長さ**を使う
    /// ので、画素と同じ尺度で作るスケッチはそのままで合う。
    ///
    /// ずっと小さい世界 (1 単位を 1 メートルとして数十単位、など) を作るときは、
    /// その世界に合わせた長さを渡す。渡さないと影が数画素に潰れる。
    ///
    /// **粗さを決めるのは 範囲 ÷ 画素数**である。下は ``shadows(_:)`` と同じ場面で
    /// 範囲だけを広げたもので、``shadowDetail(_:)`` を下げたときと同じ形の粗さが出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 面の対角 (既定) よりずっと広い範囲を焼く
    ///     shadowRange(8000)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(191, 191, 199)
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(242, 115, 64)
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ場面だが、影の縁が階段状にがたつき、影がひとまわり痩せている -->
    ///     ![同じ場面だが、影の縁が階段状にがたつき、影がひとまわり痩せている](https://i.gyazo.com/17478d4fd235be134daa18cb1de5d457.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=10cc6754
    public func shadowRange(_ size: Float) { canvas.shadowRange(size) }

    /// 影を焼き付ける面の一辺の画素数。既定は 1024。
    ///
    /// 大きくすると縁が細かくなり、そのぶん焼くのに時間がかかる。**同じ数を渡し
    /// 続けるかぎり、焼き付け先は作り直されない。**
    ///
    /// 下は ``shadows(_:)`` と同じ場面で、画素数だけを落としたもの。``shadowRange(_:)``
    /// を広げたときと同じ粗さになる — **効いているのは 範囲 ÷ 画素数の比**だからである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 下限まで落とす (64...4096 の範囲を取る)
    ///     shadowDetail(64)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(191, 191, 199)
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(242, 115, 64)
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 範囲を広げた絵とまったく同じ粗さで、影の縁が階段状にがたついている -->
    ///     ![範囲を広げた絵とまったく同じ粗さで、影の縁が階段状にがたついている](https://i.gyazo.com/9b3971b8f3b327719b032323eb5d7969.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=6803da11
    public func shadowDetail(_ size: Int) { canvas.shadowDetail(size) }

    /// 影の縁の破綻を抑える量。既定は `0.0025`。
    ///
    /// 焼いた 1 画素の中で奥行きが変わるので、そのままだと**自分の影が自分の上に
    /// 縞として出る**。それを避けるための余裕で、大きくしすぎると影が形から離れて
    /// 浮いて見える。
    ///
    /// 下は ``shadows(_:)`` と同じ場面で、余裕を 0 にしたもの。**球の明るい側に、
    /// 自分の影が細かい縞になって浮く** — これが避けようとしている破綻である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 余裕を外すと破綻が出る (既定は 0.0025)
    ///     shadowBias(0)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(191, 191, 199)
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(242, 115, 64)
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ場面だが、球の明るい側に細かい縞状の汚れが浮いている -->
    ///     ![同じ場面だが、球の明るい側に細かい縞状の汚れが浮いている](https://i.gyazo.com/3ac34ff089fca6d3574a9f9c8841272a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=704ae6de
    public func shadowBias(_ amount: Float) { canvas.shadowBias(amount) }

    /// これから置く形が、影を落とす側か。既定は落とす。
    ///
    /// 床のように「受けるだけ」の形は落とす側から外す。**全体を切るしか無いと、
    /// 自己遮蔽の強い形を置いた作品が影ごと諦めることになる。**
    ///
    /// **形ごとに決まる。** 下は同じ高さに球を 2 つ置き、右だけを落とす側から外した
    /// もの — 影は左の球のぶんしか出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     castShadow(false)
    ///     fill(191, 191, 199)
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     // 左の球だけが影を落とす
    ///     fill(242, 115, 64)
    ///     for (index, casts) in [true, false].enumerated() {
    ///         castShadow(casts)
    ///         push()
    ///         translate(130 + Float(index) * 145, 120, 20)
    ///         sphere(60)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 床の上に橙色の球が 2 つ並び、影は左の球の下にだけ落ちている -->
    ///     ![床の上に橙色の球が 2 つ並び、影は左の球の下にだけ落ちている](https://i.gyazo.com/d5975cb46d1fb2a6e86e7c21cacda5b5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=95162799
    public func castShadow(_ enabled: Bool) { canvas.castShadow(enabled) }

    /// これから置く形が、影を受ける側か。既定は受ける。
    ///
    /// **落とす側と同じく、形ごとに決まる。** 下は床を 2 枚に割って右だけを受ける側
    /// から外し、それぞれの上に球を置いたもの — 落ちている影は左の床にしか出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 床を 2 枚。右の 1 枚だけ受ける側から外す
    ///     castShadow(false)
    ///     fill(191, 191, 199)
    ///     for (index, receives) in [true, false].enumerated() {
    ///         receiveShadow(receives)
    ///         push()
    ///         translate(102 + Float(index) * 196, 250, -20)
    ///         box(188, 8, 300)
    ///         pop()
    ///     }
    ///     receiveShadow(true)
    ///     // 球は 2 つとも同じように落とす
    ///     castShadow(true)
    ///     fill(242, 115, 64)
    ///     for index in 0..<2 {
    ///         push()
    ///         translate(135 + Float(index) * 145, 120, 20)
    ///         sphere(60)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 2 枚に割れた床の上に橙色の球が 2 つ。影が出ているのは左の床だけで、右の床は継ぎ目から先が一様に明るい -->
    ///     ![2 枚に割れた床の上に橙色の球が 2 つ。影が出ているのは左の床だけで、右の床は継ぎ目から先が一様に明るい](https://i.gyazo.com/db139c7e8cee4c6060490750969a9231.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=86dc1877
    public func receiveShadow(_ enabled: Bool) { canvas.receiveShadow(enabled) }
}
