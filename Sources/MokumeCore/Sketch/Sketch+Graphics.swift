// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 描き場所と、貼る絵。
extension SketchPart {
    /// 画面とは別のグラフィックスを作る。**焼いた画像を置いたり、重ねたり、積み上げたりできる。**
    ///
    /// <!-- example: 文脈 var trail: Canvas! -->
    /// ```swift
    /// func setup() throws {
    ///     trail = try createGraphics(400, 400)
    /// }
    ///
    /// func draw() {
    ///     draw(into: trail) {
    ///         fill(255, 102, 51)
    ///         circle(mouseX, mouseY, 20)   // 消さないので跡が残る
    ///     }
    ///
    ///     image(trail, 0, 0)
    /// }
    /// ```
    ///
    /// **グラフィックスへ描く書き方は 3 つある。** 画面向けに書いた描く関数 (``circle(_:_:_:)`` など) を
    /// そのまま使い回すなら ``draw(into:_:)`` (上の例)。フラッシュの失敗を自分で捕まえたいなら
    /// ``Canvas/draw(_:)``。どちらもクロージャの中の素の呼び出しはグラフィックスへ行く。区間を自分で開け閉めするなら
    /// ``Canvas/beginDraw()`` と ``Canvas/endDraw()``。
    ///
    /// | 書き方 | 素の `circle(…)` が描く先 | フラッシュの失敗 |
    /// | --- | --- | --- |
    /// | ``draw(into:_:)`` | グラフィックス (クロージャを抜けると本体へ戻る) | 警告する |
    /// | ``Canvas/draw(_:)`` (`try trail.draw { … }`) | グラフィックス (クロージャを抜けると本体へ戻る) | ``RenderFailure`` を投げる |
    /// | ``Canvas/beginDraw()`` / ``Canvas/endDraw()`` | 本体 (グラフィックスへは `trail.circle(…)` と書く) | `endDraw()` で警告する |
    ///
    /// 3 つの違いの詳しい説明は ``draw(into:_:)`` の「3 つの `draw` の違い」に、手動の対の規則は
    /// 下の「置くのは `beginDraw()` と `endDraw()` の間だけ」にある。次の例は手動の形で、`setup()` で
    /// 1 度だけ描いたグラフィックスを、等倍と縮小で 2 度置く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         pad = try createGraphics(160, 160)
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
    ///     <!-- shot: 同じグラフィックスが 2 つ。左は等倍で大きく、右は小さく。どちらも左上寄りに橙色の円 -->
    ///     ![同じグラフィックスが 2 つ。左は等倍で大きく、右は小さく。どちらも左上寄りに橙色の円](https://i.gyazo.com/f72febd86fd1cc325ea61afe6b7077c3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 返るのは画面と同じ ``Canvas``
    ///
    /// **2D も立体も字も効果も、画面と同じように書ける。** グラフィックスを別の型にすると、
    /// 「効果に渡せる画像」と「自分で描ける画像」が分かれてしまう ([ADR-0023] 決定 1)。
    ///
    /// 時刻と刻みも画面と同じものが届く。グラフィックスで塗ったシェーダや掛けた効果が読む
    /// `in.time` は ``time`` と同じ秒数で、グラフィックスで進めるパーティクル (``Canvas/particles(_:)``) は
    /// ``deltaTime`` ずつ進む。ノイズのシードと詳細度 (``noiseSeed(_:)``・``noiseDetail(_:_:)``) も
    /// 画面と同じ 1 つを読み書きするので、グラフィックスで塗ったシェーダの `mokume_noise` は画面の
    /// ``noise(_:_:_:_:)`` と同じ模様を出す。グラフィックスから作ったグラフィックスも同じである。
    ///
    /// ## 置くのは `beginDraw()` と `endDraw()` の間だけ
    ///
    /// グラフィックスの図形・画像・背景と画素の書き込み (``Canvas/set(_:_:_:)``・``Canvas/pixels``) は、
    /// ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ置ける。**外で置くと 1 度注意して、
    /// 置かない。** `setup()` の中でも、画面の `draw()` の中でも同じで、`setup()` でグラフィックスに描くなら
    /// 対で挟む (上の例)。
    ///
    /// **シーンの記述も同じである。** 視点・投影・光・影・材質・変換・切り抜き・効果と、パーティクル
    /// (``Canvas/particles(_:)``)・計算の呼び出しも、対の中でだけ効く。外で書くと、画面の `draw()` の中に居ても
    /// 注意して無視する。注意は直し先として `beginDraw()` と `endDraw()` の間を言う。
    ///
    /// 画面の側と違うのは、次のフレームを保証する者が違うからである。画面では ``Sketch/setup()`` と
    /// 止まっている間のコールバックで置いたものを、ランタイムが次に描くフレームへ持ち越す。
    /// グラフィックスの次の画像を決めるのはスケッチを書く側の `beginDraw()` / `endDraw()` なので、その外で置いた
    /// ものには出る先が無い ([ADR-0021] 決定 4 の追補 (2026-09-27))。
    ///
    /// `beginDraw()` で開いたまま `endDraw()` を忘れると、そのフレームは**画面の次のフレームの頭で
    /// 描かずに捨てる** (1 度注意する・[#1834])。``noLoop()`` で止まっている間は、止まっている間の
    /// コールバックに入る前に捨てる。捨てた後に読めば捨てる前の画像が返り、遅れて呼んだ
    /// `endDraw()` は何もしない。``Sketch/setup()`` や止まっている間のコールバックで開いて次の ``Sketch/draw()`` で
    /// 閉じる対は、次に描くフレームに属するので捨てない。
    ///
    /// ## 既定で透明で、自動では消えない
    ///
    /// 作った時点の中身は透明で、以後は**こちらが ``Canvas/background(_:)-(LinearRGBA)`` を呼ぶまで
    /// 消えない**。消えないからこそ、前のフレームの上に描き足して跡が積み上がる画像が
    /// 書ける。毎フレーム消したいときは `trail.background(.transparent)` を書く。
    ///
    /// ## 書き出しの倍率の下では、画素だけが増える
    ///
    /// `mokume render --scale N` の下では、本体の描画先と同じく、グラフィックスも**座標の大きさは呼んだまま、画素は N 倍**で
    /// 作られる。`createGraphics(1920, 1080)` の ``width`` と ``height`` は 1920 と 1080 のまま、実際の画素
    /// (``Canvas/pixelWidth``・``Canvas/loadPixels()`` で読む ``Canvas/pixels``・``Canvas/get(_:_:)``・``Canvas/set(_:_:_:)`` の索引) は
    /// 3840×2160 (N が 2 のとき)。線の太さ・効果の半径・``clip(_:_:_:_:)`` の矩形・字の大きさは座標のまま読まれるので、
    /// 構図は変わらず、グラフィックスの画像も細かくなる。置く側 (`image(_:_:_:)`) は座標の大きさで読むので、
    /// 1920×1080 のグラフィックスは本体の座標の 1920×1080 をちょうど覆う。グラフィックスから作ったグラフィックスも、同じ倍率を
    /// 引き継ぐ。**画素の数は倍率の 2 乗で増える**ので、グラフィックスのメモリも N² 倍になる。置いた後に描き換える前の画像を取るコピー
    /// (1 つの置き先につき最大 4 枚) も同じ大きさなので、その分も N² 倍である。掛けた大きさが描画先の一辺の
    /// 上限 (16384 画素) を越える大きさは、``RenderFailure/sizeBeyondOutputScale(width:height:scale:)`` で断る —
    /// **倍率 1 では描けたスケッチが、倍率 N ではグラフィックスを作る ``Sketch/setup()`` で止まりうる** (`createGraphics(8192, 64)` を
    /// `--scale 3` で書くと 24576 画素)。
    /// ウィンドウと、`--scale` の無い書き出し (倍率 1) は、これまでと同じ。`width` で画素を回すスケッチは、倍率の下で画像が変わる。
    ///
    /// ## 描き換えても、置いた時点の画像が出る
    ///
    /// 同じフレームで置いてから描き換えて、また置ける。**先に置いた場所は描き換えに
    /// 引きずられない**ので、途中の姿と最後の姿を並べられる。
    ///
    /// 描き換える直前に、置いた側がそのときの画像のコピーを取って読む。置いた側はそこでフラッシュされ
    /// ないので、フレームの途中の区切り (``loadPixels()`` の説明) にならない。コピーは置いた側
    /// 1 つにつき 4 枚まで持ち、同じ大きさなら次のフレームで使い回す。**1 フレームに「置く →
    /// 描き換える」を 4 回より多く繰り返すと、越えた分はコピーせずに置いた側をフラッシュする** (区切りに
    /// なる)。置いた側が形を構築している途中 (``createShape(_:)``) に描き換えても、同じくコピーを
    /// 読むのでフラッシュしない (コピーの上限を越えた分とコピーを用意できなかった分は、構築の前に置いた列だけをフラッシュし、構築した形は残る)。形の中で
    /// 置いたグラフィックスはコピーへ替わらず、形を置いたときの画像を読む。止まっている間 (``noLoop()`` の後の
    /// コールバック) に置いて描き換えたものは、ほかの置いたものと同じく次のフレームで出る。
    ///
    /// - Throws: グラフィックスを確保できないときと、幅・高さのどちらかが 1 を割るとき
    ///   (``RenderFailure/invalidSize(width:height:)``。1×1 へ丸めない)・書き出しの倍率を掛けた大きさが上限を越えるとき
    ///   (``RenderFailure/sizeBeyondOutputScale(width:height:scale:)``) に ``RenderFailure``。
    ///   **構築のときに投げる** ([ADR-0020] 決定 5) ので、`setup()` で作って持ち回る。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと
    ///   ``RenderFailure/notRunning(call:)`` (プロセスは落ちない)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    // shot: 1 snippet=a1f4852e
    public func createGraphics(_ width: Int, _ height: Int) throws(RenderFailure) -> Canvas {
        try resourceCanvas(RenderFailure.self).createGraphics(width, height)
    }

