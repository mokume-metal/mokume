// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd
import Testing

@testable import MokumeCore

/// 値としての道 (``Path``) の問いと、円からの作り方 (#3561)。GPU は要らない。
@Suite("道の問い (値)")
nonisolated struct PathValueTests {
    private func square(closed: Bool = true) -> Path {
        Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: closed,
                isCurveStep: [false, false, false, false])
        ])
    }

    @Test("円から作った道の長さは 2πr に近く、刻みの細かさで決まる隔たりに収まる。中心は内側で、外は外側")
    func aCircleBecomesAPath() {
        for radius: Float in [10, 0.5, 300] {
            let path = Path(Circle(center: [0, 0], radius: radius))
            let exact = 2 * Float.pi * radius
            #expect(path.length <= exact, "折れ線は円周より短い")
            #expect(path.length > exact * 0.9995, "r=\(radius): \(path.length) / \(exact)")
            #expect(path.contains([0, 0]))
            #expect(!path.contains([radius * 1.1, 0]))
            #expect(path.contains([radius * 0.9, 0]))
        }
        let ten = Path(Circle(center: [0, 0], radius: 10))
        #expect(ten.contains([0, 0]) && !ten.contains([11, 0]))
        #expect(abs(ten.length - 2 * .pi * 10) < 0.02, "半径 10: \(ten.length)")
    }

    @Test("半径が 0 以下か数でない円は、空の道になる")
    func degenerateCirclesAreEmpty() {
        for radius: Float in [0, -5, .nan, .infinity] {
            let path = Path(Circle(center: [3, 4], radius: radius))
            #expect(path.length == 0 && !path.contains([3, 4]), "r=\(radius)")
        }
        #expect(Path(Circle(center: [.nan, 0], radius: 5)).length == 0)
    }

    @Test("空の道は、長さが 0・内側は常に偽・point(at:) は原点")
    func theEmptyPath() {
        let path = Path()
        #expect(path.length == 0)
        #expect(!path.contains([0, 0]) && !path.contains([1e9, -1e9]))
        for t: Float in [0, 0.5, 1, -3, .nan, .infinity] {
            #expect(path.point(at: t) == Vector2(0, 0), "t=\(t)")
        }
    }

    @Test("正方形の長さ・弧長の点・内側。開いていれば閉じる辺を数えない")
    func aSquare() {
        let closed = square()
        #expect(closed.length == 400)
        #expect(closed.point(at: 0) == [0, 0])
        #expect(closed.point(at: 0.25) == [100, 0])
        #expect(closed.point(at: 0.5) == [100, 100])
        #expect(closed.point(at: 0.75) == [0, 100])
        #expect(closed.point(at: 1) == [0, 0], "閉じた道の終点は始点に戻る")
        #expect(closed.point(at: 0.125) == [50, 0])
        #expect(closed.contains([50, 50]) && !closed.contains([150, 50]) && !closed.contains([50, -1]))

        let open = square(closed: false)
        #expect(open.length == 300, "閉じる辺 (0,100)→(0,0) を数えない")
        #expect(open.point(at: 1) == [0, 100])
        #expect(open.contains([50, 50]), "塗りと contains では閉じた形として扱う")
    }

    @Test("t は 0…1 に締め、数でない t は 0 として扱う")
    func tIsClamped() {
        let path = square()
        #expect(path.point(at: -1) == path.point(at: 0))
        #expect(path.point(at: 7) == path.point(at: 1))
        #expect(path.point(at: Float.infinity) == path.point(at: 1))
        #expect(path.point(at: -Float.infinity) == path.point(at: 0))
        #expect(path.point(at: Float.nan) == path.point(at: 0), "数でない t は始点")
    }

    @Test("長さ 0 の道 (点が 1 つ・全部同じ所) は、最初の点を返し、落ちない")
    func zeroLengthPaths() {
        let dot = Path(subpaths: [Path.Subpath(points: [[7, 8]], isClosed: false, isCurveStep: [false])])
        #expect(dot.length == 0)
        #expect(dot.point(at: 0.5) == [7, 8])
        #expect(!dot.contains([7, 8]))
        let stacked = Path(subpaths: [
            Path.Subpath(points: [[3, 3], [3, 3], [3, 3]], isClosed: true, isCurveStep: [false, false, false])
        ])
        #expect(stacked.point(at: 1) == [3, 3])
    }

    @Test("部分道が複数あるとき、辿る順は並べた順で、継ぎ目の間の辺は数えない")
    func severalSubpaths() {
        let path = Path(subpaths: [
            Path.Subpath(points: [[0, 0], [10, 0]], isClosed: false, isCurveStep: [false, false]),
            Path.Subpath(points: [[100, 100], [100, 120]], isClosed: false, isCurveStep: [false, false]),
        ])
        #expect(path.length == 30)
        #expect(path.point(at: 0.5) == [100, 105], "15 進んだ所: 1 本目の 10 の後、2 本目の始点から 5")
        #expect(path.point(at: 1) == [100, 120])
        #expect(path.point(at: 0) == [0, 0])
    }

    @Test("内側は回り数で決める: 逆向きの穴は抜け、同じ向きの周は内側のまま")
    func windingRule() {
        func ring(_ low: Float, _ high: Float, clockwise: Bool) -> Path.Subpath {
            let corners: [SIMD2<Float>] = [[low, low], [high, low], [high, high], [low, high]]
            return Path.Subpath(
                points: clockwise ? corners : corners.reversed(), isClosed: true,
                isCurveStep: [false, false, false, false])
        }
        let hole = Path(subpaths: [ring(0, 100, clockwise: true), ring(25, 75, clockwise: false)])
        #expect(!hole.contains([50, 50]), "逆回りの穴")
        #expect(hole.contains([10, 10]))
        let same = Path(subpaths: [ring(0, 100, clockwise: true), ring(25, 75, clockwise: true)])
        #expect(same.contains([50, 50]), "同じ向きの周は回り数 2 で内側 (画面の塗りと同じ)")
        #expect(same.contains([10, 10]))
        #expect(!same.contains([150, 50]))
    }

    @Test("座標が ±3e38 級でも、弧長の歩みは Double で行い、point(at:) は端を取り違えない")
    func hugeCoordinates() {
        let path = Path(subpaths: [
            Path.Subpath(points: [[-3e38, 0], [3e38, 0]], isClosed: false, isCurveStep: [false, false])
        ])
        #expect(path.length.isInfinite, "Float に収まらない長さは無限になる (length は Float)")
        #expect(path.point(at: 0) == [-3e38, 0], "始点を返す (終点ではない)")
        #expect(path.point(at: 1) == [3e38, 0])
        let middle = path.point(at: 0.5)
        #expect(abs(middle.x) < 1e32 && middle.y == 0, "真ん中: \(middle)")
        let quarter = path.point(at: 0.25)
        #expect(abs(quarter.x - -1.5e38) < 1e32, "\(quarter)")
    }

    @Test("大きな半径の円も、刻みの上限 2048 本まで細かく刻む (Float で作ると 8 角形に退化していた)")
    func largeCirclesAreNotOctagons() {
        for radius: Float in [1e5, 7e5, 1e6, 1e9, 1e14, 1e15, 1e30] {
            let count = Path(Circle(center: [0, 0], radius: radius)).subpaths[0].points.count
            #expect(count > 100, "r=\(radius): \(count) 本")
        }
        #expect(Path(Circle(center: [0, 0], radius: 1e9)).subpaths[0].points.count == 2048)
        for radius: Float in [1e15, 1e30] {
            #expect(Path(Circle(center: [0, 0], radius: radius)).subpaths[0].points.count == 2048, "r=\(radius): 精度が尽きたら上限に倒す")
        }
        #expect(Path(Circle(center: [0, 0], radius: 1e6)).subpaths[0].points.count == 2048)
        // 刻みは半径が上がるほど増える (単調)
        let counts = [10, 100, 1000, 10000].map { Path(Circle(center: [0, 0], radius: Float($0))).subpaths[0].points.count }
        #expect(counts == counts.sorted())
    }

    @Test("座標が 1e19 を越える道でも、contains は辺を数え落とさない (差と積は Double)")
    func containsWithHugeCoordinates() {
        let huge = Path(Circle(center: [0, 0], radius: 1e20))
        #expect(huge.contains([0, 0]), "中心は内側")
        #expect(huge.contains([5e19, 0]) && !huge.contains([3e20, 0]))
        let box = Path(subpaths: [
            Path.Subpath(
                points: [[-1e30, -1e30], [1e30, -1e30], [1e30, 1e30], [-1e30, 1e30]], isClosed: true,
                isCurveStep: [false, false, false, false])
        ])
        #expect(box.contains([0, 0]) && !box.contains([2e30, 0]))
        // 斜めの辺で、差と積が両方 Float を越える (inf - inf で辺を数え落とす)
        let triangle = Path(subpaths: [
            Path.Subpath(
                points: [[-1e20, -1e20], [1e20, 1e20], [-1e20, 1e20]], isClosed: true,
                isCurveStep: [false, false, false])
        ])
        #expect(triangle.contains([-1e19, 1e19]), "内側")
        #expect(!triangle.contains([1e19, -1e19]), "外側")
    }

    @Test("数でない点は内側ではない")
    func nonFiniteProbe() {
        let path = square()
        #expect(!path.contains([.nan, 50]) && !path.contains([50, .infinity]))
    }
}

