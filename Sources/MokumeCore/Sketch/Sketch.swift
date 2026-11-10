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
/// 描く・入力を読むといった語彙 (``SketchPart/fill(_:)-(LinearRGBA)``・``SketchPart/circle(_:_:_:)``・
/// ``SketchPart/mouseX`` など) は、スケッチが継ぐ ``SketchPart`` に置いてある。自分で書いた型も
/// `: SketchPart` と宣言すれば、その中から同じ語彙を使える。
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

    /// 外から追加する機能の並び。
    ///
    /// **並びは 1 本で、順序は宣言順** ([ADR-0024] 決定 4)。`Outlet` だけを追加するものも
    /// `Inlet` だけを追加するものも同じ並びに置き、仕分けは仕組みが行う。
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
    ///
    /// **`throws` で書ける。** 読み込みの失敗を `try?` で捨てずに、`try` で書いて投げられる。投げたら、
    /// ``draw()`` を 1 度も呼ばずにスケッチは起動の失敗として止まり、投げた失敗の全文 (何を読めなかったかと、
    /// 次にすること) が標準エラーに出る。ウィンドウで走らせても `mokume render` で書き出しても、同じ文面で止まる。
    ///
    /// <!-- example: 文脈 var cat: Image! -->
    /// ```swift
    /// func setup() throws {
    ///     cat = try loadImage("assets/cat.png")   // 無ければ、起動の失敗として止まる
    /// }
    ///
    /// func draw() {
    ///     image(cat, 0, 0)
    /// }
    /// ```
    ///
    /// 投げる型は問わない (``ImageFailure``・``ShaderFailure`` などをそのまま通せる)。投げない `func setup()` は
    /// これまでどおり書けて、同じように呼ばれる。`async` にはできない。
    func setup() throws

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
    /// **押下と解放の対は保証されない。** バッファする上限を越えたぶんは古いほうから破棄される
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

    /// 離された瞬間に呼ばれる。読める値の保証は ``mousePressed()`` と同じ。
    ///
    /// **ウィンドウが前から退いたとき (⌘Tab・ほかのウィンドウを触る・メニューを開く) も、押していたボタンの数だけ
    /// 呼ばれ、``mouseClicked()`` が続く。** 退いている間に離したボタンはウィンドウへ届かないので、離した扱い
    /// にしないと押されたまま残る ([#2443](https://github.com/mokume-metal/mokume/issues/2443))。
    /// 離していないのに呼ばれる・クリックになるのが代償である。戻ってから本物の解放が届いても、
    /// 2 度は呼ばれない。
    func mouseReleased()

    /// 押して離されたときに、``mouseReleased()`` の**直後に続けて**呼ばれる。
    ///
    /// 押下を伴わない解放 (ウィンドウの外で押して中で離した、など) では呼ばれない。押していたボタンをウィンドウが
    /// 退いて離した扱いにしたときは呼ばれる (``mouseReleased()``)。
    /// 時刻を見ないので、外から送った出来事でもウィンドウでの実操作と同じように起きる。
    func mouseClicked()

    /// 押していない間に動いたとき呼ばれる。押している間は ``mouseDragged()`` (と、続けて ``mouseDragged(deltaX:deltaY:)``) が呼ばれる。
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
    /// する。**``SketchPart/movedX`` をここで読まない** — フレームの頭から加算する合計なので、ここから
    /// 読むと部分累計を何度も加算する形になる ([ADR-0034] 決定 5)。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    func mouseMoved(deltaX: Float, deltaY: Float)

    /// 押したまま動いたとき呼ばれる。押していない間は ``mouseMoved()`` が呼ばれる。
    ///
    /// Processing・p5.js の `mouseDragged()` と同じ引数なしの形で、中で読む
    /// ``SketchPart/mouseX`` / ``SketchPart/mouseY`` は、その出来事まで当てた位置になる。
    /// 動いた量が要るなら ``mouseDragged(deltaX:deltaY:)`` を書く — ここの直後に続けて呼ばれる。
    ///
    /// **``SketchPart/dragX`` / ``SketchPart/dragY`` をここで読んではいけない。** あちらはフレームの頭から
    /// 加算する合計なので、1 フレームに 3 件届くと `a` + `(a+b)` + `(a+b+c)` を加算する形になる
    /// ([ADR-0034] 決定 5 の改訂 (2026-10-28))。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    func mouseDragged()

    /// 押したまま動いたとき、``mouseDragged()`` の**直後に続けて**呼ばれる。**その 1 件で動いた量**を
    /// 受け取る。
    ///
    /// ```swift
    /// var angle: Float = 0
    ///
    /// func mouseDragged(deltaX: Float, deltaY: Float) {
    ///     angle += deltaX * 0.01
    /// }
    /// ```
    ///
    /// 引数なしの ``mouseDragged()`` も書いていれば、1 件ごとに引数なしが先、ここが後に呼ばれる。
    ///
    /// 1 フレームに移動が 3 件届けばここは 3 回呼ばれ、渡る量はそれぞれの 1 件ぶんに
    /// なる。**3 つ足せばフレーム合計 (``SketchPart/dragX``) と一致する** — API から読む量とここへ
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
    ///     size = min(max(size + deltaY, 20), 400)
    /// }
    /// ```
    ///
    /// **量の単位は点で、機器によらず同じ物差しで届く** ([ADR-0034] 決定 8)。トラックパッドは指の動いた点が
    /// そのまま、ふつうのホイールは 1 行を 10 点に換算した量が届くので、ホイール 1 刻みは `10` 前後、
    /// トラックパッドの 1 回のスワイプは数十から数百になる。同じ係数がどの機器でも同じ桁の動きになる。
    /// **指を離した後の慣性の続きも、同じ量として届く** (トラックパッドで勢いよく払うと、離した後も
    /// 減りながら何件か続く)。ウィンドウの外から送る `scrolled` の `dx` / `dy` は、最初から点として扱い、換算しない。
    ///
    /// **Processing・p5.js の形をまねて引数なしの `func mouseWheel()` と書くと、コンパイルは
    /// 通るが一度も呼ばれない** (`mouseDragged()` は引数なしでも呼ばれるが、ここは量が要るので引数なしの形を持たない)。上の形の
    /// `func mouseWheel(deltaX: Float, deltaY: Float)` に書き直す。回した量は Processing・p5.js の `event` から
    /// 読む代わりに、引数で受け取る。
    ///
    /// **``SketchPart/scrollY`` をここで読んではいけない。** あちらはフレームの頭から加算する
    /// 合計なので、1 フレームに 3 件届くと `a` + `(a+b)` + `(a+b+c)` を加算する形に
    /// なる。欲しいのは `a+b+c` である ([ADR-0034] 決定 5)。
    ///
    /// フレームに 1 件しか届かない環境では**間違えた側も正しく動く**ので、ウィンドウを触って
    /// 確かめている限り気付けない。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    func mouseWheel(deltaX: Float, deltaY: Float)

    /// ウィンドウへファイルがドロップされたとき呼ばれる。**ドロップされたファイルの絶対パス**を受け取る (複数まとめて
    /// ドロップすれば 1 回の呼び出しに並ぶ。空にはならない)。
    ///
    /// <!-- example: 文脈 var photo: Image? -->
    /// ```swift
    /// func fileDropped(_ paths: [String]) {
    ///     photo = try? loadImage(paths[0])
    /// }
    ///
    /// func draw() {
    ///     background(20)
    ///     if let photo {
    ///         image(photo, 0, 0, width, height)
    ///     } else {
    ///         fill(200)
    ///         text("写真をここへ落とす", 20, 40)
    ///     }
    /// }
    /// ```
    ///
    /// ドロップされたファイルが画像として読めなければ `photo` は `nil` のままで、案内の文字が出続けるので、
    /// `try?` で受けている (コールバックは投げ返せない所)。
    ///
    /// ドロップした所へ ``SketchPart/mouseX``・``SketchPart/mouseY`` が動く — 呼ばれた中から読める
    /// (Processing の `mousePressed()` の中で `mouseX` を読むのと同じ書き方)。位置は引数にしない。
    /// ``mouseMoved()`` は呼ばれない。渡るのは**パスだけ**で、ファイルの中身は読まない — 読むのは作者で、
    /// ``SketchPart/loadImage(_:)``・``SketchPart/loadTable(_:header:)`` など、パスを取る API にそのまま渡せる。
    /// ファイルの URL だけを受け、ブラウザからドロップした文字列や URL は受けない。
    ///
    /// **シグネチャは `func fileDropped(_ paths: [String])` と書く。** この API は何もしない既定の実装を持つので、
    /// ラベルを違えて `func fileDropped(paths: [String])` と書いても、コンパイルは通るが一度も呼ばれない
    /// (``mouseWheel(deltaX:deltaY:)`` と同じ罠)。p5.js の `drop` は要素のメソッドで、中身を持つ `p5.File` を
    /// 渡すので、名前も渡すものも違う。
    ///
    /// **macOS の自前のウィンドウと、`mokume watch` のウィンドウだけで受ける。** ``SketchView`` に埋め込んだビューは受けない —
    /// ウィンドウはホストのもので、ホスト側のドロップと取り合わない。ホストからの受け方は、要る作例が来たら決める
    /// ([ADR-0041](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md))。
    /// iOS と、セキュリティスコープ付きの URL は、まだ決めていない
    /// ([#2605](https://github.com/mokume-metal/mokume/issues/2605))。
    /// 外から送る線の `{"type": "fileDropped", "paths": ["/tmp/a.png"], "x": 10, "y": 20}` も同じ呼び出しになる。
    ///
    /// **`mokume watch` のウィンドウでは、1 回のドロップが大きすぎると届かない。** ウィンドウが拾ったドロップは、子の標準入力へ
    /// 1 行にして渡る。その 1 行が 1 MiB (1,048,576 バイト・長いパスでおよそ 5000 本以上) を越えると、子へ
    /// 流さずに捨て、`mokume watch` が 1 度だけ `Dropped an input event of N bytes: …` と出力する。分けて
    /// 送ることはしない — 1 回のドロップは 1 回の呼び出しのままである。直に走らせたウィンドウには、この上限は無い。
    ///
    /// ``SketchPart/noLoop()`` で止めている間も呼ばれる。
    func fileDropped(_ paths: [String])

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
    /// API から読める。
    ///
    /// **ウィンドウが前から退いたとき (⌘Tab・ほかのウィンドウを触る・メニューを開く) も、押していたキーの数だけ
    /// 呼ばれる。**
    /// 退いている間に離したキーはウィンドウへ届かないので、離した扱いにしないと押されたまま残る
    /// ([#2443](https://github.com/mokume-metal/mokume/issues/2443))。離していないのに呼ばれるのが
    /// 代償である。呼ばれるのは押されているキーが離されたときだけなので、戻ってから本物の解放が
    /// 届いても 2 度は呼ばれない。修飾キーでは呼ばれない。
    func keyReleased()

    /// **文字を生むキー**が押されたときに呼ばれる。押した瞬間は ``keyPressed()`` の直後に続き、
    /// 押しっぱなしではキーリピートが届くたびに、これだけがまた呼ばれる。
    ///
    /// 矢印・ファンクションキー・Escape・Delete・Tab では呼ばれない (Processing・p5.js と同じ)。
    /// 打たれた文字は ``SketchPart/key`` から読む。
    func keyTyped()
}

