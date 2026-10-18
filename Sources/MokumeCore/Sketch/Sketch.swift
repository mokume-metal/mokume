// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 利用者が書く単位。
///
/// ```swift
/// final class MySketch: Sketch {
///     func draw() {
///         background(26, 26, 31)
///         fill(255, 102, 51)
///         circle(width / 2, height / 2, 200)
///     }
/// }
/// ```
///
/// 描く・入力を読むといった語彙 (``SketchPart/fill(_:)``・``SketchPart/circle(_:_:_:)``・
/// ``SketchPart/mouseX`` など) は、スケッチが継ぐ ``SketchPart`` に置いてある。自分で書いた型も
/// `: SketchPart` と名乗れば、その中から同じ語彙を使える。
///
/// **並行性の注釈は 1 つも要らない。** ライブラリ全体が main actor を既定の隔離と
/// しているので、スケッチもそこに乗る ([ADR-0010] 決定 1)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public protocol Sketch: AnyObject, SketchPart {
    /// 引数なしで作れること。
    init()

    /// 大きさなどの設定。
    var settings: SketchSettings { get }

    /// 外から足す機能の並び。
    ///
    /// **並びは 1 本で、順序は宣言順** ([ADR-0024] 決定 4)。出口だけを足すものも
    /// 入り口だけを足すものも同じ並びに置き、仕分けは仕組みが行う。
    ///
    /// <!-- example: 組めない VideoSender は外のパッケージが持つ (このリポジトリには無い) -->
    /// ```swift
    /// var plugins: [any Plugin] { [VideoSender(name: "mokume")] }
    /// ```
    ///
    /// 書いてあれば効き、書いていなければ効かない — 実行時に探して読み込む形も、
    /// 依存に入れただけで効く形も採らない (同 決定 5)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    var plugins: [any Plugin] { get }

    /// 一度だけ呼ばれる。
    func setup()

    /// フレームごとに呼ばれる。
    func draw()

    /// 押された瞬間に呼ばれる。
    ///
    /// **1 フレームに押して離しても、両方とも呼ばれる。** 状態 (``SketchPart/isMousePressed``) を
    /// 毎フレーム読む形では、押下と解放が同じフレームに収まると押されたことがどこにも
    /// 残らない — 外から送る経路では 1 回の要求がまとめて 1 フレームへ入るので、
    /// これは構造的に起きる ([#723])。
    ///
    /// 読める値 (``SketchPart/mouseX`` / ``SketchPart/mouseY`` / ``SketchPart/isMousePressed`` / ``SketchPart/mouseButton``) は、
    /// **その出来事を当てた直後の姿**である。`draw()` の直前に、届いた順で呼ばれる。
    ///
    /// **押下と解放の対は保証されない。** 溜める上限を越えたぶんは古いほうから捨てられる
    /// ので、描画が長く停滞すれば押下だけ・解放だけが届くことがある。
    ///
    /// <!-- example: 文脈 var seeds: [(Float, Float)] = [] -->
    /// ```swift
    /// func mousePressed() {
    ///     seeds.append((mouseX, mouseY))
    /// }
    /// ```
    ///
    /// [#723]: https://github.com/mokume-metal/mokume/issues/723
    func mousePressed()

    /// 離された瞬間に呼ばれる。読める値の約束は ``mousePressed()`` と同じ。
    ///
    /// **窓が前から退いたとき (⌘Tab・ほかの窓を触る・メニューを開く) も、押していた釦の数だけ
    /// 呼ばれ、``mouseClicked()`` が続く。** 退いている間に離した釦は窓へ届かないので、離した扱い
    /// にしないと押されたまま残る ([#2443](https://github.com/mokume-metal/mokume/issues/2443))。
    /// 離していないのに呼ばれる・クリックになるのが代償である。戻ってから本物の解放が届いても、
    /// 2 度は呼ばれない。
    func mouseReleased()

    /// 押して離されたときに、``mouseReleased()`` の**直後に続けて**呼ばれる。
    ///
    /// 押下を伴わない解放 (窓の外で押して中で離した、など) では呼ばれない。押していた釦を窓が
    /// 退いて離した扱いにしたときは呼ばれる (``mouseReleased()``)。
    /// 時刻を見ないので、外から送った出来事でも窓での実操作と同じように起きる。
    func mouseClicked()

    /// 押していない間に動いたとき呼ばれる。押している間は ``mouseDragged(deltaX:deltaY:)`` が呼ばれる。
    ///
    /// 動いた量が要るなら ``mouseMoved(deltaX:deltaY:)`` を書く — ここの直後に続けて呼ばれる。
    func mouseMoved()

    /// 押していない間に動いたとき、``mouseMoved()`` の**直後に続けて**呼ばれる。**その 1 件で
    /// 動いた量**を受け取る。
    ///
    /// カーソルを捕まえて見回す一人称のスケッチは、ここで向きを回す
    /// (``SketchPart/requestPointerLock()``):
    ///
    /// ```swift
    /// var yaw: Float = 0
    ///
    /// func mouseClicked() { requestPointerLock() }
    ///
    /// func mouseMoved(deltaX: Float, deltaY: Float) {
    ///     yaw += deltaX * 0.005
    /// }
    /// ```
    ///
    /// 捕まえている間は位置が動かないので、``SketchPart/mouseX`` の差では動きが読めない — 量はここで
    /// 受け取る。捕まえていないときは、当てる前の位置との差が渡る。単位はどちらも描く解像度の
    /// 画素で、縦軸は下向きである。
    ///
    /// 1 フレームに移動が 3 件届けばここは 3 回呼ばれる。ここと
    /// ``mouseDragged(deltaX:deltaY:)`` に渡った量を足すと、フレーム合計 (``SketchPart/movedX``) と一致
    /// する。**``SketchPart/movedX`` をここで読まない** — フレームの頭から足し込む合計なので、ここから
    /// 読むと部分累計を何度も足し込む形になる ([ADR-0034] 決定 5)。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    func mouseMoved(deltaX: Float, deltaY: Float)

    /// 押したまま動いたとき呼ばれる。**その 1 件で動いた量**を受け取る。
    ///
    /// ```swift
    /// var angle: Float = 0
    ///
    /// func mouseDragged(deltaX: Float, deltaY: Float) {
    ///     angle += deltaX * 0.01
    /// }
    /// ```
    ///
    /// **手本 (Processing・p5.js) の引数なしの形 `func mouseDragged()` で書くと、コンパイルは
    /// 通るが一度も呼ばれない。** Swift は、名前が同じで引数の違うメソッドを咎めない。上の形の
    /// `func mouseDragged(deltaX: Float, deltaY: Float)` に書き直せば、ドラッグで呼ばれる。量を
    /// 使わなくても引数は要る ([ADR-0034] 決定 5 の追補に、作品が踏んだ記録がある)。
    ///
    /// 1 フレームに移動が 3 件届けばここは 3 回呼ばれ、渡る量はそれぞれの 1 件ぶんに
    /// なる。**3 つ足せばフレーム合計 (``SketchPart/dragX``) と一致する** — 面から読む量とここへ
    /// 渡る量は、用途が違うだけで食い違わない ([ADR-0034] 決定 5)。
    ///
    /// ただし ``SketchPart/orbitControl(_:_:_:)`` は `draw()` の中で 1 回呼ぶ形のままにする。
    /// あちらが食うのはフレーム合計なので、ここから呼ぶと**同じフレームの量を何度も
    /// 食う**ことになり、回りすぎる。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    func mouseDragged(deltaX: Float, deltaY: Float)

    /// スクロールされたとき呼ばれる。**その 1 件ぶんの量**を受け取る。
    ///
    /// ```swift
    /// var size: Float = 120
    ///
    /// func mouseWheel(deltaX: Float, deltaY: Float) {
    ///     size = min(max(size + deltaY * 4, 20), 400)
    /// }
    /// ```
    ///
    /// **手本 (Processing・p5.js) の形をまねて引数なしの `func mouseWheel()` と書くと、コンパイルは
    /// 通るが一度も呼ばれない** (``mouseDragged(deltaX:deltaY:)`` と同じ)。上の形の
    /// `func mouseWheel(deltaX: Float, deltaY: Float)` に書き直す。回した量は手本の `event` から
    /// 読む代わりに、引数で受け取る。
    ///
    /// **``SketchPart/scrollY`` をここで読んではいけない。** あちらはフレームの頭から足し込む
    /// 合計なので、1 フレームに 3 件届くと `a` + `(a+b)` + `(a+b+c)` を足し込む形に
    /// なる。欲しいのは `a+b+c` である ([ADR-0034] 決定 5)。
    ///
    /// フレームに 1 件しか届かない環境では**間違えた側も正しく動く**ので、窓を触って
    /// 確かめている限り気付けない。
    func mouseWheel(deltaX: Float, deltaY: Float)

    /// キーが押された瞬間に呼ばれる。**押した 1 回だけで、押しっぱなしでは呼び直さない。**
    ///
    /// <!-- example: 文脈 var showsGrid = false -->
    /// ```swift
    /// func keyPressed() {
    ///     if keyCode == .space { showsGrid.toggle() }  // 押したままでも 1 回だけ切り替わる
    /// }
    /// ```
    ///
    /// OS のキーリピートは、文字を打つ ``keyTyped()`` にだけ届く。**Processing は連射するが、
    /// 引き継がない** — 「1 回だけ切り替える」に、押したままかの印を作者が持つ必要があった
    /// ([#2400](https://github.com/mokume-metal/mokume/issues/2400))。p5.js と同じ振る舞いである。
    /// 押している間ずっと効かせたいもの (矢印で動かす、など) は、`draw()` で
    /// ``SketchPart/keyboard`` の `isPressed(_:)` を読む。
    ///
    /// 呼ばれるのは押されていないキーが押されたとき (と、押されているはずのキーにリピートでない
    /// 押下が届いたとき。解放を取りこぼした印として、押し直しに数える) で、**修飾キー (Shift・Control・Option・
    /// Command) では呼ばれない**。修飾キーは `keyboard.isPressed(.shift)` で問う。
    ///
    /// ``SketchPart/noLoop()`` で止めている間も呼ばれる (止まっている間もコールバックは呼ばれる)。
    ///
    /// どのキーが動いたかは ``SketchPart/keyCode`` から読む。文字を打つ用途には ``keyTyped()`` と
    /// ``SketchPart/key`` を使う。
    func keyPressed()

    /// キーが離された瞬間に呼ばれる。
    ///
    /// 離されたキーも ``SketchPart/keyCode`` が指す — **最後に動いたキー**なので、押した側と同じ
    /// 口から読める。
    ///
    /// **窓が前から退いたとき (⌘Tab・ほかの窓を触る・メニューを開く) も、押していたキーの数だけ
    /// 呼ばれる。**
    /// 退いている間に離したキーは窓へ届かないので、離した扱いにしないと押されたまま残る
    /// ([#2443](https://github.com/mokume-metal/mokume/issues/2443))。離していないのに呼ばれるのが
    /// 代償である。呼ばれるのは押されているキーが離されたときだけなので、戻ってから本物の解放が
    /// 届いても 2 度は呼ばれない。修飾キーでは呼ばれない。
    func keyReleased()

    /// **文字を生むキー**が押されたときに呼ばれる。押した瞬間は ``keyPressed()`` の直後に続き、
    /// 押しっぱなしではキーリピートが届くたびに、これだけがまた呼ばれる。
    ///
    /// 矢印・ファンクションキー・Escape・Delete・Tab では呼ばれない (手本と同じ)。
    /// 打たれた文字は ``SketchPart/key`` から読む。
    func keyTyped()
}

