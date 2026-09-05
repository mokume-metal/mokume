// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、頂点を並べて作る形。
extension Sketch {
    /// 頂点を並べ始める。``vertex(_:_:)`` で点を置き、``endShape(_:)`` で描く。
    ///
    /// **同じ点の並びが、読み方 (``VertexKind``) で別の絵になる。** 下の 4 枚はどれも
    /// まったく同じ 6 点を渡していて、変えたのは `beginShape` の引数だけである。
    ///
    /// 既定の ``VertexKind/polygon`` は、置いた点を順に結んだ**周をなす 1 つの形**として
    /// 読む。**凹んでいても穴があってもよい**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     beginShape(.polygon)
    ///     vertex(50, 60)
    ///     vertex(230, 30)
    ///     vertex(350, 90)
    ///     vertex(340, 250)
    ///     vertex(150, 275)
    ///     vertex(60, 215)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色に塗られた、角が 6 つのいびつな面が 1 つ -->
    ///     ![水色に塗られた、角が 6 つのいびつな面が 1 つ](https://i.gyazo.com/63f8783d7f22a1edd1afaaccdaa3c78d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``VertexKind/points`` は 1 点ずつ独立した点として読む。塗りではなく**線の色と
    /// 太さ**で出るので、``noStroke()`` のままだと何も描かれない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 191, 242)
    ///     strokeWeight(18)
    ///     beginShape(.points)
    ///     vertex(50, 60)
    ///     vertex(230, 30)
    ///     vertex(350, 90)
    ///     vertex(340, 250)
    ///     vertex(150, 275)
    ///     vertex(60, 215)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の丸い点が 6 つ、輪を描くように散らばっている -->
    ///     ![水色の丸い点が 6 つ、輪を描くように散らばっている](https://i.gyazo.com/5e60f18f38f0e074989d518ca091b3b2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``VertexKind/lines`` は 2 点ずつ独立した線として読む。**繋がらない** — 6 点なら
    /// 3 本の線分になり、余った点は捨てられる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(89, 191, 242)
    ///     strokeWeight(8)
    ///     beginShape(.lines)
    ///     vertex(50, 60)
    ///     vertex(230, 30)
    ///     vertex(350, 90)
    ///     vertex(340, 250)
    ///     vertex(150, 275)
    ///     vertex(60, 215)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の太い線分が 3 本、互いに繋がらず離れて並んでいる -->
    ///     ![水色の太い線分が 3 本、互いに繋がらず離れて並んでいる](https://i.gyazo.com/033b018714cb3207817871800b24cbf1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``VertexKind/triangles`` は 3 点ずつ独立した三角形として読む。こちらは塗られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     beginShape(.triangles)
    ///     vertex(50, 60)
    ///     vertex(230, 30)
    ///     vertex(350, 90)
    ///     vertex(340, 250)
    ///     vertex(150, 275)
    ///     vertex(60, 215)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の平たい三角形が 2 つ、上と下に離れて並んでいる -->
    ///     ![水色の平たい三角形が 2 つ、上と下に離れて並んでいる](https://i.gyazo.com/d82039440a24ef5668f3fec4d71e5d2e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 奥行きを持たせる
    ///
    /// 頂点を ``vertex(_:_:_:)`` (奥行きつき) で置くと、その形は**立体**になる。
    /// 立体は奥行きを見て前後が決まり、光を受ける。**同じ道具のまま**なので、穴も
    /// 輪郭も頂点ごとの色も平面と同じように効く。
    ///
    /// ```swift
    /// beginShape()
    /// vertex(-40, -40, 0)
    /// vertex(40, -40, 30)
    /// vertex(40, 40, 0)
    /// vertex(-40, 40, 30)
    /// endShape(.close)
    /// ```
    ///
    /// ## 頂点ごとの色
    ///
    /// 頂点を置く前に ``fill(_:)`` を変えると、**その頂点からの塗りが変わる** —
    /// 色は頂点の間でなめらかに移る。平面でも立体でも同じように効く。
    /// 線の色は形を閉じるときのものが使われる (頂点ごとには変わらない)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     beginShape()
    ///     fill(242, 115, 64)
    ///     vertex(200, 40)
    ///     fill(89, 191, 242)
    ///     vertex(350, 250)
    ///     fill(242, 217, 89)
    ///     vertex(60, 230)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・水色・黄の 3 色が、1 つの三角形の中でなめらかに混ざっている -->
    ///     ![橙・水色・黄の 3 色が、1 つの三角形の中でなめらかに混ざっている](https://i.gyazo.com/647d74d316aa1320886e1f84268065fa.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=445ca5af
    // shot: 2 snippet=c3c942c1
    // shot: 3 snippet=603b8a4f
    // shot: 4 snippet=67509c80
    // shot: 5 snippet=1eefdc11
    public func beginShape(_ kind: VertexKind = .polygon) { canvas.beginShape(kind) }

