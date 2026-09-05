// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、基本図形。
extension Sketch {
    /// 矩形を塗る。
    ///
    /// 4 つの数の読み方は ``rectMode(_:)`` が決める。既定は**左上の角と、幅と高さ**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rect(80, 60, 240, 180)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地に、左上 (80, 60) から 240x180 の橙色の長方形 | symmetric=xy -->
    ///     ![濃い灰色の下地に、左上 (80, 60) から 240x180 の橙色の長方形](https://i.gyazo.com/91321fd926431913d8b41a1bc0877b10.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 3 つ目と 4 つ目は幅と高さなので、片方だけ変えれば細長くなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rect(60, 40, 280, 60)
    ///     rect(60, 130, 70, 130)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の長方形が上、縦長の長方形が左下に並ぶ -->
    ///     ![横長の長方形が上、縦長の長方形が左下に並ぶ](https://i.gyazo.com/1af656b7596f944cb2736ebbf1a28039.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 幅か高さが 0 以下になる指定では**何も描かない**。
    // shot: 1 snippet=74598101
    // shot: 2 snippet=60541771
    public func rect(_ a: Float, _ b: Float, _ c: Float, _ d: Float) { canvas.rect(a, b, c, d) }

    /// 正方形を塗る。
    ///
    /// 読み方は ``rect(_:_:_:_:)`` と同じで、幅と高さに同じ値を渡すのに等しい。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     square(130, 80, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 下地の中ほどに、一辺 140 の橙色の正方形 | symmetric=xy -->
    ///     ![下地の中ほどに、一辺 140 の橙色の正方形](https://i.gyazo.com/816a997e781a50e439a784d00f4f9374.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a14bfc0d
    public func square(_ a: Float, _ b: Float, _ extent: Float) { canvas.square(a, b, extent) }

    /// 円を塗る。
    ///
    /// 3 つの数の読み方は ``ellipseMode(_:)`` が決める。既定は**中心と直径**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     circle(200, 150, 160)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地の中央に、直径 160 の橙色の円 | symmetric=xy -->
    ///     ![濃い灰色の下地の中央に、直径 160 の橙色の円](https://i.gyazo.com/1cc45c1fa382c2acb3415a57aab75770.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 3 つ目は直径なので、変えても中心は動かない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     circle(200, 150, 240)
    ///     fill(89, 191, 242)
    ///     circle(200, 150, 160)
    ///     fill(242, 217, 89)
    ///     circle(200, 150, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ中心に重なる、直径 240・160・80 の 3 つの円 | symmetric=xy -->
    ///     ![同じ中心に重なる、直径 240・160・80 の 3 つの円](https://i.gyazo.com/df5fa3cd289c445abe4e14e4bb62dc9a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=dddecdb4
    // shot: 2 snippet=ccc7b2b7
    public func circle(_ a: Float, _ b: Float, _ diameter: Float) { canvas.circle(a, b, diameter) }

    /// 楕円を塗る。
    ///
    /// 4 つの数の読み方は ``ellipseMode(_:)`` が決める。既定は**中心と、幅と高さ**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     ellipse(200, 150, 280, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 画面の中央に、横に長い橙色の楕円 | symmetric=xy -->
    ///     ![画面の中央に、横に長い橙色の楕円](https://i.gyazo.com/7294388a4964ec73975ee3ae3893b42d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 幅と高さを入れ替えると、同じ中心のまま向きだけが変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     ellipse(200, 150, 280, 140)
    ///     fill(89, 191, 242)
    ///     ellipse(200, 150, 140, 280)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ中心に、横長と縦長の楕円が十字に重なる | symmetric=xy -->
    ///     ![同じ中心に、横長と縦長の楕円が十字に重なる](https://i.gyazo.com/fa1d8bb830b64a2d3889be1071bbd5e6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5db22851
    // shot: 2 snippet=b47c6582
    public func ellipse(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        canvas.ellipse(a, b, c, d)
    }