    /// グラフィックスへ描く間だけ、スケッチの API (``circle(_:_:_:)``・``fill(_:)-(LinearRGBA)`` など) をそのグラフィックスへ
    /// 向ける。**本体向けに書いた描く関数を、書き換えずにグラフィックスで使える。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var trail: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         trail = try createGraphics(400, 300)
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
    ///     ![橙色の半透明の円が楕円の軌道に沿って動き、通った跡が弧になって積み重なっていく](https://i.gyazo.com/24c45ff7db2d4a04d444e08c5ea55c6b.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `brush()` の中は本体に描くときと同じ書き方で、`trail.` を付けない。クロージャを抜けると向き先は本体へ戻る。
    /// クロージャの中の描画は本体の描画先に出ず、``image(_:_:_:)-(Canvas,_,_)`` で置くまで本体は下地のままである。
    ///
    /// ## クロージャの中でグラフィックスへ向く API
    ///
    /// - 形・描画の状態・光・視点・材質・変換・切り抜き (``circle(_:_:_:)``・``fill(_:)-(LinearRGBA)``・
    ///   ``translate(_:_:)``・``background(_:)-(LinearRGBA)`` など)
    /// - パーティクル (``emit(_:from:toward:rate:speed:life:size:color:)``・``force(_:_:)``・``particles(_:)``) と
    ///   ``orbitControl(_:_:_:)``
    /// - ``canvas``・``effects(_:)``・``filter(_:)``・``shader(_:)``・画素の読み書き・ノイズのシードと詳細度
    /// - 値の形 (`Rect`・`Circle`) の `draw()`
    ///
    /// **``width`` と ``height`` はグラフィックスの大きさを返す。** 本体が 400×400、グラフィックスが 200×100 なら、
    /// 次はグラフィックスの全面を塗る (本体の大きさでは塗らない):
    ///
    /// <!-- example: 文脈 var pad: Canvas! -->
    /// ```swift
    /// draw(into: pad) {
    ///     background(255)
    ///     rect(0, 0, width, height)
    /// }
    /// ```
    ///
    /// **入力 (``mouseX``・``mouseY``・キーなど) は本体のウィンドウのまま**で、グラフィックスの座標へは変わらない。グラフィックスを
    /// 本体と同じ大きさにして、マウスの位置にそのまま描く使い方を想定している。
    ///
    /// **グラフィックスが本体より小さいときは、クロージャの中で本体の座標をグラフィックスの座標へコピーする。** クロージャの中で切り替わるのは
    /// ``width`` と ``height`` だけで (グラフィックスの大きさになる)、``mouseX`` と ``mouseY`` は本体の座標のままである。
    /// 本体が 400×400 で、200×100 のグラフィックス `pad` を (0, 0) から 400×400 に引き伸ばして出すなら、本体のマウス
    /// (200, 200) は `pad` の (100, 50) に当たる。`circle(mouseX, mouseY, …)` と書くと、`pad` の外 (200×100 の外) へ
    /// 描いてしまうので、`mouseX * width / 400`・`mouseY * height / 400` とコピーする。一般には、本体の座標から
    /// グラフィックスを置いた位置を引き、置いた倍率 (置いた幅 ÷ グラフィックスの幅) で割る。コピーを自動では行わない。
    /// 次の例は、マウスの代わりに本体の座標で動く点 (白い輪) を使う。グラフィックスに残る橙色の筆跡の先頭が、その輪と重なる:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         pad = try createGraphics(200, 100)
    ///     }
    ///
    ///     func draw() {
    ///         // 本体 (400×400) の座標で動く点。マウスなら (mouseX, mouseY)
    ///         let x = 200 + 150 * cos(time * 3)
    ///         let y = 200 + 100 * sin(time * 4)
    ///
    ///         draw(into: pad) {
    ///             noStroke()
    ///             fill(255, 102, 51)
    ///             circle(x * width / 400, y * height / 400, 4)   // width・height は pad の 200・100
    ///         }
    ///
    ///         background(23, 26, 31)
    ///         image(pad, 0, 0, 400, 400)   // pad を 400×400 に引き伸ばして出す
    ///         noFill()
    ///         stroke(255)
    ///         circle(x, y, 16)             // 本体の点
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の下地に橙色の筆跡が曲線を描いて積み重なり、先頭を白い輪が囲んでいる。筆跡は縦に長く引き伸ばされている | size=400x400 frames=60 -->
    ///     ![灰色の下地に橙色の筆跡が曲線を描いて積み重なり、先頭を白い輪が囲んでいる。筆跡は縦に長く引き伸ばされている](https://i.gyazo.com/64ba078d83147430096ac0d3b243943c.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 時刻 (``time``・``deltaTime``・``frameCount``) も本体と同じである。``orbitControl(_:_:_:)`` のカメラ操作の状態 (``orbit``) は本体と共有で、
    /// 視点を書く先だけがグラフィックスになる。操作の始点は本体の描画先の中央で、操作の状態を進めてよいかも
    /// 本体のフレームで決まる (`setup()` の中から呼ぶと、本体と同じく断る)。
    ///
    /// 効果はグラフィックスのものになり、本体の効果は書き換わらない:
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
    /// 入れ子にでき、内側を抜けると 1 つ外の向き先へ戻る。クロージャの中で `other.circle(…)` とグラフィックスを指して書いた
    /// 呼び出しは、これまでどおりそのグラフィックスへ行く:
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
    /// グラフィックスのフレームは ``Canvas/draw(_:)`` と同じ規則で開く。閉じていれば開いてクロージャを走らせ、抜けるときに
    /// フラッシュする。``Canvas/beginDraw()`` で開いている最中なら、そのフレームの続きとして走らせる (注意を 1 度出す)。
    /// 直に作った描画先でも同じで、開いていたフレームを捨てて開き直すことはない。
    /// グラフィックスの形の構築 (``Canvas/createShape(_:)``) の中では、フレームを始めずに構築の続きとして
    /// 走らせる。**ただしフラッシュの失敗は、投げずに警告を出す** (``Canvas/endDraw()`` と同じ)。
    /// ``Canvas/draw(_:)`` は ``RenderFailure`` を投げるので、そこだけ違う。
    ///
    /// ## 3 つの `draw` の違い
    ///
    /// - ``Sketch/draw()``: 利用者が書く、1 フレームごとに呼ばれる関数
    /// - ``Canvas/draw(_:)``: グラフィックスのフレームを開き、スケッチの中なら**中の素の呼び出しをグラフィックスへ向ける**
    ///   ([#3866])。フラッシュの失敗は ``RenderFailure`` を投げる
    /// - `draw(into:)`: グラフィックスのフレームを開き、**中の素の呼び出しをグラフィックスへ向ける**。フラッシュの失敗は警告する。
    ///   本体の描画先を渡すとフレームを開き直さない (下の「本体の描画先を渡したとき」)
    ///
    /// 以前は ``Canvas/draw(_:)`` の中の素の呼び出しが本体へ行き、同じ形の `draw(into:)` と画像が黙って割れた
    /// ([#3866])。手動の対 (``Canvas/beginDraw()`` / ``Canvas/endDraw()``) の間の素の呼び出しは、今も本体へ行く。
    ///
    /// ## ノイズのシード・時刻・パーティクルの刻みは、向き先によらずスケッチのもの
    ///
    /// クロージャの中の ``noise(_:_:_:_:)``・``noiseSeed(_:)``・``noiseDetail(_:_:)`` とパーティクルの刻みは、
    /// **向き先が直に作った描画先 (``Canvas/init(target:gpu:)``) でも、スケッチの状態を読み書きする** —
    /// シードはスケッチに 1 つである。パーティクルの `wander` の揺れも、本体のフレームの番号で決まる。クロージャを抜けると、
    /// 直に作った描画先は自分の状態へ戻る。ただし**クロージャを抜けた後も描画先のフレームが開いたままなら、時刻は
    /// そのフレームが閉じるまでスケッチのまま**である (時刻はフラッシュの時点で 1 つ読むため。クロージャの中で置いた
    /// 図形が、描画先自身の時刻で描かれない)。``createGraphics(_:_:)`` で作ったグラフィックスは、もともと本体と
    /// 状態を共有する。形の構築の終了時の規則 (``createShape(_:)``) は、本体の状態について効く。
    ///
    /// ## 本体の描画先を渡したとき
    ///
    /// 本体の描画先 (``canvas``) を渡すと、フレームは開き直さず、クロージャをそのまま走らせる。本体のフレームを
    /// 保証するのはランタイムで、`setup()` の中から開くと本体のフレームが余分に回ってしまうためである
    /// (`canvas.draw { }` は本体のフレームを開き直す)。入れ子の中から本体へ戻る書き方にも使える。
    ///
    /// ## パーティクルをグラフィックスへ出す
    ///
    /// ``Canvas`` は `emit` を公開しない。乱数の列を 1 本に保つためである (``randomSeed(_:)`` がパーティクルに効かなくなる)。
    /// グラフィックスへパーティクルを出すときは、クロージャの中で ``emit(_:from:toward:rate:speed:life:size:color:)`` を呼ぶ。
    ///
    /// [#3866]: https://github.com/mokume-metal/mokume/issues/3866
    ///
    /// - Parameters:
    ///   - graphics: 描く先のグラフィックス。
    ///   - body: 中の呼び出しが `graphics` へ向くクロージャ。
    // shot: 1 snippet=52cdbef4
    // shot: 2 snippet=ba1fde9c
    public func draw(into graphics: Canvas, _ body: () -> Void) {
        guard let runtime = liveRuntime() else { return }
        // 本体の面のフレームを約束するのはランタイム。ここで開くと、`setup()` の中から呼んだときに
        // 本体のフレームが余分に回る。向き先だけを立てて、閉包を走らせる
        if graphics === runtime.canvas {
            let previous = runtime.drawingInto
            runtime.drawingInto = graphics
            defer { runtime.drawingInto = previous }
            return body()
        }
        // 向き先を立てて置き場を借りるのは `Canvas.draw(_:)` が走っているスケッチの中で行う (#3866)。
        // ここで違うのは、描き切りの失敗を投げずに警告する所だけ
        do {
            try graphics.draw(body)
        } catch {
            Diagnostics.warn("draw(into:): could not finish drawing: \(error.headline)")
        }
    }

