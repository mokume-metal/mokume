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

    /// 一度だけ呼ばれる。
    func setup()

    /// フレームごとに呼ばれる。
    func draw()
}

extension Sketch {
    public var settings: SketchSettings { SketchSettings() }
    public func setup() {}
    public func draw() {}
}

/// スケッチの設定。
public struct SketchSettings: Equatable, Sendable {
    /// 描く幅 (画素)。
    public var width: Int
    /// 描く高さ (画素)。
    public var height: Int
    /// 1 秒あたりのフレーム数の目標。
    public var frameRate: Int
    /// 窓の題名。
    public var title: String

    public init(
        width: Int = 960, height: Int = 540, frameRate: Int = 60, title: String = "mokume"
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.title = title
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

    /// 描く幅 (画素)。
    public var width: Float { canvas.width }
    /// 描く高さ (画素)。
    public var height: Float { canvas.height }

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
    /// ```swift
    /// // waves.metal
    /// // float4 paint(Fragment in, Values values) {
    /// //     float wave = 0.5 + 0.5 * sin(in.place.x * 20 + in.time * values.speed);
    /// //     return float4(values.tint.rgb * wave, 1);
    /// // }
    /// waves = try loadShader(
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
    /// 読む面の位置 (`uv`)・図形の色 (`color`)・読んだ面の値 (`texel`)・面の種類
    /// (`textureKind`)・秒数 (`time`)・面の大きさ (`resolution`)。
    ///
    /// ## 渡す値は読み込むときに宣言する
    ///
    /// `values` に書いた名前が、断片から `values.名前` で読める。後から名前を増やすと
    /// 断片ごと組み直しになるので、**名前は読み込むときに決め、値だけを後から変える**
    /// (``Shader/set(_:_:)``)。
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
    /// - Throws: 見つからないとき・組み立てられないときに ``ShaderFailure``。
    public func loadShader(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.loadShader(path, values: values)
    }

    /// 文字列から断片を作る。保存の拾い直しは効かない (在処が無いため)。
    public func makeShader(
        _ body: String, name: String = "shader", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.makeShader(body, name: name, values: values)
    }

    /// これから描くものを、この断片で塗る。
    ///
    /// **溜めている図形はその場で区切られる**ので、これより前に置いた図形が
    /// 後から差し替わることはない。
    public func shader(_ shader: Shader) { canvas.shader(shader) }

    /// 組み込みの塗りへ戻す。
    public func resetShader() { canvas.resetShader() }
}

// MARK: - 描く前の計算

extension Sketch {
    /// 数の並びを用意する。**CPU と GPU で同じものを見る。**
    ///
    /// ```swift
    /// heat = try makeNumbers(count: 4096)
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
    /// ```swift
    /// step = try makeComputation(
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
    /// ```swift
    /// func draw() {
    ///     compute(loudness, over: 4096, reads: [wave], writes: [level])
    ///     let values = read(level)      // ここで走らせて待つ
    ///     play(volume: values[0])
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
    /// ```swift
    /// func setup() {
    ///     dust = try makeParticles(count: 20000)
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
    /// ## 寿命が尽きた粒は 1 画素も出ない
    ///
    /// 描く数そのものは枠の数のままで、**尽きた粒は面積 0 に畳まれる**。描く個数を
    /// GPU 側で決める仕組みは、それが要る実害が出るまで持たない。
    ///
    /// ## 進むのは 1 フレームぶん
    ///
    /// 進む量は ``deltaTime`` で決まる。時計をフレーム番号から導く設定
    /// (``Clock/frameIndex(frameRate:)``) なら刻みが一定なので、**同じ入力から何度
    /// 走らせても同じ動き**が出る。
    public func particles(_ particles: Particles) { canvas.particles(particles) }
}

// MARK: - 保持した形

extension Sketch {
    /// 形を組み立てて保持する。**毎フレーム組み立て直さずに済む。**
    ///
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
    ///     for i in 0..<2000 { shape(leaf, x(i), y(i)) }
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
    /// for y in 0..<Int(height) {
    ///     for x in 0..<Int(width) {
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
    /// 書き換えは描画先へそのまま届く。**画素の面は描画先そのもの**で、写しではない。
    /// 「書き換えたのに送り直しを呼び忘れて絵が変わらない」という形の不具合が起きない。
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
    public var pixels: Pixels { canvas.pixels }

