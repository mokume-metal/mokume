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

// MARK: - 直接呼べる描画

extension Sketch {
    /// 面全体を塗り直す。
    public func background(_ color: LinearRGBA) { canvas.background(color) }
    /// これから描く図形の塗りの色。
    public func fill(_ color: LinearRGBA) { canvas.fill(color) }
    /// これから引く線の色。
    public func stroke(_ color: LinearRGBA) { canvas.stroke(color) }
    /// これから引く線の太さ (画素)。
    public func strokeWeight(_ weight: Float) { canvas.strokeWeight(weight) }
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
    /// 線を引く。
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        canvas.line(x1, y1, x2, y2)
    }
    /// 原点をずらす。
    public func translate(_ x: Float, _ y: Float) { canvas.translate(x, y) }
    /// 回す。正の角度は画面の上で時計回りに見える。
    public func rotate(_ radians: Float) { canvas.rotate(radians) }
    /// 伸ばす・縮める。
    public func scale(_ x: Float, _ y: Float) { canvas.scale(x, y) }
    /// いまの変換を積んでおく。
    public func push() { canvas.push() }
    /// 積んでおいた変換へ戻す。
    public func pop() { canvas.pop() }
}
