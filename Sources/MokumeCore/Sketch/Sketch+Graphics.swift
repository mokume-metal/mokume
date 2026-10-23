// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 描き場所と、貼る絵。
extension SketchPart {
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
    ///     ![同じ描き場所が 2 つ。左は等倍で大きく、右は小さく。どちらも左上寄りに橙色の円](https://i.gyazo.com/c4f5cef49f49d1b3e30312fe28a368ec.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 返るのは画面と同じ ``Canvas``
    ///
    /// **2D も立体も字も効果も、画面と同じように書ける。** 描き場所を別の型にすると、
    /// 「効果に渡せる絵」と「自分で描ける絵」が分かれてしまう ([ADR-0023] 決定 1)。
    ///
    /// 時刻と刻みも画面と同じものが届く。描き場所で塗った断片や掛けた効果が読む
    /// `in.time` は ``time`` と同じ秒数で、描き場所で進める粒 (``Canvas/particles(_:)``) は
    /// ``deltaTime`` ずつ進む。揺らぎの種と細かさ (``noiseSeed(_:)``・``noiseDetail(_:_:)``) も
    /// 画面と同じ 1 つを読み書きするので、描き場所で塗った断片の `mokume_noise` は画面の
    /// ``noise(_:_:_:_:)`` と同じ模様を出す。描き場所から作った描き場所も同じである。
    ///
    /// ## 置くのは `beginDraw()` と `endDraw()` の間だけ
    ///
    /// 描き場所の図形・絵・背景と画素の書き込み (``Canvas/set(_:_:_:)``・``Canvas/pixels``) は、
    /// ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ置ける。**外で置くと 1 度注意して、
    /// 置かない。** `setup()` の中でも、画面の `draw()` の中でも同じで、`setup()` で描き場所に描くなら
    /// 対で挟む (上の例)。
    ///
    /// **シーンの記述も同じである。** 視点・投影・光・影・材質・変換・切り抜き・効果と、粒
    /// (``Canvas/particles(_:)``)・計算の頼みも、対の中でだけ効く。外で書くと、画面の `draw()` の中に居ても
    /// 注意して無視する。注意は直し先として `beginDraw()` と `endDraw()` の間を言う。
    ///
    /// 画面の側と違うのは、次のフレームを約束する者が違うからである。画面では ``Sketch/setup()`` と
    /// 止まっている間のコールバックで置いたものを、ランタイムが次に描くフレームへ持ち越す。
    /// 描き場所の次の絵を決めるのは書き手の `beginDraw()` / `endDraw()` なので、その外で置いた
    /// ものには出る先が無い ([ADR-0021] 決定 4 の追補 (2026-09-27))。
    ///
    /// `beginDraw()` で開いたまま `endDraw()` を忘れると、そのフレームは**画面の次のフレームの頭で
    /// 描かずに捨てる** (1 度注意する・[#1834])。``noLoop()`` で止まっている間は、止まっている間の
    /// コールバックに入る前に捨てる。捨てた後に読めば捨てる前の絵が返り、遅れて呼んだ
    /// `endDraw()` は何もしない。``Sketch/setup()`` や止まっている間のコールバックで開いて次の ``Sketch/draw()`` で
    /// 閉じる対は、次に描くフレームに属するので捨てない。
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
    /// 描き換える直前に、置いた側がそのときの絵を写しに取って読む。置いた側はそこで描き切られ
    /// ないので、フレームの途中の区切り (``loadPixels()`` の説明) にならない。写しは置いた側
    /// 1 つにつき 4 枚まで持ち、同じ大きさなら次のフレームで使い回す。**1 フレームに「置く →
    /// 描き換える」を 4 回より多く繰り返すと、越えた分は写さずに置いた側を描き切る** (区切りに
    /// なる)。置いた側が形を組み立てている途中 (``createShape(_:)``) に描き換えても、同じく写しを
    /// 読むので描き切らない (写しの上限を越えた分と写しを用意できなかった分は、組み立ての前に置いた列だけを描き切り、組み立てた形は残る)。形の中で
    /// 置いた描き場所は写しへ替わらず、形を置いたときの絵を読む。止まっている間 (``noLoop()`` の後の
    /// コールバック) に置いて描き換えたものは、ほかの置いたものと同じく次のフレームで出る。
    ///
    /// - Throws: 描き場所を確保できないときと、幅・高さのどちらかが 1 を割るとき
    ///   (``RenderFailure/invalidSize(width:height:)``。1×1 へ丸めない) に ``RenderFailure``。
    ///   **組み立てのときに投げる** ([ADR-0020] 決定 5) ので、`setup()` で作って持ち回る。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと
    ///   ``RenderFailure/notRunning(call:)`` (プロセスは落ちない)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    // shot: 1 snippet=952dfdc7
    public func createGraphics(_ width: Int, _ height: Int) throws(RenderFailure) -> Canvas {
        try Self.resourceCanvas(RenderFailure.self).createGraphics(width, height)
    }

