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
    /// ## 保存したら差し替わる
    ///
    /// 在処のある断片は保存を拾って組み直される。**組み立てに失敗しても絵は消えない** —
    /// 前の断片がそのまま残り、失敗の理由は観測の警告に出る。
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

    /// 保持した形を置く。
    ///
    /// 色は形が持っているものが使われ、置く場所といまの変換が効く。
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
    public func beginShape(_ kind: VertexKind = .polygon) { canvas.beginShape(kind) }

    /// 頂点を 1 つ置く。
    public func vertex(_ x: Float, _ y: Float) { canvas.vertex(x, y) }

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

    /// 点が、いまの変換でどこへ移るか (横)。
    ///
    /// ```swift
    /// translate(100, 50)
    /// rotate(.pi / 4)
    /// let x = screenX(0, 0)   // 変換を積んだ後の原点が、面のどこにあるか
    /// ```
    public func screenX(_ x: Float, _ y: Float) -> Float { canvas.screenX(x, y) }

    /// 点が、いまの変換でどこへ移るか (縦)。
    public func screenY(_ x: Float, _ y: Float) -> Float { canvas.screenY(x, y) }

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
}
