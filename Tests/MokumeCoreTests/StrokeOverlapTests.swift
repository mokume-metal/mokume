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

    // MARK: - 反証で足した口

    /// 辺の交わらない `quad` は自己交差しないので、線全体を 1 回だけ混ぜる。凹んだ `quad` では、
    /// 向かい合う辺 (線に沿って太さより離れている) が凹みの近くで太さの中に入って重なる。
    ///
    /// `triangle` は 3 本の帯がどれも隣り合う (線に沿った隙間が 0) ので、任意多角形の規則の
    /// ままでも全部の重なりを引く。
    @Test("凹んだ quad の半透明の線は、向かい合う辺の重なりも 1 回だけ混ぜる")
    func concaveQuadBlendsOnce() throws {
        let quad = try translucent { canvas in
            canvas.strokeWeight(20)
            canvas.quad(20, 80, 140, 40, 60, 80, 140, 120)
        }
        #expect(painted(quad) > 0)
        #expect(overpainted(quad).count <= 5, "quad: \(overpainted(quad).count)")
    }

    /// 辺が交差する `quad` (砂時計) は、任意多角形の自己交差と同じく交点で 2 回混ぜる。
    @Test("辺が交差する quad の半透明の線は、交点で 2 回混ぜる")
    func crossedQuadBlendsTwiceAtTheCrossing() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.quad(20, 20, 140, 140, 140, 20, 20, 140)
        }
        #expect(abs(pixels[80, 80].red - Self.twice) <= 0.01, "交点: \(pixels[80, 80].red)")
    }

    /// 引き算は変換の前の座標で行う。回して伸ばしても重ね塗りは出ない。
    @Test("回して伸ばした閉じた 4 点の半透明の線も、角で重ねて混ぜない")
    func transformedPolygonBlendsOnce() throws {
        let pixels = try translucent { canvas in
            canvas.translate(80, 80)
            canvas.rotate(0.4)
            canvas.scale(1.3, 0.9)
            canvas.strokeWeight(14)
            canvas.beginShape()
            canvas.vertex(-40, -40)
            canvas.vertex(40, -40)
            canvas.vertex(40, 40)
            canvas.vertex(-40, 40)
            canvas.endShape(.close)
        }
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count <= 5, "\(overpainted(pixels).count)")
    }

    /// 同じ円を並べると、2 つ目から雛形に畳まれる。雛形も引いて積む。
    @Test("素通しの断片を付けて畳まれた円の半透明の線も、刻みの継ぎ目で重ねて混ぜない")
    func foldedCirclesBlendOnce() throws {
        let pixels = try translucent(shaded: true) { canvas in
            canvas.strokeWeight(10)
            canvas.circle(45, 80, 50)
            canvas.circle(115, 80, 50)
        }
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count <= 5, "\(overpainted(pixels).count)")
    }

    /// 半透明の線で記録した保持した形は、記録の時点で引いて積む。
    @Test("半透明の線で記録した保持した形も、角で重ねて混ぜない")
    func translucentRecordedShapeBlendsOnce() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var shape = Shape.empty
        try canvas.draw {
            shape = canvas.createShape {
                canvas.noFill()
                canvas.stroke(255, 0, 0, 128)
                canvas.strokeWeight(20)
                Self.closedSquare(canvas)
            }
        }
        try canvas.draw {
            canvas.background(black)
            canvas.shape(shape)
        }
        let pixels = try canvas.target.readPixels()
        #expect(abs(pixels[45, 45].red - Self.once) <= 0.01, "角 (45, 45): \(pixels[45, 45].red)")
        #expect(overpainted(pixels).count == 0)
    }

    /// 穴 (`beginContour`) の周も、外周とは別に同じ規則で積む。
    @Test("穴を持つ形の半透明の線は、外周と穴の角で重ねて混ぜない")
    func contourCornersBlendOnce() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.beginShape()
            canvas.vertex(20, 20)
            canvas.vertex(140, 20)
            canvas.vertex(140, 140)
            canvas.vertex(20, 140)
            canvas.beginContour()
            canvas.vertex(60, 60)
            canvas.vertex(60, 100)
            canvas.vertex(100, 100)
            canvas.vertex(100, 60)
            canvas.endContour()
            canvas.endShape(.close)
        }
        #expect(abs(pixels[62, 62].red - Self.once) <= 0.01, "穴の角: \(pixels[62, 62].red)")
        #expect(overpainted(pixels).count == 0)
    }

    // MARK: - #1829: 不透明の線で記録した形に、置き場所で半透明の色を掛ける

    /// 置き場所で掛ける半透明の白。不透明度は `stroke(255, 0, 0, 128)` と同じ 128/255 なので、
    /// 直に半透明の線で描いた絵と画素まで揃えて比べられる。
    private static let veil: LinearRGBA = {
        let alpha = Float(128) / 255
        return LinearRGBA(premultipliedRed: alpha, green: alpha, blue: alpha, alpha: alpha)
    }()

    /// 不透明の赤の線で記録した形。**記録のときは不透明なので、片を重ねたまま積む。**
    private static func opaqueShape(
        _ canvas: Canvas, mode: BlendMode = .blend, weight: Float = 20,
        join: StrokeJoin = .miter, cap: StrokeCap = .round, _ body: (Canvas) -> Void
    ) -> Shape {
        canvas.createShape {
            canvas.noFill()
            canvas.blendMode(mode)
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(weight)
            canvas.strokeJoin(join)
            canvas.strokeCap(cap)
            body(canvas)
        }
    }

    /// 形を組み立て (`build`)、黒地へ置き場所を渡して置く。組み立ては置く絵と別のフレームで行う。
    private func placed(
        _ build: (Canvas) -> Shape, at placements: [Placement]
    ) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var shape = Shape.empty
        try canvas.draw { shape = build(canvas) }
        try canvas.draw {
            canvas.background(black)
            canvas.shape(shape, at: placements)
        }
        return try canvas.target.readPixels()
    }

    /// 直に半透明の線で描いた絵 (置き場所で掛けた絵の物差し)。
    private func directlyTranslucent(
        mode: BlendMode = .blend, weight: Float = 20, join: StrokeJoin = .miter,
        cap: StrokeCap = .round, _ body: (Canvas) -> Void
    ) throws -> PixelBuffer {
        try translucent { canvas in
            canvas.blendMode(mode)
            canvas.strokeWeight(weight)
            canvas.strokeJoin(join)
            canvas.strokeCap(cap)
            body(canvas)
        }
    }

    /// 起票時の再現手順そのもの。線形の赤で読む: 直に半透明の線で描けば、辺の中ほども角も 0.413。
    @Test("不透明の線で記録した形に半透明の色を掛けて置いても、角で重ねて混ぜない (再現手順)")
    func reproductionOfTheIssue() throws {
        let pixels = try placed(
            { canvas in
                canvas.createShape {
                    canvas.noFill()
                    canvas.stroke(255, 0, 0)
                    canvas.strokeWeight(20)
                    canvas.beginShape()
                    canvas.vertex(40, 40)
                    canvas.vertex(120, 40)
                    canvas.vertex(120, 120)
                    canvas.vertex(40, 120)
                    canvas.endShape(.close)
                }
            },
            at: [
                Placement(
                    fill: LinearRGBA(premultipliedRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5))
            ])
        #expect(abs(pixels[80, 45].red - Self.once) <= 0.01, "辺の中ほど (80, 45): \(pixels[80, 45].red)")
        #expect(abs(pixels[45, 45].red - Self.once) <= 0.01, "角 (45, 45): \(pixels[45, 45].red)")
        #expect(overpainted(pixels).count == 0, "重ね塗り: \(overpainted(pixels).count)")
    }

    @Test(
        "不透明の線で記録した閉じた 4 点に半透明の色を掛けて置くと、直に半透明の線で描いた絵と 1 画素も違わない",
        arguments: [StrokeJoin.miter, .bevel, .round])
    func tintedClosedPolygonMatchesTranslucentDrawing(_ join: StrokeJoin) throws {
        let pixels = try placed(
            { Self.opaqueShape($0, join: join, Self.closedSquare) }, at: [Placement(fill: Self.veil)])
        let direct = try directlyTranslucent(join: join, Self.closedSquare)
        #expect(overpainted(pixels).count == 0, "\(join): \(overpainted(pixels).count)")
        #expect(abs(pixels[80, 45].red - Self.once) <= 0.01, "辺の中ほど: \(pixels[80, 45].red)")
        #expect(abs(pixels[45, 45].red - Self.once) <= 0.01, "角 (45, 45): \(pixels[45, 45].red)")
        #expect(differingPixels(pixels, direct) == 0, "\(join): \(holes(pixels, direct))")
    }

    @Test("不透明の線で記録した鋭く折れた折れ線に半透明の色を掛けて置くと、直に描いた絵と 1 画素も違わない")
    func tintedSharpFoldMatchesTranslucentDrawing() throws {
        let pixels = try placed(
            { Self.opaqueShape($0, Self.sharpFold) }, at: [Placement(fill: Self.veil)])
        let direct = try directlyTranslucent(Self.sharpFold)
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count == 0)
        #expect(differingPixels(pixels, direct) == 0, "\(holes(pixels, direct))")
    }

    @Test(
        "不透明の線で記録した 2 点の形に半透明の色を掛けて置くと、端の形と帯を重ねて混ぜない",
        arguments: [StrokeCap.round, .project])
    func tintedTwoPointCapsMatchTranslucentDrawing(_ cap: StrokeCap) throws {
        let pixels = try placed(
            { Self.opaqueShape($0, cap: cap, Self.twoPoints) }, at: [Placement(fill: Self.veil)])
        let direct = try directlyTranslucent(cap: cap, Self.twoPoints)
        #expect(abs(pixels[44, 80].red - Self.once) <= 0.01, "端から 4 内側: \(pixels[44, 80].red)")
        #expect(overpainted(pixels).count == 0, "\(cap)")
        #expect(differingPixels(pixels, direct) == 0, "\(cap): \(holes(pixels, direct))")
    }

    @Test("不透明の線で記録した曲線に半透明の色を掛けて置くと、刻みの継ぎ目で重ねて混ぜず、塗る領域も変わらない")
    func tintedCurveMatchesTranslucentDrawing() throws {
        let pixels = try placed(
            { Self.opaqueShape($0, Self.filedCurve) }, at: [Placement(fill: Self.veil)])
        let direct = try directlyTranslucent(Self.filedCurve)
        #expect(overpainted(pixels).count <= 5, "\(overpainted(pixels))")
        #expect(painted(pixels) == painted(direct), "置いた \(painted(pixels)) / 直に \(painted(direct))")
        #expect(differingPixels(pixels, direct) == 0, "\(holes(pixels, direct))")
    }

    /// **色を掛けなければ、絵は変わらない** (#1829 の条件 2)。不透明の色 (`alpha` が 1) を
    /// 掛けても同じ。引いた片に差し替えるのは、掛けた後の不透明度が 1 を下回るときだけである。
    @Test(
        "不透明の線で記録した形は、色を掛けずに置いても不透明の色を掛けて置いても、直に描いた不透明の絵と 1 画素も違わない",
        arguments: [0, 1, 2, 3, 4])
    func untintedRecordingKeepsItsPixels(_ shape: Int) throws {
        func draw(_ canvas: Canvas) {
            switch shape {
            case 0: Self.closedSquare(canvas)
            case 1: Self.sharpFold(canvas)
            case 2: Self.twoPoints(canvas)
            case 3: Self.filedCurve(canvas)
            default:
                canvas.beginShape()
                canvas.vertex(30, 30)
                canvas.bezierVertex(140, 20, 140, 140, 30, 130)
                canvas.endShape(.close)
            }
        }
        let cap: StrokeCap = shape == 2 ? .project : .round
        let direct = try render { canvas in
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(20)
            canvas.strokeCap(cap)
            draw(canvas)
        }
        let plain = try placed({ Self.opaqueShape($0, cap: cap, draw) }, at: [Placement()])
        let opaqueTint = try placed(
            { Self.opaqueShape($0, cap: cap, draw) },
            at: [Placement(fill: LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1))])
        #expect(painted(direct) > 0)
        #expect(differingPixels(plain, direct) == 0, "色なし: \(holes(plain, direct))")
        #expect(differingPixels(opaqueTint, direct) == 0, "不透明の色: \(holes(opaqueTint, direct))")
    }

    /// 引いて積むと、不透明の絵でも縁の画素が動きうる (`strokeOverlapsShow`)。参照スケッチの葉
    /// (`TypeAndImagery`・塗りと細い曲線の線を回して 9 枚並べる) は、記録の間も引くと 10 画素が
    /// 入れ替わり、台帳が動いた。**色を掛けずに置くなら、引かずに重ねて積んだ頂点のまま置く。**
    @Test("不透明の線で記録した葉の群れは、色を掛けずに置くと、直に描いた絵と 1 画素も違わない")
    func untintedLeafClusterKeepsItsPixels() throws {
        func leaves(_ canvas: Canvas) {
            canvas.fill(115, 217, 128)
            canvas.stroke(31, 89, 56)
            canvas.strokeWeight(2)
            for index in 0..<9 {
                canvas.push()
                canvas.translate(Float(20 + index % 3 * 46), Float(24 + index / 3 * 46))
                canvas.rotate(Float(index) * 0.4)
                canvas.beginShape()
                canvas.vertex(0, -22)
                canvas.bezierVertex(16, -14, 16, 14, 0, 22)
                canvas.bezierVertex(-16, 14, -16, -14, 0, -22)
                canvas.endShape(.close)
                canvas.pop()
            }
        }
        func drawn(_ tint: LinearRGBA?, recording: Bool) throws -> PixelBuffer {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
            var shape = Shape.empty
            if recording { try canvas.draw { shape = canvas.createShape { leaves(canvas) } } }
            try canvas.draw {
                canvas.background(black)
                if recording {
                    canvas.shape(shape, at: [Placement(fill: tint)])
                } else {
                    leaves(canvas)
                }
            }
            return try canvas.target.readPixels()
        }
        let direct = try drawn(nil, recording: false)
        let plain = try drawn(nil, recording: true)
        let opaqueTint = try drawn(
            LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1), recording: true)
        #expect(painted(direct) > 0)
        #expect(differingPixels(plain, direct) == 0, "色なし: \(holes(plain, direct))")
        #expect(differingPixels(opaqueTint, direct) == 0, "不透明の色: \(holes(opaqueTint, direct))")
    }

    /// 同じ形を、色を掛けない置き場所と掛ける置き場所で並べて置く。**置き場所ごとに決まる。**
    @Test("不透明の線で記録した形は、色を掛けない置き場所と掛ける置き場所を混ぜて置いても、それぞれ直に描いた絵と同じ")
    func mixedPlacementsDecidePerPlacement() throws {
        func small(_ canvas: Canvas) {
            canvas.beginShape()
            canvas.vertex(20, 20)
            canvas.vertex(50, 20)
            canvas.vertex(50, 50)
            canvas.vertex(20, 50)
            canvas.endShape(.close)
        }
        let pixels = try placed(
            { Self.opaqueShape($0, weight: 12, small) },
            at: [Placement(), Placement(x: 90, fill: Self.veil), Placement(y: 90)])
        let opaque = try render { canvas in
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(12)
            small(canvas)
            canvas.translate(0, 90)
            small(canvas)
        }
        let veiled = try directlyTranslucent(weight: 12) { canvas in
            canvas.translate(90, 0)
            small(canvas)
        }
        var wrong: [SIMD2<Int>] = []
        for y in 0..<160 {
            for x in 0..<160 {
                // 右上の 1 か所だけ色を掛けて置いた。それ以外は不透明のまま
                let expected = x >= 80 && y < 80 ? veiled[x, y] : opaque[x, y]
                if pixels[x, y] != expected { wrong.append(SIMD2(x, y)) }
            }
        }
        #expect(painted(opaque) > 0 && painted(veiled) > 0)
        #expect(wrong.isEmpty, "食い違い \(wrong.count): \(wrong.prefix(8))")
    }

    /// 回して縮めた置き場所でも、掛ける色が半透明なら角で重ならない。変換の合成で丸めが入る
    /// ので、直に描いた絵とは 1 画素ごとには揃えず、重ね塗りが無いことで見る。
    @Test("不透明の線で記録した形を、回して縮めて半透明の色を掛けて置いても、角で重ねて混ぜない")
    func tintedTransformedPlacementBlendsOnce() throws {
        let pixels = try placed(
            { Self.opaqueShape($0, weight: 16, Self.closedSquare) },
            at: [
                Placement(
                    x: 30, y: 10, scale: 0.8, rotation: SIMD3(0, 0, 0.4), fill: Self.veil)
            ])
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count == 0, "\(overpainted(pixels).count)")
    }

    // MARK: 兄弟の口 (ADR-0040)

    /// 記録の中で置き直した形は、外側の記録が輪郭の元を持ち歩く。
    @Test("不透明の線で記録した形を入れ子に置いた形に、半透明の色を掛けて置いても、角で重ねて混ぜない")
    func nestedRecordingKeepsTheCarvedPieces() throws {
        let pixels = try placed(
            { canvas in
                let inner = Self.opaqueShape(canvas, Self.closedSquare)
                return canvas.createShape { canvas.shape(inner) }
            },
            at: [Placement(fill: Self.veil)])
        let direct = try directlyTranslucent(Self.closedSquare)
        #expect(overpainted(pixels).count == 0, "\(overpainted(pixels).count)")
        #expect(differingPixels(pixels, direct) == 0, "\(holes(pixels, direct))")
    }

    /// 記録の中で半透明の色を掛けて置いたものは、その場で引いて積む。外側は色を掛けずに置いてよい。
    @Test("記録の中で半透明の色を掛けて置いた形は、外側を色なしで置いても、角で重ねて混ぜない")
    func tintedInsideRecordingBlendsOnce() throws {
        let pixels = try placed(
            { canvas in
                let inner = Self.opaqueShape(canvas, Self.closedSquare)
                return canvas.createShape {
                    canvas.shape(inner, at: [Placement(fill: Self.veil)])
                }
            },
            at: [Placement()])
        let direct = try directlyTranslucent(Self.closedSquare)
        #expect(overpainted(pixels).count == 0, "\(overpainted(pixels).count)")
        #expect(differingPixels(pixels, direct) == 0, "\(holes(pixels, direct))")
    }

    /// 内側で 1 度、外側で 1 度と、2 度半透明の色を掛けても、引いて積んだ片のまま。
    @Test("記録の中と外の両方で半透明の色を掛けて置いても、角で重ねて混ぜない")
    func tintedTwiceBlendsOnce() throws {
        let half = LinearRGBA(premultipliedRed: 0.7, green: 0.7, blue: 0.7, alpha: 0.7)
        let pixels = try placed(
            { canvas in
                let inner = Self.opaqueShape(canvas, Self.closedSquare)
                return canvas.createShape { canvas.shape(inner, at: [Placement(fill: half)]) }
            },
            at: [Placement(fill: half)])
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count == 0, "\(overpainted(pixels).count)")
        #expect(
            abs(pixels[45, 45].red - pixels[80, 45].red) <= 0.01,
            "角 \(pixels[45, 45].red) / 辺の中ほど \(pixels[80, 45].red)")
    }

    /// 組 (`Shape.group` と `+`) は並びを繋ぐだけなので、輪郭の元も繋がって残る。
    @Test("不透明の線で記録した 2 つの形を組にして半透明の色を掛けて置いても、角で重ねて混ぜない")
    func groupedRecordingsKeepTheCarvedPieces() throws {
        func left(_ canvas: Canvas) {
            canvas.beginShape()
            canvas.vertex(10, 10)
            canvas.vertex(70, 10)
            canvas.vertex(70, 70)
            canvas.vertex(10, 70)
            canvas.endShape(.close)
        }
        func right(_ canvas: Canvas) {
            canvas.beginShape()
            canvas.vertex(90, 90)
            canvas.vertex(150, 90)
            canvas.vertex(150, 150)
            canvas.vertex(90, 150)
            canvas.endShape(.close)
        }
        let direct = try directlyTranslucent(weight: 12) { canvas in
            left(canvas)
            right(canvas)
        }
        let grouped = try placed(
            { canvas in
                Shape.group([
                    Self.opaqueShape(canvas, weight: 12, left),
                    Self.opaqueShape(canvas, weight: 12, right),
                ])
            },
            at: [Placement(fill: Self.veil)])
        let added = try placed(
            { canvas in
                Self.opaqueShape(canvas, weight: 12, left)
                    + Self.opaqueShape(canvas, weight: 12, right)
            },
            at: [Placement(fill: Self.veil)])
        #expect(painted(direct) > 0)
        #expect(overpainted(grouped).count == 0)
        #expect(differingPixels(grouped, direct) == 0, "group: \(holes(grouped, direct))")
        #expect(differingPixels(added, direct) == 0, "+: \(holes(added, direct))")
    }

    /// 下地を読まない `replace` は、重ねて積んでも同じ色になる。引かずに積んだままで、直に描いた絵と同じ。
    @Test("置き換える混ぜ方で記録した不透明の線に半透明の色を掛けて置いても、直に描いた絵と 1 画素も違わない")
    func tintedReplaceStrokeMatchesDirectDrawing() throws {
        let pixels = try placed(
            { Self.opaqueShape($0, mode: .replace, Self.closedSquare) }, at: [Placement(fill: Self.veil)])
        let direct = try directlyTranslucent(mode: .replace, Self.closedSquare)
        #expect(painted(pixels) > 0)
        #expect(differingPixels(pixels, direct) == 0, "\(holes(pixels, direct))")
    }

    /// 明るいほう・暗いほうを採る混ぜ方は、不透明なら重ねても同じ色になるが、半透明なら 2 回目で
    /// 寄っていく (`strokeOverlapsShow`)。
    @Test(
        "明るいほう・暗いほうを採る混ぜ方で記録した不透明の線に半透明の色を掛けて置いても、直に描いた絵と 1 画素も違わない",
        arguments: [BlendMode.lightest, .darkest])
    func tintedLightestAndDarkestStrokesMatchDirectDrawing(_ mode: BlendMode) throws {
        // 地は灰色。線の赤は、明るいほうでは地より明るい所、暗いほうでは地より暗い所に効く
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var shape = Shape.empty
        try canvas.draw { shape = Self.opaqueShape(canvas, mode: mode, Self.closedSquare) }
        try canvas.draw {
            canvas.background(90, 90, 90)
            canvas.shape(shape, at: [Placement(fill: Self.veil)])
        }
        let pixels = try canvas.target.readPixels()
        let direct = try render { canvas in
            canvas.background(90, 90, 90)
            canvas.blendMode(mode)
            canvas.stroke(255, 0, 0, 128)
            canvas.strokeWeight(20)
            Self.closedSquare(canvas)
        }
        #expect(differingPixels(pixels, direct) == 0, "\(mode): \(holes(pixels, direct))")
    }

    // MARK: 塗りと線が同じ区間にある形・線が区間の途中から始まる形 (反証で足した口)

    private static let redInk = LinearRGBA(premultipliedRed: 1, green: 0, blue: 0, alpha: 1)
    private static let blueInk = LinearRGBA(premultipliedRed: 0, green: 0, blue: 1, alpha: 1)
    /// 半透明の赤。0.5 は 2 進で正確に表せるので、0.5 倍・0.25 倍しても成分がずれない。
    private static let paleRedInk = LinearRGBA(premultipliedRed: 0.5, green: 0, blue: 0, alpha: 0.5)
    /// 半分の不透明度の白。掛けた色は、直に描く色 (0.5 倍) と成分までビット一致する。
    private static let halfVeil = LinearRGBA(premultipliedRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)

    private static func scaled(_ color: LinearRGBA, by factor: Float) -> LinearRGBA {
        LinearRGBA(
            premultipliedRed: color.red * factor, green: color.green * factor,
            blue: color.blue * factor, alpha: color.alpha * factor)
    }

    /// 一辺 16 の閉じた四角。`fill` / `stroke` が無ければ、塗りだけ・線だけの形になる。
    /// `factor` は、置き場所で色を掛けた絵を直に描くときの倍率。
    private static func square(
        _ canvas: Canvas, x: Float, y: Float, fill: LinearRGBA?, stroke: LinearRGBA?,
        factor: Float = 1
    ) {
        if let fill { canvas.fill(scaled(fill, by: factor)) } else { canvas.noFill() }
        if let stroke {
            canvas.stroke(scaled(stroke, by: factor))
            canvas.strokeWeight(4)
        } else {
            canvas.noStroke()
        }
        canvas.beginShape()
        canvas.vertex(x, y)
        canvas.vertex(x + 16, y)
        canvas.vertex(x + 16, y + 16)
        canvas.vertex(x, y + 16)
        canvas.endShape(.close)
    }

    /// 塗りと不透明の線が、同じ区間で並ぶ形。塗りの上に線が載る。
    @Test("塗りと不透明の線を持つ形に半透明の色を掛けて置くと、直に描いた絵と 1 画素も違わない")
    func tintedFillAndOpaqueStrokeMatchDirectDrawing() throws {
        let pixels = try placed(
            { canvas in
                canvas.createShape {
                    canvas.fill(Self.blueInk)
                    canvas.stroke(Self.redInk)
                    canvas.strokeWeight(20)
                    Self.closedSquare(canvas)
                }
            },
            at: [Placement(fill: Self.halfVeil)])
        let direct = try render { canvas in
            canvas.fill(Self.scaled(Self.blueInk, by: 0.5))
            canvas.stroke(Self.scaled(Self.redInk, by: 0.5))
            canvas.strokeWeight(20)
            Self.closedSquare(canvas)
        }
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count == 0, "\(overpainted(pixels).count)")
        #expect(differingPixels(pixels, direct) == 0, "\(holes(pixels, direct))")
    }

    /// 線の手前に塗りだけの頂点が並び、線どうしの間には、半透明の線で記録した (記録のときに引いた)
    /// 線と塗りだけの頂点が挟まる。差し替える線は、置いた先で位置がずれる (`place` の
    /// `cursor` と `shift`)。置き場所は、色を掛けるもの・掛けないものを混ぜて 3 か所。
    private static func mixedPieces(_ canvas: Canvas, factor: Float) {
        square(canvas, x: 6, y: 6, fill: nil, stroke: paleRedInk, factor: factor)
        square(canvas, x: 34, y: 6, fill: blueInk, stroke: redInk, factor: factor)
        square(canvas, x: 6, y: 34, fill: blueInk, stroke: nil, factor: factor)
        square(canvas, x: 34, y: 34, fill: nil, stroke: redInk, factor: factor)
        square(canvas, x: 56, y: 56, fill: blueInk, stroke: nil, factor: factor)
    }

    @Test("線が区間の途中から始まる形は、色を掛ける置き場所と掛けない置き場所を混ぜて置いても、それぞれ直に描いた絵と同じ")
    func strokesStartingMidRunKeepTheirPlace() throws {
        let pixels = try placed(
            { canvas in canvas.createShape { Self.mixedPieces(canvas, factor: 1) } },
            at: [
                Placement(fill: Self.halfVeil), Placement(x: 80),
                Placement(y: 80, fill: Self.halfVeil),
            ])
        let direct = try render { canvas in
            Self.mixedPieces(canvas, factor: 0.5)
            canvas.push()
            canvas.translate(80, 0)
            Self.mixedPieces(canvas, factor: 1)
            canvas.pop()
            canvas.push()
            canvas.translate(0, 80)
            Self.mixedPieces(canvas, factor: 0.5)
            canvas.pop()
        }
        #expect(painted(pixels) > 0)
        #expect(differingPixels(pixels, direct) == 0, "\(holes(pixels, direct))")
    }

    /// 入れ子 (記録済みの形をそのまま置く・記録の中で半透明の色を掛けて置く) と、組 (`group` と `+`) が
    /// 混ざった形。内側で 1 度 (0.5)、外側で 1 度 (0.5) と、2 度掛かる輪郭は 0.25 倍になる。
    @Test("入れ子と組を混ぜた形に半透明の色を掛けて置いても、直に描いた絵と 1 画素も違わない")
    func nestedAndGroupedShapesKeepTheirPlace() throws {
        func build(_ canvas: Canvas, grouping: (Shape, Shape) -> Shape) -> Shape {
            let inner = canvas.createShape {
                Self.square(canvas, x: 6, y: 6, fill: Self.blueInk, stroke: Self.redInk)
            }
            let outer = canvas.createShape {
                Self.square(canvas, x: 34, y: 6, fill: Self.blueInk, stroke: nil)
                canvas.shape(inner)
                Self.square(canvas, x: 6, y: 34, fill: nil, stroke: Self.redInk)
                canvas.shape(inner, at: [Placement(x: 28, y: 28, fill: Self.halfVeil)])
            }
            let other = canvas.createShape {
                Self.square(canvas, x: 56, y: 6, fill: nil, stroke: Self.redInk)
            }
            return grouping(outer, other)
        }
        let direct = try render { canvas in
            Self.square(canvas, x: 34, y: 6, fill: Self.blueInk, stroke: nil, factor: 0.5)
            Self.square(canvas, x: 6, y: 6, fill: Self.blueInk, stroke: Self.redInk, factor: 0.5)
            Self.square(canvas, x: 6, y: 34, fill: nil, stroke: Self.redInk, factor: 0.5)
            Self.square(canvas, x: 34, y: 34, fill: Self.blueInk, stroke: Self.redInk, factor: 0.25)
            Self.square(canvas, x: 56, y: 6, fill: nil, stroke: Self.redInk, factor: 0.5)
        }
        let grouped = try placed(
            { canvas in build(canvas) { Shape.group([$0, $1]) } }, at: [Placement(fill: Self.halfVeil)])
        let added = try placed(
            { canvas in build(canvas) { $0 + $1 } }, at: [Placement(fill: Self.halfVeil)])
        #expect(painted(direct) > 0)
        #expect(differingPixels(grouped, direct) == 0, "group: \(holes(grouped, direct))")
        #expect(differingPixels(added, direct) == 0, "+: \(holes(added, direct))")
    }
}