    /// 円弧を塗る。
    ///
    /// 最初の 4 つの数は ``ellipse(_:_:_:_:)`` と同じ読み方で、続く 2 つが始まりと
    /// 終わりの角度 (ラジアン)。**角度は右向きが 0** で、増える向きは画面の上で
    /// 時計回りに見える (縦軸が下向きのため)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     arc(200, 150, 200, 200, 0, .pi / 2)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の円の、右から下へ 4 分の 1 だけが橙色の扇形になっている -->
    ///     ![中央の円の、右から下へ 4 分の 1 だけが橙色の扇形になっている](https://i.gyazo.com/f05a83df616e766bf61b02e7000c8f12.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 終わりの角度を伸ばすと、扇形はその向きへ広がる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     arc(200, 150, 200, 200, 0, .pi * 1.5)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ円の 4 分の 3 が橙色の扇形になり、右上だけが欠けている -->
    ///     ![同じ円の 4 分の 3 が橙色の扇形になり、右上だけが欠けている](https://i.gyazo.com/114fe261f94c658091628c78ed7324d9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 始まりの角度を動かすと、欠けている側が回る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     arc(200, 150, 200, 200, .pi, .pi * 1.5)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から上へ 4 分の 1 だけの橙色の扇形 -->
    ///     ![左から上へ 4 分の 1 だけの橙色の扇形](https://i.gyazo.com/fdaa962a2366d3af7dc5539767cbdff5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 角度をフレーム番号から作れば、扇形は動く。**時計を実時間ではなくフレームに
    /// 紐づけるので、何度撮っても同じ動きになる**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 217, 89)
    ///     let bite = Float.pi / 8
    ///     let start = bite * sin(Float(frameCount) * 0.06) + bite
    ///     arc(200, 150, 200, 200, start, .pi * 2 - start)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色い円が口を開け閉めするように、扇形の欠けが大きくなったり小さくなったりする | frames=60 symmetric=y -->
    ///     ![黄色い円が口を開け閉めするように、扇形の欠けが大きくなったり小さくなったりする](https://i.gyazo.com/400c7dfd652b5b06d6852aa30886e074.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 塗りは**中心を含む扇形**になる。終わりの角度が始まりより小さいときは
    /// **何も描かず**、最初の 1 回だけ知らせる。
    // shot: 1 snippet=1f67f389
    // shot: 2 snippet=e00e11b7
    // shot: 3 snippet=600285f4
    // shot: 4 snippet=27105ca4
    public func arc(
        _ a: Float, _ b: Float, _ c: Float, _ d: Float, _ start: Float, _ stop: Float
    ) {
        canvas.arc(a, b, c, d, start, stop)
    }

    /// 三角形を塗る。3 つの頂点をそのまま与える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     triangle(200, 50, 330, 250, 70, 250)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 下地の中央に、頂点を上に向けた橙色の三角形 | symmetric=x -->
    ///     ![下地の中央に、頂点を上に向けた橙色の三角形](https://i.gyazo.com/9e0c0bcf222e3977d1dc13227e874eba.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f5d478e8
    public func triangle(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x3: Float, _ y3: Float
    ) {
        canvas.triangle(x1, y1, x2, y2, x3, y3)
    }

    /// 四角形を塗る。4 つの頂点は**与えた順に結ばれる**ので、順序を入れ替えると
    /// 砂時計のような形にもなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     quad(70, 60, 330, 90, 310, 240, 90, 210)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 少し傾いた橙色の四角形 -->
    ///     ![少し傾いた橙色の四角形](https://i.gyazo.com/50f0f2f6adfcdaebe808bce6337edeb8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 後ろの 2 つを入れ替えると、同じ 4 点のまま辺が交差する。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     quad(70, 60, 330, 90, 90, 210, 310, 240)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 4 点で辺が交差し、砂時計のような形になっている -->
    ///     ![同じ 4 点で辺が交差し、砂時計のような形になっている](https://i.gyazo.com/68bbdf3c925be4e8eb5ba98e1a0b4cb3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=34577789
    // shot: 2 snippet=23b24af9
    public func quad(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float,
        _ x3: Float, _ y3: Float, _ x4: Float, _ y4: Float
    ) {
        canvas.quad(x1, y1, x2, y2, x3, y3, x4, y4)
    }

    /// 点を打つ。
    ///
    /// 大きさは ``strokeWeight(_:)`` で決めた太さ、色は ``stroke(_:)`` の色。
    /// 塗りの色ではないことに注意 — 点は「太さを持つ線の最小の形」として扱う。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     for index in 0..<5 {
    ///         strokeWeight(Float(index) * 6 + 4)
    ///         point(70 + Float(index) * 65, 150)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から右へ、だんだん大きくなる 5 つの白い点 | symmetric=y -->
    ///     ![左から右へ、だんだん大きくなる 5 つの白い点](https://i.gyazo.com/8ba9f92afc2b850ec0c6bee16468efbf.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 色を決めるのは ``stroke(_:)`` で、``fill(_:)`` は効かない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     stroke(89, 191, 242)
    ///     strokeWeight(18)
    ///     for index in 0..<5 {
    ///         point(70 + Float(index) * 65, 150)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色に塗る指定をしても、点は水色のまま並んでいる | symmetric=xy -->
    ///     ![橙色に塗る指定をしても、点は水色のまま並んでいる](https://i.gyazo.com/be20303d3bdb4dda91afc87b5233ee1e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=72c60508
    // shot: 2 snippet=8602b4e7
    public func point(_ x: Float, _ y: Float) { canvas.point(x, y) }

