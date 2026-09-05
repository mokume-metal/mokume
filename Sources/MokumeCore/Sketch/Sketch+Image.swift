// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 画像。
extension Sketch {
    /// 絵を読む。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var grain: Image? -->
    /// ```swift
    /// func setup() {
    ///     grain = try? loadImage("assets/grain.png")
    /// }
    /// ```
    ///
    /// **読み込みは投げる。** 読めなかったときに別の道を選ぶ判断が要るので、黙って
    /// 既定へ倒さない。見つからないときの説明には**探した場所**が載る。
    ///
    /// > Note: この口には例の絵が付いていない。読む先のファイルが要るが、このリポジトリは
    /// > 生成物・バイナリを持たないためである。絵を手続きで作るなら ``createImage(_:_:)``
    /// > か ``createGraphics(_:_:)`` を見ること — そちらには絵が付いている。
    ///
    /// 名前は、作業ディレクトリと**実行ファイルの隣に置かれた資材の包み**から探す。
    /// スケッチのパッケージが資材の置き場を宣言していないと、ビルドは静かに通って
    /// 実行時に読めないだけになるので、宣言を確かめること。
    public func loadImage(_ path: String) throws(ImageFailure) -> Image {
        try canvas.loadImage(path)
    }

    /// 絵を読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 復号を別の仕事として回すので、大きな絵を読んでもフレームが詰まらない。
    ///
    /// > Note: ``loadImage(_:)`` と同じ理由で、この口にも例の絵は付いていない。
    public func requestImage(_ path: String) async throws(ImageFailure) -> Image {
        try await canvas.requestImage(path)
    }

    /// 空の絵を作る。中身は透明。
    ///
    /// ``Image/set(_:_:_:)`` で書き換えると、**描くときに自動で送られる** —
    /// 送り直しを呼び忘れて絵が変わらない、という形の不具合が起きない。
    ///
    /// **投げるので `setup()` で作って持ち回る。** 下の例は 16 画素四方の絵を 1 度だけ
    /// 作り、毎フレーム大きく引き伸ばして置いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(16, 16)
    ///         for y in 0..<16 {
    ///             for x in 0..<16 {
    ///                 tile.set(x, y, .display(
    ///                     red: Float(x) / 15, green: 0.35, blue: Float(y) / 15))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 80, 30, 240, 240)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 16 画素四方の絵を大きく置いたもの。右へ行くほど赤く、下へ行くほど青い -->
    ///     ![16 画素四方の絵を大きく置いたもの。右へ行くほど赤く、下へ行くほど青い](https://i.gyazo.com/23113a03912ea1eb6254ef510a267466.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f455cc89
    public func createImage(_ width: Int, _ height: Int) throws(ImageFailure) -> Image {
        try canvas.createImage(width, height)
    }

    /// 絵を等倍で置く。左上の角が (`x`, `y`) に来る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 90, 60)
    ///         stroke(242, 242, 242)
    ///         strokeWeight(2)
    ///         line(50, 60, 90, 60)
    ///         line(90, 20, 90, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 64 画素四方の絵が等倍で置かれ、白い 2 本の線が外からその左上の角を指している -->
    ///     ![64 画素四方の絵が等倍で置かれ、白い 2 本の線が外からその左上の角を指している](https://i.gyazo.com/94f54734ee6cc0a42dfab068c7bf18e2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=484b5a23
    public func image(_ image: Image, _ x: Float, _ y: Float) { canvas.image(image, x, y) }

    /// 絵を、指定した寸法に合わせて置く。
    ///
    /// 4 つの数の読み方は ``imageMode(_:)`` が決める。**絵の画素数と合っていなくてよい** —
    /// 下の例は同じ 64 画素四方の絵を、等倍と 3 倍ほどで並べている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 30, 40, 64, 64)
    ///         image(tile, 140, 40, 200, 200)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 2 つ。左は小さく等倍、右は 3 倍ほどに引き伸ばされている -->
    ///     ![同じ絵が 2 つ。左は小さく等倍、右は 3 倍ほどに引き伸ばされている](https://i.gyazo.com/c7416c8ac28379800fdfad620bd0f32d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=6c035e1b
    public func image(_ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        canvas.image(image, a, b, c, d)
    }

