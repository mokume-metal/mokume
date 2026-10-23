// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 文字。
extension SketchPart {
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
    ///
    /// **字は Unicode のスカラ 1 つずつ引き当てて並べ、組版はしない。** 合字にしたり、
    /// 複数のスカラを 1 つの字へまとめたりはしないので、**複数のスカラでできた絵文字は
    /// 1 字にならず、部品ごとに描かれる**。肌色の修飾子を付けた `👍🏽` (親指と肌色の四角が
    /// 別々に出る)・国旗の `🇯🇵` (地域指示記号 2 つ)・ZWJ で繋いだ `👨‍👩‍👧` (3 人が別々に出る)・
    /// 異体字セレクタを付けた `❤️`・囲みを付けた `1️⃣` は、その指定が読まれず、基の字と部品が
    /// 別々に引き当てられる。幅も部品の幅の和になる (``textWidth(_:)``)。部分の幅を足すと
    /// 全体の幅と一致する、という約束と引き換えの選び方である。
    /// 1 字で出したい絵文字は、1 つのスカラで書ける形 (`👍`) を使う。
    ///
    /// **``scale(_:_:)`` で拡大した字は、拡大に合わせた画素で焼き直して置く**ので、伸ばしても縁は
    /// 鮮明なままである。ただし**保持した形 (``createShape(_:)``) の中の字は、記録した時点の変換で
    /// 焼く** — ``shape(_:_:_:)`` で拡大して置いても焼き直さない (``textSize(_:)``)。
    // shot: 1 snippet=0c8959e5
    // shot: 2 snippet=3044f8bc
    public func text(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
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
    /// **字は、この大きさに、``scale(_:_:)`` などの変換が拡げる分を掛けた大きさの画素に焼いてから置く。**
    /// `textSize(16)` を `scale(20, 20)` で伸ばした `a` は、`textSize(320)` で描いた `a` と同じ大きさ
    /// 約 320 画素で焼かれるので、縁は鮮明なままである。字形の形と並び (送り幅・整列・
    /// ``textWidth(_:)``・``textBounds(_:_:_:)``) は `textSize` のままで、拡大では変わらない。
    ///
    /// **拡大は、変換の x・y の写り (2×2) の最大の伸びを、描く画素で測る。** ``SketchSettings/pixelDensity``
    /// を下げた面では描く画素が粗いぶん小さく数え、細かさ 0.5 の `scale(2)` は 1 対 1 で、これまでどおり
    /// 焼き直さない。回すだけなら 1 で、軸ごとに倍率が違えば大きいほうで決まる。1 オクターブを 8 段に
    /// 刻んだ段に丸めて焼き、拡大が 1 以下の字は `textSize` の大きさで焼いたまま置く。段が変わるたびに
    /// 焼き直すので、拡大を動かし続ける絵は、段の境で字を焼き直す。**奥行きは見ない** — `rotateY` などで
    /// 傾けた字に遠近は掛からず、遠近で大きくなった分も焼く大きさには数えない (平面の層・[ADR-0021] 決定 2)。
    /// 傾いて x が縮んだ分も、最大の伸び (縦のまま) に隠れて数えない。
    ///
    /// **焼く量は 3 つで頭打ちにする。どれも字は欠けず、低い段か近い段の画素で描く。**
    /// - **1 字の画素は 4 MiB まで** (1 字の大きさが em で 700 画素ほど。字形で違う)。越える段は焼かず、
    ///   収まる段まで下げる。拡大したのに縁がぼけるときは、初回だけ知らせる
    /// - **1 フレームに新しく焼く拡大した字は 64 字・2 MiB まで**。越えた字は、焼いてある近い段 (無ければ
    ///   `textSize` の大きさ) で描き、次のフレームで先に焼く。**次のフレームが来ないときは、この上限を外して
    ///   要る段で焼き切る** — 書き出しの最後の 1 枚・`noLoop()` で止めたフレーム・時刻を指した 1 枚
    /// - **拡大した字は、焼き場の面の上から 4 分の 3 まで**。残りは拡大しない字のために空けておく
    ///
    /// **保持した形 (``createShape(_:)``) の中の字は、記録した時点の変換で焼く。** 記録は変換を単位から
    /// 始めるので、記録の中で ``scale(_:_:)`` した字はその拡大で焼くが、記録の外で ``shape(_:_:_:)`` に
    /// 掛けた拡大では焼き直さない (拡大して置くと、焼いた画素の拡大になり、縁がぼける)。鮮明に置きたい字は、
    /// 記録の中で拡大してから `text()` を呼ぶか、置く側で `text()` を直に呼ぶ。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    ///
    /// - Note: 文字の大きさは**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// - Note: 大きさごとに書体を引き当てて控える。控えは面ごとに 64 通りまでで、しばらく
    ///   使っていない大きさから捨てる。**1 フレームに 64 通りより多くの大きさを使うと、
    ///   毎フレーム書体を引き当て直す** (字の引き当てもやり直す)。大きさの種類を絞るか、
    ///   同じ大きさで書いて ``scale(_:_:)`` で伸ばす。伸ばした字は拡大に合わせた画素で焼かれる
    ///   (上) ので、縁は鮮明なまま、書体の控えも増えない。
    // shot: 1 snippet=a8143a74
    // shot: 2 snippet=02dd14ba
    public func textSize(_ size: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
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
    /// 既定へ戻る。名前は、CoreText が名前として引けるもの — PostScript 名 (`HiraginoSans-W3`)・
    /// ファミリー名・フルネーム (`Hiragino Sans W3`)・書体が持つ各言語の名前
    /// (`ヒラギノ角ゴシック W3`) — で渡す。書体メニューや Font Book に出る名前は、CoreText の名前の
    /// 索引に載らないもの (日本語表示の `ヒラギノ角ゴ 簡体中文 W3`・後から入れた書体の表示名など) も
    /// 引ける。この環境の書体の表示言語の名前と、書体が持つ全言語の名前から、初めて必要になった
    /// ときに 1 度だけ表を作って引く。名前が複数の面に当たるとき (ファミリー名など) は、CoreText が
    /// 選ぶ 1 面で描く。表は最初に必要になったときの書体から作るので、その後に入れた書体の、索引に
    /// 載らない名前は、起動し直すまで引けない。
    ///
    /// 指定した書体が覆えない文字 (欧文の書体に日本語を渡した場合など) は、
    /// この環境が持つ別の書体から引いて描く。
    ///
    /// - Note: 書体は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=38a1d815
    public func textFont(_ name: String) { Self.liveCanvas()?.textFont(name) }

    /// ファイルから読んだ書体 (``Font``) で描く。``loadFont(_:)`` が返した値を渡す。
    ///
    /// 読んだ書体で描くので、作品に書体を同梱でき、配った先の Mac に同じ書体が入っているかに絵が
    /// 依らない。``textWidth(_:)``・``textBounds(_:_:_:)``・``textOutline(_:_:_:)`` も同じ書体で測る。
    /// ``noTextFont()`` で既定の書体へ戻り、``textFont(_:)-(String)`` で名前の書体へ替わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var display: Font? -->
    ///     ```swift
    ///     func setup() {
    ///         display = try? loadFont("/System/Library/Fonts/SFNS.ttf")
    ///     }
    ///
    ///     func draw() {
    ///         background(18, 20, 28)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         if let display { textFont(display) }
    ///         textSize(72)
    ///         var x: Float = 24
    ///         for (index, letter) in "mokume".enumerated() {
    ///             textWeight(500 + 400 * sin(Float(index) * 0.9))
    ///             text(String(letter), x, 160)
    ///             x += textWidth(String(letter))
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 読み込んだ書体の mokume が横に並び、字ごとに太さが違う -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **字の太さは書体が持つ面で決まる。** 可変書体 (上の `SFNS.ttf`) は ``textWeight(_:)`` の太さを
    /// そのまま描き、持たない書体は最も近い太さの面で描く。太字・斜体の面を持たない書体に
    /// ``textStyle(_:)`` を頼むと、引けた面で描いて警告を 1 度出す。
    ///
    /// - Note: 書体は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 後で撮る
    public func textFont(_ font: Font) { Self.liveCanvas()?.textFont(font) }

    /// 書体の指定をやめ、この環境の既定の書体へ戻す。
    ///
    /// 下の絵の **1 行目と 3 行目は同じ書体**である — 間で ``textFont(_:)-(String)`` を挟んでも、
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
    public func noTextFont() { Self.liveCanvas()?.noTextFont() }

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
    /// 書体がその太さ・傾きの面を持たなければ (ヒラギノ角ゴシックの斜体など)、引けた面 (元の面か、
    /// 太字だけの面など) で描き、警告を 1 度出す。`.boldItalic` で太斜体の面が無い書体は、
    /// 太字の面・斜体の面の順に、引ける面で描く — 引ける性質を捨てない。**太字も斜体も持つのに
    /// 太斜体だけ無い書体 (Futura など) は、斜体を捨てて太字の立体で描く。**
    ///
    /// 書体が覆えず別の書体から引く字 (欧文の書体に渡した日本語・絵文字) は、引いた書体が持つ面で
    /// 描く — 欧文の斜体に混ぜた日本語は立ったままになる (傾けて合成はしない)。**引いた書体が頼んだ
    /// 太さ・傾きの面を持つなら、その面で描く** — 太字の面を持たない欧文の書体 (Apple Chancery など)
    /// に `.bold` を頼んで混ぜた日本語は、ヒラギノ明朝の太字 (W6) で描かれる。面の選び方は指定した書体と
    /// 同じ順 (太斜体 → 太字だけ → 斜体だけ) で、合成はしない。その面が頼んだ太さ・
    /// 傾きを持たなければ、上とは別に警告を 1 度出し、字・引いた書体・描いた面を名乗る。
    ///
    /// **家族をまたいで頼んだ面を探すことはしない。** 引いた書体の家族に頼んだ面が無ければ (太字を持たない
    /// 欧文の書体に混ぜたハングルの AppleMyungjo・タイ文字の Ayuthaya など)、字は細いまま描く。環境の
    /// 候補の列にその字を頼んだ面で持つ別の家族が入っておらず、代役を mokume が決めると指定した書体から
    /// 離れるからである。警告は、**引いた書体の家族に頼んだ面が無い**ことと、その字を頼んだ面で持つ書体の
    /// 例 (`textFont()` に渡せる名前。環境から引き、見つかったときだけ) を名乗る。
    ///
    /// 色の字形を持つ書体 (Apple Color Emoji) から引いた字は太さ・傾きの面を持ちようがないので警告しない。
    /// ❤ (U+2764) のように単色の書体から引く字は警告する。見えない字 (異体字セレクタ・和文の空白) と、
    /// どの書体も持たない字の代わりに描く豆腐も警告しない。
    ///
    /// - Note: 字の太さと傾きは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=dad4af7f
    public func textStyle(_ style: TextStyle) { Self.liveCanvas()?.textStyle(style) }

    /// これから描く文字の太さ。**100 (細い) から 900 (太い) まで**で、400 が標準、700 が ``TextStyle/bold``。
    /// 整数や `Double` の変数もそのまま渡せる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(18, 20, 28)
    ///     noStroke()
    ///     fill(242, 242, 242)
    ///     textSize(44)
    ///     textWeight(200)
    ///     text("Mokume", 24, 80)
    ///     textWeight(400)
    ///     text("Mokume", 24, 150)
    ///     textWeight(900)
    ///     text("Mokume", 24, 220)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ語が 3 行。上は細く、真ん中は標準、下は太い -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **可変書体は、太さをそのまま描く。** 既定の書体 (システムの書体) と、``loadFont(_:)`` で読んだ
    /// 可変書体は、`300` と `800` で字の幅も形も違う。40 画素の `M` の送り幅は、既定の書体で
    /// `textWeight(300)` なら約 32.9、`textWeight(800)` なら約 35.2 になる。
    ///
    /// **可変でない書体は、最も近い太さの面で描く。** `Helvetica` なら軽い面 (300)・標準 (400)・太字 (700) の
    /// 3 つのうち近いものが選ばれ、`textWeight(900)` は太字になる。頼んだ太さから 100 を超えて離れた面しか
    /// 無いとき (面が 1 つしかない書体に 700 を頼んだ場合など) は、使った面を名乗って警告を 1 度出す。
    ///
    /// **端は丸める。** 受け取った値は整数に丸め、100 未満は 100、900 超は 900 にして、1 度だけ知らせる。
    /// 数でない値・無限は 1 度だけ知らせて、前の太さのままにする。`500.2` と `500.4` は同じ太さ (500) で、
    /// `500` と `501` は別の太さである。
    ///
    /// **``textStyle(_:)`` とは、後から呼んだほうが勝つ。** `textStyle(.bold)` の後の `textWeight(300)` は
    /// 300 で描き、`textWeight(300)` の後の `textStyle(.bold)` は太字で描く。`textStyle(.italic)` の後の
    /// `textWeight(300)` は、傾きを残して 300 で描く。
    ///
    /// - Note: 太さごとに字を画素へ焼くので、**毎フレーム太さを動かすと、字ごとに太さの数だけ焼き直す**。
    ///   大きさ (``textSize(_:)``) を毎フレーム動かすのと同じ代償で、焼き場の頁が埋まれば頁を替えて焼き
    ///   直すので、字は欠けない。滑らかさの要らない動きなら、整数の太さが 10 や 20 の刻みになるよう
    ///   丸めてから渡すと、焼き直しが減る。
    ///
    /// - Note: 字の太さは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 後で撮る
    public func textWeight(_ weight: some ScalarConvertible) { Self.liveCanvas()?.textWeight(weight) }

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
        guard let canvas = Self.liveCanvas() else { return }
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
        guard let canvas = Self.liveCanvas() else { return }
        let leading = leading.asFloat
        canvas.textLeading(leading)
    }

    /// 文字列を描いたときの幅 (画素)。
    ///
    /// **Unicode のスカラ 1 つずつの送り幅の合計**なので、部分に切って足すと全体と一致する。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    /// 大きさ 0 (``textSize(_:)``) では 0 を返す。
    ///
    /// **組版をしない**ので、複数のスカラでできた字 (肌色の修飾子を付けた `👍🏽`・国旗の
    /// `🇯🇵`・ZWJ で繋いだ絵文字) は 1 字の幅にならず、部品の幅の和になる。`textWidth("👍🏽")` は
    /// `textWidth("👍") + textWidth("🏽")` と等しい (描かれ方は ``text(_:_:_:)``)。
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
    public func textWidth(_ string: String) -> Float { Self.liveCanvas(.read(returning: "0"))?.textWidth(string) ?? 0 }

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
    public func textAscent() -> Float { Self.liveCanvas(.read(returning: "0"))?.textAscent() ?? 0 }

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
    public func textDescent() -> Float { Self.liveCanvas(.read(returning: "0"))?.textDescent() ?? 0 }

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
        // 外から呼ばれたら何も置かない。置けなかった文字は全部が残りになる
        guard let canvas = Self.liveCanvas() else { return TextFlow(lineCount: 0, height: 0, remainder: string) }
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
    /// **語の切れ目は、Unicode の行分割の規則 (UAX #14) で決まる。** 欧文は空白の後ろ
    /// (ハイフンやスラッシュの後ろも) で折れ、空白の無い和文は字と字の間で折れる。
    /// 行頭に「、」「。」「」」は来ず、行末に「「」は残らない。**小書きの仮名と長音の前では
    /// 折りうる** (厳しい禁則は掛けない)。``TextWrap/character`` は、この規則を見ずに
    /// どの字の間でも折る。
    ///
    /// - Note: 折り返し方は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=9d76cf16
    // shot: 2 snippet=36f2b043
    public func textWrap(_ mode: TextWrap) { Self.liveCanvas()?.textWrap(mode) }

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
    ///     ![黄色い線だけで縁取られた mokume — 画の内側は塗られていない](https://i.gyazo.com/6065c72b010a01cbc5893c9a76a7798f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **描くときと同じ送り**で並ぶので、``text(_:_:_:)`` と同じ位置・同じ字間になる。
    /// 返る点はいまの座標のままで、変換は掛かっていない。
    ///
    /// 字ごとに、外側の周が先・穴が後の順で並ぶ。曲線は直線の並びにほどいてあり、
    /// 細かさは**文字の大きさ (``textSize(_:)``) の寸法で測った**曲線の大きさから決まる。
    /// 変換は見ないので、``scale(_:_:)`` の下で取り出しても点は増えない — 拡大して描くと
    /// 点の間が倍率のぶん開き、曲線が折れ線に見えてくる。**拡大して描く輪郭は、
    /// ``textSize(_:)`` を大きくして取り出すほうが細かい。** 既定の書体の `a` は、
    /// `textSize(320)` で取り出すと、`textSize(16)` で取り出したとき (`scale(20, 20)` の
    /// 下でも同じ) の 5 倍あまりの点になる。
    ///
    /// **点の間隔は揃っていない。** 直線の辺には端の 1 点しかなく、`I` の縦画は角の点だけになる。
    /// 点を等間隔に取りたい (粒を字の形に並べる) ときは、``textOutline(_:_:_:spacing:)`` に
    /// 間隔を画素で渡す。
    ///
    /// 位置に数でない値・無限を渡すと空を返す。
    ///
    /// **周の分かれ方は書体の持ち方どおりで、書体と字によって変わる。** 既定の書体は
    /// `A` や `B` のような字を重なった部品で持つので、`A` は重なった外周がいくつも返り、
    /// 三角の穴は ``TextContour/isHole`` の立った周として現れない (重ねて塗れば絵は
    /// 合う)。同じ既定の書体でも `o` や `D` は外周と穴に分かれる。字を「外周 + 穴」の
    /// 1 つの形として扱いたい (三角形へ畳む・穴だけ別の色にする) なら、
    /// ``textFont(_:)-(String)`` で書体を指定する — `Helvetica` などでは `A` が外周 1 つと
    /// 穴 1 つになる。
    ///
    /// 色で描かれる字 (絵文字) は輪郭を持たない絵なので、周を返さない (送りは進める)。
    // shot: 1 snippet=e9e2ccf8
    public func textOutline(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) -> [TextContour] {
        let (x, y) = (x.asFloat, y.asFloat)
        return Self.liveCanvas(.read(returning: "[]"))?.textOutline(string, x, y) ?? []
    }

    /// 文字列の輪郭を、点の間隔を揃えて取り出す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 217, 89)
    ///     textSize(88)
    ///     for contour in textOutline("mokume", 24, 170, spacing: 7) {
    ///         for point in contour.points { circle(point.x, point.y, 4) }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色い粒が、mokume の字の縁に等しい間隔で並んでいる -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``textOutline(_:_:_:)`` の点は曲線の折れ目で、**直線の辺には端の 1 点しかない** — `I` や `T` の
    /// 縦画は角にしか点が無く、粒を並べると縦画だけ抜ける。`spacing` を渡すと、周ごとに周の長さを
    /// 均等に割る点へ取り直すので、直線の辺の途中にも点が並ぶ。粒を字の形に並べる定番は、これで書ける。
    ///
    /// **`spacing` は画素で渡す。** 隣り合う点の距離は `spacing` 以下で、周の長さを均等に割った値
    /// (最後の点から最初の点へ戻る間も同じ) になる。周が短くて `spacing` で割り切れなくても、
    /// 周ごとに少なくとも 3 点を返し、周は潰れない。取り直した点は折れ目の点を結んだ線の上にあり、
    /// 角は丸まらない代わりに、点が角にちょうど乗るとは限らない。
    ///
    /// **周の並び・``TextContour/isHole``・描くときと同じ送りは、``textOutline(_:_:_:)`` と同じ。**
    /// 点の数だけが変わる。同じ入力からはいつも同じ点が返る。
    ///
    /// p5.js の `textToPoints` / `textToContours` の `sampleFactor` は書体の単位に対する比で、字の
    /// 大きさで間隔が変わる。mokume の `spacing` は画素なので、``textSize(_:)`` を変えても間隔は
    /// 変わらない。`sampleFactor` から写すときは、字の大きさにあわせて画素へ直す。
    ///
    /// `spacing` が 0 以下・数でない値・無限のときは、1 度だけ知らせて、`spacing` を省いたとき
    /// (``textOutline(_:_:_:)``) と同じ折れ目の点を返す。極端に小さい `spacing` は、1 つの周の
    /// 点を 65536 までに抑える。
    // shot: 後で撮る
    public func textOutline(
        _ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible,
        spacing: some ScalarConvertible
    ) -> [TextContour] {
        let (x, y, spacing) = (x.asFloat, y.asFloat, spacing.asFloat)
        return Self.liveCanvas(.read(returning: "[]"))?.textOutline(string, x, y, spacing: spacing) ?? []
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
    /// 同じに効く。空白は送りだけを進め、墨には数えない。色で描かれる字 (絵文字) も、
    /// 描いた絵の墨を同じく囲む。
    ///
    /// 墨が無いときは `nil` を返す — 空の文字列・空白や改行だけの文字列・大きさ 0
    /// (``textSize(_:)``)・位置に数でない値や無限を渡したとき。
    // shot: 1 snippet=f7ecb144
    public func textBounds(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) -> TextBounds? {
        let (x, y) = (x.asFloat, y.asFloat)
        return Self.liveCanvas(.read(returning: "nil"))?.textBounds(string, x, y)
    }
}