extension Sketch {
    public var settings: SketchSettings { SketchSettings() }
    public var plugins: [any Plugin] { [] }
    public func setup() throws {}
    public func draw() {}
    public func mousePressed() {}
    public func mouseReleased() {}
    public func mouseClicked() {}
    public func mouseMoved() {}
    public func mouseMoved(deltaX: Float, deltaY: Float) {}
    public func mouseDragged() {}
    public func mouseDragged(deltaX: Float, deltaY: Float) {}
    public func mouseWheel(deltaX: Float, deltaY: Float) {}
    public func fileDropped(_ paths: [String]) {}
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
    /// 1 秒あたりのフレーム数の目標。**1 以上。** 0 以下は起動の構築で
    /// ``RenderFailure/invalidFrameRate(_:)`` として断り、1 fps へ丸めない。止めたいなら
    /// ``SketchPart/noLoop()`` を呼ぶ。
    ///
    /// **起動のときに読む。** 実行中に代入しても、画面の刻みも ``SketchPart/time`` /
    /// ``SketchPart/deltaTime`` も変わらない。`var settings = SketchSettings(…)` と持てば
    /// `setup()` や `draw()` の中で代入でき、読み返しても代入した値が返るので、変えられたように
    /// 見えてしまう。**そのため、起動のときと違う値になったら、1 度だけ警告を標準エラーへ
    /// 出す** (同じ走りの中では繰り返さない・[#1323](https://github.com/mokume-metal/mokume/issues/1323))。
    ///
    /// Processing / p5 の `frameRate(n)` は実行中に呼べるが、ここには
    /// 実行中に速さを変える API が無い。
    public var frameRate: Int
    /// ウィンドウで走らせるときの時計。既定は ``ClockMode/wallClock`` (実際に流れた時間)。
    ///
    /// ``ClockMode/frames`` にすると、ウィンドウの中でも ``Sketch/draw()`` 1 回がちょうど
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
    /// ## 重いフレームでは、画像を抜かずに遅くなる (処理落ち)
    ///
    /// 1 フレームに 30 ms かかっても、``SketchPart/time`` は 1/60 秒しか進まない。実時間の時計なら
    /// 30 ms 進み、`deltaTime` も約 0.03 になる。処理落ちが起きたことは、観測の重さ
    /// (1/fps を越えたフレームの数と、いちばん重かったフレームの番号) と、ウィンドウの数字の欄に出る。
    ///
    /// - **処理落ちの間、実時間で進むものとずれる。** 音 (``SketchPart/clock`` が実時間でなくても、ウィンドウでは
    ///   実際に鳴らす)・カメラ・外から届く値は実時間で進み、画像だけが遅れる
    /// - **実時間が正であるべきゲーム** (音楽に合わせるリズムゲームなど) は、既定の
    ///   ``ClockMode/wallClock`` のまま、``SketchPart/time`` と ``SketchPart/deltaTime`` で書く
    /// - 重さの元になりやすい `draw()` の中の同期の読み込み (`loadImage` など) は、1 度だけ警告する。
    ///   `setup()` で読むか、`request…` の API を使う
    ///
    /// ## 止める API の意味は、時計によらない
    ///
    /// | API | `draw()` | `frameCount` | `time` | `deltaTime` | 入力 |
    /// | --- | --- | --- | --- | --- | --- |
    /// | 何もしない | 毎フレーム | +1 | 進む | 1/fps | 届く |
    /// | ``SketchPart/pauseTime()`` の間 | 呼ばれる | +1 | 止まる | 0 | 届く |
    /// | ``SketchPart/jumpTime(_:)`` の枚 | 呼ばれる | +1 | 指定の秒へ跳ぶ | 0 | 届く |
    /// | 時刻を指定した観測の 1 枚 | 呼ばれる | +1 | その枚だけ指定の秒 (``Sketch/draw()`` の中では。入力のコールバックは作者の時計の秒) | 0 | 届く |
    /// | ``SketchPart/noLoop()`` の間 | 呼ばれない | 止まる | 止まる | — | コールバックは呼ばれる |
    /// | ``SketchPart/redraw()`` | 1 回 | +1 | 1/fps 進む | 1/fps | 届く |
    /// | 外からの停止 (`watch`・MCP) | 呼ばれない | 止まる | 止まる | 再開した枚は 1/fps | 溜まる |
    ///
    /// ゲームの一時停止は「自分の印 + ``SketchPart/pauseTime()``」で書く。足して進めるもの
    /// (`ball.move(by:)`) は自分の印で止め、``SketchPart/time`` から作る動きは `pauseTime()` で止まる。
    /// 描画は続くので、止めた画面に「PAUSED」を出せる。画面ごと凍らせてよいなら
    /// ``SketchPart/noLoop()`` / ``SketchPart/loop()`` を使う。
    ///
    /// ## ウィンドウの外では読まない
    ///
    /// 書き出し (`mokume render`) は、この設定によらず書き出しの刻みのフレームの時計で回る。ウィンドウを
    /// 開かずに `SketchRuntime` を直に回すときも、既定でフレームの時計である。進行中の時計は
    /// ``SketchPart/clock`` で読める (この設定が ``ClockMode/frames`` のウィンドウでは
    /// ``Clock/frameIndex(frameRate:)``)。**起動のときに読む。** 実行中に代入しても時計は
    /// 変わらない。
    public var clock: ClockMode
    /// ウィンドウの題名。
    public var title: String

