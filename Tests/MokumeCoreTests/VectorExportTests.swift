// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

// ペンプロッタ用 SVG の書き出し ([#3139]・ADR-0023 の改訂 (2026-10-23))。
//
// **書いた文字列を読んで確かめる。** 画面の絵は変えない (控えるだけ) ので、GPU を使うのは、Canvas を
// 作るため (描き切りは小さな面で済ませる) と、画素の一致を見る 1 本だけである。
//
// [#3139]: https://github.com/mokume-metal/mokume/issues/3139

/// 書いた SVG を読む道具。
enum SVG {
    /// `<path .../>` の行。
    static func elements(_ svg: String) -> [String] {
        svg.split(separator: "\n").map(String.init).filter { $0.hasPrefix("<path ") }
    }

    /// 要素の属性。無ければ nil。
    static func attribute(_ name: String, in element: String) -> String? {
        guard let start = element.range(of: " \(name)=\"") else { return nil }
        let rest = element[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// `d` の中の数を、書いた順に。
    static func numbers(in element: String) -> [Double] {
        guard let d = attribute("d", in: element) else { return [] }
        var numbers: [Double] = []
        var current = ""
        for character in d {
            if character.isNumber || character == "." || (character == "-" && current.isEmpty) {
                current.append(character)
            } else {
                if let value = Double(current) { numbers.append(value) }
                current = character == "-" ? "-" : ""
            }
        }
        if let value = Double(current) { numbers.append(value) }
        return numbers
    }

    /// `d` の中の命令の文字だけを、書いた順に。
    static func commands(in element: String) -> String {
        (attribute("d", in: element) ?? "").filter { $0.isLetter }
    }

    /// 数を (x, y) の組にする。
    static func points(in element: String) -> [SIMD2<Double>] {
        let values = numbers(in: element)
        return stride(from: 0, to: values.count - 1, by: 2).map { SIMD2(values[$0], values[$0 + 1]) }
    }

    /// 2 つの点が `tolerance` の中で一致するか。
    static func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>, within tolerance: Double = 0.002) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
}

@Suite(
    "SVG に書く図形",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct VectorCaptureTests {
    /// 控えた図形の読み書き。Canvas を 1 つ作り、`draw()` の窓の中で置いて控えを受け取る。
    struct Harness {
        let canvas: Canvas

        init(width: Int = 100, height: Int = 100) throws {
            canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        }

        /// 窓を開き、呼んだ時点から控え、`body` で置いた図形と、書けなかった種類を返す。
        func capture(_ body: (Canvas) -> Void) throws -> (figures: [VectorFigure], drops: [VectorDrop]) {
            var captured: VectorCapture?
            try canvas.draw {
                canvas.beginVectorWindow(pending: [])
                canvas.startVectorCapture(path: "x.svg")
                body(canvas)
                captured = canvas.endVectorWindow()
            }
            return (captured?.figures ?? [], captured?.drops ?? [])
        }

        /// 置いて、書いた SVG の文字列を返す。
        func svg(_ body: (Canvas) -> Void) throws -> String {
            let figures = try capture(body).figures
            return String(
                decoding: SVGWriter.render(figures[...], width: canvas.width, height: canvas.height),
                as: UTF8.self)
        }

        /// 置いて、書いた SVG の要素を返す。
        func elements(_ body: (Canvas) -> Void) throws -> [String] {
            SVG.elements(try svg(body))
        }
    }

    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.display(red: 0, green: 0, blue: 1)

    // MARK: - 2・15 作例

    /// 作例: 流れ場の線 1 万本。**折れ線 1 万個だけが書かれ、塗りの矩形は無い** (15)。
    @Test("線 1 万本が折れ線 1 万個になり、viewBox は絵の大きさで、背景の塗りは書かれない")
    func tenThousandLinesBecomeTenThousandPolylines() throws {
        let harness = try Harness(width: 200, height: 120)
        let svg = try harness.svg { canvas in
            canvas.background(255)
            canvas.noFill()
            canvas.stroke(0)
            canvas.strokeWeight(0.5)
            for seed in 0..<10_000 {
                canvas.beginShape()
                let x = Float(seed % 100)
                let y = Float(seed / 100)
                for step in 0..<3 { canvas.vertex(x + Float(step) * 5, y + Float(step) * 2) }
                canvas.endShape()
            }
        }
        let elements = SVG.elements(svg)
        #expect(elements.count == 10_000)
        // 要素は折れ線だけ。背景の矩形も、ほかの要素も無い
        #expect(svg.components(separatedBy: "<").count - 1 == 10_000 + 2 + 1, "<?xml ... ?> と <svg> と </svg> を足した数")
        #expect(svg.contains("viewBox=\"0 0 200 120\""))
        #expect(svg.contains("width=\"200\" height=\"120\""))
        // 縦軸は反転しない・変換の属性は無い
        #expect(!svg.contains("transform"))
        let first = elements[0]
        #expect(SVG.attribute("d", in: first) == "M0 0L5 2 10 4")
        #expect(SVG.attribute("fill", in: first) == "none")
        #expect(SVG.attribute("stroke", in: first) == "#000000")
        #expect(SVG.attribute("stroke-width", in: first) == "0.5")
        #expect(SVG.attribute("stroke-opacity", in: first) == nil, "不透明なら不透明度は省く")
    }

    // MARK: - 3 幾何

    @Test("変換を挟んだ線の点が、描いた点に変換を当てた座標と一致する")
    func pointsMatchTheTransformedCoordinates() throws {
        let harness = try Harness()
        let angle: Float = 0.6
        let elements = try harness.elements { canvas in
            canvas.noFill()
            canvas.push()
            canvas.translate(30, 40)
            canvas.rotate(angle)
            canvas.scale(2, 3)
            canvas.strokeWeight(2)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(10, 0)
            canvas.vertex(10, 5)
            canvas.endShape()
            canvas.line(1, 2, 3, 4)
            canvas.pop()
            // 戻した後の線は変換されない
            canvas.line(1, 2, 3, 4)
        }
        try #require(elements.count == 3)
        // 式: 点 p を (拡大 → 回転 → 平行移動) の順に当てる
        let (c, s) = (Double(cos(angle)), Double(sin(angle)))
        func place(_ x: Double, _ y: Double) -> SIMD2<Double> {
            let (sx, sy) = (2 * x, 3 * y)
            return SIMD2(30 + c * sx - s * sy, 40 + s * sx + c * sy)
        }
        let polyline = SVG.points(in: elements[0])
        #expect(polyline.count == 3)
        for (actual, expected) in zip(polyline, [place(0, 0), place(10, 0), place(10, 5)]) {
            #expect(SVG.near(actual, expected), "\(actual) と \(expected)")
        }
        let line = SVG.points(in: elements[1])
        #expect(SVG.near(line[0], place(1, 2)) && SVG.near(line[1], place(3, 4)))
        let plain = SVG.points(in: elements[2])
        #expect(SVG.near(plain[0], SIMD2(1, 2)) && SVG.near(plain[1], SIMD2(3, 4)))
        // 太さは変換の拡大率 (行列式の平方根 = √6) に従う
        let widthText = try #require(SVG.attribute("stroke-width", in: elements[0]))
        let width = try #require(Double(widthText))
        #expect(abs(width - 2 * 6.0.squareRoot()) < 0.002)
        #expect(SVG.attribute("stroke-width", in: elements[2]) == "1")
    }

    // MARK: - 4 図形

    @Test("矩形は閉じた折れ線で、塗りと輪郭の値が残る")
    func aRectIsAClosedPolyline() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(3)
            canvas.rect(10, 20, 30, 40)
        }
        try #require(elements.count == 1)
        let element = elements[0]
        #expect(SVG.attribute("d", in: element) == "M10 20L40 20 40 60 10 60Z")
        #expect(SVG.attribute("fill", in: element) == "#ff0000")
        #expect(SVG.attribute("stroke", in: element) == "#0000ff")
        #expect(SVG.attribute("stroke-width", in: element) == "3")
        #expect(SVG.attribute("stroke-linecap", in: element) == "round")
        #expect(SVG.attribute("stroke-linejoin", in: element) == "miter")
        #expect(SVG.attribute("stroke-miterlimit", in: element) == "1.4143")
    }

