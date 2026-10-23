// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、基本図形。
extension SketchPart {
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
    ///     ![濃い灰色の下地に、左上 (80, 60) から 240x180 の橙色の長方形](https://i.gyazo.com/c2ec99762a53734d02277ad9d2467055.png)
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
    ///     ![横長の長方形が上、縦長の長方形が左下に並ぶ](https://i.gyazo.com/2dfec5b8beb40a85e52f268fcb446ce8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 幅か高さが 0 以下になる指定では**何も描かない**。
    // shot: 1 snippet=74598101
    // shot: 2 snippet=60541771
    public func rect(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        canvas.rect(a, b, c, d)
    }

    /// 4 つの角を同じ半径で丸めた矩形を塗る。
    ///
    /// 5 つ目が角の半径で、前の 4 つの読み方は ``rect(_:_:_:_:)`` と同じ (``rectMode(_:)`` が決める)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rect(80, 60, 240, 180, 24)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地に、角を半径 24 で丸めた 240x180 の橙色の長方形 | symmetric=xy -->
    ///     ![濃い灰色の下地に、角を半径 24 で丸めた 240x180 の橙色の長方形](https://i.gyazo.com/eff30cf40825ab1b7dc74724b93e1667.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 半径は**短い辺の半分まで**で、それより大きく渡すと短い辺の半分に締める (Processing と同じ)。
    /// 高さ 80 の矩形に半径 100 を渡すと、半径 40 の両端が半円の形になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     rect(60, 110, 280, 80, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地の中央に、両端が半円の横長の橙色の形 | symmetric=xy -->
    ///     ![濃い灰色の下地の中央に、両端が半円の横長の橙色の形](https://i.gyazo.com/5c53007e79d3fb6071125ae4509977c2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 輪郭 (`stroke`) も丸めた周を回る。角の丸い周には折れ目が無いので、``strokeJoin(_:)`` は
    /// 半径が 0 より大きいときは効かない。角は円弧で描く (Processing は二次曲線で描くので、角の中ほどが
    /// 半径の 4% ほど角に寄る)。
    ///
    /// 負の半径と数でない値は 0 として扱い、角を丸めずに描いて 1 度だけ知らせる。無限の半径は
    /// 短い辺の半分に締める。幅か高さが 0 以下になる指定では**何も描かない** (半径があっても同じ)。
    // shot: 1 snippet=e0feea22
    // shot: 2 snippet=5c86dbd7
    public func rect(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ r: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, c, d, r) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, r.asFloat)
        canvas.rect(a, b, c, d, r)
    }

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
    ///     ![下地の中ほどに、一辺 140 の橙色の正方形](https://i.gyazo.com/846ccaed5503e5c72d436c777f1f561d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a14bfc0d
    public func square(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ extent: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, extent) = (a.asFloat, b.asFloat, extent.asFloat)
        canvas.square(a, b, extent)
    }

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
    ///     ![濃い灰色の下地の中央に、直径 160 の橙色の円](https://i.gyazo.com/317de77f2b2ae9704cd049ad1ffccbae.png)
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
    ///     ![同じ中心に重なる、直径 240・160・80 の 3 つの円](https://i.gyazo.com/062fc2de26cf77114506f26ffdd72667.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=dddecdb4
    // shot: 2 snippet=ccc7b2b7
    public func circle(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ diameter: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, diameter) = (a.asFloat, b.asFloat, diameter.asFloat)
        canvas.circle(a, b, diameter)
    }

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
    ///     ![画面の中央に、横に長い橙色の楕円](https://i.gyazo.com/796275b020867edd4ddd47574cb8873f.png)
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
    ///     ![同じ中心に、横長と縦長の楕円が十字に重なる](https://i.gyazo.com/b1b1cff37c194754aaf33a08442b2fd2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5db22851
    // shot: 2 snippet=b47c6582
    public func ellipse(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
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
    ///     arc(200, 150, 200, 200, 0, Float.pi / 2)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の円の、右から下へ 4 分の 1 だけが橙色の扇形になっている -->
    ///     ![中央の円の、右から下へ 4 分の 1 だけが橙色の扇形になっている](https://i.gyazo.com/5d5ef1d146facd02816e5a4f0431b7cc.png)
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
    ///     ![同じ円の 4 分の 3 が橙色の扇形になり、右上だけが欠けている](https://i.gyazo.com/781c7a80131768de3b4eb0356008c848.png)
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
    ///     arc(200, 150, 200, 200, Float.pi, Float.pi * 1.5)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から上へ 4 分の 1 だけの橙色の扇形 -->
    ///     ![左から上へ 4 分の 1 だけの橙色の扇形](https://i.gyazo.com/dc188ab234ebc18e5b37d95fc58fcca9.png)
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
    ///     ![黄色い円が口を開け閉めするように、扇形の欠けが大きくなったり小さくなったりする](https://i.gyazo.com/aabbf800cf7ed2dce8c66629aa73010f.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 塗りは**中心を含む扇形**になる。終わりの角度が始まりより小さいときは
    /// **何も描かず**、最初の 1 回だけ知らせる。
    ///
    /// **輪郭は閉じない弧になる。** 扇の 2 本の半径は引かない — 手本 (Processing・p5.js) の
    /// 既定と同じで、`noFill()` で弧だけを引けば、メーターの針の跡や輪の欠けが描ける。
    /// 塗りと輪郭が違う形 (塗りは扇・輪郭は開いた弧) になるのも手本と同じである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     strokeWeight(14)
    ///     arc(200, 150, 200, 200, Float.pi * 0.75, Float.pi * 2.25)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 下が開いた橙色の太い弧が中央にあり、中心へ向かう線は無い -->
    ///     ![下が開いた橙色の太い弧が中央にあり、中心へ向かう線は無い](https://i.gyazo.com/f4b2cb4e33d19ed0a96d914d1a2ecb01.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **閉じ方を選ぶなら 7 つ目の引数に ``ArcMode`` を渡す** (``arc(_:_:_:_:_:_:_:)``)。
    /// 左上が引数を渡さない形、続く 3 つが `.pie`・`.chord`・`.open`。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64, 140)
    ///     stroke(242, 217, 89)
    ///     strokeWeight(4)
    ///     arc(105, 80, 150, 110, 0.4, 4.4)
    ///     arc(295, 80, 150, 110, 0.4, 4.4, .pie)
    ///     arc(105, 220, 150, 110, 0.4, 4.4, .chord)
    ///     arc(295, 220, 150, 110, 0.4, 4.4, .open)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ弧が 4 つ。左上は扇の塗りと開いた弧、右上は扇の枠つき、左下は弦で閉じた形、右下は弦で結んだ形の塗りと開いた弧 -->
    ///     ![同じ弧が 4 つ。左上は扇の塗りと開いた弧、右上は扇の枠つき、左下は弦で閉じた形、右下は弦で結んだ形の塗りと開いた弧](https://i.gyazo.com/eef5238b07675b9adfb4eecd8a3b2fb9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 手本から移すとき、輪郭付きの `arc` で**扇の枠が要る**なら `.pie` を渡す。
    ///
    /// - Note: **幅と高さが違うとき、角度は中心から見た向きではない。** 中心を `(cx, cy)`、
    ///   幅と高さの半分を `rx`・`ry` とすると、角度 `t` の弧の端は
    ///   `(cx + rx·cos t, cy + ry·sin t)` の点 (楕円の媒介変数の角) で、中心から見ると `t` より
    ///   長い軸の側に寄る — 横長の `arc(0, 0, 260, 80, 0, Float.pi / 4)` の弧の端は、
    ///   中心から見ると 45° ではなく 17° の向きにある。扇の 2 本の辺はこの点へ引かれ、塗りも
    ///   輪郭もその間だけに出る (輪郭は `.pie` のとき)。円では 2 つの向きが一致する。
    ///
    /// - Note: **p5.js とは楕円の絵が違う。** 手本の読み方は割れていて、Processing はこちらと
    ///   同じく媒介変数の角として読み、p5.js は角度を中心から見た向きとして換算してから弧を引く。
    // shot: 1 snippet=51c098c3
    // shot: 2 snippet=e00e11b7
    // shot: 3 snippet=16db4ac0
    // shot: 4 snippet=27105ca4
    // shot: 5 snippet=6cae2c65
    // shot: 6 snippet=8e587865
    public func arc(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible, _ start: some ScalarConvertible, _ stop: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, c, d, start, stop) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, start.asFloat, stop.asFloat)
        canvas.arc(a, b, c, d, start, stop)
    }

    /// 円弧を、閉じ方 (``ArcMode``) を選んで描く。
    ///
    /// 最初の 6 つの数は ``arc(_:_:_:_:_:_:)`` と同じ読み方で、7 つ目が閉じ方。
    ///
    /// | 閉じ方 | 塗り | 輪郭 |
    /// | --- | --- | --- |
    /// | (6 つの数だけ) | 扇 | 開いた弧 |
    /// | `.pie` | 扇 | 扇の枠 (中心への 2 本の半径と弧) |
    /// | `.chord` | 弧の両端を弦で結んだ形 | 弦で閉じた形の周 |
    /// | `.open` | 弧の両端を弦で結んだ形 | 開いた弧 |
    ///
    /// **`.open` の塗りは扇ではなく弦で結んだ形になる。** 手本の既定 (引数を渡さない形) とは
    /// 塗りが違うので、既定の見た目が欲しいときは、閉じ方を渡さずに呼ぶ。
    /// 一周ぶんの弧は、どの閉じ方でも楕円と同じ形になる。
    // shot: 参照 arc(_:_:_:_:_:_:)
    public func arc(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible, _ start: some ScalarConvertible, _ stop: some ScalarConvertible,
        _ mode: ArcMode
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, c, d, start, stop) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, start.asFloat, stop.asFloat)
        canvas.arc(a, b, c, d, start, stop, mode)
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
    ///     ![下地の中央に、頂点を上に向けた橙色の三角形](https://i.gyazo.com/0dfa362b281239ee52fac0810c2cc9d3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f5d478e8
    public func triangle(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible, _ x3: some ScalarConvertible, _ y3: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x1, y1, x2, y2, x3, y3) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat)
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
    ///     ![少し傾いた橙色の四角形](https://i.gyazo.com/02bf66730a70007f5df7fc21a4e33338.png)
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
    ///     ![同じ 4 点で辺が交差し、砂時計のような形になっている](https://i.gyazo.com/6e348415a98bf57d5249bb0c1e446b3a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=34577789
    // shot: 2 snippet=23b24af9
    public func quad(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible,
        _ x3: some ScalarConvertible, _ y3: some ScalarConvertible, _ x4: some ScalarConvertible, _ y4: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x1, y1, x2, y2, x3, y3, x4, y4) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat, x4.asFloat, y4.asFloat)
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
    ///     ![左から右へ、だんだん大きくなる 5 つの白い点](https://i.gyazo.com/f52bdab3030513dc854c6b08af8f8c00.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 色を決めるのは ``stroke(_:)`` で、``fill(_:)-(LinearRGBA)`` は効かない。
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
    ///     ![橙色に塗る指定をしても、点は水色のまま並んでいる](https://i.gyazo.com/c1e8b626eeaff43b1805548dcf936d96.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=72c60508
    // shot: 2 snippet=8602b4e7
    public func point(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x, y) = (x.asFloat, y.asFloat)
        canvas.point(x, y)
    }

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
    ///     ![左上を (120, 90) とする 160x120 の橙色の長方形](https://i.gyazo.com/3fccb9ad62d590f8f09242b0ea68c484.png)
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
    ///     ![(120, 90) と (160, 120) を対角とする、小さな橙色の長方形](https://i.gyazo.com/e5b81d87f4b0a6e86851007633c5e857.png)
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
    ///     ![(120, 90) を中心とする 160x120 の橙色の長方形](https://i.gyazo.com/267b47e456d34d904ae11913d14b607e.png)
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
    ///     ![同じ中心のまま、center のときの倍の大きさになった橙色の長方形](https://i.gyazo.com/3a7a0a54b203232a6247c0deff3efd4f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 座標の読み方は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=bdc059c4
    // shot: 2 snippet=93b69e1a
    // shot: 3 snippet=76535701
    // shot: 4 snippet=f9d3d420
    public func rectMode(_ mode: ShapeMode) { Self.liveCanvas()?.rectMode(mode) }

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
    ///     ![(200, 150) を中心とする、幅 200 高さ 140 の橙色の楕円](https://i.gyazo.com/c708f09f06b46a68c73a9b7d738674c0.png)
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
    ///     ![同じ数のまま右下へずれた、幅 200 高さ 140 の橙色の楕円](https://i.gyazo.com/326e3fc677ed66bfcc721fef30c9227c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 座標の読み方は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=7bc89b05
    // shot: 2 snippet=09181c0f
    public func ellipseMode(_ mode: ShapeMode) { Self.liveCanvas()?.ellipseMode(mode) }

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
    ///     ![左上から右下へ引かれた 1 本の白い線](https://i.gyazo.com/be9f6f61767831eb95c0f7d46f9688c4.png)
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
    ///     ![太さの違う 3 本の白い線が、端の形を変えて横に並んでいる](https://i.gyazo.com/c8db1e78f3ee60c130da2cb1a0cc611b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f2777671
    // shot: 2 snippet=055b0309
    public func line(_ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x1, y1, x2, y2) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat)
        canvas.line(x1, y1, x2, y2)
    }

    /// 立体の空間に線を引く。**視点と奥行きを通る。**
    ///
    /// 4 つの数の ``line(_:_:_:_:)`` は平面の図形で、視点をどう動かしても面の座標へそのまま
    /// 描かれる。6 つの数で書くと、2 つの点は奥行きを持つ点になり、``camera(_:_:_:_:_:_:_:_:_:)``
    /// や ``orbitControl(_:_:_:)`` の視点から見た位置に引かれる。立体の陰に入れば隠れる。
    /// **引数の数で、視点を通るかが変わる** — 奥行きを 0 にしても、6 つの数で書けば視点を通る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 斜め上から見下ろす
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(4)
    ///     // 手前から奥へ伸びる線
    ///     line(120, 150, 100, 120, 150, -200)
    ///     line(280, 150, 100, 280, 150, -200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 手前から奥へ伸びる 2 本の橙色の線が、奥へ行くほど寄って細くなる -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 色・太さ・端の形は 2 次元の線と同じく ``stroke(_:)``・``strokeWeight(_:)``・
    /// ``strokeCap(_:)`` が決める。太さは画面の画素で測るので、遠くても細り過ぎない。
    /// 描き方は `beginShape(.lines)` に 2 つの点を ``vertex(_:_:_:)`` で並べたのと同じである。
    // shot: 後で撮る
    public func line(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ z1: some ScalarConvertible,
        _ x2: some ScalarConvertible, _ y2: some ScalarConvertible, _ z2: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x1, y1, z1, x2, y2, z2) = (x1.asFloat, y1.asFloat, z1.asFloat, x2.asFloat, y2.asFloat, z2.asFloat)
        canvas.line(x1, y1, z1, x2, y2, z2)
    }

    /// 立体の空間に点を打つ。**視点と奥行きを通る。**
    ///
    /// 2 つの数の ``point(_:_:)`` は平面の図形で、視点を通らない。3 つの数で書くと、奥行きを
    /// 持つ点として視点から見た位置に打たれる (``line(_:_:_:_:_:_:)`` と同じ約束)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     stroke(217, 230, 255)
    ///     strokeWeight(10)
    ///     // 同じ横の位置に、奥行きだけ変えて 5 つ
    ///     for index in 0..<5 {
    ///         point(200, 150, 100 - Float(index) * 70)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が 5 つ、手前から奥へ縦に並び、奥ほど上に寄っている -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 大きさは ``strokeWeight(_:)`` の太さ (画面の画素)、色は ``stroke(_:)`` の色。描き方は
    /// `beginShape(.points)` に ``vertex(_:_:_:)`` を 1 つ置いたのと同じである。
    // shot: 後で撮る
    public func point(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        canvas.point(x, y, z)
    }
}
