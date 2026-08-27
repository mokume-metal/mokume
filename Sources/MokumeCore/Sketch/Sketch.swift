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
    /// 矩形を塗る。`x`・`y` は左上の角。
    public func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float) { canvas.rect(x, y, w, h) }
    /// 円を塗る。`x`・`y` は中心、`diameter` は直径。
    public func circle(_ x: Float, _ y: Float, _ diameter: Float) { canvas.circle(x, y, diameter) }
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