    /// 溜めている図形を描き切り、画素を読める状態にする。
    ///
    /// ``pixels`` も ``get(_:_:)`` も ``set(_:_:_:)`` も必要なら自分で呼ぶので、
    /// **省いても結果は変わらない**。待つ時点を選びたいときに使う。
    public func loadPixels() { canvas.loadPixels() }

    /// 1 画素の色。原点は左上。範囲の外は透明を返す。
    public func get(_ x: Int, _ y: Int) -> LinearRGBA { canvas.get(x, y) }

    /// 1 画素の色を書き換える。範囲の外は何もしない。
    public func set(_ x: Int, _ y: Int, _ color: LinearRGBA) { canvas.set(x, y, color) }
}

// MARK: - 直接呼べる描画

extension Sketch {
    /// 面全体を塗り直す。
    ///
    /// それまでに溜めた図形は消える — 全面を塗るのだから、下に隠れるものを
    /// 描く手間をかける意味がない。
    public func background(_ color: LinearRGBA) { canvas.background(color) }
    /// これから描く図形の塗りの色。**塗りを止めていたら、呼んだ時点で再び塗るようになる。**
    public func fill(_ color: LinearRGBA) { canvas.fill(color) }
    /// これから引く線の色。**線を止めていたら、呼んだ時点で再び引くようになる。**
    public func stroke(_ color: LinearRGBA) { canvas.stroke(color) }
    /// これから引く線の太さ (画素)。
    public func strokeWeight(_ weight: Float) { canvas.strokeWeight(weight) }

    /// 図形の内側を塗らない。輪郭だけの図形になる。
    ///
    /// ``fill(_:)`` を呼ぶと、その時点でまた塗るようになる。
    public func noFill() { canvas.noFill() }

    /// 線を引かない。図形の輪郭も出なくなる。
    ///
    /// ``stroke(_:)`` を呼ぶと、その時点でまた引くようになる。
    public func noStroke() { canvas.noStroke() }

    /// 線の端の形。既定は丸。
    ///
    /// 太さ 1 の線では 3 つとも同じに見えるので、**確かめるときは太さを振る**。
    public func strokeCap(_ cap: StrokeCap) { canvas.strokeCap(cap) }

    /// 頂点を並べ始める。``vertex(_:_:)`` で点を置き、``endShape(_:)`` で描く。
    ///
    /// ```swift
    /// beginShape()
    /// vertex(20, 20)
    /// vertex(80, 30)
    /// vertex(50, 80)
    /// endShape(.close)
    /// ```
    ///
    /// 既定の読み方 (``VertexKind/polygon``) では、**凹んでいても穴があってもよい**。
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
    public func beginShape(_ kind: VertexKind = .polygon) { canvas.beginShape(kind) }

    /// 頂点を 1 つ置く。
    public func vertex(_ x: Float, _ y: Float) { canvas.vertex(x, y) }

    /// 奥行きを持つ頂点を 1 つ置く。**この形は立体になる。**
    ///
    /// 1 つでもこの形で置けば、その形は最後まで立体として扱われる — 途中で
    /// ``vertex(_:_:)`` を混ぜてもよく、そちらは奥行き 0 の頂点になる。
    public func vertex(_ x: Float, _ y: Float, _ z: Float) { canvas.vertex(x, y, z) }

    /// 貼る絵の読み取り位置つきで頂点を 1 つ置く。
    ///
    /// `u`・`v` は**貼る絵の画素**で書く (``image(_:_:_:_:_:_:_:_:_:)`` の切り出しと
    /// 同じ単位)。``texture(_:)`` で絵を束ねていなければ、書いても何も起きない。
    ///
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
    /// 手前に点が無いときは何もしない — 曲線は「いまの点から」繋ぐものなので、
    /// 始点が無ければ引きようがない。
    public func bezierVertex(
        _ cx1: Float, _ cy1: Float, _ cx2: Float, _ cy2: Float, _ x: Float, _ y: Float
    ) {
        canvas.bezierVertex(cx1, cy1, cx2, cy2, x, y)
    }