    /// 頂点を 1 つ置く。
    ///
    /// **置いた順にそのまま結ばれる。** 周は凹んでいてもよく、へこみはへこみのまま塗られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     beginShape()
    ///     vertex(60, 40)
    ///     vertex(340, 40)
    ///     vertex(340, 130)
    ///     vertex(200, 130)
    ///     vertex(200, 260)
    ///     vertex(60, 260)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上が横いっぱいに広がり、そこから左半分だけが下へ伸びた橙色の面 -->
    ///     ![上が横いっぱいに広がり、そこから左半分だけが下へ伸びた橙色の面](https://i.gyazo.com/385be95c1bff7165c857831e334f3955.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **順が違えば別の形になる。** 同じ 4 点でも、2 番目と 3 番目を入れ替えると周が
    /// 自分自身と交差する。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(89, 191, 242)
    ///     strokeWeight(5)
    ///     beginShape()
    ///     vertex(80, 60)
    ///     vertex(330, 250)
    ///     vertex(320, 70)
    ///     vertex(70, 240)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の線が中央で交差し、左右に縦の辺を持つ蝶ネクタイのような形になっている -->
    ///     ![水色の線が中央で交差し、左右に縦の辺を持つ蝶ネクタイのような形になっている](https://i.gyazo.com/1c4621f3d160c15325d59205f0715563.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=c25c6dcf
    // shot: 2 snippet=be9944e2
    public func vertex(_ x: Float, _ y: Float) { canvas.vertex(x, y) }

    /// 奥行きを持つ頂点を 1 つ置く。**この形は立体になる。**
    ///
    /// 1 つでもこの形で置けば、その形は最後まで立体として扱われる — 途中で
    /// ``vertex(_:_:)`` を混ぜてもよく、そちらは奥行き 0 の頂点になる。
    public func vertex(_ x: Float, _ y: Float, _ z: Float) { canvas.vertex(x, y, z) }

    /// 貼る絵の読み取り位置つきで頂点を 1 つ置く。
    ///
    /// `u`・`v` は**貼る絵の画素**で書く (``image(_:_:_:_:_:_:_:_:_:)-(Image,_,_,_,_,_,_,_,_)``
    /// の切り出しと同じ単位)。``texture(_:)-(Image)`` で絵を束ねていなければ、書いても
    /// 何も起きない。
    ///
    /// <!-- example: 文脈 var grain: Image! -->
    /// ```swift
    /// texture(grain)
    /// beginShape()
    /// vertex(0, 0, 0, 0)                                  // 絵の左上を形の左上へ
    /// vertex(200, 0, Float(grain.width), 0)
    /// vertex(200, 200, Float(grain.width), Float(grain.height))
    /// vertex(0, 200, 0, Float(grain.height))
    /// endShape(.close)
    /// ```
    public func vertex(_ x: Float, _ y: Float, _ u: Float, _ v: Float) {
        canvas.vertex(x, y, u, v)
    }

    /// 奥行きと読み取り位置を持つ頂点を 1 つ置く。**この形は立体になる。**
    ///
    /// 単位は ``vertex(_:_:_:_:)`` と同じ (貼る絵の画素)。
    ///
    /// **書かなかった頂点は、形の囲みの箱から求まる** — 横と縦の広がりを 0…1 に写す。
    /// 一部にだけ書いた形では、書いた頂点だけがそのとおりに、残りが囲みの箱から
    /// 決まるので、混ぜて書くと絵が捻れる。書くなら全部に書く。
    public func vertex(_ x: Float, _ y: Float, _ z: Float, _ u: Float, _ v: Float) {
        canvas.vertex(x, y, z, u, v)
    }

