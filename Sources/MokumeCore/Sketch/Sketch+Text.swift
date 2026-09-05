// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 文字。
extension Sketch {
    /// 文字列を描く。
    ///
    /// `y` が何を指すかは ``textAlign(_:_:)`` が決める。既定は**基準線** — 字が乗る線で、
    /// `g` や `y` の下へ伸びる部分はここより下に出る (下の絵の灰色の線が基準線)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(0, 170, 400, 170)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(56)
    ///     text("mokume", 40, 170)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の横線のちょうど上に、白い大きな mokume が乗っている -->
    ///     ![灰色の横線のちょうど上に、白い大きな mokume が乗っている](https://i.gyazo.com/fe969b6fb9f7ae6bad63c019a50a51da.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **改行で行が分かれる。** 行の間隔は ``textLeading(_:)`` が決める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(40)
    ///     text("mokume\nmetal", 40, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い文字が 2 行に分かれ、左端を揃えて縦に並んでいる -->
    ///     ![白い文字が 2 行に分かれ、左端を揃えて縦に並んでいる](https://i.gyazo.com/7f75a9cee673a0c12a7c761f3e19377e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **塗りの色で描く**ので、``noFill()`` の状態では何も出ない。
    // shot: 1 snippet=0c8959e5
    // shot: 2 snippet=3044f8bc
    public func text(_ string: String, _ x: Float, _ y: Float) { canvas.text(string, x, y) }

    /// これから描く文字の大きさ (画素)。既定は 12。
    ///
    /// 行送りを指定していなければ、行の間隔もこの値から決まる。
    /// 下の 2 枚は同じ基準線 (灰色の横線) の上に置いてある。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(0, 200, 400, 200)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(24)
    ///     text("mokume", 40, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の線の上に、小さめの白い mokume が乗っている -->
    ///     ![灰色の線の上に、小さめの白い mokume が乗っている](https://i.gyazo.com/bed29d4c29e5ecfd5c288f2d2e8470ec.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(0, 200, 400, 200)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(64)
    ///     text("mokume", 40, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ位置の灰色の線の上に、ずっと大きな白い mokume が乗っている -->
    ///     ![同じ位置の灰色の線の上に、ずっと大きな白い mokume が乗っている](https://i.gyazo.com/9ee88ae6a7bf082fe8654ca5267089d9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 文字の大きさは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=a8143a74
    // shot: 2 snippet=02dd14ba
    public func textSize(_ size: Float) { canvas.textSize(size) }

    /// これから描く文字の書体。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(34)
    ///     text("mokume 123", 30, 110)
    ///     textFont("Courier")
    ///     text("mokume 123", 30, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ語が 2 行。上は既定の書体、下は字幅の揃った書体で描かれている -->
    ///     ![同じ語が 2 行。上は既定の書体、下は字幅の揃った書体で描かれている](https://i.gyazo.com/ec22d871ad2611b4d627ac62e5d32792.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **この環境に無い名前は効かない。** 名前が違っても別の書体で描かれてしまうと
    /// 気付けないので、無い名前は警告を出して書体を変えない。``noTextFont()`` で
    /// 既定へ戻る。
    ///
    /// 指定した書体が覆えない文字 (欧文の書体に日本語を渡した場合など) は、
    /// この環境が持つ別の書体から引いて描く。
    ///
    /// - Note: 書体は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=38a1d815
    public func textFont(_ name: String) { canvas.textFont(name) }

    /// 書体の指定をやめ、この環境の既定の書体へ戻す。
    ///
    /// 下の絵の **1 行目と 3 行目は同じ書体**である — 間で ``textFont(_:)`` を挟んでも、
    /// 戻せば元に帰る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(30)
    ///     text("mokume", 30, 80)
    ///     textFont("Courier")
    ///     text("mokume", 30, 160)
    ///     noTextFont()
    ///     text("mokume", 30, 240)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ語が 3 行。1 行目と 3 行目は同じ書体で、真ん中の 1 行だけ違う -->
    ///     ![同じ語が 3 行。1 行目と 3 行目は同じ書体で、真ん中の 1 行だけ違う](https://i.gyazo.com/2556f54db965d96a7cd836d96d3ff054.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 書体は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=92702e23
    public func noTextFont() { canvas.noTextFont() }