    /// 実際に刻む画素の密度。1 が実寸で、0.5 なら縦横とも半分のピクセル密度で描く。
    ///
    /// **重い画像を低いピクセル密度で描いて拡大すれば、フレーム時間に収まらなかった表現が
    /// 動くようになる** ([ADR-0015] 決定 1)。座標は出すピクセル密度のままなので、
    /// スケッチのコードは 1 行も変わらない。
    ///
    /// 線の太さも出すピクセル密度の画素で書き、描く画素ではピクセル密度の分だけ細くなる。0.5 なら
    /// `strokeWeight(1)` の線は描く画素で太さ 0.5 の線として、その太さぶんの濃さで描かれてから
    /// 拡大される (濃さは置く位置で ±25% ほどまで振れうる)。描く画素で 1 画素より細い線は、描く経路 (距離関数の経路・
    /// 三角形の経路・立体) によらずこうなる。それより太い線は、三角形の経路と立体では描く画素の
    /// 格子で丸まる — たとえば 0.5 の `strokeWeight(3)` は描く画素で 1.5 になり、`triangle` や
    /// `shader()` を付けた図形・立体の線では 1 行か 2 行で塗られる (縁を滑らかにするのは距離関数の
    /// 経路だけである)。塗りも同じで、`rect`・`ellipse` などの基本図形を描く画素で 1 画素より細く
    /// 描いた塗りは、面積に比例した濃さで出る (`shader()` や `texture()` を付けた長い形は、置く位置に
    /// よって 1 割ほど揺れる。扇形 (一周でない `arc`。`.chord`・`.open` の弦で結んだ形も) は付けるかによらず保証の外で、`triangle`・`quad`・
    /// `beginShape` は描く画素の格子で丸まる)。
    /// 効果の半径 (``Effect/blur(radius:)`` など)・切り抜きの矩形 (``SketchPart/clip(_:_:_:_:)``)・
    /// シェーダ (塗りと効果) が受け取る位置と大きさも同じく座標の単位で、ピクセル密度によらない。
    /// 違うのは描く画素 1 つより細かい所 (拡大のぼけと、描く画素の格子への丸め) だけである。
    ///
    /// **座標の単位は、ピクセル密度と、書き出しの倍率 (`mokume render --scale`) のどちらにもよらない。**
    /// 倍率 N の書き出しは、座標を変えずに出す画素を縦横 N 倍にする。線の太さ・効果の半径・切り抜き・シェーダが
    /// 受け取る位置と大きさ・字は、座標と同じく倍率を掛けて読まれ、描く画素は「出す大きさ × 倍率 × ピクセル密度」
    /// になる。``SketchPart/width`` / ``SketchPart/height`` は倍率の下でも変わらず、実際に刻む画素
    /// (``SketchPart/pixelWidth``・`pixels`) だけが倍率を掛けた数になる。
    ///
    /// 使えるのは 0 より大きく 1 以下。1 を超える指定 (出すより細かく描く) は
    /// 引き受けないので、構築の時点で断る。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    public var pixelDensity: Float
    /// 描くピクセル密度と出すピクセル密度の間を、どうやって埋めるか。既定は ``Upscale/spatial``。
    ///
    /// ## 時間方向を選ぶと、単一フレームの再現が失われる
    ///
    /// ``Upscale/temporal`` は前のフレームの結果を積み上げて埋めるので、**フレーム N
    /// の画像はそこへ至る経路に依る** — 単独で描いた N と、0 から進めて得た N が
    /// 一致しない。同じ描画結果が出ることを前提にした仕組み (画像の比較・単一フレームだけを
    /// 描く経路) は、``SketchPart/usesFrameHistory`` を読んでそれを知る必要がある。
    /// [ADR-0015] 決定 2 の言う代償がこれである。
    ///
    /// ## いまは動きの情報を持たない
    ///
    /// この土台はまだ「どの画素がどこから来たか」を作っていないので、時間方向の
    /// 拡大には「何も動いていない」と告げている。**止まっている画像ではちらつきが減り、
    /// 動くものは尾を引く。** ピクセル密度そのものは空間方向と大きく変わらない。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    public var upscale: Upscale
    /// ウィンドウを開く大きさ。**出す 1 画素を、ウィンドウの何点にするか**で書く。既定は 0.5 で、960x540 の
    /// スケッチは 480x270 点のウィンドウで開く。
    ///
    /// 320x180 の画素画像を 4 倍に拡大して見せるウィンドウ (1280x720 点):
    ///
    /// ```swift
    /// var settings: SketchSettings { SketchSettings(width: 320, height: 180, windowScale: 4) }
    /// ```
    ///
    /// 1 にすると、Processing の `size(1280, 720)` と同じく 1 画素 = 1 点で開く —
    /// 隣に並べて見比べるウィンドウが同じ大きさになる:
    ///
    /// ```swift
    /// var settings: SketchSettings { SketchSettings(width: 1280, height: 720, windowScale: 1) }
    /// ```
    ///
    /// ## 描くピクセル密度は変わらない
    ///
    /// 決めるのはウィンドウの大きさだけで、描く画素の数は ``width`` と ``height`` のまま変わらない。
    /// ウィンドウが画像より大きければ拡大して、小さければ縮めて出す。開いた後にウィンドウを手で広げても同じで
    /// ある。書き出す画像 (``SketchPart/save(_:)``・録画) にも効かない。
    ///
    /// ## 指定を変えたら、覚えた大きさより指定を取る
    ///
    /// ウィンドウは閉じたときの大きさと位置を覚えていて、次に開くときはそこへ戻す。ただし
    /// **開く大きさの指定 (描く大きさ × この倍率) が前と変わっていれば、覚えた大きさと位置を
    /// 捨てて新しい指定で開く。** 変えていなければ、手で広げた大きさと置いた位置が戻る。
    ///
    /// ## 使える値
    ///
    /// 0 より大きい有限の数。0 以下・無限大・NaN は、構築の時点で
    /// ``RenderFailure/invalidWindowScale(_:)`` として断る。**画面に収まらない大きさは、
    /// 縦横比を保って画面へ収まるまで縮めて開き**、縮めたことを 1 行言う — 同じスケッチでも
    /// 画面が大きければ呼んだとおりに開くので、値そのものは断らない。
    ///
    /// **起動のときに読む。** 実行中に代入してもウィンドウの大きさは変わらない。
    ///
    /// 全画面 (``fullScreenDisplay``) では読まない。
    public var windowScale: Float

    /// 全画面で出すディスプレイの番号 (``Display/number``)。**`nil` ならウィンドウで開く** (既定)。
    ///
    /// 書き方と、全画面のときに何が変わるかは ``fullScreen(_:)`` にある。**起動のときに読む。**
    public var fullScreenDisplay: Int?