extension Sketch {
    public var settings: SketchSettings { SketchSettings() }
    public var plugins: [any Plugin] { [] }
    public func setup() {}
    public func draw() {}
    public func mousePressed() {}
    public func mouseReleased() {}
    public func mouseClicked() {}
    public func mouseMoved() {}
    public func mouseMoved(deltaX: Float, deltaY: Float) {}
    public func mouseDragged(deltaX: Float, deltaY: Float) {}
    public func mouseWheel(deltaX: Float, deltaY: Float) {}
    public func keyPressed() {}
    public func keyReleased() {}
    public func keyTyped() {}
}

/// スケッチの設定。
public struct SketchSettings: Equatable, Sendable {
    /// 出す幅 (画素)。**スケッチが書く座標もこの幅の中にある。**
    public var width: Int
    /// 出す高さ (画素)。
    public var height: Int
    /// 1 秒あたりのフレーム数の目標。**1 以上。** 0 以下は起動の組み立てで
    /// ``RenderFailure/invalidFrameRate(_:)`` として断り、1 fps へ丸めない。止めたいなら
    /// ``SketchPart/noLoop()`` を呼ぶ。
    ///
    /// **起動のときに読む。** 走っている最中に代入しても、画面の刻みも ``SketchPart/time`` /
    /// ``SketchPart/deltaTime`` も変わらない。`var settings = SketchSettings(…)` と持てば
    /// `setup()` や `draw()` の中で代入でき、読み返しても代入した値が返るので、変えられたように
    /// 見えてしまう。**そのため、起動のときと違う値になったら、1 度だけ警告を標準エラーへ
    /// 出す** (同じ走りの中では繰り返さない・[#1323](https://github.com/mokume-metal/mokume/issues/1323))。
    ///
    /// 手本 (Processing / p5) の `frameRate(n)` は走っている最中に呼べるが、ここには
    /// 走っている最中に速さを変える口が無い。
    public var frameRate: Int
    /// 窓で走らせるときの時計。既定は ``ClockMode/wallClock`` (実際に流れた時間)。
    ///
    /// ``ClockMode/frames`` にすると、窓の中でも ``Sketch/draw()`` 1 回がちょうど
    /// ``frameRate`` 分の 1 秒になる。書き出し (`mokume render`) と同じ時計で、``SketchPart/time`` は
    /// `(frameCount − 1) / frameRate`、``SketchPart/deltaTime`` は常に 1 / ``frameRate`` である。
    /// 同じ入力をフレームの番号つきで流せば、同じ状態に進む — ゲームの書き方 (Pico-8・GameMaker・
    /// Processing の `x += 2`) である。
    ///
    /// <!-- example: 文脈 var ball = Circle(x: 240, y: 60, radius: 8); var vy: Float = 0 -->
    /// ```swift
    /// var settings: SketchSettings { SketchSettings(width: 480, height: 270, clock: .frames) }
    ///
    /// func draw() {
    ///     // フレームと押下の判定の単位が同じなので、2 回発火も取りこぼしも無い
    ///     if keyboard.justPressed(.space) { vy = -8 }
    ///     vy += 0.4                        // deltaTime を掛けなくてよい
    ///     ball.move(by: Vector2(0, vy))
    ///     background(20)
    ///     ball.draw()
    /// }
    /// ```
    ///
    /// ## 重いフレームでは、絵を抜かずに遅くなる (処理落ち)
    ///
    /// 1 フレームに 30 ms かかっても、``SketchPart/time`` は 1/60 秒しか進まない。実時間の時計なら
    /// 30 ms 進み、`deltaTime` も約 0.03 になる。処理落ちが起きたことは、観測の重さ
    /// (1/fps を越えたフレームの数と、いちばん重かったフレームの番号) と、窓の数字の欄に出る。
    ///
    /// - **処理落ちの間、実時間で進むものとずれる。** 音 (``SketchPart/clock`` が実時間でなくても、窓では
    ///   実際に鳴らす)・カメラ・外から届く値は実時間で進み、絵だけが遅れる
    /// - **実時間が正であるべきゲーム** (音楽に合わせるリズムゲームなど) は、既定の
    ///   ``ClockMode/wallClock`` のまま、``SketchPart/time`` と ``SketchPart/deltaTime`` で書く
    /// - 重さの元になりやすい `draw()` の中の同期の読み込み (`loadImage` など) は、1 度だけ警告する。
    ///   `setup()` で読むか、`request…` の口を使う
    ///
    /// ## 止める口の意味は、時計によらない
    ///
    /// | 口 | `draw()` | `frameCount` | `time` | `deltaTime` | 入力 |
    /// | --- | --- | --- | --- | --- | --- |
    /// | 何もしない | 毎フレーム | +1 | 進む | 1/fps | 届く |
    /// | ``SketchPart/pauseTime()`` の間 | 呼ばれる | +1 | 止まる | 0 | 届く |
    /// | ``SketchPart/jumpTime(_:)`` の枚 | 呼ばれる | +1 | 指定の秒へ跳ぶ | 0 | 届く |
    /// | 時刻を指定した観測の 1 枚 | 呼ばれる | +1 | その枚だけ指定の秒 | 0 | 届く |
    /// | ``SketchPart/noLoop()`` の間 | 呼ばれない | 止まる | 止まる | — | コールバックは呼ばれる |
    /// | ``SketchPart/redraw()`` | 1 回 | +1 | 1/fps 進む | 1/fps | 届く |
    /// | 外からの停止 (`watch`・MCP) | 呼ばれない | 止まる | 止まる | 再開した枚は 1/fps | 溜まる |
    ///
    /// ゲームの一時停止は「自分の印 + ``SketchPart/pauseTime()``」で書く。足して進めるもの
    /// (`ball.move(by:)`) は自分の印で止め、``SketchPart/time`` から作る動きは `pauseTime()` で止まる。
    /// 描画は続くので、止めた画面に「PAUSED」を出せる。画面ごと凍らせてよいなら
    /// ``SketchPart/noLoop()`` / ``SketchPart/loop()`` を使う。
    ///
    /// ## 窓の外では読まない
    ///
    /// 書き出し (`mokume render`) は、この設定によらず書き出しの刻みのフレームの時計で回る。窓を
    /// 開かずに `SketchRuntime` を直に回すときも、既定でフレームの時計である。走っている時計は
    /// ``SketchPart/clock`` で読める (この設定が ``ClockMode/frames`` の窓では
    /// ``Clock/frameIndex(frameRate:)``)。**起動のときに読む。** 走っている最中に代入しても時計は
    /// 変わらない。
    public var clock: ClockMode
    /// 窓の題名。
    public var title: String

