// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 三角形の経路の平面の線は、1 つの図形の中で重ねて混ぜない ([#1536]・[#1562])。GPU を要する。
///
/// 線は帯・折れ目の形・端の形・曲線の刻みの円板を別々の三角形として積む。重ねたまま積むと、
/// 半透明の線と下地を読む混ぜ方で、重なった所だけが 2〜3 回混ざって濃くなる。距離関数の
/// 経路は線を 1 つの領域として 1 回だけ塗るので、`shader()` を 1 行足しただけで同じ `rect` の
/// 角の濃さが変わっていた。
///
/// **単位 ([#1536] の判断 1):**
///
/// - 任意多角形 (`beginShape`・`triangle`・`quad`・`line`) は、線に沿って太さ以内で繋がる片
///   どうしを 1 回だけ混ぜる。線に沿って離れた部分が交わる所 (自己交差) は、別々の線と同じく
///   2 回混ぜる
/// - 基本図形 (`rect` / `ellipse` / `arc`) は自己交差しないので、線全体を 1 回だけ混ぜる
///   (距離関数の経路と同じ)
///
/// ## 読み方
///
/// 面は 160×160 の黒地で、線は `stroke(255, 0, 0, 128)`。1 回混ぜると線形の赤が 0.413、
/// 2 回で 0.618、3 回で 0.721 になる。「重ね塗りの画素」は赤が 0.5 を超える画素とする。
/// 期待値は保存した画像ではなく、この混ぜ方の式と、同じ図形を別の経路で描いた絵から導く
/// ([ADR-0019] 決定 4)。
///
/// [#1536]: https://github.com/mokume-metal/mokume/issues/1536
/// [#1562]: https://github.com/mokume-metal/mokume/issues/1562
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "三角形の経路の線の重ね塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct StrokeOverlapTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 1 回だけ混ぜたときの赤 (線形)。`stroke(255, 0, 0, 128)` を黒地に 1 回 `blend` した値。
    private static let once: Float = 0.413
    /// 2 回混ぜたときの赤。
    private static let twice: Float = 0.618

    /// 素通しの断片。組み込みの断片と同じ色を出すが、`shader()` が効くので三角形の経路へ落ちる。
    private static let passThrough = "float4 paint(Fragment in, Values values) { return in.color; }"

    /// 黒地に `noFill()` で描いて、線形の画素を読む。
    ///
    /// - Parameter shaded: 素通しの断片を効かせてから描く
    private func render(shaded: Bool = false, _ body: (Canvas) -> Void) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            if shaded {
                do { canvas.shader(try canvas.makeShader(Self.passThrough)) } catch { failure = error }
            }
            body(canvas)
        }
        if let failure { throw failure }
        return try canvas.target.readPixels()
    }

    /// 半透明の赤の線で描く。
    private func translucent(shaded: Bool = false, _ body: (Canvas) -> Void) throws -> PixelBuffer {
        try render(shaded: shaded) { canvas in
            canvas.stroke(255, 0, 0, 128)
            body(canvas)
        }
    }

    /// 赤が 0.5 を超える画素 (2 回以上混ぜた画素) の位置。
    private func overpainted(_ pixels: PixelBuffer) -> [SIMD2<Int>] {
        var found: [SIMD2<Int>] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 { found.append(SIMD2(x, y)) }
        }
        return found
    }

    /// 塗られた画素 (赤 > 0.05) の数。
    private func painted(_ pixels: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.05 { count += 1 }
        }
        return count
    }

    private func differingPixels(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y] != b[x, y] { count += 1 }
        }
        return count
    }

    /// 片方にだけ塗られた画素の位置 (穴かはみ出し)。
    private func holes(_ a: PixelBuffer, _ b: PixelBuffer) -> [SIMD2<Int>] {
        var found: [SIMD2<Int>] = []
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y] != b[x, y] { found.append(SIMD2(x, y)) }
        }
        return found
    }

    // MARK: - 形

    /// 起票時の閉じた 4 点。
    private static func closedSquare(_ canvas: Canvas) {
        canvas.beginShape()
        canvas.vertex(40, 40)
        canvas.vertex(120, 40)
        canvas.vertex(120, 120)
        canvas.vertex(40, 120)
        canvas.endShape(.close)
    }

    /// 鋭く折れた開いた折れ線。
    private static func sharpFold(_ canvas: Canvas) {
        canvas.beginShape()
        canvas.vertex(30, 130)
        canvas.vertex(80, 30)
        canvas.vertex(130, 130)
        canvas.endShape()
    }

    /// 2 点の開いた形。
    private static func twoPoints(_ canvas: Canvas) {
        canvas.beginShape()
        canvas.vertex(40, 80)
        canvas.vertex(120, 80)
        canvas.endShape()
    }

    /// 起票時の曲線。頂点の近くで刻みの間隔が太さの半分より短くなり、円板が 2 つ先の帯まで届く。
    private static func filedCurve(_ canvas: Canvas) {
        canvas.beginShape()
        canvas.vertex(20, 120)
        canvas.bezierVertex(40, 20, 120, 20, 140, 120)
        canvas.endShape()
    }

    // MARK: - #1536 条件 1: 任意多角形の繋ぎ目

    @Test("閉じた 4 点の半透明の線は、角も辺と同じく 1 回だけ混ぜる", arguments: [StrokeJoin.miter, .bevel, .round])
    func closedPolygonCornersBlendOnce(_ join: StrokeJoin) throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            canvas.strokeJoin(join)
            Self.closedSquare(canvas)
        }
        #expect(abs(pixels[80, 45].red - Self.once) <= 0.01, "辺の中ほど: \(pixels[80, 45].red)")
        #expect(abs(pixels[45, 45].red - Self.once) <= 0.01, "角 (45, 45): \(pixels[45, 45].red)")
        #expect(overpainted(pixels).count == 0, "\(join)")
    }

    @Test("鋭く折れた開いた折れ線の半透明の線は、折れ目で重ねて混ぜない")
    func sharpFoldBlendsOnce() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            Self.sharpFold(canvas)
        }
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count == 0)
    }

    @Test("2 点の開いた形の半透明の線は、端の形と帯を重ねて混ぜない", arguments: [StrokeCap.round, .project])
    func twoPointCapsBlendOnce(_ cap: StrokeCap) throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            canvas.strokeCap(cap)
            Self.twoPoints(canvas)
        }
        #expect(abs(pixels[44, 80].red - Self.once) <= 0.01, "端から 4 内側: \(pixels[44, 80].red)")
        #expect(overpainted(pixels).count == 0, "\(cap)")
    }

    // MARK: - #1536 条件 2: `shader()` を付けた基本図形

    @Test("素通しの断片を付けた rect の半透明の線は、角で重ねて混ぜない", arguments: [StrokeJoin.miter, .bevel, .round])
    func shadedRectCornersBlendOnce(_ join: StrokeJoin) throws {
        let pixels = try translucent(shaded: true) { canvas in
            canvas.strokeWeight(20)
            canvas.strokeJoin(join)
            canvas.rect(40, 40, 80, 80)
        }
        #expect(abs(pixels[45, 45].red - Self.once) <= 0.01, "角 (45, 45): \(pixels[45, 45].red)")
        #expect(overpainted(pixels).count == 0, "\(join)")
    }

    @Test("素通しの断片を付けた line と細い rect の半透明の線は、重ねて混ぜない")
    func shadedLineAndThinRectBlendOnce() throws {
        let line = try translucent(shaded: true) { canvas in
            canvas.strokeWeight(20)
            canvas.line(40, 80, 120, 80)
        }
        #expect(painted(line) > 0)
        #expect(overpainted(line).count == 0, "line")
        let thin = try translucent(shaded: true) { canvas in
            canvas.strokeWeight(20)
            canvas.rect(60, 30, 4, 100)
        }
        #expect(painted(thin) > 0)
        #expect(overpainted(thin).count == 0, "rect(60, 30, 4, 100)")
    }

    /// 円は刻みの継ぎ目ごとに円板を置く。引き算の切り口 (T 字の継ぎ目) で、丸めのために
    /// 画素の中心がどちらの三角形にも入る筋が数画素出うる (#1536 条件 2 の「5 画素以下」)。
    @Test("素通しの断片を付けた円の半透明の線は、刻みの継ぎ目で重ねて混ぜない", arguments: [Float(80), 16, 12])
    func shadedCirclesBlendOnce(_ diameter: Float) throws {
        let pixels = try translucent(shaded: true) { canvas in
            canvas.strokeWeight(20)
            canvas.circle(80, 80, diameter)
        }
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count <= 5, "直径 \(diameter): \(overpainted(pixels))")
    }

    // MARK: - #1536 条件 3: 起票時の曲線

    /// 塗られた画素の数は、重ね塗りの無い不透明の同じ曲線と同じ (起票時 4437)。
    @Test("起票時の曲線の半透明の線は、刻みの継ぎ目で重ねて混ぜず、塗る領域も変わらない")
    func filedCurveBlendsOnce() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            Self.filedCurve(canvas)
        }
        let opaque = try render { canvas in
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(20)
            Self.filedCurve(canvas)
        }
        #expect(overpainted(pixels).count <= 5, "\(overpainted(pixels))")
        #expect(painted(pixels) == painted(opaque), "半透明 \(painted(pixels)) / 不透明 \(painted(opaque))")
        #expect(painted(opaque) == 4437)
    }

    // MARK: - #1536 条件 4: 下地を読む混ぜ方

    @Test("不透明な線でも、足す混ぜ方で角を重ねて足さない")
    func addedCornersAddOnce() throws {
        let pixels = try render { canvas in
            canvas.blendMode(.add)
            canvas.stroke(100, 0, 0)
            canvas.strokeWeight(20)
            Self.closedSquare(canvas)
        }
        var brightest: Float = 0
        for y in 0..<160 {
            for x in 0..<160 { brightest = max(brightest, pixels[x, y].red) }
        }
        #expect(pixels[80, 45].red > 0.1)
        #expect(brightest <= 0.11, "赤の最大: \(brightest)")
    }

    // MARK: - #1536 条件 5: 自己交差は 2 回のまま

    /// 線に沿って離れた部分が交わる所は、別々の `line` が交わるのと同じく 2 回混ぜる
    /// (#1536 の判断 1)。重ね塗りは交点の近くにしか残らない。
    @Test("開いた折れ線の自己交差は、別々の線の交差と同じく 2 回混ぜる")
    func selfIntersectionBlendsTwice() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.strokeJoin(.round)
            canvas.beginShape()
            canvas.vertex(20, 20)
            canvas.vertex(140, 140)
            canvas.vertex(140, 20)
            canvas.vertex(20, 140)
            canvas.endShape()
        }
        #expect(abs(pixels[80, 80].red - Self.twice) <= 0.01, "交点: \(pixels[80, 80].red)")
        let far = overpainted(pixels).filter { point in
            let offset = SIMD2<Float>(Float(point.x - 80), Float(point.y - 80))
            return (offset * offset).sum() > 100
        }
        #expect(far.isEmpty, "交点から 10 画素より遠い重ね塗り: \(far)")
    }

    // MARK: - #1536 条件 6: 塗る領域は変わらない

    /// 引き算は片の和を変えない。不透明の線は、引かずに積む (組み込みの断片・`blend`) 絵と
    /// 引いて積む (`shader()`) 絵が 1 画素も違わない — 穴もはみ出しも無いことの見張り。
    @Test(
        "不透明の線は、素通しの断片を付けて引いて積んでも、付けない絵と 1 画素も違わない",
        arguments: [0, 1, 2, 3, 4])
    func opaqueStrokeKeepsItsRegion(_ shape: Int) throws {
        func draw(_ canvas: Canvas) {
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(20)
            switch shape {
            case 0: Self.closedSquare(canvas)
            case 1:
                canvas.strokeJoin(.round)
                Self.closedSquare(canvas)
            case 2: Self.sharpFold(canvas)
            case 3: Self.twoPoints(canvas)
            default: Self.filedCurve(canvas)
            }
        }
        let plain = try render(shaded: false, draw)
        let shaded = try render(shaded: true, draw)
        #expect(painted(plain) > 0)
        #expect(differingPixels(plain, shaded) == 0, "\(holes(plain, shaded))")
    }

    // MARK: - #1562: 細長い楕円と扇

    /// 上下の弧は線に沿っては離れているが、太さが短径を超えると画面で重なる。基本図形は
    /// 線全体を 1 回だけ混ぜる。塗られた画素の数は起票時 (main `d38308e`) の値と同じ。
    @Test("素通しの断片を付けた細長い楕円と扇の半透明の線は、向かい合う弧の重なりも 1 回だけ混ぜる")
    func thinEllipseAndArcBlendOnce() throws {
        let ellipse = try translucent(shaded: true) { canvas in
            canvas.strokeWeight(20)
            canvas.ellipse(80, 80, 100, 6)
        }
        #expect(overpainted(ellipse).count <= 5, "ellipse: \(overpainted(ellipse).count)")
        #expect(painted(ellipse) == 2747)
        let arc = try translucent(shaded: true) { canvas in
            canvas.strokeWeight(20)
            canvas.arc(80, 80, 100, 6, 0, Float.pi)
        }
        #expect(overpainted(arc).count <= 5, "arc: \(overpainted(arc).count)")
        #expect(painted(arc) == 2572)
    }
}