    /// 走っている間、別のアプリ (マッパー・録画の道具など) の一覧に名乗り、繋いできたアプリへ絵を渡すか。**既定は `true`。**
    ///
    /// 何も書かなければ、ウィンドウを持って走る作品は別のアプリの一覧に出て、繋がれたらそのアプリが用意した面へ、画面と同じ
    /// 値の絵を毎フレーム渡す。渡している間は、メニューバーの名乗りに相手が出る。作品のコードにも起動の仕方にも何も足さずに、
    /// 制作中の作品も配った `.app` も、そのまま外の画面へ出せるようにするためである。
    ///
    /// 渡したくない作品は `false` にする。`fullScreenDisplay` と同じく、返った設定へ代入して書く:
    ///
    /// ```swift
    /// var settings: SketchSettings {
    ///     var settings = SketchSettings.size(640, 360)
    ///     settings.sharesFrames = false
    ///     return settings
    /// }
    /// ```
    ///
    /// `false` の作品は、どの起こし方 (直に走らせる・`mokume run`・束ねた `.app`・`mokume watch`) でも一覧に出ず、
    /// 繋ぐための名前も登録しない。
    ///
    /// **渡すことを考え直したほうがよい作品**: カメラ・マイク・入力監視の許可で受けるキー・書類やデスクトップなど守られた
    /// 場所から選んだファイルを描く作品。これらは画面収録の許可の外で守られているが、作品が描いた絵は、その許可を持たない
    /// 同じ利用者のアプリにも渡る。
    ///
    /// **起動のときに読む。** 実行中に代入しても変わらない。
    public var sharesFrames: Bool

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
        self.sharesFrames = true
    }

    /// ウィンドウの大きさ (画素) を書いて作る。`SketchSettings(width:height:)` と同じ設定を、型の名前を
    /// 繰り返さずに書ける。
    ///
    /// Processing の `size(width, height)` に当たる。`.fullScreen()` と同じく、
    /// 返り値の型から決まる書き方である:
    ///
    /// ```swift
    /// var settings: SketchSettings { .size(800, 600) }
    /// ```
    ///
    /// 1 秒あたりのフレーム数とウィンドウの題名は、あとに続けて渡せる。省けば ``init(width:height:frameRate:title:pixelDensity:upscale:windowScale:clock:)``
    /// の既定 (60・`"mokume"`) と同じになる:
    ///
    /// ```swift
    /// var settings: SketchSettings { .size(640, 360, frameRate: 30, title: "Waves") }
    /// ```
    ///
    /// 描くピクセル密度 (``pixelDensity``)・ウィンドウの倍率 (``windowScale``)・時計 (``clock``) など、ここに無い設定は
    /// 返った値へ代入して変える (``fullScreen(_:)`` の説明と同じ書き方):
    ///
    /// ```swift
    /// var settings: SketchSettings {
    ///     var settings = SketchSettings.size(320, 180)
    ///     settings.windowScale = 4
    ///     return settings
    /// }
    /// ```
    ///
    /// ウィンドウで開く (全画面にしない)。全画面は ``fullScreen(_:)`` を使う。
    public static func size(_ width: Int, _ height: Int, frameRate: Int = 60, title: String = "mokume") -> SketchSettings {
        SketchSettings(width: width, height: height, frameRate: frameRate, title: title)
    }

    /// 全画面で出す。番号でディスプレイを選び、省けばメニューバーのある画面 (1) に出す。
    ///
    /// Processing の `fullScreen()` / `fullScreen(display)` に当たる。展示でプロジェクタを
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
    /// 画素が多くて重ければ、描くピクセル密度 (``pixelDensity``) を下げて拡大させる。他の設定は
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
    /// **起動の構築で断り、別の画面へは出さない** — 番号が 1 を割れば
    /// ``RenderFailure/invalidDisplay(_:)``、繋がっていなければ
    /// ``RenderFailure/displayNotConnected(_:connected:)`` (いま繋がっている一覧を添える)。
    /// 繋がっていなければウィンドウで開く、とするなら ``SketchPart/displays`` を読んで選ぶ。手元ではウィンドウで書き、
    /// 会場でプロジェクタを繋いだら全画面になる:
    ///
    /// ```swift
    /// var settings: SketchSettings {
    ///     displays.count >= 2 ? .fullScreen(2) : SketchSettings(width: 1280, height: 720)
    /// }
    /// ```
    ///
    /// ## 画面ごとに 1 つずつ起動する
    ///
    /// 同じスケッチを画面の数だけ起動し、それぞれ別の画面に出すなら、出す番号を起動するときの引数で
    /// 渡す (`Wall 2`・`Wall 3`、束ねた `.app` なら `open -n Wall.app --args 3`):
    ///
    /// ```swift
    /// var settings: SketchSettings {
    ///     .fullScreen(CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? 2)
    /// }
    /// ```
    ///
    /// **全画面のウィンドウは位置を覚えない。** 配置は番号が決めるので、何本起動しても覚えた位置を
    /// 取り合わない (ウィンドウで開くときは、閉じたときの位置を覚えて次に戻す)。番号は配置から振るので
    /// 繋ぐ順には左右されないが、**間の 1 台が欠けると後ろの番号が詰まる** — 欠けた 1 台に出す
    /// はずのスケッチが隣の画面へ出ないよう、`displays.count` が揃っているかを確かめてから選ぶ。
    ///
    /// ## ウィンドウと全画面
    ///
    /// 全画面は macOS の全画面 (ウィンドウの緑のボタンと同じもの) で、ウィンドウはそのディスプレイの操作スペースを
    /// 1 つ占める。システム設定の「ディスプレイごとに個別の操作スペース」を切っていると、他の
    /// ディスプレイは空になる。抜けるには、画面の上端へポインタを寄せて出る緑のボタンを押す。
    /// 抜けたウィンドウはそのディスプレイに残り、スケッチは走り続ける。
    ///
    /// **矢印のカーソルは、全画面でもスケッチの上に出る。** 展示で人が触らないなら、`setup()` で
    /// ``SketchPart/noCursor()`` を呼ぶと、スケッチのウィンドウの上にあるあいだ隠れる。
    ///
    /// - **実行中にディスプレイが外れたら**、ウィンドウは macOS が残りの画面へ移す。描く大きさは
    ///   起動のときのままで、画像はウィンドウに収まるように縮めて出る。挿し直したときに元の画面へ戻す
    ///   手当ては、mokume からはしない
    /// - **`mokume watch` では、スケッチのウィンドウは `mokume watch` が持つ。** `mokume watch` が、宣言したディスプレイでスケッチのウィンドウを全画面にする
    ///   (プレビューは手元にウィンドウのまま残る)。**宣言が変わったときだけ当てる** — 保存しても全画面は外れず、
    ///   手で全画面を抜けた後に保存しても戻らない。宣言を別のディスプレイへ変えて保存すると、そちらへ移る。
    ///   `mokume watch` を止めて起動し直せば、また全画面で出る。`mokume watch` がこのバージョンより古いとウィンドウのまま開くので、そのときは
    ///   手で全画面にする (起動のときの 1 行がそう言う)
    /// - **`mokume render` ではウィンドウを開かない。** 書き出す画像の大きさは、そのディスプレイで全画面に
    ///   したときの大きさになる
    /// - **``SketchView`` では読まない。** ウィンドウはホストのものなので、ウィンドウは変えず、描く大きさは
    ///   ``SketchSettings/width``・``SketchSettings/height`` のまま、そのビューが始まるたびに 1 度警告する (待っている理由の警告のように、プロセスで 1 度ではない)
    /// - 複数のディスプレイにまたがる 1 枚の画像 (Processing の `SPAN`) と、重なりのぼかしは持たない。
    ///   プロジェクションマッピングのツールへ渡す仕事である
    public static func fullScreen(_ display: Int = 1) -> SketchSettings {
        var settings = SketchSettings()
        settings.fullScreenDisplay = display
        return settings
    }
}

// MARK: - いま描いている対象

/// いま実行中のランタイム。
///
/// [ADR-0010] 決定 2 のとおり、**隠された裏口ではなく明示的に main actor 隔離された
/// グローバル**として置く。隔離されている以上、可変であることは問題にならない。
///
/// **書くのは ``SketchRuntime/withActiveRuntime(_:)`` だけ、読むのは ``activeRun(for:from:)`` だけ** ([#3846])。
/// 語彙 (``SketchPart/circle(_:_:_:)``・``SketchPart/width`` など) はここを直に見ず、目的を名乗って
/// ``activeRun(for:from:)`` から引く。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [#3846]: https://github.com/mokume-metal/mokume/issues/3846
@MainActor
var runningSketch: SketchRuntime?

