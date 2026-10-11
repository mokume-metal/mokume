// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// SVG の読み解き (``SVGFile``) と、読めないときの伝え方 ([#2019])。GPU は要らない。
///
/// 期待値は書いた文字から手で導く ([ADR-0019] 決定 4)。絵が正しいかは
/// ``SVGShapeTests`` が、同じ形を本体の口で描いた絵と比べて見る。
///
/// [#2019]: https://github.com/mokume-metal/mokume/issues/2019
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite("SVG の読み解き")
struct SVGFileTests {
    // MARK: - 補助

    /// 線の集まりを、始点と線分の終点の並びにする (形を数で比べるため)。
    private func points(_ subpath: SVGFile.Subpath) -> [SIMD2<Float>] {
        [subpath.start] + subpath.segments.map { segment in
            switch segment {
            case .line(let point): point
            case .cubic(_, _, let point): point
            }
        }
    }

    private func isClose(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tolerance: Float = 1e-3) -> Bool {
        simd_length(a - b) < tolerance
    }

    private func document(_ body: String, root: String = "<svg xmlns=\"http://www.w3.org/2000/svg\">")
        throws -> SVGFile.Drawing
    {
        try SVGFile.parse("\(root)\n\(body)\n</svg>", path: "test.svg")
    }

    // MARK: - パスの文法

    @Test("相対の命令と絶対の命令が同じ線になる (l / h / v / z)")
    func relativeCommandsMatchAbsoluteOnes() {
        let absolute = SVGFile.parsePath("M10 10 L30 10 V30 H10 Z")
        let relative = SVGFile.parsePath("m10 10 l20 0 v20 h-20 z")
        #expect(absolute.brokenAfter == nil)
        #expect(relative == absolute)
        let subpath = absolute.subpaths[0]
        #expect(subpath.isClosed)
        #expect(points(subpath) == [SIMD2(10, 10), SIMD2(30, 10), SIMD2(30, 30), SIMD2(10, 30)])
    }

    @Test("区切りを省いた数 (符号と小数点で始まる数) を読み分ける")
    func numbersWithoutSeparators() {
        let data = SVGFile.parsePath("M10-20.5.5.5L1e1,2E-1")
        #expect(data.brokenAfter == nil)
        #expect(points(data.subpaths[0]) == [SIMD2(10, -20.5), SIMD2(0.5, 0.5), SIMD2(10, 0.2)])
    }

    @Test("移動の後に続く組は直線になる (m の後は相対の直線)")
    func pairsAfterAMoveAreLines() {
        #expect(points(SVGFile.parsePath("M0 0 10 0 10 10").subpaths[0]) == [.zero, SIMD2(10, 0), SIMD2(10, 10)])
        #expect(points(SVGFile.parsePath("m5 5 10 0 0 10").subpaths[0]) == [SIMD2(5, 5), SIMD2(15, 5), SIMD2(15, 15)])
    }

    @Test("閉じた後に移動を挟まず続く線は、閉じた線の始点から始まる")
    func drawingAfterCloseStartsAtTheSubpathStart() {
        let data = SVGFile.parsePath("M10 10 l10 0 l0 10 z l5 5")
        #expect(data.subpaths.count == 2)
        #expect(points(data.subpaths[1]) == [SIMD2(10, 10), SIMD2(15, 15)])
    }