    /// グラフィックスを等倍で置く。
    ///
    /// (`x`, `y`) の読み方は ``imageMode(_:)`` が決める — 既定の `.corner` と `.corners` なら
    /// 左上の角、`.center` と `.radius` なら中心が (`x`, `y`) に来る。**大きさは、どの読み方でも
    /// グラフィックスの座標の大きさ (``createGraphics(_:_:)`` に渡した幅と高さ) のまま**である。
    /// 書き出しの倍率 (`mokume render --scale`) の下ではグラフィックスの画素が倍率を掛けた数になるが、置く大きさは変わらない。
    ///
    /// 置くのは**そのときフラッシュ済みの画像**である。``Canvas/endDraw()`` を呼ぶ前に置くと、
    /// 途中の区切り (`loadPixels()`・`get()` など) が無ければ 1 フレーム前の画像、あれば区切りまで
    /// 描いた画像が出る (効果は通らない)。どちらも警告が出る。ピクセル密度 (``SketchSettings/pixelDensity``)
    /// にはよらない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         pad = try createGraphics(120, 120)
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
    ///     <!-- shot: 120 画素四方のグラフィックスが等倍で置かれ、白い 2 本の線が外からその左上の角を指している -->
    ///     ![120 画素四方のグラフィックスが等倍で置かれ、白い 2 本の線が外からその左上の角を指している](https://i.gyazo.com/cee09c7f5e6322052d5f2457c5207368.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=423340e2
    public func image(_ graphics: Canvas, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        guard let canvas = liveCanvas() else { return }
        let (x, y) = (x.asFloat, y.asFloat)
        canvas.image(graphics, x, y)
    }