/// 実行を引く目的。**目的ごとに引く順が違う** (``activeRun(for:from:)``)。
///
/// 選び方は、外で呼んだときのフォールバックの仕方 (``OutsideRun/Use``) と対になる。読み取りの API は ``read``、何もしない API は
/// ``act``、型付きのエラーを投げる API・代わりの値を作って返す API は ``make``。外す API だけはフォールバックの仕方 (`act`) によらず
/// ``release(_:)`` で、持ち主を先に見る。追加して使うものを作る API は ``attach``、フレームの中かを問う所は ``frame``。
enum RunPurpose {
    /// 読む API (``SketchPart/width``・``SketchPart/frameCount``・入力・時刻)。**フレームの外の規則に乗る** (``activeRun(for:from:)``)。
    case read
    /// 描く・状態を書く API (``SketchPart/circle(_:_:_:)``・``SketchPart/noLoop()``・``SketchPart/save(_:)``・
    /// 観測へ差し出す ``SketchPart/expose(_:_:)-(_,Double)`` など)。差している実行だけを見る。
    ///
    /// **フレームの外からは描かせない。** 外 (ホストのコード・`Task`) から描けると、描く先の時刻が決まらず、描く順が
    /// 外の呼び出しの時機で決まる。描画順を main actor の上で直列に確定させている性質 ([ADR-0010] の影響欄) が崩れる
    /// (``LaunchingSketch``)。
    ///
    /// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
    case act
    /// リソースを作る API (``SketchPart/createGraphics(_:_:)``・``SketchPart/loadImage(_:)``・``SketchPart/createShape(_:)`` など)。
    /// **フレームの外の規則に乗る** (``activeRun(for:from:)``)。
    ///
    /// 待つ読み込みの API は、差している実行の次に `Task` に持ち越した描画先 (``LaunchingSketch/canvas``) を見る
    /// (``SketchPart/loadingCanvas(_:_:)``)。持ち越すのは実行ではなく描画先なので、ここでは返さない。
    case make
    /// 実行中のスケッチへ追加して使うものを作る API (音・通信・シリアル・ゲームパッド・MIDI)。差している実行だけを見る。
    ///
    /// **追加の順序は実行の側が決める。** `Task` からの要求も、実行がフレームの頭で当てる (``AttachRequests``)。描く順と
    /// 同じ理由で、外から足す時機を持ち込まないためである。ホストのコードから足す形は [#2671] で決める。
    ///
    /// [#2671]: https://github.com/mokume-metal/mokume/issues/2671
    case attach
    /// 外す API (``SketchPart/detach(_:)-(Inlet)``・`Inlet` の `stop()`)。そのプラグインを追加した実行 (``SeamHomes``) を
    /// 先に見て、無ければ差している実行を見る。足した実行を持ち主から引くので、`Task` の中からも外せる ([#2840])。
    ///
    /// [#2840]: https://github.com/mokume-metal/mokume/issues/2840
    case release(AnyObject)
    /// フレームの中か、どのフレームか (``DrawLedger``・外の `Inlet` が取り出したフレームの記録)。差している実行だけを見る。
    /// フレームの外で何を返すかは呼び出し側が決める (`MokumeGame` の `Scene.current` は最後に描いた場面を返して警告し、
    /// 外の `Inlet` はフレーム 0 と記録する)。
    case frame
}

/// 実行中のスケッチを、目的ごとの順で引く。**``runningSketch`` を読むのはここだけ** ([#3846])。
///
/// | 目的 | 引く順 |
/// | --- | --- |
/// | ``RunPurpose/read``・``RunPurpose/make`` | 差している実行 → `receiver` が ``Sketch`` の実体なら、それに結ばれた実行 (``SketchHomes``) → 部品・値の型なら、実行中のスケッチが 1 つだけのときそれ (``OutsideRun/solePresented``) |
/// | ``RunPurpose/act``・``RunPurpose/attach``・``RunPurpose/frame`` | 差している実行だけ |
/// | ``RunPurpose/release(_:)`` | プラグインを追加した実行 → 差している実行 |
///
/// **差している実行を先に見る。** フレームの中 (`setup()`・`draw()`・入力のコールバック) では
/// ``SketchRuntime/withActiveRuntime(_:)`` が自分を差すので、どの実行に向けるかは曖昧にならず、ここから先の規則は
/// フレームの外 — ホストのコード (`SketchView` の隣のボタンの処理)・`Task`・走る前 — だけに効く ([#3847])。
///
/// - **``Sketch`` の実体は、自分に結ばれた実行だけを見る。** 止まった実行の実体や、まだ映していない実体は、他の
///   実行を拾わない
/// - **部品 (``SketchPart`` を名乗った値の型) と、`self` を持たない呼び出しは、実行中のスケッチが 1 つだけならそれを
///   使う** (#3847 の案 Y)。走る前 (部品の `init()`)・実行が 1 つも無いとき・2 つ以上のときは `nil` で、いまどおり
///   既定へ倒れる。代償は、実行中のスケッチの数で同じコードの結果が変わること。どの実行に向けるかを明示する API は、複数の
///   同居を opt-in で追加するとき ([#3802]) に、2 つ以上のときの警告の文面とあわせて追加する
///
/// 引けなければ `nil` を返すだけで、外で呼んだときにどうフォールバックするか (0 を返して警告・何もせず警告・型付きのエラー・
/// ``SketchPart/canvas`` の停止) は呼ぶ側 (``SketchPart/liveRuntime(_:_:)``・``SketchPart/resourceCanvas(_:_:)``
/// など) が決める ([ADR-0020] 決定 5)。
///
/// **「実行は同時に 1 つ」の前提に立つ所。** 差している実行が無いとき、``DrawLedger/progress`` は最後に動いた
/// 実行の目盛り (``DrawLedger``) へ倒れる。実行が 1 つなら、それがいまの実行だからである。複数の実行の同居を
/// opt-in で足すとき ([#3802]) は、この倒れ方とあわせて、ここで引く順を決め直す。
///
/// - Parameters:
///   - purpose: 何のために引くか。
///   - receiver: 語彙を呼んだ `self` (語彙のツールが渡す)。**評価するのは、差している実行が無いときだけ。**
///     フレームの中の呼び出しには負担を足さない。
///
/// **呼ぶ所へ展開する** ([#3082])。描画の API は 1 回ごとにここを通るので、関数の境界を越えて実行を返すと、返す値の
/// 保持と解放が 1 対増える。実行は弱い参照 (``SeamHomes`` など) を受けているので、その保持と解放は参照数の遅い道
/// (side table) を通り、`rect` 1 回の費用の大半を占めていた。別のパッケージから release で `rect`・`circle` を 2 万・
/// 10 万個置くと、``SketchPart/liveCanvas(_:_:)`` まで展開したときに 1 個あたり約 117 ns → 約 80 ns になった。
/// 展開する本体はフレームの中の 1 本の読み取りだけで、フレームの外の引き方は ``activeRunOutsideFrame(from:)`` に残す。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [#3082]: https://github.com/mokume-metal/mokume/issues/3082
/// [#3802]: https://github.com/mokume-metal/mokume/issues/3802
/// [#3846]: https://github.com/mokume-metal/mokume/issues/3846
/// [#3847]: https://github.com/mokume-metal/mokume/issues/3847
@MainActor
@inline(__always)
func activeRun(
    for purpose: RunPurpose, from receiver: @autoclosure () -> (any SketchPart)? = nil
) -> SketchRuntime? {
    switch purpose {
    case .act, .attach, .frame:
        return runningSketch
    case .release(let seam):
        return SeamHomes.runtime(of: seam) ?? runningSketch
    case .read, .make:
        if let runtime = runningSketch { return runtime }
        return activeRunOutsideFrame(from: receiver)
    }
}

/// ``activeRun(for:from:)`` のうち、差している実行が無いときの読み取り・リソースの API の引き方。**展開しない** — フレームの
/// 外でしか通らないので、呼ぶ所ごとに複製しても速くならず、コードが増えるだけである ([#3082])。
///
/// [#3082]: https://github.com/mokume-metal/mokume/issues/3082
@MainActor
@inline(never)
private func activeRunOutsideFrame(from receiver: () -> (any SketchPart)?) -> SketchRuntime? {
    if let sketch = receiver() as? any Sketch { return SketchHomes.runtime(of: sketch) }
    return OutsideRun.log.solePresented
}

/// 走っている実行の外から呼ばれた API を、API ごとに 1 度だけ知らせる (``SketchPart/liveRuntime(_:_:)``)。**展開しない** —
/// 呼ぶ所へ展開される ``SketchPart/liveRuntime(_:_:)`` の中で、外でしか通らない枝を 1 本の呼び出しに留める ([#3082])。
///
/// [#3082]: https://github.com/mokume-metal/mokume/issues/3082
@MainActor
@inline(never)
func warnOutsideRun(_ call: String, _ use: OutsideRun.Use) {
    OutsideRun.log.warn(call, use)
}

