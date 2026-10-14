// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 優先の順の検査が使う色 (純色)。
private nonisolated enum Ink {
    static let red = SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1)
    static let green = SVGFile.Color(red: 0, green: 1, blue: 0, alpha: 1)
    static let blue = SVGFile.Color(red: 0, green: 0, blue: 1, alpha: 1)
}

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

    /// 数は SVG / CSS の数の文法 (10 進の綴り) で読む。Swift の `Float(String)` が受ける 16 進・
    /// `nan`・`inf` は数でなく、数と単位のあいだの空白も読めない値のまま ([#2513])。
    ///
    /// [#2513]: https://github.com/mokume-metal/mokume/issues/2513
    @Test("長さと色の成分は 10 進の綴りだけを数にする (#2513)")
    func numbersAreDecimalOnly() {
        for text in ["0x10", "0x10mm", "0x10%", "0x1p-1", "0X2px", "nan", "inf", "10 px", "1e39"] {
            #expect(SVGFile.parseLength(text, reference: 100) == nil, "\(text)")
        }
        #expect(SVGFile.parseLength(" .5px\n", reference: 0) == 0.5)
        #expect(SVGFile.parseLength("+1e1", reference: 0) == 10)
        #expect(SVGFile.parseLength("-0.5in", reference: 0) == -48)
        for text in ["rgb(0x10, 0, 0)", "rgb(0x10%, 0%, 0%)", "rgba(0, 0, 0, 0x1p-1)", "rgb(nan, 0, 0)"] {
            #expect(SVGFile.parseColor(text) == nil, "\(text)")
        }
        #expect(SVGFile.parseColor("rgb(16, 0, 0)") == SVGFile.Color(red: 16 / 255, green: 0, blue: 0, alpha: 1))
    }

    @Test(
        "16 進の数は、同じ口に abc を置いたときと同じく読めない値として名乗る (#2513)",
        arguments: ["0x10", "0x1p-1", "0X2", "abc"])
    func hexadecimalValuesAreUnreadable(_ bad: String) throws {
        let drawing = try document(
            """
            <rect width="\(bad)" height="10"/>
            <rect width="10" height="10" stroke="red" stroke-width="\(bad)"/>
            <rect width="10" height="10" opacity="\(bad)"/>
            <rect width="10" height="10" fill-opacity="\(bad)%"/>
            <rect width="10" height="10" fill="rgb(\(bad), 0, 0)"/>
            <rect width="\(bad)mm" height="10"/>
            <rect width="10" height="10" stroke="red" stroke-opacity="\(bad)"/>
            <rect x="\(bad)" width="10" height="10"/>
            <rect y="\(bad)" width="10" height="10"/>
            <circle cx="\(bad)" r="5"/>
            <circle r="\(bad)"/>
            <ellipse rx="\(bad)" ry="5"/>
            <ellipse rx="5" ry="\(bad)"/>
            <line x1="\(bad)" x2="5" stroke="red"/>
            <line y2="\(bad)" x2="5" stroke="red"/>
            """)
        #expect(
            drawing.skipped.map(\.what) == [
                "<rect width=\"\(bad)\">", "stroke-width \"\(bad)\"", "opacity \"\(bad)\"",
                "fill-opacity \"\(bad)%\"", "fill \"rgb(\(bad), 0, 0)\"", "<rect width=\"\(bad)mm\">",
                "stroke-opacity \"\(bad)\"", "<rect x=\"\(bad)\">", "<rect y=\"\(bad)\">",
                "<circle cx=\"\(bad)\">", "<circle r=\"\(bad)\">", "<ellipse rx=\"\(bad)\">",
                "<ellipse ry=\"\(bad)\">", "<line x1=\"\(bad)\">", "<line y2=\"\(bad)\">",
            ], "\(bad)")
        // 寸法・位置の読めない図形は描かず、読めない宣言は捨てて既定 (線の太さ 1・不透明・黒) のまま
        #expect(drawing.items.count == 5)
        #expect(drawing.items.first?.strokeWidth == 1)
        #expect(drawing.items.dropFirst().prefix(3).map(\.fill) == [.black, .black, .black])
        #expect(drawing.items.last?.stroke == SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1))
    }

    @Test("10 進で書いた長さ・不透明度・rgb() は変わらず読む (#2513 の陰性対照)")
    func decimalValuesStillRead() throws {
        let drawing = try document(
            """
            <rect width="10" height="10" stroke="red" stroke-width="2" opacity=".5"/>
            <rect width="1e1" height="10" fill="rgb(16, 0, 0)" fill-opacity="50%"/>
            """)
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items.map(\.strokeWidth) == [2, 1])
        #expect(drawing.items[0].fill == SVGFile.Color(red: 0, green: 0, blue: 0, alpha: 0.5))
        #expect(drawing.items[1].outline == .rect(x: 0, y: 0, width: 10, height: 10))
        #expect(drawing.items[1].fill == SVGFile.Color(red: 16 / 255, green: 0, blue: 0, alpha: 0.5))
    }

    @Test("transform の名前と括弧のあいだの改行は空白として落とす (#2513)")
    func newlineBetweenTransformNameAndParenthesis() throws {
        for text in ["translate\n(10)", "translate\r\n(10)", "translate \t(10)", "\ntranslate\n(10)\n"] {
            let read = try #require(SVGFile.parseTransform(text), "\(text.debugDescription)")
            #expect(read == .translate(10, 0), "\(text.debugDescription)")
        }
        // 属性に文字参照で書いた改行も、同じ変換になる
        let drawing = try document(#"<rect width="1" height="1" transform="translate&#10;(10)"/>"#)
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items.first?.transform == .translate(10, 0))
    }

    /// `rgb()` の引数の区切りの空白には改行も数える (CSS の空白)。`<style>` の値は改行を残して
    /// 渡るので、`fill: rgb(255,` で折り返した規則が読めないと名乗られていた (#2513 の反証)。
    @Test("rgb() の引数のあいだの改行は空白として区切る (#2513)")
    func newlinesSeparateRgbArguments() throws {
        let red = SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1)
        for text in ["rgb(255,\n 0, 0)", "rgb(255\r\n0\n0)", "rgba(255, 0,\n0 /\n100%)"] {
            #expect(SVGFile.parseColor(text) == red, "\(text.debugDescription)")
        }
        let drawing = try document(
            """
            <style>.a { fill: rgb(255,
              0, 0) }</style>
            <rect class="a" width="1" height="1"/>
            <rect width="1" height="1" fill="rgb(255,&#10;0,&#13;&#10;0)"/>
            """)
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items.map(\.fill) == [red, red])
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

    /// 根の `<svg>` に幅か高さの片方と `viewBox` だけを書くと、書いていない側は `viewBox` の
    /// 縦横比から決まる (CSS Images 3 の既定の大きさの決め方。ブラウザの `<img>`・resvg・librsvg
    /// の大きさ) ([#2333])。
    ///
    /// [#2333]: https://github.com/mokume-metal/mokume/issues/2333
    @Test(
        "根の幅か高さの片方だけなら、もう片方は viewBox の縦横比から決まる (#2333)",
        arguments: [
            // (根の属性, viewBox の右下の角, 写った先)
            (#"width="50" viewBox="0 0 10 20""#, SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            (#"height="50" viewBox="0 0 20 10""#, SIMD2(20, 10), SIMD2(100, 50)),
            (#"width="50" viewBox="0 0 10 20" preserveAspectRatio="none""#, SIMD2(10, 20), SIMD2(50, 100)),
            (#"height="50" viewBox="0 0 20 10" preserveAspectRatio="xMidYMid slice""#, SIMD2(20, 10), SIMD2(100, 50)),
            // 書いた側を割合で書いても、割合を読んだ後の大きさから導く。根の割合を viewBox に
            // 対して読むのは mokume の決まりで、ブラウザで開いたときの大きさと同じとは限らない
            (#"width="500%" viewBox="0 0 10 20""#, SIMD2(10, 20), SIMD2(50, 100)),
            // SVG 2 の auto と読めない値は、書いていないのと同じ
            (#"width="50" height="auto" viewBox="0 0 10 20""#, SIMD2(10, 20), SIMD2(50, 100)),
            (#"width="auto" height="100" viewBox="0 0 10 20""#, SIMD2(10, 20), SIMD2(50, 100)),
            (#"width="50" height="abc" viewBox="0 0 10 20""#, SIMD2(10, 20), SIMD2(50, 100)),
        ])
    func oneRootSideFollowsTheViewBoxAspect(_ sample: (String, SIMD2<Float>, SIMD2<Float>)) throws {
        let drawing = try document(
            #"<rect width="1" height="1"/>"#, root: "<svg xmlns=\"http://www.w3.org/2000/svg\" \(sample.0)>")
        let transform = drawing.items[0].transform
        #expect(isClose(transform.apply(.zero), .zero), "\(sample.0): \(transform.apply(.zero))")
        #expect(isClose(transform.apply(sample.1), sample.2), "\(sample.0): \(transform.apply(sample.1))")
    }

    @Test("viewBox の原点が 0 でない根でも、片方だけなら縦横比から導き、viewBox の左上が原点へ写る (#2333)")
    func oneRootSideWithAnOffsetViewBox() throws {
        let drawing = try document(
            #"<rect width="1" height="1"/>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" width="50" viewBox="10 10 10 20">"#)
        let transform = drawing.items[0].transform
        #expect(isClose(transform.apply(SIMD2(10, 10)), .zero), "\(transform.apply(SIMD2(10, 10)))")
        #expect(isClose(transform.apply(SIMD2(20, 30)), SIMD2(50, 100)), "\(transform.apply(SIMD2(20, 30)))")
    }

    /// 入れ子の `<svg>` の書いていない側は、根と違って親の座標の決まりの 100% (SVG 2 の `auto`)
    /// のままで、縦横比からは導かない。
    @Test("入れ子の <svg> に片方だけ書けば、もう片方は親の 100% のまま (#2333)")
    func nestedSvgWithOneSideKeepsTheParentSize() throws {
        let drawing = try document(
            #"<svg width="20" viewBox="0 0 10 20"><rect width="1" height="1"/></svg>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">"#)
        let transform = drawing.items[0].transform
        // 20×100 の枠に meet で 2 倍、縦の余り 100 − 40 の半分だけ下へ寄せる
        // (縦横比から導くと 20×40 の枠になり、ずれは出ない)
        #expect(isClose(transform.apply(.zero), SIMD2(0, 30)), "\(transform.apply(.zero))")
        #expect(isClose(transform.apply(SIMD2(10, 20)), SIMD2(20, 70)), "\(transform.apply(SIMD2(10, 20)))")
    }

    /// 導いた側が `Float` に収まらない (無限大・0 へ潰れる) ときは、導けないものとして直す前と
    /// 同じ `viewBox` の大きさに倒す。途中の積があふれても答えが収まるなら、その答えを使う。
    @Test(
        "根の片方から導いた大きさが Float に収まらなければ、viewBox の大きさに倒す (#2333)",
        arguments: [
            // (根の属性, viewBox の右下の角, 写った先)
            // 導くと高さ 1e39 (無限大)。viewBox の高さ 10 に倒し、縦は等倍・横は余りの半分だけ寄る
            (#"width="1e38" viewBox="0 0 1 10""#, SIMD2<Float>(1, 10), SIMD2<Float>(5e37, 10)),
            // 縦横比そのものが 1e40 (無限大)。viewBox の高さに倒し、縦は等倍・横は余りの半分 50 だけ寄る
            (#"width="100" viewBox="0 0 1e-20 1e20""#, SIMD2(1e-20, 1e20), SIMD2(50, 1e20)),
            // 縦横比が 1e-60 (0 へ潰れる)。viewBox の高さ 1e-30 に倒し、縦は等倍
            (#"width="100" viewBox="0 0 1e30 1e-30""#, SIMD2(1e30, 1e-30), SIMD2(100, 1e-30)),
            // 書いた幅 × viewBox の高さは 1e40 であふれるが、答えの 1e30 は収まる
            (#"width="1e30" viewBox="0 0 1e10 1e10""#, SIMD2(1e10, 1e10), SIMD2(1e30, 1e30)),
        ])
    func derivedRootSideThatDoesNotFitFallsBack(_ sample: (String, SIMD2<Float>, SIMD2<Float>)) throws {
        let drawing = try document(
            #"<rect width="1" height="1"/>"#, root: "<svg xmlns=\"http://www.w3.org/2000/svg\" \(sample.0)>")
        let item = try #require(drawing.items.first, "\(sample.0): 描かれなかった")
        let transform = item.transform
        let coefficients = [transform.a, transform.b, transform.c, transform.d, transform.e, transform.f]
        let isFinite = coefficients.allSatisfy { $0.isFinite }
        #expect(isFinite, "\(sample.0): \(transform)")
        let mapped = transform.apply(sample.1)
        // 桁が大きく離れるので、相対の誤差で比べる
        let matches = (0..<2).allSatisfy { abs(mapped[$0] - sample.2[$0]) <= 1e-3 * max(1, abs(sample.2[$0])) }
        #expect(matches, "\(sample.0): \(mapped)")
    }

    @Test(
        "根に幅と高さの両方か、どちらも書かなければ、写し方は変わらない (#2333 の陰性対照)",
        arguments: [
            // 両方を書けば、その枠へ写す
            (#"width="50" height="100" viewBox="0 0 10 20""#, SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            // 両方を書いて縦横比が違えば、縦横比を保って中央へ (片方から導かない)
            (#"width="50" height="50" viewBox="0 0 10 20""#, SIMD2(10, 20), SIMD2(37.5, 50)),
            // どちらも書かなければ等倍
            (#"viewBox="0 0 10 20""#, SIMD2(10, 20), SIMD2(10, 20)),
            (#"width="auto" height="auto" viewBox="0 0 10 20""#, SIMD2(10, 20), SIMD2(10, 20)),
            // viewBox が無ければ導けない。書いていない側は 100 で、変換は掛からない
            (#"width="50""#, SIMD2(10, 20), SIMD2(10, 20)),
        ])
    func rootWithBothOrNeitherSideIsUnchanged(_ sample: (String, SIMD2<Float>, SIMD2<Float>)) throws {
        let drawing = try document(
            #"<rect width="1" height="1"/>"#, root: "<svg xmlns=\"http://www.w3.org/2000/svg\" \(sample.0)>")
        let transform = drawing.items[0].transform
        #expect(isClose(transform.apply(sample.1), sample.2), "\(sample.0): \(transform.apply(sample.1))")
    }

    /// 長さを取る口に `auto` 以外の読めない値を書くと、書いていないのと同じに読んだうえで**名乗る**
    /// ([#2556])。`auto` と書いていない口は名乗らない。
    ///
    /// [#2556]: https://github.com/mokume-metal/mokume/issues/2556
    @Test(
        "根の幅・高さの読めない値は、書いていないものとして読んで skipped に載る (#2556)",
        arguments: [
            // (根の属性, 載るはずの名乗り, viewBox の右下の角の写った先)
            (#"width="50" height="abc" viewBox="0 0 10 20""#, #"<svg height="abc">"#, SIMD2<Float>(50, 100)),
            (#"width="abc" height="100" viewBox="0 0 10 20""#, #"<svg width="abc">"#, SIMD2<Float>(50, 100)),
            // 空・16 進・読めない単位
            (#"width="50" height="" viewBox="0 0 10 20""#, #"<svg height="">"#, SIMD2(50, 100)),
            (#"width="50" height="0x10" viewBox="0 0 10 20""#, #"<svg height="0x10">"#, SIMD2(50, 100)),
            (#"width="50" height="10em" viewBox="0 0 10 20""#, #"<svg height="10em">"#, SIMD2(50, 100)),
            // 両方が読めなければ、どちらも書いていないのと同じ (等倍)
            (#"width="abc" height="abc" viewBox="0 0 10 20""#, #"<svg width="abc">"#, SIMD2(10, 20)),
        ])
    func unreadableRootSizeIsNamed(_ sample: (String, String, SIMD2<Float>)) throws {
        let drawing = try document(
            #"<rect width="1" height="1"/>"#, root: "<svg xmlns=\"http://www.w3.org/2000/svg\" \(sample.0)>")
        #expect(drawing.skipped.first?.what == sample.1, "\(sample.0): \(drawing.skipped)")
        let transform = drawing.items[0].transform
        #expect(isClose(transform.apply(SIMD2(10, 20)), sample.2), "\(sample.0): \(transform.apply(SIMD2(10, 20)))")
    }

    @Test(
        "根の幅・高さが auto・空白つきの AUTO・書いていないときは、名乗らない (#2556 の陰性対照)",
        arguments: [
            #"width="50" height="auto" viewBox="0 0 10 20""#,
            #"width=" AUTO " height="100" viewBox="0 0 10 20""#,
            #"width="50" viewBox="0 0 10 20""#,
            #"viewBox="0 0 10 20""#,
        ])
    func autoAndAbsentRootSizeAreNotNamed(_ attributes: String) throws {
        let drawing = try document(
            #"<rect width="1" height="1"/>"#, root: "<svg xmlns=\"http://www.w3.org/2000/svg\" \(attributes)>")
        #expect(drawing.skipped.isEmpty, "\(attributes): \(drawing.skipped)")
    }

    @Test("入れ子の <svg> の x・y・width・height の読めない値も名乗る。auto は width・height だけ許す (#2556)")
    func unreadableNestedSvgLengthsAreNamed() throws {
        let drawing = try document(
            #"<svg x="abc" y="0x1" width="xyz" height="auto"><rect width="1" height="1"/></svg>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">"#)
        #expect(
            drawing.skipped.map(\.what) == [#"<svg x="abc">"#, #"<svg y="0x1">"#, #"<svg width="xyz">"#],
            "\(drawing.skipped)")
        // x・y は auto を取らない
        let autoPosition = try document(
            #"<svg x="auto"><rect width="1" height="1"/></svg>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">"#)
        #expect(autoPosition.skipped.map(\.what) == [#"<svg x="auto">"#])
        // 読めた値・書いていない値は名乗らない
        let readable = try document(
            #"<svg x="5" y="10px" width="auto"><rect width="1" height="1"/></svg>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">"#)
        #expect(readable.skipped.isEmpty, "\(readable.skipped)")
    }

    @Test("rect の rx・ry の読めない値は名乗り、書いていないものとして読む。auto・書いていない・負の値は名乗らない (#2556)")
    func unreadableCornerRadiusIsNamed() throws {
        let bad = try document(#"<rect width="10" height="10" rx="abc"/>"#)
        #expect(bad.skipped.map(\.what) == [#"<rect rx="abc">"#], "\(bad.skipped)")
        // 角は丸めない (rx を書いていないのと同じ)
        #expect(bad.items[0].outline == .rect(x: 0, y: 0, width: 10, height: 10))
        // ry だけ読めなければ、読めた rx がもう片方にも使われる
        let half = try document(#"<rect width="10" height="10" rx="2" ry="0x3"/>"#)
        #expect(half.skipped.map(\.what) == [#"<rect ry="0x3">"#], "\(half.skipped)")
        guard case .path = half.items[0].outline else {
            Issue.record("角が丸まっていない: \(half.items[0].outline)")
            return
        }
        for radii in [#"rx="auto""#, #"rx="auto" ry=" Auto ""#, "", #"rx="-3""#, #"ry="2""#] {
            let clean = try document(#"<rect width="10" height="10" \#(radii)/>"#)
            #expect(clean.skipped.isEmpty, "\(radii): \(clean.skipped)")
        }
    }

    /// SVG 2 では `width` / `height` は CSS の性質でもあるので、根の大きさを `style` 属性や `<style>` で
    /// 書いた SVG は属性と同じに効く。重なれば CSS が属性に勝つ ([#2557])。
    ///
    /// [#2557]: https://github.com/mokume-metal/mokume/issues/2557
    @Test(
        "根の幅・高さを CSS で書いても、属性と同じに効き、CSS が属性に勝つ (#2557)",
        arguments: [
            // (根の属性, <style> の中身, viewBox の右下の角, 写った先)
            (#"viewBox="0 0 10 20" style="width:50px""#, "", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            (#"viewBox="0 0 20 10" style="height:50px""#, "", SIMD2<Float>(20, 10), SIMD2<Float>(100, 50)),
            (#"viewBox="0 0 10 20" style="width: 50px; height: 100px""#, "", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            (#"viewBox="0 0 10 20""#, "svg { width: 50px }", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            (#"viewBox="0 0 10 20""#, "* { width: 50px }", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            (#"viewBox="0 0 10 20" class="logo""#, ".logo { width: 50px; }", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            // 割合は viewBox に対して読む (根の決まり)
            (#"viewBox="0 0 10 20" style="width:500%""#, "", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            // CSS が属性に勝つ
            (#"viewBox="0 0 10 20" width="10" style="width:50px""#, "", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            (#"viewBox="0 0 10 20" width="10""#, "svg { width: 50px }", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            // !important の規則は、重なる style 属性にも勝つ
            (#"viewBox="0 0 10 20" style="width:10px""#, "svg { width: 50px !important }", SIMD2<Float>(10, 20), SIMD2<Float>(50, 100)),
            // 属性で書いた片方と、CSS で書いたもう片方 (両方が揃えば縦横比は導かない)
            (#"viewBox="0 0 10 20" width="50" style="height:50px""#, "", SIMD2<Float>(10, 20), SIMD2<Float>(37.5, 50)),
        ])
    func rootSizeWrittenInCSSIsRead(_ sample: (String, String, SIMD2<Float>, SIMD2<Float>)) throws {
        let drawing = try document(
            "<style>\(sample.1)</style><rect width=\"1\" height=\"1\"/>",
            root: "<svg xmlns=\"http://www.w3.org/2000/svg\" \(sample.0)>")
        #expect(drawing.skipped.isEmpty, "\(sample.0) \(sample.1): \(drawing.skipped)")
        let transform = drawing.items[0].transform
        #expect(
            isClose(transform.apply(sample.2), sample.3), "\(sample.0) \(sample.1): \(transform.apply(sample.2))")
    }

    @Test("根の幅・高さを CSS で読めない値に書けば名乗り、auto に書けば属性の値も消える (#2557)")
    func unreadableOrAutoRootSizeInCSS() throws {
        let bad = try document(
            #"<rect width="1" height="1"/>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20" style="width:abc">"#)
        #expect(bad.skipped.map(\.what) == [#"<svg width="abc">"#], "\(bad.skipped)")
        #expect(isClose(bad.items[0].transform.apply(SIMD2(10, 20)), SIMD2(10, 20)))
        // calc() など、読まない書き方も名乗る
        let calc = try document(
            "<style>svg { height: calc(50px + 1px) }</style><rect width=\"1\" height=\"1\"/>",
            root: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20">"#)
        #expect(calc.skipped.map(\.what) == [#"<svg height="calc(50px + 1px)">"#], "\(calc.skipped)")
        // CSS の auto は属性の width="50" に勝つ: どちらも書いていないのと同じ (等倍)
        let auto = try document(
            #"<rect width="1" height="1"/>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20" width="50" style="width:auto">"#)
        #expect(auto.skipped.isEmpty, "\(auto.skipped)")
        #expect(isClose(auto.items[0].transform.apply(SIMD2(10, 20)), SIMD2(10, 20)))
    }

    /// CSS では読めない (無効な) 宣言は捨てられ、順位の下の宣言が残る。勝った宣言が読めない値なら、読める
    /// 下の宣言 (属性など) を採り、読めなかった宣言を名乗る。
    @Test(
        "CSS で書いた読めない値は、読める属性に勝たず、名乗る",
        arguments: [
            // (根の属性, <style> の中身, 名乗りの並び)。viewBox は 512×256 で、属性の 24 (縦横比から 24×12) が残れば右下が (24, 12)
            (#"width="24" style="width:1em""#, "", [#"<svg width="1em">"#]),
            (#"width="24" style="width:1rem""#, "", [#"<svg width="1rem">"#]),
            (#"width="24" style="width:100vw""#, "", [#"<svg width="100vw">"#]),
            (#"width="24" style="width:calc(100% - 4px)""#, "", [#"<svg width="calc(100% - 4px)">"#]),
            (#"height="12" style="height:fit-content""#, "", [#"<svg height="fit-content">"#]),
            // <style> の規則でも、!important でも同じ
            (#"width="24""#, "svg { width: 1em }", [#"<svg width="1em">"#]),
            (#"width="24""#, "svg { width: 1em !important }", [#"<svg width="1em">"#]),
            // 読めない宣言が 2 つ重なれば、順位の高いほうから両方を名乗る
            (#"width="24" style="width:2rem""#, "svg { width: 1em }", [#"<svg width="2rem">"#, #"<svg width="1em">"#]),
            // 読める宣言のあいだに読めない宣言があれば、読めない宣言だけを飛ばす
            (#"width="24" style="width:1em""#, "svg { width: 24px }", [#"<svg width="1em">"#]),
        ])
    func unreadableCSSSizeDoesNotBeatReadableOne(_ sample: (String, String, [String])) throws {
        let drawing = try document(
            "<style>\(sample.1)</style><rect width=\"1\" height=\"1\"/>",
            root: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 512 256\" \(sample.0)>")
        #expect(drawing.skipped.map(\.what) == sample.2, "\(sample.0) \(sample.1): \(drawing.skipped)")
        let mapped = drawing.items[0].transform.apply(SIMD2(512, 256))
        #expect(isClose(mapped, SIMD2(24, 12)), "\(sample.0) \(sample.1): \(mapped)")
    }

    @Test("CSS の読めない値だけが重なれば、全部を名乗り、書いていないのと同じ (viewBox の大きさ) に読む")
    func onlyUnreadableSizesFallBackToTheViewBox() throws {
        let drawing = try document(
            #"<style>svg { width: 1em }</style><rect width="1" height="1"/>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="abc">"#)
        #expect(drawing.skipped.map(\.what) == [#"<svg width="1em">"#, #"<svg width="abc">"#], "\(drawing.skipped)")
        #expect(isClose(drawing.items[0].transform.apply(SIMD2(512, 512)), SIMD2(512, 512)))
    }

    /// `initial` と `unset` は、`width` / `height` では初めの値 `auto` と同じ。読める宣言として名乗らず、
    /// 下の属性を消して書いていないのと同じにする (CSS の `auto` と同じ)。
    @Test("CSS の initial と unset は auto と同じ (名乗らず、属性を消す)", arguments: ["initial", "unset", " AUTO "])
    func initialAndUnsetAreAuto(_ keyword: String) throws {
        let drawing = try document(
            #"<rect width="1" height="1"/>"#,
            root:
                #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="24" height="24" style="width:\#(keyword)">"#
        )
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        // 幅は auto (書いていない) で、高さは 24 だけが残る: 縦横比 1:1 から幅も 24
        #expect(isClose(drawing.items[0].transform.apply(SIMD2(512, 512)), SIMD2(24, 24)))
    }

    /// `ellipse` の `rx` / `ry` の `auto` は、`rect` と同じに名乗らず、書いていないのと同じに読む (SVG 2:
    /// 片方が `auto` なら、もう片方を使う。両方なら 0 で描かない)。
    @Test("ellipse の rx・ry の auto は名乗らず、片方が auto ならもう片方を使う")
    func ellipseAutoRadius() throws {
        let one = try document(#"<ellipse cx="10" cy="10" rx="auto" ry="5"/>"#)
        #expect(one.skipped.isEmpty, "\(one.skipped)")
        #expect(one.items.first?.outline == .ellipse(centerX: 10, centerY: 10, radiusX: 5, radiusY: 5))
        let other = try document(#"<ellipse cx="10" cy="10" rx="7" ry=" Auto "/>"#)
        #expect(other.skipped.isEmpty, "\(other.skipped)")
        #expect(other.items.first?.outline == .ellipse(centerX: 10, centerY: 10, radiusX: 7, radiusY: 7))
        let both = try document(#"<ellipse cx="10" cy="10" rx="auto" ry="auto"/>"#)
        #expect(both.skipped.isEmpty, "\(both.skipped)")
        #expect(both.items.isEmpty)
        // 読めない値は、これまでどおり名乗って描かない
        let bad = try document(#"<ellipse cx="10" cy="10" rx="abc" ry="5"/>"#)
        #expect(bad.skipped.map(\.what) == [#"<ellipse rx="abc">"#], "\(bad.skipped)")
        #expect(bad.items.isEmpty)
    }

    @Test("rect の width・height の auto は、rx と同じに名乗らず、0 として描かない。読めない値は名乗る")
    func rectAutoSize() throws {
        let auto = try document(#"<rect width="auto" height="10"/><rect width="10" height=" auto "/>"#)
        #expect(auto.skipped.isEmpty, "\(auto.skipped)")
        #expect(auto.items.isEmpty)
        let bad = try document(#"<rect width="abc" height="10"/>"#)
        #expect(bad.skipped.map(\.what) == [#"<rect width="abc">"#], "\(bad.skipped)")
        #expect(bad.items.isEmpty)
    }

    @Test("CSS の width は svg 以外の要素の大きさを変えない (#2557 の陰性対照)")
    func cssWidthDoesNotTouchOtherElements() throws {
        let drawing = try document(
            #"<style>rect { width: 50px }</style><rect width="10" height="10"/>"#,
            root: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">"#)
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items[0].outline == .rect(x: 0, y: 0, width: 10, height: 10))
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

    // MARK: 優先の順 — `!important` と詳細度 ([#2348], [#2334])
    //
    // 順位は 属性 < 規則 (詳細度の順: `*` < 要素名 < クラス・同じなら後に書いたほう) < `style` 属性。
    // `!important` の宣言はそれらすべてより上で、その中でも同じ順に並ぶ。期待値は CSS の順から手で導く。
    //
    // [#2348]: https://github.com/mokume-metal/mokume/issues/2348
    // [#2334]: https://github.com/mokume-metal/mokume/issues/2334

    /// `<style>` と 1 つの `rect` を読んで、その `rect` の塗り。
    private func fill(sheet: String, rect attributes: String = "") throws -> SVGFile.Color? {
        let drawing = try document(
            "<style>\(sheet)</style>\n<rect width=\"1\" height=\"1\" \(attributes)/>")
        #expect(drawing.items.count == 1, "\(sheet) / \(attributes)")
        return drawing.items.first?.fill
    }

    @Test(
        "<style> の !important は、style 属性・属性・ふつうの規則に勝つ",
        arguments: [
            // 要素名・クラス・* のどの規則でも、style 属性のふつうの宣言に勝つ ([#2348] の 1)
            ("rect { fill: red !important }", #"style="fill: blue""#),
            (".a { fill: red !important }", #"class="a" style="fill: blue""#),
            ("* { fill: red !important }", #"style="fill: blue""#),
            // 属性にも勝つ
            ("rect { fill: red !important }", #"fill="blue""#),
            // ふつうのクラスの規則にも勝つ ([#2348] の 4)
            (".a { fill: #00ff00 } rect { fill: red !important }", #"class="a" fill="white""#),
            // 後に書いたふつうの規則にも勝つ
            ("rect { fill: red !important } rect { fill: blue }", ""),
            // `!` と important の間の空白・大文字小文字・詰めた書き方・後ろの空白は同じに読む ([#2348] の 5)
            ("rect { fill: red ! important }", #"style="fill: blue""#),
            ("rect { fill: red !IMPORTANT }", #"style="fill: blue""#),
            ("rect { fill: red!important }", #"style="fill: blue""#),
            ("rect { fill: red !important ; }", #"style="fill: blue""#),
            ("rect { fill: red !important }", #"style="fill: blue; fill: lime""#),
        ])
    func importantRulesBeatEverythingNormal(_ sample: (sheet: String, rect: String)) throws {
        let painted = try fill(sheet: sample.sheet, rect: sample.rect)
        #expect(painted == Ink.red, "\(sample.sheet) / \(sample.rect)")
    }

    @Test(
        "style 属性の !important は <style> の !important に勝つ",
        arguments: [
            ("rect { fill: red !important }", #"style="fill: blue !important""#),
            ("rect { fill: red !important }", #"style="fill: blue ! IMPORTANT""#),
            (".a { fill: red !important }", #"class="a" style="fill: blue !important""#),
            // 同じ宣言の並びの中でも、important が上
            ("", #"style="fill: blue !important; fill: red""#),
        ])
    func importantStyleAttributeBeatsImportantRules(_ sample: (sheet: String, rect: String)) throws {
        let painted = try fill(sheet: sample.sheet, rect: sample.rect)
        #expect(painted == Ink.blue, "\(sample.sheet) / \(sample.rect)")
    }

    @Test(
        "<style> の !important どうしは詳細度の順で、同じなら後に書いたほうが勝つ",
        arguments: [
            // クラスの規則が要素名の規則に勝つ。要素名の規則を後に書いても ([#2348] の 3)
            (".a { fill: #00ff00 !important } rect { fill: red !important }", #"class="a""#, Ink.green),
            ("rect { fill: red !important } .a { fill: #00ff00 !important }", #"class="a""#, Ink.green),
            // 要素名の規則が * に勝つ。* を後に書いても
            ("rect { fill: red !important } * { fill: blue !important }", "", Ink.red),
            ("* { fill: blue !important } rect { fill: red !important }", "", Ink.red),
            // クラスの規則が * に勝つ
            (".a { fill: red !important } * { fill: blue !important }", #"class="a""#, Ink.red),
            // 詳細度が同じなら後に書いたほう
            ("rect { fill: blue !important } rect { fill: red !important }", "", Ink.red),
            ("rect { fill: red !important } rect { fill: blue !important }", "", Ink.blue),
            // 別の <style> に分けても、書いた順は文書の順
            ("rect { fill: blue !important }</style><style>rect { fill: red !important }", "", Ink.red),
        ])
    func importantRulesFollowSpecificity(_ sample: (sheet: String, rect: String, expected: SVGFile.Color)) throws {
        let painted = try fill(sheet: sample.sheet, rect: sample.rect)
        #expect(painted == sample.expected, "\(sample.sheet) / \(sample.rect)")
    }

    @Test(
        "important の無い宣言でも、詳細度が同じなら後に書いたほうが勝つ",
        arguments: [
            ("rect { fill: blue } rect { fill: red }", "", Ink.red),
            ("rect { fill: red } rect { fill: blue }", "", Ink.blue),
            ("* { fill: blue } * { fill: red }", "", Ink.red),
            (".a { fill: blue } .b { fill: red }", #"class="a b""#, Ink.red),
            (".b { fill: red } .a { fill: blue }", #"class="a b""#, Ink.blue),
            // 別の <style> に分けても、文書の順
            ("rect { fill: blue }</style><style>rect { fill: red }", "", Ink.red),
            // 同じ `style` 属性の中でも
            ("", #"style="fill: blue; fill: red""#, Ink.red),
        ])
    func laterWinsAtEqualSpecificity(_ sample: (sheet: String, rect: String, expected: SVGFile.Color)) throws {
        let painted = try fill(sheet: sample.sheet, rect: sample.rect)
        #expect(painted == sample.expected, "\(sample.sheet) / \(sample.rect)")
    }

    @Test("!important が掛かるのは、それを付けた宣言だけ")
    func importantOnlyCoversItsOwnDeclaration() throws {
        let drawing = try document(
            """
            <style>rect { fill: red !important; stroke: #0000ff; stroke-width: 3 }</style>
            <rect width="1" height="1" style="fill: blue; stroke: #00ff00"/>
            """)
        #expect(drawing.items.count == 1)
        #expect(drawing.items[0].fill == Ink.red, "important の付いた fill は style 属性に勝つ")
        #expect(drawing.items[0].stroke == Ink.green, "important の無い stroke は style 属性に負ける")
        #expect(drawing.items[0].strokeWidth == 3)
        // 同じ性質を同じ規則の中で 2 度書いたときも、important が先に書いたか後に書いたかに依らず勝つ
        #expect(try fill(sheet: "rect { fill: red !important; fill: blue }") == Ink.red)
        #expect(try fill(sheet: "rect { fill: blue; fill: red !important }") == Ink.red)
        // 受け継ぐ値は、子自身のどの宣言よりも弱い (important は子へ移らない)
        let inherited = try document(
            """
            <style>g { fill: red !important }</style>
            <g><rect width="1" height="1"/><rect width="1" height="1" fill="blue"/></g>
            """)
        #expect(inherited.items.map(\.fill) == [Ink.red, Ink.blue])
    }

    @Test(
        "宣言の末尾の !important は値から外して持ち、綴りの揺れは同じに読む",
        arguments: [
            ("fill: red !important", "red", true),
            ("fill:red!important", "red", true),
            ("fill: red ! important", "red", true),
            ("fill: red !IMPORTANT ", "red", true),
            ("FILL: url(#a) red !Important", "url(#a) red", true),
            ("fill: red", "red", false),
            // 末尾でない `!important` は CSS の文法の外。印とは読まず、値のまま (読めない値として名乗られる)
            ("fill: red !important blue", "red !important blue", false),
            ("fill: red !imp", "red !imp", false),
        ])
    func importantMarkerIsSplitFromTheValue(_ sample: (text: String, value: String, isImportant: Bool)) {
        let declarations = SVGFile.parseDeclarations(sample.text)
        #expect(declarations.count == 1, "\(sample.text)")
        #expect(declarations.first?.name == "fill", "\(sample.text)")
        #expect(declarations.first?.value == sample.value, "\(sample.text)")
        #expect(declarations.first?.isImportant == sample.isImportant, "\(sample.text)")
    }

    @Test("規則は、* と要素名とクラスのセレクタを分けて持ち、宣言ごとに important を持つ")
    func styleSheetKeepsSelectorKindsAndImportance() {
        let sheet = SVGFile.parseStyleSheet(
            "* { fill: blue } rect { fill: red !important; stroke: #00f } .a, circle { opacity: 0.5 }")
        #expect(sheet.unread.isEmpty, "\(sheet.unread)")
        #expect(
            sheet.rules.map(\.selector) == [.universal, .element("rect"), .className("a"), .element("circle")])
        #expect(sheet.rules[0].selector.specificity < sheet.rules[1].selector.specificity)
        #expect(sheet.rules[1].selector.specificity < sheet.rules[2].selector.specificity)
        #expect(
            sheet.rules[1].declarations == [
                SVGFile.Declaration(name: "fill", value: "red", isImportant: true),
                SVGFile.Declaration(name: "stroke", value: "#00f", isImportant: false),
            ])
        #expect(sheet.rules[0].selector.matches(name: "rect", classes: []))
        #expect(!sheet.rules[1].selector.matches(name: "circle", classes: ["rect"]))
        #expect(sheet.rules[2].selector.matches(name: "g", classes: ["a", "b"]))
    }

    @Test("!important を付けた値が読めなければ、!important を除いた値を名乗る")
    func unreadableImportantValueIsReportedWithoutTheMarker() throws {
        let drawing = try document(
            "<style>rect { fill: nonsense !important }</style>\n<rect width=\"1\" height=\"1\" fill=\"#0000ff\"/>")
        #expect(drawing.skipped.map(\.what) == ["fill \"nonsense\""])
        #expect(drawing.items[0].fill == Ink.blue, "読めない宣言は無かったことになり、属性の青が残る")
    }

    @Test(
        "* の規則は要素名の規則より弱く、書いた順に依らない",
        arguments: [
            ("rect { fill: red } * { fill: blue }", Ink.red),
            ("* { fill: blue } rect { fill: red }", Ink.red),
            // 別の <style> に分けても
            ("rect { fill: red }</style><style>* { fill: blue }", Ink.red),
            // クラスの規則は * にも要素名の規則にも勝つ
            (".a { fill: #00ff00 } * { fill: blue }", Ink.green),
            (".a { fill: #00ff00 } rect { fill: red } * { fill: blue }", Ink.green),
        ])
    func universalRuleIsWeakerThanTypeAndClassRules(_ sample: (sheet: String, expected: SVGFile.Color)) throws {
        let painted = try fill(sheet: sample.sheet, rect: #"class="a""#)
        #expect(painted == sample.expected, "\(sample.sheet)")
        // クラスを持たない要素では、要素名の規則が * に勝つだけ
        let plain = try fill(sheet: sample.sheet)
        #expect(plain == (sample.sheet.contains("rect") ? Ink.red : Ink.blue), "\(sample.sheet)")
    }

    @Test("* の規則は属性より強く、style 属性より弱い")
    func universalRuleSitsBetweenAttributesAndStyleAttribute() throws {
        #expect(try fill(sheet: "* { fill: blue }", rect: #"fill="red""#) == Ink.blue)
        #expect(try fill(sheet: "* { fill: blue }", rect: #"style="fill: red""#) == Ink.red)
        // 同じ * の規則でも、属性の無い要素には何も足さず、ほかの性質は触らない
        let drawing = try document(
            "<style>* { stroke: #00ff00 }</style>\n<rect width=\"1\" height=\"1\" fill=\"red\"/>")
        #expect(drawing.items[0].fill == Ink.red)
        #expect(drawing.items[0].stroke == Ink.green)
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

    /// `visibility` の読めない値 (`abc`・空) は、`hidden` と同じに隠さず、無かったものとして親の値を受け継いで
    /// 描き、`fill-rule "abc"` などと同じ形で名乗る ([#2626])。
    ///
    /// [#2626]: https://github.com/mokume-metal/mokume/issues/2626
    @Test(
        "visibility の読めない値は隠さず、親の値を受け継いで描き、skipped に載る (#2626)",
        arguments: [
            // (SVG の本体, 載るはずの名乗り, 描かれる矩形の数)
            (#"<rect width="10" height="10" visibility="abc"/>"#, [#"visibility "abc""#], 1),
            (#"<rect width="10" height="10" visibility=""/>"#, [#"visibility """#], 1),
            // 空白つきは落とした文字で名乗る
            (#"<rect width="10" height="10" visibility=" abc "/>"#, [#"visibility "abc""#], 1),
            // CSS の宣言 (style 属性・<style>) でも同じ
            (#"<rect width="10" height="10" style="visibility:abc"/>"#, [#"visibility "abc""#], 1),
            (#"<style>rect { visibility: abc }</style><rect width="10" height="10"/>"#, [#"visibility "abc""#], 1),
            // 親が visible なら描き、hidden なら受け継いで隠れたまま (読めない値は hidden に変えず、visible にも戻さない)
            (#"<g visibility="visible"><rect width="10" height="10" visibility="abc"/></g>"#, [#"visibility "abc""#], 1),
            (#"<g visibility="hidden"><rect width="10" height="10" visibility="abc"/></g>"#, [#"visibility "abc""#], 0),
            // 祖先の読めない値は、祖先の resolve で名乗られる (中身が空でも載る。祖先 1 つで 1 件)。子は受け継ぐだけで名乗らない
            (#"<g visibility="abc"><rect width="10" height="10"/><rect width="10" height="10"/></g>"#, [#"visibility "abc""#], 2),
        ])
    func unreadableVisibilityIsNamedAndInherited(_ sample: (String, [String], Int)) throws {
        let drawing = try document(sample.0)
        #expect(drawing.skipped.map(\.what) == sample.1, "\(sample.0): \(drawing.skipped)")
        #expect(drawing.items.count == sample.2, "\(sample.0): \(drawing.items)")
    }

    @Test(
        "visibility の visible・hidden・collapse は今までどおりで、名乗らない (#2626 の陰性対照)",
        arguments: [
            (#"<rect width="10" height="10" visibility="visible"/>"#, 1),
            (#"<rect width="10" height="10" visibility=" VISIBLE "/>"#, 1),
            (#"<rect width="10" height="10" visibility="hidden"/>"#, 0),
            (#"<rect width="10" height="10" visibility="collapse"/>"#, 0),
            (#"<rect width="10" height="10" style="visibility:hidden"/>"#, 0),
            (#"<rect width="10" height="10" style="visibility:collapse"/>"#, 0),
            (#"<style>rect { visibility: hidden }</style><rect width="10" height="10"/>"#, 0),
            // inherit は親の値のまま (hidden の親なら隠れる)
            (#"<g visibility="hidden"><rect width="10" height="10" visibility="inherit"/></g>"#, 0),
            (#"<rect width="10" height="10" visibility="inherit"/>"#, 1),
            // 親が hidden でも、子が visible なら描く
            (#"<g visibility="hidden"><rect width="10" height="10" visibility="visible"/></g>"#, 1),
        ])
    func readableVisibilityIsUnchanged(_ sample: (String, Int)) throws {
        let drawing = try document(sample.0)
        #expect(drawing.skipped.isEmpty, "\(sample.0): \(drawing.skipped)")
        #expect(drawing.items.count == sample.1, "\(sample.0): \(drawing.items)")
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

    // MARK: - XML 宣言と行の終わり (#2332・#2331)

    /// 行の終わりの 3 通り。どれも 1 つの行の終わり (``TextFile/lines(of:)``)。
    private static let lineBreaks: [(name: String, text: String)] = [
        ("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r"),
    ]

    /// 宣言だけを替える。**ASCII でない文字を属性の値とコメントと字に持たせる** (ASCII だけなら、
    /// 宣言が何でも libxml2 は読めてしまう)。
    private nonisolated static let declarations: [(name: String, text: String)] = [
        ("宣言なし", ""),
        ("Shift_JIS", #"<?xml version="1.0" encoding="Shift_JIS"?>"#),
        ("一重引用符", "<?xml version='1.0' encoding='Shift_JIS'?>"),
        ("ISO-8859-1", #"<?xml version="1.0" encoding="ISO-8859-1"?>"#),
        ("UTF-16", #"<?xml version="1.0" encoding="UTF-16"?>"#),
        ("standalone が続く", #"<?xml version="1.0" encoding="Shift_JIS" standalone="yes"?>"#),
    ]

    @Test("宣言の encoding が何でも、UTF-8 として読んだ同じ Drawing になる", arguments: declarations)
    func declaredEncodingIsNotRead(_ name: String, _ declaration: String) throws {
        let body = """
            <svg xmlns="http://www.w3.org/2000/svg" data-name="値é">
            <!-- 星 -->
            <text x="0" y="0">星</text>
            <rect id="é" width="4" height="4" fill="#ff0000"/>
            </svg>
            """
        let expected = try SVGFile.parse(body, path: "plain.svg")
        let drawing = try SVGFile.parse(declaration + "\n" + body, path: "declared.svg")
        #expect(drawing.items.count == 1, "\(name)")
        #expect(drawing.items.first?.fill == SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1), "\(name)")
        // 宣言が使う行の数だけ下がる。字 (3 行目) を捨てたと名乗る行も、その分だけ下がる
        let used = declaration.filter { $0 == "\n" }.count + 1
        #expect(drawing.items == expected.items, "\(name)")
        #expect(
            drawing.skipped == [SVGFile.Skip(what: "<text>", count: 1, line: 3 + used)], "\(name)")
    }

    @Test("値が名前の形でない宣言の SVG は、書き換えず、これまでどおり malformed で投げる", arguments: ["", "1abc", "Shift JIS"])
    func declarationThatIsNotANameStaysMalformed(_ name: String) {
        do {
            _ = try SVGFile.parse(
                "<?xml version=\"1.0\" encoding=\"\(name)\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>",
                path: "x.svg")
            Issue.record("読めたことになっている: \"\(name)\"")
        } catch {
            guard case .malformed(_, let line, _) = error else {
                Issue.record("malformed でない: \(error)")
                return
            }
            #expect(line == 1, "\"\(name)\"")
        }
    }

    @Test("先頭に BOM が残った SVG も、宣言の encoding を読まない (loadShape と同じ道で読む)")
    func declaredEncodingIsNotReadAfterLeftoverBOM() throws {
        let body = """
            <svg xmlns="http://www.w3.org/2000/svg">
            <!-- 星 -->
            <text x="0" y="0">星</text>
            <rect id="é" width="4" height="4" fill="#ff0000"/>
            </svg>
            """
        let bom = Data([0xEF, 0xBB, 0xBF])
        let shiftJIS = #"<?xml version="1.0" encoding="Shift_JIS"?>"#
        // `loadShape` は `TextFile.read` (BOM を 1 つ落とす) の結果を `SVGFile.parse` に渡す。
        // BOM が 2 つのファイルでは 1 つが残り、libxml2 はそれを読み飛ばしてから宣言を読む
        for (name, count, declaration) in [
            ("BOM 1 つ・Shift_JIS", 1, shiftJIS), ("BOM 2 つ・Shift_JIS", 2, shiftJIS),
            ("BOM 1 つ・宣言なし", 1, ""), ("BOM 2 つ・宣言なし", 2, ""),
        ] {
            var bytes = Data()
            for _ in 0..<count { bytes.append(bom) }
            bytes.append(Data((declaration + body).utf8))
            let url = try written(bytes, as: "bom.svg")
            defer { try? FileManager.default.removeItem(at: url) }
            let drawing = try SVGFile.parse(try TextFile.read(url, path: url.path), path: url.path)
            #expect(drawing.items.count == 1, "\(name)")
            #expect(drawing.skipped == [SVGFile.Skip(what: "<text>", count: 1, line: 3)], "\(name)")
        }
    }

    /// 捨てるものの行が、改行のどれでも同じになる SVG。字 (3 行目)・グラデーションの塗り (4 行目)・
    /// 読めない CSS の規則 (5 行目)。
    private static let skippingLines = """
        <svg xmlns="http://www.w3.org/2000/svg">
        <defs><linearGradient id="g"/></defs>
        <text x="0" y="0">A</text>
        <rect width="4" height="4" fill="url(#g)"/>
        <style>g .deep { fill: red }</style>
        </svg>
        """

    @Test("CR・CRLF で改行した壊れていない SVG も、捨てたものの行が LF と同じになる")
    func skippedLinesDoNotDependOnTheBreak() throws {
        let expected = try SVGFile.parse(Self.skippingLines, path: "lf.svg")
        let lines = Dictionary(uniqueKeysWithValues: expected.skipped.map { ($0.what, $0.line) })
        #expect(lines == ["<text>": 3, "fill=\"url(…)\"": 4, "CSS rule \"g .deep\"": 5])
        for (kind, lineBreak) in Self.lineBreaks {
            let drawing = try SVGFile.parse(
                Self.skippingLines.replacingOccurrences(of: "\n", with: lineBreak), path: "\(kind).svg")
            #expect(drawing == expected, "\(kind)")
        }
    }

    @Test(
        "行の終わりが LF・CRLF・CR のどれでも、壊れた SVG と根が <svg> でない XML は同じ行を名乗る",
        arguments: [
            ("閉じない要素", "<svg>\n<rect width=\"1\" height=\"1\">\n</svg>\n", 3),
            ("閉じる名前の食い違い", "<svg>\n<g>\n<rect/>\n</rect>\n</svg>", 4),
            ("定義の無い実体", "<svg>\n<g/>\n<g x=\"&nope;\"/>\n</svg>", 3),
            ("根が svg でない", "<?xml version=\"1.0\"?>\n<html><body/></html>", 2),
            ("根が svg でない (3 行目)", "<!-- a -->\n\n<html/>", 3),
        ])
    func malformedSVGNamesTheSameLineWithAnyBreak(_ name: String, _ text: String, _ line: Int) {
        for (kind, lineBreak) in Self.lineBreaks {
            do {
                _ = try SVGFile.parse(text.replacingOccurrences(of: "\n", with: lineBreak), path: "x.svg")
                Issue.record("読めたことになっている: \(name) (\(kind))")
            } catch {
                guard case .malformed(_, let named, _) = error else {
                    Issue.record("malformed でない: \(error)")
                    continue
                }
                #expect(named == line, "\(name) (\(kind))")
            }
        }
    }

    @Test("CR だけで改行した SVG を loadShape が読めないとき、壊れた行は LF の SVG と同じ")
    func loadShapeNamesTheLineOfACarriageReturnFile() throws {
        let url = try written(
            Data("<svg>\r<rect width=\"1\" height=\"1\">\r</svg>\r".utf8), as: "broken-cr.svg")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try Probe().loadShape(url.path)
            Issue.record("壊れた XML を読めたことになっている")
        } catch {
            guard case .malformed(_, let line, _) = error else {
                Issue.record("malformed でない: \(error)")
                return
            }
            #expect(line == 3)
        }
    }

    @Test("属性と <style> (CDATA を含む) の値は、行の終わりによらず同じに読む")
    func valuesDoNotDependOnTheBreak() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg">
            <style><![CDATA[
            .a { fill: red;
            stroke: blue }
            ]]></style>
            <style>.b { fill: lime;
            stroke: black }</style>
            <rect class="a" width="4" height="4"/>
            <rect class="b" width="4" height="4"/>
            <rect width="4" height="4" style="fill:red;
            stroke:blue"/>
            <polyline points="0,0
            5,0
            5,5" fill="none" stroke="black"/>
            </svg>
            """
        let expected = try SVGFile.parse(svg, path: "lf.svg")
        // 規則が実際に効いている (どの書き方も、読めた値は同じ赤と青)
        let red = SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = SVGFile.Color(red: 0, green: 0, blue: 1, alpha: 1)
        #expect(expected.items.count == 4)
        #expect(expected.items[0].fill == red && expected.items[0].stroke == blue)
        #expect(expected.items[1].stroke == SVGFile.Color(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(expected.items[2].fill == red && expected.items[2].stroke == blue)
        // 改行だけで区切った点の並び (属性の値の改行は空白 1 つ。消えると点がつながる)
        guard case .path(let subpaths) = expected.items[3].outline else {
            Issue.record("polyline が線の集まりになっていない")
            return
        }
        #expect(points(subpaths[0]) == [SIMD2(0, 0), SIMD2(5, 0), SIMD2(5, 5)])
        #expect(expected.skipped.isEmpty, "\(expected.skipped)")
        for (kind, lineBreak) in Self.lineBreaks {
            let drawing = try SVGFile.parse(
                svg.replacingOccurrences(of: "\n", with: lineBreak), path: "\(kind).svg")
            #expect(drawing == expected, "\(kind)")
        }
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
