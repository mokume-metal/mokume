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
        for radius: Float in [1e5, 7e5, 1e6, 1e9] {
            let count = Path(Circle(center: [0, 0], radius: radius)).subpaths[0].points.count
            #expect(count > 100, "r=\(radius): \(count) 本")
        }
        #expect(Path(Circle(center: [0, 0], radius: 1e9)).subpaths[0].points.count == 2048)
        #expect(Path(Circle(center: [0, 0], radius: 1e6)).subpaths[0].points.count == 2048)
        // 刻みは半径が上がるほど増える (単調)
        let counts = [10, 100, 1000, 10000].map { Path(Circle(center: [0, 0], radius: Float($0))).subpaths[0].points.count }
        #expect(counts == counts.sorted())
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