/// 実行中のランタイムの描画先を、その中で起動された `Task` へ持ち越すもの。
///
/// ``runningSketch`` は `setup()` / `draw()` が返った時点で外れる。そこで起動した
/// `Task` の中身が走るのはその後なので、中から ``SketchPart/canvas`` を取ると何も差さって
/// いない。待つ読み込みの API (``SketchPart/requestImage(_:)``・``SketchPart/requestModel(_:normalize:)``)
/// は `async` で `Task` からしか呼べないので、**呼べる場所が 1 つも無かった**
/// ([#1367](https://github.com/mokume-metal/mokume/issues/1367))。`Task { … }` は起こした
/// 文脈のタスクローカル値を受け継ぐので、ここに束ねた描画先はそのまま中へ届く
/// (`Task.detached` は受け継がない)。
///
/// **読むのは待つ読み込みの API だけ** (``Sketch/loadingCanvas(_:_:)``)。描画の API は
/// ``runningSketch`` だけを見続ける — `Task` から描けると、描く順が `Task` に番が回る時機で
/// 決まり、描画順を main actor の上で直列に確定させている性質 ([ADR-0010] の影響欄) が崩れる。
/// 待つ読み込みの API は描画せず、値を作って返すだけなので、この性質に触れない。
///
/// **持ち越すのは実行ではなく描画先で、強く持つ。** 弱く持つと、実行が畳まれた後に届いたときに
/// 返せる描画先が無く、止めるか投げるかしかなくなる。描画先が生きるのはその `Task` が実行中である
/// 間だけで、実行そのもの (観測・入力・名乗り) は `Task` に生かされない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
enum LaunchingSketch {
    @TaskLocal static var canvas: Canvas?
    /// ファイルを選ばせる要求の待ち (``SketchPart/selectInput(_:)``)。**中で起動された `Task` が、プラグインが外れた
    /// 後もこの待ちへ頼めるようにする** ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。待つ側は
    /// 絵を描かず、頼んで結果を待つだけなので、描く順の性質に触れない。
    @TaskLocal static var selection: SelectionBroker?
    /// `Inlet` を追加する要求の受付 (``SketchPart/requestSound(_:)`` など)。**中で起動された `Task` が、プラグインが外れた
    /// 後も、追加を実行へ要求できるようにする** — 追加は実行がフレームの頭で行い、ここが持ち越すのは要求の受付だけである
    /// (``AttachRequests``)。実行そのものは持ち越さないので、描画の API は `Task` から効かない。
    @TaskLocal static var attachments: AttachRequests?
    /// 実行を記録する型 (``ReplayRecorder``・#3570)。**中で起動された `Task` の読み込み (``SketchPart/requestJSONObject(_:)``
    /// など) が、URL から受け取ったこと (記録は本文を持たない) をその回に名乗れるようにする。** 名乗るだけで、
    /// 実行の状態には触らない。記録していない実行は `nil`。
    @TaskLocal static var replay: ReplayRecorder?
}

extension SketchPart {
    /// いま描いている描画先。
    ///
    /// **実行中のスケッチの外 (初期化子の中・終了処理の後・`Task` の中) で取ると止まる。** 返せる
    /// 描画先が無く、プロパティなので投げることもできないためである。リソースを作る API
    /// (``createGraphics(_:_:)`` など) は同じ場所から呼んでも止まらず、型のついたエラー
    /// (``RenderFailure/notRunning(call:)`` など) を投げる。描く・読むときは語彙
    /// (``circle(_:_:_:)``・``width`` など) を通せば、外からでも落ちない。
    public var canvas: Canvas {
        // **止める口はここ 1 つだけに置く** (#2683 の反証 B3)。止める取り方を別の口にしておくと、
        // 新しい資源の口がそれを呼べてしまい、投げるべき所でまた落ちる。資源の口は
        // ``resourceCanvas(_:_:)`` / ``loadingCanvas(_:_:)`` を通って投げる
        guard let runtime = activeRun(for: .act) else { fatalError(OutsideRun.canvasStopNotice) }
        return runtime.activeCanvas
    }

    /// 出す幅 (座標の単位)。**ピクセル密度 (``SketchSettings/pixelDensity``) も、書き出しの倍率
    /// (`mokume render --scale`) も、変えても動かない。**
    ///
    /// 走る前 (部品の `init()` の中など) に読むと 0 を返し、1 度だけ警告する。描画先の大きさで
    /// 決まる値は ``Sketch/setup()`` の中で決める。
    public var width: Float { liveCanvas(.read(returning: "0"))?.width ?? 0 }
    /// 出す高さ (座標の単位)。**ピクセル密度も書き出しの倍率も、変えても動かない。**
    public var height: Float { liveCanvas(.read(returning: "0"))?.height ?? 0 }

    /// 実際に刻んでいる幅 (画素)。ピクセル密度が 1 で、書き出しの倍率 (`mokume render --scale`) も掛けていなければ
    /// ``width`` と同じ。倍率 2 なら ``width`` の 2 倍。
    ///
    /// ``pixels`` の索引はこちらの数である。シェーダ (塗りと効果) が受け取る位置と大きさは
    /// こちらではなく、座標と同じ出す画素 (``width``) で届く。
    public var pixelWidth: Int { liveCanvas(.read(returning: "0"))?.pixelWidth ?? 0 }
    /// 実際に刻んでいる高さ (画素)。
    public var pixelHeight: Int { liveCanvas(.read(returning: "0"))?.pixelHeight ?? 0 }