    /// 実際に刻む画素の密度。1 が実寸で、0.5 なら縦横とも半分の細かさで描く。
    ///
    /// **重い絵を低い細かさで描いて拡大すれば、フレーム時間に収まらなかった表現が
    /// 動くようになる** ([ADR-0015] 決定 1)。座標は出す細かさのままなので、
    /// スケッチのコードは 1 行も変わらない。
    ///
    /// 線の太さも出す細かさの画素で書き、描く画素では細かさの分だけ細くなる。0.5 なら
    /// `strokeWeight(1)` の線は描く画素で太さ 0.5 の線として、置く位置によらずその太さぶんの
    /// 濃さで描かれてから拡大される。描く画素で 1 画素より細い線は、描く経路 (距離関数の経路・
    /// 三角形の経路・立体) によらずこうなる。それより太い線は、三角形の経路と立体では描く画素の
    /// 格子で丸まる — たとえば 0.5 の `strokeWeight(3)` は描く画素で 1.5 になり、`triangle` や
    /// `shader()` を付けた図形・立体の線では 1 行か 2 行で塗られる (縁を滑らかにするのは距離関数の
    /// 経路だけである)。塗りも同じで、`rect`・`ellipse` などの基本図形を描く画素で 1 画素より細く
    /// 描いた塗りは、面積に比例した濃さで出る (`shader()` や `texture()` を付けた長い形は、置く位置に
    /// よって 1 割ほど揺れる。扇形 (一周でない `arc`) は付けるかによらず約束の外で、`triangle`・`quad`・
    /// `beginShape` は描く画素の格子で丸まる)。
    /// 効果の半径 (``Effect/blur(radius:)`` など)・切り抜きの矩形 (``SketchPart/clip(_:_:_:_:)``)・
    /// 断片 (塗りと効果) が受け取る位置と大きさも同じく出す細かさの画素で、細かさによらない。
    /// 違うのは描く画素 1 つより細かい所 (拡大のぼけと、描く画素の格子への丸め) だけである。
    ///
    /// 使えるのは 0 より大きく 1 以下。1 を超える指定 (出すより細かく描く) は
    /// 引き受けないので、組み立ての時点で断る。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    public var pixelDensity: Float
    /// 描く細かさと出す細かさの間を、どうやって埋めるか。既定は ``Upscale/spatial``。
    ///
    /// ## 時間方向を選ぶと、単一フレームの再現が失われる
    ///
    /// ``Upscale/temporal`` は前のフレームの結果を積み上げて埋めるので、**フレーム N
    /// の絵はそこへ至る経路に依る** — 単独で描いた N と、0 から進めて得た N が
    /// 一致しない。同じ絵が出ることを前提にした仕組み (画像の比較・単一フレームだけを
    /// 描く経路) は、``SketchPart/usesFrameHistory`` を読んでそれを知る必要がある。
    /// [ADR-0015] 決定 2 の言う代償がこれである。
    ///
    /// ## いまは動きの情報を持たない
    ///
    /// この土台はまだ「どの画素がどこから来たか」を作っていないので、時間方向の
    /// 拡大には「何も動いていない」と告げている。**止まっている絵ではちらつきが減り、
    /// 動くものは尾を引く。** 細かさそのものは空間方向と大きく変わらない。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    public var upscale: Upscale
    /// 窓を開く大きさ。**出す 1 画素を、窓の何点にするか**で書く。既定は 0.5 で、960x540 の
    /// スケッチは 480x270 点の窓で開く。
    ///
    /// 320x180 の画素絵を 4 倍に拡大して見せる窓 (1280x720 点):
    ///
    /// ```swift
    /// var settings: SketchSettings { SketchSettings(width: 320, height: 180, windowScale: 4) }
    /// ```
    ///
    /// 1 にすると、手本 (Processing の `size(1280, 720)`) と同じく 1 画素 = 1 点で開く —
    /// 隣に並べて見比べる窓が同じ大きさになる:
    ///
    /// ```swift
    /// var settings: SketchSettings { SketchSettings(width: 1280, height: 720, windowScale: 1) }
    /// ```
    ///
    /// ## 描く細かさは変わらない
    ///
    /// 決めるのは窓の大きさだけで、描く画素の数は ``width`` と ``height`` のまま変わらない。
    /// 窓が絵より大きければ拡大して、小さければ縮めて出す。開いた後に窓を手で広げても同じで
    /// ある。書き出す絵 (``SketchPart/save(_:)``・録画) にも効かない。
    ///
    /// ## 指定を変えたら、覚えた大きさより指定を取る
    ///
    /// 窓は閉じたときの大きさと位置を覚えていて、次に開くときはそこへ戻す。ただし
    /// **開く大きさの指定 (描く大きさ × この倍率) が前と変わっていれば、覚えた大きさと位置を
    /// 捨てて新しい指定で開く。** 変えていなければ、手で広げた大きさと置いた位置が戻る。
    ///
    /// ## 使える値
    ///
    /// 0 より大きい有限の数。0 以下・無限大・NaN は、組み立ての時点で
    /// ``RenderFailure/invalidWindowScale(_:)`` として断る。**画面に収まらない大きさは、
    /// 縦横比を保って画面へ収まるまで縮めて開き**、縮めたことを 1 行言う — 同じスケッチでも
    /// 画面が大きければ頼んだとおりに開くので、値そのものは断らない。
    ///
    /// **起動のときに読む。** 走っている最中に代入しても窓の大きさは変わらない。
    ///
    /// 全画面 (``fullScreenDisplay``) では読まない。
    public var windowScale: Float

