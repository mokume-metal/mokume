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
/// **並行性の注釈は 1 つも要らない。** ライブラリ全体が main actor を既定の隔離と
/// しているので、スケッチもそこに乗る ([ADR-0010] 決定 1)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public protocol Sketch: AnyObject {
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
    /// **1 フレームに押して離しても、両方とも呼ばれる。** 状態 (``isMousePressed``) を
    /// 毎フレーム読む形では、押下と解放が同じフレームに収まると押されたことがどこにも
    /// 残らない — 外から送る経路では 1 回の要求がまとめて 1 フレームへ入るので、
    /// これは構造的に起きる ([#723])。
    ///
    /// 読める値 (``mouseX`` / ``mouseY`` / ``isMousePressed`` / ``mouseButton``) は、
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
    func mouseReleased()

    /// 押して離されたときに、``mouseReleased()`` の**直後に続けて**呼ばれる。
    ///
    /// 押下を伴わない解放 (窓の外で押して中で離した、など) では呼ばれない。
    /// 時刻を見ないので、外から送った出来事でも窓での実操作と同じように起きる。
    func mouseClicked()

    /// 押していない間に動いたとき呼ばれる。押している間は ``mouseDragged(deltaX:deltaY:)`` が呼ばれる。
    func mouseMoved()

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
    /// 1 フレームに移動が 3 件届けばここは 3 回呼ばれ、渡る量はそれぞれの 1 件ぶんに
    /// なる。**3 つ足せばフレーム合計 (``dragX``) と一致する** — 面から読む量とここへ
    /// 渡る量は、用途が違うだけで食い違わない ([ADR-0034] 決定 5)。
    ///
    /// ただし ``orbitControl(_:_:_:)`` は `draw()` の中で 1 回呼ぶ形のままにする。
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
    /// **``scrollY`` をここで読んではいけない。** あちらはフレームの頭から足し込む
    /// 合計なので、1 フレームに 3 件届くと `a` + `(a+b)` + `(a+b+c)` を足し込む形に
    /// なる。欲しいのは `a+b+c` である ([ADR-0034] 決定 5)。
    ///
    /// フレームに 1 件しか届かない環境では**間違えた側も正しく動く**ので、窓を触って
    /// 確かめている限り気付けない。
    func mouseWheel(deltaX: Float, deltaY: Float)

    /// キーが押された瞬間に呼ばれる。
    ///
    /// **押しっぱなしでは連射される** (手本 — Processing / p5.js — と同じ)。1 回だけ
    /// 効かせたいなら、押されているキーの集合 (``isKeyDown(_:)``) を自分で見る。
    ///
    /// どのキーが動いたかは ``keyCode`` から読む。文字を打つ用途には ``keyTyped()`` と
    /// ``key`` を使う。
    func keyPressed()

    /// キーが離された瞬間に呼ばれる。
    ///
    /// 離されたキーも ``keyCode`` が指す — **最後に動いたキー**なので、押した側と同じ
    /// 口から読める。
    func keyReleased()

    /// **文字を生むキー**が押されたとき、``keyPressed()`` の直後に続けて呼ばれる。
    ///
    /// 矢印・ファンクションキー・Escape・Delete・Tab では呼ばれない (手本と同じ)。
    /// 打たれた文字は ``key`` から読む。
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
    /// 1 秒あたりのフレーム数の目標。
    ///
    /// **起動のときに読む。** 走っている最中に代入しても、画面の刻みも ``Sketch/time`` /
    /// ``Sketch/deltaTime`` も変わらず、警告も出ない。`var settings = SketchSettings(…)` と
    /// 持てば `draw()` の中で代入でき、読み返しても代入した値が返るので、変えられたように
    /// 見えてしまう。
    ///
    /// 手本 (Processing / p5) の `frameRate(n)` は走っている最中に呼べるが、ここには
    /// 走っている最中に速さを変える口がまだ無い
    /// ([#1323](https://github.com/mokume-metal/mokume/issues/1323))。
    public var frameRate: Int
    /// 窓の題名。
    public var title: String

    /// 実際に刻む画素の密度。1 が実寸で、0.5 なら縦横とも半分の細かさで描く。
    ///
    /// **重い絵を低い細かさで描いて拡大すれば、フレーム時間に収まらなかった表現が
    /// 動くようになる** ([ADR-0015] 決定 1)。座標は出す細かさのままなので、
    /// スケッチのコードは 1 行も変わらない。
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
    /// 描く経路) は、``Sketch/usesFrameHistory`` を読んでそれを知る必要がある。
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

    public init(
        width: Int = 960, height: Int = 540, frameRate: Int = 60, title: String = "mokume",
        pixelDensity: Float = 1, upscale: Upscale = .spatial
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.title = title
        self.pixelDensity = pixelDensity
        self.upscale = upscale
    }
}

// MARK: - いま描いている対象

/// いま走っているランタイム。
///
/// [ADR-0010] 決定 2 のとおり、**隠された裏口ではなく明示的に main actor 隔離された
/// グローバル**として置く。隔離されている以上、可変であることは問題にならない。
/// 直接呼べる描画関数 (``Sketch/circle(_:_:_:)`` など) はここを見る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
@MainActor
var runningSketch: SketchRuntime?