    /// 絵の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**絵の中のどこを切り出すか**。切り出しが絵の
    /// 外へ出ても落ちず、重なった分だけが出る。
    ///
    /// 下の例は同じ絵を 2 度置いている — 左は全体、右は左上の 28 画素四方だけを
    /// 同じ大きさへ引き伸ばしたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 20, 40, 128, 128)
    ///         image(tile, 190, 40, 128, 128, 4, 4, 28, 28)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に絵の全体、右はその左上 28 画素四方だけを同じ大きさへ引き伸ばしたもの。右は橙色が大半を占め、下端にだけ青が残る -->
    ///     ![左に絵の全体、右はその左上 28 画素四方だけを同じ大きさへ引き伸ばしたもの。右は橙色が大半を占め、下端にだけ青が残る](https://i.gyazo.com/b5b141dafb763161b546b61ca2cc152e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b02a0f10
    public func image(
        _ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        canvas.image(image, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// 4 つの数を、絵のどこの寸法として読むか。既定は**左上の角と、幅と高さ**。
    ///
    /// 下の 4 枚はどれも同じ 4 つの数 `200, 150, 120, 90` を渡していて、変えたのは
    /// 読み方だけである (白い点が `200, 150`)。``rectMode(_:)`` と同じ約束。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.corner)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が絵の左上の角にあり、絵は点から右下へ広がっている -->
    ///     ![白い点が絵の左上の角にあり、絵は点から右下へ広がっている](https://i.gyazo.com/93cf7dab5d61fb2ff2984033eb16f6b0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.corners)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///         circle(120, 90, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が 2 つあり、それぞれ絵の右下と左上の角になっている -->
    ///     ![白い点が 2 つあり、それぞれ絵の右下と左上の角になっている](https://i.gyazo.com/6cf1dd506ad84c3445ce927576bd5fdd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.center)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が絵のまん中にある -->
    ///     ![白い点が絵のまん中にある](https://i.gyazo.com/dfbbf32976cabfcd95f00c8b68f31b43.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.radius)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が絵のまん中にあり、絵は center のときの縦横 2 倍になっている -->
    ///     ![白い点が絵のまん中にあり、絵は center のときの縦横 2 倍になっている](https://i.gyazo.com/c43c94a65c7d0253e1cf349c6e795c42.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3489d6ec
    // shot: 2 snippet=1c6055c2
    // shot: 3 snippet=bbc7b35e
    // shot: 4 snippet=04e1e495
    public func imageMode(_ mode: ShapeMode) { canvas.imageMode(mode) }

    /// 絵に掛ける色。**掛け算なので、白は何も変えない。**
    ///
    /// 下の 2 枚はどちらも、左が掛ける前・右が掛けた後である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 20, 90, 160, 120)
    ///         tint(255, 255, 255, 128)
    ///         image(tile, 220, 90, 160, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 2 つ。右は濃さが半分で、下地に沈んで見える -->
    ///     ![同じ絵が 2 つ。右は濃さが半分で、下地に沈んで見える](https://i.gyazo.com/87d4061dddb98fd5ad315d423ac8b612.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 20, 90, 160, 120)
    ///         tint(255, 153, 153)
    ///         image(tile, 220, 90, 160, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 2 つ。右は緑と青が抑えられて赤みが乗っている -->
    ///     ![同じ絵が 2 つ。右は緑と青が抑えられて赤みが乗っている](https://i.gyazo.com/bb37aac80ea19d3ee416c5fd02e881fc.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=25c42a96
    // shot: 2 snippet=4775cb21
    public func tint(_ color: LinearRGBA) { canvas.tint(color) }

    /// 色掛けをやめる。
    ///
    /// **1 つ目と 3 つ目は同じ色で出る** — 間で ``tint(_:)`` を掛けても、外せば元に帰る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 15, 100, 110, 110)
    ///         tint(255, 128, 128)
    ///         image(tile, 145, 100, 110, 110)
    ///         noTint()
    ///         image(tile, 275, 100, 110, 110)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 3 つ横に並び、真ん中だけ赤みが乗っている。右は左と同じ色に戻っている -->
    ///     ![同じ絵が 3 つ横に並び、真ん中だけ赤みが乗っている。右は左と同じ色に戻っている](https://i.gyazo.com/a945802560d325a9b9bb53d60f5b8871.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=82db2864
    public func noTint() { canvas.noTint() }
}