    /// 全画面で出すディスプレイの番号 (``Display/number``)。**`nil` なら窓で開く** (既定)。
    ///
    /// 書き方と、全画面のときに何が変わるかは ``fullScreen(_:)`` にある。**起動のときに読む。**
    public var fullScreenDisplay: Int?

    public init(
        width: Int = 960, height: Int = 540, frameRate: Int = 60, title: String = "mokume",
        pixelDensity: Float = 1, upscale: Upscale = .spatial, windowScale: Float = 0.5,
        clock: ClockMode = .wallClock
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.clock = clock
        self.title = title
        self.pixelDensity = pixelDensity
        self.upscale = upscale
        self.windowScale = windowScale
        self.fullScreenDisplay = nil
    }

    /// 全画面で出す。番号でディスプレイを選び、省けばメニューバーのある画面 (1) に出す。
    ///
    /// 手本 (Processing) の `fullScreen()` / `fullScreen(display)` に当たる。展示でプロジェクタを
    /// 2 枚目のディスプレイとして繋いだら、1 行でそちらへ全画面で出せる:
    ///
    /// ```swift
    /// var settings: SketchSettings { .fullScreen(2) }
    /// ```
    ///
    /// 番号は ``Display`` の「番号の振り方」のとおり、1 がメニューバーのある画面で、2 から先は
    /// システム設定 › ディスプレイ の配置の左から振る。
    ///
    /// ## 描く大きさは、そのディスプレイが決める
    ///
    /// 全画面のときは ``width`` / ``height`` / ``windowScale`` を読まず、そのディスプレイで全画面に
    /// したときの画素 (``Display/width`` × ``Display/height``) で描く。描いた 1 画素が画面の 1 画素に
    /// 載るので、Retina の画面では点の 2 倍になる。スケッチの中の ``SketchPart/width`` /
    /// ``SketchPart/height`` はその大きさを返す。描く側のフレームはこれまでと同じで、変わるのは大きさ
    /// だけである。
    ///
    /// 画素が多くて重ければ、描く細かさ (``pixelDensity``) を下げて拡大させる。他の設定は
    /// 返った値に代入して変える:
    ///
    /// ```swift
    /// var settings: SketchSettings {
    ///     var settings = SketchSettings.fullScreen(2)
    ///     settings.frameRate = 30
    ///     settings.pixelDensity = 0.5
    ///     return settings
    /// }
    /// ```
    ///
    /// ## 選んだディスプレイが無いとき
    ///
    /// **起動の組み立てで断り、別の画面へは出さない** — 番号が 1 を割れば
    /// ``RenderFailure/invalidDisplay(_:)``、繋がっていなければ
    /// ``RenderFailure/displayNotConnected(_:connected:)`` (いま繋がっている一覧を添える)。
    /// 繋がっていなければ窓で開く、とするなら ``SketchPart/displays`` を読んで選ぶ。手元では窓で書き、
    /// 会場でプロジェクタを繋いだら全画面になる:
    ///
    /// ```swift
    /// var settings: SketchSettings {
    ///     displays.count >= 2 ? .fullScreen(2) : SketchSettings(width: 1280, height: 720)
    /// }
    /// ```
    ///
    /// ## 画面ごとに 1 本ずつ起こす
    ///
    /// 同じ作品を画面の数だけ起こし、それぞれ別の画面に出すなら、出す番号を起こすときの引数で
    /// 渡す (`Wall 2`・`Wall 3`、束ねた `.app` なら `open -n Wall.app --args 3`):
    ///
    /// ```swift
    /// var settings: SketchSettings {
    ///     .fullScreen(CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? 2)
    /// }
    /// ```
    ///
    /// **全画面の窓は位置を覚えない。** 置き場所は番号が決めるので、何本起こしても覚えた位置を
    /// 取り合わない (窓で開くときは、閉じたときの位置を覚えて次に戻す)。番号は配置から振るので
    /// 繋ぐ順には左右されないが、**間の 1 台が欠けると後ろの番号が詰まる** — 欠けた 1 台に出す
    /// はずの作品が隣の画面へ出ないよう、`displays.count` が揃っているかを確かめてから選ぶ。
    ///
    /// ## 窓と全画面
    ///
    /// 全画面は macOS の全画面 (窓の緑のボタンと同じもの) で、窓はそのディスプレイの操作スペースを
    /// 1 つ占める。システム設定の「ディスプレイごとに個別の操作スペース」を切っていると、他の
    /// ディスプレイは空になる。抜けるには、画面の上端へポインタを寄せて出る緑のボタンを押す。
    /// 抜けた窓はそのディスプレイに残り、スケッチは走り続ける。
    ///
    /// **矢印のカーソルは、全画面でも作品の上に出る。** 展示で人が触らないなら、`setup()` で
    /// ``SketchPart/noCursor()`` を呼ぶと、作品の面の上にあるあいだ隠れる。
    ///
    /// - **走っている間にディスプレイが外れたら**、窓は macOS が残りの画面へ移す。描く大きさは
    ///   起動のときのままで、絵は窓に収まるように縮めて出る。挿し直したときに元の画面へ戻す
    ///   手当ては、mokume からはしない
    /// - **`mokume watch` では、作品の窓は道具が持つ。** 描く大きさはディスプレイから決まるが、
    ///   全画面にはしない。道具の作品の窓を手で全画面にすれば、保存しても外れない
    ///   (そのことを起動のときに 1 行言う)
    /// - **`mokume render` では窓を開かない。** 書き出す絵の大きさは、そのディスプレイで全画面に
    ///   したときの大きさになる
    /// - 複数のディスプレイにまたがる 1 枚の絵 (手本の `SPAN`) と、重なりのぼかしは持たない。
    ///   プロジェクションマッピングの道具へ渡す仕事である
    public static func fullScreen(_ display: Int = 1) -> SketchSettings {
        var settings = SketchSettings()
        settings.fullScreenDisplay = display
        return settings
    }
}