/// `createPath { }` で道を記録し、`shape(_:)` で描く (#3561)。
@Suite(
    "createPath と shape(path)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PathRecordingTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas(width: Int = 120, height: Int = 120) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// `draw()` の中で道を作って返す。
    private func record(_ canvas: Canvas, _ body: @escaping (Canvas) -> Void) throws -> Path {
        var made = Path()
        try canvas.draw { made = canvas.createPath { body(canvas) } }
        return made
    }

    private func picture(_ canvas: Canvas, _ body: (Canvas) -> Void) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(black)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    private func squareOutline(_ canvas: Canvas) {
        canvas.beginShape()
        canvas.vertex(0, 0)
        canvas.vertex(100, 0)
        canvas.vertex(100, 100)
        canvas.vertex(0, 100)
        canvas.endShape(.close)
    }

    // MARK: - 記録して問う

    @Test("折れ線から作って、長さ・弧長の点・内側を問える")
    func recordsAPolyline() throws {
        let path = try record(try makeCanvas()) { squareOutline($0) }
        #expect(path.length == 400)
        #expect(path.point(at: 0) == [0, 0])
        #expect(path.point(at: 0.25) == [100, 0])
        #expect(path.point(at: 0.5) == [100, 100])
        #expect(path.contains([50, 50]))
        #expect(!path.contains([150, 50]))
    }

    @Test("開いた部分道は、長さと point(at:) に閉じる辺を数えない。contains では閉じた形として扱う")
    func anOpenSubpathHasNoClosingEdge() throws {
        let path = try record(try makeCanvas()) { canvas in
            canvas.beginShape()
            canvas.vertex(0, 50)
            canvas.vertex(100, 50)
            canvas.endShape()
        }
        #expect(path.length == 100)
        #expect(path.point(at: 1) == [100, 50])
        let triangle = try record(try makeCanvas()) { canvas in
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(100, 0)
            canvas.vertex(0, 100)
            canvas.endShape()
        }
        #expect(triangle.contains([10, 10]), "開いたままでも、内側は閉じた形で数える")
    }

    @Test("beginContour の穴: 逆向きは抜け、同じ向きは内側のまま。beginShape を重ねた部分道も同じ規則")
    func holesFollowTheWindingRule() throws {
        func holed(_ canvas: Canvas, reversed: Bool) {
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(100, 0)
            canvas.vertex(100, 100)
            canvas.vertex(0, 100)
            canvas.beginContour()
            let hole: [(Float, Float)] = [(25, 25), (25, 75), (75, 75), (75, 25)]
            for point in reversed ? hole : hole.reversed() { canvas.vertex(point.0, point.1) }
            canvas.endContour()
            canvas.endShape(.close)
        }
        // 外周 (0,0)→(100,0)→(100,100)→(0,100) は画面で時計回り。穴 (25,25)→(25,75)→(75,75)→(75,25) は逆向き
        let hole = try record(try makeCanvas()) { holed($0, reversed: true) }
        #expect(!hole.contains([50, 50]))
        #expect(hole.contains([10, 10]))
        let same = try record(try makeCanvas()) { holed($0, reversed: false) }
        #expect(same.contains([50, 50]), "外周と同じ向きの周の中は内側")
        // 同じ 2 つを、beginShape を 2 回に分けて置いても同じ
        let apart = try record(try makeCanvas()) { canvas in
            squareOutline(canvas)
            canvas.beginShape()
            canvas.vertex(25, 25)
            canvas.vertex(25, 75)
            canvas.vertex(75, 75)
            canvas.vertex(75, 25)
            canvas.endShape(.close)
        }
        #expect(!apart.contains([50, 50]) && apart.contains([10, 10]))
        #expect(apart.length == 400 + 200)
    }

    @Test("曲線は刻んだ折れ線で持ち、入口の変換は単位に戻り、中の変換は焼き込まれる")
    func curvesAndTransforms() throws {
        let canvas = try makeCanvas()
        var outer = Path()
        var inner = Path()
        try canvas.draw {
            canvas.translate(50, 50)
            outer = canvas.createPath { squareOutline(canvas) }
            inner = canvas.createPath {
                canvas.translate(10, 20)
                canvas.scale(2, 2)
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(5, 0)
                canvas.endShape()
            }
        }
        #expect(outer.point(at: 0) == [0, 0], "外の translate は道に入らない")
        #expect(inner.point(at: 0) == [10, 20] && inner.point(at: 1) == [20, 20], "中の変換は焼き込む")

        let curved = try record(try makeCanvas()) { canvas in
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.bezierVertex(0, 60, 100, 60, 100, 0)
            canvas.endShape()
        }
        #expect(curved.length > 100 * 1.1, "弦より長い曲線の長さ: \(curved.length)")
        #expect(simd_distance(curved.point(at: 1).simd, SIMD2<Float>(100, 0)) < 1e-3)
        #expect(curved.subpaths[0].points.count > 4)
        #expect(curved.subpaths[0].isCurveStep.contains(true), "刻みの印を持つ")
        #expect(curved.subpaths[0].isCurveStep.first == false && curved.subpaths[0].isCurveStep.last == false)
    }

    @Test("空の createPath は空の道。落ちない")
    func anEmptyRecording() throws {
        let path = try record(try makeCanvas()) { _ in }
        #expect(path.length == 0 && !path.contains([0, 0]) && path.point(at: 0.5) == [0, 0])
    }

    @Test("入れ子: createPath の中の createShape の輪郭は外の道へ漏れず、createShape の中の createPath も外の形へ漏れない")
    func nestingDoesNotLeak() throws {
        let canvas = try makeCanvas()
        var inner = Shape.empty
        var outer = Path()
        try canvas.draw {
            outer = canvas.createPath {
                inner = canvas.createShape { squareOutline(canvas) }
            }
        }
        #expect(outer.length == 0, "中の形の輪郭が外の道へ漏れている")
        #expect(inner.bounds != nil, "中の形が空になっている")

        var innerPath = Path()
        var shape = Shape.empty
        try canvas.draw {
            shape = canvas.createShape {
                innerPath = canvas.createPath { squareOutline(canvas) }
            }
        }
        #expect(innerPath.length == 400)
        #expect(shape.isEmpty, "中の道の輪郭が外の形に描かれている")
        // 入れ子を抜けた後も、外の記録は続く
        let both = try record(canvas) { canvas in
            _ = canvas.createShape { canvas.rect(0, 0, 5, 5) }
            squareOutline(canvas)
        }
        #expect(both.length == 400)
    }

    @Test("bezier() は道に入る (開いた部分道)。基本図形のように断らない")
    func bezierIsRecorded() throws {
        let canvas = try makeCanvas()
        let path = try record(canvas) { $0.bezier(0, 0, 0, 60, 100, 60, 100, 0) }
        #expect(path.subpaths.count == 1 && !path.subpaths[0].isClosed)
        #expect(path.length > 110)
        #expect(simd_distance(path.point(at: 1).simd, SIMD2<Float>(100, 0)) < 1e-3)
        #expect(canvas.warnings.message(for: .insidePath(.primitive)) == nil, "bezier() は基本図形の断りを出さない")
    }

    @Test("createPath の中の shape(path) は、描き方に依らず、変換を掛けた部分道を 1 回ずつ足す")
    func shapeInsideCreatePathAddsSubpaths() throws {
        let canvas = try makeCanvas()
        let source = try record(canvas) { squareOutline($0) }
        func length(fill: Bool, stroke: Bool, subpaths: Int = 1) throws -> Path {
            try record(canvas) { canvas in
                fill ? canvas.fill(red) : canvas.noFill()
                stroke ? canvas.stroke(blue) : canvas.noStroke()
                canvas.translate(10, 20)
                for _ in 0..<subpaths { canvas.shape(source, 5, 0) }
            }
        }
        for (fill, stroke) in [(true, true), (false, false), (true, false), (false, true)] {
            let path = try length(fill: fill, stroke: stroke)
            #expect(path.length == 400, "fill=\(fill) stroke=\(stroke): \(path.length)")
            #expect(path.point(at: 0) == [15, 20], "変換 (10,20) と位置 (5,0) を掛けて足す")
        }
        let twice = try length(fill: true, stroke: true, subpaths: 2)
        #expect(twice.subpaths.count == 2 && twice.length == 800)
        // 複数の部分道の道も、描き方に依らず部分道の数のまま
        let two = try record(canvas) { canvas in
            squareOutline(canvas)
            canvas.beginShape()
            canvas.vertex(25, 25); canvas.vertex(25, 75); canvas.vertex(75, 75)
            canvas.endShape(.close)
        }
        for (fill, stroke) in [(true, true), (false, false)] {
            let nested = try record(canvas) { canvas in
                fill ? canvas.fill(red) : canvas.noFill()
                stroke ? canvas.stroke(blue) : canvas.noStroke()
                canvas.shape(two)
            }
            #expect(nested.subpaths.count == 2 && nested.length == two.length, "fill=\(fill) stroke=\(stroke)")
        }
    }

    @Test("非有限になる位置で足す shape(path) は、部分道を飛ばして、1 度知らせる")
    func nonFinitePlacementIsNamed() throws {
        let canvas = try makeCanvas()
        let far = Path(subpaths: [
            Path.Subpath(
                points: [[3e38, 0], [0, 0], [0, 1]], isClosed: true, isCurveStep: [false, false, false])
        ])
        let made = try record(canvas) { canvas in
            canvas.shape(far, 3e38, 0)
        }
        #expect(made.subpaths.isEmpty)
        #expect(canvas.warnings.hasWarned(.badVertex), "黙って捨てている")
    }

    @Test("createPath の中の部分道の並び順: shape(path) は即座に足し、開いた beginShape は endShape で足す")
    func subpathOrder() throws {
        let canvas = try makeCanvas()
        let source = try record(canvas) { squareOutline($0) }
        let made = try record(canvas) { canvas in
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(10, 0)
            canvas.shape(source)
            canvas.vertex(10, 10)
            canvas.endShape(.close)
        }
        try #require(made.subpaths.count == 2)
        #expect(made.subpaths[0].points.count == 4, "先に足された shape(path)")
        #expect(made.subpaths[1].points.count == 3, "endShape で足された外の形")
        #expect(made.point(at: 0) == [0, 0])
        // 辿る順は [source (400), 外の三角形]: 400 進んだ所は source の終点 (0,0)、そこから三角形の 10 先は (10, 0)
        let total = made.length
        #expect(simd_distance(made.point(at: 410 / total).simd, SIMD2<Float>(10, 0)) < 1e-3)
    }

    @Test("開いた beginShape の途中で shape(path) を呼んでも、外の形を黙って捨てない")
    func shapePathKeepsTheOpenShape() throws {
        let canvas = try makeCanvas()
        let source = try record(canvas) { squareOutline($0) }
        // 道の記録の中
        let inPath = try record(canvas) { canvas in
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(10, 0)
            canvas.shape(source)
            canvas.vertex(10, 10)
            canvas.endShape(.close)
        }
        #expect(inPath.subpaths.count == 2)
        let expected: Float = 400 + 10 + 10 + 10 * Float(2).squareRoot()
        #expect(abs(inPath.length - expected) < 1e-3, "\(inPath.length)")
        // 形の組み立ての中 (描く側)
        var shape = Shape.empty
        try canvas.draw {
            shape = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(10, 0)
                canvas.shape(source)
                canvas.vertex(10, 10)
                canvas.endShape(.close)
            }
        }
        #expect(!canvas.warnings.hasWarned(.shapeBegunWhileOpen), "外の形を捨てた")
        #expect(shape.bounds != nil)
    }

    @Test("先頭の部分道が 3 点に満たなくても (線・点)、残りの部分道は塗られ、contains とずれない")
    func fillSkipsSubpathsWithoutArea() throws {
        let line = Path.Subpath(points: [[0, 0], [5, 5]], isClosed: false, isCurveStep: [false, false])
        let box = Path.Subpath(
            points: [[20, 20], [100, 20], [100, 100], [20, 100]], isClosed: true,
            isCurveStep: [false, false, false, false])
        let path = Path(subpaths: [line, box])
        #expect(path.contains([60, 60]))
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            canvas.noStroke()
            canvas.fill(LinearRGBA.linear(red: 1, green: 1, blue: 1))
            canvas.shape(path)
        }
        let at = (60 * image.width + 60) * 4
        #expect(image.bytes[at] > 235, "先頭が線だと全体が塗られなかった: \(image.bytes[at])")
        // 線は線として引く: 線だけの道でも、線を引く側は落ちない
        let stroked = try picture(canvas) { canvas in
            canvas.noFill()
            canvas.stroke(LinearRGBA.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(3)
            canvas.shape(Path(subpaths: [line, box]))
        }
        #expect(stroked.bytes != (try picture(canvas) { _ in }).bytes)
    }

    @Test("残らない値 (頂点ごとの色・読み取り位置・面の向き) は、輪郭を残したまま、種類ごとに 1 度知らせる")
    func droppedVertexAttributesAreNamed() throws {
        let canvas = try makeCanvas()
        let path = try record(canvas) { canvas in
            canvas.beginShape()
            canvas.fill(red)
            canvas.vertex(0, 0)
            canvas.fill(blue)
            canvas.vertex(100, 0)
            canvas.vertex(100, 100, 3, 4)
            canvas.normal(0, 0, 1)
            canvas.vertex(0, 100)
            canvas.endShape(.close)
        }
        #expect(path.length == 400, "輪郭は残る")
        #expect(canvas.warnings.message(for: .insidePath(.vertexColour)) != nil)
        #expect(canvas.warnings.message(for: .insidePath(.textureCoordinate)) != nil)
        #expect(canvas.warnings.message(for: .insidePath(.normal)) != nil)
        // 同じ色・座標だけの形は黙っている
        let quiet = try makeCanvas()
        _ = try record(quiet) { squareOutline($0) }
        #expect(quiet.warnings.count { key in if case .insidePath = key { true } else { false } } == 0)
    }

    @Test("断りの文面は、呼んだ口の名前で言う: createPath の中は createPath、createShape の中は createShape")
    func noticesNameTheCaller() throws {
        let canvas = try makeCanvas()
        _ = try record(canvas) { canvas in
            canvas.background(red)
            canvas.push()
        }
        let background = try #require(canvas.warnings.message(for: .backgroundInsideShape))
        #expect(background.contains("createPath { }") && !background.contains("createShape"), "\(background)")
        let stacks = try #require(canvas.warnings.message(for: .pushLeftOpen))
        #expect(stacks.contains("createPath { … }") && !stacks.contains("createShape"), "\(stacks)")

        let other = try makeCanvas()
        try other.draw {
            _ = other.createShape {
                other.background(red)
                other.push()
            }
        }
        let shapeBackground = try #require(other.warnings.message(for: .backgroundInsideShape))
        #expect(shapeBackground.contains("createShape { }") && !shapeBackground.contains("createPath"))
        let shapeStacks = try #require(other.warnings.message(for: .pushLeftOpen))
        #expect(shapeStacks.contains("createShape { … }"))
    }

    // MARK: - 閉包の中で断るもの

    @Test("rect() などの基本図形は、描かれず、道に入らず、種類ごとに 1 度だけ知らせる")
    func primitivesAreRefused() throws {
        let canvas = try makeCanvas()
        let blank = try picture(canvas) { _ in }
        var made = Path()
        let image = try picture(canvas) { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            made = canvas.createPath {
                canvas.rect(10, 10, 50, 50)
                canvas.circle(60, 60, 40)
                canvas.line(0, 0, 100, 100)
                canvas.rect(20, 20, 30, 30)
            }
        }
        #expect(made.length == 0, "道に入っていない")
        #expect(image.bytes == blank.bytes, "画面へ流れている")
        let notice = try #require(canvas.warnings.message(for: .insidePath(.primitive)))
        #expect(notice.contains("createPath"), "\(notice)")
        // 鍵は種類ごとに 1 つ (何度呼んでも 1 度)。基本図形のほかの種類は言っていない
        #expect(canvas.warnings.count { key in if case .insidePath = key { true } else { false } } == 1)
    }

    @Test("立体と奥行きのある頂点も断る。断ったものは道に入らない")
    func solidsAndDepthAreRefused() throws {
        let canvas = try makeCanvas()
        let made = try record(canvas) { canvas in
            canvas.box(30)
            canvas.beginShape()
            canvas.vertex(0, 0, 0)
            canvas.vertex(100, 0, 10)
            canvas.vertex(100, 100, 0)
            canvas.endShape(.close)
        }
        #expect(made.length == 0)
        #expect(canvas.warnings.message(for: .insidePath(.solid)) != nil)
        #expect(canvas.warnings.message(for: .insidePath(.depth)) != nil)
    }

    @Test("閉包の中で変えた塗りなどの設定は、出口で戻り、shape(path) は描くときの設定で描く")
    func settingsAreRestored() throws {
        let canvas = try makeCanvas()
        var before: LinearRGBA?
        var after: LinearRGBA?
        var path = Path()
        try canvas.draw {
            canvas.fill(red)
            before = canvas.style.fill
            path = canvas.createPath {
                canvas.fill(blue)
                canvas.strokeWeight(9)
                squareOutline(canvas)
            }
            after = canvas.style.fill
        }
        #expect(before == after)
        #expect(canvas.style.strokeWeight != 9)
        // 描くときの設定で描く: 赤で描くと赤、青で描くと青になる (道は色を持たない)
        let asRed = try picture(canvas) { canvas in
            canvas.noStroke()
            canvas.fill(red)
            canvas.shape(path, 10, 10)
        }
        let asBlue = try picture(canvas) { canvas in
            canvas.noStroke()
            canvas.fill(blue)
            canvas.shape(path, 10, 10)
        }
        #expect(asRed.bytes != asBlue.bytes)
    }

    // MARK: - 描く

    @Test("部分道が 1 つの道は、同じ beginShape をその場で描いたときと同じ画素になる (塗りも線も)")
    func drawsLikeTheImmediateShape() throws {
        func scene(_ canvas: Canvas) {
            canvas.beginShape()
            canvas.vertex(10, 20)
            canvas.bezierVertex(10, 90, 60, 90, 60, 20)
            canvas.vertex(35, 5)
            canvas.endShape(.close)
        }
        func drawn(through path: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            var made = Path()
            if path { made = try record(canvas) { scene($0) } }
            return try picture(canvas) { canvas in
                canvas.fill(red)
                canvas.stroke(blue)
                canvas.strokeWeight(14)
                canvas.strokeJoin(.bevel)
                if path { canvas.shape(made) } else { scene(canvas) }
            }
        }
        let immediate = try drawn(through: false)
        let retained = try drawn(through: true)
        #expect(immediate.bytes != (try picture(try makeCanvas()) { _ in }).bytes, "何かが描かれている")
        #expect(retained.bytes == immediate.bytes)
    }

    @Test("穴のある 1 本の beginShape も、その場で描いたときと同じ画素になる。位置を渡した描き方は translate と同じ")
    func drawsHolesAndOffsetsLikeTheImmediateShape() throws {
        func scene(_ canvas: Canvas) {
            canvas.beginShape()
            canvas.vertex(10, 10)
            canvas.vertex(100, 10)
            canvas.vertex(100, 100)
            canvas.vertex(10, 100)
            canvas.beginContour()
            canvas.vertex(30, 30)
            canvas.vertex(30, 80)
            canvas.vertex(80, 80)
            canvas.vertex(80, 30)
            canvas.endContour()
            canvas.endShape(.close)
        }
        func draw(_ canvas: Canvas, through path: Path?, offset: Bool) throws -> DisplayImage {
            try picture(canvas) { canvas in
                canvas.fill(red)
                canvas.stroke(blue)
                canvas.strokeWeight(4)
                if offset { canvas.translate(7, 5) }
                if let path { canvas.shape(path, 0, 0) } else { scene(canvas) }
            }
        }
        let canvas = try makeCanvas(width: 140, height: 140)
        let made = try record(canvas) { scene($0) }
        let immediate = try draw(try makeCanvas(width: 140, height: 140), through: nil, offset: false)
        let retained = try draw(try makeCanvas(width: 140, height: 140), through: made, offset: false)
        #expect(retained.bytes == immediate.bytes, "穴の輪郭まで同じ")

        let moved = try picture(try makeCanvas(width: 140, height: 140)) { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(4)
            canvas.shape(made, 7, 5)
        }
        let translated = try draw(try makeCanvas(width: 140, height: 140), through: made, offset: true)
        #expect(moved.bytes == translated.bytes, "shape(path, x, y) は translate(x, y) と同じ")
    }

    @Test("複数の部分道は、全部を 1 つの形として回り数で塗る。逆向きの穴は抜け、同じ向きの周は塗られる")
    func severalSubpathsFillByWindingNumber() throws {
        func ring(_ canvas: Canvas, _ low: Float, _ high: Float, clockwise: Bool) {
            canvas.beginShape()
            let corners: [(Float, Float)] = [(low, low), (high, low), (high, high), (low, high)]
            for corner in clockwise ? corners : corners.reversed() { canvas.vertex(corner.0, corner.1) }
            canvas.endShape(.close)
        }
        func centre(clockwiseInner: Bool) throws -> UInt8 {
            let canvas = try makeCanvas()
            let path = try record(canvas) { canvas in
                ring(canvas, 10, 110, clockwise: true)
                ring(canvas, 35, 85, clockwise: clockwiseInner)
            }
            let image = try picture(canvas) { canvas in
                canvas.noStroke()
                canvas.fill(LinearRGBA.linear(red: 1, green: 1, blue: 1))
                canvas.shape(path)
            }
            let at = (60 * image.width + 60) * 4
            return image.bytes[at]
        }
        let ring = try centre(clockwiseInner: false)
        let same = try centre(clockwiseInner: true)
        #expect(ring < 20, "逆向きの周は抜ける: \(ring)")
        #expect(same > 235, "同じ向きの周は塗られる: \(same)")
    }
}