    /// これから置く頂点の面の向きを決める。
    ///
    /// 面の向きは、光がどれだけ当たるかを決めるもの。**書き換えるまで続き、
    /// ``beginShape(_:)`` で未指定へ戻る。**
    ///
    /// ```swift
    /// beginShape(.triangles)
    /// normal(0, 0, 1)     // ここから置く頂点は、画面の側を向く
    /// vertex(-30, -30, 0)
    /// vertex(30, -30, 0)
    /// vertex(0, 30, 0)
    /// endShape()
    /// ```
    ///
    /// **書かなければ、形から求まる。** 頂点が属する三角形の向きを寄せ集めるので、
    /// 帯状に並べても扇状に並べても、置いた頂点すべてに向きが付く。書く必要が
    /// あるのは、隣り合う面をなめらかに繋ぎたいときや、形とは違う向きを与えたいとき。
    ///
    /// 面は**どちらの側から見ても光を受ける**ので、向きの符号 (頂点を並べる向き) で
    /// 絵が真っ黒になることはない。
    public func normal(_ x: Float, _ y: Float, _ z: Float) { canvas.normal(x, y, z) }

    /// 穴を並べ始める。
    ///
    /// ``beginShape(_:)`` と ``endShape(_:)`` の間で開き、``endContour()`` で閉じる。
    /// 挟んだ頂点は外周ではなく**穴**になる。
    ///
    /// **穴の頂点は外周と逆回りに並べる。** 下の例では外周が時計回り、穴が反時計回り。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     beginShape()
    ///     vertex(60, 50)
    ///     vertex(340, 40)
    ///     vertex(300, 265)
    ///     vertex(90, 240)
    ///     beginContour()
    ///     vertex(140, 200)
    ///     vertex(255, 195)
    ///     vertex(210, 110)
    ///     endContour()
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色のいびつな四角形の中央に、三角形の穴が 1 つ開いている -->
    ///     ![水色のいびつな四角形の中央に、三角形の穴が 1 つ開いている](https://i.gyazo.com/358b76f864f04b9ea7874fa9496ccdb9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=aefc2c81
    public func beginContour() { canvas.beginContour() }

    /// 穴を並べ終える。
    ///
    /// **閉じてからもう一度 ``beginContour()`` を開けば、穴はいくつでも空けられる。**
    /// 頂点が 3 つに満たない穴は捨てられる (面にならないため)。閉じ忘れても
    /// ``endShape(_:)`` が畳む。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 217, 89)
    ///     beginShape()
    ///     vertex(50, 45)
    ///     vertex(350, 60)
    ///     vertex(330, 265)
    ///     vertex(70, 250)
    ///     beginContour()
    ///     vertex(110, 190)
    ///     vertex(180, 185)
    ///     vertex(150, 110)
    ///     endContour()
    ///     beginContour()
    ///     vertex(230, 210)
    ///     vertex(300, 200)
    ///     vertex(265, 120)
    ///     endContour()
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色い面に、三角形の穴が 2 つ横に並んで開いている -->
    ///     ![黄色い面に、三角形の穴が 2 つ横に並んで開いている](https://i.gyazo.com/a2678c7238b5365705eab6dd72a3d002.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=eac40026
    public func endContour() { canvas.endContour() }

    /// 並べ終えて描く。
    ///
    /// 既定の ``ShapeEnd/open`` は、最後の点から最初の点へ戻らない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(5)
    ///     beginShape()
    ///     vertex(70, 240)
    ///     vertex(120, 70)
    ///     vertex(230, 150)
    ///     vertex(300, 60)
    ///     vertex(345, 245)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の折れ線が 4 本つながってジグザグに走り、両端は結ばれていない -->
    ///     ![橙色の折れ線が 4 本つながってジグザグに走り、両端は結ばれていない](https://i.gyazo.com/384db2b9bb170b9918b30e4c578ff793.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeEnd/close`` を渡すと戻る。**変わるのは線だけである** — 塗りは並べた点で
    /// 決まるので、どちらで閉じても同じ面が塗られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(89, 191, 242)
    ///     strokeWeight(5)
    ///     beginShape()
    ///     vertex(70, 240)
    ///     vertex(120, 70)
    ///     vertex(230, 150)
    ///     vertex(300, 60)
    ///     vertex(345, 245)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じジグザグの両端が 1 本の辺で結ばれ、閉じた形になっている -->
    ///     ![同じジグザグの両端が 1 本の辺で結ばれ、閉じた形になっている](https://i.gyazo.com/0322d55983df57eee540a944218b3355.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=ba1ee5bb
    // shot: 2 snippet=35422e2c
    public func endShape(_ end: ShapeEnd = .open) { canvas.endShape(end) }
}