    /// 描き場所へ描く間だけ、スケッチの口 (``circle(_:_:_:)``・``fill(_:)-(LinearRGBA)`` など) をその描き場所へ
    /// 向ける。**本体向けに書いた描く関数を、書き換えずに描き場所で使える。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var trail: Canvas! -->
    ///     ```swift
    ///     func setup() {
    ///         trail = try! createGraphics(400, 300)
    ///     }
    ///
    ///     func brush() {
    ///         noStroke()
    ///         fill(255, 102, 51, 40)
    ///         circle(200 + 120 * cos(time * 3), 150 + 80 * sin(time * 3), 24)
    ///     }
    ///
    ///     func draw() {
    ///         draw(into: trail) { brush() }   // 筆跡は描き場所に積む
    ///         background(20)
    ///         image(trail, 0, 0)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の半透明の円が楕円の軌道に沿って動き、通った跡が弧になって積み重なっていく | frames=60 -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `brush()` の中は本体に描くときと同じ書き方で、`trail.` を付けない。閉包を抜けると向き先は本体へ戻る。
    /// 閉包の中の描画は本体の面に出ず、``image(_:_:_:)-(Canvas,_,_)`` で置くまで本体は下地のままである。
    ///
    /// ## 閉包の中で描き場所へ向く口
    ///
    /// - 形・描画の状態・光・視点・材質・変換・切り抜き (``circle(_:_:_:)``・``fill(_:)-(LinearRGBA)``・
    ///   ``translate(_:_:)``・``background(_:)-(LinearRGBA)`` など)
    /// - 粒 (``emit(_:from:toward:rate:speed:life:size:color:)``・``force(_:_:)``・``particles(_:)``) と
    ///   ``orbitControl(_:_:_:)``
    /// - ``canvas``・``effects(_:)``・``shader(_:)``・画素の読み書き・揺らぎの種と細かさ
    /// - 値の形 (`Rect`・`Circle`) の `draw()`
    ///
    /// **``width`` と ``height`` は描き場所の大きさを返す。** 本体が 400×400、描き場所が 200×100 なら、
    /// 次は描き場所の全面を塗る (本体の大きさでは塗らない):
    ///
    /// <!-- example: 文脈 var pad: Canvas! -->
    /// ```swift
    /// draw(into: pad) {
    ///     background(255)
    ///     rect(0, 0, width, height)
    /// }
    /// ```
    ///
    /// **入力 (``mouseX``・``mouseY``・キーなど) は本体の窓のまま**で、描き場所の座標へは変わらない。描き場所を
    /// 本体と同じ大きさにして、マウスの位置にそのまま描く使い方を想定している。時刻 (``time``・``deltaTime``・
    /// ``frameCount``) も本体と同じである。``orbitControl(_:_:_:)`` の道具の状態 (``orbit``) は本体と共有で、
    /// 視点を書く先だけが描き場所になる。道具の始まりは本体の面の中央で、道具の状態を進めてよいかも
    /// 本体のフレームで決まる (`setup()` の中から呼ぶと、本体と同じく断る)。
    ///
    /// 効果は描き場所のものになり、本体の効果は書き換わらない:
    ///
    /// <!-- example: 文脈 var pad: Canvas! -->
    /// ```swift
    /// draw(into: pad) {
    ///     effects([.blur(radius: 4)])
    /// }
    /// ```
    ///
    /// ## 入れ子と、`pad.` 付きの呼び出しとの混在
    ///
    /// 入れ子にでき、内側を抜けると 1 つ外の向き先へ戻る。閉包の中で `other.circle(…)` と描き場所を指して書いた
    /// 呼び出しは、これまでどおりその描き場所へ行く:
    ///
    /// <!-- example: 文脈 var a: Canvas! -->
    /// <!-- example: 文脈 var b: Canvas! -->
    /// <!-- example: 文脈 var c: Canvas! -->
    /// ```swift
    /// draw(into: a) {
    ///     draw(into: b) { circle(10, 10, 8) }   // b へ
    ///     circle(30, 30, 8)                      // a へ
    ///     c.circle(50, 50, 8)                    // c へ (指して書いた呼び出し)
    /// }
    /// ```
    ///
    /// ## フレームは `draw { }` と同じ形で開く
    ///
    /// 描き場所のフレームは ``Canvas/draw(_:)`` と同じ規則で開く。閉じていれば開いて閉包を走らせ、抜けるときに
    /// 描き切る。``Canvas/beginDraw()`` で開いている最中なら、そのフレームの続きとして走らせる (注意を 1 度出す)。
    /// 描き場所の形の組み立て (``Canvas/createShape(_:)``) の中では、フレームを始めずに組み立ての続きとして
    /// 走らせる。**ただし描き切りの失敗は、投げずに警告で知らせる** (``Canvas/endDraw()`` と同じ)。
    /// ``Canvas/draw(_:)`` は ``RenderFailure`` を投げるので、そこだけ違う。
    ///
    /// ## 3 つの `draw` の違い
    ///
    /// - ``Sketch/draw()``: 利用者が書く、1 フレームごとに呼ばれる関数
    /// - ``Canvas/draw(_:)``: 描き場所のフレームを開く。**中の素の呼び出しは本体へ行く** (`pad.circle(…)` と書く)
    /// - `draw(into:)`: 描き場所のフレームを開き、**中の素の呼び出しを描き場所へ向ける**
    ///
    /// ## 揺らぎの種・時刻・粒の刻みは、向き先によらずスケッチのもの
    ///
    /// 閉包の中の ``noise(_:_:_:_:)``・``noiseSeed(_:)``・``noiseDetail(_:_:)`` と粒の刻みは、
    /// **向き先が直に作った面 (``Canvas/init(target:gpu:)``) でも、スケッチの置き場を読み書きする** —
    /// 種はスケッチに 1 つである。閉包を抜けると、直に作った面は自分の置き場へ戻る。
    /// ``createGraphics(_:_:)`` で作った描き場所は、もともと本体と置き場を共有する。形の組み立ての
    /// 出口の規則 (``createShape(_:)``) は、本体の置き場について効く。
    ///
    /// ## 本体の面を渡したとき
    ///
    /// 本体の面 (``canvas``) を渡すと、フレームは開き直さず、閉包をそのまま走らせる。本体のフレームを
    /// 約束するのはランタイムで、`setup()` の中から開くと本体のフレームが余分に回ってしまうためである
    /// (`canvas.draw { }` は本体のフレームを開き直す)。入れ子の中から本体へ戻る書き方にも使える。
    ///
    /// ## 粒を描き場所へ出す
    ///
    /// ``Canvas`` は `emit` を公開しない。乱数の列を 1 本に保つためである (``randomSeed(_:)`` が粒に効かなくなる)。
    /// 描き場所へ粒を出すときは、閉包の中で ``emit(_:from:toward:rate:speed:life:size:color:)`` を呼ぶ。
    ///
    /// - Parameters:
    ///   - graphics: 描く先の描き場所。
    ///   - body: 中の呼び出しが `graphics` へ向く閉包。
    // shot: 後で撮る
    public func draw(into graphics: Canvas, _ body: () -> Void) {
        guard let runtime = Self.liveRuntime() else { return }
        let previous = runtime.drawingInto
        runtime.drawingInto = graphics
        defer { runtime.drawingInto = previous }
        // 本体の面のフレームを約束するのはランタイム。ここで開くと、`setup()` の中から呼んだときに
        // 本体のフレームが余分に回る。向き先だけを立てて、閉包を走らせる
        if graphics === runtime.canvas { return body() }
        // 揺らぎの種・時刻・粒の刻みは、向き先が直に作った面でもスケッチのものを読む
        let restore = graphics.borrowSketchState(from: runtime.canvas)
        defer { restore() }
        do {
            try graphics.draw(body)
        } catch {
            Diagnostics.warn("draw(into:): could not finish drawing: \(error.headline)")
        }
    }