    @Test("角を丸めた矩形は、直線と四分円の曲線で書かれる")
    func aRoundedRectHasLinesAndCurves() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.noStroke()
            canvas.rect(10, 20, 30, 40, 8)
        }
        try #require(elements.count == 1)
        #expect(SVG.commands(in: elements[0]) == "MLCLCLCLCZ")
        // 角の曲線の真ん中は、角の円の上にある (中心 (40-8, 20+8)・半径 8)
        let points = SVG.points(in: elements[0])
        let curve = Array(points[2...4])  // 右上の角: 始点 (32, 20) の次から、制御点 2 つと終点
        let start = points[1]
        func bezier(_ t: Double, _ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>) -> SIMD2<Double> {
            let u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        }
        let middle = bezier(0.5, start, curve[0], curve[1], curve[2])
        let distance = ((middle.x - 32) * (middle.x - 32) + (middle.y - 28) * (middle.y - 28)).squareRoot()
        #expect(abs(distance - 8) < 0.01, "\(distance)")
    }

    @Test("楕円は 4 つの曲線で閉じ、曲線の上の点は楕円の上にある")
    func anEllipseIsFourCurvesOnTheEllipse() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.ellipse(50, 40, 60, 30)
        }
        try #require(elements.count == 1)
        #expect(SVG.commands(in: elements[0]) == "MCZ")
        let points = SVG.points(in: elements[0])
        #expect(points.count == 13)
        #expect(SVG.near(points[0], SIMD2(80, 40)), "始点は右端")
        for index in stride(from: 0, to: 12, by: 3) {
            let (p0, p1, p2, p3) = (points[index], points[index + 1], points[index + 2], points[index + 3])
            let t = 0.5
            let u = 1 - t
            let middle = u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
            let radial = ((middle.x - 50) / 30) * ((middle.x - 50) / 30) + ((middle.y - 40) / 15) * ((middle.y - 40) / 15)
            #expect(abs(radial - 1) < 0.002, "\(radial)")
        }
    }

    /// 弧は閉じ方で、塗りの形と輪郭の形が違う。
    @Test("弧は閉じ方ごとに、塗りと輪郭の形が決まる")
    func anArcFollowsItsClosure() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.arc(50, 50, 40, 40, 0, Float.pi, .pie)
            canvas.arc(50, 50, 40, 40, 0, Float.pi, .chord)
            canvas.arc(50, 50, 40, 40, 0, Float.pi, .open)
            canvas.arc(50, 50, 40, 40, 0, Float.pi)
        }
        // pie と chord は塗りと輪郭が同じ形で 1 つ、open と既定は塗り → 輪郭の 2 つ
        try #require(elements.count == 6)
        // pie: 中心から弧の始点へ線を引いて閉じる
        #expect(SVG.commands(in: elements[0]) == "MLCZ")
        #expect(SVG.attribute("fill", in: elements[0]) == "#ff0000" && SVG.attribute("stroke", in: elements[0]) == "#0000ff")
        #expect(SVG.near(SVG.points(in: elements[0])[0], SIMD2(50, 50)), "扇は中心から")
        // chord: 弧を描いて、弦で閉じる
        #expect(SVG.commands(in: elements[1]) == "MCZ")
        // open: 塗りは弦で結んだ形・輪郭は開いた弧 (閉じない)
        #expect(SVG.commands(in: elements[2]) == "MCZ" && SVG.attribute("stroke", in: elements[2]) == nil)
        #expect(SVG.commands(in: elements[3]) == "MC" && SVG.attribute("fill", in: elements[3]) == "none")
        // 既定: 塗りは扇・輪郭は開いた弧
        #expect(SVG.commands(in: elements[4]) == "MLCZ" && SVG.attribute("stroke", in: elements[4]) == nil)
        #expect(SVG.commands(in: elements[5]) == "MC")
        // 半周は 2 つの四分円
        #expect(SVG.points(in: elements[3]).count == 1 + 3 * 2)
    }

    @Test("線と点は輪郭だけで、端の形が値で残る")
    func linesAndPointsKeepTheirCaps() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.stroke(blue)
            canvas.strokeWeight(4)
            canvas.line(10, 10, 50, 10)
            canvas.strokeCap(.square)
            canvas.line(10, 20, 50, 20)
            canvas.strokeCap(.project)
            canvas.line(10, 30, 50, 30)
            canvas.strokeCap(.round)
            canvas.point(60, 60)
        }
        try #require(elements.count == 4)
        #expect(elements.map { SVG.attribute("fill", in: $0) } == Array(repeating: "none", count: 4))
        #expect(SVG.attribute("d", in: elements[0]) == "M10 10L50 10")
        // 画面の `square` は「長さちょうどで切る」で SVG の butt、`project` は SVG の square
        #expect(SVG.attribute("stroke-linecap", in: elements[0]) == "round")
        #expect(SVG.attribute("stroke-linecap", in: elements[1]) == "butt")
        #expect(SVG.attribute("stroke-linecap", in: elements[2]) == "square")
        // 点は長さ 0 の線
        #expect(SVG.attribute("d", in: elements[3]) == "M60 60L60 60")
        #expect(SVG.attribute("stroke-linecap", in: elements[3]) == "round")
        #expect(SVG.attribute("stroke-width", in: elements[3]) == "4")
    }

    @Test("折れ目の形が値で残り、尖りの限界は丸めた形では書かない")
    func joinsAreWrittenAsValues() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.noFill()
            for join in [StrokeJoin.miter, .bevel, .round] {
                canvas.strokeJoin(join)
                canvas.triangle(10, 10, 40, 10, 10, 40)
            }
        }
        try #require(elements.count == 3)
        #expect(elements.map { SVG.attribute("stroke-linejoin", in: $0) } == ["miter", "bevel", "round"])
        #expect(SVG.attribute("stroke-miterlimit", in: elements[0]) == "1.4143")
        #expect(SVG.attribute("stroke-miterlimit", in: elements[1]) == nil)
    }

    @Test("三角形と四角形は閉じた折れ線になる")
    func trianglesAndQuadsAreClosed() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.noStroke()
            canvas.triangle(10, 10, 40, 10, 10, 40)
            canvas.quad(50, 10, 90, 12, 88, 40, 52, 38)
        }
        try #require(elements.count == 2)
        #expect(SVG.attribute("d", in: elements[0]) == "M10 10L40 10 10 40Z")
        #expect(SVG.attribute("d", in: elements[1]) == "M50 10L90 12 88 40 52 38Z")
        #expect(SVG.attribute("stroke", in: elements[0]) == nil)
    }

    @Test("開いた形は閉じず、閉じた形は閉じる。塗りは開いていても閉じて塗られる")
    func openAndClosedShapes() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            for end in [ShapeEnd.open, .close] {
                canvas.beginShape()
                canvas.vertex(10, 10)
                canvas.vertex(40, 10)
                canvas.vertex(25, 30)
                canvas.endShape(end)
            }
        }
        try #require(elements.count == 2)
        #expect(SVG.attribute("d", in: elements[0]) == "M10 10L40 10 25 30")
        #expect(SVG.attribute("d", in: elements[1]) == "M10 10L40 10 25 30Z")
        #expect(SVG.attribute("fill", in: elements[0]) == "#ff0000", "開いた形の塗りも書く (SVG が閉じて塗る)")
    }

    @Test("穴のある形は、外周と穴を 1 つの道に並べ、穴の向きによらず抜ける規則で塗る")
    func aShapeWithAHoleKeepsItsHole() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.fill(red)
            canvas.noStroke()
            canvas.beginShape()
            canvas.vertex(10, 10)
            canvas.vertex(90, 10)
            canvas.vertex(90, 90)
            canvas.vertex(10, 90)
            canvas.beginContour()
            canvas.vertex(30, 30)
            canvas.vertex(70, 30)
            canvas.vertex(70, 70)
            canvas.vertex(30, 70)
            canvas.endContour()
            canvas.endShape(.close)
        }
        try #require(elements.count == 1)
        #expect(SVG.attribute("d", in: elements[0]) == "M10 10L90 10 90 90 10 90ZM30 30L70 30 70 70 30 70Z")
        #expect(SVG.attribute("fill-rule", in: elements[0]) == "evenodd")
    }

    @Test("点・線・三角形の読み方は、原始形ごとに図形になる")
    func vertexKindsBecomeOneFigurePerPrimitive() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.stroke(blue)
            canvas.fill(red)
            canvas.beginShape(.triangles)
            for point in [(10, 10), (30, 10), (10, 30), (50, 10), (70, 10), (50, 30)] {
                canvas.vertex(point.0, point.1)
            }
            canvas.endShape()
            canvas.beginShape(.lines)
            for point in [(10, 50), (30, 50), (10, 60), (30, 60)] { canvas.vertex(point.0, point.1) }
            canvas.endShape()
            canvas.beginShape(.points)
            for point in [(80, 80), (85, 85)] { canvas.vertex(point.0, point.1) }
            canvas.endShape()
        }
        try #require(elements.count == 6)
        #expect(SVG.attribute("d", in: elements[0]) == "M10 10L30 10 10 30Z")
        #expect(SVG.attribute("d", in: elements[2]) == "M10 50L30 50")
        #expect(SVG.attribute("fill", in: elements[2]) == "none", "線は塗らない")
        #expect(SVG.attribute("d", in: elements[4]) == "M80 80L80 80")
    }

    @Test("曲線は画面と同じ刻みの折れ線になる")
    func curvesAreFlattenedLikeTheScreen() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.noFill()
            canvas.curveDetail(4)
            canvas.bezier(10, 10, 20, 0, 40, 0, 50, 10)
        }
        try #require(elements.count == 1)
        #expect(SVG.points(in: elements[0]).count == 1 + 4)
        #expect(SVG.near(SVG.points(in: elements[0]).last!, SIMD2(50, 10)))
    }

    // MARK: - 破線

    @Test("破線は片に分けず、破線の指定のまま 1 つの図形として書く")
    func dashesStayAsADashArray() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.stroke(blue)
            canvas.strokeDash(6, 3)
            canvas.line(10, 10, 90, 10)
            canvas.push()
            canvas.scale(2, 2)
            canvas.line(10, 20, 40, 20)
            canvas.pop()
        }
        try #require(elements.count == 2)
        #expect(SVG.attribute("d", in: elements[0]) == "M10 10L90 10")
        #expect(SVG.attribute("stroke-dasharray", in: elements[0]) == "6 3")
        // 拡大すれば破線の長さも拡大される (画面の道と同じ)
        #expect(SVG.attribute("stroke-dasharray", in: elements[1]) == "12 6")
    }

    @Test("塗りのある破線の矩形は、塗りと破線の輪郭の 2 つになる")
    func aDashedFilledRectIsTwoFigures() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeDash(4, 2)
            canvas.rect(10, 10, 40, 30)
        }
        try #require(elements.count == 2)
        #expect(SVG.attribute("fill", in: elements[0]) == "#ff0000" && SVG.attribute("stroke", in: elements[0]) == nil)
        #expect(SVG.attribute("fill", in: elements[1]) == "none")
        #expect(SVG.attribute("stroke-dasharray", in: elements[1]) == "4 2")
        #expect(SVG.commands(in: elements[1]).hasSuffix("Z"), "輪郭は閉じた周")
    }

    @Test("細かすぎて刻めない破線は、画面と同じく実線で書く")
    func aTooFineDashIsWrittenSolid() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.stroke(blue)
            canvas.strokeDash(0.001, 0.001)
            canvas.line(0, 0, 100, 100)
        }
        try #require(elements.count == 1)
        #expect(SVG.attribute("stroke-dasharray", in: elements[0]) == nil)
    }

    // MARK: - 色と不透明度

    @Test("色は sRGB で、不透明度は別の値になる")
    func colourIsSRGBAndOpacityIsSeparate() throws {
        let harness = try Harness()
        let elements = try harness.elements { canvas in
            canvas.fill(.display(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5))
            canvas.stroke(.display(red: 1, green: 1, blue: 1, alpha: 0.25))
            canvas.rect(10, 10, 20, 20)
        }
        try #require(elements.count == 1)
        #expect(SVG.attribute("fill", in: elements[0]) == "#336699")
        #expect(SVG.attribute("fill-opacity", in: elements[0]) == "0.5")
        #expect(SVG.attribute("stroke", in: elements[0]) == "#ffffff")
        #expect(SVG.attribute("stroke-opacity", in: elements[0]) == "0.25")
    }

    @Test("塗りも輪郭も無い図形は書かれない")
    func nothingVisibleIsNotWritten() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.noFill()
            canvas.noStroke()
            canvas.rect(10, 10, 20, 20)
            canvas.line(0, 0, 10, 10)
        }
        #expect(figures.isEmpty)
        #expect(drops.isEmpty, "見えないものは、書けなかったものにも数えない")
    }

    // MARK: - 書けないもの (8)

    @Test("書けない図形は、種類を数えて落とす")
    func unwritableFiguresAreCountedByKind() throws {
        let harness = try Harness()
        let image = try harness.canvas.createGraphics(8, 8)
        let (figures, drops) = try harness.capture { canvas in
            canvas.text("a", 10, 10)
            canvas.text("b", 10, 20)
            canvas.image(image, 0, 0)
            canvas.box(10)
            canvas.set(1, 1, .linear(red: 1, green: 0, blue: 0))
            canvas.blendMode(.add)
            canvas.rect(10, 10, 5, 5)
            canvas.blendMode(.blend)
            canvas.rect(20, 10, 5, 5)
            canvas.effects([.threshold(level: 0.5)])
        }
        #expect(figures.count == 1, "書けるのは通常の混ぜ方の矩形だけ")
        #expect(drops.filter { $0 == .effects }.count == 1, "効果は出力段の手前に立つので、書かずに名乗る")
        #expect(drops.filter { $0 == .text }.count == 2)
        #expect(drops.filter { $0 == .image }.count == 1)
        #expect(drops.filter { $0 == .solid }.count == 1)
        #expect(drops.filter { $0 == .pixels }.count == 1)
        #expect(drops.filter { $0 == .blendMode }.count == 1)
    }

    @Test("貼る絵・勾配・切り抜き・断片の効いた図形は、書かずに数える")
    func shadedFiguresAreCounted() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        let (figures, drops) = try harness.capture { canvas in
            canvas.texture(picture)
            canvas.rect(0, 0, 10, 10)
            canvas.triangle(0, 0, 5, 0, 0, 5)
            canvas.noTexture()
            canvas.fill(.linearGradient([(.linear(red: 1, green: 0, blue: 0), 0), (.linear(red: 0, green: 0, blue: 1), 1)], from: [0, 0], to: [10, 0]))
            canvas.rect(0, 0, 10, 10)
            canvas.fill(red)
            canvas.clip(0, 0, 50, 50)
            canvas.rect(0, 0, 10, 10)
            canvas.noClip()
        }
        #expect(figures.isEmpty)
        #expect(drops.filter { $0 == .texture }.count == 2)
        #expect(drops.filter { $0 == .gradient }.count == 1)
        #expect(drops.filter { $0 == .clip }.count == 1)
    }

    @Test("利用者の断片が効いた図形は、塗りも輪郭も線も、断片として数えて書かない")
    func userShadersAreCounted() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            let paint = try! canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
            canvas.shader(paint)
            canvas.rect(0, 0, 10, 10)
            canvas.line(0, 0, 10, 10)
            canvas.point(5, 5)
            canvas.resetShader()
            canvas.rect(20, 0, 10, 10)
        }
        #expect(figures.count == 1)
        #expect(drops.filter { $0 == .shader }.count == 3)
    }

    @Test("頂点ごとに塗りの色が違う形は、最初の頂点の色で書き、そのことを数える")
    func perVertexColoursUseTheFirstVertex() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.noStroke()
            canvas.beginShape()
            canvas.fill(red)
            canvas.vertex(0, 0)
            canvas.fill(blue)
            canvas.vertex(10, 0)
            canvas.vertex(0, 10)
            canvas.endShape(.close)
        }
        try #require(figures.count == 1)
        #expect(figures[0].fill?.color == VectorColor(red))
        #expect(drops == [.vertexColours])
    }

    @Test("立体の頂点を持つ形は、書かずに立体として数える")
    func depthShapesAreSolids() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.line(0, 0, 0, 10, 10, 10)
            canvas.beginShape(.triangles)
            canvas.vertex(0, 0, 1)
            canvas.vertex(5, 0, 1)
            canvas.vertex(0, 5, 1)
            canvas.endShape()
        }
        #expect(figures.isEmpty)
        #expect(drops == [.solid, .solid])
    }

    @Test("保持した形は、書かずに数える。作る間は控えない")
    func retainedShapesAreCountedWhenPlaced() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            let shape = canvas.createShape {
                canvas.rect(0, 0, 10, 10)
                canvas.line(0, 0, 5, 5)
            }
            #expect(canvas.vector.capture?.figures.isEmpty == true, "作る間に置いた図形は控えない")
            canvas.shape(shape, 10, 10)
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 5, y: 5)])
        }
        #expect(figures.isEmpty)
        #expect(drops == [.retainedShape, .retainedShape, .retainedShape])
    }

    // MARK: - 5 画面は変わらない

    /// **控えは観測であって、描く道を変えない。** 同じスケッチを、控えて描いた画素と控えずに描いた画素が
    /// 一致する (GPU を使う。単発で 1 回)。
    @Test("控えて描いた画素が、控えずに描いた画素と一致する")
    func capturingDoesNotChangeThePicture() throws {
        func picture(capturing: Bool) throws -> [UInt8] {
            let harness = try Harness(width: 96, height: 96)
            let canvas = harness.canvas
            try canvas.draw {
                if capturing {
                    canvas.beginVectorWindow(pending: [])
                    canvas.startVectorCapture(path: "x.svg")
                }
                canvas.background(30)
                canvas.fill(.display(red: 1, green: 0.5, blue: 0.2, alpha: 0.7))
                canvas.stroke(.display(red: 0.2, green: 0.8, blue: 1))
                canvas.strokeWeight(5)
                canvas.rect(10, 10, 40, 30, 6)
                canvas.ellipse(60, 30, 30, 20)
                canvas.arc(30, 70, 30, 30, 0.3, 2.5)
                canvas.strokeDash(4, 3)
                canvas.line(5, 90, 90, 60)
                canvas.rect(50, 50, 30, 30)
                canvas.noStrokeDash()
                canvas.push()
                canvas.translate(70, 70)
                canvas.rotate(0.5)
                canvas.triangle(0, 0, 20, 0, 0, 20)
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(15, 5)
                canvas.vertex(5, 15)
                canvas.endShape(.close)
                canvas.pop()
                if capturing { _ = canvas.endVectorWindow() }
            }
            return try canvas.target.encodeForDisplay().bytes
        }
        #expect(try picture(capturing: true) == picture(capturing: false))
    }
}