    /// いまの画像が、前のフレームの結果に依っているか。
    ///
    /// **決定論に依る仕組みはここを読む** ([ADR-0015] の影響欄) — 同じ入力から
    /// 同じ描画結果が出ることを前提にした画像比較や、単一フレームだけを描く経路は、
    /// これが `true` の間はその前提を持てない。
    ///
    /// `true` になるのは ``SketchSettings/upscale`` に ``Upscale/temporal`` を
    /// 選び、かつ実際に拡大が立っているときだけである。
    ///
    /// ``draw(into:_:)`` のクロージャの中でも、答えは本体の描画先のもの。スケッチの設定で決まる値で、グラフィックスは
    /// 拡大を立てないので、向き先を読むとクロージャの中と外で答えが割れる。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    public var usesFrameHistory: Bool {
        liveRuntime(.read(returning: "false"))?.canvas.usesFrameHistory ?? false
    }

    /// これまでに描いたフレームの数。最初の ``Sketch/draw()`` の最中は 1。
    public var frameCount: Int { liveRuntime(.read(returning: "0"))?.frameCount ?? 0 }
    /// いまのフレームの時刻 (秒)。最初のフレームは 0。
    ///
    /// **最初のフレームが 0 なのは時計 (``clock``) によらない。** ウィンドウに出して動かしている間も、
    /// アプリの起動・ウィンドウの作成・``Sketch/setup()`` の中で済む計算にかかった時間は乗らない — 数え始める
    /// のは最初のフレームからである。ただし ``Sketch/setup()`` で ``jumpTime(_:)`` した最初のフレームは
    /// 飛び先の秒、時刻を指定した観測が撮る最初のフレームはその秒になる。`mokume watch --keep-time` で作り直した
    /// 後の最初のフレームは、前の世代の作者の時計の続きの秒 (止めていれば止めた秒) になり、
    /// ``Sketch/setup()`` の中で読む ``time`` もその秒である (``pauseTime()`` の「書き出しと作り直し」)。
    ///
    /// ウィンドウに出して動かしている間は、既定で**実際に流れた時間**で、フレームが何枚落ちても
    /// 復帰した瞬間に追いつく。**揃えたいものはここから導く** ([ADR-0025] 決定 6) —
    /// 実時間の時計で複数の実行を並べたときに合うのはこの値で、``deltaTime`` を加算して作った
    /// 状態ではない。
    ///
    /// **ウィンドウに出している間の実時間の時計では、その枚が表示される予定の時刻である**
    /// ([#2390](https://github.com/mokume-metal/mokume/issues/2390))。``Sketch/draw()`` が実行された時刻ではない。
    /// main が他の仕事 (イベント・タイマー) で数ミリ秒遅れても、時刻は表示の刻みの間隔のまま進み、
    /// 表示が刻みを飛ばしたときは飛んだ枚数ぶん進んで、表示の時刻と合ったままになる。
    /// 最初の枚が 0 で (`--keep-time` の引き継ぎを除く)、その起点は ``Sketch/setup()`` の後である。
    ///
    /// - **表示の時刻と合うのは、その刻みに間に合った枚だけ** — 描き終えて差し出せた枚である。
    ///   遅れた枚は後の刻みで表示されるが、時刻は予定のままである
    /// - **共有フレーム (`mokume watch` のプレビュー) では、スケッチ側の刻みの予定の時刻である。** 揺れはウィンドウと同じく
    ///   取れるが、`mokume watch` のウィンドウに出る時刻とは 1〜2 刻みずれうる (画像はスケッチ側の刻みで焼き、公開は次の刻みで、
    ///   出すのは `mokume watch` 側の画面の刻みである)
    /// - **現在時刻で進む回がある。** 表示のリフレッシュが止まって予備のタイマーが進めた回と、メニューバーの
    ///   メニューが開いている間にプレビューを動かす回である。どちらの回でも時刻は前の枚より小さくならず、
    ///   予定の時刻が現在時刻より先にある間の切り替わりでは経過が 0 の枚が出うる
    /// - **ウィンドウの数字 (fps・1 枚の ms) と観測の応答の `frameRate`・`frameTimeMs` は、描いた時刻 (コールバックの
    ///   時点) で数える。** 予定の時刻の列で数えると main の遅れが見えなくなるので、時刻の軸とは揃えない
    ///
    /// ウィンドウでもフレームの時計を選べる (``SketchSettings/clock`` を ``SketchSettings/ClockMode/frames``)。
    /// そのときと書き出し (`mokume render`) では `(frameCount − 1) / fps` で、重いフレームでも 1 枚に
    /// 1/fps 秒しか進まない (処理落ち)。止める・飛ぶ (``pauseTime()`` / ``jumpTime(_:)``) と、`--keep-time` で
    /// 引き継いだ秒が乗った実行では、その分の原点のずれがこの式に足される。
    ///
    /// スケッチの側から止める・飛ぶこともできる (``pauseTime()`` / ``jumpTime(_:)``)。
    ///
    /// **長く走らせるほど、`Float` の刻みは粗くなる。** 時計の中は `Double` の秒だが、ここへ渡すときに
    /// `Float` へ落ちるので、約 1.5 日を超えると刻みは約 15.6 ms (60 fps の 1 フレームとほぼ同じ)、
    /// 約 3 日を超えると約 31 ms、約 6 日を超えると約 62.5 ms (実質 16 fps)、約 24 日を超えると約 250 ms
    /// になる。`sin(time * 0.8)` も `noise(time * 0.5)` も、その刻みの段になる ([ADR-0025] 決定 6 の表)。
    /// **周期のある動きは ``phase(period:)`` で書く** — 倍精度の秒から周期の位相を取るので、何日走らせても
    /// 刻みは周期の長さで決まる。周期の無い使い方 (`noise(time)`) は、長い展示なら日に 1 度は
    /// 起動し直す。
    ///
    /// **時刻を指定した観測の枚では、観測の秒を読むのは ``Sketch/draw()`` と、その直前の `Inlet` の供給
    /// (``Inlet/supply()``) の間だけである。** 入力のコールバックが読むのは作者の時計の秒で、
    /// `keyPressed()` の `jumpTime(time + 0.25)` が作者の時計を観測の秒へ飛ばさない。動画の再生位置と
    /// 録った音の起点も、作者の時計の秒で進む。`Inlet` や部品が状態を進めるなら、``authorTime`` を読む。
    ///
    /// ```swift
    /// circle(sin(time) * 200 + width / 2, height / 2, 40)
    /// ```
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    public var time: Float { liveRuntime(.read(returning: "0"))?.time ?? 0 }
    /// 作者の時計の上の、いまのフレームの時刻 (秒)。`Inlet`・部品が、再生位置や起点といった**状態**を
    /// 進めるための秒である。**描く値には ``time`` を使う。**
    ///
    /// **時刻を指定した観測の枚でも作者の時計の値**で、観測でない枚では ``time`` と同じ値である。
    /// ``time`` は、観測の枚の ``Sketch/draw()`` と、その直前の `Inlet` の供給 (``Inlet/supply()``) の間だけ
    /// 観測の指定秒になるので、状態の進みに使うと、観測が済んだ後も指定秒が状態に残る
    /// ([#2357](https://github.com/mokume-metal/mokume/issues/2357))。``jumpTime(_:)`` と ``pauseTime()`` には
    /// ``time`` と同じく従う。
    ///
    /// 動画のような `Inlet` は、状態を ``authorTime`` で進め、映すコマだけを ``time`` で決める。観測で撮った
    /// 1 枚は指定の秒の画像になり、観測の後の枚は作者の時計に沿って続く。最後に値を受け取った時刻のような
    /// 状態も、こちらで積む (``ExternalInput`` と ``ExternalQueue`` は、受け取った時刻をこの秒で積む)。
    /// **描く値に使うと、観測で撮った 1 枚が指定の秒の画像にならない。**
    ///
    /// 実行中でないとき (`init` の中・終わった後) に読むと 0 を返し、1 度だけ警告する (``time`` と同じ)。
    ///
    /// ```swift
    /// final class Playhead: Inlet {
    ///     weak var owner: (any Sketch)?
    ///     private var position: Float = 0
    ///
    ///     func supply() {
    ///         guard let owner else { return }
    ///         position = owner.authorTime  // 状態は作者の時計で進める
    ///         let shown = owner.time       // 映すものは time (観測の枚では観測の秒) から決める
    ///         // …shown のコマを映す
    ///         _ = shown
    ///     }
    /// }
    /// ```
    ///
    /// ADR-0045 決定 9 の 2026-10-18 と 2026-10-20 の改訂が正典である
    /// ([ADR-0045](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0045-game-direction.md))。
    public var authorTime: Float { liveRuntime(.read(returning: "0"))?.authorTime ?? 0 }
    /// 前のフレームからの経過 (**秒**)。
    ///
    /// **p5.js の `deltaTime` はミリ秒で、単位が 1000 倍違う。** p5.js からコピーした係数は 1000 倍して
    /// 使う — `x += 0.2 * deltaTime` (1 ミリ秒に 0.2 画素) は `x += 200 * deltaTime` (1 秒に 200 画素)
    /// と書く。直さずにコピーすると、1000 倍遅くなってほとんど動かない。秒で渡すのは Unity・Godot・LÖVE・
    /// raylib といったゲームエンジンの慣例に揃えたためで、``time`` とも同じ単位である
    /// ([ADR-0020](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md) 決定 1)。
    ///
    /// **フレームの時計** (書き出しと、``SketchSettings/clock`` を ``SketchSettings/ClockMode/frames``
    /// にしたウィンドウ) では、**常にちょうど 1 / fps 秒**である。重いフレームの後でも変わらない。
    ///
    /// 以下は、ウィンドウの既定の**実時間の時計** (``Clock/wallClock``) の話である。
    ///
    /// **ウィンドウに出している間は、経過は表示の刻みの間隔である** ([#2390](https://github.com/mokume-metal/mokume/issues/2390))。
    /// ``Sketch/draw()`` が実行された時刻の差ではなく、その枚が表示される予定の時刻 (``time`` と同じ時刻) の差なので、
    /// main が他の仕事で遅れても揺れない。60 Hz なら、ふだんは 1/60 秒に揃い、表示が刻みを飛ばしたときだけ
    /// 飛んだ枚数ぶん跳ぶ。共有フレーム・現在時刻で進む回・間に合わなかった枚の扱いは ``time`` にある。
    ///
    /// **最初のフレームは、時計 (``clock``) によらず 1 フレームぶんである。** ウィンドウに出して動かして
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
    /// (パーティクル・視点) が 1 回で吹き飛ぶ。目標フレーム間隔の 10 倍を上限にしてある
    /// ([#874](https://github.com/mokume-metal/mokume/issues/874))。
    ///
    /// **作者が止めていたところから描く 1 枚は、目標の 1 フレームぶんになる** — ``redraw()``
    /// で描き直した 1 枚と、``loop()`` で戻った最初の 1 枚である (``redraw()`` の
    /// 「描き直しの 1 枚の時刻」)。
    ///
    /// **作者が時刻を止めている間と、飛んだ枚は 0 である** (``pauseTime()`` / ``jumpTime(_:)``)。
    /// どちらの時計でも同じである。
    ///
    /// ## 加算した状態が揃うかは、時計で決まる
    ///
    /// - **フレームの時計では揃う。** 刻みが毎回ちょうど 1 / fps なので、同じ入力をフレームの番号
    ///   つきで流せば、加算した状態 (位置・速さ・残り時間) は何度走らせても同じになる
    /// - **実時間の時計では揃わない。** 刻み方が実行ごとに違い、同じ合計時間でも刻み方が違えば
    ///   結果が変わる。フレーム落ちの起き方が違う 2 つの実行は、加算した状態が合わない — 揃えたい
    ///   ものは ``time`` から導く ([ADR-0025] 決定 6)
    public var deltaTime: Float { liveRuntime(.read(returning: "0"))?.deltaTime ?? 0 }
    /// ``time`` がどこから来ているか。
    ///
    /// ウィンドウに出して動かしている間は、既定で ``Clock/wallClock`` (実際に流れた時間) で、書き出し
    /// (`mokume render`) と、ウィンドウを開かずに回すテストでは ``Clock/frameIndex(frameRate:)``
    /// (フレームの数え方) である。ウィンドウでも ``SketchSettings/clock`` を ``SketchSettings/ClockMode/frames``
    /// にすれば、宣言の fps の ``Clock/frameIndex(frameRate:)`` になる。
    ///
    /// **外の時間で動くものを作る側が読む** — たとえば音声ファイルの再生 (`loadSound(_:)`)
    /// は、書き出しではデバイスで鳴らさずに再生位置をフレームの数から決める (固定の時計で `.mov` へ書き出すと、
    /// 鳴った音は動画の音声トラックに載る)。書き出すたびに同じ描画結果になるのはこのためである
    /// ([ADR-0025] の水準 2)。ウィンドウでは、フレームの時計でも実際に鳴らす。
    ///
    /// ```swift
    /// background(0)
    /// // 実時間で動いている間だけ時刻を出し、書き出す画像には入れない
    /// if clock == .wallClock { text("\(time)", 20, 40) }
    /// ```
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    public var clock: Clock { liveRuntime(.read(returning: ".wallClock"))?.clock ?? .wallClock }

    // 描画 API が Sketch+*.swift に分かれているので private にはできない。
    // 公開もしない — 利用者が触る面ではない。

    /// 実行中のスケッチ。**外から呼ばれたら、API の名前ごとに 1 度だけ警告して `nil` を返す。**
    ///
    /// [ADR-0020] 決定 5 のとおり、実行中でない時点 (初期化子の中・終了処理の後・そこで起動した
    /// `Task` の中) から呼ばれた語彙はプロセスを落とさない。描く・状態を書く API (`use` が
    /// ``OutsideRun/Use/act``) は何もせず、読み取りの API は呼ぶ側が安全な既定 (0・空) を返す。
    /// 以前はここが `fatalError` で、`struct Player: SketchPart` の `init()` で `width` を
    /// 読むだけでウィンドウが開かずに落ちた ([#2265])。
    ///
    /// **実体のメソッドなのは、呼んだ `self` を渡すため** ([#3847])。フレームの外の読み取りとリソースの API は、`self` が
    /// スケッチの実体ならその実行を、部品なら映している唯一の実行を引く (``activeRun(for:from:)``)。
    ///
    /// - Parameters:
    ///   - use: 外から呼ばれたとき、どうフォールバックするか。警告の文面を選ぶ。
    ///   - call: 警告に載せる API の名前。呼ぶ側の `#function` が入る。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#2265]: https://github.com/mokume-metal/mokume/issues/2265
    /// [#3847]: https://github.com/mokume-metal/mokume/issues/3847
    @MainActor
    @inline(__always)
    func liveRuntime(_ use: OutsideRun.Use = .act, _ call: String = #function) -> SketchRuntime? {
        guard let runtime = activeRun(for: use.purpose, from: self) else {
            warnOutsideRun(call, use)
            return nil
        }
        return runtime
    }

    /// 実行中の描画先。外から呼ばれたときの扱いは ``liveRuntime(_:_:)`` と同じ。
    ///
    /// **呼ぶ所へ展開する** ([#3082])。描画の API は `guard let canvas = liveCanvas() else { return }` の形で 1 回ごとに
    /// ここを通る。展開すると、``activeRun(for:from:)`` が返す実行の保持と解放 (参照数の遅い道) を最適化が外せる。
    ///
    /// [#3082]: https://github.com/mokume-metal/mokume/issues/3082
    @MainActor
    @inline(__always)
    func liveCanvas(_ use: OutsideRun.Use = .act, _ call: String = #function) -> Canvas? {
        liveRuntime(use, call)?.activeCanvas
    }

    /// リソースを作る API (``createGraphics(_:_:)`` など) が使う描画先。**外から呼ばれたら、API ごとに 1 度だけ
    /// 警告して、その API の型の `notRunning(call:)` を投げる。**
    ///
    /// 警告は ``OutsideRun`` の控えへ言い、観測の応答にも載る。投げるだけだと、`try?` で受けた側
    /// (部品の `init()` の `sprite = try? loadImage(…)`) には値が黙って `nil` になる以外に何も残らない。
    ///
    /// 返す値そのもの — 描画先・画像・形・領域 — を実行中の描画先からしか作れず、既定へ倒せない。
    /// 以前はここが `fatalError` で、投げる口なのに `try?` でも受けられずにプロセスごと落ちた
    /// ([#2683])。リソースの生成は型のついたエラーを投げる ([ADR-0020] 決定 5)。
    ///
    /// - Parameters:
    ///   - failure: 投げる型。呼ぶ API の `throws` の型を渡す。
    ///   - call: エラーに載せる API の名前。呼ぶ側の `#function` が入る。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#2683]: https://github.com/mokume-metal/mokume/issues/2683
    @MainActor
    func resourceCanvas<Failure: NotRunningFailure>(
        _ failure: Failure.Type, _ call: String = #function
    ) throws(Failure) -> Canvas {
        guard let runtime = activeRun(for: .make, from: self) else {
            // 投げるだけでは `try?` で受けた側に何も残らないので、口ごとに 1 度言う
            OutsideRun.log.warn(call, .thrown)
            throw Failure.notRunning(call: call)
        }
        return runtime.canvas
    }

    /// 待つ読み込みの API が使う描画先。**実行中でなくても、実行中のスケッチの中で起動された
    /// `Task` からなら、その実行の描画先を返す** (``LaunchingSketch``)。
    ///
    /// 引く順は、差している実行 → 持ち越した描画先 → フレームの外の規則 (``activeRun(for:from:)`` の
    /// ``RunPurpose/make``)。`Task` は、起動した実行の描画先を、映している実行より先に見る。
    ///
    /// どれでも引けない所 (走る前・終了処理の後・映している実行が無いときの `Task.detached`) では、
    /// どの描画先へ読み込むかが決まらず、返すリソースを作れない。そこでは ``resourceCanvas(_:_:)`` と
    /// 同じく、API ごとに 1 度だけ警告して `notRunning(call:)` を投げる。
    ///
    /// - Parameters:
    ///   - failure: 投げる型。呼ぶ API の `throws` の型を渡す。
    ///   - call: エラーに載せる API の名前。呼ぶ側の `#function` が入り、
    ///     ``OutsideRun/waitingLoads`` のどれかである。
    @MainActor
    func loadingCanvas<Failure: NotRunningFailure>(
        _ failure: Failure.Type, _ call: String = #function
    ) throws(Failure) -> Canvas {
        guard
            let canvas = activeRun(for: .frame)?.canvas ?? LaunchingSketch.canvas
                ?? activeRun(for: .make, from: self)?.canvas
        else {
            OutsideRun.log.warn(call, .thrown)
            throw Failure.notRunning(call: call)
        }
        return canvas
    }
}