    /// 矩形に渡す座標の読み方。既定は ``ShapeMode/corner``。
    ///
    /// 同じ 4 つの数を渡しても、モードが変われば出る場所と大きさが変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rectMode(.corner)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上を (120, 90) とする 160x120 の橙色の長方形 | symmetric=xy -->
    ///     ![左上を (120, 90) とする 160x120 の橙色の長方形](https://i.gyazo.com/4897a176deed098645d6b8808791c91d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/corners`` は 4 つの数を**向かい合う 2 つの角**として読む。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rectMode(.corners)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: (120, 90) と (160, 120) を対角とする、小さな橙色の長方形 -->
    ///     ![(120, 90) と (160, 120) を対角とする、小さな橙色の長方形](https://i.gyazo.com/387917c8b465595dea782dfc522edbad.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/center`` は**中心と、幅と高さ**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rectMode(.center)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: (120, 90) を中心とする 160x120 の橙色の長方形 -->
    ///     ![(120, 90) を中心とする 160x120 の橙色の長方形](https://i.gyazo.com/f36d9de1076d83443e54fef36e915c7e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/radius`` は**中心と、中心から端までの長さ**なので倍の大きさになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rectMode(.radius)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ中心のまま、center のときの倍の大きさになった橙色の長方形 -->
    ///     ![同じ中心のまま、center のときの倍の大きさになった橙色の長方形](https://i.gyazo.com/dc4d256a60d1292df561947039050001.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=bdc059c4
    // shot: 2 snippet=93b69e1a
    // shot: 3 snippet=76535701
    // shot: 4 snippet=f9d3d420
    public func rectMode(_ mode: ShapeMode) { canvas.rectMode(mode) }

    /// 楕円と円弧に渡す座標の読み方。既定は ``ShapeMode/center``。
    ///
    /// ``circle(_:_:_:)`` にも効く — 直径 1 つしか渡さないので、意味を持つのは
    /// 中心から測る 2 つ (``ShapeMode/center`` と ``ShapeMode/radius``) である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     ellipseMode(.center)
    ///     ellipse(200, 150, 200, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: (200, 150) を中心とする、幅 200 高さ 140 の橙色の楕円 | symmetric=xy -->
    ///     ![(200, 150) を中心とする、幅 200 高さ 140 の橙色の楕円](https://i.gyazo.com/a93e72193a029fcd3333328a96fbe291.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/corner`` にすると、同じ数が**左上の角と、幅と高さ**になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     ellipseMode(.corner)
    ///     ellipse(200, 150, 200, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ数のまま右下へずれた、幅 200 高さ 140 の橙色の楕円 -->
    ///     ![同じ数のまま右下へずれた、幅 200 高さ 140 の橙色の楕円](https://i.gyazo.com/4cfb7fee1ff44c5487734333161ebf04.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=7bc89b05
    // shot: 2 snippet=09181c0f
    public func ellipseMode(_ mode: ShapeMode) { canvas.ellipseMode(mode) }

    /// 線を引く。塗りは持たない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     strokeWeight(6)
    ///     line(60, 60, 340, 240)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上から右下へ引かれた 1 本の白い線 -->
    ///     ![左上から右下へ引かれた 1 本の白い線](https://i.gyazo.com/120912ee096c296b2ad0f761ba14f0da.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 太さは ``strokeWeight(_:)``、端の形は ``strokeCap(_:)`` が決める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     for (index, cap) in [StrokeCap.square, .round, .project].enumerated() {
    ///         strokeCap(cap)
    ///         strokeWeight(Float(index) * 8 + 8)
    ///         line(90, 70 + Float(index) * 60, 310, 70 + Float(index) * 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太さの違う 3 本の白い線が、端の形を変えて横に並んでいる | symmetric=x -->
    ///     ![太さの違う 3 本の白い線が、端の形を変えて横に並んでいる](https://i.gyazo.com/68d0eaf648d2832387f34292a65687bb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f2777671
    // shot: 2 snippet=055b0309
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        canvas.line(x1, y1, x2, y2)
    }
}