    /// グラフィックスを、指定した寸法に合わせて置く。
    ///
    /// 4 つの数の読み方は ``imageMode(_:)`` が決める。画像と同じ扱いなので、
    /// ``tint(_:)`` の色掛けも同じように効く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         pad = try createGraphics(120, 120)
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
    ///     <!-- shot: 左に大きく、右に小さく同じグラフィックス。右は赤が抑えられて青緑に寄っている -->
    ///     ![左に大きく、右に小さく同じグラフィックス。右は赤が抑えられて青緑に寄っている](https://i.gyazo.com/5dd046b52d65cfbbfe205be1b52eb955.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=d40247f8
    public func image(_ graphics: Canvas, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        guard let canvas = liveCanvas() else { return }
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        canvas.image(graphics, a, b, c, d)
    }

    /// グラフィックスの一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**グラフィックスの中のどこを切り出すか**。切り出しが
    /// 外へ出ても落ちず、**重なった分だけが、同じ倍率で指した場所に出る** — 置き先も切り出しを
    /// 締めたのと同じ割合で締まるので、倍率は `置き先 / 切り出し` のまま変わらない。
    /// たとえば 64 画素四方のグラフィックスの `(32, 0, 64, 64)` を `128×128` へ置くと、置き先の右半分
    /// (グラフィックスの右端を越えた所) には何も置かれず、重なった分 (グラフィックスの右半分) が 2 倍の
    /// `64×128` で置き先の左半分に出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         pad = try createGraphics(120, 120)
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
    ///     <!-- shot: 左にグラフィックスの全体、右はその左上 4 分の 1 だけを同じ大きさへ引き伸ばしたもの -->
    ///     ![左にグラフィックスの全体、右はその左上 4 分の 1 だけを同じ大きさへ引き伸ばしたもの](https://i.gyazo.com/415dd5a9f368feb579a7a5cf2d59ab21.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=9f3f2df0
    public func image(
        _ graphics: Canvas, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ sourceX: some ScalarConvertible, _ sourceY: some ScalarConvertible, _ sourceWidth: some ScalarConvertible, _ sourceHeight: some ScalarConvertible
    ) {
        guard let canvas = liveCanvas() else { return }
        let (a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, sourceX.asFloat, sourceY.asFloat, sourceWidth.asFloat, sourceHeight.asFloat)
        canvas.image(graphics, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// これから置く塗りに画像を貼る。
    ///
    /// 下の画像は、橙色と青灰色の 8 画素の格子でできた 64 画素四方の画像を、同じ
    /// `texture(tile)` のまま 3 つの形に貼ったもの。読み取り位置は組み込みの形が自分で持つ —
    /// 四角には画像が 1 枚、箱には 6 面それぞれに 1 枚、球には経度と緯度に沿って巻かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
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
    ///         push {
    ///             translate(200, 150, 0)
    ///             rotateX(-0.5)
    ///             rotateY(0.6)
    ///             box(90)
    ///         }
    ///
    ///         push {
    ///             translate(330, 150, 0)
    ///             rotateY(-0.6)
    ///             sphere(55)
    ///         }
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
    /// 四角、右は線を消した四角で、どちらも内側には同じ描画結果が貼られている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
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
    ///     <!-- shot: 同じ描画結果を貼った四角が 2 つ。左は太い黄色の縁があり、縁には画像が貼られていない。右は縁が無く、画像が四角の端まで続いている -->
    ///     ![同じ描画結果を貼った四角が 2 つ。左は太い黄色の縁があり、縁には画像が貼られていない。右は縁が無く、画像が四角の端まで続いている](https://i.gyazo.com/63f28fb64415257df422a70b9888c4c7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **貼った画像は、光と材質を通ったあとの色に掛かる。** 立体では陰影がそのまま残り、
    /// 平面では ``fill(_:)-(LinearRGBA)`` が色掛けになる (白なら画像がそのまま出る)。下の 3 枚はどれも
    /// 同じ四角で、変えたのは `fill` だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
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
    ///     <!-- shot: 同じ描画結果を貼った四角が 3 つ。左は画像がそのまま、中は緑と青が抑えられて赤みが乗り、右は全体が暗くなっている -->
    ///     ![同じ描画結果を貼った四角が 3 つ。左は画像がそのまま、中は緑と青が抑えられて赤みが乗り、右は全体が暗くなっている](https://i.gyazo.com/1dab2d544daf6584fca1fed62a843318.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 自分で並べた形では ``vertex(_:_:_:_:)`` で読み取り位置を書け、書かなければ形の
    /// 囲みの箱から決まる。円柱と円錐は側面の一周と蓋の円、輪は 2 つの一周を読む。
    ///
    /// **画像を貼らずに ``shader(_:)`` だけを当てた形にも、同じ読み取り位置がシェーダの `in.uv` へ届く**
    /// (白い 1×1 の画像を貼ったのと同じ)。模様を描くシェーダは、画像が無くても形に付いてくる。
    ///
    /// **描き方なのでフレームを越える** — 塗りや線と同じく、一度書けば
    /// ``noTexture()`` を呼ぶまで続き、``push(fileID:line:)`` / ``pop(fileID:line:)`` で積める。
    // shot: 1 snippet=56054e65 image=592a9bcf077af6ce
    // shot: 2 snippet=8457adaf
    // shot: 3 snippet=17433594
    public func texture(_ image: Image) { liveCanvas()?.texture(image) }

    /// これから置く塗りにグラフィックスを貼る。
    ///
    /// **読み込んだ画像とまったく同じに扱える。** 毎フレーム描き直したグラフィックスを
    /// 立体に貼れば、面の上で動く画像になる。下の画像は、青灰色の地に橙色の円を描いた
    /// グラフィックスを、四角と箱に貼ったもの。箱の 6 面には、それぞれグラフィックスが 1 枚ずつ貼られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         pad = try createGraphics(120, 120)
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
    ///         push {
    ///             translate(290, 150, 0)
    ///             rotateX(-0.5)
    ///             rotateY(0.6)
    ///             box(100)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左の四角と右の箱の面に、青灰色の地に橙色の円を描いた同じグラフィックスが貼られている。箱は陰影が付き、面ごとに円がある -->
    ///     ![左の四角と右の箱の面に、青灰色の地に橙色の円を描いた同じグラフィックスが貼られている。箱は陰影が付き、面ごとに円がある](https://i.gyazo.com/fbf158869e8ae93c6d64d9288cab0770.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **貼るのは 1 度でよい。** 呼び直さずにグラフィックスを描き換えながら塗り続けても、形は
    /// 置くたびにその時点の画像で描かれる — 先に置いた形が、後から描き換えた画像に化けることは
    /// ない。`setup()` で 1 度だけ貼って毎フレーム描き換えても、`createShape` の中で貼った
    /// 形を描き換えながら置き直しても同じである。下の例は 1 度だけ貼り、四角を置いてから
    /// グラフィックスの円を描き換えて、もう 1 つ四角を置いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pad: Canvas! -->
    ///     ```swift
    ///     func setup() throws {
    ///         pad = try createGraphics(120, 120)
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
    /// - Note: 貼る画像は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=f7249143 image=74746e0b7fc5a93d
    // shot: 2 snippet=a78d202e
    public func texture(_ graphics: Canvas) { liveCanvas()?.texture(graphics) }

    /// 画像を貼るのをやめる。
    ///
    /// 以後の塗りは貼る画像なしの、``fill(_:)-(LinearRGBA)`` の色になる。下の左は画像を貼ったままの
    /// 四角、右は `noTexture()` の後に `fill` を変えて置いた同じ四角で、右は 1 色で塗られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
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
    /// 貼る画像はスタイルとして積まれるので、``push(_:)`` のクロージャの中で呼んだ `noTexture()` は
    /// クロージャを抜けると元に戻る (``push(fileID:line:)`` / ``pop(fileID:line:)`` の対でも同じ)。下の画像は、
    /// 貼ったまま 3 つ目の四角を置くとき、2 つ目だけを `push { }` で包んで画像を外している。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
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
    ///         push {
    ///             noTexture()
    ///             fill(242, 115, 64)
    ///             rect(150, 100, 100, 100)
    ///         }
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
    /// - Note: 貼る画像は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=3d8912c0
    // shot: 2 snippet=cd9091a0 image=6f8d871270ab0592
    public func noTexture() { liveCanvas()?.noTexture() }
}

extension SketchRuntime {
    /// `work` の間だけ、スケッチの口の向き先を `graphics` に立て、揺らぎの種・時刻・粒の刻みを本体の描画先から
    /// 借りる ([#2454]・[#3866])。抜けると 1 つ前の向き先へ戻り、借りた置き場を手放す (手放し方は
    /// ``Canvas/borrowSketchState(from:)``)。
    ///
    /// 本体以外の描画先の ``Canvas/draw(_:)`` が、走っているスケッチの中で呼ばれたときに通る 1 本で、
    /// ``SketchPart/draw(into:_:)`` もここを通る (`Canvas.draw(_:)` を呼ぶ)。本体の描画先は渡さない —
    /// 本体の置き場は借りるまでもなく本体のものである。
    ///
    /// [#2454]: https://github.com/mokume-metal/mokume/issues/2454
    /// [#3866]: https://github.com/mokume-metal/mokume/issues/3866
    func directing(to graphics: Canvas, _ work: () throws(RenderFailure) -> Void) throws(RenderFailure) {
        let previous = drawingInto
        drawingInto = graphics
        defer { drawingInto = previous }
        let restore = graphics.borrowSketchState(from: canvas)
        defer { restore() }
        try work()
    }
}