    /// 2 次の曲線で、いまの点から `x`・`y` まで繋ぐ。
    public func quadraticVertex(_ cx: Float, _ cy: Float, _ x: Float, _ y: Float) {
        canvas.quadraticVertex(cx, cy, x, y)
    }

    /// 通過点を結ぶ曲線の制御点を置く。
    ///
    /// **4 つ揃って初めて 1 区間が引ける。** 最初と最後の点は曲がり方を決めるためだけに
    /// 使われ、その間だけが描かれる — 端まで描きたいときは端の点を 2 度置く。
    public func curveVertex(_ x: Float, _ y: Float) { canvas.curveVertex(x, y) }

    /// 曲線をいくつの直線で近似するか。
    public func curveDetail(_ steps: Int) { canvas.curveDetail(steps) }

    /// 通過点を結ぶ曲線の張り具合。0 が既定で、大きくすると曲がりが緩くなる。
    public func curveTightness(_ amount: Float) { canvas.curveTightness(amount) }

    /// 穴を並べ始める。
    public func beginContour() { canvas.beginContour() }

    /// 穴を並べ終える。
    public func endContour() { canvas.endContour() }

    /// 並べ終えて描く。
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
    /// ```swift
    /// blendMode(.add)      // 光を重ねたように明るくなる
    /// blendMode(.multiply) // 暗いほうへ寄る
    /// ```
    ///
    /// **どのモードでも、アルファ 0 の色は下地を変えない。** 混ぜ方が変わっても
    /// 「どれだけ効かせるか」はアルファが決める。
    public func blendMode(_ mode: BlendMode) { canvas.blendMode(mode) }

    /// 線の折れ目の形。既定は尖らせる形。
    ///
    /// 折れ線と、閉じた図形の輪郭の角に効く。
    public func strokeJoin(_ join: StrokeJoin) { canvas.strokeJoin(join) }
    /// 矩形を塗る。
    ///
    /// 4 つの数の読み方は ``rectMode(_:)`` が決める。既定は**左上の角と、幅と高さ**。
    ///
    /// ```swift
    /// rect(20, 20, 60, 40)   // 左上 (20, 20) から 60x40
    /// rectMode(.center)
    /// rect(50, 40, 60, 40)   // 中心 (50, 40) の 60x40 — 上と同じ場所に出る
    /// ```
    ///
    /// 幅か高さが 0 以下になる指定では**何も描かない**。
    public func rect(_ a: Float, _ b: Float, _ c: Float, _ d: Float) { canvas.rect(a, b, c, d) }

    /// 正方形を塗る。
    ///
    /// 読み方は ``rect(_:_:_:_:)`` と同じで、幅と高さに同じ値を渡すのに等しい。
    public func square(_ a: Float, _ b: Float, _ extent: Float) { canvas.square(a, b, extent) }

    /// 円を塗る。
    ///
    /// 3 つの数の読み方は ``ellipseMode(_:)`` が決める。既定は**中心と直径**。
    public func circle(_ a: Float, _ b: Float, _ diameter: Float) { canvas.circle(a, b, diameter) }

    /// 楕円を塗る。
    ///
    /// 4 つの数の読み方は ``ellipseMode(_:)`` が決める。既定は**中心と、幅と高さ**。
    public func ellipse(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        canvas.ellipse(a, b, c, d)
    }

    /// 円弧を塗る。
    ///
    /// 最初の 4 つの数は ``ellipse(_:_:_:_:)`` と同じ読み方で、続く 2 つが始まりと
    /// 終わりの角度 (ラジアン)。**角度は右向きが 0** で、増える向きは画面の上で
    /// 時計回りに見える (縦軸が下向きのため)。
    ///
    /// ```swift
    /// arc(50, 50, 80, 80, 0, .pi / 2)   // 右から下へ 4 分の 1
    /// ```
    ///
    /// 塗りは**中心を含む扇形**になる。終わりの角度が始まりより小さいときは
    /// **何も描かず**、最初の 1 回だけ知らせる。
    public func arc(
        _ a: Float, _ b: Float, _ c: Float, _ d: Float, _ start: Float, _ stop: Float
    ) {
        canvas.arc(a, b, c, d, start, stop)
    }

