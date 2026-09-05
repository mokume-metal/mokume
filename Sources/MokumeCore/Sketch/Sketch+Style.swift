// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、塗り・線・重ね方の設定。
extension Sketch {
    /// 面全体を塗り直す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(26, 89, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 面全体がくすんだ濃い青 1 色で塗られている | symmetric=xy -->
    ///     ![面全体がくすんだ濃い青 1 色で塗られている](https://i.gyazo.com/e82fe62b30c6016d1d17788c3b022dd4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// それまでに溜めた図形は消える — 全面を塗るのだから、下に隠れるものを
    /// 描く手間をかける意味がない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     fill(242, 115, 64)
    ///     circle(200, 150, 260)
    ///     background(26, 89, 140)
    ///     fill(242, 217, 89)
    ///     circle(200, 150, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 先に描いた大きな橙色の円は消え、濃い青の下地に黄色い小さな円だけが残っている | symmetric=xy -->
    ///     ![先に描いた大きな橙色の円は消え、濃い青の下地に黄色い小さな円だけが残っている](https://i.gyazo.com/e029756fe495d29926176cb2dce1b6e5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=45bd9950
    // shot: 2 snippet=f68cd749
    public func background(_ color: LinearRGBA) { canvas.background(color) }

    /// これから描く図形の塗りの色。**塗りを止めていたら、呼んだ時点で再び塗るようになる。**
    ///
    /// 呼んだ時点より後の図形にだけ効く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(110, 150, 130)
    ///     fill(89, 191, 242)
    ///     circle(200, 150, 130)
    ///     fill(242, 217, 89)
    ///     circle(290, 150, 130)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・水色・黄の円が、少しずつ重なりながら左から順に並んでいる | symmetric=y -->
    ///     ![橙・水色・黄の円が、少しずつ重なりながら左から順に並んでいる](https://i.gyazo.com/fa67f8d215df306400d938cca49bafb4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 4 つ目の `alpha` を下げると、下にあるものが透ける。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(150, 150, 200)
    ///     fill(89, 191, 242, 153)
    ///     circle(250, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円の上に半透明の水色の円が重なり、重なった部分だけ色が混ざっている | symmetric=y -->
    ///     ![橙色の円の上に半透明の水色の円が重なり、重なった部分だけ色が混ざっている](https://i.gyazo.com/11c4ac43fa8b7aa9f7aff5b4dc8991a8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=a705bbfd
    // shot: 2 snippet=bedf025c
    public func fill(_ color: LinearRGBA) { canvas.fill(color) }

    /// これから引く線の色。**線を止めていたら、呼んだ時点で再び引くようになる。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     strokeWeight(8)
    ///     stroke(242, 115, 64)
    ///     circle(110, 150, 130)
    ///     stroke(89, 191, 242)
    ///     circle(200, 150, 130)
    ///     stroke(242, 217, 89)
    ///     circle(290, 150, 130)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・水色・黄の輪郭だけの円が、少しずつ重なりながら左から順に並んでいる | symmetric=y -->
    ///     ![橙・水色・黄の輪郭だけの円が、少しずつ重なりながら左から順に並んでいる](https://i.gyazo.com/d18e00bca1eb95424ab87c36a9bba024.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 塗りとは別に決まるので、``fill(_:)`` と組み合わせれば中と縁で別の色になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(89, 191, 242)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(16)
    ///     circle(200, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色に塗られた円を、太い橙色の輪郭が囲んでいる | symmetric=xy -->
    ///     ![水色に塗られた円を、太い橙色の輪郭が囲んでいる](https://i.gyazo.com/9b76ba5c17e2ad76aa6460fb63c1576f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=4c4fa3bb
    // shot: 2 snippet=fbfeb1bb
    public func stroke(_ color: LinearRGBA) { canvas.stroke(color) }

    /// これから引く線の太さ (画素)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     for index in 0..<5 {
    ///         strokeWeight(Float(index) * 7 + 2)
    ///         line(70, 60 + Float(index) * 45, 330, 60 + Float(index) * 45)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上から下へ、だんだん太くなる 5 本の白い横線 | symmetric=x -->
    ///     ![上から下へ、だんだん太くなる 5 本の白い横線](https://i.gyazo.com/890dce0704f422b7a97bba8da5a47bea.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 図形の輪郭にも効く。太さは縁を中心に内と外へ半分ずつ広がるので、太くすると
    /// 図形は一回り大きく見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(2)
    ///     square(60, 100, 100)
    ///     strokeWeight(30)
    ///     square(240, 100, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの正方形が 2 つ並び、左は細い橙色の輪郭、右は太い橙色の輪郭で描かれている | symmetric=y -->
    ///     ![同じ大きさの正方形が 2 つ並び、左は細い橙色の輪郭、右は太い橙色の輪郭で描かれている](https://i.gyazo.com/23f026f2a7694e42780dceada175d1f4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 線の太さは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=1f8ee8eb
    // shot: 2 snippet=edd890f7
    public func strokeWeight(_ weight: Float) { canvas.strokeWeight(weight) }