    /// これから描く文字の太さと傾き。既定はそのまま。
    ///
    /// **4 通りを 1 枚に並べてある** — 別々の絵にすると、どれも「白い字がある」絵に
    /// なって見比べられないためである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(18)
    ///     fill(89, 191, 242)
    ///     text("normal", 20, 70)
    ///     text("bold", 20, 135)
    ///     text("italic", 20, 200)
    ///     text("boldItalic", 20, 265)
    ///     textSize(44)
    ///     fill(242, 242, 242)
    ///     textStyle(.normal)
    ///     text("Mokume", 130, 70)
    ///     textStyle(.bold)
    ///     text("Mokume", 130, 135)
    ///     textStyle(.italic)
    ///     text("Mokume", 130, 200)
    ///     textStyle(.boldItalic)
    ///     text("Mokume", 130, 265)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に水色の指定名、右に白い Mokume が 4 行。下 2 行は右へ傾き、2 行目と 4 行目は画が太い -->
    ///     ![左に水色の指定名、右に白い Mokume が 4 行。下 2 行は右へ傾き、2 行目と 4 行目は画が太い](https://i.gyazo.com/16d812f6ddaf11fff08f543cf65f0681.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 字の太さと傾きは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=dad4af7f
    public func textStyle(_ style: TextStyle) { canvas.textStyle(style) }

    /// 文字列を、指定した位置のどちら側へ置くか。既定は**左から右へ・基準線**。
    ///
    /// ```swift
    /// textAlign(.center, .center)
    /// text("mokume", width / 2, height / 2)   // 面のまん中に置かれる
    /// ```
    ///
    /// **横の 3 通りを、同じ 1 本の縦線を基準に並べてある。** どれも `x` に同じ 200 を
    /// 渡していて、変えたのは指定だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(200, 0, 200, 300)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(28)
    ///     textAlign(.left)
    ///     text("left", 200, 90)
    ///     textAlign(.center)
    ///     text("center", 200, 160)
    ///     textAlign(.right)
    ///     text("right", 200, 230)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 1 本の縦線に対し、右へ出る・線をまたぐ・線で終わる の 3 語が上から並んでいる -->
    ///     ![1 本の縦線に対し、右へ出る・線をまたぐ・線で終わる の 3 語が上から並んでいる](https://i.gyazo.com/f7d48c6258ea121365b590483af5eb6c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **縦の 4 通りも同じように、1 本の横線を基準に並べてある。** `baseline` だけが
    /// 字の乗る線で、他の 3 つは字の囲みの上端・中央・下端を線に合わせる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(0, 150, 400, 150)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(22)
    ///     textAlign(.left, .top)
    ///     text("top", 20, 150)
    ///     textAlign(.left, .center)
    ///     text("center", 110, 150)
    ///     textAlign(.left, .baseline)
    ///     text("base", 230, 150)
    ///     textAlign(.left, .bottom)
    ///     text("bottom", 310, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 1 本の横線に対し、下へぶら下がる・線をまたぐ・線に乗る・線の上に載る の 4 語が左から並んでいる -->
    ///     ![1 本の横線に対し、下へぶら下がる・線をまたぐ・線に乗る・線の上に載る の 4 語が左から並んでいる](https://i.gyazo.com/bda78fe4da8ce167d0bb7446dfc8b14b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 揃えは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=ee229cc3
    // shot: 2 snippet=ad72b9a7
    public func textAlign(
        _ horizontal: HorizontalTextAlign, _ vertical: VerticalTextAlign = .baseline
    ) {
        canvas.textAlign(horizontal, vertical)
    }