    /// 三角形を塗る。3 つの頂点をそのまま与える。
    public func triangle(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x3: Float, _ y3: Float
    ) {
        canvas.triangle(x1, y1, x2, y2, x3, y3)
    }

    /// 四角形を塗る。4 つの頂点は**与えた順に結ばれる**ので、順序を入れ替えると
    /// 砂時計のような形にもなる。
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
    public func point(_ x: Float, _ y: Float) { canvas.point(x, y) }

    /// 矩形に渡す座標の読み方。既定は ``ShapeMode/corner``。
    public func rectMode(_ mode: ShapeMode) { canvas.rectMode(mode) }

    /// 楕円と円弧に渡す座標の読み方。既定は ``ShapeMode/center``。
    ///
    /// ``circle(_:_:_:)`` にも効く — 直径 1 つしか渡さないので、意味を持つのは
    /// 中心から測る 2 つ (``ShapeMode/center`` と ``ShapeMode/radius``) である。
    public func ellipseMode(_ mode: ShapeMode) { canvas.ellipseMode(mode) }
    /// 線を引く。塗りは持たない。
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        canvas.line(x1, y1, x2, y2)
    }
    /// 原点をずらす。
    public func translate(_ x: Float, _ y: Float) { canvas.translate(x, y) }
    /// 回す。縦軸が下向きなので、正の角度は画面の上で時計回りに見える。
    public func rotate(_ radians: Float) { canvas.rotate(radians) }
    /// 伸ばす・縮める。
    public func scale(_ x: Float, _ y: Float) { canvas.scale(x, y) }

    /// 原点を奥行きも含めてずらす。
    ///
    /// **奥行きは見ている側が正。** 正の値を渡すと手前へ、負の値を渡すと奥へ動く
    /// (手本のある向きに合わせてある)。
    public func translate(_ x: Float, _ y: Float, _ z: Float) { canvas.translate(x, y, z) }

    /// 横軸まわりに回す。
    ///
    /// 縦軸が下向きなので、正の角度は**上の面が奥へ倒れる**向きに見える。
    public func rotateX(_ radians: Float) { canvas.rotateX(radians) }

    /// 縦軸まわりに回す。
    ///
    /// 正の角度は、右の面が奥へ回る向きに見える。
    public func rotateY(_ radians: Float) { canvas.rotateY(radians) }

    /// 奥行きの軸まわりに回す。``rotate(_:)`` と同じ。
    public func rotateZ(_ radians: Float) { canvas.rotateZ(radians) }

    /// 奥行きも含めて伸ばす・縮める。
    public func scale(_ x: Float, _ y: Float, _ z: Float) { canvas.scale(x, y, z) }

    /// 横方向へ斜めに歪める。
    public func shearX(_ radians: Float) { canvas.shearX(radians) }

    /// 縦方向へ斜めに歪める。
    public func shearY(_ radians: Float) { canvas.shearY(radians) }