/// 字の輪郭から道を作る (`Path(textOutline(…))`・#3562)。周を値で渡す検査は GPU が要らない。
@Suite("字の輪郭からの道 (値)")
nonisolated struct PathFromContoursValueTests {
    /// 時計回り (面の座標で外側が正) の 100 四方と、その中の逆回りの穴 (30〜70)。字 `O` と同じ並び。
    private let ring: [TextContour] = [
        TextContour(points: [[0, 0], [100, 0], [100, 100], [0, 100]], isHole: false),
        TextContour(points: [[30, 30], [30, 70], [70, 70], [70, 30]], isHole: true),
    ]

    @Test("穴は外になり、輪の上は内側。周の外は外側")
    func theHoleIsOutside() {
        let path = Path(ring)
        #expect(path.contains([10, 50]) && path.contains([90, 50]) && path.contains([50, 15]), "輪の上")
        #expect(!path.contains([50, 50]), "穴の中")
        #expect(!path.contains([120, 50]) && !path.contains([-5, -5]), "周の外")
    }

    @Test("重なった外周は和になる。重なりの中も、重ならない所も内側で、どれにも入らない所は外側")
    func overlappingOutersAreAUnion() {
        let path = Path([
            TextContour(points: [[0, 0], [60, 0], [60, 60], [0, 60]], isHole: false),
            TextContour(points: [[40, 40], [100, 40], [100, 100], [40, 100]], isHole: false),
        ])
        #expect(path.contains([10, 10]) && path.contains([90, 90]), "重ならない所")
        #expect(path.contains([50, 50]), "重なりの中 (回り数 2) も内側のまま")
        #expect(!path.contains([90, 10]) && !path.contains([10, 90]), "どちらにも入らない角")
    }

    @Test("point(at:) は周を並んだ順に繋いだ全体の弧長で読む。外周が先、穴が後")
    func pointAtWalksTheContoursInOrder() {
        let path = Path(ring)
        #expect(path.length == 400 + 160)
        // t は Float の割り算なので、端の丸めの分だけ許す
        func near(_ t: Float, _ expected: Vector2, _ message: Comment) {
            #expect(simd_length(path.point(at: t).simd - expected.simd) < 1e-3, message)
        }
        near(0, [0, 0], "外周の始点")
        // 継ぎ目では、外周の終わり (= 始点) から穴の始点へ飛ぶ。継ぎ目そのものは丸めでどちらにも倒れるので、前後で見る
        near(399.0 / 560.0, [0, 1], "外周の最後の辺の終わりぎわ")
        near(401.0 / 560.0, [30, 31], "穴の最初の辺の始まりぎわ")
        near(1, [30, 30], "穴も閉じた周なので、終点は穴の始点へ戻る")
        // 外周の途中と、穴の途中
        near(100.0 / 560.0, [100, 0], "外周の 2 つ目の角")
        near(440.0 / 560.0, [30, 70], "穴の 2 つ目の角")
    }

    @Test("空の並びと、点のない周は、空の道になる")
    func emptyInputs() {
        #expect(Path([]) == Path())
        let hollow = Path([TextContour(points: [], isHole: false)])
        #expect(hollow == Path() && hollow.length == 0 && !hollow.contains([0, 0]))
        // 点のない周は飛ばし、残りは並びを保つ
        let skipped = Path([TextContour(points: [], isHole: true)] + ring)
        #expect(skipped == Path(ring))
    }

    @Test("点は置いた点として持ち、曲線の刻みの印は付けない。周は閉じた部分道")
    func contoursKeepPlacedPoints() {
        let path = Path(ring)
        #expect(path.subpaths.count == 2)
        #expect(path.subpaths.allSatisfy { $0.isClosed && !$0.isCurveStep.contains(true) })
        #expect(path.subpaths[0].points == [[0, 0], [100, 0], [100, 100], [0, 100]])
    }
}