    @Test("S は直前の 3 次曲線の制御点を、T は直前の 2 次曲線の制御点を鏡に映す")
    func smoothCurvesReflectThePreviousControlPoint() throws {
        let cubic = SVGFile.parsePath("M0 0 C0 10 10 10 10 0 S20 -10 20 0").subpaths[0]
        guard case .cubic(let reflected, _, _) = cubic.segments[1] else {
            Issue.record("2 つ目が 3 次曲線でない")
            return
        }
        #expect(isClose(reflected, SIMD2(10, -10)))

        // 2 次曲線は 3 次として持つ。鏡に映した制御点 (15, -10) の 2/3 の位置が 1 つ目の制御点
        let quadratic = SVGFile.parsePath("M0 0 Q5 10 10 0 T20 0").subpaths[0]
        guard case .cubic(let first, _, let end) = quadratic.segments[1] else {
            Issue.record("2 つ目が曲線でない")
            return
        }
        #expect(isClose(first, SIMD2(10 + 5 * 2 / 3, -10 * 2 / 3)))
        #expect(end == SIMD2(20, 0))

        // 直前が曲線でなければ、今の点を制御点にする
        let afterLine = SVGFile.parsePath("M0 0 L10 0 S20 10 30 0").subpaths[0]
        guard case .cubic(let fromPoint, _, _) = afterLine.segments[1] else {
            Issue.record("2 つ目が曲線でない")
            return
        }
        #expect(fromPoint == SIMD2(10, 0))
    }

    @Test("弧のフラグは詰めて書いてもよく、向き (sweep) で通る側が変わる")
    func arcFlagsAndSweep() {
        // 「1」「0」と終点「10 0」を区切りなしで書いた形。半径 5 の半円で、90° ずつ 2 本に割れる
        let below = SVGFile.parsePath("M0 0a5 5 0 1010 0").subpaths[0]
        #expect(below.segments.count == 2)
        #expect(isClose(points(below)[1], SIMD2(5, 5)), "sweep 0 は下を通る: \(points(below))")
        #expect(points(below)[2] == SIMD2(10, 0))

        let above = SVGFile.parsePath("M0 0 A5 5 0 0 1 10 0").subpaths[0]
        #expect(isClose(points(above)[1], SIMD2(5, -5)), "sweep 1 は上を通る: \(points(above))")
    }

    @Test("弧の半径が足りなければ広げ、半径 0 なら直線、始点と同じ終点なら何も描かない")
    func arcEdgeCases() {
        let widened = SVGFile.parsePath("M0 0 A1 1 0 0 1 10 0").subpaths[0]
        #expect(isClose(points(widened)[1], SIMD2(5, -5)), "半径は 5 へ広がる: \(points(widened))")

        let flat = SVGFile.parsePath("M0 0 A0 4 0 0 1 10 0").subpaths[0]
        #expect(flat.segments == [.line(SIMD2(10, 0))])

        #expect(SVGFile.parsePath("M3 3 A4 4 0 0 1 3 3").subpaths.isEmpty)
    }

    @Test("壊れた所までは読み、壊れた所の手前の文字を返す")
    func brokenPathDataKeepsWhatCameBefore() {
        let data = SVGFile.parsePath("M0 0 L10 0 L5")
        #expect(points(data.subpaths[0]) == [.zero, SIMD2(10, 0)])
        #expect(data.brokenAfter == "M0 0 L10 0 L")
        // 移動で始まらない・閉じた後に数が続く
        #expect(SVGFile.parsePath("L10 0").brokenAfter != nil)
        #expect(SVGFile.parsePath("M0 0 L1 1 Z 4 4").brokenAfter != nil)
    }

    // MARK: - 変換・色・長さ

    @Test("変換は左から順に掛かる (点には右の変換が先に掛かる)")
    func transformsComposeLeftToRight() throws {
        let chained = try #require(SVGFile.parseTransform("translate(10 20) rotate(90) scale(2)"))
        #expect(isClose(chained.apply(SIMD2(1, 0)), SIMD2(10, 22)))
        let pivoted = try #require(SVGFile.parseTransform("rotate(90 10 10)"))
        #expect(isClose(pivoted.apply(SIMD2(20, 10)), SIMD2(10, 20)))
        let skewed = try #require(SVGFile.parseTransform("skewX(45)"))
        #expect(isClose(skewed.apply(SIMD2(0, 1)), SIMD2(1, 1)))
        let matrix = try #require(SVGFile.parseTransform("matrix(1,0,0,1,5,6) translate(1)"))
        #expect(isClose(matrix.apply(.zero), SIMD2(6, 6)))
        #expect(SVGFile.parseTransform("rotate(a)") == nil)
        #expect(SVGFile.parseTransform("spin(10)") == nil)
    }