    /// 与えた変換を、いまの変換の後に重ねる。
    public func applyMatrix(_ matrix: Transform) { canvas.applyMatrix(matrix) }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix()``) は捨てないので、戻す先は残る。
    public func resetMatrix() { canvas.resetMatrix() }

    /// いまの変換を積んでおく。
    public func pushMatrix() { canvas.pushMatrix() }

    /// 積んでおいた変換へ戻す。積んでいなければ何もしない。
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
    /// - Note: 視点は**フレームを越えない**。`draw()` の中で毎フレーム書く。初期化の
    ///   ときに書いた視点はどのフレームにも属さないので、警告して無視される。
    public func camera() { canvas.camera() }

    /// 見る位置・見ている先・上方向を決める。
    ///
    /// 座標は世界の座標で、**いまの変換の影響を受けない** — 視点は「何をどう置くか」
    /// ではなく「どこから見るか」なので、積んだ変換とは別に決まる。
    ///
    /// ```swift
    /// func draw() {
    ///     background(.display(red: 0.08, green: 0.09, blue: 0.12))
    ///     lights()
    ///     // 斜め上から見下ろす
    ///     camera(
    ///         width / 2 + 260, height / 2 - 200, 420,
    ///         width / 2, height / 2, 0,
    ///         0, 1, 0)
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     box(140)
    ///     pop()
    /// }
    /// ```
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
    /// - Note: 視点は**フレームを越えない**。`draw()` の中で毎フレーム当てる。
    public func setCamera(_ camera: Camera) { canvas.setCamera(camera) }

    /// 透視投影を既定へ戻す。
    ///
    /// 既定の画角・手前と奥の面は、**既定の視点の距離から導かれている**。
    ///
    /// - Note: 投影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    public func perspective() { canvas.perspective() }

    /// 遠くのものほど小さく写す。
    ///
    /// - Parameters:
    ///   - fieldOfView: 縦方向の画角 (ラジアン)。広げるほど遠近が強く出る。
    ///   - aspect: 横 ÷ 縦の比。ふつうは `width / height`。
    ///   - near: 手前の面までの距離。**これより手前は写らない。**
    ///   - far: 奥の面までの距離。**これより奥は写らない。**
    ///
    /// - Note: 投影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    public func perspective(_ fieldOfView: Float, _ aspect: Float, _ near: Float, _ far: Float) {
        canvas.perspective(fieldOfView, aspect, near, far)
    }

    /// 平行投影を既定へ戻す。
    ///
    /// 範囲は**既定の視点を中心に面 1 枚ぶん**である。だから `ortho()` だけを書いても
    /// 被写体は隅へ寄らず、奥に置いたものも切れない。奥行き 0 に置いたものが平面の
    /// 図形と重なる性質も、透視投影の既定と同じように成り立つ。
    ///
    /// - Note: 投影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
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
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。初期化の
    ///   ときに置いた光はどのフレームにも属さないので、警告して無視される。
    public func ambientLight(_ color: LinearRGBA) { canvas.ambientLight(color) }

    /// 向きだけを持つ光を置く (無限に遠くから差す光)。
    ///
    /// 渡すのは**光が進む向き**である。縦軸は下向きなので、`(0, 1, 0)` が真上から
    /// 差す光になる。斜めの成分を入れると、陰の境目が左右どちらかへ寄る。
    ///
    /// ```swift
    /// func draw() {
    ///     ambientLight(.opaque(red: 0.3, green: 0.3, blue: 0.3))
    ///     directionalLight(.opaque(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.8, -0.4)
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     sphere(120)
    ///     pop()
    /// }
    /// ```
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    public func directionalLight(_ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float) {
        canvas.directionalLight(color, x, y, z)
    }

    /// 位置を持つ光を置く。面から光源へ向かう向きで明るさが決まる。
    ///
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
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
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
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
    /// - Note: 光は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    public func lights() { canvas.lights() }

    /// 置いた光をすべて取り除く。以降の立体は塗り 1 色で描かれる。
    public func noLights() { canvas.noLights() }

    // MARK: - モデル

    /// 外で作ったモデルを読む。読み終わるまで返らない。
    ///
    /// ```swift
    /// func setup() {
    ///     head = try? loadModel("assets/head.obj")
    /// }
    /// func draw() {
    ///     lights()
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     rotateY(millis() / 2000)
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
    public func loadModel(_ path: String, normalize: Bool = true) throws(ModelFailure) -> Model {
        try canvas.loadModel(path, normalize: normalize)
    }

    /// 外で作ったモデルを読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 解釈を別の仕事として回すので、大きなモデルを読んでもフレームが詰まらない。
    public func requestModel(_ path: String, normalize: Bool = true) async throws(ModelFailure)
        -> Model
    {
        try await canvas.requestModel(path, normalize: normalize)
    }

    /// 読み込んだモデルを置く。
    ///
    /// いまの変換と塗りが効く。**続けて同じモデルを置いても描く回数は増えない** —
    /// 頂点は置き直されず、置き場所だけが増える。
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
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    ///   **光を 1 つも置かなければ立体は塗り 1 色で出る**ので、材質はどれも効かない
    ///   (書いてあれば警告が出る)。
    public func shininess(_ amount: Float) { canvas.shininess(amount) }

    /// 金属らしさ。`0` が非金属 (既定)、`1` が金属。
    ///
    /// 金属は拡散を持たず、**周りを映すことでしか見えない**。いまは映り込む先が
    /// 無いので、``ambientLight(_:)`` で置いた底上げの光を一様な周りとして映す —
    /// 底上げの光を 1 つも置かずに金属を上げると、艶だけが残って暗くなる
    /// (このとき警告が出る)。
    ///
    /// 艶の色も変わる。非金属の艶は光の色のまま白く出るが、金属の艶は塗りの色に
    /// 染まる。
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
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
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    public func ambient(_ color: LinearRGBA) { canvas.ambient(color) }

    /// 自ら出す光。光が当たっていない側にも同じだけ出る。
    ///
    /// **周りを照らしはしない** — その面が明るく見えるだけで、ほかの立体には届かない。
    /// 明かりそのものを描きたいときは、同じ場所に ``pointLight(_:_:_:_:)`` も置く。
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
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
    /// - Note: 周囲は**フレームを越えない**。`draw()` の中で毎フレーム置く。
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
    /// - Note: 影は**フレームを越えない**。`draw()` の中で毎フレーム書く。毎フレーム
    ///   書いても焼き付け先は作り直さないので、繰り返しの負担にはならない。
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
    /// - Note: 影は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    public func shadowRange(_ size: Float) { canvas.shadowRange(size) }

    /// 影を焼き付ける面の一辺の画素数。既定は 1024。
    ///
    /// 大きくすると縁が細かくなり、そのぶん焼くのに時間がかかる。**同じ数を渡し
    /// 続けるかぎり、焼き付け先は作り直されない。**
    public func shadowDetail(_ size: Int) { canvas.shadowDetail(size) }

    /// 影の縁の破綻を抑える量。既定は `0.0025`。
    ///
    /// 焼いた 1 画素の中で奥行きが変わるので、そのままだと**自分の影が自分の上に
    /// 縞として出る**。それを避けるための余裕で、大きくしすぎると影が形から離れて
    /// 浮いて見える。
    public func shadowBias(_ amount: Float) { canvas.shadowBias(amount) }

    /// これから置く形が、影を落とす側か。既定は落とす。
    ///
    /// 床のように「受けるだけ」の形は落とす側から外す。**全体を切るしか無いと、
    /// 自己遮蔽の強い形を置いた作品が影ごと諦めることになる。**
    public func castShadow(_ enabled: Bool) { canvas.castShadow(enabled) }

    /// これから置く形が、影を受ける側か。既定は受ける。
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
    public func box(_ size: Float) { canvas.box(size) }

    /// 幅・高さ・奥行きを別々に決めた箱を置く。
    public func box(_ width: Float, _ height: Float, _ depth: Float) {
        canvas.box(width, height, depth)
    }

    /// 球を置く。
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 上下は半周なので、その半分で割る。
    public func sphere(_ radius: Float, detail: Int = Canvas.defaultSolidDetail) {
        canvas.sphere(radius, detail: detail)
    }

    /// 平らな面を置く。画面の側を向く。
    ///
    /// 奥行き 0 に置いた面は、同じ座標に描いた ``rect(_:_:_:_:)`` とぴったり重なる。
    public func plane(_ width: Float, _ height: Float) { canvas.plane(width, height) }

    /// 円柱を置く。軸は縦。
    ///
    /// - Parameters:
    ///   - radius: 半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    public func cylinder(
        _ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail
    ) {
        canvas.cylinder(radius, height, detail: detail)
    }

    /// 円錐を置く。軸は縦で、先は上を向く。
    ///
    /// - Parameters:
    ///   - radius: 底の半径 (画素)。
    ///   - height: 高さ (画素)。
    ///   - detail: **一周をいくつに割るか。**
    public func cone(_ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail) {
        canvas.cone(radius, height, detail: detail)
    }

    /// 輪を置く。穴は画面の側を向く。
    ///
    /// - Parameters:
    ///   - radius: 中心から管の中心までの距離 (画素)。
    ///   - tubeRadius: 管の半径 (画素)。
    ///   - detail: **一周をいくつに割るか。** 輪の一周も管の一周も同じ数で割る。
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
    public func push() { canvas.push() }

    /// 積んでおいた変換とスタイルの両方へ戻す。積んでいなければ何もしない。
    public func pop() { canvas.pop() }

    // MARK: - 文字

    /// 文字列を描く。
    ///
    /// ```swift
    /// textSize(48)
    /// fill(.display(red: 1, green: 1, blue: 1))
    /// text("mokume", 40, 100)   // (40, 100) が字の乗る線
    /// ```
    ///
    /// `y` が何を指すかは ``textAlign(_:_:)`` が決める。既定は**基準線** — 字が乗る線で、
    /// `g` や `y` の下へ伸びる部分はここより下に出る。
    ///
    /// 改行で行が分かれ、行の間隔は ``textLeading(_:)`` が決める。**塗りの色で描く**ので、
    /// ``noFill()`` の状態では何も出ない。
    public func text(_ string: String, _ x: Float, _ y: Float) { canvas.text(string, x, y) }

    /// これから描く文字の大きさ (画素)。既定は 12。
    ///
    /// 行送りを指定していなければ、行の間隔もこの値から決まる。
    public func textSize(_ size: Float) { canvas.textSize(size) }

    /// これから描く文字の書体。
    ///
    /// ```swift
    /// textFont("Helvetica")
    /// ```
    ///
    /// **この環境に無い名前は効かない。** 名前が違っても別の書体で描かれてしまうと
    /// 気付けないので、無い名前は警告を出して書体を変えない。``noTextFont()`` で
    /// 既定へ戻る。
    ///
    /// 指定した書体が覆えない文字 (欧文の書体に日本語を渡した場合など) は、
    /// この環境が持つ別の書体から引いて描く。
    public func textFont(_ name: String) { canvas.textFont(name) }

    /// 書体の指定をやめ、この環境の既定の書体へ戻す。
    public func noTextFont() { canvas.noTextFont() }

    /// これから描く文字の太さと傾き。既定はそのまま。
    public func textStyle(_ style: TextStyle) { canvas.textStyle(style) }

    /// 文字列を、指定した位置のどちら側へ置くか。既定は**左から右へ・基準線**。
    ///
    /// ```swift
    /// textAlign(.center, .center)
    /// text("mokume", width / 2, height / 2)   // 面のまん中に置かれる
    /// ```
    public func textAlign(
        _ horizontal: HorizontalTextAlign, _ vertical: VerticalTextAlign = .baseline
    ) {
        canvas.textAlign(horizontal, vertical)
    }

    /// 行と行の間隔 (画素)。指定しなければ大きさの 1.25 倍。
    public func textLeading(_ leading: Float) { canvas.textLeading(leading) }

    /// 文字列を描いたときの幅 (画素)。
    ///
    /// **1 文字ずつの送り幅の合計**なので、部分に切って足すと全体と一致する。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    ///
    /// ```swift
    /// let w = textWidth("mokume")
    /// text("mokume", 20, 60)
    /// line(20, 64, 20 + w, 64)   // 文字列のちょうど下に線が引ける
    /// ```
    public func textWidth(_ string: String) -> Float { canvas.textWidth(string) }

    /// 基準線から上へ伸びる高さ (画素)。
    public func textAscent() -> Float { canvas.textAscent() }

    /// 基準線から下へ伸びる深さ (画素)。
    public func textDescent() -> Float { canvas.textDescent() }

    /// 矩形の中へ文字列を流し込む。
    ///
    /// ```swift
    /// let flow = text(long, 20, 20, 200, 120)
    /// text(flow.remainder, 240, 20, 200, 120)   // 入りきらなかった続きを隣の段へ
    /// ```
    ///
    /// 4 つの数の読み方は ``rectMode(_:)`` が決める — ``rect(_:_:_:_:)`` と同じ約束である。
    /// 幅で折り返し、**高さに収まる行だけ**を置く。折り返す場所は ``textWrap(_:)``。
    ///
    /// 返る値は「何行置いたか・どれだけの高さを使ったか・何が残ったか」。**続きを
    /// どこから描くかを自分で数え直さずに済む**ように返している。
    ///
    /// 縦の指定 (``textAlign(_:_:)``) は置いた塊全体に効く。矩形の中では基準線に
    /// 意味が無いので、基準線指定は上揃えと同じに扱う。
    @discardableResult
    public func text(_ string: String, _ a: Float, _ b: Float, _ c: Float, _ d: Float)
        -> TextFlow
    {
        canvas.text(string, a, b, c, d)
    }

    /// 幅に収まらなくなったとき、どこで行を折るか。既定は語の切れ目。
    ///
    /// 語の切れ目で折るとき、**1 語が幅より長ければその語の中で折る** —
    /// でないと置き場所が無くなる。
    public func textWrap(_ mode: TextWrap) { canvas.textWrap(mode) }

    /// 文字列の輪郭を取り出す。
    ///
    /// ```swift
    /// noFill()
    /// stroke(.display(red: 1, green: 1, blue: 1))
    /// for contour in textOutline("mokume", 20, 100) {
    ///     beginShape()
    ///     for point in contour.points { vertex(point.x, point.y) }
    ///     endShape(.close)
    /// }
    /// ```
    ///
    /// **描くときと同じ送り**で並ぶので、``text(_:_:_:)`` と同じ位置・同じ字間になる。
    /// 返る点はいまの座標のままで、変換は掛かっていない。
    ///
    /// 字ごとに、外側の周が先・穴が後の順で並ぶ。曲線は直線の並びにほどいてあり、
    /// 細かさは曲線の大きさから決まる。
    public func textOutline(_ string: String, _ x: Float, _ y: Float) -> [TextContour] {
        canvas.textOutline(string, x, y)
    }

    // MARK: - 画像

    /// 絵を読む。読み終わるまで返らない。
    ///
    /// ```swift
    /// func setup() {
    ///     grain = try? loadImage("assets/grain.png")
    /// }
    /// ```
    ///
    /// **読み込みは投げる。** 読めなかったときに別の道を選ぶ判断が要るので、黙って
    /// 既定へ倒さない。見つからないときの説明には**探した場所**が載る。
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
    public func requestImage(_ path: String) async throws(ImageFailure) -> Image {
        try await canvas.requestImage(path)
    }

    /// 空の絵を作る。中身は透明。
    ///
    /// ``Image/set(_:_:_:)`` で書き換えると、**描くときに自動で送られる** —
    /// 送り直しを呼び忘れて絵が変わらない、という形の不具合が起きない。
    public func createImage(_ width: Int, _ height: Int) throws(ImageFailure) -> Image {
        try canvas.createImage(width, height)
    }

    /// 絵を等倍で置く。左上の角が (`x`, `y`) に来る。
    public func image(_ image: Image, _ x: Float, _ y: Float) { canvas.image(image, x, y) }

    /// 絵を、指定した寸法に合わせて置く。
    ///
    /// 4 つの数の読み方は ``imageMode(_:)`` が決める。
    public func image(_ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        canvas.image(image, a, b, c, d)
    }

    /// 絵の一部を切り出して置く。
    ///
    /// ```swift
    /// image(sheet, 0, 0, 32, 32, 64, 0, 32, 32)   // 右となりの駒を左上へ
    /// ```
    ///
    /// 前の 4 つが置き先、後の 4 つが**絵の中のどこを切り出すか**。切り出しが絵の
    /// 外へ出ても落ちず、重なった分だけが出る。
    public func image(
        _ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        canvas.image(image, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// 4 つの数を、絵のどこの寸法として読むか。既定は**左上の角と、幅と高さ**。
    public func imageMode(_ mode: ShapeMode) { canvas.imageMode(mode) }

    /// 絵に掛ける色。**掛け算なので、白は何も変えない。**
    ///
    /// ```swift
    /// tint(.display(red: 1, green: 1, blue: 1, alpha: 0.5))   // 半分の濃さで置く
    /// tint(.display(red: 1, green: 0.6, blue: 0.6))           // 赤みを乗せる
    /// ```
    public func tint(_ color: LinearRGBA) { canvas.tint(color) }

    /// 色掛けをやめる。
    public func noTint() { canvas.noTint() }

    // MARK: - 貼る

    /// これから置く塗りに絵を貼る。
    ///
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

    /// 絵を貼るのをやめる。
    public func noTexture() { canvas.noTexture() }
}
