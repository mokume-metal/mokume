// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 利用者が書く単位。
///
/// ```swift
/// final class MySketch: Sketch {
///     func draw() {
///         background(.display(red: 0.1, green: 0.1, blue: 0.12))
///         fill(.display(red: 1, green: 0.4, blue: 0.2))
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
}

extension Sketch {
    public var settings: SketchSettings { SketchSettings() }
    public var plugins: [any Plugin] { [] }
    public func setup() {}
    public func draw() {}
}

/// スケッチの設定。
public struct SketchSettings: Equatable, Sendable {
    /// 出す幅 (画素)。**スケッチが書く座標もこの幅の中にある。**
    public var width: Int
    /// 出す高さ (画素)。
    public var height: Int
    /// 1 秒あたりのフレーム数の目標。
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
    public var time: Float { Self.requireRuntime().time }
    /// 前のフレームからの経過 (秒)。
    public var deltaTime: Float { Self.requireRuntime().deltaTime }

    @MainActor
    private static func requireRuntime() -> SketchRuntime {
        guard let runtime = runningSketch else {
            // 走っていないときに描く手立ては無い。返せる値も無いので、ここで止める。
            // 典型は init やプロパティの初期化子から呼んだ場合。
            fatalError(
                "描画 API はスケッチが走っている間だけ使えます。"
                    + "init やプロパティの初期化子ではなく setup() / draw() の中で呼んでください。")
        }
        return runtime
    }
}

// MARK: - 利用者が書く塗り

extension Sketch {
    /// 断片を読み込む。
    ///
    /// <!-- example: 文脈 var waves: Shader! -->
    /// ```swift
    /// // waves.metal
    /// // float4 paint(Fragment in, Values values) {
    /// //     float wave = 0.5 + 0.5 * sin(in.place.x * 20 + in.time * values.speed);
    /// //     return float4(values.tint.rgb * wave, 1);
    /// // }
    /// waves = try? loadShader(
    ///     "assets/waves.metal",
    ///     values: ["speed": 2, "tint": .color(.display(red: 1, green: 0.5, blue: 0.2))])
    /// ```
    ///
    /// ## 書くのは「その画素の色」だけ
    ///
    /// 断片が用意するのは `paint` 1 本で、返すのはその画素の色である。下地との
    /// 混ぜ方 (``blendMode(_:)``) は書かなくてよい — 組み込みの塗りとまったく同じ
    /// 合成を通るので、**混ぜ方が断片によって食い違わない。**
    ///
    /// `Fragment` から読めるもの: 面の中の位置 (`position` は画素・`place` は 0…1)・
    /// 読む面の位置 (`uv`)・図形の色 (`color`)・読んだ面の値 (`texel`)・秒数
    /// (`time`)・面の大きさ (`resolution`)。
    ///
    /// ## 渡す値は読み込むときに宣言する
    ///
    /// `values` に書いた名前が、断片から `values.名前` で読める。後から名前を増やすと
    /// 断片ごと組み直しになるので、**名前は読み込むときに決め、値だけを後から変える**
    /// (``Shader/set(_:_:)-(_,ShaderValue)``)。
    ///
    /// 渡せるのは **float 換算で 64 個まで** (色は 4 個ぶん・2 つ組は 2 個ぶん) — 値は列
    /// ごとに 1 区画へ載せるので、上限は動かせない。超えた宣言は読み込みの時点で断られる。
    ///
    /// ## 面も名前で渡せる
    ///
    /// `surfaces` に書いた名前が、断片から `surfaces.名前` で読める。**渡せるのは
    /// 読み込んだ絵と、自分で描いた面の両方**である。
    ///
    /// <!-- example: 文脈 var blended: Shader! -->
    /// ```swift
    /// // blended.metal
    /// // float4 paint(Fragment in, Values values, Surfaces surfaces) {
    /// //     float4 wood = mokume_sample(surfaces.grain, in.uv);
    /// //     float4 dirt = mokume_sample(surfaces.smudge, in.place);
    /// //     return float4(wood.rgb * mix(1.0, dirt.r, values.amount), wood.a);
    /// // }
    /// guard let bark = try? loadImage("assets/bark.png"),
    ///     let smudge = try? createGraphics(256, 256)
    /// else { return }
    /// blended = try? loadShader(
    ///     "assets/blended.metal",
    ///     values: ["amount": 0.7],
    ///     surfaces: ["grain": .image(bark), "smudge": .graphics(smudge)])
    /// ```
    ///
    /// **面を宣言した断片だけ、受け取るものが 1 つ増える。** 宣言していない断片は
    /// `paint(Fragment, Values)` のままで、書き換えなくてよい。
    ///
    /// 渡せるのは **4 枚まで** — 面は名前ごとに口を 1 つ使い、口の数は断片によらず
    /// 決まっている。超えた宣言は読み込みの時点で断られる。値と同じく、**名前は
    /// 読み込むときに決め、面だけを後から差し替える** (``Shader/set(_:_:)-(_,ShaderSurface)``)。
    ///
    /// ## 平面にも立体にも同じ断片が効く
    ///
    /// **書き分けは要らない。** `rect` にも `box` にも同じ断片が同じ規約で効く —
    /// 前置きの配り方も、渡す値も、置き場も同じである。立体では `Fragment` の
    /// `color` に**光と材質を通したあとの色**が入るので、`in.color` をそのまま
    /// 返せば組み込みの塗りと同じ絵になり、そこから変えていける。
    ///
    /// 断片が書けるのは**その画素の色だけ**で、頂点の落とし方は差し替えられない。
    /// まとめ描き (``shape(_:at:)``) は頂点の側の仕組みなので、**断片を使っても
    /// まとまり方は変わらない。**
    ///
    /// ## 保存したら差し替わる
    ///
    /// 在処のある断片は保存を拾って組み直される。**組み立てに失敗しても絵は消えない** —
    /// 前の断片がそのまま残り、失敗の理由は観測の警告に出る。平面と立体の両方が
    /// 組み上がってはじめて差し替わるので、片方だけ古い断片が効くことはない。
    ///
    /// - Throws: 見つからないとき・組み立てられないとき・値や面が多すぎるときに ``ShaderFailure``。
    public func loadShader(
        _ path: String, values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.loadShader(path, values: values, surfaces: surfaces)
    }

    /// 文字列から断片を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// - Throws: 組み立てられないとき・値や面が多すぎるときに ``ShaderFailure``。
    public func makeShader(
        _ body: String, name: String = "shader", values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.makeShader(body, name: name, values: values, surfaces: surfaces)
    }

    /// これから描くものを、この断片で塗る。
    ///
    /// **溜めている図形はその場で区切られる**ので、これより前に置いた図形が
    /// 後から差し替わることはない。
    public func shader(_ shader: Shader) { canvas.shader(shader) }

    /// 組み込みの塗りへ戻す。
    public func resetShader() { canvas.resetShader() }
}

// MARK: - 効果

extension Sketch {
    /// このフレームの絵にかける効果を決める。
    ///
    /// ```swift
    /// func draw() {
    ///     // …描く…
    ///     effects([.blur(radius: 4), .bloom(amount: 0.6), .vignette(amount: 0.5)])
    /// }
    /// ```
    ///
    /// ## 並びがそのまま順番
    ///
    /// 前から順にかかる。**並びは値なので、組み替えても差し替えても同じように効く** —
    /// 効果ごとの呼び出し口 (`blur()` のようなもの) は置いていない。置いた時点で
    /// 「並び」を持てなくなり、後から段を差し込む先が無くなるためである。
    ///
    /// ## フレームを越えない
    ///
    /// ほかの状態と同じで、`draw()` のたびに書き直す。書かなかったフレームには
    /// 何もかからない。
    ///
    /// ## 数の意味
    ///
    /// **`amount` は 0…1 で、0 なら効かない。** 寸法は名前で示す (`radius` は画素)。
    /// 詳しくは ``Effect``。
    ///
    /// ## 画素を読むときとの前後
    ///
    /// 効果はフレームの終わりに立つ段なので、``pixels`` のようにフレームの途中で読む
    /// 画素には**まだ効いていない**。画面・書き出し・観測はいずれも効果を通した同じ
    /// 1 枚を受け取る。
    public func effects(_ effects: [Effect]) { canvas.effects(effects) }

    /// 文字列から効果を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// <!-- example: 文脈 var ripple: EffectShader! -->
    /// ```swift
    /// ripple = try? makeEffect(
    ///     """
    ///     float4 effect(Pixel in, Values values) {
    ///         float wave = sin(in.place.y * 60.0 + in.time * 4.0) * values.depth;
    ///         return mokume_at(in, in.place + float2(wave, 0.0));
    ///     }
    ///     """,
    ///     values: ["depth": 0.01])
    /// ```
    ///
    /// ## 平面・立体の塗りと同じ規約
    ///
    /// 前置きは自動で足されるので、書くのは `float4 effect(Pixel in, Values values)`
    /// 1 本だけ。`in.color` がこの画素、`mokume_at` でほかの場所を読める。渡した値は
    /// `values` から名前で引ける。**組み込みの効果も同じ規約で書いてある。**
    ///
    /// 使うときは ``Effect/custom(_:)`` として並びへ入れる。
    ///
    /// - Throws: 組み立てられないときに ``ShaderFailure``。
    public func makeEffect(
        _ body: String, name: String = "effect", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        try canvas.makeEffect(body, name: name, values: values)
    }

    /// ファイルから効果を読み込む。
    ///
    /// **保存したら差し替わる。** 組み立てに失敗しても絵は止まらない — 前の効果が
    /// そのまま残り、失敗の理由は観測の警告に出る。
    ///
    /// - Throws: 見つからないとき・組み立てられないときに ``ShaderFailure``。
    public func loadEffect(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        try canvas.loadEffect(path, values: values)
    }
}

// MARK: - 描く前の計算

extension Sketch {
    /// 数の並びを用意する。**CPU と GPU で同じものを見る。**
    ///
    /// <!-- example: 文脈 var heat: Numbers! -->
    /// ```swift
    /// heat = try? makeNumbers(count: 4096)
    /// heat.fill(0)
    /// ```
    ///
    /// ## 書くのは CPU から、読むのは 1 本の道から
    ///
    /// 書くのはいつでもよい。種を蒔く向き (CPU → GPU) はフレームの外でも中でも意味が
    /// 変わらないので、`setup()` で蒔いてから `draw()` で回してよい。
    ///
    /// **読むときは ``read(_:)`` を通る。** この型に読む口は無く、そこは必ず計算の
    /// 完了まで待つ。同じメモリを見ているので値は「読めて」しまうが、それが計算の前なのか
    /// 後なのかは呼んだ側に分からず、**絵か音がおかしくなって初めて気付く**形になるため。
    ///
    /// - Throws: 領域を取れないときに ``RenderFailure``。
    public func makeNumbers(count: Int) throws(RenderFailure) -> Numbers {
        try canvas.makeNumbers(count: count)
    }

    /// 文字列から計算を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// <!-- example: 文脈 var step: Computation! -->
    /// ```swift
    /// step = try? makeComputation(
    ///     """
    ///     kernel void step(device float *heat [[buffer(0)]],
    ///                      constant Values &values [[buffer(MOKUME_VALUES)]],
    ///                      uint id [[thread_position_in_grid]])
    ///     {
    ///         heat[id] = 0.5 + 0.5 * sin(float(id) * 0.01 + values.time);
    ///     }
    ///     """,
    ///     name: "step", values: ["time": 0])
    /// ```
    ///
    /// ## 入口の関数は名前と同じ
    ///
    /// `name` がそのまま断片の中の `kernel void <name>(...)` になる。読み込む側
    /// (``loadComputation(_:values:)``) ではファイル名がその名前になる。
    ///
    /// ## 束ねる先は呼ぶときに決まる
    ///
    /// ``compute(_:over:reads:writes:)`` に渡した `reads + writes` の並びが、そのまま
    /// `buffer(0)`, `buffer(1)`, … になる。渡した値は `MOKUME_VALUES` の口に載る
    /// (番号を書き写さずに済むよう名前で配ってある)。値は後から差し替えられる
    /// (``Computation/set(_:_:)``)。
    ///
    /// ## 保存したら差し替わる
    ///
    /// 在処のある断片は保存を拾って組み直される。**組み立てに失敗しても計算は止まらない** —
    /// 前の断片がそのまま残り、失敗の理由は観測の警告に出る。
    ///
    /// - Throws: 組み立てられないときに ``ShaderFailure``。
    public func makeComputation(
        _ body: String, name: String = "computation", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        try canvas.makeComputation(body, name: name, values: values)
    }

    /// ファイルから計算を読み込む。**入口の関数の名前はファイル名**になる。
    ///
    /// - Throws: 見つからないとき・組み立てられないときに ``ShaderFailure``。
    public func loadComputation(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        try canvas.loadComputation(path, values: values)
    }

    /// 描く前に計算させる (1 次元)。
    ///
    /// <!-- example: 文脈 var step: Computation! -->
    /// <!-- example: 文脈 var seed: Numbers! -->
    /// <!-- example: 文脈 var heat: Numbers! -->
    /// ```swift
    /// func draw() {
    ///     compute(step, over: 4096, reads: [seed], writes: [heat])
    ///     // …heat を読む断片で塗る
    /// }
    /// ```
    ///
    /// ## 読むものと書くものを言う
    ///
    /// `reads` と `writes` は**束ねる先であると同時に、依存の宣言**でもある。前に頼んだ
    /// 計算が書いた並びに触れる計算は、その計算が終わってから走る — 触れない計算どうしは
    /// 並行に走る。**順序は宣言から導かれる**ので、待つ仕掛けを自分で書くことはない。
    ///
    /// 束ねる先と宣言を 1 つにしてあるのは、2 つに分けると「束ねたのに宣言し忘れた」
    /// 組み合わせが作れてしまうからである。
    ///
    /// ## 計算と描画の間
    ///
    /// 計算が書いた並びを描画が読むときの同期も仕組みが入れる。**頼まれていない
    /// フレームでは何も待たない**ので、計算を使わないスケッチが遅くなることはない。
    ///
    /// ## 描くところで頼む
    ///
    /// `draw()` の中だけで効く。`setup()` や初期化から頼んだ計算はどのフレームにも
    /// 属さないので、**無視して理由を知らせる**。
    public func compute(
        _ computation: Computation, over count: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        canvas.compute(computation, over: count, reads: reads, writes: writes)
    }

    /// これから描くものが、この並びを読む。
    ///
    /// 断片からは `in.numbers[i]` で引ける。**計算が書いた値をそのまま絵にする道**で、
    /// 渡していない断片が読むと 1 個の 0 が返る (何も束ねない状態は作らない)。
    ///
    /// **溜めている図形はその場で区切られる**ので、これより前に置いた図形が後から
    /// 差し替わることはない。長さは渡した側が知っているので断片へは配らない。
    public func numbers(_ numbers: Numbers) { canvas.numbers(numbers) }

    /// 並びを読まない状態へ戻す。
    public func resetNumbers() { canvas.resetNumbers() }

    /// 描く前に計算させる (2 次元)。
    ///
    /// 断片は `uint2 at [[thread_position_in_grid]]` で位置を受け取る。ほかは 1 次元の
    /// ``compute(_:over:reads:writes:)`` と同じ。
    public func compute(
        _ computation: Computation, over width: Int, by height: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        canvas.compute(computation, over: width, by: height, reads: reads, writes: writes)
    }

    /// 計算が書いた値を読む。**そのフレームの結果が返る。**
    ///
    /// <!-- example: 文脈 var loudness: Computation! -->
    /// <!-- example: 文脈 var wave: Numbers! -->
    /// <!-- example: 文脈 var level: Numbers! -->
    /// ```swift
    /// func draw() {
    ///     compute(loudness, over: 4096, reads: [wave], writes: [level])
    ///     let values = read(level)      // ここで走らせて待つ
    ///     circle(width / 2, height / 2, values[0] * 200)
    /// }
    /// ```
    ///
    /// GPU で集めた値を、音・通信・状態遷移といった CPU 側の仕事へ渡すための道である。
    ///
    /// ## 読むと、そのフレームの続きが止まる
    ///
    /// 頼んだ計算がまだ走っていなければ、**その場で走らせて GPU の完了まで待つ**。
    /// 待っているあいだ、このフレームの続き (残りの図形を置くことも、描き切ることも)
    /// は進まない。毎フレーム読むと CPU と GPU が交互に動く形になり、重なって進めなく
    /// なる — **読むのは要るときだけ・まとめて 1 度**にする。
    ///
    /// 頼んだ計算が残っていなければ待ちは起きない。走らせたものはコマンドの完了まで
    /// 待ってから返っているので、**溜まっていない = 全部終わっている**が成り立つ。
    /// 同じフレームで 2 度読んでも、待つのは 1 度きり。
    ///
    /// ## 溜めている図形には触らない
    ///
    /// 画素の読み戻し (``pixels``) は溜めている図形を描き切るが、こちらは計算だけを
    /// 流す。図形を 1 つも置いていないフレームでも読めるし、読んだあとに置いた図形が
    /// 消えることもない。**別の機能を有効にしたときだけ動く形にしない**ため、同期を
    /// ほかの経路の副作用に相乗りさせていない。
    ///
    /// ## 読んだ後にもう一度頼んでよい
    ///
    /// 読んだ時点で溜め場は空になる。そのあと頼んだ計算は、いつもどおり描く前に流れる。
    /// 同じ計算が 2 度走ることはない。
    public func read(_ numbers: Numbers) -> [Float] { canvas.read(numbers) }
}

// MARK: - 粒

extension Sketch {
    /// 粒を用意する。**同時に持てる数をここで決める。**
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// func setup() {
    ///     dust = try? makeParticles(count: 20000)
    /// }
    /// ```
    ///
    /// ## 枠は環状に回る
    ///
    /// 出した粒は空いている枠へ順に入り、末尾まで行くと先頭へ戻る。**まだ生きている粒を
    /// 上書きしたときは理由を知らせる** — 出す数 (`rate`) × 寿命 (`life`) がここで決めた
    /// 数より多いと起きるので、どれかを変える。
    ///
    /// ## 大きすぎる数
    ///
    /// 置き場を取れない数は**確保の失敗として返る**。途中まで作って止まることはない。
    ///
    /// - Throws: 置き場を取れないときに ``RenderFailure``。
    public func makeParticles(count: Int) throws(RenderFailure) -> Particles {
        try canvas.makeParticles(count: count)
    }

    /// 粒を出す。
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// func draw() {
    ///     emit(dust, from: .point(width / 2, 40), rate: 600, life: 1...2.5)
    ///     force(dust, .gravity(0, 90), .drag(0.4))
    ///     particles(dust)
    /// }
    /// ```
    ///
    /// ## 低いレートでも、長い目で見て頼んだ数が出る
    ///
    /// `rate` は**毎秒**の数で、1 フレームぶんに割ると端数が出る。端数は捨てずに繰り越す
    /// ので、毎秒 1 個未満でもいつかは出る。捨てる作りにすると、**低いレートで 1 個も
    /// 出ない**が起き、しかも 1 枚の絵では見えない。
    ///
    /// ## 出る場所と飛ぶ向きは別
    ///
    /// `from` が出る場所を、`angle` が飛ぶ向き (画面の面内・ラジアン) を決める。形を
    /// 差し替えても向きは変わらない。
    ///
    /// ## 何もかも幅で指定する
    ///
    /// `speed` / `life` / `size` は幅で渡す。1 つに決めたいときは `2...2` のように書く。
    /// `color` を省くと、そのときの塗りで出る。
    ///
    /// 出た粒の値は**種から決まる乱数** (``random()`` と同じ 1 本の流れ) で引くので、
    /// ``randomSeed(_:)`` を決めれば何度走らせても同じ粒が出る。
    public func emit(
        _ particles: Particles, from source: Emitter, rate: Float,
        speed: ClosedRange<Float> = 20...60,
        angle: ClosedRange<Float> = 0...(2 * Float.pi),
        life: ClosedRange<Float> = 1...2,
        size: ClosedRange<Float> = 2...6,
        color: LinearRGBA? = nil
    ) {
        let runtime = Self.requireRuntime()
        canvas.emit(
            particles, from: source, rate: rate, speed: speed, angle: angle, life: life,
            size: size, color: color, using: &runtime.randomness)
    }