/// 実物の字の輪郭から作った道 (#3562)。`textOutline` は描き場所を要るので GPU の条件に置く。
@Suite(
    "字の輪郭からの道 (実物の字)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PathFromTextOutlineTests {
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    private func makeCanvas(width: Int = 240, height: Int = 110, size: Float = 64) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        canvas.textFont("Helvetica")
        canvas.textSize(size)
        return canvas
    }

    private func bounds(_ points: [Vector2]) -> (minX: Float, maxX: Float, minY: Float, maxY: Float) {
        (
            points.map(\.x).min()!, points.map(\.x).max()!,
            points.map(\.y).min()!, points.map(\.y).max()!
        )
    }

    @Test("字 O: 穴の中は外側、輪の上は内側。穴は外周と逆回りで返る")
    func theHoleOfAnO() throws {
        let canvas = try makeCanvas(size: 90)
        let contours = canvas.textOutline("O", 20, 90)
        let outer = try #require(contours.first { !$0.isHole })
        let hole = try #require(contours.first { $0.isHole })
        let path = Path(contours)

        let box = bounds(outer.points)
        let inner = bounds(hole.points)
        let middle = (box.minY + box.maxY) / 2
        // 輪の左の帯 (外周の左端と穴の左端の間) の真ん中
        #expect(path.contains([(box.minX + inner.minX) / 2, middle]), "輪の左の帯")
        #expect(path.contains([(inner.maxX + box.maxX) / 2, middle]), "輪の右の帯")
        #expect(path.contains([(inner.minX + inner.maxX) / 2, (box.minY + inner.minY) / 2]), "輪の上の帯")
        #expect(!path.contains([(inner.minX + inner.maxX) / 2, (inner.minY + inner.maxY) / 2]), "穴の中")
        #expect(!path.contains([box.minX - 5, middle]) && !path.contains([box.maxX + 5, middle]), "字の外")
        // 穴は外周と逆回り (符号つきの面積の符号が逆)
        func area(_ points: [Vector2]) -> Float {
            var sum: Float = 0
            for index in points.indices {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                sum += a.x * b.y - b.x * a.y
            }
            return sum / 2
        }
        #expect(area(outer.points) * area(hole.points) < 0, "外周 \(area(outer.points)) / 穴 \(area(hole.points))")
    }

    @Test("既定の書体の A は重なった外周で返るが、和として読める")
    func theDefaultTypefaceAIsAUnion() throws {
        let canvas = try makeCanvas(size: 90)
        canvas.noTextFont()
        let contours = canvas.textOutline("A", 20, 90)
        #expect(contours.count > 1 && contours.allSatisfy { !$0.isHole }, "重なった外周で返る")
        let path = Path(contours)
        let box = bounds(contours.flatMap(\.points))
        let top = box.minY
        let base = box.maxY
        let centre = (box.minX + box.maxX) / 2
        // 二本の脚が交わる頂は内側、脚の根元の間 (三角の穴の下) は外側
        #expect(path.contains([centre, top + (base - top) * 0.1]), "頂")
        #expect(!path.contains([centre, base - (base - top) * 0.1]), "二本の脚の間")
        #expect(path.contains([box.minX + (box.maxX - box.minX) * 0.12, base - 3]), "左の脚の根元")
        #expect(path.contains([box.maxX - (box.maxX - box.minX) * 0.12, base - 3]), "右の脚の根元")
    }

    /// 墨の載った画素と `contains` が、字の縁から離れた画素の全部で一致する。字は `text` で描く。
    @Test("contains は、text が描いた墨の載る所と、縁から離れた画素の全部で一致する (穴も重なりも)")
    func containsMatchesTheInk() throws {
        for (string, plain) in [("mokume", false), ("O8", false), ("AB", true)] {
            let canvas = try makeCanvas(width: 240, height: 110, size: 64)
            if plain { canvas.noTextFont() }
            let contours = canvas.textOutline(string, 10, 80)
            let path = Path(contours)
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.text(string, 10, 80)
            }
            let image = try canvas.target.encodeForDisplay()

            let edges = contours.flatMap { contour in
                contour.outline.indices.map { (contour.outline[$0], contour.outline[($0 + 1) % contour.outline.count]) }
            }
            func nearEdge(_ x: Float, _ y: Float) -> Bool {
                let p = SIMD2<Float>(x, y)
                for (a, b) in edges {
                    let ab = b - a
                    let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-9)))
                    if simd_length(p - (a + t * ab)) < 1.5 { return true }
                }
                return false
            }
            var checked = 0
            var inkCount = 0
            var mismatches: [String] = []
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let px = Float(x) + 0.5
                    let py = Float(y) + 0.5
                    if nearEdge(px, py) { continue }
                    let ink = image.bytes[(y * image.width + x) * 4] > 127
                    checked += 1
                    if ink { inkCount += 1 }
                    if path.contains([px, py]) != ink { mismatches.append("(\(x), \(y)) ink=\(ink)") }
                }
            }
            #expect(inkCount > 300, "\(string): 墨が載った画素が少なすぎる (\(inkCount))")
            #expect(mismatches.isEmpty, "\(string): \(checked) 画素のうち \(mismatches.count) 画素が不一致 \(mismatches.prefix(5))")
        }
    }

    @Test("周が複数の字で、point(at:) は外周を辿った後に穴へ渡る。全体の弧長で読む")
    func pointAtCrossesFromTheOuterRingToTheHole() throws {
        let canvas = try makeCanvas(size: 90)
        let contours = canvas.textOutline("O", 20, 90)
        let outer = try #require(contours.first { !$0.isHole })
        let hole = try #require(contours.first { $0.isHole })
        let path = Path(contours)
        #expect(contours.first == outer, "外周が先")
        let outerLength = Path([outer]).length
        let holeLength = Path([hole]).length
        #expect(abs(path.length - (outerLength + holeLength)) < 1e-2)
        func near(_ a: Vector2, _ b: Vector2, _ message: Comment) {
            // 継ぎ目の前後 0.25 の点は、始点から最大 0.25 離れる
            #expect(simd_length(a.simd - b.simd) < 0.3, message)
        }
        near(path.point(at: 0), outer.points[0], "外周の始点")
        // 継ぎ目では外周の終わり (= 始点) から穴の始点へ飛ぶ。継ぎ目そのものは丸めでどちらにも倒れるので、前後 0.25 で見る
        near(path.point(at: (outerLength - 0.25) / path.length), outer.points[0], "外周を辿り終える手前は外周の始点の近く")
        near(path.point(at: (outerLength + 0.25) / path.length), hole.points[0], "辿り終えた直後は穴の始点の近く")
        near(path.point(at: (outerLength + holeLength * 0.5) / path.length), Path([hole]).point(at: 0.5), "穴の半周")
        near(path.point(at: 1), hole.points[0], "終点は穴の始点へ戻る")
    }

    @Test("shape(path) は、同じ周を beginShape と beginContour で並べて描いたときと同じ画素になる")
    func drawsLikeTheContoursByHand() throws {
        func fresh() throws -> Canvas { try makeCanvas(width: 120, height: 110, size: 90) }
        func paint(_ canvas: Canvas, _ body: () -> Void) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(LinearRGBA.linear(red: 1, green: 0.3, blue: 0))
                canvas.stroke(LinearRGBA.linear(red: 0, green: 0.3, blue: 1))
                canvas.strokeWeight(3)
                body()
            }
            return try canvas.target.encodeForDisplay()
        }
        let probe = try fresh()
        let contours = probe.textOutline("O", 15, 90)
        let outer = try #require(contours.first { !$0.isHole })
        let hole = try #require(contours.first { $0.isHole })

        let byHand = try fresh()
        let manual = try paint(byHand) {
            byHand.beginShape()
            for point in outer.points { byHand.vertex(point.x, point.y) }
            byHand.beginContour()
            for point in hole.points { byHand.vertex(point.x, point.y) }
            byHand.endContour()
            byHand.endShape(.close)
        }
        let throughPath = try fresh()
        let drawn = try paint(throughPath) { throughPath.shape(Path(contours)) }
        #expect(drawn.bytes.contains { $0 != 0 }, "何も描かれていない")
        // 1 本の beginShape と同じ読み (外周 + 穴) なので、塗りは同じ。輪郭の継ぎ目も刻みの印が無いので同じ
        #expect(drawn.bytes == manual.bytes)
    }
}
