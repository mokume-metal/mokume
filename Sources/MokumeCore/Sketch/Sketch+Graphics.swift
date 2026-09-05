// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 描き場所と、貼る絵。
extension Sketch {
    /// 画面とは別の描き場所を作る。**焼いた絵を置いたり、重ねたり、積み上げたりできる。**
    ///
    /// <!-- example: 文脈 var trail: Canvas! -->
    /// ```swift
    /// func setup() {
    ///     trail = try! createGraphics(400, 400)
    /// }
    ///
    /// func draw() {
    ///     trail.beginDraw()
    ///     trail.fill(255, 102, 51)
    ///     trail.circle(mouseX, mouseY, 20)   // 消さないので跡が残る
    ///     trail.endDraw()
    ///
    ///     image(trail, 0, 0)
    /// }
    /// ```
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() {
    ///         pad = try! createGraphics(160, 160)
    ///         pad.beginDraw()
    ///         pad.background(38, 46, 61)
    ///         pad.noStroke()
    ///         pad.fill(242, 115, 64)
    ///         pad.circle(50, 50, 70)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(pad, 20, 70)
    ///         image(pad, 220, 90, 100, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ描き場所が 2 つ。左は等倍で大きく、右は小さく。どちらも左上寄りに橙色の円 -->
    ///     ![同じ描き場所が 2 つ。左は等倍で大きく、右は小さく。どちらも左上寄りに橙色の円](https://i.gyazo.com/606d841b2d2b83c964e3f9a1e7491381.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 返るのは画面と同じ ``Canvas``
    ///
    /// **2D も立体も字も効果も、画面と同じように書ける。** 描き場所を別の型にすると、
    /// 「効果に渡せる絵」と「自分で描ける絵」が分かれてしまう ([ADR-0023] 決定 1)。
    ///
    /// ## 既定で透けていて、自動では消えない
    ///
    /// 作った時点の中身は透明で、以後は**こちらが ``Canvas/background(_:)-(LinearRGBA)`` を呼ぶまで
    /// 消えない**。消えないからこそ、前のフレームの上に描き足して跡が積み上がる絵が
    /// 書ける。毎フレーム消したいときは `trail.background(.transparent)` を書く。
    ///
    /// ## 描き換えても、置いた時点の絵が出る
    ///
    /// 同じフレームで置いてから描き換えて、また置ける。**先に置いた場所は描き換えに
    /// 引きずられない**ので、途中の姿と最後の姿を並べられる。
    ///
    /// - Throws: 描き場所を確保できないときに ``RenderFailure``。**組み立てのときに
    ///   投げる** ([ADR-0020] 決定 5) ので、`setup()` で作って持ち回る。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    // shot: 1 snippet=952dfdc7
    public func createGraphics(_ width: Int, _ height: Int) throws(RenderFailure) -> Canvas {
        try canvas.createGraphics(width, height)
    }

    /// 描き場所を等倍で置く。左上の角が (`x`, `y`) に来る。
    ///
    /// 置くのは**そのとき描き切れている絵**なので、``Canvas/endDraw()`` を呼ぶ前に
    /// 置くと 1 フレーム前の絵が出る (そのときは警告が出る)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() {
    ///         pad = try! createGraphics(120, 120)
    ///         pad.beginDraw()
    ///         pad.background(51, 71, 102)
    ///         pad.fill(242, 115, 64)
    ///         pad.circle(40, 40, 60)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(pad, 90, 60)
    ///         stroke(242, 242, 242)
    ///         strokeWeight(2)
    ///         line(50, 60, 90, 60)
    ///         line(90, 20, 90, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 120 画素四方の描き場所が等倍で置かれ、白い 2 本の線が外からその左上の角を指している -->
    ///     ![120 画素四方の描き場所が等倍で置かれ、白い 2 本の線が外からその左上の角を指している](https://i.gyazo.com/f804371a6e909e246cec01104e3f565b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b01c8b0c
    public func image(_ graphics: Canvas, _ x: Float, _ y: Float) {
        canvas.image(graphics, x, y)
    }

    /// 描き場所を、指定した寸法に合わせて置く。
    ///
    /// 4 つの数の読み方は ``imageMode(_:)`` が決める。絵と同じ扱いなので、
    /// ``tint(_:)`` の色掛けも同じように効く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() {
    ///         pad = try! createGraphics(120, 120)
    ///         pad.beginDraw()
    ///         pad.background(51, 71, 102)
    ///         pad.fill(242, 115, 64)
    ///         pad.circle(40, 40, 60)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(pad, 20, 60, 160, 160)
    ///         tint(128, 255, 255)
    ///         image(pad, 210, 90, 100, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に大きく、右に小さく同じ描き場所。右は赤が抑えられて青緑に寄っている -->
    ///     ![左に大きく、右に小さく同じ描き場所。右は赤が抑えられて青緑に寄っている](https://i.gyazo.com/5b6f3f97e602e14c11974eccd3bb9063.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=eca56bd9
    public func image(_ graphics: Canvas, _ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        canvas.image(graphics, a, b, c, d)
    }

    /// 描き場所の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**描き場所の中のどこを切り出すか**。切り出しが
    /// 外へ出ても落ちず、重なった分だけが出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() {
    ///         pad = try! createGraphics(120, 120)
    ///         pad.beginDraw()
    ///         pad.background(51, 71, 102)
    ///         pad.fill(242, 115, 64)
    ///         pad.circle(40, 40, 60)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(pad, 20, 60, 160, 160)
    ///         image(pad, 210, 60, 160, 160, 0, 0, 60, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に描き場所の全体、右はその左上 4 分の 1 だけを同じ大きさへ引き伸ばしたもの -->
    ///     ![左に描き場所の全体、右はその左上 4 分の 1 だけを同じ大きさへ引き伸ばしたもの](https://i.gyazo.com/0327e1ed6bf37fd144de1c21c9b417f7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=625e4d78
    public func image(
        _ graphics: Canvas, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        canvas.image(graphics, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// これから置く塗りに絵を貼る。
    ///
    /// <!-- example: 文脈 var grain: Image! -->
    /// ```swift
    /// texture(grain)
    /// box(200)            // 6 面それぞれに 1 枚ずつ貼られる
    /// sphere(80)          // 経度と緯度に巻かれる
    /// rect(0, 0, 300, 200)  // 平面にも同じように効く
    /// ```
    ///
    /// **効くのは塗りだけ。** 輪郭・端点・角・立体の線と点・文字・周囲には貼られない
    /// ので、`stroke()` を残したまま貼っても縁は線の色のまま出る。
    ///
    /// **貼った絵は、光と材質を通ったあとの色に掛かる。** 立体では陰影がそのまま残り、
    /// 平面では ``fill(_:)`` が色掛けになる (白なら絵がそのまま出る)。
    ///
    /// 読み取り位置は組み込みの形が自分で持つ (箱は 6 面それぞれに 1 枚、球は経度と
    /// 緯度、円柱と円錐は側面の一周と蓋の円、輪は 2 つの一周)。自分で並べた形では
    /// ``vertex(_:_:_:_:)`` で書け、書かなければ形の囲みの箱から決まる。
    ///
    /// **描き方なのでフレームを越える** — 塗りや線と同じく、一度書けば
    /// ``noTexture()`` を呼ぶまで続き、``push()`` / ``pop()`` で積める。
    public func texture(_ image: Image) { canvas.texture(image) }

    /// これから置く塗りに描き場所を貼る。
    ///
    /// **読み込んだ絵とまったく同じに扱える。** 毎フレーム描き直した描き場所を
    /// 立体に貼れば、面の上で動く絵になる。
    ///
    /// <!-- example: 文脈 var dial: Canvas! -->
    /// ```swift
    /// texture(dial)
    /// box(200)
    /// ```
    ///
    /// - Note: 貼る絵は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func texture(_ graphics: Canvas) { canvas.texture(graphics) }

    /// 絵を貼るのをやめる。
    ///
    /// - Note: 貼る絵は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func noTexture() { canvas.noTexture() }
}