// MARK: - いま描いている対象

/// いま走っているランタイム。
///
/// [ADR-0010] 決定 2 のとおり、**隠された裏口ではなく明示的に main actor 隔離された
/// グローバル**として置く。隔離されている以上、可変であることは問題にならない。
/// 直接呼べる描画関数 (``SketchPart/circle(_:_:_:)`` など) はここを見る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
@MainActor
var runningSketch: SketchRuntime?

/// 走っているランタイムの面を、その中で起こされた `Task` へ持ち越すもの。
///
/// ``runningSketch`` は `setup()` / `draw()` が返った時点で外れる。そこで起こした
/// `Task` の中身が走るのはその後なので、中から ``SketchPart/canvas`` を取ると何も差さって
/// いない。待つ読み込みの口 (``SketchPart/requestImage(_:)``・``SketchPart/requestModel(_:normalize:)``)
/// は `async` で `Task` からしか呼べないので、**呼べる場所が 1 つも無かった**
/// ([#1367](https://github.com/mokume-metal/mokume/issues/1367))。`Task { … }` は起こした
/// 文脈のタスクローカル値を受け継ぐので、ここに束ねた面はそのまま中へ届く
/// (`Task.detached` は受け継がない)。
///
/// **読むのは待つ読み込みの口だけ** (``Sketch/loadingCanvas(_:_:)``)。描く口は
/// ``runningSketch`` だけを見続ける — `Task` から描けると、描く順が `Task` に番が回る時機で
/// 決まり、描画順を main actor の上で直列に確定させている性質 ([ADR-0010] の影響欄) が崩れる。
/// 待つ読み込みの口は絵を描かず、値を作って返すだけなので、この性質に触れない。
///
/// **持ち越すのは実行ではなく面で、強く持つ。** 弱く持つと、実行が畳まれた後に届いたときに
/// 返せる面が無く、止めるか投げるかしかなくなる。面が生きるのはその `Task` が走っている
/// 間だけで、実行そのもの (観測・入力・名乗り) は `Task` に生かされない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
enum LaunchingSketch {
    @TaskLocal static var canvas: Canvas?
}