/// 数の書式と要素の書き方。GPU を要さない。
@Suite("SVG の書式")
struct SVGWriterTests {
    private func render(_ figure: VectorFigure) -> String {
        String(decoding: SVGWriter.render([figure][...], width: 10, height: 10), as: UTF8.self)
    }

    @Test("数は 1/1000 まで書き、末尾の 0 と -0 は書かない")
    func numbersAreFixedPoint() {
        let path = VectorSubpath(
            points: [SIMD2(0.05, -0.0004), SIMD2(1.5, 100), SIMD2(-3.25, 0.001), SIMD2(12345.6789, 2)],
            isClosed: false)
        let svg = render(VectorFigure(subpaths: [path], fill: nil, stroke: nil))
        #expect(svg.contains("d=\"M0.05 0L1.5 100 -3.25 0.001 12345.679 2\""), "\(svg)")
    }

    @Test("同じ入力を 2 回組むと、バイトまで一致する")
    func renderingIsDeterministic() {
        let figures = (0..<50).map { index in
            VectorFigure(
                subpaths: [
                    VectorSubpath(
                        points: (0..<20).map { SIMD2(Float($0) * 1.37 + Float(index), Float($0 * $0) / 7) },
                        isClosed: index % 2 == 0)
                ],
                fill: index % 3 == 0 ? VectorFill(color: VectorColor(.display(red: 0.3, green: 0.5, blue: 0.7, alpha: 0.4)), evenOdd: false) : nil,
                stroke: VectorStroke(color: VectorColor(.display(red: 0, green: 0, blue: 0)), width: 0.7, cap: .round, join: .miter))
        }
        let first = SVGWriter.render(figures[...], width: 640, height: 480)
        let second = SVGWriter.render(figures[...], width: 640, height: 480)
        #expect(first == second)
    }

    @Test("色は sRGB の 8 ビットで、範囲の外は収める")
    func colourClamps() {
        #expect(VectorColor(.display(red: 0.2, green: 0.4, blue: 0.6)) == VectorColor(red: 0x33, green: 0x66, blue: 0x99, opacity: 1))
        // 作業空間の明るさが 1 を超える色は白に収まる
        #expect(VectorColor(.linear(red: 4, green: 4, blue: 4)) == VectorColor(red: 255, green: 255, blue: 255, opacity: 1))
        // 透明は、色を持たない不透明度 0
        #expect(VectorColor(.transparent).opacity == 0)
    }
}