/// 走っているランタイムの面を、その中で起こされた `Task` へ持ち越すもの。
///
/// ``runningSketch`` は `setup()` / `draw()` が返った時点で外れる。そこで起こした
/// `Task` の中身が走るのはその後なので、中から ``Sketch/canvas`` を取ると何も差さって
/// いない。待つ読み込みの口 (``Sketch/requestImage(_:)``・``Sketch/requestModel(_:normalize:)``)
/// は `async` で `Task` からしか呼べないので、**呼べる場所が 1 つも無かった**
/// ([#1367](https://github.com/mokume-metal/mokume/issues/1367))。`Task { … }` は起こした
/// 文脈のタスクローカル値を受け継ぐので、ここに束ねた面はそのまま中へ届く
/// (`Task.detached` は受け継がない)。
///
/// **読むのは待つ読み込みの口だけ** (``Sketch/requireLoadingCanvas(_:)``)。描く口は
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

extension Sketch {
    /// いま描いている面。
    public var canvas: Canvas { Self.requireRuntime().canvas }

    /// 出す幅 (画素)。**細かさ (``SketchSettings/pixelDensity``) を変えても動かない。**
    public var width: Float { canvas.width }
    /// 出す高さ (画素)。**細かさを変えても動かない。**
    public var height: Float { canvas.height }

    /// 実際に刻んでいる幅 (画素)。細かさが 1 なら ``width`` と同じ。
    ///
    /// ``pixels`` の索引と、断片が受け取る位置はこちらの数である。
    public var pixelWidth: Int { canvas.pixelWidth }
    /// 実際に刻んでいる高さ (画素)。
    public var pixelHeight: Int { canvas.pixelHeight }

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
    public var usesFrameHistory: Bool { canvas.usesFrameHistory }

    /// これまでに描いたフレームの数。最初の ``draw()`` の最中は 1。
    public var frameCount: Int { Self.requireRuntime().frameCount }
    /// いまのフレームの時刻 (秒)。最初のフレームは 0。
    ///
    /// 窓に出して動かしている間は**実際に流れた時間**で、フレームが何枚落ちても
    /// 復帰した瞬間に追いつく。**揃えたいものはここから導く** ([ADR-0025] 決定 6) —
    /// 複数の実行を並べたときに合うのはこの値で、``deltaTime`` を足し込んで作った
    /// 状態ではない。
    ///
    /// ```swift
    /// circle(sin(time) * 200 + width / 2, height / 2, 40)
    /// ```
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    public var time: Float { Self.requireRuntime().time }
    /// 前のフレームからの経過 (秒)。
    ///
    /// **止まっていた時間まるごとは渡らない。** ディスプレイのスリープなどでフレームが
    /// 長く途切れたとき、その間の秒数がそのまま 1 枚に乗ると、これで積分している側
    /// (粒・視点) が 1 回で吹き飛ぶ。目標フレーム間隔の 10 倍を上限にしてある
    /// ([#874](https://github.com/mokume-metal/mokume/issues/874))。
    ///
    /// **足し込んだ合計は ``time`` と一致しない。** 揃えたいものをこれで作らない
    /// ([ADR-0025] 決定 6) — 同じ合計時間でも刻み方が違えば結果が変わるので、
    /// フレーム落ちの起き方が違う 2 つの実行は、足し込んだ状態が合わない。
    public var deltaTime: Float { Self.requireRuntime().deltaTime }

    // 描画 API が Sketch+*.swift に分かれているので private にはできない。
    // 公開もしない — 利用者が触る面ではない。
    @MainActor
    static func requireRuntime() -> SketchRuntime {
        guard let runtime = runningSketch else {
            // 走っていないときに描く手立ては無い。返せる値も無いので、ここで止める。
            // 典型は init やプロパティの初期化子から呼んだ場合。
            fatalError(
                "The drawing API only works while the sketch is running. "
                    + "Call it from setup() or draw(), not from init or a property initialiser.")
        }
        return runtime
    }

    /// 待つ読み込みの口が使う面。**走っていなくても、走っている実行の中で起こされた
    /// `Task` からなら、その実行の面を返す** (``LaunchingSketch``)。
    ///
    /// 先に見るのは ``runningSketch`` で、これまで動いていた経路は何も変わらない。
    /// 持ち越した面へ倒れるのは、これまで止まっていた経路だけである。
    ///
    /// - Parameter call: 止めるときの文面に載せる、呼ばれた口の名前。
    @MainActor
    static func requireLoadingCanvas(_ call: String) -> Canvas {
        guard let canvas = runningSketch?.canvas ?? LaunchingSketch.canvas else {
            // 走っている実行から起こされていない (init・プロパティの初期化子・
            // Task.detached)。どの面へ読み込むかが決まらないので、描く口と同じく止める
            fatalError(
                "\(call) only works for a sketch that is running. Call it from setup() or "
                    + "draw(), or from a Task started there — not from init, a property "
                    + "initialiser or Task.detached.")
        }
        return canvas
    }
}