extension SketchPart {
    /// いま描いている面。
    ///
    /// **走っている実行の外 (初期化子の中・後片付けの後・`Task` の中) で取ると止まる。** 返せる
    /// 面が無く、プロパティなので投げることもできないためである。資源を作る口
    /// (``createGraphics(_:_:)`` など) は同じ場所から呼んでも止まらず、型のついたエラー
    /// (``RenderFailure/notRunning(call:)`` など) を投げる。描く・読むときは語彙
    /// (``circle(_:_:_:)``・``width`` など) を通せば、外からでも落ちない。
    public var canvas: Canvas {
        // **止める口はここ 1 つだけに置く** (#2683 の反証 B3)。止める取り方を別の口にしておくと、
        // 新しい資源の口がそれを呼べてしまい、投げるべき所でまた落ちる。資源の口は
        // ``resourceCanvas(_:_:)`` / ``loadingCanvas(_:_:)`` を通って投げる
        guard let runtime = runningSketch else { fatalError(OutsideRun.canvasStopNotice) }
        return runtime.canvas
    }

    /// 出す幅 (画素)。**細かさ (``SketchSettings/pixelDensity``) を変えても動かない。**
    ///
    /// 走る前 (部品の `init()` の中など) に読むと 0 を返し、1 度だけ警告する。面の大きさで
    /// 決まる値は ``Sketch/setup()`` の中で決める。
    public var width: Float { Self.liveCanvas(.read(returning: "0"))?.width ?? 0 }
    /// 出す高さ (画素)。**細かさを変えても動かない。**
    public var height: Float { Self.liveCanvas(.read(returning: "0"))?.height ?? 0 }

    /// 実際に刻んでいる幅 (画素)。細かさが 1 なら ``width`` と同じ。
    ///
    /// ``pixels`` の索引はこちらの数である。断片 (塗りと効果) が受け取る位置と大きさは
    /// こちらではなく、座標と同じ出す画素 (``width``) で届く。
    public var pixelWidth: Int { Self.liveCanvas(.read(returning: "0"))?.pixelWidth ?? 0 }
    /// 実際に刻んでいる高さ (画素)。
    public var pixelHeight: Int { Self.liveCanvas(.read(returning: "0"))?.pixelHeight ?? 0 }

    /// いまの絵が、前のフレームの結果に依っているか。
    ///
    /// **決定論に依る仕組みはここを読む** ([ADR-0015] の影響欄) — 同じ入力から
    /// 同じ絵が出ることを前提にした画像比較や、単一フレームだけを描く経路は、
    /// これが `true` の間はその前提を持てない。
    ///
    /// `true` になるのは ``SketchSettings/upscale`` に ``Upscale/temporal`` を
    /// 選び、かつ実際に拡大が立っているときだけである。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    public var usesFrameHistory: Bool { Self.liveCanvas(.read(returning: "false"))?.usesFrameHistory ?? false }