    /// 図形の内側を塗らない。輪郭だけの図形になる。
    ///
    /// ``fill(_:)`` を呼ぶと、その時点でまた塗るようになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     strokeWeight(8)
    ///     fill(242, 115, 64)
    ///     circle(110, 150, 150)
    ///     noFill()
    ///     circle(290, 150, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左は中が橙色に塗られた円、右は同じ大きさで白い輪郭だけの円 | symmetric=y -->
    ///     ![左は中が橙色に塗られた円、右は同じ大きさで白い輪郭だけの円](https://i.gyazo.com/7c54b002459baa15f3c67537a866cfe9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=8bdd372c
    public func noFill() { canvas.noFill() }

    /// 線を引かない。図形の輪郭も出なくなる。
    ///
    /// ``stroke(_:)`` を呼ぶと、その時点でまた引くようになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     stroke(217, 230, 255)
    ///     strokeWeight(8)
    ///     circle(110, 150, 150)
    ///     noStroke()
    ///     circle(290, 150, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左は白い輪郭のある橙色の円、右は輪郭の無い同じ橙色の円 | symmetric=y -->
    ///     ![左は白い輪郭のある橙色の円、右は輪郭の無い同じ橙色の円](https://i.gyazo.com/d0bd6b957452c857ee0843bc2320a49c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=ddde199c
    public func noStroke() { canvas.noStroke() }

    /// 線の端の形。既定は丸。
    ///
    /// 太さ 1 の線では 3 つとも同じに見えるので、**確かめるときは太さを振る**。
    /// 下の 3 枚は同じ線を形だけ変えて引いたもので、細い白い線が**渡した端の位置**を
    /// 示している。
    ///
    /// ``StrokeCap/round`` は端を丸め、渡した位置より半円ぶん外へ出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     strokeWeight(2)
    ///     line(140, 40, 140, 260)
    ///     line(260, 40, 260, 260)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(60)
    ///     strokeCap(.round)
    ///     line(140, 150, 260, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の線の端が丸く、白い目印の線より外へ半円ぶんはみ出している | symmetric=xy -->
    ///     ![太い橙色の線の端が丸く、白い目印の線より外へ半円ぶんはみ出している](https://i.gyazo.com/30f60dd0e811851ab37489895bd68875.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeCap/square`` は渡した位置ちょうどで切る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     strokeWeight(2)
    ///     line(140, 40, 140, 260)
    ///     line(260, 40, 260, 260)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(60)
    ///     strokeCap(.square)
    ///     line(140, 150, 260, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の線が、白い目印の線のところでまっすぐ切れている | symmetric=xy -->
    ///     ![太い橙色の線が、白い目印の線のところでまっすぐ切れている](https://i.gyazo.com/f490ccd70812fee1a733777d8fcba71d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeCap/project`` は四角いまま、太さの半分だけ外へ出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(217, 230, 255)
    ///     strokeWeight(2)
    ///     line(140, 40, 140, 260)
    ///     line(260, 40, 260, 260)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(60)
    ///     strokeCap(.project)
    ///     line(140, 150, 260, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の線が、白い目印の線より外へ四角くはみ出している | symmetric=xy -->
    ///     ![太い橙色の線が、白い目印の線より外へ四角くはみ出している](https://i.gyazo.com/5471180214c3bf8620991d5b1bd193f0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 端の形は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=a8be414a
    // shot: 2 snippet=1620a3e0
    // shot: 3 snippet=ee04ab7c
    public func strokeCap(_ cap: StrokeCap) { canvas.strokeCap(cap) }

    /// 描くものを、この矩形の中だけに収める。座標の読み方は ``rectMode(_:)`` が決める。
    ///
    /// 積み降ろし (``pushStyle()``) で戻るので、入れ子にして元へ帰れる。
    /// 面の外へ出た指定は面の内側へ収める。
    public func clip(_ a: Float, _ b: Float, _ c: Float, _ d: Float) { canvas.clip(a, b, c, d) }

    /// 切り抜きをやめる。
    public func noClip() { canvas.noClip() }