    @Test(
        "色の書き方を読み分ける",
        arguments: [
            ("#f80", 255, 136, 0, 255), ("#FF8800", 255, 136, 0, 255), ("#ff880080", 255, 136, 0, 128),
            ("#f808", 255, 136, 0, 136), ("rgb(255, 136, 0)", 255, 136, 0, 255),
            ("rgb(100%, 0%, 50%)", 255, 0, 128, 255), ("rgba(0,0,0,0.5)", 0, 0, 0, 128),
            ("rgb(255 136 0 / 50%)", 255, 136, 0, 128), ("rebeccapurple", 102, 51, 153, 255),
            ("Gold", 255, 215, 0, 255), ("transparent", 0, 0, 0, 0),
        ])
    func colorSpellings(_ sample: (String, Int, Int, Int, Int)) throws {
        let color = try #require(SVGFile.parseColor(sample.0))
        let read = [color.red, color.green, color.blue, color.alpha].map { Int(($0 * 255).rounded()) }
        #expect(read == [sample.1, sample.2, sample.3, sample.4], "\(sample.0)")
    }

    @Test("読めない色は nil", arguments: ["#12345", "#ggg", "notacolor", "rgb(1, 2)", "hsl(0, 0%, 0%)"])
    func unreadableColors(_ text: String) {
        #expect(SVGFile.parseColor(text) == nil)
    }

    @Test("長さの単位と割合")
    func lengths() {
        #expect(SVGFile.parseLength("12", reference: 0) == 12)
        #expect(SVGFile.parseLength("12px", reference: 0) == 12)
        #expect(SVGFile.parseLength("1in", reference: 0) == 96)
        #expect(SVGFile.parseLength("50%", reference: 80) == 40)
        #expect(SVGFile.parseLength("2em", reference: 0) == nil)
    }

    // MARK: - 文書