    /// 粒に力を効かせる。
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// force(dust, .gravity(0, 90), .swirl(width / 2, height / 2, strength: 40), .drag(0.6))
    /// ```
    ///
    /// **積んだぶんが、次に進めるときにまとめて効く。** ``particles(_:)`` を呼ぶと空に
    /// なるので、毎フレーム書いてよい。1 回に効かせられるのは 8 個までで、超えたぶんは
    /// 理由を添えて捨てる。
    ///
    /// 引く力 (``Force/attract(_:_:_:strength:)``) は強さを負にすると押す力になる。
    /// 読みやすさのために ``Force/repel(_:_:_:strength:)`` も置いてあるが、**計算は
    /// 同じ 1 本**である。
    public func force(_ particles: Particles, _ forces: Force...) {
        canvas.force(particles, forces)
    }

    /// 粒を 1 フレーム進めて描く。
    ///
    /// **呼ばなければ進まない。** 進めるのと描くのを分けていないのは、「進めたのに
    /// 描いていない粒」と「描いたのに進んでいない粒」という 2 つの状態を作らないため。
    ///
    /// ## 寿命が尽きた粒は描かれない
    ///
    /// 描く個数は GPU が数える。生きている粒だけを枠の番号順に詰めて描くので、枠を
    /// 大きく取っても、払うのは生きている粒のぶんだけである。
    ///
    /// ## 進むのは 1 フレームぶん
    ///
    /// 進む量は ``deltaTime`` で決まる。時計をフレーム番号から導く走らせ方 (ヘッドレスの
    /// 書き出し) なら刻みが一定なので、**同じ入力から何度走らせても同じ動き**が出る。
    public func particles(_ particles: Particles) { canvas.particles(particles) }
}

// MARK: - 保持した形

extension Sketch {
    /// 形を組み立てて保持する。**毎フレーム組み立て直さずに済む。**
    ///
    /// <!-- example: 文脈 var leaf: Shape! -->
    /// ```swift
    /// func setup() {
    ///     leaf = createShape {
    ///         noStroke()
    ///         fill(.display(red: 0.4, green: 0.8, blue: 0.35))
    ///         beginShape()
    ///         vertex(0, -20)
    ///         bezierVertex(14, -14, 14, 14, 0, 20)
    ///         bezierVertex(-14, 14, -14, -14, 0, -20)
    ///         endShape(.close)
    ///     }
    /// }
    ///
    /// func draw() {
    ///     for i in 0..<2000 { shape(leaf, Float(i % 50) * 8 + 10, Float(i / 50) * 8 + 10) }
    /// }
    /// ```
    ///
    /// ## 色は形の中に焼き付く
    ///
    /// 中で呼んだ ``fill(_:)`` や ``stroke(_:)`` は、組み立てた時点で頂点の色になる。
    /// **だから塗りや輪郭は形の中で決める** — 置くときに外から ``fill(_:)`` を変えても
    /// 形の色は変わらない。組み立てるコードを読めば何色になるかが分かり、置く側の
    /// コードを読んでも分からない、という形にしてある。
    ///
    /// **焼き付くのは色だけではない。** 組み立ての間に効いていた ``shader(_:)`` と、
    /// そのとき渡していた値・面・数の並びも形が持ち歩く。置く前に ``resetShader()``
    /// しても、別の断片へ切り替えても、形は記録した塗りで出る。
    ///
    /// 置く場所は別で、``translate(_:_:)`` や ``rotate(_:)`` は置くときに効く。
    /// 色は形のもので、場所は置き方のもの、という切り分けである。
    ///
    /// ## 座標は形自身のもの
    ///
    /// 組み立ての間、変換は畳まれている。どこで組み立てても同じ形になり、
    /// ``shape(_:_:_:)`` の与える位置がそのまま形の原点になる。
    ///
    /// ## 組にしても描く回数は増えない
    ///
    /// ``Shape/group(_:)`` と `+` は形を**1 本の頂点の並びへ畳む**。子の一覧を持って
    /// 1 つずつ描く作りではないので、「保持にしたのに速くならない」が起きない。
    public func createShape(_ body: () -> Void) -> Shape { canvas.createShape(body) }

    /// 保持した形を、**置き場所ぶんだけまとめて置く**。
    ///
    /// 同じ形をたくさん置くときは、これがいちばん速い。形の頂点は 1 度しか置かれず、
    /// 置き場所の数だけ描き足される — 1 万個置いても**描く回数は 1 回**になる。
    ///
    /// ```swift
    /// let grain = createShape { box(6) }
    /// var places: [Placement] = []
    /// for _ in 0..<5000 {
    ///     places.append(
    ///         Placement(
    ///             x: random(width), y: random(height),
    ///             rotation: SIMD3(0, random(2 * .pi), 0)))
    /// }
    /// shape(grain, at: places)
    /// ```
    ///
    /// **1 つずつ置いたときと同じ絵になる。** `push()` / `translate()` / `pop()` の
    /// 繰り返しで書いても、まとめて渡しても、経路は 1 本しかない。
    ///
    /// ``Placement/fill`` を渡すと、その置き場所の色に**掛かる** (渡さなければ何も
    /// 掛からない)。
    public func shape(_ shape: Shape, at placements: [Placement]) {
        canvas.shape(shape, at: placements)
    }

    /// 保持した形を置く。
    ///
    /// 色は形が持っているものが使われ、置く場所といまの変換が効く。
    ///
    /// **たくさん置くときは shape(_:at:) を使う。** こちらは 1 回ごとに頂点を
    /// 置き直すので、置く数だけ描く回数が増える。
    public func shape(_ shape: Shape, _ x: Float = 0, _ y: Float = 0) {
        canvas.shape(shape, x, y)
    }
}

// MARK: - 画素

extension Sketch {
    /// 描いた結果を画素として読み書きする面。
    ///
    /// ```swift
    /// for y in 0..<pixelHeight {
    ///     for x in 0..<pixelWidth {
    ///         let color = pixels[x, y]
    ///         pixels[x, y] = LinearRGBA(
    ///             premultipliedRed: color.green, green: color.blue, blue: color.red,
    ///             alpha: color.alpha)
    ///     }
    /// }
    /// ```
    ///
    /// ## 送り直しの手順は無い
    ///
    /// 書き換えは、次に描くときに描画先へ自動で戻される。**呼ぶべき送り直しの口が無い**
    /// ので、「書き換えたのに送り直しを呼び忘れて絵が変わらない」という形の不具合が
    /// 起きない。戻すのは書いたフレームだけで、読むだけのフレームは戻さない。
    ///
    /// ## 読む値と書く値は同じ表現
    ///
    /// どちらも ``LinearRGBA`` — 線形・アルファ乗算済みの作業空間の値である。
    /// 変換が挟まらないので `pixels[x, y] = pixels[x, y]` は絵を変えない。
    /// 半透明の画素でも同じで、読んで書き戻すだけで色が沈むことはない。
    ///
    /// ## いつの絵が読めるか
    ///
    /// **そのフレームでそこまでに描いたもの**が読める。初めて触れた時点で溜めていた
    /// 図形が描き切られ、GPU の完了を待つ。待つのはフレームに 1 度きりなので、
    /// 何画素読んでも待ち時間は増えない。待つ時点を自分で選びたいときは
    /// ``loadPixels()`` を先に呼ぶ。
    ///
    /// **取ったフレームの中で使い切る。** 返るのは描画先の写しへの窓で、写しは次に
    /// 画素を読むときに描き直される。プロパティに取っておいて次のフレームで読むと
    /// 古い絵が読め、書くと GPU が写しを書いている途中に触ることになる。次のフレーム
    /// では `pixels` をもう一度取る。
    ///
    /// ## 索引は実際に刻んでいる画素
    ///
    /// 大きさは ``pixelWidth`` / ``pixelHeight`` で、細かさ
    /// (``SketchSettings/pixelDensity``) を下げているときは ``width`` / ``height``
    /// より小さい。**読み書きするのは拡大より手前の絵**なので、ここで書いた値も
    /// 拡大を通ってから出て行く。
    public var pixels: Pixels { canvas.pixels }

    /// 溜めている図形を描き切り、画素を読める状態にする。
    ///
    /// ``pixels`` も ``get(_:_:)`` も ``set(_:_:_:)`` も必要なら自分で呼ぶので、
    /// **省いても結果は変わらない**。待つ時点を選びたいときに使う。
    ///
    /// > Note: この口には例の絵が付いていない。**呼んでも絵が 1 画素も変わらない**ので、
    /// > 付けても呼ばなかった絵と見分けが付かないためである。
    public func loadPixels() { canvas.loadPixels() }

    /// 1 画素の色。原点は左上。範囲の外は透明を返す。索引は ``pixels`` と同じ。
    ///
    /// **そのフレームでそこまでに描いたもの**が読める。下の例は先に描いた円の中から
    /// 色を 1 つ読み、その色で別の図形を塗っている — 2 つは同じ色で出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(110, 100, 140)
    ///     let picked = get(110, 100)   // 円の中の 1 画素
    ///     fill(picked)
    ///     rect(230, 160, 130, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上に橙色の円、右下に同じ橙色で塗られた四角 -->
    ///     ![左上に橙色の円、右下に同じ橙色で塗られた四角](https://i.gyazo.com/7f2cf2912d36c99c25f51ea9671679f9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=286bfc72
    public func get(_ x: Int, _ y: Int) -> LinearRGBA { canvas.get(x, y) }

    /// 1 画素の色を書き換える。範囲の外は何もしない。
    ///
    /// **書いた画素だけが変わる。** 図形を描く口と違って塗りも線も見ないので、
    /// 下の例では書いた範囲の外が下地のまま残る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     for y in 60..<240 {
    ///         for x in 100..<300 {
    ///             if (x + y) % 12 < 6 {
    ///                 set(x, y, .display(red: 0.95, green: 0.85, blue: 0.35))
    ///             }
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色い斜めの縞が、四角い範囲の中にだけ並んでいる -->
    ///     ![黄色い斜めの縞が、四角い範囲の中にだけ並んでいる](https://i.gyazo.com/893d0f3dcc2226810339c4d10df573a1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=95cce64d
    public func set(_ x: Int, _ y: Int, _ color: LinearRGBA) { canvas.set(x, y, color) }
}

// MARK: - 直接呼べる描画

