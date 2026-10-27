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
            // 輪郭は貼る絵にも勾配にも関わらず書かれる (下の `texturesAndGradientsDropOnlyTheFill`)。ここは塗りだけ見る
            canvas.noStroke()
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

    // MARK: - 反証の直し (#3139)

    @Test("画素の窓への書き込み (添字・fill・update) も、set と同じく画素の書き込みとして名乗る")
    func pixelWindowWritesAreNamed() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.set(1, 1, red)
            canvas.pixels[2, 2] = red
            canvas.pixels.fill(blue)
            canvas.pixels.update { _, _, color in color }
        }
        #expect(figures.isEmpty)
        #expect(drops.filter { $0 == .pixels }.count == 4, "set・添字・fill・update の 4 つが数えられる: \(drops)")
    }

    @Test("background() は、それより前に置いた図形と、書けなかった名乗りを、画面と同じく消す")
    func backgroundErasesEarlierFigures() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.stroke(0)
            canvas.line(0, 0, 10, 0)  // A: 画面から消える
            canvas.text("a", 10, 10)  // 消える図形の名乗りも消える
            canvas.background(255)
            canvas.line(0, 10, 20, 10)  // B
        }
        try #require(figures.count == 1, "B だけが残る")
        #expect(figures[0].subpaths[0].points == [SIMD2(0, 10), SIMD2(20, 10)])
        #expect(drops.isEmpty, "\(drops)")
    }

    @Test("切り抜きの中だけの background() は中だけの塗り直しなので、先に置いた図形を残す")
    func clippedBackgroundKeepsEarlierFigures() throws {
        let harness = try Harness()
        let (figures, _) = try harness.capture { canvas in
            canvas.stroke(0)
            canvas.line(0, 0, 10, 0)  // A: 切り抜きの外にも続く
            canvas.clip(0, 0, 50, 50)
            canvas.background(255)
            canvas.noClip()
            canvas.line(0, 10, 20, 10)  // B
        }
        #expect(figures.count == 2)
    }

    /// 端の形ごとの、点 1 つの輪郭。画面は孤立した端を `round` なら円・それ以外なら正方形で置く。
    @Test("点 1 つの輪郭は、端の形を画面と同じに読み替えて書く", arguments: [StrokeCap.round, .square, .project])
    func singlePointsReadTheCapLikeTheScreen(cap: StrokeCap) throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.stroke(0)
            canvas.strokeWeight(10)
            canvas.strokeCap(cap)
            canvas.beginShape(.points)  // 点の形
            canvas.vertex(50, 50)
            canvas.endShape()
            canvas.beginShape()  // 頂点が 1 つの形
            canvas.vertex(50, 20)
            canvas.endShape()
            canvas.draw(Canvas.Outline(points: [SIMD2(50, 80)], isClosed: false, fills: false))  // 周の道
            canvas.point(10, 10)  // 基本図形の道 (前から読み替えている)
        }
        #expect(drops.isEmpty)
        try #require(figures.count == 4)
        let expected: StrokeCap = cap == .round ? .round : .project
        for figure in figures {
            #expect(figure.stroke?.cap == expected, "\(String(describing: figure.stroke?.cap))")
            #expect(figure.subpaths[0].points.count == 1)
        }
    }

    /// 上の読み替えの根拠: 画面は `square` の孤立した点を、`project` と同じ正方形で出す。
    @Test("画面は、点 1 つを端が round なら円で、square・project なら正方形で出す", arguments: [StrokeCap.round, .square, .project])
    func theScreenDrawsASinglePointAsSquareOrDisc(cap: StrokeCap) throws {
        let harness = try Harness()
        var corner: Float = 0
        try harness.canvas.draw {
            let canvas = harness.canvas
            canvas.background(255)
            canvas.stroke(0)
            canvas.strokeWeight(20)
            canvas.strokeCap(cap)
            canvas.beginShape(.points)
            canvas.vertex(50, 50)
            canvas.endShape()
            // 中心から (+9, -9) の画素。円の半径 10 の外 (距離 12.7)、正方形の半幅 10 の内
            corner = canvas.get(59, 40).red
        }
        if cap == .round {
            #expect(corner > 0.9, "円の外は白のまま: \(corner)")
        } else {
            #expect(corner < 0.1, "正方形の角は塗られる: \(corner)")
        }
    }

    /// 基本図形・周・頂点の形の、塗りと輪郭を両方持つ置き方。
    private var shapes: [(name: String, place: (Canvas) -> Void)] {
        [
            ("rect", { $0.rect(10, 10, 30, 20) }),
            ("rounded rect", { $0.rect(10, 10, 30, 20, 5) }),
            ("ellipse", { $0.ellipse(30, 30, 30, 20) }),
            ("pie", { $0.arc(30, 30, 30, 20, 0.2, 2.2, .pie) }),
            ("default arc", { $0.arc(30, 30, 30, 20, 0.2, 2.2) }),
            ("chord", { $0.arc(30, 30, 30, 20, 0.2, 2.2, .chord) }),
            ("open arc", { $0.arc(30, 30, 30, 20, 0.2, 2.2, .open) }),
            ("full turn arc", { $0.arc(30, 30, 30, 20, 0, 7) }),
            ("triangle", { $0.triangle(0, 0, 10, 0, 0, 10) }),
            (
                "shape",
                {
                    $0.beginShape()
                    $0.vertex(0, 0)
                    $0.vertex(15, 5)
                    $0.vertex(5, 15)
                    $0.endShape(.close)
                }
            ),
        ]
    }

    @Test("貼る絵・勾配は塗りにしか効かない: 輪郭は書き、塗りだけを名指しで落とす")
    func texturesAndGradientsDropOnlyTheFill() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        let gradient = Gradient.linearGradient(
            [(LinearRGBA.linear(red: 1, green: 0, blue: 0), 0), (LinearRGBA.linear(red: 0, green: 0, blue: 1), 1)],
            from: [0, 0], to: [10, 0])
        for (name, place) in shapes {
            for (paint, kind) in [("texture", VectorDrop.texture), ("gradient", .gradient)] {
                let (figures, drops) = try harness.capture { canvas in
                    canvas.noTexture()
                    canvas.fill(red)
                    if paint == "texture" { canvas.texture(picture) } else { canvas.fill(gradient) }
                    canvas.stroke(blue)
                    canvas.strokeWeight(2)
                    place(canvas)
                }
                #expect(figures.count == 1, "\(name) + \(paint): 輪郭は書く \(figures.count)")
                #expect(figures.first?.fill == nil, "\(name) + \(paint)")
                #expect(figures.first?.stroke?.color == VectorColor(blue), "\(name) + \(paint)")
                #expect(drops == [kind], "\(name) + \(paint): 塗りを 1 度だけ名指す \(drops)")
            }
        }
    }

    @Test("矩形・楕円の輪郭は、貼る絵が効いても真の形 (周を刻んだ折れ線でない) で書く")
    func theStrokeOfAShadedFormKeepsItsTrueShape() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        let (figures, _) = try harness.capture { canvas in
            canvas.fill(red)
            canvas.texture(picture)
            canvas.stroke(blue)
            canvas.rect(10, 10, 30, 20)
            canvas.ellipse(60, 30, 30, 20)
        }
        try #require(figures.count == 2)
        #expect(figures[0].subpaths[0].points == [SIMD2(10, 10), SIMD2(40, 10), SIMD2(40, 30), SIMD2(10, 30)])
        #expect(figures[0].subpaths[0].isClosed)
        #expect(figures[1].subpaths[0].curves.count == 4, "楕円は 3 次ベジェ 4 つ")
    }

    @Test("塗りだけの角丸の矩形は畳む道を通っても、貼る絵・断片の塗りを 1 度だけ名指しで落とし、図形は書かない (#3170)")
    func aFoldedRoundedRectDropsOnlyTheFill() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        let shader = try harness.canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        let (figures, drops) = try harness.capture { canvas in
            canvas.noStroke()
            canvas.fill(red)
            canvas.texture(picture)
            canvas.rect(10, 10, 30, 20, 5)
            canvas.noTexture()
            canvas.shader(shader)
            canvas.rect(10, 10, 30, 20, 5)
            canvas.resetShader()
        }
        #expect(figures.isEmpty, "塗りしか無い図形は、塗りを落とせば何も残らない")
        #expect(drops == [.texture, .shader], "\(drops)")
    }

    /// 輪郭の要素が通る道ごとに確かめる、塗りと輪郭を両方持つ基本図形。**実際の公開の口** (`rect(…, r)`・
    /// `ellipse`・`arc`) で置く。
    private var outlinedShapes: [(name: String, place: (Canvas) -> Void)] {
        [
            ("rect", { $0.rect(10, 10, 30, 20) }),
            ("rounded rect", { $0.rect(10, 10, 30, 20, 5) }),
            ("ellipse", { $0.ellipse(30, 30, 30, 20) }),
            ("circle", { $0.circle(30, 30, 24) }),
            ("pie", { $0.arc(30, 30, 30, 20, 0.2, 2.2, .pie) }),
            ("default arc", { $0.arc(30, 30, 30, 20, 0.2, 2.2) }),
            ("chord", { $0.arc(30, 30, 30, 20, 0.2, 2.2, .chord) }),
            ("open arc", { $0.arc(30, 30, 30, 20, 0.2, 2.2, .open) }),
            ("full turn arc", { $0.arc(30, 30, 30, 20, 0, 7) }),
        ]
    }

    /// 図形を 1 つ、輪郭の設定を変えて置き、控えた図形と書けなかったものを返す。
    ///
    /// - `shaded`: 貼る絵 (`texture()`)・勾配・利用者の断片 (`shader()`) のどれが塗りに効くか。
    /// - `dashed`: 破線の輪郭か。
    /// - `filled`: 塗りがあるか。
    /// - `transformed`: 回転と拡大を掛けるか (置くときの変換が点にも破線の長さにも当たる)。
    private func outlinedFigures(
        _ harness: Harness, _ place: (Canvas) -> Void, shaded: Shading? = nil, dashed: Bool,
        filled: Bool = true, transformed: Bool = false
    ) throws -> (figures: [VectorFigure], drops: [VectorDrop]) {
        let picture = try harness.canvas.createGraphics(8, 8)
        let shader = try harness.canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        let gradient = Gradient.linearGradient(
            [(LinearRGBA.linear(red: 1, green: 0, blue: 0), 0), (LinearRGBA.linear(red: 0, green: 0, blue: 1), 1)],
            from: [0, 0], to: [10, 0])
        return try harness.capture { canvas in
            canvas.noTexture()
            canvas.resetShader()
            if filled { canvas.fill(red) } else { canvas.noFill() }
            canvas.stroke(blue)
            canvas.strokeWeight(2)
            if dashed { canvas.strokeDash(6, 3) } else { canvas.noStrokeDash() }
            switch shaded {
            case .texture: canvas.texture(picture)
            case .shader: canvas.shader(shader)
            case .gradient: canvas.fill(gradient)
            case nil: break
            }
            if transformed {
                canvas.translate(20, 5)
                canvas.rotate(0.3)
                canvas.scale(1.5, 1.5)
            }
            place(canvas)
            canvas.resetShader()
            canvas.noTexture()
        }
    }

    enum Shading { case texture, shader, gradient }

    @Test("貼る絵・勾配が効く輪郭つきの図形は、効かない同じ図形と同じ真の形で書き、塗りだけを名指しで落とす (#3271・#3295)")
    func aShadedFigureWithAStrokeWritesTheTrueShape() throws {
        let harness = try Harness()
        for (name, place) in outlinedShapes {
            for dashed in [false, true] {
                for transformed in [false, true] {
                    // 基準: 塗りの無い同じ図形 (貼る絵が無ければ距離関数の道)
                    let (reference, _) = try outlinedFigures(
                        harness, place, dashed: dashed, filled: false, transformed: transformed)
                    try #require(reference.count == 1, "\(name)")
                    for (shading, dropped) in [(Shading.texture, VectorDrop.texture), (.gradient, .gradient)] {
                        let label = "\(name) \(shading) dashed=\(dashed) transformed=\(transformed)"
                        let (figures, drops) = try outlinedFigures(
                            harness, place, shaded: shading, dashed: dashed, transformed: transformed)
                        try #require(figures.count == 1, "\(label): \(figures)")
                        #expect(figures[0] == reference[0], "\(label)")
                        #expect(
                            figures[0].subpaths[0].curves.isEmpty == (name == "rect"),
                            "\(label): 曲線の図形は折れ線でなく 3 次ベジェ")
                        #expect(figures[0].fill == nil, "\(label)")
                        #expect(figures[0].stroke?.dash.isEmpty == !dashed, "\(label)")
                        #expect(drops == [dropped], "\(label): 塗りを 1 度だけ名指す \(drops)")
                    }
                }
            }
        }
    }

    @Test("利用者の断片は輪郭にも効くので、輪郭つきの図形も図形ごと 1 度だけ名指しで落とす (#3271・#3139 の決定 3)")
    func aShaderOnAFigureWithAStrokeDropsTheWholeFigure() throws {
        let harness = try Harness()
        for (name, place) in outlinedShapes {
            for dashed in [false, true] {
                let (figures, drops) = try outlinedFigures(harness, place, shaded: .shader, dashed: dashed)
                #expect(figures.isEmpty, "\(name) dashed=\(dashed): \(figures)")
                #expect(drops == [.shader], "\(name) dashed=\(dashed): \(drops)")
            }
        }
    }

    @Test("破線の図形は、実線の同じ図形と同じ真の形 (折れ線でない)・同じ起点で、破線の指定だけが載る (#3271・#3295)")
    func aDashedFigureWritesTheTrueShapeAndStart() throws {
        let harness = try Harness()
        for (name, place) in outlinedShapes {
            for transformed in [false, true] {
                let label = "\(name) transformed=\(transformed)"
                let (solid, _) = try outlinedFigures(
                    harness, place, dashed: false, filled: false, transformed: transformed)
                let (dashed, drops) = try outlinedFigures(
                    harness, place, dashed: true, filled: true, transformed: transformed)
                try #require(solid.count == 1, "\(label)")
                // 塗り → 輪郭の順。輪郭は塗りの後
                try #require(dashed.count == 2, "\(label): \(dashed)")
                #expect(dashed[0].stroke == nil && dashed[0].fill != nil, "\(label)")
                #expect(dashed[1].fill == nil, "\(label)")
                #expect(dashed[1].subpaths == solid[0].subpaths, "\(label): 輪郭の道が実線と同じ")
                #expect(
                    dashed[1].subpaths[0].curves.isEmpty == (name == "rect"),
                    "\(label): 曲線の図形は折れ線でなく 3 次ベジェ")
                let scale: Float = transformed ? 1.5 : 1
                #expect(dashed[1].stroke?.dash == [6 * scale, 3 * scale], "\(label)")
                #expect(dashed[1].stroke?.width == solid[0].stroke?.width, "\(label)")
                #expect(drops.isEmpty, "\(label): \(drops)")
            }
        }
    }

    @Test("数でない変換の下では、貼る絵が効く図形も破線の図形も書かない (旧い道と同じ・#3271)")
    func aNonFiniteTransformWritesNothing() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        for (name, place) in outlinedShapes {
            for dashed in [false, true] {
                for shaded in [false, true] {
                    let (figures, _) = try harness.capture { canvas in
                        canvas.noTexture()
                        canvas.fill(red)
                        canvas.stroke(blue)
                        canvas.strokeWeight(2)
                        if dashed { canvas.strokeDash(6, 3) } else { canvas.noStrokeDash() }
                        if shaded { canvas.texture(picture) }
                        canvas.translate(Float.nan, 0)
                        place(canvas)
                        canvas.noTexture()
                    }
                    #expect(figures.isEmpty, "\(name) dashed=\(dashed) shaded=\(shaded): \(figures)")
                }
            }
        }
    }

    /// 変換を当てた後の座標が書けない大きさ (1/1000 にした絶対値が 1e15 以上・元の値で約 1e12 以上) の図形は、
    /// 書かずに名指しで落とす (#3318)。書き手は書けない数を `0` と書くので、控えると (0, 0) へ潰れた形が残る。
    /// 数でない座標の図形と違い、有限の図形は画面には描かれるので、黙って消さずに名乗る。
    @Test("変換後の座標が 1e12 を越える有限の図形は、(0, 0) へ潰れた形で書かれず、名指しで落とす (#3318)")
    func aHugeFiniteCoordinateWritesNothing() throws {
        let harness = try Harness()
        for (name, place) in outlinedShapes {
            for dashed in [false, true] {
                let (figures, drops) = try harness.capture { canvas in
                    canvas.fill(red)
                    canvas.stroke(blue)
                    canvas.strokeWeight(2)
                    if dashed { canvas.strokeDash(6, 3) } else { canvas.noStrokeDash() }
                    canvas.translate(2e12, 0)
                    place(canvas)
                }
                #expect(figures.isEmpty, "\(name) dashed=\(dashed): \(figures)")
                #expect(drops == [.tooLarge], "図形 1 つにつき 1 度: \(name) dashed=\(dashed): \(drops)")
            }
        }
        // 線と頂点の形 (基本図形の口とは別の道) も、控えへ足す同じ 1 点で名指しで落とす
        let (figures, drops) = try harness.capture { canvas in
            canvas.stroke(blue)
            canvas.noFill()
            canvas.translate(0, 3e12)
            canvas.line(0, 0, 10, 10)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(15, 5)
            canvas.vertex(5, 15)
            canvas.endShape(.close)
        }
        #expect(figures.isEmpty, "\(figures)")
        #expect(drops == [.tooLarge, .tooLarge], "\(drops)")
    }

    @Test("書けない大きさの座標の図形は落とし、同じ口で置いた書ける図形はそのまま書く (1e12 の外と内)")
    func hugeAndOrdinaryFiguresAreSeparated() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.fill(red)
            canvas.noStroke()
            canvas.push()
            canvas.translate(2e12, 0)
            canvas.circle(0, 0, 20)
            canvas.pop()
            canvas.rect(10, 10, 30, 20)
        }
        #expect(figures.count == 1, "\(figures)")
        #expect(drops == [.tooLarge], "\(drops)")
        let svg = String(decoding: SVGWriter.render(figures[...], width: 100, height: 100), as: UTF8.self)
        let elements = SVG.elements(svg)
        #expect(SVG.attribute("d", in: elements.first ?? "") == "M10 10L40 10 40 30 10 30Z", "\(svg)")
        // 落としたことは、書いた後の知らせの文面にも名指しで出る
        let said = FrameRecorder.vectorLeftOutNotice(path: "x.svg", dropped: drops[...])
        #expect(said.contains("shape x1") && said.contains("1e12 or more"), "\(said)")
    }

    @Test("見えない線の太さは数えない — 塗りが書ける図形は、見えない線が溢れる太さでも塗りを書く (#3318)")
    func anInvisibleStrokeDoesNotDropTheFill() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.fill(red)
            canvas.stroke(.display(red: 0, green: 0, blue: 1, alpha: 0))
            canvas.strokeWeight(1e13)
            canvas.circle(50, 50, 20)
        }
        try #require(figures.count == 1, "\(figures)")
        #expect(figures[0].fill != nil && figures[0].stroke == nil, "\(figures)")
        #expect(drops.isEmpty, "\(drops)")
        // 見える線なら、同じ太さの図形は落とす
        let visible = try harness.capture { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(1e13)
            canvas.circle(50, 50, 20)
        }
        #expect(visible.figures.isEmpty && visible.drops == [.tooLarge], "\(visible)")
    }

    @Test("書いた図形だけが「色が違う」と名乗られ、落とした図形は名乗られない (#3318)")
    func aDroppedShapeIsNotAlsoWrittenInTheFirstVertexColour() throws {
        let harness = try Harness()
        func place(_ shift: Float) throws -> (figures: [VectorFigure], drops: [VectorDrop]) {
            try harness.capture { canvas in
                canvas.noStroke()
                canvas.translate(shift, 0)
                canvas.beginShape()
                canvas.fill(red)
                canvas.vertex(0, 0)
                canvas.fill(blue)
                canvas.vertex(10, 0)
                canvas.vertex(0, 10)
                canvas.endShape(.close)
            }
        }
        let written = try place(0)
        #expect(written.figures.count == 1 && written.drops == [.vertexColours], "\(written)")
        let huge = try place(2e12)
        #expect(huge.figures.isEmpty && huge.drops == [.tooLarge], "書いたとも名乗らない: \(huge)")
        let absent = try place(.nan)
        #expect(absent.figures.isEmpty && absent.drops.isEmpty, "\(absent)")
    }

    @Test("線の太さだけが大きすぎても、破線の有無によらず、塗りも輪郭も図形ごと落ち、名乗りは 1 度 (#3318)")
    func anOversizedStrokeWidthDropsTheWholeFigureThroughEveryDoor() throws {
        let harness = try Harness()
        for (name, place) in outlinedShapes {
            for dashed in [false, true] {
                let (figures, drops) = try harness.capture { canvas in
                    canvas.fill(red)
                    canvas.stroke(blue)
                    canvas.strokeWeight(2e12)
                    if dashed { canvas.strokeDash(6, 3) } else { canvas.noStrokeDash() }
                    place(canvas)
                }
                #expect(figures.isEmpty, "\(name) dashed=\(dashed): \(figures)")
                #expect(drops == [.tooLarge], "\(name) dashed=\(dashed): \(drops)")
            }
        }
    }

    /// 変換の拡大率を掛けた積が Float の上限 (約 3.4e38) を越える形。置き先の中心は有限のまま、角・半径が越える
    /// (中心の置き先が越えるものは、画面が `isPlaceable` で図形ごと落とすので、ここには入れない・#3350)。
    private var overflowingShapes: [(name: String, place: (Canvas) -> Void)] {
        [
            ("rect", { $0.rect(-5e19, -5e19, 1e20, 1e20) }),
            ("rounded rect", { $0.rect(-5e19, -5e19, 1e20, 1e20, 5) }),
            ("ellipse", { $0.ellipse(0, 0, 1e20, 1e20) }),
            ("circle", { $0.circle(0, 0, 1e20) }),
            ("pie", { $0.arc(0, 0, 1e20, 1e20, 0.2, 2.2, .pie) }),
            ("open arc", { $0.arc(0, 0, 1e20, 1e20, 0.2, 2.2, .open) }),
        ]
    }

    /// 有限の座標に有限の拡大率を掛けた積が桁あふれして ∞ になっても、入力は有限なので「数でない」図形とは違う。
    /// 数でない図形は画面にも描かれないので黙って書かないが、桁あふれは画面にも描かれうる大きさの窓があり、
    /// 黙って消さずに `tooLarge` で名乗る (#3350)。
    @Test("有限の座標 × 拡大率が Float の上限を越えて ∞ になった図形は、黙って落とさず名指しで落とす (#3350)")
    func aFiniteCoordinateOverflowingTheScaleIsNamed() throws {
        let harness = try Harness()
        for (name, place) in overflowingShapes {
            for dashed in [false, true] {
                let (figures, drops) = try harness.capture { canvas in
                    canvas.fill(red)
                    canvas.stroke(blue)
                    canvas.strokeWeight(1)
                    if dashed { canvas.strokeDash(6, 3) } else { canvas.noStrokeDash() }
                    canvas.scale(1e19, 1e19)
                    place(canvas)
                }
                #expect(figures.isEmpty, "\(name) dashed=\(dashed): \(figures)")
                #expect(drops == [.tooLarge], "\(name) dashed=\(dashed): \(drops)")
            }
        }
        // 頂点の形の座標 × 拡大率 (基本図形とは別の道)
        let shape = try harness.capture { canvas in
            canvas.fill(red)
            canvas.noStroke()
            canvas.scale(1e19, 1e19)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(1e20, 0)
            canvas.vertex(0, 1e20)
            canvas.endShape(.close)
        }
        #expect(shape.figures.isEmpty && shape.drops == [.tooLarge], "\(shape)")
        // 同じ図形が上限の手前で名乗られるものと、名乗り方が変わらない (上限の手前も約 1e12 を越えれば tooLarge)
        let below = try harness.capture { canvas in
            canvas.fill(red)
            canvas.noStroke()
            canvas.scale(1e10, 1e10)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(1e20, 0)
            canvas.vertex(0, 1e20)
            canvas.endShape(.close)
        }
        #expect(below.figures.isEmpty && below.drops == [.tooLarge], "\(below)")
    }

    @Test("組み立ての途中 (中心 + 半径・制御点の延ばし) で Float の上限を越えた図形も、有限の入力なので名指しで落とす (#3350)")
    func aShapeOverflowingWhileBeingBuiltIsNamed() throws {
        let harness = try Harness()
        for (name, place) in [
            ("circle", { (canvas: Canvas) in canvas.circle(2.5e38, 0, 3e38) }),
            ("ellipse", { (canvas: Canvas) in canvas.ellipse(2.5e38, 0, 3e38, 3e38) }),
            ("pie", { (canvas: Canvas) in canvas.arc(2.5e38, 0, 3e38, 3e38, 0.2, 2.2, .pie) }),
        ] {
            let (figures, drops) = try harness.capture { canvas in
                canvas.fill(red)
                canvas.noStroke()
                place(canvas)
            }
            #expect(figures.isEmpty, "\(name): \(figures)")
            #expect(drops == [.tooLarge], "\(name): \(drops)")
        }
    }

    @Test("有限の線の太さ × 拡大率が Float の上限を越えて ∞ になっても、塗りも輪郭も図形ごと名指しで落とし、名乗りは 1 度 (#3350)")
    func aFiniteStrokeWidthOverflowingTheScaleIsNamed() throws {
        let harness = try Harness()
        for (name, place) in outlinedShapes {
            for dashed in [false, true] {
                let (figures, drops) = try harness.capture { canvas in
                    canvas.fill(red)
                    canvas.stroke(blue)
                    canvas.strokeWeight(1e30)
                    if dashed { canvas.strokeDash(6, 3) } else { canvas.noStrokeDash() }
                    canvas.scale(1e10, 1e10)
                    place(canvas)
                }
                #expect(figures.isEmpty, "\(name) dashed=\(dashed): \(figures)")
                #expect(drops == [.tooLarge], "\(name) dashed=\(dashed): \(drops)")
            }
        }
        // 太さが上限をまたぐ前後で、結果は変わらない (3e38 は有限で書けない大きさ・4e38 は桁あふれ)
        for weight: Float in [3e28, 4e28, 1e30] {
            let (figures, drops) = try harness.capture { canvas in
                canvas.noFill()
                canvas.stroke(blue)
                canvas.strokeWeight(weight)
                canvas.scale(1e10, 1e10)
                canvas.circle(0, 0, 20)
            }
            #expect(figures.isEmpty && drops == [.tooLarge], "weight=\(weight): \(figures) \(drops)")
        }
        // 頂点の形・線 (基本図形とは別の道)
        let (figures, drops) = try harness.capture { canvas in
            canvas.stroke(blue)
            canvas.noFill()
            canvas.strokeWeight(1e30)
            canvas.scale(1e10, 1e10)
            canvas.line(0, 0, 10, 10)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(15, 5)
            canvas.vertex(5, 15)
            canvas.endShape(.close)
        }
        #expect(figures.isEmpty && drops == [.tooLarge, .tooLarge], "\(figures) \(drops)")
    }

    @Test("有限の破線の長さ × 拡大率が Float の上限を越えて ∞ になっても、図形ごと名指しで落とす (#3350)")
    func aFiniteDashLengthOverflowingTheScaleIsNamed() throws {
        let harness = try Harness()
        for (name, place) in outlinedShapes {
            let (figures, drops) = try harness.capture { canvas in
                canvas.noFill()
                canvas.stroke(blue)
                canvas.strokeWeight(2)
                canvas.strokeDash(1e30, 1e30)
                canvas.scale(1e10, 1e10)
                place(canvas)
            }
            #expect(figures.isEmpty && drops == [.tooLarge], "\(name): \(figures) \(drops)")
        }
    }

    @Test("入力そのものが数でない・無限の図形は、拡大率と掛けても桁あふれとは名乗らず、従来どおり黙って書かない (#3350)")
    func aNonFiniteInputIsStillDroppedSilently() throws {
        let harness = try Harness()
        // 数でない頂点は `vertex()` が置かないので、数でない入力が控えへ届くのは変換だけである
        for bad: Float in [.nan, .infinity, -.infinity] {
            // 数でない変換 (太さも大きい)
            let moved = try harness.capture { canvas in
                canvas.fill(red)
                canvas.stroke(blue)
                canvas.strokeWeight(1e30)
                canvas.translate(bad, 0)
                canvas.scale(1e10, 1e10)
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(10, 0)
                canvas.vertex(0, 10)
                canvas.endShape(.close)
                canvas.line(0, 0, 10, 10)
                canvas.circle(0, 0, 10)
            }
            #expect(moved.figures.isEmpty && moved.drops.isEmpty, "translate \(bad): \(moved)")
        }
        // 拡大率の積が桁あふれする変換の行列そのものが有限でない (scale を 2 度重ねて ∞) ときも、入力が有限でないので黙る
        let matrix = try harness.capture { canvas in
            canvas.fill(red)
            canvas.noStroke()
            canvas.scale(1e30, 1e30)
            canvas.scale(1e30, 1e30)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(10, 0)
            canvas.vertex(0, 10)
            canvas.endShape(.close)
        }
        #expect(matrix.figures.isEmpty && matrix.drops.isEmpty, "\(matrix)")
        // 中心の置き先が桁あふれする基本図形は、画面が `isPlaceable` で図形ごと落とすので、書き出しも名乗らない
        let center = try harness.capture { canvas in
            canvas.fill(red)
            canvas.noStroke()
            canvas.scale(1e19, 1e19)
            canvas.circle(1e20, 0, 10)
        }
        #expect(center.figures.isEmpty && center.drops.isEmpty, "\(center)")
    }

    @Test("破線で塗りもある図形の塗りが別の理由で名乗られても、輪郭の大きすぎる名乗りは消えない (種類ごとに 1 件・#3318)")
    func differentReasonsInOneDashedFigureAreBothNamed() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        let (figures, drops) = try harness.capture { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(2e12)
            canvas.strokeDash(6, 3)
            canvas.texture(picture)
            canvas.rect(10, 10, 30, 20)
            canvas.noTexture()
        }
        #expect(figures.isEmpty, "\(figures)")
        #expect(drops == [.texture, .tooLarge], "\(drops)")
        // 括りの約束そのもの: 同じ種類は 1 件・違う種類はどちらも名乗る (括りが最初の 1 件だけ残すと tooLarge が消える)
        let counted = try harness.capture { canvas in
            canvas.countingOneVectorFigure {
                canvas.noteVectorDrop(.gradient)
                canvas.noteVectorDrop(.tooLarge)
                canvas.noteVectorDrop(.gradient)
                canvas.noteVectorDrop(.tooLarge)
            }
        }
        #expect(counted.drops == [.gradient, .tooLarge], "\(counted.drops)")
    }

    @Test("大きさが原因の知らせは、原因を大きさと言い、「線と平らな塗りだけ」とは言わない。種類が原因のものと混ざれば両方言う (#3318)")
    func theNoticeNamesTheCause() {
        let size = FrameRecorder.vectorLeftOutNotice(path: "x.svg", dropped: [.tooLarge, .tooLarge][...])
        #expect(size.contains("1e12 or more") && size.contains("line width") && size.contains("dash length"), "\(size)")
        #expect(size.contains("shape x2") && size.contains("still on the screen"), "\(size)")
        #expect(!size.contains("flat filled shapes only"), "線も平らな塗りも落ちるので言わない: \(size)")
        let mixed = FrameRecorder.vectorLeftOutNotice(path: "x.svg", dropped: [.text, .tooLarge][...])
        #expect(mixed.contains("text x1") && mixed.contains("shape x1") && mixed.contains("1e12 or more"), "\(mixed)")
        #expect(mixed.contains("flat filled shapes only"), "\(mixed)")
        let kind = FrameRecorder.vectorLeftOutNotice(path: "x.svg", dropped: [.text][...])
        #expect(kind.contains("flat filled shapes only") && !kind.contains("1e12"), "\(kind)")
    }

    @Test("頂点の形の穴が書けない大きさなら、穴だけを欠いた外周でなく、図形ごと名指しで落とす (#3318)")
    func aHugeHoleDropsTheWholeShape() throws {
        let harness = try Harness()
        let (figures, drops) = try harness.capture { canvas in
            canvas.fill(red)
            canvas.noStroke()
            canvas.beginShape()
            canvas.vertex(10, 10)
            canvas.vertex(90, 10)
            canvas.vertex(90, 90)
            canvas.vertex(10, 90)
            canvas.beginContour()
            canvas.vertex(30, 30)
            canvas.vertex(2e12, 30)
            canvas.vertex(70, 70)
            canvas.endContour()
            canvas.endShape(.close)
        }
        #expect(figures.isEmpty, "\(figures)")
        #expect(drops == [.tooLarge], "\(drops)")
    }

    @Test("弧の塗り (扇) と輪郭 (開いた弧) は揃って落ちる — 中心だけが書けない大きさの弧で、輪郭だけが残らない (#3318)")
    func anArcFillAndStrokeFallTogether() throws {
        let harness = try Harness()
        // 中心 (1.5e12, 0)・半径 1.5e12 の弧の、角 π ± 0.01 の部分。弧の点は x が 0 の近くへ戻って書ける大きさに
        // 収まり、扇の頂点 (中心) だけが 1e12 を越える
        func place(_ mode: ArcMode?) throws -> (figures: [VectorFigure], drops: [VectorDrop]) {
            try harness.capture { canvas in
                canvas.fill(red)
                canvas.stroke(blue)
                canvas.strokeWeight(2)
                if let mode {
                    canvas.arc(1.5e12, 0, 3e12, 200, Float.pi - 0.01, Float.pi + 0.01, mode)
                } else {
                    canvas.arc(1.5e12, 0, 3e12, 200, Float.pi - 0.01, Float.pi + 0.01)
                }
            }
        }
        // 標準の閉じ方は、塗り (扇) と輪郭 (開いた弧) が別の形。扇が書けないなら、輪郭も一緒に落とす
        let standard = try place(nil)
        #expect(standard.figures.isEmpty, "\(standard.figures)")
        #expect(standard.drops == [.tooLarge], "\(standard.drops)")
        // 弦で結んだ形は中心を含まないので、塗りも輪郭も書ける
        let chord = try place(.chord)
        #expect(chord.figures.count == 1 && chord.drops.isEmpty, "\(chord)")
    }

    @Test("判定は変換の後の座標で行う — 形自身の座標が 1e13 でも、縮めれば収まって書き、拡大して溢れれば控えない")
    func theLimitIsJudgedAfterTheTransform() throws {
        let harness = try Harness()
        let shrunk = try harness.capture { canvas in
            canvas.noFill()
            canvas.stroke(blue)
            canvas.scale(1e-3, 1e-3)
            canvas.line(1e13, 0, 1e13 + 1e6, 0)
        }
        #expect(shrunk.figures.count == 1, "\(shrunk.figures)")
        let points = shrunk.figures.first?.subpaths.first?.points ?? []
        #expect(points.allSatisfy { abs($0.x - 1e10) < 1e7 }, "\(points)")
        let grown = try harness.capture { canvas in
            canvas.noFill()
            canvas.stroke(blue)
            canvas.scale(1e3, 1e3)
            canvas.line(1e10, 0, 1e10 + 1, 0)
        }
        #expect(grown.figures.isEmpty, "\(grown.figures)")
    }

    @Test("書けない設定が効く破線の輪郭を控える口は、落とした印を 1 度だけ付ける (括りに頼らない・#3271)")
    func theDashedFormRecorderCountsABlockedStrokeOnce() throws {
        let harness = try Harness()
        let canvas = harness.canvas
        var drops: [VectorDrop] = []
        _ = try harness.capture { canvas in
            canvas.noFill()
            canvas.stroke(blue)
            canvas.strokeWeight(2)
            canvas.strokeDash(6, 3)
            canvas.blendMode(.add)
            let sink = try! #require(canvas.vector.capture)
            let outline = canvas.ringOutlineForDash(
                radiusX: 15, radiusY: 10, start: 0, sweep: 2 * .pi, piece: .sector, at: SIMD2(30, 30))
            canvas.recordVectorDashedForm(
                sink, kind: .ellipse, center: SIMD2(30, 30), half: SIMD2(15, 10), arc: .zero,
                arcClosure: .pie, cornerRadius: 0, outline: outline)
            drops = sink.drops
            canvas.blendMode(.blend)
        }
        _ = canvas
        #expect(drops == [.blendMode], "\(drops)")
    }

    @Test("輪郭の太さが 0 の角丸 rect は、貼る絵が効いても輪郭を書かず、塗りだけを名指しで落とす (#3271)")
    func aShadedRoundedRectWithoutAStrokeWritesNothing() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        let (figures, drops) = try harness.capture { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(0)
            canvas.texture(picture)
            canvas.rect(10, 10, 30, 20, 5)
            canvas.noTexture()
        }
        #expect(figures.isEmpty, "\(figures)")
        #expect(drops == [.texture], "\(drops)")
    }

    @Test("利用者の断片・通常以外の混ぜ方・切り抜きは輪郭にも効くので、図形ごと 1 つと数えて落とす")
    func whatTouchesTheStrokeDropsTheWholeFigureOnce() throws {
        let harness = try Harness()
        let shader = try harness.canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        let settings: [(String, VectorDrop, (Canvas) -> Void)] = [
            ("shader", .shader, { $0.shader(shader) }),
            ("blend mode", .blendMode, { $0.blendMode(.add) }),
            ("clip", .clip, { $0.clip(0, 0, 90, 90) }),
        ]
        for (name, place) in shapes {
            for (setting, kind, apply) in settings {
                let (figures, drops) = try harness.capture { canvas in
                    canvas.resetShader()
                    canvas.blendMode(.blend)
                    canvas.noClip()
                    canvas.fill(red)
                    canvas.stroke(blue)
                    canvas.strokeWeight(2)
                    apply(canvas)
                    place(canvas)
                    canvas.resetShader()
                    canvas.blendMode(.blend)
                    canvas.noClip()
                }
                #expect(figures.isEmpty, "\(name) + \(setting)")
                #expect(drops == [kind], "\(name) + \(setting): 1 つの図形は 1 つ \(drops)")
            }
        }
    }

    @Test("破線で塗りもある図形は、書けない設定が効いても 1 つと数える")
    func aDashedFilledFigureIsCountedOnce() throws {
        let harness = try Harness()
        let picture = try harness.canvas.createGraphics(8, 8)
        let (figures, drops) = try harness.capture { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(2)
            canvas.strokeDash(4, 2)
            canvas.blendMode(.add)
            canvas.rect(10, 10, 30, 20)
            canvas.ellipse(60, 30, 30, 20)
            canvas.blendMode(.blend)
            canvas.texture(picture)
            canvas.rect(10, 50, 30, 20)
        }
        #expect(drops == [.blendMode, .blendMode, .texture], "矩形 1・楕円 1・貼る絵の矩形 1: \(drops)")
        #expect(figures.count == 1, "貼る絵の矩形は、塗りを落として破線の輪郭だけ書く")
        #expect(figures.first?.stroke?.dash == [4, 2])
    }

    @Test("見えない (不透明度 0 の) 線と塗りは書かず、両方見えない図形は要素にならない")
    func invisibleColoursAreNotWritten() throws {
        let harness = try Harness()
        let svg = try harness.svg { canvas in
            canvas.fill(red)
            canvas.stroke(.display(red: 1, green: 1, blue: 1, alpha: 0))
            canvas.rect(0, 0, 10, 10)  // 塗りだけ
            canvas.noFill()
            canvas.stroke(.display(red: 1, green: 0, blue: 0, alpha: 0))
            canvas.line(0, 0, 10, 10)  // 何も見えない
            canvas.fill(.display(red: 1, green: 0, blue: 0, alpha: 0.0001))
            canvas.noStroke()
            canvas.rect(20, 0, 10, 10)  // 1/1000 に満たない薄さ
            canvas.beginShape()
            canvas.stroke(.display(red: 0, green: 0, blue: 0, alpha: 0))
            canvas.vertex(0, 0)
            canvas.vertex(5, 5)
            canvas.endShape()
        }
        let elements = SVG.elements(svg)
        #expect(elements.count == 1, "\(svg)")
        #expect(SVG.attribute("fill", in: elements.first ?? "") == "#ff0000")
        #expect(SVG.attribute("stroke", in: elements.first ?? "") == nil)
        #expect(!svg.contains("opacity=\"0\""), "不透明度 0 の要素を書かない: \(svg)")
    }

    @Test("Image.save は .svg の名前を受けず、PNG の中身を .svg の名前で書かない")
    func imageSaveRefusesAnSVGName() throws {
        let harness = try Harness()
        let image = try harness.canvas.createImage(4, 4)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mokume-svg-image-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("x.svg").path
        #expect(throws: ImageFailure.self) { try image.save(path) }
        #expect(!FileManager.default.fileExists(atPath: path))
        // PNG は今までどおり
        let png = directory.appendingPathComponent("x.png").path
        try image.save(png)
        #expect(FileManager.default.fileExists(atPath: png))
    }

    // MARK: - 5 画面は変わらない

    /// **控えは観測であって、描く道を変えない。** 同じスケッチを、控えて描いた画素と控えずに描いた画素が
    /// 一致する (GPU を使う。単発で 1 回)。
    @Test("控えて描いた画素が、控えずに描いた画素と一致する")
    func capturingDoesNotChangeThePicture() throws {
        func picture(capturing: Bool) throws -> [UInt8] {
            let harness = try Harness(width: 96, height: 96)
            let canvas = harness.canvas
            let paper = try canvas.createGraphics(8, 8)
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
                // 控えの位置を動かした道 (#3271・#3295): 破線の角丸・楕円・弧と、貼る絵が効く輪郭つきの角丸・弧
                canvas.rect(50, 8, 36, 14, 4)
                canvas.ellipse(22, 30, 16, 12)
                canvas.arc(75, 36, 20, 14, 0.4, 2.6)
                canvas.noStrokeDash()
                canvas.texture(paper)
                canvas.rect(4, 44, 24, 16, 5)
                canvas.arc(40, 80, 24, 16, 0.3, 2.6)
                canvas.arc(70, 90, 24, 12, 0.3, 2.6, .chord)
                canvas.noTexture()
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

    // MARK: - 書けない大きさの数 (#3318)

    private func capture(_ figure: VectorFigure) -> [VectorFigure] {
        let sink = VectorCapture()
        sink.add(figure)
        return sink.figures
    }

    /// 足して、残った図形と名乗りを返す。
    private func captured(_ figure: VectorFigure) -> (figures: [VectorFigure], drops: [VectorDrop]) {
        let sink = VectorCapture()
        sink.add(figure)
        return (sink.figures, sink.drops)
    }

    private func line(from a: SIMD2<Float>, to b: SIMD2<Float>, width: Float = 1, dash: [Float] = []) -> VectorFigure {
        VectorFigure(
            subpaths: [VectorSubpath(points: [a, b], isClosed: false)], fill: nil,
            stroke: VectorStroke(color: VectorColor(red: 0, green: 0, blue: 0, opacity: 1), width: width, cap: .round, join: .miter, dash: dash))
    }

    /// Float で 1e12 に最も近い下側の値 (999999995904) まで書け、次の値 (1000000061440) から書けない。
    @Test("書ける数の境界: 1/1000 にした絶対値が 1e15 に届く直前までは書き、届いたら書けない")
    func theWritableBoundary() {
        let below: Float = 999_999_995_904
        let above: Float = 1_000_000_061_440
        #expect(below.nextUp == above)
        #expect(SVGWriter.fit(of: below) == .writable)
        #expect(SVGWriter.fit(of: -below) == .writable)
        #expect(SVGWriter.fit(of: above) == .tooLarge)
        #expect(SVGWriter.fit(of: -above) == .tooLarge)
        #expect(SVGWriter.fit(of: .nan) == .notANumber)
        #expect(SVGWriter.fit(of: .infinity) == .notANumber)
        #expect(SVGWriter.fit(of: 0) == .writable)
        #expect(SVGWriter.fit(of: -0.0) == .writable)
        // 境界の内側は、そのままの値で書く
        #expect(capture(line(from: SIMD2(below, 0), to: SIMD2(0, -below))).count == 1)
        let svg = String(
            decoding: SVGWriter.render([line(from: SIMD2(below, 0), to: SIMD2(1, 1))][...], width: 10, height: 10),
            as: UTF8.self)
        #expect(svg.contains("d=\"M999999995904 0L1 1\""), "\(svg)")
    }

    @Test("書けない大きさの点・線の太さ・破線を持つ図形は足さず、有限なら名指しで落とし、数でなければ黙って足さない")
    func figuresWithUnwritableNumbersAreNotCaptured() {
        let above: Float = 1_000_000_061_440
        for (name, figure) in [
            ("end point", line(from: SIMD2(0, 0), to: SIMD2(above, 0))),
            ("start point", line(from: SIMD2(0, -above), to: SIMD2(1, 1))),
            ("width", line(from: SIMD2(0, 0), to: SIMD2(1, 1), width: above)),
            ("dash", line(from: SIMD2(0, 0), to: SIMD2(1, 1), dash: [4, above])),
        ] {
            let result = captured(figure)
            #expect(result.figures.isEmpty && result.drops == [.tooLarge], "\(name): \(result)")
        }
        // 数でない座標は、画面にも描かれないので名乗らない
        let notANumber = captured(line(from: SIMD2(0, 0), to: SIMD2(.nan, 1)))
        #expect(notANumber.figures.isEmpty && notANumber.drops.isEmpty, "\(notANumber)")
        // 数でない点と書けない点が混じれば、画面に無い図形なので名乗らない
        let mixed = captured(line(from: SIMD2(.infinity, 0), to: SIMD2(above, 1)))
        #expect(mixed.figures.isEmpty && mixed.drops.isEmpty, "\(mixed)")
        // 2 つ目の道の点でも見る
        let second = VectorFigure(
            subpaths: [
                VectorSubpath(points: [SIMD2(0, 0), SIMD2(1, 1)], isClosed: false),
                VectorSubpath(points: [SIMD2(0, 0), SIMD2(above, 1)], isClosed: false),
            ], fill: VectorFill(color: VectorColor(red: 0, green: 0, blue: 0, opacity: 1), evenOdd: false), stroke: nil)
        #expect(captured(second).figures.isEmpty && captured(second).drops == [.tooLarge])
        // 普通の図形は足される
        #expect(capture(line(from: SIMD2(0, 0), to: SIMD2(1e9, 1), width: 3, dash: [4, 2])).count == 1)
    }

    @Test("見えない線を外した後で判定する — 書ける塗りと、溢れる太さの見えない線の図形は、塗りを残す")
    func visibilityIsDecidedBeforeFitting() {
        let above: Float = 1_000_000_061_440
        let fill = VectorFill(color: VectorColor(red: 255, green: 0, blue: 0, opacity: 1), evenOdd: false)
        let ghost = VectorStroke(
            color: VectorColor(red: 0, green: 0, blue: 255, opacity: 0), width: above, cap: .round, join: .miter,
            dash: [above])
        let figure = VectorFigure(
            subpaths: [VectorSubpath(points: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 10)], isClosed: true)],
            fill: fill, stroke: ghost)
        let result = captured(figure)
        #expect(result.figures.count == 1 && result.figures[0].stroke == nil && result.drops.isEmpty, "\(result)")
    }

    @Test("1 つの図形の部品は、揃って足されるか揃って落ちる — 名乗りは 1 度")
    func partsFallTogether() {
        let above: Float = 1_000_000_061_440
        let red = VectorFill(color: VectorColor(red: 255, green: 0, blue: 0, opacity: 1), evenOdd: false)
        let blue = VectorStroke(
            color: VectorColor(red: 0, green: 0, blue: 255, opacity: 1), width: 1, cap: .round, join: .miter)
        func parts(fillPoint: SIMD2<Float>) -> [VectorFigure] {
            [
                VectorFigure(subpaths: [VectorSubpath(points: [fillPoint, SIMD2(1, 0), SIMD2(0, 1)], isClosed: true)], fill: red, stroke: nil),
                VectorFigure(subpaths: [VectorSubpath(points: [SIMD2(1, 0), SIMD2(0, 1)], isClosed: false)], fill: nil, stroke: blue),
            ]
        }
        let together = VectorCapture()
        together.group { parts(fillPoint: SIMD2(0, 0)).forEach { together.add($0) } }
        #expect(together.figures.count == 2 && together.drops.isEmpty)
        let dropped = VectorCapture()
        dropped.group { parts(fillPoint: SIMD2(above, 0)).forEach { dropped.add($0) } }
        #expect(dropped.figures.isEmpty && dropped.drops == [.tooLarge], "\(dropped.figures)")
        let absent = VectorCapture()
        absent.group { parts(fillPoint: SIMD2(.nan, 0)).forEach { absent.add($0) } }
        #expect(absent.figures.isEmpty && absent.drops.isEmpty)
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