    /// これまでに描いたフレームの数。最初の ``Sketch/draw()`` の最中は 1。
    public var frameCount: Int { Self.liveRuntime(.read(returning: "0"))?.frameCount ?? 0 }
    /// いまのフレームの時刻 (秒)。最初のフレームは 0。
    ///
    /// **最初のフレームが 0 なのは時計 (``clock``) によらない。** 窓に出して動かしている間も、
    /// アプリの起動・窓の作成・``Sketch/setup()`` の中で済む計算にかかった時間は乗らない — 数え始める
    /// のは最初のフレームからである。ただし ``Sketch/setup()`` で ``jumpTime(_:)`` した最初のフレームは
    /// 飛び先の秒、時刻を指定した観測が撮る最初のフレームはその秒になる。
    ///
    /// 窓に出して動かしている間は、既定で**実際に流れた時間**で、フレームが何枚落ちても
    /// 復帰した瞬間に追いつく。**揃えたいものはここから導く** ([ADR-0025] 決定 6) —
    /// 実時間の時計で複数の実行を並べたときに合うのはこの値で、``deltaTime`` を足し込んで作った
    /// 状態ではない。
    ///
    /// 窓でもフレームの時計を選べる (``SketchSettings/clock`` を ``SketchSettings/ClockMode/frames``)。
    /// そのときと書き出し (`mokume render`) では `(frameCount − 1) / fps` で、重いフレームでも 1 枚に
    /// 1/fps 秒しか進まない (処理落ち)。
    ///
    /// 作品の側から止める・飛ぶこともできる (``pauseTime()`` / ``jumpTime(_:)``)。
    ///
    /// ```swift
    /// circle(sin(time) * 200 + width / 2, height / 2, 40)
    /// ```
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    public var time: Float { Self.liveRuntime(.read(returning: "0"))?.time ?? 0 }
    /// 前のフレームからの経過 (秒)。
    ///
    /// **フレームの時計** (書き出しと、``SketchSettings/clock`` を ``SketchSettings/ClockMode/frames``
    /// にした窓) では、**常にちょうど 1 / fps 秒**である。重いフレームの後でも変わらない。
    ///
    /// 以下は、窓の既定の**実時間の時計** (``Clock/wallClock``) の話である。
    ///
    /// **最初のフレームは、時計 (``clock``) によらず 1 フレームぶんである。** 窓に出して動かして
    /// いる間は目標の 1 フレームぶん (``SketchSettings/frameRate`` 分の 1 秒) で、アプリの起動や
    /// ``Sketch/setup()`` の中で済む計算にかかった時間は乗らない。ただし ``Sketch/setup()`` で ``pauseTime()`` /
    /// ``jumpTime(_:)`` した最初のフレームと、時刻を指定した観測が撮る最初のフレームは 0 である。
    ///
    /// **最初のフレームの中で使った時間は、2 枚目に乗る** (上限まで・実時間の時計)。``Sketch/setup()`` で
    /// 置いた図形・画素・背景は最初のフレームへ持ち越されてその中で組まれ、最初の ``Sketch/draw()`` の
    /// 重い準備もその中で走るので、ほかのフレームと同じく次の枚の経過になる。
    ///
    /// **止まっていた時間まるごとは渡らない。** ディスプレイのスリープなどでフレームが
    /// 長く途切れたとき、その間の秒数がそのまま 1 枚に乗ると、これで積分している側
    /// (粒・視点) が 1 回で吹き飛ぶ。目標フレーム間隔の 10 倍を上限にしてある
    /// ([#874](https://github.com/mokume-metal/mokume/issues/874))。
    ///
    /// **作者が止めていたところから描く 1 枚は、目標の 1 フレームぶんになる** — ``redraw()``
    /// で描き直した 1 枚と、``loop()`` で戻った最初の 1 枚である (``redraw()`` の
    /// 「描き直しの 1 枚の時刻」)。
    ///
    /// **作者が時刻を止めている間と、飛んだ枚は 0 である** (``pauseTime()`` / ``jumpTime(_:)``)。
    /// どちらの時計でも同じである。
    ///
    /// ## 足し込んだ状態が揃うかは、時計で決まる
    ///
    /// - **フレームの時計では揃う。** 刻みが毎回ちょうど 1 / fps なので、同じ入力をフレームの番号
    ///   つきで流せば、足し込んだ状態 (位置・速さ・残り時間) は何度走らせても同じになる
    /// - **実時間の時計では揃わない。** 刻み方が実行ごとに違い、同じ合計時間でも刻み方が違えば
    ///   結果が変わる。フレーム落ちの起き方が違う 2 つの実行は、足し込んだ状態が合わない — 揃えたい
    ///   ものは ``time`` から導く ([ADR-0025] 決定 6)
    public var deltaTime: Float { Self.liveRuntime(.read(returning: "0"))?.deltaTime ?? 0 }
    /// ``time`` がどこから来ているか。
    ///
    /// 窓に出して動かしている間は、既定で ``Clock/wallClock`` (実際に流れた時間) で、書き出し
    /// (`mokume render`) と、窓を開かずに回す検査では ``Clock/frameIndex(frameRate:)``
    /// (フレームの数え方) である。窓でも ``SketchSettings/clock`` を ``SketchSettings/ClockMode/frames``
    /// にすれば、宣言の fps の ``Clock/frameIndex(frameRate:)`` になる。
    ///
    /// **外の時間で動くものを作る側が読む** — たとえば音声ファイルの再生 (`loadSound(_:)`)
    /// は、書き出しでは鳴らさずに再生位置をフレームの数から決める。書き出すたびに同じ絵に
    /// なるのはこのためである ([ADR-0025] の水準 2)。窓では、フレームの時計でも実際に鳴らす。
    ///
    /// ```swift
    /// background(0)
    /// // 実時間で動いている間だけ時刻を出し、書き出す絵には入れない
    /// if clock == .wallClock { text("\(time)", 20, 40) }
    /// ```
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    public var clock: Clock { Self.liveRuntime(.read(returning: ".wallClock"))?.clock ?? .wallClock }

    // 描画 API が Sketch+*.swift に分かれているので private にはできない。
    // 公開もしない — 利用者が触る面ではない。

    /// 走っている実行。**外から呼ばれたら、口の名前ごとに 1 度だけ警告して `nil` を返す。**
    ///
    /// [ADR-0020] 決定 5 のとおり、走っていない時点 (初期化子の中・後片付けの後・そこで起こした
    /// `Task` の中) から呼ばれた語彙はプロセスを落とさない。描く・状態を書く口 (`use` が
    /// ``OutsideRun/Use/act``) は何もせず、読み取りの口は呼ぶ側が安全な既定 (0・空) を返す。
    /// 以前はここが `fatalError` で、`struct Player: SketchPart` の `init()` で `width` を
    /// 読むだけで窓が開かずに落ちた ([#2265])。
    ///
    /// - Parameters:
    ///   - use: 外から呼ばれたとき、どう倒すか。警告の文面を選ぶ。
    ///   - call: 警告に載せる口の名前。呼ぶ側の `#function` が入る。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#2265]: https://github.com/mokume-metal/mokume/issues/2265
    @MainActor
    static func liveRuntime(_ use: OutsideRun.Use = .act, _ call: String = #function) -> SketchRuntime? {
        guard let runtime = runningSketch else {
            OutsideRun.log.warn(call, use)
            return nil
        }
        return runtime
    }