    /// 描き場所を等倍で置く。
    ///
    /// (`x`, `y`) の読み方は ``imageMode(_:)`` が決める — 既定の `.corner` と `.corners` なら
    /// 左上の角、`.center` と `.radius` なら中心が (`x`, `y`) に来る。**大きさは、どの読み方でも
    /// 描き場所の画素数のまま**である。
    ///
    /// 置くのは**そのとき描き切れている絵**である。``Canvas/endDraw()`` を呼ぶ前に置くと、
    /// 途中の区切り (`loadPixels()`・`get()` など) が無ければ 1 フレーム前の絵、あれば区切りまで
    /// 描いた絵が出る (効果は通らない)。どちらも警告が出る。細かさ (``SketchSettings/pixelDensity``)
    /// にはよらない。
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
    ///     ![120 画素四方の描き場所が等倍で置かれ、白い 2 本の線が外からその左上の角を指している](https://i.gyazo.com/cee09c7f5e6322052d5f2457c5207368.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b01c8b0c
    public func image(_ graphics: Canvas, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (x, y) = (x.asFloat, y.asFloat)
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
    ///     ![左に大きく、右に小さく同じ描き場所。右は赤が抑えられて青緑に寄っている](https://i.gyazo.com/5dd046b52d65cfbbfe205be1b52eb955.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=eca56bd9
    public func image(_ graphics: Canvas, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        canvas.image(graphics, a, b, c, d)
    }

    /// 描き場所の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**描き場所の中のどこを切り出すか**。切り出しが
    /// 外へ出ても落ちず、**重なった分だけが、同じ倍率で指した場所に出る** — 置き先も切り出しを
    /// 締めたのと同じ割合で締まるので、倍率は `置き先 / 切り出し` のまま変わらない。
    /// たとえば 64 画素四方の描き場所の `(32, 0, 64, 64)` を `128×128` へ置くと、置き先の右半分
    /// (描き場所の右端を越えた所) には何も置かれず、重なった分 (描き場所の右半分) が 2 倍の
    /// `64×128` で置き先の左半分に出る。
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
    ///     ![左に描き場所の全体、右はその左上 4 分の 1 だけを同じ大きさへ引き伸ばしたもの](https://i.gyazo.com/415dd5a9f368feb579a7a5cf2d59ab21.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=625e4d78
    public func image(
        _ graphics: Canvas, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ sourceX: some ScalarConvertible, _ sourceY: some ScalarConvertible, _ sourceWidth: some ScalarConvertible, _ sourceHeight: some ScalarConvertible
    ) {
        guard let canvas = Self.liveCanvas() else { return }
        let (a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, sourceX.asFloat, sourceY.asFloat, sourceWidth.asFloat, sourceHeight.asFloat)
        canvas.image(graphics, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// これから置く塗りに絵を貼る。
    ///
    /// 下の絵は、橙色と青灰色の 8 画素の格子でできた 64 画素四方の絵を、同じ
    /// `texture(tile)` のまま 3 つの形に貼ったもの。読み取り位置は組み込みの形が自分で持つ —
    /// 四角には絵が 1 枚、箱には 6 面それぞれに 1 枚、球には経度と緯度に沿って巻かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<64 {
    ///             for x in 0..<64 where (x / 8 + y / 8) % 2 == 0 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         lights()
    ///         texture(tile)
    ///
    ///         rect(20, 100, 100, 100)
    ///
    ///         push()
    ///         translate(200, 150, 0)
    ///         rotateX(-0.5)
    ///         rotateY(0.6)
    ///         box(90)
    ///         pop()
    ///
    ///         push()
    ///         translate(330, 150, 0)
    ///         rotateY(-0.6)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から四角・箱・球。どれにも同じ市松模様が貼られ、四角には 1 枚、箱には面ごとに 1 枚、球には経度と緯度に沿って巻かれている -->
    ///     ![左から四角・箱・球。どれにも同じ市松模様が貼られ、四角には 1 枚、箱には面ごとに 1 枚、球には経度と緯度に沿って巻かれている](https://i.gyazo.com/bfd4070f53054b218b620aa82513f01b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **効くのは塗りだけ。** 輪郭・端点・角・立体の線と点・文字・周囲には貼られない
    /// ので、`stroke()` を残したまま貼っても縁は線の色のまま出る。下の左は太い線を残した
    /// 四角、右は線を消した四角で、どちらも内側には同じ絵が貼られている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<64 {
    ///             for x in 0..<64 where (x / 8 + y / 8) % 2 == 0 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         texture(tile)
    ///
    ///         stroke(242, 217, 89)
    ///         strokeWeight(8)
    ///         rect(60, 90, 120, 120)
    ///
    ///         noStroke()
    ///         rect(220, 90, 120, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵を貼った四角が 2 つ。左は太い黄色の縁があり、縁には絵が貼られていない。右は縁が無く、絵が四角の端まで続いている -->
    ///     ![同じ絵を貼った四角が 2 つ。左は太い黄色の縁があり、縁には絵が貼られていない。右は縁が無く、絵が四角の端まで続いている](https://i.gyazo.com/63f28fb64415257df422a70b9888c4c7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **貼った絵は、光と材質を通ったあとの色に掛かる。** 立体では陰影がそのまま残り、
    /// 平面では ``fill(_:)-(LinearRGBA)`` が色掛けになる (白なら絵がそのまま出る)。下の 3 枚はどれも
    /// 同じ四角で、変えたのは `fill` だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<64 {
    ///             for x in 0..<64 where (x / 8 + y / 8) % 2 == 0 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         texture(tile)
    ///
    ///         fill(255)
    ///         rect(15, 100, 100, 100)
    ///         fill(255, 153, 153)
    ///         rect(150, 100, 100, 100)
    ///         fill(128)
    ///         rect(285, 100, 100, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵を貼った四角が 3 つ。左は絵がそのまま、中は緑と青が抑えられて赤みが乗り、右は全体が暗くなっている -->
    ///     ![同じ絵を貼った四角が 3 つ。左は絵がそのまま、中は緑と青が抑えられて赤みが乗り、右は全体が暗くなっている](https://i.gyazo.com/1dab2d544daf6584fca1fed62a843318.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 自分で並べた形では ``vertex(_:_:_:_:)`` で読み取り位置を書け、書かなければ形の
    /// 囲みの箱から決まる。円柱と円錐は側面の一周と蓋の円、輪は 2 つの一周を読む。
    ///
    /// **描き方なのでフレームを越える** — 塗りや線と同じく、一度書けば
    /// ``noTexture()`` を呼ぶまで続き、``push()`` / ``pop()`` で積める。
    // shot: 1 snippet=c9428b67
    // shot: 2 snippet=f943b654
    // shot: 3 snippet=beee00de
    public func texture(_ image: Image) { Self.liveCanvas()?.texture(image) }

    /// これから置く塗りに描き場所を貼る。
    ///
    /// **読み込んだ絵とまったく同じに扱える。** 毎フレーム描き直した描き場所を
    /// 立体に貼れば、面の上で動く絵になる。下の絵は、青灰色の地に橙色の円を描いた
    /// 描き場所を、四角と箱に貼ったもの。箱の 6 面には、それぞれ描き場所が 1 枚ずつ貼られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() {
    ///         pad = try! createGraphics(120, 120)
    ///         pad.beginDraw()
    ///         pad.background(51, 71, 102)
    ///         pad.noStroke()
    ///         pad.fill(242, 115, 64)
    ///         pad.circle(60, 60, 80)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         lights()
    ///         texture(pad)
    ///
    ///         rect(30, 90, 120, 120)
    ///
    ///         push()
    ///         translate(290, 150, 0)
    ///         rotateX(-0.5)
    ///         rotateY(0.6)
    ///         box(100)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左の四角と右の箱の面に、青灰色の地に橙色の円を描いた同じ描き場所が貼られている。箱は陰影が付き、面ごとに円がある -->
    ///     ![左の四角と右の箱の面に、青灰色の地に橙色の円を描いた同じ描き場所が貼られている。箱は陰影が付き、面ごとに円がある](https://i.gyazo.com/0b363f8077db4c7b85d97381ed5aac4c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **貼るのは 1 度でよい。** 呼び直さずに描き場所を描き換えながら塗り続けても、形は
    /// 置くたびにその時点の絵で描かれる — 先に置いた形が、後から描き換えた絵に化けることは
    /// ない。`setup()` で 1 度だけ貼って毎フレーム描き換えても、`createShape` の中で貼った
    /// 形を描き換えながら置き直しても同じである。下の例は 1 度だけ貼り、四角を置いてから
    /// 描き場所の円を描き換えて、もう 1 つ四角を置いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() {
    ///         pad = try! createGraphics(120, 120)
    ///         pad.beginDraw()
    ///         pad.background(51, 71, 102)
    ///         pad.noStroke()
    ///         pad.fill(242, 115, 64)
    ///         pad.circle(60, 60, 80)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         texture(pad)
    ///         rect(40, 90, 120, 120)
    ///
    ///         pad.beginDraw()
    ///         pad.background(51, 71, 102)
    ///         pad.fill(89, 217, 128)
    ///         pad.circle(40, 80, 60)
    ///         pad.endDraw()
    ///         rect(240, 90, 120, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ四角が 2 つ。左は橙色の円、右は描き換えた後の緑の円で、左は描き換えに引きずられていない -->
    ///     ![同じ四角が 2 つ。左は橙色の円、右は描き換えた後の緑の円で、左は描き換えに引きずられていない](https://i.gyazo.com/6301586b325c43f92706a48b342ca800.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 貼る絵は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=ce04dd39
    // shot: 2 snippet=5d6b5918
    public func texture(_ graphics: Canvas) { Self.liveCanvas()?.texture(graphics) }

    /// 絵を貼るのをやめる。
    ///
    /// 以後の塗りは貼る絵なしの、``fill(_:)-(LinearRGBA)`` の色になる。下の左は絵を貼ったままの
    /// 四角、右は `noTexture()` の後に `fill` を変えて置いた同じ四角で、右は 1 色で塗られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<64 {
    ///             for x in 0..<64 where (x / 8 + y / 8) % 2 == 0 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///
    ///         texture(tile)
    ///         rect(40, 100, 100, 100)
    ///
    ///         noTexture()
    ///         fill(242, 115, 64)
    ///         rect(260, 100, 100, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの四角が 2 つ。左は市松模様、右は橙色の 1 色 -->
    ///     ![同じ大きさの四角が 2 つ。左は市松模様、右は橙色の 1 色](https://i.gyazo.com/0425511f17d65a4ff96d3adb979331d5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 貼る絵は ``push()`` / ``pop()`` で積めるので、`push()` の中で呼んだ `noTexture()` は
    /// `pop()` で元に戻る。下の絵は、貼ったまま 3 つ目の四角を置くとき、2 つ目だけを
    /// `push()` と `pop()` で挟んで絵を外している。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<64 {
    ///             for x in 0..<64 where (x / 8 + y / 8) % 2 == 0 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         texture(tile)
    ///         rect(20, 100, 100, 100)
    ///
    ///         push()
    ///         noTexture()
    ///         fill(242, 115, 64)
    ///         rect(150, 100, 100, 100)
    ///         pop()
    ///
    ///         rect(280, 100, 100, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの四角が 3 つ。左と右は市松模様で、真ん中だけが橙色の 1 色 -->
    ///     ![同じ大きさの四角が 3 つ。左と右は市松模様で、真ん中だけが橙色の 1 色](https://i.gyazo.com/928da5480cc8e19933aa2f8cad1d594a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 貼る絵は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=5281a349
    // shot: 2 snippet=346300b3
    public func noTexture() { Self.liveCanvas()?.noTexture() }
}