    @Test("基本図形と、群の変換を畳んだ置き場所を読む")
    func elementsAndGroupTransforms() throws {
        let drawing = try document(
            """
            <g transform="translate(100 0)">
              <g transform="scale(2)">
                <rect x="1" y="2" width="3" height="4" fill="red"/>
              </g>
              <circle cx="5" cy="6" r="7"/>
            </g>
            <ellipse cx="1" cy="2" rx="3" ry="4" fill="none" stroke="blue"/>
            <line x1="0" y1="0" x2="5" y2="5" stroke="#000"/>
            <polyline points="0,0 5,0 5,5" fill="none" stroke="black"/>
            <polygon points="0,0 5,0 5,5"/>
            """)
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items.count == 6)
        let rect = drawing.items[0]
        #expect(rect.outline == .rect(x: 1, y: 2, width: 3, height: 4))
        #expect(isClose(rect.transform.apply(SIMD2(1, 2)), SIMD2(102, 4)))
        #expect(rect.fill == SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(rect.stroke == nil, "線の既定は none")
        // 塗りの既定は黒
        #expect(drawing.items[1].fill == .black)
        #expect(drawing.items[1].outline == .ellipse(centerX: 5, centerY: 6, radiusX: 7, radiusY: 7))
        #expect(drawing.items[2].fill == nil)
        #expect(drawing.items[3].fill == nil, "line は塗らない")
        guard case .path(let open) = drawing.items[4].outline, case .path(let closed) = drawing.items[5].outline
        else {
            Issue.record("polyline / polygon が線の集まりになっていない")
            return
        }
        #expect(!open[0].isClosed)
        #expect(closed[0].isClosed)
    }

    @Test("viewBox を幅と高さへ写す (既定は縦横比を保って中央へ)")
    func viewBoxFitsTheViewport() throws {
        let drawing = try document(
            "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\"/>",
            root: "<svg width=\"200\" height=\"100\" viewBox=\"10 10 100 100\">")
        let transform = drawing.items[0].transform
        // 縦横の小さいほうの倍率 (1) で写し、横の余り 100 の半分だけ右へ寄せる
        #expect(isClose(transform.apply(SIMD2(10, 10)), SIMD2(50, 0)))
        #expect(isClose(transform.apply(SIMD2(110, 110)), SIMD2(150, 100)))

        let stretched = try document(
            "<rect width=\"10\" height=\"10\"/>",
            root: "<svg width=\"200\" height=\"100\" viewBox=\"0 0 100 100\" preserveAspectRatio=\"none\">")
        #expect(isClose(stretched.items[0].transform.apply(SIMD2(100, 100)), SIMD2(200, 100)))
    }

    @Test("書き方の優先は 属性 < 要素名の規則 < クラスの規則 < style 属性")
    func cascadeOrder() throws {
        let drawing = try document(
            """
            <style>.a { fill: #00ff00; } rect { fill: #0000ff; stroke: #ff0000 } .b { stroke-width: 4 }</style>
            <rect class="a b" width="1" height="1" fill="#ffffff"/>
            <rect width="1" height="1" fill="#ffffff"/>
            <rect class="a" style="fill: #123456 !important" width="1" height="1"/>
            <rect class="unknown" width="1" height="1" fill="#ffffff" style="stroke:none"/>
            """)
        let green = SVGFile.Color(red: 0, green: 1, blue: 0, alpha: 1)
        let blue = SVGFile.Color(red: 0, green: 0, blue: 1, alpha: 1)
        #expect(drawing.items[0].fill == green)
        #expect(drawing.items[0].strokeWidth == 4)
        #expect(drawing.items[0].stroke == SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(drawing.items[1].fill == blue)
        #expect(drawing.items[2].fill == SVGFile.parseColor("#123456"))
        #expect(drawing.items[3].fill == blue)
        #expect(drawing.items[3].stroke == nil)
    }

    @Test("受け継ぎ: 色は子へ渡り、currentColor は color を引き、不透明度は掛かる")
    func inheritance() throws {
        let drawing = try document(
            """
            <g fill="red" stroke="currentColor" color="#00f" opacity="0.5" stroke-linecap="round">
              <rect width="1" height="1" fill-opacity="0.5"/>
              <rect width="1" height="1" fill="inherit" color="lime"/>
            </g>
            """)
        #expect(drawing.items[0].fill?.alpha == 0.25)
        #expect(drawing.items[0].stroke == SVGFile.Color(red: 0, green: 0, blue: 1, alpha: 0.5))
        #expect(drawing.items[0].cap == .round)
        #expect(drawing.items[1].stroke?.green == 1, "currentColor は要素自身の color を引く")
        #expect(drawing.items[1].fill?.red == 1)
    }

    @Test("SVG の端と角の既定は butt と miter (本体の綴りでは square と miter)")
    func strokeDefaults() throws {
        let drawing = try document(
            """
            <line x2="1" stroke="black"/>
            <line x2="1" stroke="black" stroke-linecap="square" stroke-linejoin="bevel"/>
            """)
        #expect(drawing.items[0].cap == .square)
        #expect(drawing.items[0].join == .miter)
        #expect(drawing.items[1].cap == .project)
        #expect(drawing.items[1].join == .bevel)
    }

    @Test("display=\"none\" と visibility=\"hidden\" は描かず、数えもしない")
    func hiddenThingsAreNotDrawnNorReported() throws {
        let drawing = try document(
            """
            <g display="none"><rect width="1" height="1"/><text>gone</text></g>
            <g visibility="hidden"><rect width="1" height="1"/><rect visibility="visible" width="2" height="2"/></g>
            """)
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items.map(\.outline) == [.rect(x: 0, y: 0, width: 2, height: 2)])
    }

    @Test("角丸の矩形は線の集まりに、片方だけ書いた半径はもう片方にも使う")
    func roundedRectangles() throws {
        let drawing = try document("<rect x=\"0\" y=\"0\" width=\"20\" height=\"10\" rx=\"8\"/>")
        guard case .path(let subpaths) = drawing.items[0].outline else {
            Issue.record("角丸の矩形が線の集まりになっていない")
            return
        }
        // 縦の半径は高さの半分 (5) で止まる。上の辺は x = 8 から 12 まで
        #expect(subpaths[0].start == SIMD2(8, 0))
        #expect(subpaths[0].isClosed)
        let corners = points(subpaths[0])
        #expect(corners.contains(SIMD2(20, 5)))
        #expect(corners.contains(SIMD2(0, 5)))
    }

    @Test("switch は拡張を求めない最初の子だけを描く (Illustrator の互換の書き出し)")
    func switchPicksTheFirstPlainChild() throws {
        let drawing = try document(
            """
            <switch>
              <foreignObject requiredExtensions="http://ns.adobe.com/AdobeIllustrator/10.0/" width="1" height="1"/>
              <g><rect width="3" height="3"/></g>
              <rect width="9" height="9"/>
            </switch>
            """)
        #expect(drawing.items.map(\.outline) == [.rect(x: 0, y: 0, width: 3, height: 3)])
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
    }

    @Test("根に前置きの付いた SVG も読み、他の名前空間の要素は黙って飛ばす")
    func namespacePrefixes() throws {
        let prefixed = try SVGFile.parse(
            """
            <s:svg xmlns:s="http://www.w3.org/2000/svg" xmlns:i="urn:x">
              <i:namedview/><s:rect width="2" height="2"/>
            </s:svg>
            """, path: "prefixed.svg")
        #expect(prefixed.items.count == 1)
        #expect(prefixed.skipped.isEmpty)
    }

    @Test("Illustrator の古い書き出し (DOCTYPE と実体・独自の名前空間の要素) を読む")
    func legacyIllustratorExport() throws {
        let drawing = try SVGFile.parse(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [
              <!ENTITY ns_svg "http://www.w3.org/2000/svg">
              <!ENTITY st0 "fill:#E94E1B;">
            ]>
            <svg version="1.1" xmlns="&ns_svg;" xmlns:i="http://ns.adobe.com/AdobeIllustrator/10.0/" x="0px" y="0px" width="20px" height="20px" viewBox="0 0 20 20">
            <i:pgf id="adobe_illustrator_pgf">ignored</i:pgf>
            <rect x="2" y="2" width="16" height="16" style="&st0;"/>
            </svg>
            """, path: "legacy.svg")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items.count == 1)
        #expect(drawing.items[0].fill == SVGFile.parseColor("#E94E1B"))
    }

    // MARK: - 捨てたものの一覧

    @Test("描けないものは、何を何回・最初の行で名乗る")
    func skippedThingsAreCountedWithTheirFirstLine() throws {
        let drawing = try SVGFile.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
            <defs><linearGradient id="g"/><clipPath id="c"><rect width="1" height="1"/></clipPath></defs>
            <title>never drawn and never counted</title>
            <text x="0" y="0">A</text>
            <text x="0" y="9">B</text>
            <rect width="4" height="4" fill="url(#g) #ff0000" clip-path="url(#c)"/>
            <rect width="4" height="4" fill="url(#g)" stroke="black" stroke-dasharray="2 1"/>
            <image href="x.png" width="1" height="1"/>
            <use href="#c"/>
            <path d="M0 0 L5 5 L"/>
            <rect width="4" height="4" fill="not-a-color"><animate attributeName="x"/></rect>
            <style>g .deep { fill: red }</style>
            </svg>
            """, path: "skips.svg")
        let skipped = Dictionary(uniqueKeysWithValues: drawing.skipped.map { ($0.what, $0) })
        #expect(skipped["<text>"] == SVGFile.Skip(what: "<text>", count: 2, line: 4))
        #expect(skipped["fill=\"url(…)\""]?.count == 2)
        #expect(skipped["fill=\"url(…)\""]?.line == 6)
        #expect(skipped["clip-path"]?.line == 6)
        #expect(skipped["stroke-dasharray"]?.line == 7)
        #expect(skipped["<image>"]?.line == 8)
        #expect(skipped["<use>"]?.line == 9)
        #expect(skipped["path data after \"M0 0 L5 5 L\""]?.line == 10)
        #expect(skipped["fill \"not-a-color\""]?.line == 11)
        #expect(skipped["<animate>"]?.line == 11)
        #expect(skipped["CSS rule \"g .deep\""]?.line == 12)
        // 定義・題・切り抜きの中の形は数えない
        #expect(skipped["<linearGradient>"] == nil)
        #expect(skipped["<title>"] == nil)
        #expect(drawing.skipped.count == 10, "\(drawing.skipped.map(\.what))")

        // 代わりの色があればその色で塗り、無ければ塗らない。壊れたパスも壊れた所までは描く
        #expect(drawing.items[0].fill == SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(drawing.items[1].fill == nil)
        #expect(drawing.items[1].stroke != nil)
        guard case .path(let subpaths) = drawing.items[2].outline else {
            Issue.record("壊れたパスの手前が描かれていない")
            return
        }
        #expect(points(subpaths[0]) == [.zero, SIMD2(5, 5)])
        // 読めない色は受け継いだ黒のまま
        #expect(drawing.items[3].fill == .black)
    }

    @Test("知らせの文面に、捨てたものと数と行が載る")
    func noticeNamesWhatWasSkipped() throws {
        let drawing = try document("<text>A</text><text>B</text><rect width=\"1\" height=\"1\" clip-path=\"url(#c)\"/>")
        let notice = Canvas.svgSkippedNotice(drawing, path: "logo.svg")
        #expect(notice.contains("\"logo.svg\""))
        #expect(notice.contains("<text> (2 times, first at line 2)"))
        #expect(notice.contains("clip-path (line 2)"))
        #expect(notice.contains("drew what mokume can draw"))

        let nothing = try document("<text>only words</text>")
        #expect(nothing.items.isEmpty)
        #expect(Canvas.svgSkippedNotice(nothing, path: "words.svg").contains("the shape is empty"))
    }

    // MARK: - 塗りの規則

    @Test("evenodd は入れ子の深さで向きをそろえ直す (同じ向きの穴が穴になる)")
    func evenOddAlternatesNestedRings() {
        // 外側も内側も同じ向き (時計回り) で書いた 2 つの正方形と、外側の外にある正方形
        let data = SVGFile.parsePath(
            "M0 0 H30 V30 H0 Z M10 10 H20 V20 H10 Z M40 0 H50 V10 H40 Z")
        let rings = SVGFile.alternatingWinding(data.subpaths)
        func area(_ subpath: SVGFile.Subpath) -> Float {
            let polygon = subpath.roughPolygon
            var sum: Float = 0
            for index in polygon.indices {
                let here = polygon[index]
                let next = polygon[(index + 1) % polygon.count]
                sum += here.x * next.y - next.x * here.y
            }
            return sum
        }
        #expect(area(rings[0]) > 0)
        #expect(area(rings[1]) < 0, "内側の正方形が外側と逆向きになっていない")
        #expect(area(rings[2]) > 0, "外にある正方形まで裏返っている")
    }

    // MARK: - 曲線の刻み

    @Test("曲線の刻みの数は、曲がり具合と置く倍率で増え、まっすぐな曲線は 1 本")
    func curveStepsFollowTheBend() {
        let straight = Canvas.curveSteps(.zero, SIMD2(1, 0), SIMD2(2, 0), SIMD2(3, 0), scale: 1)
        #expect(straight == 1)
        // 半径 100 の 4 分の 1 円
        let k: Float = 0.5523 * 100
        let quarter = Canvas.curveSteps(
            SIMD2(100, 0), SIMD2(100, k), SIMD2(k, 100), SIMD2(0, 100), scale: 1)
        let enlarged = Canvas.curveSteps(
            SIMD2(100, 0), SIMD2(100, k), SIMD2(k, 100), SIMD2(0, 100), scale: 4)
        #expect(quarter > 20, "等倍でも既定の刻み (20) より細かい: \(quarter)")
        #expect(enlarged > quarter)
        #expect(enlarged <= 256)
    }

    // MARK: - 読めないときの伝え方

    /// 読み込みの口を呼ぶためのスケッチ。**走らせない** — 失敗は面を使う前に投げる。
    final class Probe: Sketch {
        var settings = SketchSettings(width: 8, height: 8)
        init() {}
        func setup() {}
        func draw() {}
    }

    /// 検査ごとに別の名前で、一時ディレクトリへ書く。
    private func written(_ data: Data, as name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-svg-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    @Test("見つからないファイルは notFound で、探した場所が載る")
    func missingFileThrowsNotFound() {
        let name = "mokume-no-such-\(UUID().uuidString).svg"
        do {
            _ = try Probe().loadShape(name)
            Issue.record("見つからないファイルを読めたことになっている")
        } catch {
            guard case .notFound(let path, let searched) = error else {
                Issue.record("notFound でない: \(error)")
                return
            }
            #expect(path == name)
            #expect(!searched.isEmpty)
        }
    }

    @Test("UTF-8 でないファイルは unreadable")
    func nonUTF8ThrowsUnreadable() throws {
        let url = try written(Data([0x3C, 0x73, 0x76, 0x67, 0xFF, 0xFE]), as: "binary.svg")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DataFailure.unreadable(path: url.path)) { try Probe().loadShape(url.path) }
    }

    @Test("XML として壊れたファイルは malformed で、壊れた行が載る")
    func brokenXMLThrowsMalformedWithTheLine() throws {
        let url = try written(
            Data("<svg>\n<rect width=\"1\" height=\"1\">\n</svg>\n".utf8), as: "broken.svg")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try Probe().loadShape(url.path)
            Issue.record("壊れた XML を読めたことになっている")
        } catch {
            guard case .malformed(let path, let line, _) = error else {
                Issue.record("malformed でない: \(error)")
                return
            }
            #expect(path == url.path)
            #expect(line == 3)
        }
    }

    @Test("根が <svg> でない XML は malformed で、根の名前を名乗る")
    func nonSVGRootThrowsMalformed() throws {
        do {
            _ = try SVGFile.parse("<?xml version=\"1.0\"?>\n<html><body/></html>", path: "page.html")
            Issue.record("SVG でない XML を読めたことになっている")
        } catch {
            guard case .malformed(_, let line, let reason) = error else {
                Issue.record("malformed でない: \(error)")
                return
            }
            #expect(line == 2)
            #expect(reason.contains("<html>"))
        }
    }

    /// **投げた case を見る。** `parse` は `throws(DataFailure)` なので、型だけを見ると
    /// どの case でも通る (#2289)。
    @Test("空の文字は malformed")
    func emptyTextThrowsMalformed() {
        do {
            _ = try SVGFile.parse("", path: "empty.svg")
            Issue.record("空の文字を読めたことになっている")
        } catch {
            guard case .malformed(let path, _, _) = error else {
                Issue.record("malformed でない: \(error)")
                return
            }
            #expect(path == "empty.svg")
        }
    }
}