    /// 描くものを、下にある絵とどう混ぜるか。既定は上に重ねる。
    ///
    /// 下の 4 枚は、灰色の下地に赤と青の円を重ねる同じ絵を、混ぜ方だけ変えたもの。
    ///
    /// ``BlendMode/blend`` (既定) は、後から描いたものが前を覆う。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 140, 148)
    ///     noStroke()
    ///     blendMode(.blend)
    ///     fill(242, 76, 51)
    ///     circle(160, 130, 190)
    ///     fill(51, 115, 242)
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の下地に赤い円と青い円が並び、青い円が赤い円の上に重なっている -->
    ///     ![灰色の下地に赤い円と青い円が並び、青い円が赤い円の上に重なっている](https://i.gyazo.com/fe2288a524130e51bb18ea6be92d7ec8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``BlendMode/add`` は光を重ねたように明るくなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 140, 148)
    ///     noStroke()
    ///     blendMode(.add)
    ///     fill(242, 76, 51)
    ///     circle(160, 130, 190)
    ///     fill(51, 115, 242)
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 2 つの円が明るくなり、重なった部分が白に近い桃色になっている -->
    ///     ![同じ 2 つの円が明るくなり、重なった部分が白に近い桃色になっている](https://i.gyazo.com/2cbff1c1cbfbb7e7bfc2982e9ff09194.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``BlendMode/multiply`` は暗いほうへ寄る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 140, 148)
    ///     noStroke()
    ///     blendMode(.multiply)
    ///     fill(242, 76, 51)
    ///     circle(160, 130, 190)
    ///     fill(51, 115, 242)
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 2 つの円が暗くなり、重なった部分がいちばん暗い -->
    ///     ![同じ 2 つの円が暗くなり、重なった部分がいちばん暗い](https://i.gyazo.com/4a2141c572badcb62394b3d91de83221.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``BlendMode/difference`` は下地との差を取るので、色が反転して見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 140, 148)
    ///     noStroke()
    ///     blendMode(.difference)
    ///     fill(242, 76, 51)
    ///     circle(160, 130, 190)
    ///     fill(51, 115, 242)
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 赤い円は桃色、青い円は紫へ転び、重なった部分が鮮やかな赤紫になっている -->
    ///     ![赤い円は桃色、青い円は紫へ転び、重なった部分が鮮やかな赤紫になっている](https://i.gyazo.com/7250b40c643c6acc9a880001be774c10.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 重なりが動くと、混ぜ方の効きがはっきりする。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 15, 23)
    ///     noStroke()
    ///     blendMode(.add)
    ///     let sweep = 90 * sin(Float(frameCount) * 0.05)
    ///     fill(242, 51, 38)
    ///     circle(200 - sweep, 150, 170)
    ///     fill(38, 115, 242)
    ///     circle(200 + sweep, 150, 170)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 赤い円と青い円が近づいたり離れたりし、重なった部分だけが明るい桃色に光る | frames=60 symmetric=y -->
    ///     ![赤い円と青い円が近づいたり離れたりし、重なった部分だけが明るい桃色に光る](https://i.gyazo.com/905bebca900be3c8189cf81c8426afc1.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **どのモードでも、アルファ 0 の色は下地を変えない。** 混ぜ方が変わっても
    /// 「どれだけ効かせるか」はアルファが決める。
    ///
    /// - Note: 混ぜ方は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=579fbd41
    // shot: 2 snippet=519aa11b
    // shot: 3 snippet=0f727a4c
    // shot: 4 snippet=b5a144fd
    // shot: 5 snippet=43e3e4b7
    public func blendMode(_ mode: BlendMode) { canvas.blendMode(mode) }

    /// 線の折れ目の形。既定は尖らせる形。
    ///
    /// 折れ線と、閉じた図形の輪郭の角に効く。
    ///
    /// ``StrokeJoin/miter`` は角を尖らせる**指定**だが、いまの実装は
    /// ``StrokeJoin/bevel`` と同じ形で埋める (``StrokeJoin/miter`` の但し書き)。
    /// 下の 2 枚が同じ絵になるのはそのためで、伸びの限界を持つ尖りが入れば変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(44)
    ///     strokeJoin(.miter)
    ///     beginShape()
    ///     vertex(70, 230)
    ///     vertex(200, 70)
    ///     vertex(330, 230)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の山形の折れ線。頂点は尖らず、平らに削がれている | symmetric=x -->
    ///     ![太い橙色の山形の折れ線。頂点は尖らず、平らに削がれている](https://i.gyazo.com/845d763011b862a08a45daf482ad4330.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeJoin/bevel`` は角を削ぐ。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(44)
    ///     strokeJoin(.bevel)
    ///     beginShape()
    ///     vertex(70, 230)
    ///     vertex(200, 70)
    ///     vertex(330, 230)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ折れ線の頂点が、平らに削がれている | symmetric=x -->
    ///     ![同じ折れ線の頂点が、平らに削がれている](https://i.gyazo.com/845d763011b862a08a45daf482ad4330.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeJoin/round`` は角を丸める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(44)
    ///     strokeJoin(.round)
    ///     beginShape()
    ///     vertex(70, 230)
    ///     vertex(200, 70)
    ///     vertex(330, 230)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ折れ線の頂点が、丸くなっている | symmetric=x -->
    ///     ![同じ折れ線の頂点が、丸くなっている](https://i.gyazo.com/fa97542f35665344b2155270fe77ff23.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 折れ目の形は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=dc0e1fbc
    // shot: 2 snippet=449f0a0c
    // shot: 3 snippet=6ea17290
    public func strokeJoin(_ join: StrokeJoin) { canvas.strokeJoin(join) }

    /// いまのスタイル (塗り・線・端と折れ目の形・座標の読み方) を積んでおく。
    public func pushStyle() { canvas.pushStyle() }

    /// 積んでおいたスタイルへ戻す。積んでいなければ何もしない。
    public func popStyle() { canvas.popStyle() }
}
