// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、塗り・線・重ね方の設定。
extension Sketch {
    /// 面全体を塗り直す。切り抜き (``clip(_:_:_:_:)``) の中で呼べば、その中だけを塗り直す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(26, 89, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 面全体がくすんだ濃い青 1 色で塗られている | symmetric=xy -->
    ///     ![面全体がくすんだ濃い青 1 色で塗られている](https://i.gyazo.com/ef634168fd61fb510457ae7b6e03bb49.png)
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
    ///     ![先に描いた大きな橙色の円は消え、濃い青の下地に黄色い小さな円だけが残っている](https://i.gyazo.com/30cab01270e473c802ae7fd35b300899.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 色の不透明度も同じで、**下地に重ならず、面をその色で置き換える**。半透明の色を
    /// 渡せば面が半透明の色になり、前の絵は残らない。何も残さず透明へ戻すなら
    /// ``LinearRGBA/transparent`` を渡す (`background(.transparent)`)。残像の作り方は
    /// ``background(_:_:)`` に書いた。
    ///
    /// **呼んだ時点の描き方は効かない。** 混ぜ方 (``blendMode(_:)``)・断片 (``shader(_:)``)・
    /// 貼る絵・影を落とすかのどれを変えたままでも、同じ色で置き換える。同じフレームで先に画素を
    /// 読んでいても (``loadPixels()`` など)、それまでの絵ごと置き換わる。
    ///
    /// **切り抜きの中で呼ぶと、その中だけを置き換える。** 切り抜きの外に先に描いたものは残り、
    /// 中は色も前後 (奥行き) も塗り直した面と同じになる — 後から置く立体は、先に置いた立体に
    /// 隠されない。周囲を背景にする `background(.sky)` も同じ規則で置き換える。
    ///
    /// 数でない成分・無限の成分を持つ色は受けず、塗り直さない (それまでに描いたものも残る)。
    /// 初回だけ理由を知らせる。
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
    ///     ![橙・水色・黄の円が、少しずつ重なりながら左から順に並んでいる](https://i.gyazo.com/d7b7902117ae8137c5c761b17ddc3b32.png)
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
    ///     ![橙色の円の上に半透明の水色の円が重なり、重なった部分だけ色が混ざっている](https://i.gyazo.com/c5b1ffad45cd768c804c4e38b11bd4e2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `rect` や `circle` で 1 画素より細く描いた塗りは、置く位置によらず面積に比例した濃さで
    /// 出る (1 画素より小さい円は、外接する正方形の面積に比例する)。`square`・`ellipse` と一周の
    /// `arc` も同じで、`shader()` や `texture()` を付けても変わらない。`triangle`・`quad`・
    /// `beginShape` と、`shader()` や `texture()` を付けた扇形 (一周でない `arc`) の 1 画素より
    /// 細い塗りはこの約束の外で、縁を滑らかにせずに三角形で描くので画素の格子に丸まり、置く位置に
    /// よって消えるか 1 画素の濃さで出る。
    ///
    /// 数でない成分・無限の成分を持つ色は受けず、塗りは直前のまま残る。初回だけ理由を知らせる。
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
    ///     ![橙・水色・黄の輪郭だけの円が、少しずつ重なりながら左から順に並んでいる](https://i.gyazo.com/5a11fbf1a01d6f8f8cb0bb3042325d7b.png)
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
    ///     ![水色に塗られた円を、太い橙色の輪郭が囲んでいる](https://i.gyazo.com/7525fbdb545e5afc07a044a0689a263d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 半透明の線や、下地を読む混ぜ方 (``blendMode(_:)``) で引いても、線は繋ぎ目・端・
    /// 曲線の継ぎ目で濃くならない。基本図形 (`rect` / `ellipse` / `arc`・辺の交差しない `quad`)
    /// の線は、描く経路によらず 1 つの領域として 1 回だけ混ぜる。`beginShape()` で並べた形の
    /// 線は、線に沿って太さより離れた部分が重なると (自己交差・細長い形の向かい合う辺・曲線の
    /// 折り返し)、別々の線が重なるのと同じく重ねて混ぜる。
    ///
    /// 数でない成分・無限の成分を持つ色は受けず、線の色は直前のまま残る。初回だけ理由を知らせる。
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
    ///     ![上から下へ、だんだん太くなる 5 本の白い横線](https://i.gyazo.com/0b4c2047d239a9c640bc20c8ec7a6406.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 太さは 0 以上の有限の数。負の値・数でない値・無限は 0 (線が出ない) として扱い、1 度だけ
    /// 知らせる。
    ///
    /// 1 画素より細い線は、置く位置によらず太さに比例した濃さで出る (点は面積に比例する)。
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
    ///     ![同じ大きさの正方形が 2 つ並び、左は細い橙色の輪郭、右は太い橙色の輪郭で描かれている](https://i.gyazo.com/a8add64cfa2eeddbb4268d2cf81a2589.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 線の太さは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=1f8ee8eb
    // shot: 2 snippet=edd890f7
    public func strokeWeight(_ weight: some ScalarConvertible) {
        let weight = weight.asFloat
        canvas.strokeWeight(weight)
    }

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
    ///     ![左は中が橙色に塗られた円、右は同じ大きさで白い輪郭だけの円](https://i.gyazo.com/a2cc975f1de172ef03648d3b0b3182b3.png)
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
    ///     ![左は白い輪郭のある橙色の円、右は輪郭の無い同じ橙色の円](https://i.gyazo.com/515eb90948becaf5a1f6c967ad31e22e.png)
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
    ///     ![太い橙色の線の端が丸く、白い目印の線より外へ半円ぶんはみ出している](https://i.gyazo.com/2d48f8905febc6a6de8a4e48828f071a.png)
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
    ///     ![太い橙色の線が、白い目印の線のところでまっすぐ切れている](https://i.gyazo.com/4af2b4e45ba96fb2c9d24ff1537be18f.png)
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
    ///     ![太い橙色の線が、白い目印の線より外へ四角くはみ出している](https://i.gyazo.com/69298c069054e439f115704769d5759c.png)
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
    /// 塗り直し (`background()`) も収める — 切り抜きの中だけを置き換え、外に先に描いたものは
    /// 残る。
    ///
    /// 矩形は**いまの変換の影響を受けず**、面の座標で読む。``translate(_:_:)`` などの後で
    /// 呼んでも、切り抜くのは面の同じ場所である。変換を効かせたいときは、角を
    /// ``screenX(_:_:)`` / ``screenY(_:_:)`` で面の座標へ写してから渡す。平行移動と拡大までは、
    /// 角を 2 つ写せば足りる (既定の `rectMode(.corner)` のとき):
    ///
    /// ```swift
    /// translate(60, 60)
    /// scale(2, 2)
    /// let left = screenX(0, 0)
    /// let top = screenY(0, 0)
    /// clip(left, top, screenX(60, 60) - left, screenY(60, 60) - top)
    /// rect(0, 0, 60, 60)  // 動かした先の矩形の中だけが残る
    /// ```
    ///
    /// 切り抜きは面に沿った矩形しか持てないので、``rotate(_:)`` や ``shearX(_:)`` を掛けた
    /// 矩形は表せない — 角を写しても、回した矩形にはならない。
    ///
    /// 積み降ろし (``pushStyle()``) で戻るので、入れ子にして元へ帰れる。
    /// 面の外へ出た指定は面の内側へ収める。
    ///
    /// 切り抜きは画素を丸ごと通すか落とすかしかできないので、**画素の中心が矩形の内 (縁の上を
    /// 含む) にある画素を通す**。覆う割合が半分以上の画素を通すことに当たり、同じ矩形の
    /// ``rect(_:_:_:_:)`` と縁が揃う (ちょうど半分の画素は通す)。``SketchSettings/pixelDensity``
    /// が 1 未満なら描く画素の格子で同じ規則を使うので、縁は描く画素の半分までずれうる。
    /// たとえば細かさ 0.5 の `clip(51, 0, 20, 40)` は、奇数の縁が描く画素の中心に乗るので
    /// 外へ倒れ、出す画素で 50…72 を通す。
    ///
    /// 縁の上の画素を通すので、**隣り合う 2 つの切り抜きが縁を共有し、その縁が画素の中心に
    /// 乗るとき (細かさ 1 なら `x.5`)、その画素はどちらの切り抜きでも描かれる**。半透明の絵を
    /// 左右に分けて描くと、継ぎ目の 1 列が 2 度重なる。避けるなら、縁を画素の境目 (細かさ 1
    /// なら整数) に置く。
    ///
    /// - Note: 切り抜きは**フレームを越えない**。`draw()` の中で毎フレーム書く。初期化の
    ///   ときや、止まっている間の入力のコールバックで書いた切り抜きはどのフレームにも
    ///   属さないので、警告して無視される。
    public func clip(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        canvas.clip(a, b, c, d)
    }