    /// 行と行の間隔 (画素)。指定しなければ大きさの 1.25 倍。
    ///
    /// 下の 2 枚は同じ 3 行を、同じ大きさで、同じ位置から描いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(28)
    ///     text("one\ntwo\nthree", 40, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い 3 行が、詰まった間隔で縦に並んでいる -->
    ///     ![白い 3 行が、詰まった間隔で縦に並んでいる](https://i.gyazo.com/60fbf69ea1ac41029a3c32d107a041ee.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(28)
    ///     textLeading(70)
    ///     text("one\ntwo\nthree", 40, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 3 行が、倍ほど離れた間隔で縦に並んでいる -->
    ///     ![同じ 3 行が、倍ほど離れた間隔で縦に並んでいる](https://i.gyazo.com/8d9bf47f4cb581aca54c68e1b2bbfe03.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 行送りは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=c1e64917
    // shot: 2 snippet=26cf4f8a
    public func textLeading(_ leading: Float) { canvas.textLeading(leading) }

    /// 文字列を描いたときの幅 (画素)。
    ///
    /// **1 文字ずつの送り幅の合計**なので、部分に切って足すと全体と一致する。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(44)
    ///     text("mokume", 40, 150)
    ///     let w = textWidth("mokume")
    ///     stroke(242, 115, 64)
    ///     strokeWeight(3)
    ///     line(40, 168, 40 + w, 168)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い mokume のすぐ下に、語と同じ長さの橙色の線が引かれている -->
    ///     ![白い mokume のすぐ下に、語と同じ長さの橙色の線が引かれている](https://i.gyazo.com/9de2422d96c08e453703cae91c47accd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=ebe1b460
    public func textWidth(_ string: String) -> Float { canvas.textWidth(string) }

    /// 基準線から上へ伸びる高さ (画素)。
    ///
    /// **書体が持つ値で、いま描く文字列には依らない。** どんな字を渡してもこの高さより
    /// 上へは出ない (下の絵の水色の線)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     textSize(64)
    ///     let base: Float = 200
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(0, base, 400, base)
    ///     stroke(89, 191, 242)
    ///     strokeWeight(2)
    ///     line(0, base - textAscent(), 400, base - textAscent())
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     text("Mokume", 40, base)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の基準線に字が乗り、その上に引かれた水色の線を字が越えていない -->
    ///     ![灰色の基準線に字が乗り、その上に引かれた水色の線を字が越えていない](https://i.gyazo.com/f86f6d9fb6c33c2fa194202b0f4b5293.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f70f460d
    public func textAscent() -> Float { canvas.textAscent() }

    /// 基準線から下へ伸びる深さ (画素)。
    ///
    /// こちらも書体が持つ値。`g` や `y` のように基準線の下へ伸びる字も、この深さより
    /// 下へは出ない (下の絵の橙色の線)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     textSize(64)
    ///     let base: Float = 150
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     line(0, base, 400, base)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(2)
    ///     line(0, base + textDescent(), 400, base + textDescent())
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     text("mokugy", 40, base)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の基準線から g と y が下へ伸び、その先を橙色の線が受け止めている -->
    ///     ![灰色の基準線から g と y が下へ伸び、その先を橙色の線が受け止めている](https://i.gyazo.com/e70bb9120406f546faa8158fdaa40acd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=cce8b3db
    public func textDescent() -> Float { canvas.textDescent() }