/// リソースを作る API が投げる失敗の型。実行中でないときの場合 (`notRunning(call:)`) を持つ。
///
/// ``SketchPart/resourceCanvas(_:_:)`` が、呼んだ API の `throws` の型のまま投げるための束ね。
/// 各型の場合そのものがこの要件を満たす。公開しない — 利用者が名乗る型ではない。外のモジュール
/// (MokumeCamera の `MovieFailure`) も満たせるよう、パッケージの中にだけ見せる。
package protocol NotRunningFailure: Error {
    static func notRunning(call: String) -> Self
}

extension NotRunningFailure {
    /// 実行中のスケッチへ追加して使うものを作る API (音・通信) の `notRunning(call:)` の文面
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
    /// 描画先を取れる所から呼ばれたかを確かめる。取れなければ、`call` の名前で 1 度だけ警告して
    /// `notRunning(call:)` を投げる (``resourceCanvas(_:_:)`` と同じ)。
    ///
    /// ファイルを開くなど、画像を作る前に重い仕事をする API が、その前に呼ぶ。
    package func requireSurface<Failure: NotRunningFailure>(
        _ failure: Failure.Type, calledAs call: String
    ) throws(Failure) {
        _ = try resourceCanvas(failure, call)
    }

    /// ``createImage(_:_:)`` と同じ画像を作る。描画先を取れないときは `call` の名前で投げる。
    package func createImage(
        _ width: Int, _ height: Int, calledAs call: String
    ) throws(ImageFailure) -> Image {
        try resourceCanvas(ImageFailure.self, call).createImage(width, height)
    }
}