    /// 走っている実行の面。外から呼ばれたときの扱いは ``liveRuntime(_:_:)`` と同じ。
    @MainActor
    static func liveCanvas(_ use: OutsideRun.Use = .act, _ call: String = #function) -> Canvas? {
        liveRuntime(use, call)?.canvas
    }

    /// 資源を作る口 (``createGraphics(_:_:)`` など) が使う面。**外から呼ばれたら、口ごとに 1 度だけ
    /// 警告して、その口の型の `notRunning(call:)` を投げる。**
    ///
    /// 警告は ``OutsideRun`` の控えへ言い、観測の応答にも載る。投げるだけだと、`try?` で受けた側
    /// (部品の `init()` の `sprite = try? loadImage(…)`) には値が黙って `nil` になる以外に何も残らない。
    ///
    /// 返す値そのもの — 面・画像・形・領域 — を走っている面からしか作れず、既定へ倒せない。
    /// 以前はここが `fatalError` で、投げる口なのに `try?` でも受けられずにプロセスごと落ちた
    /// ([#2683])。資源の生成は型のついたエラーを投げる ([ADR-0020] 決定 5)。
    ///
    /// - Parameters:
    ///   - failure: 投げる型。呼ぶ口の `throws` の型を渡す。
    ///   - call: エラーに載せる口の名前。呼ぶ側の `#function` が入る。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#2683]: https://github.com/mokume-metal/mokume/issues/2683
    @MainActor
    static func resourceCanvas<Failure: NotRunningFailure>(
        _ failure: Failure.Type, _ call: String = #function
    ) throws(Failure) -> Canvas {
        guard let runtime = runningSketch else {
            // 投げるだけでは `try?` で受けた側に何も残らないので、口ごとに 1 度言う
            OutsideRun.log.warn(call, .thrown)
            throw Failure.notRunning(call: call)
        }
        return runtime.canvas
    }

    /// 待つ読み込みの口が使う面。**走っていなくても、走っている実行の中で起こされた
    /// `Task` からなら、その実行の面を返す** (``LaunchingSketch``)。
    ///
    /// 先に見るのは ``runningSketch`` で、これまで動いていた経路は何も変わらない。
    /// 持ち越した面へ倒れるのは、``runningSketch`` が外れた後の `Task` だけである。
    ///
    /// 走っている実行から起こされていない所 (`init`・後片付けの後・`Task.detached`) では、
    /// どの面へ読み込むかが決まらず、返す資源を作れない。そこでは ``resourceCanvas(_:_:)`` と
    /// 同じく、口ごとに 1 度だけ警告して `notRunning(call:)` を投げる。
    ///
    /// - Parameters:
    ///   - failure: 投げる型。呼ぶ口の `throws` の型を渡す。
    ///   - call: エラーに載せる口の名前。呼ぶ側の `#function` が入り、
    ///     ``OutsideRun/waitingLoads`` のどれかである。
    @MainActor
    static func loadingCanvas<Failure: NotRunningFailure>(
        _ failure: Failure.Type, _ call: String = #function
    ) throws(Failure) -> Canvas {
        guard let canvas = runningSketch?.canvas ?? LaunchingSketch.canvas else {
            OutsideRun.log.warn(call, .thrown)
            throw Failure.notRunning(call: call)
        }
        return canvas
    }
}

/// 資源を作る口が投げる失敗の型。走っていないときの場合 (`notRunning(call:)`) を持つ。
///
/// ``SketchPart/resourceCanvas(_:_:)`` が、呼んだ口の `throws` の型のまま投げるための束ね。
/// 各型の場合そのものがこの要件を満たす。公開しない — 利用者が名乗る型ではない。外のモジュール
/// (MokumeCamera の `MovieFailure`) も満たせるよう、パッケージの中にだけ見せる。
package protocol NotRunningFailure: Error {
    static func notRunning(call: String) -> Self
}

extension NotRunningFailure {
    /// 走っている実行へ足して使うものを作る口 (音・通信) の `notRunning(call:)` の文面
    /// (``OutsideRun/notAttachedNotice(_:)``)。外のモジュールの型 (`AudioFailure` など) が `description` に使う
    /// ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。
    package nonisolated static func notAttachedNotice(_ call: String) -> String {
        OutsideRun.notAttachedNotice(call)
    }
}

extension RenderFailure: NotRunningFailure {}
extension ImageFailure: NotRunningFailure {}
extension ShaderFailure: NotRunningFailure {}
extension ModelFailure: NotRunningFailure {}
extension DataFailure: NotRunningFailure {}

// 外のモジュールの資源の口 (MokumeCamera の `createCapture`・`createVideo`) が使う入口。
//
// **呼んだ口の名前を外の口のものにする** (#2683 の反証 2)。公開の ``SketchPart/createImage(_:_:)``
// を素で呼ぶと、`notRunning(call:)` にも警告にも `"createImage(_:_:)"` が入り、利用者が呼んだ口を
// 名乗らない。
extension SketchPart {
    /// 面を取れる所から呼ばれたかを確かめる。取れなければ、`call` の名前で 1 度だけ警告して
    /// `notRunning(call:)` を投げる (``resourceCanvas(_:_:)`` と同じ)。
    ///
    /// ファイルを開くなど、絵を作る前に重い仕事をする口が、その前に呼ぶ。
    package func requireSurface<Failure: NotRunningFailure>(
        _ failure: Failure.Type, calledAs call: String
    ) throws(Failure) {
        _ = try Self.resourceCanvas(failure, call)
    }

    /// ``createImage(_:_:)`` と同じ絵を作る。面を取れないときは `call` の名前で投げる。
    package func createImage(
        _ width: Int, _ height: Int, calledAs call: String
    ) throws(ImageFailure) -> Image {
        try Self.resourceCanvas(ImageFailure.self, call).createImage(width, height)
    }
}