    /// 切り抜きをやめる。
    ///
    /// - Note: 切り抜きは**フレームを越えない**ので、フレームの外 (初期化のときなど) には
    ///   外す切り抜きが無い。そこで呼ぶと、``clip(_:_:_:_:)`` と同じく警告して無視される。
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
    ///     ![灰色の下地に赤い円と青い円が並び、青い円が赤い円の上に重なっている](https://i.gyazo.com/7cbd71d6a1889e1466a326d24c622b82.png)
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
    ///     ![同じ 2 つの円が明るくなり、重なった部分が白に近い桃色になっている](https://i.gyazo.com/f45365e5b8ae67a4b4a5e8766b382281.png)
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
    ///     ![同じ 2 つの円が暗くなり、重なった部分がいちばん暗い](https://i.gyazo.com/d54635fba4250b95cdd0703b17f70b24.png)
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
    ///     ![赤い円は桃色、青い円は紫へ転び、重なった部分が鮮やかな赤紫になっている](https://i.gyazo.com/de4f70ec46001667084d96f770954a50.png)
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
    ///     ![赤い円と青い円が近づいたり離れたりし、重なった部分だけが明るい桃色に光る](https://i.gyazo.com/31800dab0433d9820b53232901f4d0f2.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **置き換える (``BlendMode/replace``) 以外のどのモードでも、アルファ 0 の色は下地を
    /// 変えない。** 混ぜ方が変わっても「どれだけ効かせるか」はアルファが決める。
    /// ``BlendMode/replace`` だけは下地を見ず、形が掛かる画素を置いた色でアルファごと
    /// 置き換える — アルファ 0 の色なら、その画素は透明になる ([#1542])。
    ///
    /// **下地が透明な所では、どのモードでも置いた色がそのまま載る。** 混ぜる相手が無いので、
    /// 混ぜ方は下地のアルファの分だけ効く — 半分透ける下地の上では、混ぜた色と置いた色が
    /// 半分ずつになる (W3C の合成の一般式・[#1447])。透明で始まる描き場所
    /// (``createGraphics(_:_:)``) に ``BlendMode/multiply`` で描いても、黒い形にはならない。
    ///
    /// **混ぜた結果は、その場で表示できる範囲へ丸めない。** ``BlendMode/add`` は 1.0 を
    /// 超えた明るさをそのまま残すので、光を重ねるほど積み上がる — 芯が頭打ちにならず、
    /// 「重なっているところ」と「重なっていないところ」の差が消えない。``BlendMode/subtract``
    /// は 0 を下回った値を残すので、暗部は途中で折れずに黒へ着く。表示できる範囲へ畳むのは
    /// 出力段だけである ([ADR-0011] 決定 1・[#1057])。
    ///
    /// [#1057]: https://github.com/mokume-metal/mokume/issues/1057
    /// [#1447]: https://github.com/mokume-metal/mokume/issues/1447
    /// [#1542]: https://github.com/mokume-metal/mokume/issues/1542
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
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
    /// 折れ線と、閉じた図形の輪郭の角に効く。**曲線の刻みの継ぎ目には効かない** —
    /// 継ぎ目は角ではないので、どの形でも丸く繋ぐ ([#1409])。曲線の終点
    /// (``bezierVertex(_:_:_:_:_:_:)`` に渡した最後の点) と通過点 (``curveVertex(_:_:)``) は
    /// 置いた点なので、そこで折れれば角として扱う。扇形 (``arc(_:_:_:_:_:_:)``) の中心と
    /// 弧の両端は、どの形でも丸く繋ぐ。
    ///
    /// **折れ目の形は、そこで出会う 2 本の線の向きと太さだけで決まる。** 回してから描いても、
    /// 回した座標で描いても同じ形で、一直線に並べた点では線の外へ何も出ない。
    ///
    /// ``StrokeJoin/miter`` は角を尖らせる。尖りが角から線幅 × √2 / 2 より先へ伸びる鋭い
    /// 角では、そこで先を平らに切る。下の山形は直角より鋭いので、先が切られている。
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
    ///     <!-- shot: 太い橙色の山形の折れ線。頂点は尖り、尖りの先が平らに切られている | symmetric=x -->
    ///     ![太い橙色の山形の折れ線。頂点は尖り、尖りの先が平らに切られている](https://i.gyazo.com/25a56824ea6ecfae0a022341f083d266.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeJoin/bevel`` は角を削ぐ。尖りを、角から線幅の半分の所で切る。
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
    ///     ![同じ折れ線の頂点が、平らに削がれている](https://i.gyazo.com/d9c82c4f11477500aa18eafb2ee0e18a.png)
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
    ///     ![同じ折れ線の頂点が、丸くなっている](https://i.gyazo.com/7a1ba2fc8b2489b15372f1c185975ebb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// [#1409]: https://github.com/mokume-metal/mokume/issues/1409
    ///
    /// - Note: 折れ目の形は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=dc0e1fbc
    // shot: 2 snippet=449f0a0c
    // shot: 3 snippet=6ea17290
    public func strokeJoin(_ join: StrokeJoin) { canvas.strokeJoin(join) }

    /// いまのスタイル (塗り・線・端と折れ目の形・座標の読み方) を積んでおく。
    ///
    /// - Note: **積んだ履歴はフレームを越えない。** スタイルそのものは越えるが、積んだ
    ///   事実は `draw()` の頭で捨てられるので、`pushStyle()` と `popStyle()` は同じ
    ///   フレームの中で釣り合わせる。降ろし忘れても次のフレームへは積み上がらない。
    public func pushStyle() { canvas.pushStyle() }

    /// 積んでおいたスタイルへ戻す。積んでいなければ何もしない。
    public func popStyle() { canvas.popStyle() }
}
