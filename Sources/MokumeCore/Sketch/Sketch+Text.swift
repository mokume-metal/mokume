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
    ///     ![灰色の横線のちょうど上に、白い大きな mokume が乗っている](https://i.gyazo.com/a58c90895bc6a44ed63585d197e3613e.png)
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
    ///     ![白い文字が 2 行に分かれ、左端を揃えて縦に並んでいる](https://i.gyazo.com/1ce42b215592f9c253a1393bd9b98c4e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **塗りの色で描く**ので、``noFill()`` の状態では何も出ない。
    // shot: 1 snippet=0c8959e5
    // shot: 2 snippet=3044f8bc
    public func text(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        canvas.text(string, x, y)
    }

    /// これから描く文字の大きさ (画素)。既定は 12。
    ///
    /// 大きさは 0 以上。大きさ 0 の文字は何も描かれず、測る口 (``textWidth(_:)``・
    /// ``textAscent()``・``textDescent()``) も 0 を返す。
    ///
    /// 負の値・数でない値・無限は 0 として、1e18 を越える値は 1e18 として扱い、1 度だけ知らせる。
    /// 字の寸法から作る量 (行送り・送り幅の合計・輪郭の点) が、有限の数に収まる上限である。
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
    ///     ![灰色の線の上に、小さめの白い mokume が乗っている](https://i.gyazo.com/c69fce4a3f022cebe481f12682f200f0.png)
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
    ///     ![同じ位置の灰色の線の上に、ずっと大きな白い mokume が乗っている](https://i.gyazo.com/c711be7bc1d9a11780ea0cd6dad3c1a3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 文字の大きさは**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// - Note: 大きさごとに書体を引き当てて控える。控えは面ごとに 64 通りまでで、しばらく
    ///   使っていない大きさから捨てる。**1 フレームに 64 通りより多くの大きさを使うと、
    ///   毎フレーム書体を引き当て直す** (字の引き当てもやり直す)。大きさの種類を絞るか、
    ///   同じ大きさで書いて ``scale(_:_:)`` で伸ばす。
    // shot: 1 snippet=a8143a74
    // shot: 2 snippet=02dd14ba
    public func textSize(_ size: some ScalarConvertible) {
        let size = size.asFloat
        canvas.textSize(size)
    }

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
    ///     ![同じ語が 2 行。上は既定の書体、下は字幅の揃った書体で描かれている](https://i.gyazo.com/f3ff89ec0190856486fed4a6c51a138c.png)
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
    ///     ![同じ語が 3 行。1 行目と 3 行目は同じ書体で、真ん中の 1 行だけ違う](https://i.gyazo.com/d739aeb0dc9533a618987bbc0d16b309.png)
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
    ///     ![左に水色の指定名、右に白い Mokume が 4 行。下 2 行は右へ傾き、2 行目と 4 行目は画が太い](https://i.gyazo.com/5bf1d3a5e3faeea58355c1fbfdba0068.png)
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
    ///     ![1 本の縦線に対し、右へ出る・線をまたぐ・線で終わる の 3 語が上から並んでいる](https://i.gyazo.com/c2abe7e828cb7e5050dba1b6c9db85f0.png)
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
    ///     ![1 本の横線に対し、下へぶら下がる・線をまたぐ・線に乗る・線の上に載る の 4 語が左から並んでいる](https://i.gyazo.com/d0283412728bbf95e42fb176b222797f.png)
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
    /// 受け取り方は ``textSize(_:)`` と同じ (負の値・数でない値・無限は 0、1e18 を越える
    /// 値は 1e18 として扱い、1 度だけ知らせる)。
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
    ///     ![白い 3 行が、詰まった間隔で縦に並んでいる](https://i.gyazo.com/29fd0ff2bcf8945246b08b8140cc9899.png)
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
    ///     ![同じ 3 行が、倍ほど離れた間隔で縦に並んでいる](https://i.gyazo.com/f6a3ab2d79d23fbbe6283d62bdb62dfd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 行送りは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=c1e64917
    // shot: 2 snippet=26cf4f8a
    public func textLeading(_ leading: some ScalarConvertible) {
        let leading = leading.asFloat
        canvas.textLeading(leading)
    }

    /// 文字列を描いたときの幅 (画素)。
    ///
    /// **1 文字ずつの送り幅の合計**なので、部分に切って足すと全体と一致する。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    /// 大きさ 0 (``textSize(_:)``) では 0 を返す。
    ///
    /// 送り幅は字の左右に書体が付けた余白を含む。墨の載る範囲は ``textBounds(_:_:_:)`` が返す。
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
    ///     ![白い mokume のすぐ下に、語と同じ長さの橙色の線が引かれている](https://i.gyazo.com/80f942db8e0d8e7cbe66e7aeaa1fb1db.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=ebe1b460
    public func textWidth(_ string: String) -> Float { canvas.textWidth(string) }

    /// 基準線から上へ伸びる高さ (画素)。
    ///
    /// **書体が持つ値で、いま描く文字列には依らない。** 既定の書体では、アクセントの
    /// 付いた大文字 (`Å` `É`) もこの高さより上へは出ない。下の絵の水色の線がこの高さである。
    ///
    /// **どの字もこの線の内側に収まるとは限らない。** 書体によってはアクセントの付いた字が
    /// この線を越える — `Helvetica` の `Å` の輪は、この高さより上に出る。
    ///
    /// 大きさ 0 (``textSize(_:)``) では 0 を返す。
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
    ///     ![灰色の基準線に字が乗り、その上に引かれた水色の線を字が越えていない](https://i.gyazo.com/ded9e7aaeeb134315f5b79ed6725f11d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f70f460d
    public func textAscent() -> Float { canvas.textAscent() }

    /// 基準線から下へ伸びる深さ (画素)。
    ///
    /// こちらも書体が持つ値。既定の書体では、`g` や `y` のように基準線の下へ伸びる字も
    /// この深さより下へは出ない (下の絵の橙色の線)。
    ///
    /// こちらも**どの字も収まるとは限らない。** 字の下に付く記号は越えることがあり、既定の
    /// 書体でも `Ç` の鉤はこの深さより下に出る。
    ///
    /// 大きさ 0 (``textSize(_:)``) では 0 を返す。
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
    ///     ![灰色の基準線から g と y が下へ伸び、その先を橙色の線が受け止めている](https://i.gyazo.com/0a2d00da9b0c0dc5c25d07c91f692b36.png)
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
    ///     ![灰色の縦長の枠の中に、折り返された白い日本語の文が収まっている](https://i.gyazo.com/bc93d54f4e7955623bca6efe2d339195.png)
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
    ///     ![左の枠に白い文が収まり、右の枠にその続きが水色で流れている](https://i.gyazo.com/cf93424b86d8b1e40f229e968c1e9095.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 返る値は「何行置いたか・どれだけの高さを使ったか・何が残ったか」。**続きを
    /// どこから描くかを自分で数え直さずに済む**ように返している。
    ///
    /// 縦の指定 (``textAlign(_:_:)``) は置いた塊全体に効く。矩形の中では基準線に
    /// 意味が無いので、基準線指定は上揃えと同じに扱う。
    ///
    /// **横の揃えは、行の末尾の空白を数えない。** 行をどこで折るかはこちらが決めるので、
    /// 折った行も段落の最後の行も、末尾の空白を除いた幅で揃える — 末尾に空白がいくつ
    /// 続いても、空白が無いときと同じ位置に揃う。``textWidth(_:)`` と点の形の
    /// ``text(_:_:_:)`` は末尾の空白も数える (渡した文字列を、渡した位置で終わらせる)。
    ///
    /// **改行しない空白 (U+00A0・U+202F・U+2007) は字と同じに扱う。** そこでは折らず、
    /// 切れ目の後ろでも消費せず、行の末尾にあっても幅に数える — 「10\u{00A0}km」の
    /// 数と単位は同じ行に残る。
    // shot: 1 snippet=82f3bb5e
    // shot: 2 snippet=6b763151
    @discardableResult
    public func text(_ string: String, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible)
        -> TextFlow
    {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        return canvas.text(string, a, b, c, d)
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
    ///     ![枠の中の英文が語の切れ目で折り返され、行末が不揃いになっている](https://i.gyazo.com/c21de78386e9d45de403d710c94b5065.png)
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
    ///     ![同じ英文が文字の切れ目で折り返され、行末が枠の右辺近くで揃っている](https://i.gyazo.com/6021ee7778f561ce5097349fc0b1e964.png)
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
    ///     ![黄色い線だけで縁取られた mokume — 画の内側は塗られていない](https://i.gyazo.com/03f1e65d5e6a6ab5037347aad603188d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **描くときと同じ送り**で並ぶので、``text(_:_:_:)`` と同じ位置・同じ字間になる。
    /// 返る点はいまの座標のままで、変換は掛かっていない。
    ///
    /// 字ごとに、外側の周が先・穴が後の順で並ぶ。曲線は直線の並びにほどいてあり、
    /// 細かさは曲線の大きさから決まる。
    ///
    /// 位置に数でない値・無限を渡すと空を返す。
    ///
    /// **周の分かれ方は書体の持ち方どおりで、書体と字によって変わる。** 既定の書体は
    /// `A` や `B` のような字を重なった部品で持つので、`A` は重なった外周がいくつも返り、
    /// 三角の穴は ``TextContour/isHole`` の立った周として現れない (重ねて塗れば絵は
    /// 合う)。同じ既定の書体でも `o` や `D` は外周と穴に分かれる。字を「外周 + 穴」の
    /// 1 つの形として扱いたい (三角形へ畳む・穴だけ別の色にする) なら、
    /// ``textFont(_:)`` で書体を指定する — `Helvetica` などでは `A` が外周 1 つと
    /// 穴 1 つになる。
    // shot: 1 snippet=e9e2ccf8
    public func textOutline(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) -> [TextContour] {
        let (x, y) = (x.asFloat, y.asFloat)
        return canvas.textOutline(string, x, y)
    }

    /// 文字列を描いたときに、墨が載る範囲を返す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(64)
    ///     text("mokume 1", 40, 170)
    ///     if let bounds = textBounds("mokume 1", 40, 170) {
    ///         noFill()
    ///         stroke(242, 115, 64)
    ///         strokeWeight(2)
    ///         rect(bounds.x, bounds.y, bounds.width, bounds.height)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い mokume 1 の墨を、橙の細い枠がぴったり囲んでいる -->
    ///     ![白い mokume 1 の墨を、橙の細い枠がぴったり囲んでいる](https://i.gyazo.com/c2df83e4af00939a3c923995a23c0426.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 同じ引数で ``text(_:_:_:)`` を描いたときの墨を囲む。**送り幅とは違う** —
    /// ``textWidth(_:)`` は字の左右に書体が付けた余白を含み、この枠は含まない。字の中心を
    /// 送り幅で取ると、余白の大きい字 (`1` など) は墨が片寄って見える。墨の中心は
    /// `bounds.x + bounds.width / 2` で取る。
    ///
    /// 枠の `x`・`y` は**いつも左上**で、``rectMode(_:)`` に依らない。返る値は**いまの座標の
    /// まま**で、変換は掛かっていない — 同じ変換の下で ``rect(_:_:_:_:)`` へ渡せば、描いた字を
    /// 囲む。``textAlign(_:_:)`` の横・縦と、行送り・改行・``textStyle(_:)`` は、描くときと
    /// 同じに効く。空白は送りだけを進め、墨には数えない。
    ///
    /// 墨が無いときは `nil` を返す — 空の文字列・空白や改行だけの文字列・大きさ 0
    /// (``textSize(_:)``)・位置に数でない値や無限を渡したとき。
    // shot: 1 snippet=f7ecb144
    public func textBounds(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) -> TextBounds? {
        let (x, y) = (x.asFloat, y.asFloat)
        return canvas.textBounds(string, x, y)
    }
}