extension Sketch {
    /// 面全体を塗り直す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.10, green: 0.35, blue: 0.55))
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 面全体がくすんだ濃い青 1 色で塗られている | symmetric=xy -->
    ///     ![面全体がくすんだ濃い青 1 色で塗られている](https://i.gyazo.com/e82fe62b30c6016d1d17788c3b022dd4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// それまでに溜めた図形は消える — 全面を塗るのだから、下に隠れるものを
    /// 描く手間をかける意味がない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(200, 150, 260)
    ///     background(.display(red: 0.10, green: 0.35, blue: 0.55))
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     circle(200, 150, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 先に描いた大きな橙色の円は消え、濃い青の下地に黄色い小さな円だけが残っている | symmetric=xy -->
    ///     ![先に描いた大きな橙色の円は消え、濃い青の下地に黄色い小さな円だけが残っている](https://i.gyazo.com/9d79996d003e77b264444ebb7b60c5a5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a9a4b1c1
    // shot: 2 snippet=06a34484
    public func background(_ color: LinearRGBA) { canvas.background(color) }
    /// これから描く図形の塗りの色。**塗りを止めていたら、呼んだ時点で再び塗るようになる。**
    ///
    /// 呼んだ時点より後の図形にだけ効く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(110, 150, 130)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     circle(200, 150, 130)
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     circle(290, 150, 130)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・水色・黄の円が、少しずつ重なりながら左から順に並んでいる | symmetric=y -->
    ///     ![橙・水色・黄の円が、少しずつ重なりながら左から順に並んでいる](https://i.gyazo.com/d9561feaaaf61c716a934b9b9becbe2d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 4 つ目の `alpha` を下げると、下にあるものが透ける。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(150, 150, 200)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95, alpha: 0.6))
    ///     circle(250, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円の上に半透明の水色の円が重なり、重なった部分だけ色が混ざっている | symmetric=y -->
    ///     ![橙色の円の上に半透明の水色の円が重なり、重なった部分だけ色が混ざっている](https://i.gyazo.com/3b22aa622e4e116813827c7506e2a344.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=4553e138
    // shot: 2 snippet=471b5a72
    public func fill(_ color: LinearRGBA) { canvas.fill(color) }
    /// これから引く線の色。**線を止めていたら、呼んだ時点で再び引くようになる。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     strokeWeight(8)
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(110, 150, 130)
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     circle(200, 150, 130)
    ///     stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     circle(290, 150, 130)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・水色・黄の輪郭だけの円が、少しずつ重なりながら左から順に並んでいる | symmetric=y -->
    ///     ![橙・水色・黄の輪郭だけの円が、少しずつ重なりながら左から順に並んでいる](https://i.gyazo.com/d52d48c8a4994693b679569e0715a2d4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 塗りとは別に決まるので、``fill(_:)`` と組み合わせれば中と縁で別の色になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(16)
    ///     circle(200, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色に塗られた円を、太い橙色の輪郭が囲んでいる | symmetric=xy -->
    ///     ![水色に塗られた円を、太い橙色の輪郭が囲んでいる](https://i.gyazo.com/848e15edffad8dc14dbb347850c5d64b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=52e2382e
    // shot: 2 snippet=9fd52b82
    public func stroke(_ color: LinearRGBA) { canvas.stroke(color) }
    /// これから引く線の太さ (画素)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     for index in 0..<5 {
    ///         strokeWeight(Float(index) * 7 + 2)
    ///         line(70, 60 + Float(index) * 45, 330, 60 + Float(index) * 45)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上から下へ、だんだん太くなる 5 本の白い横線 | symmetric=x -->
    ///     ![上から下へ、だんだん太くなる 5 本の白い横線](https://i.gyazo.com/54213d17507b422557afb9541f29ce0a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 図形の輪郭にも効く。太さは縁を中心に内と外へ半分ずつ広がるので、太くすると
    /// 図形は一回り大きく見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(2)
    ///     square(60, 100, 100)
    ///     strokeWeight(30)
    ///     square(240, 100, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの正方形が 2 つ並び、左は細い橙色の輪郭、右は太い橙色の輪郭で描かれている | symmetric=y -->
    ///     ![同じ大きさの正方形が 2 つ並び、左は細い橙色の輪郭、右は太い橙色の輪郭で描かれている](https://i.gyazo.com/8e17f246f704030ea38dca747306e122.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=7aee288f
    // shot: 2 snippet=c3229bad
    public func strokeWeight(_ weight: Float) { canvas.strokeWeight(weight) }

    /// 図形の内側を塗らない。輪郭だけの図形になる。
    ///
    /// ``fill(_:)`` を呼ぶと、その時点でまた塗るようになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     strokeWeight(8)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(110, 150, 150)
    ///     noFill()
    ///     circle(290, 150, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左は中が橙色に塗られた円、右は同じ大きさで白い輪郭だけの円 | symmetric=y -->
    ///     ![左は中が橙色に塗られた円、右は同じ大きさで白い輪郭だけの円](https://i.gyazo.com/c1c94cc4ba3fb68f29dad4b295a95eba.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=848590b4
    public func noFill() { canvas.noFill() }

    /// 線を引かない。図形の輪郭も出なくなる。
    ///
    /// ``stroke(_:)`` を呼ぶと、その時点でまた引くようになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     strokeWeight(8)
    ///     circle(110, 150, 150)
    ///     noStroke()
    ///     circle(290, 150, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左は白い輪郭のある橙色の円、右は輪郭の無い同じ橙色の円 | symmetric=y -->
    ///     ![左は白い輪郭のある橙色の円、右は輪郭の無い同じ橙色の円](https://i.gyazo.com/24370476c54c4b0bf6f2e035fd25fa6c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5e1b5cf3
    public func noStroke() { canvas.noStroke() }

    /// 線の端の形。既定は丸。
    ///
    /// 太さ 1 の線では 3 つとも同じに見えるので、**確かめるときは太さを振る**。
    /// 下の 3 枚は同じ線を形だけ変えて引いたもので、細い白い線が**渡した端の位置**を
    /// 示している。
    ///
    /// ``StrokeCap/round`` は端を丸め、渡した位置より半円ぶん外へ出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     strokeWeight(2)
    ///     line(140, 40, 140, 260)
    ///     line(260, 40, 260, 260)
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(60)
    ///     strokeCap(.round)
    ///     line(140, 150, 260, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の線の端が丸く、白い目印の線より外へ半円ぶんはみ出している | symmetric=xy -->
    ///     ![太い橙色の線の端が丸く、白い目印の線より外へ半円ぶんはみ出している](https://i.gyazo.com/b8fff97556114a1c9a4fac48bf3658df.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeCap/square`` は渡した位置ちょうどで切る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     strokeWeight(2)
    ///     line(140, 40, 140, 260)
    ///     line(260, 40, 260, 260)
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(60)
    ///     strokeCap(.square)
    ///     line(140, 150, 260, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の線が、白い目印の線のところでまっすぐ切れている | symmetric=xy -->
    ///     ![太い橙色の線が、白い目印の線のところでまっすぐ切れている](https://i.gyazo.com/27e91f36498415fe4c700fb3954854e0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeCap/project`` は四角いまま、太さの半分だけ外へ出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     strokeWeight(2)
    ///     line(140, 40, 140, 260)
    ///     line(260, 40, 260, 260)
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(60)
    ///     strokeCap(.project)
    ///     line(140, 150, 260, 150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の線が、白い目印の線より外へ四角くはみ出している | symmetric=xy -->
    ///     ![太い橙色の線が、白い目印の線より外へ四角くはみ出している](https://i.gyazo.com/84aafb115c492ac744db4e9232630252.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5fd70319
    // shot: 2 snippet=e12f5d6e
    // shot: 3 snippet=9387a57e
    public func strokeCap(_ cap: StrokeCap) { canvas.strokeCap(cap) }

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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     beginShape()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     vertex(200, 40)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     vertex(350, 250)
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     vertex(60, 230)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・水色・黄の 3 色が、1 つの三角形の中でなめらかに混ざっている -->
    ///     ![橙・水色・黄の 3 色が、1 つの三角形の中でなめらかに混ざっている](https://i.gyazo.com/dbe1887aad37bbb36b2dab85b663f608.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=088b2c60
    // shot: 2 snippet=3c826cb4
    // shot: 3 snippet=4f541c98
    // shot: 4 snippet=2d751eab
    // shot: 5 snippet=c8cdea48
    public func beginShape(_ kind: VertexKind = .polygon) { canvas.beginShape(kind) }

    /// 頂点を 1 つ置く。
    ///
    /// **置いた順にそのまま結ばれる。** 周は凹んでいてもよく、へこみはへこみのまま塗られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
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
    // shot: 1 snippet=1242029c
    // shot: 2 snippet=d106bd46
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

    /// 3 次の曲線で、いまの点から `x`・`y` まで繋ぐ。
    ///
    /// **2 つの制御点は通らない** — 曲線を引っぱる位置である。下の例では灰色の丸が
    /// 制御点で、細い線がどちらの端から引っぱっているかを示している。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(60, 250, 100, 40)
    ///     line(340, 220, 200, 90)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(100, 40, 12)
    ///     circle(200, 90, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     vertex(60, 250)
    ///     bezierVertex(100, 40, 200, 90, 340, 220)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が左下から右下へ弧を描き、灰色の細い線が 2 つの制御点へ伸びている -->
    ///     ![橙色の曲線が左下から右下へ弧を描き、灰色の細い線が 2 つの制御点へ伸びている](https://i.gyazo.com/fe7006ac47c62f7b51f16f8bbbf46f09.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **繋げて呼べば、閉じた形も作れる。** 前の区間の終点が次の区間の始点になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     beginShape()
    ///     vertex(180, 50)
    ///     bezierVertex(340, 70, 320, 230, 210, 260)
    ///     bezierVertex(90, 230, 60, 110, 180, 50)
    ///     endShape(.close)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の、木の葉のようにふくらんだ閉じた形 -->
    ///     ![水色の、木の葉のようにふくらんだ閉じた形](https://i.gyazo.com/2f70a2339d3ed646904439376d90e4ea.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 手前に点が無いときは何もしない — 曲線は「いまの点から」繋ぐものなので、
    /// 始点が無ければ引きようがない。
    // shot: 1 snippet=d80d93dd
    // shot: 2 snippet=3f38b979
    public func bezierVertex(
        _ cx1: Float, _ cy1: Float, _ cx2: Float, _ cy2: Float, _ x: Float, _ y: Float
    ) {
        canvas.bezierVertex(cx1, cy1, cx2, cy2, x, y)
    }

    /// 2 次の曲線で、いまの点から `x`・`y` まで繋ぐ。
    ///
    /// **制御点は 1 つ。** ``bezierVertex(_:_:_:_:_:_:)`` より書くことが少ない代わりに、
    /// 両端で別々の曲がり方を与えることはできない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(60, 250, 260, 40)
    ///     line(340, 210, 260, 40)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(260, 40, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     vertex(60, 250)
    ///     quadraticVertex(260, 40, 340, 210)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色の曲線が 1 つの制御点へ引き寄せられ、灰色の細い線が両端からその点へ伸びている -->
    ///     ![黄色の曲線が 1 つの制御点へ引き寄せられ、灰色の細い線が両端からその点へ伸びている](https://i.gyazo.com/55ebcbd9b72c0a21cb03b0b925e82bd3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=1b8fea51
    public func quadraticVertex(_ cx: Float, _ cy: Float, _ x: Float, _ y: Float) {
        canvas.quadraticVertex(cx, cy, x, y)
    }

    /// 通過点を結ぶ曲線の制御点を置く。
    ///
    /// **4 つ揃って初めて 1 区間が引ける。** 最初と最後の点は曲がり方を決めるためだけに
    /// 使われ、その間だけが描かれる。下の 4 点 (灰色の丸) で引かれるのは、真ん中の
    /// 2 点を結ぶ 1 区間だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の点が 4 つ散らばり、橙色の曲線は真ん中の 2 点の間にだけ引かれている -->
    ///     ![灰色の点が 4 つ散らばり、橙色の曲線は真ん中の 2 点の間にだけ引かれている](https://i.gyazo.com/4ecda07ed6c5ce52abb7aebd230fdc88.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **端まで描きたいときは端の点を 2 度置く。** 点の位置は変えていない — 増やしたのは
    /// 「曲がり方を決めるためだけの点」のほうである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 4 点を通る水色の曲線が、左下の端から右上の端まで引かれている -->
    ///     ![同じ 4 点を通る水色の曲線が、左下の端から右上の端まで引かれている](https://i.gyazo.com/a85ebc2fbea9ebb9f307f8b7904328d5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=51f26e08
    // shot: 2 snippet=36f4228e
    public func curveVertex(_ x: Float, _ y: Float) { canvas.curveVertex(x, y) }

    /// 曲線をいくつの直線で近似するか。
    ///
    /// **1 区間あたりの刻みの数**で、大きいほどなめらかになる (既定は 20)。
    /// ``bezierVertex(_:_:_:_:_:_:)`` / ``quadraticVertex(_:_:_:_:)`` / ``curveVertex(_:_:)``
    /// のどれにも効く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     curveDetail(2)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 刻みが粗く、黄色の曲線が数本の直線に折れて見える -->
    ///     ![刻みが粗く、黄色の曲線が数本の直線に折れて見える](https://i.gyazo.com/b39b2023a2dbb9c79c32a02376fccadc.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     curveDetail(20)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 刻みが細かく、同じ黄色の曲線がなめらかな弧に見える -->
    ///     ![刻みが細かく、同じ黄色の曲線がなめらかな弧に見える](https://i.gyazo.com/03a508f760532bcb7fcb5fdb12b05e41.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=db839269
    // shot: 2 snippet=b204de50
    public func curveDetail(_ steps: Int) { canvas.curveDetail(steps) }

    /// 通過点を結ぶ曲線の張り具合。**0 が既定で、1 にすると点と点が直線で結ばれる。**
    ///
    /// 大きくするほど曲線は点の並び (折れ線) へ近づき、負にするほど**点と点の間での
    /// ふくらみが深くなる**。通る点は変わらない — 変わるのは間の通り方だけで、
    /// 負にしても通過点より外へは出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     curveTightness(-1)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が、点と点の間で既定よりも深くふくらんでいる -->
    ///     ![橙色の曲線が、点と点の間で既定よりも深くふくらんでいる](https://i.gyazo.com/ea06c3fd1e492430bbd74bdcdbfddabc.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     curveTightness(0)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の曲線が 4 つの点をなめらかに通っている (既定) -->
    ///     ![橙色の曲線が 4 つの点をなめらかに通っている (既定)](https://i.gyazo.com/fe197347b14c8a856edf8b6013c82d4e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     curveTightness(1)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     circle(60, 230, 12)
    ///     circle(140, 80, 12)
    ///     circle(260, 220, 12)
    ///     circle(350, 60, 12)
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(4)
    ///     beginShape()
    ///     curveVertex(60, 230)
    ///     curveVertex(60, 230)
    ///     curveVertex(140, 80)
    ///     curveVertex(260, 220)
    ///     curveVertex(350, 60)
    ///     curveVertex(350, 60)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の線が点と点を直線で結び、曲がりの無い折れ線になっている -->
    ///     ![橙色の線が点と点を直線で結び、曲がりの無い折れ線になっている](https://i.gyazo.com/b8922bca0875149df3c1557f15b4cb04.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=fb27d368
    // shot: 2 snippet=822d810e
    // shot: 3 snippet=a9f2f126
    public func curveTightness(_ amount: Float) { canvas.curveTightness(amount) }

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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
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
    // shot: 1 snippet=bec474a2
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
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
    // shot: 1 snippet=c326fc6d
    public func endContour() { canvas.endContour() }

    /// 並べ終えて描く。
    ///
    /// 既定の ``ShapeEnd/open`` は、最後の点から最初の点へ戻らない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
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
    // shot: 1 snippet=42050a4c
    // shot: 2 snippet=43d84742
    public func endShape(_ end: ShapeEnd = .open) { canvas.endShape(end) }

    /// 描くものを、この矩形の中だけに収める。座標の読み方は ``rectMode(_:)`` が決める。
    ///
    /// 積み降ろし (``pushStyle()``) で戻るので、入れ子にして元へ帰れる。
    /// 面の外へ出た指定は面の内側へ収める。
    public func clip(_ a: Float, _ b: Float, _ c: Float, _ d: Float) { canvas.clip(a, b, c, d) }

    /// 切り抜きをやめる。
    public func noClip() { canvas.noClip() }

    /// 描くものを、下にある絵とどう混ぜるか。既定は上に重ねる。
    ///
    /// 下の 4 枚は、灰色の下地に赤と青の円を重ねる同じ絵を、混ぜ方だけ変えたもの。
    ///
    /// ``BlendMode/blend`` (既定) は、後から描いたものが前を覆う。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.55, green: 0.55, blue: 0.58))
    ///     noStroke()
    ///     blendMode(.blend)
    ///     fill(.display(red: 0.95, green: 0.30, blue: 0.20))
    ///     circle(160, 130, 190)
    ///     fill(.display(red: 0.20, green: 0.45, blue: 0.95))
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の下地に赤い円と青い円が並び、青い円が赤い円の上に重なっている -->
    ///     ![灰色の下地に赤い円と青い円が並び、青い円が赤い円の上に重なっている](https://i.gyazo.com/ef8f694c336b8fffb31ac6a6cf323a21.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``BlendMode/add`` は光を重ねたように明るくなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.55, green: 0.55, blue: 0.58))
    ///     noStroke()
    ///     blendMode(.add)
    ///     fill(.display(red: 0.95, green: 0.30, blue: 0.20))
    ///     circle(160, 130, 190)
    ///     fill(.display(red: 0.20, green: 0.45, blue: 0.95))
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 2 つの円が明るくなり、重なった部分が白に近い桃色になっている -->
    ///     ![同じ 2 つの円が明るくなり、重なった部分が白に近い桃色になっている](https://i.gyazo.com/b9d96d70ac9f6d147b768bd89d1f4564.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``BlendMode/multiply`` は暗いほうへ寄る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.55, green: 0.55, blue: 0.58))
    ///     noStroke()
    ///     blendMode(.multiply)
    ///     fill(.display(red: 0.95, green: 0.30, blue: 0.20))
    ///     circle(160, 130, 190)
    ///     fill(.display(red: 0.20, green: 0.45, blue: 0.95))
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 2 つの円が暗くなり、重なった部分がいちばん暗い -->
    ///     ![同じ 2 つの円が暗くなり、重なった部分がいちばん暗い](https://i.gyazo.com/79347a038e72078aa342c5036af65e6a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``BlendMode/difference`` は下地との差を取るので、色が反転して見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.55, green: 0.55, blue: 0.58))
    ///     noStroke()
    ///     blendMode(.difference)
    ///     fill(.display(red: 0.95, green: 0.30, blue: 0.20))
    ///     circle(160, 130, 190)
    ///     fill(.display(red: 0.20, green: 0.45, blue: 0.95))
    ///     circle(240, 175, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 赤い円は桃色、青い円は紫へ転び、重なった部分が鮮やかな赤紫になっている -->
    ///     ![赤い円は桃色、青い円は紫へ転び、重なった部分が鮮やかな赤紫になっている](https://i.gyazo.com/dc91d8f98368175099b77a6942906989.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 重なりが動くと、混ぜ方の効きがはっきりする。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.06, green: 0.06, blue: 0.09))
    ///     noStroke()
    ///     blendMode(.add)
    ///     let sweep = 90 * sin(Float(frameCount) * 0.05)
    ///     fill(.display(red: 0.95, green: 0.20, blue: 0.15))
    ///     circle(200 - sweep, 150, 170)
    ///     fill(.display(red: 0.15, green: 0.45, blue: 0.95))
    ///     circle(200 + sweep, 150, 170)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 赤い円と青い円が近づいたり離れたりし、重なった部分だけが明るい桃色に光る | frames=60 symmetric=y -->
    ///     ![赤い円と青い円が近づいたり離れたりし、重なった部分だけが明るい桃色に光る](https://i.gyazo.com/1e5b770dc68ce2340e1e2addb7e725d3.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **どのモードでも、アルファ 0 の色は下地を変えない。** 混ぜ方が変わっても
    /// 「どれだけ効かせるか」はアルファが決める。
    // shot: 1 snippet=770dfac6
    // shot: 2 snippet=739b6a04
    // shot: 3 snippet=a57216c1
    // shot: 4 snippet=ae76263d
    // shot: 5 snippet=ff14ef73
    public func blendMode(_ mode: BlendMode) { canvas.blendMode(mode) }

    /// 線の折れ目の形。既定は尖らせる形。
    ///
    /// 折れ線と、閉じた図形の輪郭の角に効く。
    ///
    /// ``StrokeJoin/miter`` は角を尖らせる**指定**だが、いまの実装は
    /// ``StrokeJoin/bevel`` と同じ形で埋める (``StrokeJoin/miter`` の但し書き)。
    /// 下の 2 枚が同じ絵になるのはそのためで、伸びの限界を持つ尖りが入れば変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(44)
    ///     strokeJoin(.miter)
    ///     beginShape()
    ///     vertex(70, 230)
    ///     vertex(200, 70)
    ///     vertex(330, 230)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太い橙色の山形の折れ線。頂点は尖らず、平らに削がれている | symmetric=x -->
    ///     ![太い橙色の山形の折れ線。頂点は尖らず、平らに削がれている](https://i.gyazo.com/845d763011b862a08a45daf482ad4330.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeJoin/bevel`` は角を削ぐ。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(44)
    ///     strokeJoin(.bevel)
    ///     beginShape()
    ///     vertex(70, 230)
    ///     vertex(200, 70)
    ///     vertex(330, 230)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ折れ線の頂点が、平らに削がれている | symmetric=x -->
    ///     ![同じ折れ線の頂点が、平らに削がれている](https://i.gyazo.com/845d763011b862a08a45daf482ad4330.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``StrokeJoin/round`` は角を丸める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(44)
    ///     strokeJoin(.round)
    ///     beginShape()
    ///     vertex(70, 230)
    ///     vertex(200, 70)
    ///     vertex(330, 230)
    ///     endShape()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ折れ線の頂点が、丸くなっている | symmetric=x -->
    ///     ![同じ折れ線の頂点が、丸くなっている](https://i.gyazo.com/fa97542f35665344b2155270fe77ff23.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=83ed7fe6
    // shot: 2 snippet=6d2736cd
    // shot: 3 snippet=7fe6028f
    public func strokeJoin(_ join: StrokeJoin) { canvas.strokeJoin(join) }
    /// 矩形を塗る。
    ///
    /// 4 つの数の読み方は ``rectMode(_:)`` が決める。既定は**左上の角と、幅と高さ**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     rect(80, 60, 240, 180)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地に、左上 (80, 60) から 240x180 の橙色の長方形 | symmetric=xy -->
    ///     ![濃い灰色の下地に、左上 (80, 60) から 240x180 の橙色の長方形](https://i.gyazo.com/91321fd926431913d8b41a1bc0877b10.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 3 つ目と 4 つ目は幅と高さなので、片方だけ変えれば細長くなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     rect(60, 40, 280, 60)
    ///     rect(60, 130, 70, 130)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の長方形が上、縦長の長方形が左下に並ぶ -->
    ///     ![横長の長方形が上、縦長の長方形が左下に並ぶ](https://i.gyazo.com/1af656b7596f944cb2736ebbf1a28039.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 幅か高さが 0 以下になる指定では**何も描かない**。
    // shot: 1 snippet=5f2f4b5f
    // shot: 2 snippet=a1283c68
    public func rect(_ a: Float, _ b: Float, _ c: Float, _ d: Float) { canvas.rect(a, b, c, d) }

    /// 正方形を塗る。
    ///
    /// 読み方は ``rect(_:_:_:_:)`` と同じで、幅と高さに同じ値を渡すのに等しい。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(130, 80, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 下地の中ほどに、一辺 140 の橙色の正方形 | symmetric=xy -->
    ///     ![下地の中ほどに、一辺 140 の橙色の正方形](https://i.gyazo.com/816a997e781a50e439a784d00f4f9374.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=0545e44d
    public func square(_ a: Float, _ b: Float, _ extent: Float) { canvas.square(a, b, extent) }

    /// 円を塗る。
    ///
    /// 3 つの数の読み方は ``ellipseMode(_:)`` が決める。既定は**中心と直径**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(200, 150, 160)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地の中央に、直径 160 の橙色の円 | symmetric=xy -->
    ///     ![濃い灰色の下地の中央に、直径 160 の橙色の円](https://i.gyazo.com/9f85642dcfaf33847d61876f57ae2efe.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 3 つ目は直径なので、変えても中心は動かない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     circle(200, 150, 240)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     circle(200, 150, 160)
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     circle(200, 150, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ中心に重なる、直径 240・160・80 の 3 つの円 | symmetric=xy -->
    ///     ![同じ中心に重なる、直径 240・160・80 の 3 つの円](https://i.gyazo.com/0deb638d76e89a91dd47d6ce89d90fda.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=cc15d686
    // shot: 2 snippet=99563468
    public func circle(_ a: Float, _ b: Float, _ diameter: Float) { canvas.circle(a, b, diameter) }

    /// 楕円を塗る。
    ///
    /// 4 つの数の読み方は ``ellipseMode(_:)`` が決める。既定は**中心と、幅と高さ**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     ellipse(200, 150, 280, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 画面の中央に、横に長い橙色の楕円 | symmetric=xy -->
    ///     ![画面の中央に、横に長い橙色の楕円](https://i.gyazo.com/f22d63e7a8e424184eb7bb7a0bf24867.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 幅と高さを入れ替えると、同じ中心のまま向きだけが変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     ellipse(200, 150, 280, 140)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     ellipse(200, 150, 140, 280)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ中心に、横長と縦長の楕円が十字に重なる | symmetric=xy -->
    ///     ![同じ中心に、横長と縦長の楕円が十字に重なる](https://i.gyazo.com/81440c52fa93cc3f7f3ddd3d135e7529.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=660be063
    // shot: 2 snippet=4bc091fd
    public func ellipse(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     arc(200, 150, 200, 200, 0, .pi / 2)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の円の、右から下へ 4 分の 1 だけが橙色の扇形になっている -->
    ///     ![中央の円の、右から下へ 4 分の 1 だけが橙色の扇形になっている](https://i.gyazo.com/09f809b037d513468da45aa923cc321e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 終わりの角度を伸ばすと、扇形はその向きへ広がる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     arc(200, 150, 200, 200, 0, .pi * 1.5)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ円の 4 分の 3 が橙色の扇形になり、右上だけが欠けている -->
    ///     ![同じ円の 4 分の 3 が橙色の扇形になり、右上だけが欠けている](https://i.gyazo.com/69c374878e71d1e6c950630393a8bfd3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 始まりの角度を動かすと、欠けている側が回る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     arc(200, 150, 200, 200, .pi, .pi * 1.5)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から上へ 4 分の 1 だけの橙色の扇形 -->
    ///     ![左から上へ 4 分の 1 だけの橙色の扇形](https://i.gyazo.com/26d9569d49725ce3f3bfc4334f808132.png)
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     let bite = Float.pi / 8
    ///     let start = bite * sin(Float(frameCount) * 0.06) + bite
    ///     arc(200, 150, 200, 200, start, .pi * 2 - start)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 黄色い円が口を開け閉めするように、扇形の欠けが大きくなったり小さくなったりする | frames=60 symmetric=y -->
    ///     ![黄色い円が口を開け閉めするように、扇形の欠けが大きくなったり小さくなったりする](https://i.gyazo.com/7c306f3edde7ca7f3157cbc5dd083a1f.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 塗りは**中心を含む扇形**になる。終わりの角度が始まりより小さいときは
    /// **何も描かず**、最初の 1 回だけ知らせる。
    // shot: 1 snippet=b1d01c8d
    // shot: 2 snippet=de19318a
    // shot: 3 snippet=9301f40a
    // shot: 4 snippet=305be8b5
    public func arc(
        _ a: Float, _ b: Float, _ c: Float, _ d: Float, _ start: Float, _ stop: Float
    ) {
        canvas.arc(a, b, c, d, start, stop)
    }

    /// 三角形を塗る。3 つの頂点をそのまま与える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     triangle(200, 50, 330, 250, 70, 250)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 下地の中央に、頂点を上に向けた橙色の三角形 | symmetric=x -->
    ///     ![下地の中央に、頂点を上に向けた橙色の三角形](https://i.gyazo.com/9e0c0bcf222e3977d1dc13227e874eba.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=7d0adefe
    public func triangle(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x3: Float, _ y3: Float
    ) {
        canvas.triangle(x1, y1, x2, y2, x3, y3)
    }

    /// 四角形を塗る。4 つの頂点は**与えた順に結ばれる**ので、順序を入れ替えると
    /// 砂時計のような形にもなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     quad(70, 60, 330, 90, 310, 240, 90, 210)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 少し傾いた橙色の四角形 -->
    ///     ![少し傾いた橙色の四角形](https://i.gyazo.com/50f0f2f6adfcdaebe808bce6337edeb8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 後ろの 2 つを入れ替えると、同じ 4 点のまま辺が交差する。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     quad(70, 60, 330, 90, 90, 210, 310, 240)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 4 点で辺が交差し、砂時計のような形になっている -->
    ///     ![同じ 4 点で辺が交差し、砂時計のような形になっている](https://i.gyazo.com/68bbdf3c925be4e8eb5ba98e1a0b4cb3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=8f205856
    // shot: 2 snippet=af89c551
    public func quad(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float,
        _ x3: Float, _ y3: Float, _ x4: Float, _ y4: Float
    ) {
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     for index in 0..<5 {
    ///         strokeWeight(Float(index) * 6 + 4)
    ///         point(70 + Float(index) * 65, 150)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から右へ、だんだん大きくなる 5 つの白い点 | symmetric=y -->
    ///     ![左から右へ、だんだん大きくなる 5 つの白い点](https://i.gyazo.com/85a4928d5f536bc3781c1f265bf2c2ea.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 色を決めるのは ``stroke(_:)`` で、``fill(_:)`` は効かない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     strokeWeight(18)
    ///     for index in 0..<5 {
    ///         point(70 + Float(index) * 65, 150)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色に塗る指定をしても、点は水色のまま並んでいる | symmetric=xy -->
    ///     ![橙色に塗る指定をしても、点は水色のまま並んでいる](https://i.gyazo.com/43f7f0bf9325519e41a492150390c392.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=de455ec9
    // shot: 2 snippet=35a5937e
    public func point(_ x: Float, _ y: Float) { canvas.point(x, y) }

    /// 矩形に渡す座標の読み方。既定は ``ShapeMode/corner``。
    ///
    /// 同じ 4 つの数を渡しても、モードが変われば出る場所と大きさが変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     rectMode(.corner)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上を (120, 90) とする 160x120 の橙色の長方形 | symmetric=xy -->
    ///     ![左上を (120, 90) とする 160x120 の橙色の長方形](https://i.gyazo.com/4897a176deed098645d6b8808791c91d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/corners`` は 4 つの数を**向かい合う 2 つの角**として読む。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     rectMode(.corners)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: (120, 90) と (160, 120) を対角とする、小さな橙色の長方形 -->
    ///     ![(120, 90) と (160, 120) を対角とする、小さな橙色の長方形](https://i.gyazo.com/387917c8b465595dea782dfc522edbad.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/center`` は**中心と、幅と高さ**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     rectMode(.center)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: (120, 90) を中心とする 160x120 の橙色の長方形 -->
    ///     ![(120, 90) を中心とする 160x120 の橙色の長方形](https://i.gyazo.com/f36d9de1076d83443e54fef36e915c7e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/radius`` は**中心と、中心から端までの長さ**なので倍の大きさになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     rectMode(.radius)
    ///     rect(120, 90, 160, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ中心のまま、center のときの倍の大きさになった橙色の長方形 -->
    ///     ![同じ中心のまま、center のときの倍の大きさになった橙色の長方形](https://i.gyazo.com/dc4d256a60d1292df561947039050001.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=8fd5ed99
    // shot: 2 snippet=88773cca
    // shot: 3 snippet=c95457e8
    // shot: 4 snippet=39e1d7b6
    public func rectMode(_ mode: ShapeMode) { canvas.rectMode(mode) }

    /// 楕円と円弧に渡す座標の読み方。既定は ``ShapeMode/center``。
    ///
    /// ``circle(_:_:_:)`` にも効く — 直径 1 つしか渡さないので、意味を持つのは
    /// 中心から測る 2 つ (``ShapeMode/center`` と ``ShapeMode/radius``) である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     ellipseMode(.center)
    ///     ellipse(200, 150, 200, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: (200, 150) を中心とする、幅 200 高さ 140 の橙色の楕円 | symmetric=xy -->
    ///     ![(200, 150) を中心とする、幅 200 高さ 140 の橙色の楕円](https://i.gyazo.com/3183dfa1e410e8670ca7f45cc055dd87.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``ShapeMode/corner`` にすると、同じ数が**左上の角と、幅と高さ**になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     ellipseMode(.corner)
    ///     ellipse(200, 150, 200, 140)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ数のまま右下へずれた、幅 200 高さ 140 の橙色の楕円 -->
    ///     ![同じ数のまま右下へずれた、幅 200 高さ 140 の橙色の楕円](https://i.gyazo.com/e20e650ac074bbd0d7c3ca4a39bd29c9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=ace05fd1
    // shot: 2 snippet=da8b31b4
    public func ellipseMode(_ mode: ShapeMode) { canvas.ellipseMode(mode) }
    /// 線を引く。塗りは持たない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     strokeWeight(6)
    ///     line(60, 60, 340, 240)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上から右下へ引かれた 1 本の白い線 -->
    ///     ![左上から右下へ引かれた 1 本の白い線](https://i.gyazo.com/b02fdde509a8e9b6db78a44b8623c1c7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 太さは ``strokeWeight(_:)``、端の形は ``strokeCap(_:)`` が決める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.85, green: 0.90, blue: 1.00))
    ///     for (index, cap) in [StrokeCap.square, .round, .project].enumerated() {
    ///         strokeCap(cap)
    ///         strokeWeight(Float(index) * 8 + 8)
    ///         line(90, 70 + Float(index) * 60, 310, 70 + Float(index) * 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 太さの違う 3 本の白い線が、端の形を変えて横に並んでいる | symmetric=x -->
    ///     ![太さの違う 3 本の白い線が、端の形を変えて横に並んでいる](https://i.gyazo.com/2f54b8bc10dd255977971f5679592cd1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5d41ed20
    // shot: 2 snippet=87c26840
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        canvas.line(x1, y1, x2, y2)
    }
    /// 原点をずらす。
    ///
    /// **図形の座標は変えない。** ずらすのは原点のほうで、同じ `square(0, 0, 80)` が
    /// 違う場所に出る。下の例はどれも同じ 1 行で四角を描いていて、違うのは前に呼ぶ
    /// ``translate(_:_:)`` だけである (薄い線が原点にいたときの位置)。
    ///
    /// 横だけずらす:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(40, 110, 80)
    ///     translate(150, 0)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(40, 110, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠だけの四角の右に、同じ大きさの橙色の四角が並んでいる | symmetric=y -->
    ///     ![灰色の枠だけの四角の右に、同じ大きさの橙色の四角が並んでいる](https://i.gyazo.com/4a539ee108132857230c49f0902cb52f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 縦だけずらす:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(160, 30, 80)
    ///     translate(0, 140)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(160, 30, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠だけの四角の下に、同じ大きさの水色の四角が並んでいる | symmetric=x -->
    ///     ![灰色の枠だけの四角の下に、同じ大きさの水色の四角が並んでいる](https://i.gyazo.com/fc34d9ce032ae868920ada3421cd796f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **重ねて呼ぶと足し合わさる。** 2 度呼べば 2 度ぶんずれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     square(30, 30, 60)
    ///     translate(100, 70)
    ///     fill(.display(red: 0.55, green: 0.60, blue: 0.70))
    ///     square(30, 30, 60)
    ///     translate(100, 70)
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     square(30, 30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰・薄い灰・黄の四角が、左上から右下へ等間隔の階段状に並んでいる -->
    ///     ![濃い灰・薄い灰・黄の四角が、左上から右下へ等間隔の階段状に並んでいる](https://i.gyazo.com/61c3d3f1b24a6fa55c228934a366d4bb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b049f853
    // shot: 2 snippet=2e149d2f
    // shot: 3 snippet=b9761949
    public func translate(_ x: Float, _ y: Float) { canvas.translate(x, y) }
    /// 回す。縦軸が下向きなので、正の角度は画面の上で時計回りに見える。
    ///
    /// **回る中心は原点である。** 図形の真ん中ではないので、原点から離れた図形を回すと
    /// 位置ごと動く。真ん中で回したいときは ``translate(_:_:)`` で原点を図形の
    /// 中心へ運んでから回す — 下の例はどれもそうしている (薄い枠が回す前の位置)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-60, -60, 120)
    ///     rotate(0.26)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-60, -60, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、少しだけ時計回りに傾いた橙色の正方形が重なっている -->
    ///     ![灰色の枠の正方形に、少しだけ時計回りに傾いた橙色の正方形が重なっている](https://i.gyazo.com/3ac184de0bb8aacfbc75693bbbb93c85.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 45 度 (`0.79` ラジアン) 回すと、正方形は菱形に見える:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-60, -60, 120)
    ///     rotate(0.79)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(-60, -60, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形の上に、45 度傾いて菱形に見える水色の正方形が重なっている | symmetric=xy -->
    ///     ![灰色の枠の正方形の上に、45 度傾いて菱形に見える水色の正方形が重なっている](https://i.gyazo.com/14ab1a48c0eb4df486f6f71d33d1c0a1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **負の角度は反対向き** (画面の上で反時計回り):
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     rect(-90, -30, 180, 60)
    ///     rotate(-0.52)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     rect(-90, -30, 180, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の灰色の枠に、左端が上がる向きに傾いた黄色の横長の四角が重なっている -->
    ///     ![横長の灰色の枠に、左端が上がる向きに傾いた黄色の横長の四角が重なっている](https://i.gyazo.com/5c2c33811e5859573472d5b8bc53a96a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=31999c20
    // shot: 2 snippet=d8a6fbf0
    // shot: 3 snippet=4d75c8fb
    public func rotate(_ radians: Float) { canvas.rotate(radians) }
    /// 伸ばす・縮める。
    ///
    /// **基準は原点で、図形の中心ではない。** 倍率は軸ごとに別々に決まるので、片方だけ
    /// 渡せば片方だけ伸びる。下の例は原点を面の中央へ運んでから掛けている (薄い枠が
    /// 等倍のときの位置)。
    ///
    /// 横だけ 2 倍:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-45, -45, 90)
    ///     scale(2, 1)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形をまたいで、横に 2 倍伸びた橙色の長方形が重なっている | symmetric=xy -->
    ///     ![灰色の枠の正方形をまたいで、横に 2 倍伸びた橙色の長方形が重なっている](https://i.gyazo.com/703913f942c9f3f394e33df6eef57665.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 縦だけ半分:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-45, -45, 90)
    ///     scale(1, 0.5)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形の中に、縦が半分に潰れた水色の横長の四角が収まっている | symmetric=xy -->
    ///     ![灰色の枠の正方形の中に、縦が半分に潰れた水色の横長の四角が収まっている](https://i.gyazo.com/29546ac971a94e11b4b2859ccad1176f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **線の太さも一緒に掛かる。** 掛けた後に引く線は、倍率のぶん太く (細く) 見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-45, -45, 90)
    ///     scale(1.6, 1.6)
    ///     stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 細い灰色の枠の正方形の外側に、一回り大きく線も太い黄色の枠の正方形がある | symmetric=xy -->
    ///     ![細い灰色の枠の正方形の外側に、一回り大きく線も太い黄色の枠の正方形がある](https://i.gyazo.com/30d87c6524acd2e85185dbe01c2cea82.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=76d7590b
    // shot: 2 snippet=e61d2850
    // shot: 3 snippet=fe738fca
    public func scale(_ x: Float, _ y: Float) { canvas.scale(x, y) }

    /// 原点を奥行きも含めてずらす。
    ///
    /// **奥行きは見ている側が正。** 正の値を渡すと手前へ、負の値を渡すと奥へ動く
    /// (手本のある向きに合わせてある)。
    ///
    /// **平面版との違いは、大きさが変わること。** 既定の視点は遠近が付くので、
    /// まったく同じ球でも手前に置いたほうが大きく見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     for (index, depth) in [Float(-110), 0, 80].enumerated() {
    ///         push()
    ///         translate(90 + Float(index) * 105, 150, depth)
    ///         sphere(28)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ半径の橙色の球が 3 つ。左から右へ、奥から手前へ置いてあり、右へ行くほど大きく見える -->
    ///     ![同じ半径の橙色の球が 3 つ。左から右へ、奥から手前へ置いてあり、右へ行くほど大きく見える](https://i.gyazo.com/e197b11cec722ba8b16852986cdf813e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=0c95f4e0
    public func translate(_ x: Float, _ y: Float, _ z: Float) { canvas.translate(x, y, z) }

    /// 横軸まわりに回す。
    ///
    /// 縦軸が下向きなので、正の角度は**上の面が奥へ倒れる**向きに見える。
    /// 下の 3 段階は同じ板で、**縦が詰まっていく**。横幅は軸に沿っているので変わらない
    /// はずだが、傾いた板の上の辺が手前へ来るぶん**遠近で少しだけ広がる**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     for (index, angle) in [Float(0), 0.6, 1.2].enumerated() {
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         rotateX(angle)
    ///         box(100, 44, 8)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の横長の板が 3 つ。左から右へ、縦だけが詰まって奥へ倒れていく -->
    ///     ![橙色の横長の板が 3 つ。左から右へ、縦だけが詰まって奥へ倒れていく](https://i.gyazo.com/38501d547b91f7a4b02377af00cd8caa.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=84ddd42c
    public func rotateX(_ radians: Float) { canvas.rotateX(radians) }

    /// 縦軸まわりに回す。
    ///
    /// 正の角度は、右の面が奥へ回る向きに見える。
    /// ``rotateX(_:)`` とまったく同じ板を同じ角度で回しているが、**詰まるのは横のほう**
    /// である。こちらも縦が遠近で少しだけ伸びる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     for (index, angle) in [Float(0), 0.6, 1.2].enumerated() {
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         rotateY(angle)
    ///         box(100, 44, 8)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ橙色の板が 3 つ。左から右へ、横だけが詰まって右の面が奥へ回っていく | symmetric=y -->
    ///     ![同じ橙色の板が 3 つ。左から右へ、横だけが詰まって右の面が奥へ回っていく](https://i.gyazo.com/7bbfaf01e374dbcb4ca4664b377a3fb1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a0e2a911
    public func rotateY(_ radians: Float) { canvas.rotateY(radians) }

    /// 奥行きの軸まわりに回す。``rotate(_:)`` と同じ。
    ///
    /// **こちらは画面の中で回るだけ** — 板が傾いても、こちらを向いた面が奥へ倒れない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     for (index, angle) in [Float(0), 0.6, 1.2].enumerated() {
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         rotateZ(angle)
    ///         box(100, 44, 8)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ橙色の板が 3 つ。左から右へ画面の中で傾いていくが、奥へは倒れない -->
    ///     ![同じ橙色の板が 3 つ。左から右へ画面の中で傾いていくが、奥へは倒れない](https://i.gyazo.com/021262387681ab64202dd35e05b95479.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=e95a52a6
    public func rotateZ(_ radians: Float) { canvas.rotateZ(radians) }

    /// 奥行きも含めて伸ばす・縮める。
    ///
    /// **奥行きだけを伸ばした立体は、正面からでは分からない。** 下の 3 つは同じ場所・
    /// 同じ向きに置いてあり、変えたのは伸ばす軸だけ — 横へ伸ばすと横幅がそのまま倍に
    /// なるが、奥へ伸ばしたぶんは**回してある角度のぶんだけ**しか横幅に出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(200, 55, 0)
    ///     rotateY(0.35)
    ///     box(50)
    ///     pop()
    ///     push()
    ///     translate(200, 150, 0)
    ///     rotateY(0.35)
    ///     scale(2, 1, 1)
    ///     box(50)
    ///     pop()
    ///     push()
    ///     translate(200, 245, 0)
    ///     rotateY(0.35)
    ///     scale(1, 1, 2)
    ///     box(50)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の箱が縦に 3 つ。上は立方体、真ん中は横へ広く、下は奥へ伸びていて上より少しだけ広い -->
    ///     ![橙色の箱が縦に 3 つ。上は立方体、真ん中は横へ広く、下は奥へ伸びていて上より少しだけ広い](https://i.gyazo.com/6b1bc92b37837419450260289e1540d5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=c7877b94
    public func scale(_ x: Float, _ y: Float, _ z: Float) { canvas.scale(x, y, z) }

    /// 横方向へ斜めに歪める。
    ///
    /// **縦の辺だけが傾く。** 横の辺は水平のまま残るので、正方形は平行四辺形になる。
    /// ずれる量は原点からの縦の距離に比例するので、**正の角度では下の辺ほど右へ**動く
    /// (薄い枠が歪める前の位置)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearX(0.5)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、下辺が右へずれた橙色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、下辺が右へずれた橙色の平行四辺形が重なっている](https://i.gyazo.com/df91781ca0dfd22959333bc36f37b5a4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **負の角度は反対へ倒れる**:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearX(-0.5)
    ///     noStroke()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、下辺が左へずれた水色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、下辺が左へずれた水色の平行四辺形が重なっている](https://i.gyazo.com/d7e5c29e1052867d86b3303375e5a1d5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=481117e9
    // shot: 2 snippet=a1793d65
    public func shearX(_ radians: Float) { canvas.shearX(radians) }

    /// 縦方向へ斜めに歪める。
    ///
    /// ``shearX(_:)`` と軸が入れ替わる — **横の辺だけが傾き**、縦の辺は垂直のまま残る。
    /// ずれる量は原点からの横の距離に比例するので、**正の角度では右の辺ほど下へ**動く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearY(0.5)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、右辺が下へずれた黄色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、右辺が下へずれた黄色の平行四辺形が重なっている](https://i.gyazo.com/e1c57633ffff621e2e6a034ab1f19acd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **負の角度は反対へ倒れる**:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(-55, -55, 110)
    ///     shearY(-0.5)
    ///     noStroke()
    ///     fill(.display(red: 0.55, green: 0.85, blue: 0.55))
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、右辺が上へずれた緑色の平行四辺形が重なっている -->
    ///     ![灰色の枠の正方形に、右辺が上へずれた緑色の平行四辺形が重なっている](https://i.gyazo.com/31825412975ecf1316a352efd44bc74f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=8e8a2090
    // shot: 2 snippet=f3fcdb4e
    public func shearY(_ radians: Float) { canvas.shearY(radians) }

    /// 与えた変換を、いまの変換の後に重ねる。
    ///
    /// 渡す ``Transform`` は ``Transform/identity`` から積み上げて作る。積む順も向きも
    /// ``translate(_:_:)`` や ``rotate(_:)`` を並べて呼ぶのと同じで、**結果も同じ**に
    /// なる — 違うのは、その一連の変換を**値として持てる**ことである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(2)
    ///     square(145, 95, 110)
    ///     var moved = Transform.identity
    ///     moved.translate(x: 200, y: 150)
    ///     moved.rotate(by: 0.6)
    ///     applyMatrix(moved)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、同じ中心で右へ傾いた橙色の正方形が重なっている -->
    ///     ![灰色の枠の正方形に、同じ中心で右へ傾いた橙色の正方形が重なっている](https://i.gyazo.com/6320710d6ce061aa8a49fbf841271445.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **値として持てると、同じ変換を何度も重ねられる。** 移動・回転・縮小を 1 つに
    /// まとめた `step` を作り、図形を描くたびに重ねると、同じ間隔で少しずつ倒れて
    /// 小さくなる並びになる。呼び出しを並べる書き方では、この「1 段ぶんの変換」を
    /// 名前で指せない:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(120, 215)
    ///     var step = Transform.identity
    ///     step.translate(x: 46, y: -34)
    ///     step.rotate(by: 0.3)
    ///     step.scale(x: 0.86, y: 0.86)
    ///     noStroke()
    ///     for i in 0..<6 {
    ///         fill(.display(red: 0.35 + Float(i) * 0.10, green: 0.78 - Float(i) * 0.07, blue: 0.95))
    ///         square(-30, -30, 60)
    ///         applyMatrix(step)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左下から右へ、少しずつ小さく傾きながら弧を描いて並ぶ 6 つの正方形。色は水色から桃色へ移る -->
    ///     ![左下から右へ、少しずつ小さく傾きながら弧を描いて並ぶ 6 つの正方形。色は水色から桃色へ移る](https://i.gyazo.com/84d3726467a3f3fefee55ee7b16c35d8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f11076e6
    // shot: 2 snippet=8a91459f
    public func applyMatrix(_ matrix: Transform) { canvas.applyMatrix(matrix) }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix()``) は捨てないので、戻す先は残る。
    ///
    /// **どれだけ重ねていても 1 回で戻る。** 下の例は原点を動かして回した後に呼んで
    /// いるので、最後の四角は面の左上を原点とする素の座標で描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     rotate(0.5)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-50, -50, 100)
    ///     resetMatrix()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(20, 20, 70)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央に傾いた橙色の正方形があり、左上の隅にまっすぐな水色の正方形がある -->
    ///     ![中央に傾いた橙色の正方形があり、左上の隅にまっすぐな水色の正方形がある](https://i.gyazo.com/e38e62b49f5580c4209b966ed516c724.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b928daab
    public func resetMatrix() { canvas.resetMatrix() }

    /// いまの変換を積んでおく。
    ///
    /// ``popMatrix()`` と対で使う。**挟んだ中で何を掛けても、外へ出れば元に戻る** ので、
    /// 図形ごとに変換を掛けたいときに前の状態を数えなくて済む。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     noStroke()
    ///     pushMatrix()
    ///     rotate(0.79)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-55, -55, 110)
    ///     popMatrix()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(-30, -30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 45 度傾いた橙色の正方形の中央に、傾いていない水色の小さな正方形が重なっている | symmetric=xy -->
    ///     ![45 度傾いた橙色の正方形の中央に、傾いていない水色の小さな正方形が重なっている](https://i.gyazo.com/923ac5c1df5399eaec343b5344dc0132.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **積むのは何段でもよい。** 段ごとに戻る先が別々に残る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     translate(90, 150)
    ///     pushMatrix()
    ///     translate(110, 0)
    ///     pushMatrix()
    ///     translate(110, 0)
    ///     fill(.display(red: 0.95, green: 0.85, blue: 0.35))
    ///     square(-30, -30, 60)
    ///     popMatrix()
    ///     fill(.display(red: 0.55, green: 0.60, blue: 0.70))
    ///     square(-30, -30, 60)
    ///     popMatrix()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-30, -30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・灰・黄の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる | symmetric=y -->
    ///     ![橙・灰・黄の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる](https://i.gyazo.com/782c849f1510bab910e10317a0b8c128.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5e812adb
    // shot: 2 snippet=4752a417
    public func pushMatrix() { canvas.pushMatrix() }

    /// 積んでおいた変換へ戻す。積んでいなければ何もしない。
    ///
    /// **積んでいないときに呼んでも落ちない。** 何もせずそのまま進むので、対にし忘れた
    /// 場合は「戻らない」ことだけが起きる — 下の例は ``pushMatrix()`` を呼んでいないので、
    /// 2 つ目の四角も回した座標系のまま描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     translate(200, 150)
    ///     rotate(0.79)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     square(-55, -55, 110)
    ///     popMatrix()
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(-30, -30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 45 度傾いた橙色の正方形の中央に、同じく傾いた水色の小さな正方形が重なっている | symmetric=xy -->
    ///     ![45 度傾いた橙色の正方形の中央に、同じく傾いた水色の小さな正方形が重なっている](https://i.gyazo.com/75d1ddf1cbab5bdb7265ab44779d76e3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=cef51ea3
    public func popMatrix() { canvas.popMatrix() }

    /// いまのスタイル (塗り・線・端と折れ目の形・座標の読み方) を積んでおく。
    public func pushStyle() { canvas.pushStyle() }

    // MARK: - 視点と投影

    /// 視点を既定へ戻す。
    ///
    /// 既定は**面がちょうど収まる位置から、面を正面に見る**視点である。だから何も
    /// 指定せずに置いた立体は画素の大きさで見え、奥行き 0 に置いたものは同じ座標に
    /// 描いた平面の図形とぴったり重なる。
    ///
    /// **重なることは絵で確かめられる。** 下は斜めの視点にしてから `camera()` で
    /// 戻し、奥行き 0 の面と、同じ座標に描いた平面の四角を重ねたものである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     // 斜めから見る視点にしてから、既定へ戻す
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     camera()
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(120, 100, 0)
    ///     plane(120, 120)
    ///     pop()
    ///     // 同じ座標に描いた平面の図形。こちらは視点の影響を受けない
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     strokeWeight(3)
    ///     square(60, 40, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の正方形の面に、同じ大きさの水色の細い四角がずれなく重なっている -->
    ///     ![橙色の正方形の面に、同じ大きさの水色の細い四角がずれなく重なっている](https://i.gyazo.com/2de6696ad418dc1815519342f4c15771.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 視点は**フレームを越えない**。`draw()` の中で毎フレーム書く。初期化の
    ///   ときに書いた視点はどのフレームにも属さないので、警告して無視される。
    // shot: 1 snippet=97d20b2d
    public func camera() { canvas.camera() }

    /// 見る位置・見ている先・上方向を決める。
    ///
    /// 座標は世界の座標で、**いまの変換の影響を受けない** — 視点は「何をどう置くか」
    /// ではなく「どこから見るか」なので、積んだ変換とは別に決まる。
    ///
    /// 下は**同じ高さに置いた 3 つの立方体を、上から見下ろした**もの。正面から見た絵
    /// (``perspective()`` の 1 枚) では、どれが手前かは大きさの差でしか分からない —
    /// 見下ろすと**奥行きが上下のずれになる**ので、並びがそのまま位置として読める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     // 上から見下ろす。奥行きの違いが上下のずれになる
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     // 同じ大きさの立方体を、横と奥行きだけ変えて 3 つ
    ///     for (x, z) in [(Float(105), Float(80)), (200, 0), (325, -80)] {
    ///         push()
    ///         translate(x, 150, z)
    ///         rotateY(0.6)
    ///         rotateX(0.35)
    ///         box(48)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 つの立方体が左下から右上へ階段のように並んでいる。奥に置いたものほど画面の上に写っている -->
    ///     ![3 つの立方体が左下から右上へ階段のように並んでいる。奥に置いたものほど画面の上に写っている](https://i.gyazo.com/077611e0ae638fb99709fdd0c0d73ddc.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - eyeX: 見る位置。
    ///   - eyeY: 見る位置。
    ///   - eyeZ: 見る位置。**奥行きは手前が正**なので、正の値が画面の手前になる。
    ///   - centerX: 見ている先。
    ///   - centerY: 見ている先。
    ///   - centerZ: 見ている先。
    ///   - upX: どちらを上とするか。
    ///   - upY: どちらを上とするか。**縦軸は下向き**なので、`(0, 1, 0)` が普通の向きになる。
    ///   - upZ: どちらを上とするか。
    ///
    /// - Note: 視点は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    ///   見る位置と見ている先が同じ・上方向が視線と重なるといった成り立たない指定は、
    ///   警告してそれまでの視点のまま続ける。
    // shot: 1 snippet=e2cc6454
    public func camera(
        _ eyeX: Float, _ eyeY: Float, _ eyeZ: Float,
        _ centerX: Float, _ centerY: Float, _ centerZ: Float,
        _ upX: Float, _ upY: Float, _ upZ: Float
    ) {
        canvas.camera(eyeX, eyeY, eyeZ, centerX, centerY, centerZ, upX, upY, upZ)
    }

    /// いま効いている視点を、値として取る。
    ///
    /// 視点はフレームを越えないので、**複数の視点を持ちたければ値で持つ**。初期化の
    /// ときに作っておいて、毎フレーム ``setCamera(_:)`` で当てる。
    ///
    /// <!-- example: 組めない 視点を値で持つ形だけを示す省略記法 (`...`) -->
    /// ```swift
    /// var front = Camera(...)
    /// var side = Camera(...)
    ///
    /// func draw() {
    ///     setCamera(frameCount / 60 % 2 == 0 ? front : side)
    ///     ...
    /// }
    /// ```
    public var currentCamera: Camera { canvas.currentCamera }

    /// 作っておいた視点を当てる。
    ///
    /// **1 つのフレームに複数の視点を混ぜられる。** 視点を当てると、そこまでに置いた
    /// ものは**置いた時点の視点のまま**描き切られるためである。下は場面を斜めから
    /// 見て、目盛りだけ既定の視点へ戻して描いたもの — 戻したほうは奥行き 0 なので、
    /// 平面の図形と同じように座標どおりの長方形として出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     let front = currentCamera
    ///     // 場面は斜めから見る
    ///     camera(200, -150, 300, 200, 150, 0, 0, 1, 0)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     box(120)
    ///     pop()
    ///     // 目盛りだけ既定の視点へ戻して描く
    ///     setCamera(front)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     push()
    ///     translate(60, 250, 0)
    ///     plane(80, 24)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 斜めから見た橙色の立方体の下に、水色の細長い長方形が画面と平行に置かれている -->
    ///     ![斜めから見た橙色の立方体の下に、水色の細長い長方形が画面と平行に置かれている](https://i.gyazo.com/0f6b5f84dc947ede21aa5f8db8218136.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 視点は**フレームを越えない**。`draw()` の中で毎フレーム当てる。
    // shot: 1 snippet=378168f8
    public func setCamera(_ camera: Camera) { canvas.setCamera(camera) }

    /// 透視投影を既定へ戻す。
    ///
    /// 既定の画角・手前と奥の面は、**既定の視点の距離から導かれている**。
    ///
    /// 下はこの節のほかの絵と同じ場面を、既定の透視投影で写したもの。比べるときの
    /// 基準になる。**3 つの立方体は同じ大きさ**で、置いた奥行きだけが違う。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     // 投影を既定へ戻す
    ///     perspective()
    ///     // 同じ大きさの立方体を、横と奥行きだけ変えて 3 つ
    ///     for (x, z) in [(Float(105), Float(80)), (200, 0), (325, -80)] {
    ///         push()
    ///         translate(x, 150, z)
    ///         rotateY(0.6)
    ///         rotateX(0.35)
    ///         box(48)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの立方体が 3 つ。手前に置いたものほど大きく写っている -->
    ///     ![同じ大きさの立方体が 3 つ。手前に置いたものほど大きく写っている](https://i.gyazo.com/d5911bec26fda6b6d5467ba8a9b92323.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 投影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=0aacaded
    public func perspective() { canvas.perspective() }

    /// 遠くのものほど小さく写す。
    ///
    /// 下の 2 枚は ``perspective()`` の絵と同じ場面で、引数だけを変えている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     // 画角を広げる (既定は π/3)
    ///     perspective(1.6, width / height, 26, 2600)
    ///     // 同じ大きさの立方体を、横と奥行きだけ変えて 3 つ
    ///     for (x, z) in [(Float(105), Float(80)), (200, 0), (325, -80)] {
    ///         push()
    ///         translate(x, 150, z)
    ///         rotateY(0.6)
    ///         rotateX(0.35)
    ///         box(48)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 つの立方体がどれも小さくなり、画面の中央寄りに集まっている -->
    ///     ![3 つの立方体がどれも小さくなり、画面の中央寄りに集まっている](https://i.gyazo.com/996f977e3616ed01224e30bedc6d88ae.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     // 奥の面を手前へ寄せる
    ///     perspective(Float.pi / 3, width / height, 26, 300)
    ///     // 同じ大きさの立方体を、横と奥行きだけ変えて 3 つ
    ///     for (x, z) in [(Float(105), Float(80)), (200, 0), (325, -80)] {
    ///         push()
    ///         translate(x, 150, z)
    ///         rotateY(0.6)
    ///         rotateX(0.35)
    ///         box(48)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 立方体が 2 つしか写っていない。いちばん奥に置いた 3 つ目が消えている -->
    ///     ![立方体が 2 つしか写っていない。いちばん奥に置いた 3 つ目が消えている](https://i.gyazo.com/77156723b2ab7429a314178d5f87c889.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - fieldOfView: 縦方向の画角 (ラジアン)。**広げるほど写る範囲が広がり、その
    ///     ぶん被写体は小さくなる。** 視点を動かさずに画角だけ変えても**遠近の強さは
    ///     変わらない** — 手前と奥の大きさの比を決めているのは、画角ではなく視点から
    ///     の距離である。
    ///   - aspect: 横 ÷ 縦の比。ふつうは `width / height`。
    ///   - near: 手前の面までの距離。**これより手前は写らない。**
    ///   - far: 奥の面までの距離。**これより奥は写らない。**
    ///
    /// - Note: 投影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=75f86d22
    // shot: 2 snippet=accb6544
    public func perspective(_ fieldOfView: Float, _ aspect: Float, _ near: Float, _ far: Float) {
        canvas.perspective(fieldOfView, aspect, near, far)
    }

    /// 平行投影を既定へ戻す。
    ///
    /// 範囲は**既定の視点を中心に面 1 枚ぶん**である。だから `ortho()` だけを書いても
    /// 被写体は隅へ寄らず、奥に置いたものも切れない。奥行き 0 に置いたものが平面の
    /// 図形と重なる性質も、透視投影の既定と同じように成り立つ。
    ///
    /// ``perspective()`` の絵と同じ場面である。**奥行きが違っても大きさが変わらない**
    /// ので、3 つの立方体は同じ幅で並ぶ。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     // 平行投影へ切り替える
    ///     ortho()
    ///     // 同じ大きさの立方体を、横と奥行きだけ変えて 3 つ
    ///     for (x, z) in [(Float(105), Float(80)), (200, 0), (325, -80)] {
    ///         push()
    ///         translate(x, 150, z)
    ///         rotateY(0.6)
    ///         rotateX(0.35)
    ///         box(48)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 つの立方体が同じ大きさで横に並んでいる。奥に置いたものも小さくなっていない -->
    ///     ![3 つの立方体が同じ大きさで横に並んでいる。奥に置いたものも小さくなっていない](https://i.gyazo.com/629a4b0cc5e5caaffe305b5ea3374f9c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 投影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=4f7b76e3
    public func ortho() { canvas.ortho() }

    /// 距離によらず同じ大きさで写す。
    ///
    /// 範囲は**視点から見た座標**で与える。
    ///
    /// ```swift
    /// // 面 1 枚ぶんを、視点を中心に写す (ortho() と同じ範囲)
    /// ortho(-width / 2, width / 2, height / 2, -height / 2, 60, 6000)
    /// ```
    ///
    /// **範囲を広げるほど小さく写る。** 下は ``ortho()`` と同じ場面を、面 1 枚半ぶんの
    /// 範囲で写したもの。3 つとも同じ幅である点は変わらない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     // 面 1 枚ぶんより広い範囲を写す (既定は 400×300 ぶん)
    ///     ortho(-300, 300, 225, -225, 60, 2600)
    ///     // 同じ大きさの立方体を、横と奥行きだけ変えて 3 つ
    ///     for (x, z) in [(Float(105), Float(80)), (200, 0), (325, -80)] {
    ///         push()
    ///         translate(x, 150, z)
    ///         rotateY(0.6)
    ///         rotateX(0.35)
    ///         box(48)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 つの立方体が同じ大きさで並んでいる。ortho() の絵より一回り小さく、中央へ寄っている -->
    ///     ![3 つの立方体が同じ大きさで並んでいる。ortho() の絵より一回り小さく、中央へ寄っている](https://i.gyazo.com/daf137a448beb2f0a7737629a248b488.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - left: 画面の左端に来る位置。
    ///   - right: 画面の右端に来る位置。
    ///   - bottom: **画面の下端**に来る位置。
    ///   - top: **画面の上端**に来る位置。
    ///   - near: 手前の面までの距離。これより手前は写らない。
    ///   - far: 奥の面までの距離。これより奥は写らない。
    ///
    /// - Important: 縦軸が下向きなので、**`top` のほうが `bottom` より小さい数**になる。
    ///   引数は画面の側を正として読む — `top` は画面の上端であって、行列の慣行で言う
    ///   上側ではない。取り違えても警告は出ず、絵が上下反転するだけなので注意する。
    ///
    /// - Note: 投影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=13b60e14
    public func ortho(
        _ left: Float, _ right: Float, _ bottom: Float, _ top: Float, _ near: Float, _ far: Float
    ) {
        canvas.ortho(left, right, bottom, top, near, far)
    }

    // MARK: - 光

    /// 全体を底上げする光を置く。向きを持たないので、どの面も同じだけ明るくなる。
    ///
    /// **色そのものが明るさの倍率**である。`1.0` は「その光を正面から受けた白い面が
    /// 白として出る」明るさで、それより明るい光は 1 を超える色で書く
    /// (`.opaque(red: 2, green: 2, blue: 2)`)。強さを表す別の数は持たない。
    ///
    /// **向きを持たないので、丸いものも丸く見えない。** 下は同じ球を、底上げの光の
    /// 明るさだけ変えて 3 つ描いたもの — どれも塗り 1 色の円板で、変わるのは明るさ
    /// だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     for (index, level) in [Float(0.15), 0.4, 0.9].enumerated() {
    ///         noLights()
    ///         ambientLight(.opaque(red: level, green: level, blue: level))
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円が 3 つ。左から右へ明るくなるが、どれも陰影が無く塗りつぶした円板に見える | symmetric=y -->
    ///     ![橙色の円が 3 つ。左から右へ明るくなるが、どれも陰影が無く塗りつぶした円板に見える](https://i.gyazo.com/3763e86b68c96dbbc1984eb558372872.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。初期化の
    ///   ときに置いた光はどのフレームにも属さないので、警告して無視される。
    // shot: 1 snippet=33e9275d
    public func ambientLight(_ color: LinearRGBA) { canvas.ambientLight(color) }

    /// 向きだけを持つ光を置く (無限に遠くから差す光)。
    ///
    /// 渡すのは**光が進む向き**である。縦軸は下向きなので、`(0, 1, 0)` が真上から
    /// 差す光になる。斜めの成分を入れると、陰の境目が左右どちらかへ寄る。
    ///
    /// 下は同じ球を、光が進む向きだけ変えて 3 つ描いたもの。**明るくなるのは光が
    /// 入ってくる側**である — 右へ進む光 `(1, …)` は球の左側を、下へ進む光 `(…, 1, …)`
    /// は上側を照らす。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     let ways: [(Float, Float, Float)] = [(1, 0.25, -0.3), (0, 1, -0.3), (-1, -1, -0.3)]
    ///     for (index, way) in ways.enumerated() {
    ///         noLights()
    ///         ambientLight(.opaque(red: 0.12, green: 0.12, blue: 0.12))
    ///         directionalLight(.opaque(red: 0.95, green: 0.95, blue: 0.95), way.0, way.1, way.2)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。明るい側が左・上・右下と移り、反対側が暗く落ちている -->
    ///     ![橙色の球が 3 つ。明るい側が左・上・右下と移り、反対側が暗く落ちている](https://i.gyazo.com/1a82908e97c3c99ef3d7093efd421e8d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=2fb129d2
    public func directionalLight(_ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float) {
        canvas.directionalLight(color, x, y, z)
    }

    /// 位置を持つ光を置く。面から光源へ向かう向きで明るさが決まる。
    ///
    /// **平行光と違い、当たり方が場所によって変わる。** 下は平らな面 1 枚を、左上に
    /// 置いた光で照らしたもの — いちばん明るいのは光源の真下で、そこから四方へ
    /// なだらかに暗くなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     ambientLight(.opaque(red: 0.12, green: 0.12, blue: 0.12))
    ///     // 面より手前 (z = 160) の、左上に置く
    ///     pointLight(.opaque(red: 1.1, green: 1.1, blue: 1.1), 110, 90, 160)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の面。左上が最も明るく、右下へ向かってなだらかに暗くなっている -->
    ///     ![橙色の面。左上が最も明るく、右下へ向かってなだらかに暗くなっている](https://i.gyazo.com/94332772af480c9101862cd9caa23e22.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=124cad8c
    public func pointLight(_ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float) {
        canvas.pointLight(color, x, y, z)
    }

    /// 位置と向きと広がりを持つ光を置く。広がりの外へは当たらない。
    ///
    /// - Parameters:
    ///   - color: 光の色 (明るさの倍率を兼ねる)。
    ///   - x: 光源の位置。
    ///   - y: 光源の位置。
    ///   - z: 光源の位置。
    ///   - directionX: 光が進む向き。
    ///   - directionY: 光が進む向き。
    ///   - directionZ: 光が進む向き。
    ///   - angle: 広がりの半分の角 (ラジアン)。
    ///
    /// 下の 2 枚は同じ面を、同じ位置・同じ向きの光で照らしている。**違うのは広がりの
    /// 角だけ**で、当たる輪の大きさがそれについて変わる。輪の外は底上げの光しか
    /// 届かないので暗いままである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     ambientLight(.opaque(red: 0.12, green: 0.12, blue: 0.12))
    ///     // 狭い光 (半分の角 15 度)
    ///     spotLight(
    ///         .opaque(red: 1.2, green: 1.2, blue: 1.2),
    ///         160, 120, 200,
    ///         0, 0, -1,
    ///         angle: .pi / 12)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 暗い橙色の面の左上寄りに、明るい小さな円が浮かんでいる -->
    ///     ![暗い橙色の面の左上寄りに、明るい小さな円が浮かんでいる](https://i.gyazo.com/228198bdd5db252909cdc2373789c4c0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     ambientLight(.opaque(red: 0.12, green: 0.12, blue: 0.12))
    ///     // 広い光 (半分の角 25.7 度)
    ///     spotLight(
    ///         .opaque(red: 1.2, green: 1.2, blue: 1.2),
    ///         160, 120, 200,
    ///         0, 0, -1,
    ///         angle: .pi / 7)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ面の同じ場所だが、明るい円がひとまわり以上大きく広がっている -->
    ///     ![同じ面の同じ場所だが、明るい円がひとまわり以上大きく広がっている](https://i.gyazo.com/f9a015f5bf1dfcf589cc459d8e9d296e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=c24e62c2
    // shot: 2 snippet=e0bd7283
    public func spotLight(
        _ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float,
        _ directionX: Float, _ directionY: Float, _ directionZ: Float,
        angle: Float = .pi / 6
    ) {
        canvas.spotLight(color, x, y, z, directionX, directionY, directionZ, angle: angle)
    }

    /// ひととおりの光を置く — 底上げの光と、斜め上から差す光。
    ///
    /// 立体を「とりあえず立体らしく」見せるための組み合わせ。細かく決めたくなったら
    /// ``ambientLight(_:)`` と ``directionalLight(_:_:_:_:)`` を自分で並べる。
    ///
    /// **中身は絵で確かめられる。** 下は左から、底上げの光だけ・斜め上から差す光だけ・
    /// ``lights()`` の 3 つ。3 つ目には前の 2 つが両方出ている — **暗い側は 1 つ目と
    /// 同じ明るさで止まり** (底上げの光がそこまでは持ち上げる)、明るい側には 2 つ目と
    /// 同じ向きの傾きが出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     // ① 底上げの光だけ
    ///     ambientLight(.opaque(red: 0.35, green: 0.35, blue: 0.35))
    ///     push()
    ///     translate(70, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     // ② 斜め上から差す光だけ
    ///     noLights()
    ///     directionalLight(.opaque(red: 0.85, green: 0.85, blue: 0.85), -0.35, 0.75, -0.55)
    ///     push()
    ///     translate(200, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     // ③ lights() = ① と ②
    ///     noLights()
    ///     lights()
    ///     push()
    ///     translate(330, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左は陰影の無い円板、中央は右下が黒く落ちた球、右はその 2 つを重ねたように暗い側も残った球 -->
    ///     ![橙色の球が 3 つ。左は陰影の無い円板、中央は右下が黒く落ちた球、右はその 2 つを重ねたように暗い側も残った球](https://i.gyazo.com/7964829651241d7b77827012f9006623.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=8d465f91
    public func lights() { canvas.lights() }

    /// 置いた光をすべて取り除く。以降の立体は塗り 1 色で描かれる。
    ///
    /// **効くのはこれより後に置いたものだけ。** 光を取り除くと列がその場で閉じるので、
    /// 既に置いた立体は光が当たったまま残る。下は同じ球を、取り除く前と後に 1 つずつ
    /// 描いたものである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     lights()
    ///     push()
    ///     translate(120, 150, 0)
    ///     sphere(70)
    ///     pop()
    ///     // ここから先は塗り 1 色になる
    ///     noLights()
    ///     push()
    ///     translate(280, 150, 0)
    ///     sphere(70)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左は陰影の付いた橙色の球、右は同じ大きさだが影も艶も無い、のっぺりした橙色の円 -->
    ///     ![左は陰影の付いた橙色の球、右は同じ大きさだが影も艶も無い、のっぺりした橙色の円](https://i.gyazo.com/82383f6d15fa64608ccda457a94a36ed.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a4494cd7
    public func noLights() { canvas.noLights() }

    // MARK: - モデル

    /// 外で作ったモデルを読む。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var head: Model? -->
    /// ```swift
    /// func setup() {
    ///     head = try? loadModel("assets/head.obj")
    /// }
    /// func draw() {
    ///     lights()
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     rotateY(time * 0.5)
    ///     if let head { model(head) }
    ///     pop()
    /// }
    /// ```
    ///
    /// 読むのは **OBJ (.obj)** だけ。形 (頂点・面・面の向き) だけを読み、材質・
    /// テクスチャ・物体の区切りは読み飛ばす (何行読み飛ばしたかは ``Model/skippedLines``)。
    /// 面の向きが書かれていなければ**形から求める**ので、向きの無いモデルでも
    /// 立体らしく光が付く。
    ///
    /// **既定では、置いたら見える大きさへ整える** (`normalize`)。整えるのは 3 つ —
    /// 中心を原点へ、いちばん長い辺を面の短いほうの半分へ (一様に。軸の比は変わらない)、
    /// 縦軸をこの面の約束 (下向き) へ。`false` を渡すと**ファイルの座標がそのまま**残る。
    ///
    /// **読み込みは投げる。** 失敗したときに別の道を選ぶ判断が要るためで、見つからない
    /// ときの説明には**探した場所**が載る。同じ名前・同じ整え方なら読み直さない。
    ///
    /// - Note: 読めても面が 1 つも無いことがある (``Model/isEmpty``)。そのときは
    ///   投げずに、置いたときに警告する — 「読めなかった」と「読めたが見えない」は
    ///   別の話なので、区別できるようにしてある。
    ///
    /// > Note: この口には例の絵が付いていない。読む先のファイルが要るが、このリポジトリは
    /// > 生成物・バイナリを持たないためである。手元の形で試すなら ``box(_:)`` や
    /// > ``sphere(_:detail:)`` を見ること — そちらには絵が付いている。
    public func loadModel(_ path: String, normalize: Bool = true) throws(ModelFailure) -> Model {
        try canvas.loadModel(path, normalize: normalize)
    }

    /// 外で作ったモデルを読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 解釈を別の仕事として回すので、大きなモデルを読んでもフレームが詰まらない。
    ///
    /// > Note: ``loadModel(_:normalize:)`` と同じ理由で、この口にも例の絵は付いていない。
    public func requestModel(_ path: String, normalize: Bool = true) async throws(ModelFailure)
        -> Model
    {
        try await canvas.requestModel(path, normalize: normalize)
    }

    /// 読み込んだモデルを置く。
    ///
    /// いまの変換と塗りが効く。**続けて同じモデルを置いても描く回数は増えない** —
    /// 頂点は置き直されず、置き場所だけが増える。
    ///
    /// > Note: 置く先のモデルがこのリポジトリに無いので、この口にも例の絵は付いていない。
    /// > 光や材質の効き方は組み込みの立体と同じなので、``sphere(_:detail:)`` の絵が
    /// > そのまま参考になる。
    public func model(_ model: Model) { canvas.model(model) }

    // MARK: - 表面の質感

    /// 艶の鋭さ。**0 なら艶を出さない** (既定)。
    ///
    /// 数が大きいほど艶は小さく鋭くなり、小さいほど広くぼやける — 粗い表面ほど
    /// 小さい数になる。
    ///
    /// ```swift
    /// func draw() {
    ///     lights()
    ///     fill(.display(red: 0.9, green: 0.85, blue: 0.8))
    ///     shininess(64)        // 磨いた面
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     sphere(120)
    ///     pop()
    /// }
    /// ```
    ///
    /// 下は同じ球を、艶の鋭さだけ変えて 3 つ描いたもの。**光の当たる側に白い点が
    /// 現れ、数を上げるほど小さく強くなる。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     noStroke()
    ///     for (index, amount) in [Float(0), 16, 128].enumerated() {
    ///         shininess(amount)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左は艶が無く、中央は広くぼやけた白い光沢、右は小さく鋭い光沢が乗っている -->
    ///     ![橙色の球が 3 つ。左は艶が無く、中央は広くぼやけた白い光沢、右は小さく鋭い光沢が乗っている](https://i.gyazo.com/2130395c3278efb4ccb1caecbed9be5a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    ///   **光を 1 つも置かなければ立体は塗り 1 色で出る**ので、材質はどれも効かない
    ///   (書いてあれば警告が出る)。
    // shot: 1 snippet=976efc57
    public func shininess(_ amount: Float) { canvas.shininess(amount) }

    /// 金属らしさ。`0` が非金属 (既定)、`1` が金属。
    ///
    /// 金属は拡散を持たず、**周りを映すことでしか見えない**。映す先になるのは
    /// ``surroundings(_:)`` で置いた周囲で、それが無ければ ``ambientLight(_:)`` で
    /// 置いた底上げの光を一様な周りとして映す。**どちらも置かずに金属を上げると、
    /// 艶だけが残って暗くなる** (このとき警告が出る)。
    ///
    /// 艶の色も変わる。非金属の艶は光の色のまま白く出るが、金属の艶は塗りの色に
    /// 染まる。
    ///
    /// 下は同じ球を、金属らしさだけ変えて 3 つ描いたもの。光は 1 つも置かず、
    /// ``surroundings(_:)`` だけを置いている。**上げるほど周囲の映り込みが強くなり、
    /// その色は塗りに染まる** — 上下の明暗の差が開き、全体が塗りの色みへ寄っていく。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.06, green: 0.06, blue: 0.07))
    ///     surroundings(.studio)
    ///     noStroke()
    ///     fill(.display(red: 0.90, green: 0.72, blue: 0.45))
    ///     shininess(90)
    ///     for (index, amount) in [Float(0), 0.5, 1].enumerated() {
    ///         metalness(amount)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 球が 3 つ。右へ行くほど上下の明暗の差がはっきりし、色みも濃い黄土色へ寄っていく -->
    ///     ![球が 3 つ。右へ行くほど上下の明暗の差がはっきりし、色みも濃い黄土色へ寄っていく](https://i.gyazo.com/27ab3fd68a1afeddac4bf2ebdbddab1b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=10d0313c
    public func metalness(_ amount: Float) { canvas.metalness(amount) }

    /// 周りの光 (``ambientLight(_:)``) をどれだけ返すか。既定は白 = 全部返す。
    ///
    /// 灰色を渡すとその分だけ返さなくなる — **物陰のように、周りの光が届きにくい
    /// ところを表す**のに使う。塗りに掛かるので、白は何も変えない。
    ///
    /// ```swift
    /// ambient(.display(red: 0.3, green: 0.3, blue: 0.3))   // 周りの光を 3 割だけ返す
    /// ```
    ///
    /// **動くのはほとんど暗い側である。** 下は同じ球を、返す量だけ変えて 3 つ描いた
    /// もの — 陰の側が 6 分の 1 まで落ちるあいだ、直接の光が当たっている側は 1 割ほど
    /// しか下がらない。結果として**陰影は深くなる**。``emissive(_:)`` とはここが逆に
    /// なる (あちらは陰影を浅くする)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     ambientLight(.opaque(red: 0.45, green: 0.45, blue: 0.45))
    ///     directionalLight(.opaque(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     noStroke()
    ///     for (index, level) in [Float(1), 0.5, 0.1].enumerated() {
    ///         ambient(.display(red: level, green: level, blue: level))
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。明るい側はほとんど変わらないまま、陰の側が左から右へ暗く沈んでいく -->
    ///     ![橙色の球が 3 つ。明るい側はほとんど変わらないまま、陰の側が左から右へ暗く沈んでいく](https://i.gyazo.com/310b983eb22e64f26d243bb64a27f7de.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=c2ebed5d
    public func ambient(_ color: LinearRGBA) { canvas.ambient(color) }

    /// 自ら出す光。光が当たっていない側にも同じだけ出る。
    ///
    /// **周りを照らしはしない** — その面が明るく見えるだけで、ほかの立体には届かない。
    /// 明かりそのものを描きたいときは、同じ場所に ``pointLight(_:_:_:_:)`` も置く。
    ///
    /// **足されるのは明暗を問わず同じ量である。** 下は同じ球を、自ら出す光だけ変えて
    /// 3 つ描いたもの — 同じ量でも暗いところほど見た目の変化は大きいので、**陰影は
    /// 浅くなっていく**。``ambient(_:)`` とはここが逆になる (あちらは陰影を深くする)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     ambientLight(.opaque(red: 0.10, green: 0.10, blue: 0.10))
    ///     directionalLight(.opaque(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     noStroke()
    ///     for (index, glow) in [Float(0), 0.15, 0.4].enumerated() {
    ///         emissive(.display(red: glow, green: glow, blue: glow))
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左から右へ、陰の側から先に明るくなり、陰影が浅く平らになっていく -->
    ///     ![橙色の球が 3 つ。左から右へ、陰の側から先に明るくなり、陰影が浅く平らになっていく](https://i.gyazo.com/194cfd9c126347900e037e36cd06e868.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=2550be15
    public func emissive(_ color: LinearRGBA) { canvas.emissive(color) }

    // MARK: - 周囲

    /// 立体を取り巻く周囲を置く。**金属や艶のある面は、これが無いと絵にならない。**
    ///
    /// 周囲は上・地平・下の 3 色の帯で、資材は要らない。置くと 2 つのことが起きる:
    /// 面がその向きに応じて周囲の色を受け取り (上を向いた面は空の色、下を向いた面は
    /// 地面の色)、艶があれば反射の向きの色が映り込む。
    ///
    /// ```swift
    /// func draw() {
    ///     surroundings(.sky)
    ///     background(.sky)        // 背景にも出す (置くのと描くのは別)
    ///     metalness(1)
    ///     shininess(90)
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     sphere(120)
    ///     pop()
    /// }
    /// ```
    ///
    /// **他の設定は何も変わらない** — 底上げの光も露出も、置いたままである。周囲は
    /// 「もう 1 つ置いた光」として足されるだけなので、絵が変わった理由はいつも
    /// 呼び出した行から読める。
    ///
    /// 下は同じ金属の球を、備え付けの 3 つの周囲で照らしたもの。**光は 1 つも
    /// 置いていない** — 映っているのは周囲だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.06, green: 0.06, blue: 0.07))
    ///     noStroke()
    ///     fill(.display(red: 0.90, green: 0.90, blue: 0.90))
    ///     metalness(1)
    ///     shininess(90)
    ///     for (index, around) in [Surroundings.sky, .studio, .sunset].enumerated() {
    ///         surroundings(around)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 金属の球が 3 つ。左は青みがかり、中央は白っぽく、右は橙色を帯びている -->
    ///     ![金属の球が 3 つ。左は青みがかり、中央は白っぽく、右は橙色を帯びている](https://i.gyazo.com/64d536a3e60c48f0acd8a3909b0c180b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 周囲は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=8533681f
    public func surroundings(_ surroundings: Surroundings) {
        canvas.surroundings(surroundings)
    }

    /// 周囲を背景として描く。いまの視点から見た周囲がそのまま出る。
    ///
    /// **置くのと描くのは別である。** ``surroundings(_:)`` を呼ばずにこれだけを呼べば
    /// 背景にだけ出て、映り込みには効かない。逆も同じ。片方を呼んだらもう片方も、
    /// という親切は入れていない。
    ///
    /// 背景と映り込みは**同じ 1 本の式から読む**ので、上下・左右がずれることはない。
    ///
    /// **別なので、食い違わせることもできる。** 下は背景に空を描きながら、映り込む
    /// 周囲には夕暮れを置いたもの — 背景は青いのに、球には橙が映る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     // 背景に描くのは空
    ///     background(.sky)
    ///     // 映り込むのは夕暮れ
    ///     surroundings(.sunset)
    ///     noStroke()
    ///     fill(.display(red: 0.90, green: 0.90, blue: 0.90))
    ///     metalness(1)
    ///     shininess(90)
    ///     push()
    ///     translate(200, 150, 0)
    ///     sphere(105)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 青白い空を背にした金属の球。球に映っているのは空ではなく、橙色の夕暮れ | symmetric=x -->
    ///     ![青白い空を背にした金属の球。球に映っているのは空ではなく、橙色の夕暮れ](https://i.gyazo.com/8cdda6b7abb3c91fcb511032b5f668d7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b19cc57e
    public func background(_ surroundings: Surroundings) {
        canvas.background(surroundings)
    }

    // MARK: - 影

    /// 影を落とすかどうか。既定は落とさない。
    ///
    /// 落とすのは**置いてあるうちの最初の向きを持つ光** (``directionalLight(_:_:_:_:)``)
    /// で、その光から見た奥行きを 1 枚焼いてから画面を描く。
    ///
    /// ```swift
    /// func draw() {
    ///     lights()
    ///     shadows(true)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     push()
    ///     translate(width / 2, height * 0.8, 0)
    ///     box(400, 10, 400)
    ///     pop()
    ///     castShadow(true)
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     sphere(80)
    ///     pop()
    /// }
    /// ```
    ///
    /// **影が減らすのは直接の光だけ**である。影の中でも、``ambientLight(_:)`` の光・
    /// ``surroundings(_:)`` の光・``emissive(_:)`` の自発光は残り、``ambient(_:)`` は
    /// 影の内外を問わず効く。
    ///
    /// 下はこのあとの 3 枚と同じ場面で、影の設定を何も足していないもの。比べるときの
    /// 基準になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(.display(red: 0.75, green: 0.75, blue: 0.78))
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 見下ろした灰色の床の上に橙色の球が浮かび、床の左奥にその影が落ちている -->
    ///     ![見下ろした灰色の床の上に橙色の球が浮かび、床の左奥にその影が落ちている](https://i.gyazo.com/c14865869e0a99b600596cad935e0124.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 影は**フレームを越えない**。`draw()` の中で毎フレーム書く。毎フレーム
    ///   書いても焼き付け先は作り直さないので、繰り返しの負担にはならない。
    // shot: 1 snippet=17289524
    public func shadows(_ enabled: Bool) { canvas.shadows(enabled) }

    /// 影を焼き付ける範囲の一辺 (世界の長さ)。
    ///
    /// **影の細かさは世界の大きさに依る。** 焼き付け先の広さは決まっているので、
    /// 広い範囲を焼けばそのぶん粗くなる。何も指定しなければ**面の対角の長さ**を使う
    /// ので、画素と同じ尺度で作るスケッチはそのままで合う。
    ///
    /// ずっと小さい世界 (1 単位を 1 メートルとして数十単位、など) を作るときは、
    /// その世界に合わせた長さを渡す。渡さないと影が数画素に潰れる。
    ///
    /// **粗さを決めるのは 範囲 ÷ 画素数**である。下は ``shadows(_:)`` と同じ場面で
    /// 範囲だけを広げたもので、``shadowDetail(_:)`` を下げたときと同じ形の粗さが出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 面の対角 (既定) よりずっと広い範囲を焼く
    ///     shadowRange(8000)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(.display(red: 0.75, green: 0.75, blue: 0.78))
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ場面だが、影の縁が階段状にがたつき、影がひとまわり痩せている -->
    ///     ![同じ場面だが、影の縁が階段状にがたつき、影がひとまわり痩せている](https://i.gyazo.com/95e2213c287a8493be11b1f160ce0a70.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=55bb3714
    public func shadowRange(_ size: Float) { canvas.shadowRange(size) }

    /// 影を焼き付ける面の一辺の画素数。既定は 1024。
    ///
    /// 大きくすると縁が細かくなり、そのぶん焼くのに時間がかかる。**同じ数を渡し
    /// 続けるかぎり、焼き付け先は作り直されない。**
    ///
    /// 下は ``shadows(_:)`` と同じ場面で、画素数だけを落としたもの。``shadowRange(_:)``
    /// を広げたときと同じ粗さになる — **効いているのは 範囲 ÷ 画素数の比**だからである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 下限まで落とす (64...4096 の範囲を取る)
    ///     shadowDetail(64)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(.display(red: 0.75, green: 0.75, blue: 0.78))
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 範囲を広げた絵とまったく同じ粗さで、影の縁が階段状にがたついている -->
    ///     ![範囲を広げた絵とまったく同じ粗さで、影の縁が階段状にがたついている](https://i.gyazo.com/df96ed6e41c9ed077b68cecb9b3cf09a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=48cf482c
    public func shadowDetail(_ size: Int) { canvas.shadowDetail(size) }

    /// 影の縁の破綻を抑える量。既定は `0.0025`。
    ///
    /// 焼いた 1 画素の中で奥行きが変わるので、そのままだと**自分の影が自分の上に
    /// 縞として出る**。それを避けるための余裕で、大きくしすぎると影が形から離れて
    /// 浮いて見える。
    ///
    /// 下は ``shadows(_:)`` と同じ場面で、余裕を 0 にしたもの。**球の明るい側に、
    /// 自分の影が細かい縞になって浮く** — これが避けようとしている破綻である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     // 少し上から見下ろす
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 余裕を外すと破綻が出る (既定は 0.0025)
    ///     shadowBias(0)
    ///     // 床は受けるだけにしておく (自分の影が自分に出ない)
    ///     castShadow(false)
    ///     fill(.display(red: 0.75, green: 0.75, blue: 0.78))
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     castShadow(true)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(180, 120, 20)
    ///     sphere(75)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ場面だが、球の明るい側に細かい縞状の汚れが浮いている -->
    ///     ![同じ場面だが、球の明るい側に細かい縞状の汚れが浮いている](https://i.gyazo.com/8d49bfb070bb93f481a2a7a848ef6bef.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=c92ffd08
    public func shadowBias(_ amount: Float) { canvas.shadowBias(amount) }

    /// これから置く形が、影を落とす側か。既定は落とす。
    ///
    /// 床のように「受けるだけ」の形は落とす側から外す。**全体を切るしか無いと、
    /// 自己遮蔽の強い形を置いた作品が影ごと諦めることになる。**
    ///
    /// **形ごとに決まる。** 下は同じ高さに球を 2 つ置き、右だけを落とす側から外した
    /// もの — 影は左の球のぶんしか出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     castShadow(false)
    ///     fill(.display(red: 0.75, green: 0.75, blue: 0.78))
    ///     push()
    ///     translate(200, 250, -20)
    ///     box(400, 8, 300)
    ///     pop()
    ///     // 左の球だけが影を落とす
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     for (index, casts) in [true, false].enumerated() {
    ///         castShadow(casts)
    ///         push()
    ///         translate(130 + Float(index) * 145, 120, 20)
    ///         sphere(60)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 床の上に橙色の球が 2 つ並び、影は左の球の下にだけ落ちている -->
    ///     ![床の上に橙色の球が 2 つ並び、影は左の球の下にだけ落ちている](https://i.gyazo.com/3ffbff84eee487311590fabd018885a4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3bf54063
    public func castShadow(_ enabled: Bool) { canvas.castShadow(enabled) }

    /// これから置く形が、影を受ける側か。既定は受ける。
    ///
    /// **落とす側と同じく、形ごとに決まる。** 下は床を 2 枚に割って右だけを受ける側
    /// から外し、それぞれの上に球を置いたもの — 落ちている影は左の床にしか出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     camera(200, -70, 320, 200, 200, 0, 0, 1, 0)
    ///     lights()
    ///     shadows(true)
    ///     noStroke()
    ///     // 床を 2 枚。右の 1 枚だけ受ける側から外す
    ///     castShadow(false)
    ///     fill(.display(red: 0.75, green: 0.75, blue: 0.78))
    ///     for (index, receives) in [true, false].enumerated() {
    ///         receiveShadow(receives)
    ///         push()
    ///         translate(102 + Float(index) * 196, 250, -20)
    ///         box(188, 8, 300)
    ///         pop()
    ///     }
    ///     receiveShadow(true)
    ///     // 球は 2 つとも同じように落とす
    ///     castShadow(true)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     for index in 0..<2 {
    ///         push()
    ///         translate(135 + Float(index) * 145, 120, 20)
    ///         sphere(60)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 2 枚に割れた床の上に橙色の球が 2 つ。影が出ているのは左の床だけで、右の床は継ぎ目から先が一様に明るい -->
    ///     ![2 枚に割れた床の上に橙色の球が 2 つ。影が出ているのは左の床だけで、右の床は継ぎ目から先が一様に明るい](https://i.gyazo.com/ef2bac62139783c79bfd8f6d6ef1ab3c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=6a405215
    public func receiveShadow(_ enabled: Bool) { canvas.receiveShadow(enabled) }

    // MARK: - 乱数と揺らぎ

    /// 0 以上 1 未満の値。**呼ぶたびに列が進む。**
    ///
    /// **種を決めなくても、走らせるたびに同じ列が出る。** 時刻から種を作らないため
    /// ([ADR-0001] 原則 2)。毎回ちがう絵が欲しければ、変わる値を ``randomSeed(_:)``
    /// へ渡す。
    ///
    /// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
    public func random() -> Float { Self.requireRuntime().randomness.unitValue() }

    /// 0 以上 `high` 未満の値。`high` が負なら `high` 以上 0 未満。
    public func random(_ high: Float) -> Float {
        Self.requireRuntime().randomness.value(from: 0, to: high)
    }

    /// `low` 以上 `high` 未満の値。**順序が逆でも受け取る。**
    public func random(_ low: Float, _ high: Float) -> Float {
        Self.requireRuntime().randomness.value(from: low, to: high)
    }

    /// 乱数の種。同じ種を置いてから同じ順に呼べば、いつでも同じ列が出る。
    ///
    /// **列は ``draw()`` を越えて進み続ける。** フレームの頭で戻したいなら、
    /// そのフレームの頭でこれを呼ぶ。
    public func randomSeed(_ seed: Int) { Self.requireRuntime().randomness = Randomness(seed: seed) }

    /// その座標の揺らぎ (0…1)。**近い座標には近い値**が返る、なめらかな乱れ。
    ///
    /// ``random()`` と違って列ではないので、**同じ座標には何度呼んでも同じ値**が
    /// 返る。フレームをまたいで安定した模様は、これで描く。
    ///
    /// ```swift
    /// for x in stride(from: 0, to: width, by: 4) {
    ///     let y = noise(x * 0.01) * height
    ///     circle(x, y, 3)
    /// }
    /// ```
    ///
    /// **断片からも同じ値が引ける。** 利用者が書いた塗りの中で `mokume_noise(in, p)`
    /// と書くと、``noiseSeed(_:)`` で決めた同じ種の同じ揺らぎが出る — 面と立体で
    /// 同じ模様を出すのに、揺らぎを 2 つ別々に持たなくてよい。
    ///
    /// 座標として扱えるのは ±1e6 くらいまで。それを超えると模様は破綻するが、
    /// 落ちはしない (数でない座標には 0 が返る)。
    public func noise(_ x: Float, _ y: Float = 0, _ z: Float = 0) -> Float {
        canvas.noise(x, y, z)
    }

    /// 揺らぎの種。**断片にも同じ種が届く**ので、配線しなくてよい。
    ///
    /// 乱数の種 (``randomSeed(_:)``) とは別に持つ。片方を決め直しても、もう片方の
    /// 模様は動かない。
    public func noiseSeed(_ seed: Int) { canvas.noiseSeed(seed) }

    /// 揺らぎの細かさ — 重ねる枚数 `lod` と、1 枚ごとの弱まり `falloff`。
    ///
    /// 枚数を増やすほど細かい乱れが乗り、弱まりを大きくするほど細かいほうが目立つ。
    /// 既定は 4 枚・0.5。枚数は 1…16、弱まりは 0…1 で、外れた値は無視して知らせる。
    ///
    /// **断片にも同じ細かさが届く。**
    public func noiseDetail(_ lod: Int, _ falloff: Float = 0.5) {
        canvas.noiseDetail(lod, falloff)
    }

    // MARK: - 明るさを画面へ写す

    /// 画面全体の明るさの倍率。既定は `1`。
    ///
    /// **画面の性質なので、材質や光と違ってフレームを越える** — 一度書けば書き換える
    /// まで残る。効くのは**画面から出て行く絵すべて**で、窓に出る絵と書き出した絵の
    /// 両方に同じだけ掛かる。``loadPixels()`` で読む画素には掛からない (そちらは
    /// 写す前の作業空間そのものである)。
    ///
    /// ```swift
    /// func setup() {
    ///     exposure(1.6)   // 全体を明るく写す。描く色は変えない
    /// }
    /// ```
    public func exposure(_ multiplier: Float) { canvas.exposure(multiplier) }

    /// 表示できる範囲を超えた明るさの丸め方。既定は ``ToneMapping/clip``。
    ///
    /// 既定では**範囲の内側の明るさを 1 ビットも変えない** — `0.5` と書いた色が
    /// 指定どおりの明るさで出る。その代わり、範囲を超えたところは端で切れるので、
    /// 強い艶や明るい光が一様な白い塊になる。``ToneMapping/roll`` を選ぶと、
    /// 明るいところがなめらかに範囲へ収まる代わりに、`0.8` より明るいところが
    /// 指定より少し暗く出る。
    ///
    /// - Note: ``exposure(_:)`` と同じく**画面の性質**で、フレームを越える。
    public func toneMapping(_ mode: ToneMapping) { canvas.toneMapping(mode) }

    // MARK: - 立体

    /// 立方体を置く。
    ///
    /// 中心は原点で、大きさは画素で数える。**何も指定しなければ画素の大きさで
    /// 見える** — 既定の視点は面がちょうど収まる位置に置いてあるので、`box(120)` は
    /// 120 画素の箱として出る。動かすには ``translate(_:_:_:)`` と ``rotateY(_:)``
    /// などを重ねる。
    ///
    /// ```swift
    /// func draw() {
    ///     background(.display(red: 0.08, green: 0.09, blue: 0.12))
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.3))
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     rotateY(0.6)
    ///     box(120)
    ///     pop()
    /// }
    /// ```
    ///
    /// - Note: 光を 1 つも置かなければ塗り 1 色で出る。立体らしく見せるには
    ///   ``lights()`` を `draw()` の中で呼ぶ。
    ///
    /// **面ごとに明るさが違う**ので、同じ塗り 1 色でも角が読める。下の絵はどれも
    /// ``lights()`` を置き、面のまん中へ運んでから斜めに回して見ている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     box(150)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の立方体が斜めから見えている。3 つの面がそれぞれ違う明るさで出ている -->
    ///     ![橙色の立方体が斜めから見えている。3 つの面がそれぞれ違う明るさで出ている](https://i.gyazo.com/56a5f1c0d17a1ffbcb60318114ce1ebb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=89bfb603
    public func box(_ size: Float) { canvas.box(size) }

    /// 幅・高さ・奥行きを別々に決めた箱を置く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     box(230, 80, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横に長く薄い橙色の板。斜めから見えていて、奥行きが薄いことが分かる -->
    ///     ![横に長く薄い橙色の板。斜めから見えていて、奥行きが薄いことが分かる](https://i.gyazo.com/665028f152b9a87a181549c6754205ee.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=23718862
    public func box(_ width: Float, _ height: Float, _ depth: Float) {
        canvas.box(width, height, depth)
    }

    /// 球を置く。
    ///
    /// **`detail` を落とすと面が見えてくる。** 下の 2 枚は同じ半径で、割り方だけを
    /// 変えている (既定は 24)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     sphere(110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球。左上から光が当たり、右下へ向かって暗くなっている -->
    ///     ![橙色の球。左上から光が当たり、右下へ向かって暗くなっている](https://i.gyazo.com/b05b424da02517dd96374ae6a694a5ef.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     sphere(110, detail: 6)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの立体だが、面が数えられるほど粗く、丸みが多角形になっている -->
    ///     ![同じ大きさの立体だが、面が数えられるほど粗く、丸みが多角形になっている](https://i.gyazo.com/f7b3f1ebc4f0c232108c9af02ca7ff2d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 上下は半周なので、その半分で割る。
    // shot: 1 snippet=e0b936c2
    // shot: 2 snippet=d021273a
    public func sphere(_ radius: Float, detail: Int = Canvas.defaultSolidDetail) {
        canvas.sphere(radius, detail: detail)
    }

    /// 平らな面を置く。画面の側を向く。
    ///
    /// 奥行き 0 に置いた面は、同じ座標に描いた ``rect(_:_:_:_:)`` とぴったり重なる。
    /// **傾けると空間の中の 1 枚として見える** — 厚みは無いので、真横から見れば消える。
    /// 面が 1 つしか無いぶん**明るさは一様**になり、傾きは輪郭の形にだけ出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     plane(220, 160)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の 1 枚の面。面が 1 つしか無いので明るさは一様で、傾きは輪郭が長方形でないことにだけ出ている -->
    ///     ![橙色の 1 枚の面。面が 1 つしか無いので明るさは一様で、傾きは輪郭が長方形でないことにだけ出ている](https://i.gyazo.com/644b718dbb347e8337bb843acc8a84a6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=9aeefd09
    public func plane(_ width: Float, _ height: Float) { canvas.plane(width, height) }

    /// 円柱を置く。軸は縦。
    ///
    /// こちらも `detail` を落とすと面が見えてくる。下の 2 枚は同じ寸法で、割り方だけを
    /// 変えている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     cylinder(80, 180)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円柱が斜めに立っていて、上の蓋が楕円に見えている -->
    ///     ![橙色の円柱が斜めに立っていて、上の蓋が楕円に見えている](https://i.gyazo.com/563c968f429d67974de3ea69f6596365.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     cylinder(80, 180, detail: 6)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ寸法だが一周が 6 つに割られ、六角柱になっている -->
    ///     ![同じ寸法だが一周が 6 つに割られ、六角柱になっている](https://i.gyazo.com/08a4787b75e86f5973c5698f118904b5.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    // shot: 1 snippet=d5dd0e40
    // shot: 2 snippet=0d372704
    public func cylinder(
        _ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail
    ) {
        canvas.cylinder(radius, height, detail: detail)
    }

    /// 円錐を置く。軸は縦で、先は上を向く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     cone(90, 190)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円錐が斜めに立っていて、先が上を向き、底の円が楕円に見えている -->
    ///     ![橙色の円錐が斜めに立っていて、先が上を向き、底の円が楕円に見えている](https://i.gyazo.com/c5c1d800f172015c2f31a6e644550948.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 底の半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    // shot: 1 snippet=629b0d9b
    public func cone(_ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail) {
        canvas.cone(radius, height, detail: detail)
    }

    /// 輪を置く。穴は画面の側を向く。
    ///
    /// **2 つの半径のうち、後ろが管の太さである。** 下の 2 枚は輪の大きさを変えずに、
    /// 管だけを太くしている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     torus(100, 20)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の細い輪が斜めに傾いていて、中央に大きな穴が空いている -->
    ///     ![橙色の細い輪が斜めに傾いていて、中央に大きな穴が空いている](https://i.gyazo.com/8069cdfa773d799bcd1da70f459ca73e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     lights()
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     translate(200, 150, 0)
    ///     rotateY(0.6)
    ///     rotateX(0.35)
    ///     torus(100, 50)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの輪だが管が太く、中央の穴が小さくなっている -->
    ///     ![同じ大きさの輪だが管が太く、中央の穴が小さくなっている](https://i.gyazo.com/da3b4140dcdb6e812a690063f594ad02.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Parameters:
    ///   - radius: 中心から管の中心までの距離 (画素)。
    ///   - tubeRadius: 管の半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 輪の一周も管の一周も同じ数で割る。
    // shot: 1 snippet=63060d33
    // shot: 2 snippet=6b681e80
    public func torus(
        _ radius: Float, _ tubeRadius: Float, detail: Int = Canvas.defaultSolidDetail
    ) {
        canvas.torus(radius, tubeRadius, detail: detail)
    }

    /// 積んでおいたスタイルへ戻す。積んでいなければ何もしない。
    public func popStyle() { canvas.popStyle() }

    /// 変換とスタイルの**両方**を積んでおく。
    ///
    /// 片方だけを積みたいときは ``pushMatrix()`` / ``pushStyle()`` を使う。
    ///
    /// **``pushMatrix()`` との違いは、色や線の太さも一緒に戻ること。** 下の例は挟んだ
    /// 中で原点も色も太さも変えているが、``pop()`` の後の四角は**どれも元のまま**で
    /// 描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.55, green: 0.60, blue: 0.70))
    ///     strokeWeight(3)
    ///     translate(110, 150)
    ///     push()
    ///     translate(180, 0)
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(12)
    ///     square(-45, -45, 90)
    ///     pop()
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 右に太い橙色の枠の正方形、左に細い灰色の枠の正方形が並んでいる | symmetric=y -->
    ///     ![右に太い橙色の枠の正方形、左に細い灰色の枠の正方形が並んでいる](https://i.gyazo.com/5aa73f26bc698ad8e1edd3827d3c74f1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=92c18fef
    public func push() { canvas.push() }

    /// 積んでおいた変換とスタイルの両方へ戻す。積んでいなければ何もしない。
    ///
    /// **``push()`` と対で使う。** 積んでいないときに呼んでも落ちず、何もせず進む。
    /// 下の例は 2 段積んで 2 段戻しているので、3 つの四角がそれぞれ別の段の状態で
    /// 描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     translate(80, 150)
    ///     fill(.display(red: 0.55, green: 0.60, blue: 0.70))
    ///     push()
    ///     translate(120, 0)
    ///     fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     push()
    ///     translate(120, 0)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     square(-35, -35, 70)
    ///     pop()
    ///     square(-35, -35, 70)
    ///     pop()
    ///     square(-35, -35, 70)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰・橙・水色の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる | symmetric=y -->
    ///     ![灰・橙・水色の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる](https://i.gyazo.com/8cde6942eb1b51e484e0a87fd113a1ad.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a8da334a
    public func pop() { canvas.pop() }

    // MARK: - 文字

    /// 文字列を描く。
    ///
    /// `y` が何を指すかは ``textAlign(_:_:)`` が決める。既定は**基準線** — 字が乗る線で、
    /// `g` や `y` の下へ伸びる部分はここより下に出る (下の絵の灰色の線が基準線)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(0, 170, 400, 170)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(56)
    ///     text("mokume", 40, 170)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の横線のちょうど上に、白い大きな mokume が乗っている -->
    ///     ![灰色の横線のちょうど上に、白い大きな mokume が乗っている](https://i.gyazo.com/6bfff58c6f3b88d797718b12e60c9022.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **改行で行が分かれる。** 行の間隔は ``textLeading(_:)`` が決める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(40)
    ///     text("mokume\nmetal", 40, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い文字が 2 行に分かれ、左端を揃えて縦に並んでいる -->
    ///     ![白い文字が 2 行に分かれ、左端を揃えて縦に並んでいる](https://i.gyazo.com/027952e745878babd9d7310e3d842ef9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **塗りの色で描く**ので、``noFill()`` の状態では何も出ない。
    // shot: 1 snippet=11c9d2b4
    // shot: 2 snippet=361f9ffa
    public func text(_ string: String, _ x: Float, _ y: Float) { canvas.text(string, x, y) }

    /// これから描く文字の大きさ (画素)。既定は 12。
    ///
    /// 行送りを指定していなければ、行の間隔もこの値から決まる。
    /// 下の 2 枚は同じ基準線 (灰色の横線) の上に置いてある。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(0, 200, 400, 200)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(24)
    ///     text("mokume", 40, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の線の上に、小さめの白い mokume が乗っている -->
    ///     ![灰色の線の上に、小さめの白い mokume が乗っている](https://i.gyazo.com/9a963c8a9130fa24838a42cefe99e710.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(0, 200, 400, 200)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(64)
    ///     text("mokume", 40, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ位置の灰色の線の上に、ずっと大きな白い mokume が乗っている -->
    ///     ![同じ位置の灰色の線の上に、ずっと大きな白い mokume が乗っている](https://i.gyazo.com/c193cb2547db95504c8d1e7ac0865a1c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=7e61e41a
    // shot: 2 snippet=a1eaa157
    public func textSize(_ size: Float) { canvas.textSize(size) }

    /// これから描く文字の書体。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(34)
    ///     text("mokume 123", 30, 110)
    ///     textFont("Courier")
    ///     text("mokume 123", 30, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ語が 2 行。上は既定の書体、下は字幅の揃った書体で描かれている -->
    ///     ![同じ語が 2 行。上は既定の書体、下は字幅の揃った書体で描かれている](https://i.gyazo.com/0ed7b61b333d5d35b83cf5ec3082122a.png)
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
    // shot: 1 snippet=8ee18157
    public func textFont(_ name: String) { canvas.textFont(name) }

    /// 書体の指定をやめ、この環境の既定の書体へ戻す。
    ///
    /// 下の絵の **1 行目と 3 行目は同じ書体**である — 間で ``textFont(_:)`` を挟んでも、
    /// 戻せば元に帰る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
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
    ///     ![同じ語が 3 行。1 行目と 3 行目は同じ書体で、真ん中の 1 行だけ違う](https://i.gyazo.com/ebe920bd60120ef4be9a91d7409f7211.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=bdbf4551
    public func noTextFont() { canvas.noTextFont() }

    /// これから描く文字の太さと傾き。既定はそのまま。
    ///
    /// **4 通りを 1 枚に並べてある** — 別々の絵にすると、どれも「白い字がある」絵に
    /// なって見比べられないためである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(18)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     text("normal", 20, 70)
    ///     text("bold", 20, 135)
    ///     text("italic", 20, 200)
    ///     text("boldItalic", 20, 265)
    ///     textSize(44)
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
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
    ///     ![左に水色の指定名、右に白い Mokume が 4 行。下 2 行は右へ傾き、2 行目と 4 行目は画が太い](https://i.gyazo.com/afb42350b56971b8be3665c8ea2da73c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=00a4bd2e
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(200, 0, 200, 300)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
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
    ///     ![1 本の縦線に対し、右へ出る・線をまたぐ・線で終わる の 3 語が上から並んでいる](https://i.gyazo.com/832ef217b81799dec8e4dc6b53e91fc0.png)
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(0, 150, 400, 150)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
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
    ///     ![1 本の横線に対し、下へぶら下がる・線をまたぐ・線に乗る・線の上に載る の 4 語が左から並んでいる](https://i.gyazo.com/f8976a14a1bb15eb04bc126245d4de59.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=89de4578
    // shot: 2 snippet=c4ea8b65
    public func textAlign(
        _ horizontal: HorizontalTextAlign, _ vertical: VerticalTextAlign = .baseline
    ) {
        canvas.textAlign(horizontal, vertical)
    }

    /// 行と行の間隔 (画素)。指定しなければ大きさの 1.25 倍。
    ///
    /// 下の 2 枚は同じ 3 行を、同じ大きさで、同じ位置から描いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(28)
    ///     text("one\ntwo\nthree", 40, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い 3 行が、詰まった間隔で縦に並んでいる -->
    ///     ![白い 3 行が、詰まった間隔で縦に並んでいる](https://i.gyazo.com/ab0be0edb70be3204d0e2c72821539ec.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(28)
    ///     textLeading(70)
    ///     text("one\ntwo\nthree", 40, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 3 行が、倍ほど離れた間隔で縦に並んでいる -->
    ///     ![同じ 3 行が、倍ほど離れた間隔で縦に並んでいる](https://i.gyazo.com/cc20d16f281696966191c89fbfa3eb09.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a559294d
    // shot: 2 snippet=b071867c
    public func textLeading(_ leading: Float) { canvas.textLeading(leading) }

    /// 文字列を描いたときの幅 (画素)。
    ///
    /// **1 文字ずつの送り幅の合計**なので、部分に切って足すと全体と一致する。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(44)
    ///     text("mokume", 40, 150)
    ///     let w = textWidth("mokume")
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(3)
    ///     line(40, 168, 40 + w, 168)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い mokume のすぐ下に、語と同じ長さの橙色の線が引かれている -->
    ///     ![白い mokume のすぐ下に、語と同じ長さの橙色の線が引かれている](https://i.gyazo.com/e781eaf7128c2bc83a5dd33d93b65a09.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=d0ab3923
    public func textWidth(_ string: String) -> Float { canvas.textWidth(string) }

    /// 基準線から上へ伸びる高さ (画素)。
    ///
    /// **書体が持つ値で、いま描く文字列には依らない。** どんな字を渡してもこの高さより
    /// 上へは出ない (下の絵の水色の線)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     textSize(64)
    ///     let base: Float = 200
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(0, base, 400, base)
    ///     stroke(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     strokeWeight(2)
    ///     line(0, base - textAscent(), 400, base - textAscent())
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     text("Mokume", 40, base)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の基準線に字が乗り、その上に引かれた水色の線を字が越えていない -->
    ///     ![灰色の基準線に字が乗り、その上に引かれた水色の線を字が越えていない](https://i.gyazo.com/fd7a39121db7a5eb2a4a236b13f4a01d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a6eb7f98
    public func textAscent() -> Float { canvas.textAscent() }

    /// 基準線から下へ伸びる深さ (画素)。
    ///
    /// こちらも書体が持つ値。`g` や `y` のように基準線の下へ伸びる字も、この深さより
    /// 下へは出ない (下の絵の橙色の線)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     textSize(64)
    ///     let base: Float = 150
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     line(0, base, 400, base)
    ///     stroke(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///     strokeWeight(2)
    ///     line(0, base + textDescent(), 400, base + textDescent())
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     text("mokugy", 40, base)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の基準線から g と y が下へ伸び、その先を橙色の線が受け止めている -->
    ///     ![灰色の基準線から g と y が下へ伸び、その先を橙色の線が受け止めている](https://i.gyazo.com/8f7f757454acd91ab42d06605c61e75b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=798b905e
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     let long = "矩形へ流し込むと、指定した幅で折り返し、指定した高さに収まる行だけが置かれる。入りきらなかった分は remainder に残るので、続きを別の場所へ流せる。"
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     rect(30, 40, 160, 220)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(18)
    ///     text(long, 30, 40, 160, 220)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の縦長の枠の中に、折り返された白い日本語の文が収まっている -->
    ///     ![灰色の縦長の枠の中に、折り返された白い日本語の文が収まっている](https://i.gyazo.com/21d9dfe8844b5743d5dd2ac6c0a10340.png)
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
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     let long = "矩形へ流し込むと、指定した幅で折り返し、指定した高さに収まる行だけが置かれる。入りきらなかった分は remainder に残るので、続きを別の場所へ流せる。"
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     rect(20, 40, 170, 100)
    ///     rect(210, 40, 170, 100)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(18)
    ///     let flow = text(long, 20, 40, 170, 100)
    ///     fill(.display(red: 0.35, green: 0.75, blue: 0.95))
    ///     text(flow.remainder, 210, 40, 170, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左の枠に白い文が収まり、右の枠にその続きが水色で流れている -->
    ///     ![左の枠に白い文が収まり、右の枠にその続きが水色で流れている](https://i.gyazo.com/a57da60dddbf2fe85ff8ce27aa9680a3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 返る値は「何行置いたか・どれだけの高さを使ったか・何が残ったか」。**続きを
    /// どこから描くかを自分で数え直さずに済む**ように返している。
    ///
    /// 縦の指定 (``textAlign(_:_:)``) は置いた塊全体に効く。矩形の中では基準線に
    /// 意味が無いので、基準線指定は上揃えと同じに扱う。
    // shot: 1 snippet=5f51171b
    // shot: 2 snippet=c5aeaa7d
    @discardableResult
    public func text(_ string: String, _ a: Float, _ b: Float, _ c: Float, _ d: Float)
        -> TextFlow
    {
        canvas.text(string, a, b, c, d)
    }

    /// 幅に収まらなくなったとき、どこで行を折るか。既定は語の切れ目。
    ///
    /// 下の 2 枚は同じ文を同じ枠へ流している。**語で折ると行末が不揃いになり、
    /// 文字で折ると枠の右辺で揃う。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     let words = "mokume renders declarative sketches"
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     rect(60, 50, 150, 200)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(20)
    ///     textWrap(.word)
    ///     text(words, 60, 50, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 枠の中の英文が語の切れ目で折り返され、行末が不揃いになっている -->
    ///     ![枠の中の英文が語の切れ目で折り返され、行末が不揃いになっている](https://i.gyazo.com/5845d1221557dd0cd1e52136478c67a7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     let words = "mokume renders declarative sketches"
    ///     noFill()
    ///     stroke(.display(red: 0.35, green: 0.38, blue: 0.45))
    ///     strokeWeight(1)
    ///     rect(60, 50, 150, 200)
    ///     noStroke()
    ///     fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///     textSize(20)
    ///     textWrap(.character)
    ///     text(words, 60, 50, 150, 200)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ英文が文字の切れ目で折り返され、行末が枠の右辺近くで揃っている -->
    ///     ![同じ英文が文字の切れ目で折り返され、行末が枠の右辺近くで揃っている](https://i.gyazo.com/ce2fa802eb9d76da9d61b785a5111013.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 語の切れ目で折るとき、**1 語が幅より長ければその語の中で折る** —
    /// でないと置き場所が無くなる。
    // shot: 1 snippet=6d98185f
    // shot: 2 snippet=874d4026
    public func textWrap(_ mode: TextWrap) { canvas.textWrap(mode) }

    /// 文字列の輪郭を取り出す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     noFill()
    ///     stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
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
    ///     ![黄色い線だけで縁取られた mokume — 画の内側は塗られていない](https://i.gyazo.com/ce06383d7ffd37ad69775c5d89c958bb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **描くときと同じ送り**で並ぶので、``text(_:_:_:)`` と同じ位置・同じ字間になる。
    /// 返る点はいまの座標のままで、変換は掛かっていない。
    ///
    /// 字ごとに、外側の周が先・穴が後の順で並ぶ。曲線は直線の並びにほどいてあり、
    /// 細かさは曲線の大きさから決まる。
    // shot: 1 snippet=f29666de
    public func textOutline(_ string: String, _ x: Float, _ y: Float) -> [TextContour] {
        canvas.textOutline(string, x, y)
    }

    // MARK: - 画像

    /// 絵を読む。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var grain: Image? -->
    /// ```swift
    /// func setup() {
    ///     grain = try? loadImage("assets/grain.png")
    /// }
    /// ```
    ///
    /// **読み込みは投げる。** 読めなかったときに別の道を選ぶ判断が要るので、黙って
    /// 既定へ倒さない。見つからないときの説明には**探した場所**が載る。
    ///
    /// > Note: この口には例の絵が付いていない。読む先のファイルが要るが、このリポジトリは
    /// > 生成物・バイナリを持たないためである。絵を手続きで作るなら ``createImage(_:_:)``
    /// > か ``createGraphics(_:_:)`` を見ること — そちらには絵が付いている。
    ///
    /// 名前は、作業ディレクトリと**実行ファイルの隣に置かれた資材の包み**から探す。
    /// スケッチのパッケージが資材の置き場を宣言していないと、ビルドは静かに通って
    /// 実行時に読めないだけになるので、宣言を確かめること。
    public func loadImage(_ path: String) throws(ImageFailure) -> Image {
        try canvas.loadImage(path)
    }

    /// 絵を読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 復号を別の仕事として回すので、大きな絵を読んでもフレームが詰まらない。
    ///
    /// > Note: ``loadImage(_:)`` と同じ理由で、この口にも例の絵は付いていない。
    public func requestImage(_ path: String) async throws(ImageFailure) -> Image {
        try await canvas.requestImage(path)
    }

    /// 空の絵を作る。中身は透明。
    ///
    /// ``Image/set(_:_:_:)`` で書き換えると、**描くときに自動で送られる** —
    /// 送り直しを呼び忘れて絵が変わらない、という形の不具合が起きない。
    ///
    /// **投げるので `setup()` で作って持ち回る。** 下の例は 16 画素四方の絵を 1 度だけ
    /// 作り、毎フレーム大きく引き伸ばして置いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(16, 16)
    ///         for y in 0..<16 {
    ///             for x in 0..<16 {
    ///                 tile.set(x, y, .display(
    ///                     red: Float(x) / 15, green: 0.35, blue: Float(y) / 15))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(tile, 80, 30, 240, 240)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 16 画素四方の絵を大きく置いたもの。右へ行くほど赤く、下へ行くほど青い -->
    ///     ![16 画素四方の絵を大きく置いたもの。右へ行くほど赤く、下へ行くほど青い](https://i.gyazo.com/23113a03912ea1eb6254ef510a267466.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b1cb4ca2
    public func createImage(_ width: Int, _ height: Int) throws(ImageFailure) -> Image {
        try canvas.createImage(width, height)
    }

    /// 絵を等倍で置く。左上の角が (`x`, `y`) に来る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(tile, 90, 60)
    ///         stroke(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///         strokeWeight(2)
    ///         line(50, 60, 90, 60)
    ///         line(90, 20, 90, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 64 画素四方の絵が等倍で置かれ、白い 2 本の線が外からその左上の角を指している -->
    ///     ![64 画素四方の絵が等倍で置かれ、白い 2 本の線が外からその左上の角を指している](https://i.gyazo.com/cc4bdf044a32f8021840eef1b986431f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=38e37457
    public func image(_ image: Image, _ x: Float, _ y: Float) { canvas.image(image, x, y) }

    /// 絵を、指定した寸法に合わせて置く。
    ///
    /// 4 つの数の読み方は ``imageMode(_:)`` が決める。**絵の画素数と合っていなくてよい** —
    /// 下の例は同じ 64 画素四方の絵を、等倍と 3 倍ほどで並べている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(tile, 30, 40, 64, 64)
    ///         image(tile, 140, 40, 200, 200)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 2 つ。左は小さく等倍、右は 3 倍ほどに引き伸ばされている -->
    ///     ![同じ絵が 2 つ。左は小さく等倍、右は 3 倍ほどに引き伸ばされている](https://i.gyazo.com/000fd3d72844861557046e7bccfdf482.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b6e9798c
    public func image(_ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        canvas.image(image, a, b, c, d)
    }

    /// 絵の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**絵の中のどこを切り出すか**。切り出しが絵の
    /// 外へ出ても落ちず、重なった分だけが出る。
    ///
    /// 下の例は同じ絵を 2 度置いている — 左は全体、右は左上の 28 画素四方だけを
    /// 同じ大きさへ引き伸ばしたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(tile, 20, 40, 128, 128)
    ///         image(tile, 190, 40, 128, 128, 4, 4, 28, 28)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に絵の全体、右はその左上 28 画素四方だけを同じ大きさへ引き伸ばしたもの。右は橙色が大半を占め、下端にだけ青が残る -->
    ///     ![左に絵の全体、右はその左上 28 画素四方だけを同じ大きさへ引き伸ばしたもの。右は橙色が大半を占め、下端にだけ青が残る](https://i.gyazo.com/26c7189551956678633bbf1645bd0105.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=91678c9a
    public func image(
        _ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        canvas.image(image, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// 4 つの数を、絵のどこの寸法として読むか。既定は**左上の角と、幅と高さ**。
    ///
    /// 下の 4 枚はどれも同じ 4 つの数 `200, 150, 120, 90` を渡していて、変えたのは
    /// 読み方だけである (白い点が `200, 150`)。``rectMode(_:)`` と同じ約束。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         imageMode(.corner)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が絵の左上の角にあり、絵は点から右下へ広がっている -->
    ///     ![白い点が絵の左上の角にあり、絵は点から右下へ広がっている](https://i.gyazo.com/be990dbb96d2d4a50ce13d375d0ae03d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         imageMode(.corners)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///         circle(200, 150, 10)
    ///         circle(120, 90, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が 2 つあり、それぞれ絵の右下と左上の角になっている -->
    ///     ![白い点が 2 つあり、それぞれ絵の右下と左上の角になっている](https://i.gyazo.com/e19ef72d6dbbabe121f39eb1ccacb716.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         imageMode(.center)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が絵のまん中にある -->
    ///     ![白い点が絵のまん中にある](https://i.gyazo.com/6426d023a292164af1afeb8fc7866a36.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         imageMode(.radius)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が絵のまん中にあり、絵は center のときの縦横 2 倍になっている -->
    ///     ![白い点が絵のまん中にあり、絵は center のときの縦横 2 倍になっている](https://i.gyazo.com/af711f3205bcf02cc426619c69fe29ad.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=6071ac1e
    // shot: 2 snippet=b141b66f
    // shot: 3 snippet=97228423
    // shot: 4 snippet=99e89cd7
    public func imageMode(_ mode: ShapeMode) { canvas.imageMode(mode) }

    /// 絵に掛ける色。**掛け算なので、白は何も変えない。**
    ///
    /// 下の 2 枚はどちらも、左が掛ける前・右が掛けた後である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(tile, 20, 90, 160, 120)
    ///         tint(.display(red: 1, green: 1, blue: 1, alpha: 0.5))
    ///         image(tile, 220, 90, 160, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 2 つ。右は濃さが半分で、下地に沈んで見える -->
    ///     ![同じ絵が 2 つ。右は濃さが半分で、下地に沈んで見える](https://i.gyazo.com/f2504860f4fedf20f011b3e8690ed0d9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(tile, 20, 90, 160, 120)
    ///         tint(.display(red: 1, green: 0.6, blue: 0.6))
    ///         image(tile, 220, 90, 160, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 2 つ。右は緑と青が抑えられて赤みが乗っている -->
    ///     ![同じ絵が 2 つ。右は緑と青が抑えられて赤みが乗っている](https://i.gyazo.com/18238a312dbdd0f3a246680852aa475b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=8554f87e
    // shot: 2 snippet=df73f03d
    public func tint(_ color: LinearRGBA) { canvas.tint(color) }

    /// 色掛けをやめる。
    ///
    /// **1 つ目と 3 つ目は同じ色で出る** — 間で ``tint(_:)`` を掛けても、外せば元に帰る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, .display(red: 0.95, green: 0.45, blue: 0.25))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(tile, 15, 100, 110, 110)
    ///         tint(.display(red: 1, green: 0.5, blue: 0.5))
    ///         image(tile, 145, 100, 110, 110)
    ///         noTint()
    ///         image(tile, 275, 100, 110, 110)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 3 つ横に並び、真ん中だけ赤みが乗っている。右は左と同じ色に戻っている -->
    ///     ![同じ絵が 3 つ横に並び、真ん中だけ赤みが乗っている。右は左と同じ色に戻っている](https://i.gyazo.com/48e60fd99fd4e6335aef596effdec411.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=18365a53
    public func noTint() { canvas.noTint() }

    // MARK: - 描き場所

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
    ///     trail.fill(.display(red: 1, green: 0.4, blue: 0.2))
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
    ///         pad.background(.display(red: 0.15, green: 0.18, blue: 0.24))
    ///         pad.noStroke()
    ///         pad.fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///         pad.circle(50, 50, 70)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(pad, 20, 70)
    ///         image(pad, 220, 90, 100, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ描き場所が 2 つ。左は等倍で大きく、右は小さく。どちらも左上寄りに橙色の円 -->
    ///     ![同じ描き場所が 2 つ。左は等倍で大きく、右は小さく。どちらも左上寄りに橙色の円](https://i.gyazo.com/c60d052e340a68caf0fb948173f12a35.png)
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
    // shot: 1 snippet=82d426ed
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
    ///         pad.background(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         pad.fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///         pad.circle(40, 40, 60)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(pad, 90, 60)
    ///         stroke(.display(red: 0.95, green: 0.95, blue: 0.95))
    ///         strokeWeight(2)
    ///         line(50, 60, 90, 60)
    ///         line(90, 20, 90, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 120 画素四方の描き場所が等倍で置かれ、白い 2 本の線が外からその左上の角を指している -->
    ///     ![120 画素四方の描き場所が等倍で置かれ、白い 2 本の線が外からその左上の角を指している](https://i.gyazo.com/a335b3a5a2534f36798a0fc70bbb5979.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3e16141c
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
    ///         pad.background(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         pad.fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///         pad.circle(40, 40, 60)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(pad, 20, 60, 160, 160)
    ///         tint(.display(red: 0.5, green: 1, blue: 1))
    ///         image(pad, 210, 90, 100, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に大きく、右に小さく同じ描き場所。右は赤が抑えられて青緑に寄っている -->
    ///     ![左に大きく、右に小さく同じ描き場所。右は赤が抑えられて青緑に寄っている](https://i.gyazo.com/474adea0157149f502f6bfb951428834.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=e6207d93
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
    ///         pad.background(.display(red: 0.20, green: 0.28, blue: 0.40))
    ///         pad.fill(.display(red: 0.95, green: 0.45, blue: 0.25))
    ///         pad.circle(40, 40, 60)
    ///         pad.endDraw()
    ///     }
    ///
    ///     func draw() {
    ///         background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///         image(pad, 20, 60, 160, 160)
    ///         image(pad, 210, 60, 160, 160, 0, 0, 60, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に描き場所の全体、右はその左上 4 分の 1 だけを同じ大きさへ引き伸ばしたもの -->
    ///     ![左に描き場所の全体、右はその左上 4 分の 1 だけを同じ大きさへ引き伸ばしたもの](https://i.gyazo.com/8c7973a955f0f17d45697415c248b499.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5b9df865
    public func image(
        _ graphics: Canvas, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        canvas.image(graphics, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    // MARK: - 貼る

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
    public func texture(_ graphics: Canvas) { canvas.texture(graphics) }

    /// 絵を貼るのをやめる。
    public func noTexture() { canvas.noTexture() }
}