    /// 矩形の中へ文字列を流し込む。
    ///
    /// 4 つの数の読み方は ``rectMode(_:)`` が決める — ``rect(_:_:_:_:)`` と同じ約束である。
    /// 幅で折り返し、**高さに収まる行だけ**を置く。折り返す場所は ``textWrap(_:)``。
    /// 下の絵の灰色の枠が、渡した矩形そのものである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let long = "矩形へ流し込むと、指定した幅で折り返し、指定した高さに収まる行だけが置かれる。入りきらなかった分は remainder に残るので、続きを別の場所へ流せる。"
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     rect(30, 40, 160, 220)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(18)
    ///     text(long, 30, 40, 160, 220)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の縦長の枠の中に、折り返された白い日本語の文が収まっている -->
    ///     ![灰色の縦長の枠の中に、折り返された白い日本語の文が収まっている](https://i.gyazo.com/22a66d00f08e753735e77e420cecb1a7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **入りきらなかった続きは `remainder` に残る。** 別の矩形へそのまま渡せば、
    /// 段を跨いで流せる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let long = "矩形へ流し込むと、指定した幅で折り返し、指定した高さに収まる行だけが置かれる。入りきらなかった分は remainder に残るので、続きを別の場所へ流せる。"
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     rect(20, 40, 170, 100)
    ///     rect(210, 40, 170, 100)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(18)
    ///     let flow = text(long, 20, 40, 170, 100)
    ///     fill(89, 191, 242)
    ///     text(flow.remainder, 210, 40, 170, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左の枠に白い文が収まり、右の枠にその続きが水色で流れている -->
    ///     ![左の枠に白い文が収まり、右の枠にその続きが水色で流れている](https://i.gyazo.com/c299d0a2c333736f566d17f5a5102a4c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 返る値は「何行置いたか・どれだけの高さを使ったか・何が残ったか」。**続きを
    /// どこから描くかを自分で数え直さずに済む**ように返している。
    ///
    /// 縦の指定 (``textAlign(_:_:)``) は置いた塊全体に効く。矩形の中では基準線に
    /// 意味が無いので、基準線指定は上揃えと同じに扱う。
    // shot: 1 snippet=82f3bb5e
    // shot: 2 snippet=6b763151
    @discardableResult
    public func text(_ string: String, _ a: Float, _ b: Float, _ c: Float, _ d: Float)
        -> TextFlow
    {
        canvas.text(string, a, b, c, d)
    }

    /// 幅に収まらなくなったとき、どこで行を折るか。既定は語の切れ目。
    ///
    /// 下の 2 枚は同じ文を同じ枠へ流している。**語で折ると行末が不揃いになり、
    /// 文字で折ると枠の右辺で揃う。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let words = "mokume renders declarative sketches"
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     rect(60, 50, 150, 200)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(20)
    ///     textWrap(.word)
    ///     text(words, 60, 50, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 枠の中の英文が語の切れ目で折り返され、行末が不揃いになっている -->
    ///     ![枠の中の英文が語の切れ目で折り返され、行末が不揃いになっている](https://i.gyazo.com/d43fcff337558a959ce774c30a5b942a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let words = "mokume renders declarative sketches"
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(1)
    ///     rect(60, 50, 150, 200)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(20)
    ///     textWrap(.character)
    ///     text(words, 60, 50, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ英文が文字の切れ目で折り返され、行末が枠の右辺近くで揃っている -->
    ///     ![同じ英文が文字の切れ目で折り返され、行末が枠の右辺近くで揃っている](https://i.gyazo.com/73fe4cc1b409eba3e8f80f78fdd321e8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 語の切れ目で折るとき、**1 語が幅より長ければその語の中で折る** —
    /// でないと置き場所が無くなる。
    ///
    /// - Note: 折り返し方は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=9d76cf16
    // shot: 2 snippet=36f2b043
    public func textWrap(_ mode: TextWrap) { canvas.textWrap(mode) }

    /// 文字列の輪郭を取り出す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(242, 217, 89)
    ///     strokeWeight(2)
    ///     textSize(72)
    ///     for contour in textOutline("mokume", 20, 190) {
    ///         beginShape()
    ///         for point in contour.points { vertex(point.x, point.y) }
    ///         endShape(.close)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色い線だけで縁取られた mokume — 画の内側は塗られていない -->
    ///     ![黄色い線だけで縁取られた mokume — 画の内側は塗られていない](https://i.gyazo.com/ce06383d7ffd37ad69775c5d89c958bb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **描くときと同じ送り**で並ぶので、``text(_:_:_:)`` と同じ位置・同じ字間になる。
    /// 返る点はいまの座標のままで、変換は掛かっていない。
    ///
    /// 字ごとに、外側の周が先・穴が後の順で並ぶ。曲線は直線の並びにほどいてあり、
    /// 細かさは曲線の大きさから決まる。
    // shot: 1 snippet=e9e2ccf8
    public func textOutline(_ string: String, _ x: Float, _ y: Float) -> [TextContour] {
        canvas.textOutline(string, x, y)
    }
}
