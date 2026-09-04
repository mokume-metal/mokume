// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 文字の検査。GPU を要する。
///
/// ## 何を物差しにするか
///
/// **幅は 1 文字ずつの送り幅の合計**という規約そのものを見る。保存した絵と比べるのでは
/// なく、規約から導ける性質 (部分の和が全体に一致する・描画の前進が計測と一致する) を
/// 突き合わせるので、書体が変わっても検査は生き続ける。
///
/// 位置の検査は**この環境の書体の寸法**を独立に引いて突き合わせる。同じ計算を 2 度
/// 通しても「両方同じだけずれている」ことは見つからないため。
@Suite(
    "文字",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 検査で使う書体。**版が変わりにくいものを選ぶ** — 環境の既定の書体は
    /// 更新で字形が動きうるので、位置の検査の土台には使わない。
    private let fontName = "Helvetica"

    private func makeCanvas(width: Int = 160, height: Int = 96) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        let canvas = try Canvas(target: target, gpu: gpu)
        canvas.textFont(fontName)
        canvas.textSize(32)
        return canvas
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 墨の乗っている画素の外接矩形。何も描かれていなければ `nil`。
    private func inkBounds(_ image: DisplayImage, width: Int, height: Int) -> (
        left: Int, top: Int, right: Int, bottom: Int
    )? {
        var left = Int.max
        var top = Int.max
        var right = Int.min
        var bottom = Int.min
        for y in 0..<height {
            for x in 0..<width where image[x, y].red > 8 {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
            }
        }
        guard left <= right else { return nil }
        return (left, top, right, bottom)
    }

    // MARK: - 幅の規約

    @Test("部分文字列の幅を足すと、全体の幅にそのまま一致する")
    func widthIsAdditive() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textWidth("AB") == canvas.textWidth("A") + canvas.textWidth("B"))
        #expect(
            canvas.textWidth("Wave") == canvas.textWidth("Wa") + canvas.textWidth("ve"))
    }

    @Test("末尾の空白も幅に数える")
    func trailingSpaceCounts() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textWidth("A ") > canvas.textWidth("A"))
        #expect(canvas.textWidth("A ") == canvas.textWidth("A") + canvas.textWidth(" "))
    }

    @Test("空文字列の幅は 0")
    func emptyStringHasNoWidth() throws {
        #expect(try makeCanvas().textWidth("") == 0)
    }

    @Test("改行を含む文字列の幅は、いちばん長い行の幅")
    func widthOfMultipleLinesIsTheWidest() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textWidth("A\nAAA") == canvas.textWidth("AAA"))
    }

    @Test("大きさを変えると幅も変わる")
    func widthFollowsSize() throws {
        let canvas = try makeCanvas()
        let small = canvas.textWidth("mokume")
        canvas.textSize(64)
        #expect(canvas.textWidth("mokume") > small)
    }

    // MARK: - 描画と計測の一致

    @Test("描画の前進は、計測した送り幅と同じ")
    func drawingAdvancesByTheMeasuredWidth() throws {
        let together = try makeCanvas()
        try together.draw {
            together.background(black)
            together.fill(white)
            together.text("AV", 20, 60)
        }

        let apart = try makeCanvas()
        try apart.draw {
            apart.background(black)
            apart.fill(white)
            apart.text("A", 20, 60)
            apart.text("V", 20 + apart.textWidth("A"), 60)
        }

        #expect(try pixels(of: together).bytes == pixels(of: apart).bytes)
    }

    @Test("字形の絵に付けた余白は、送り位置に混ざらない")
    func glyphPaddingDoesNotShiftThePen() throws {
        let canvas = try makeCanvas()
        let x: Float = 24
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("L", x, 60)
        }

        // この環境の書体から独立に引いた、字形の絵の左端
        let font = CTFontCreateWithName(fontName as CFString, 32, nil)
        var units = Array("L".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1)
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
        let expected = x + Float(bounds.minX)

        let ink = try #require(inkBounds(pixels(of: canvas), width: 160, height: 96))
        // 縁を滑らかにする分の 1 画素だけ許す。焼くときの余白 (2 画素) が
        // 混ざっていれば、この幅では収まらない
        #expect(abs(Float(ink.left) - expected) <= 1)
    }

    @Test("基準線に字が乗る")
    func baselineSitsWhereAsked() throws {
        let canvas = try makeCanvas()
        let baseline: Float = 60
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("L", 24, baseline)
        }

        // 「L」は基準線より下へ出ない字なので、墨の下端が基準線のすぐ上に来る
        let ink = try #require(inkBounds(pixels(of: canvas), width: 160, height: 96))
        #expect(abs(Float(ink.bottom) - (baseline - 1)) <= 1)
    }

    @Test("字形が上下逆さまに置かれていない")
    func glyphsAreNotUpsideDown() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("L", 24, 70)
        }

        // 「L」は下端に横棒があり、上は細い縦棒だけ。上下が入れ替わると重心も入れ替わる
        let image = try pixels(of: canvas)
        let ink = try #require(inkBounds(image, width: 160, height: 96))
        let middle = (ink.top + ink.bottom) / 2
        var upper = 0
        var lower = 0
        for y in ink.top...ink.bottom {
            for x in ink.left...ink.right where image[x, y].red > 8 {
                if y < middle { upper += 1 } else { lower += 1 }
            }
        }
        #expect(lower > upper)
    }

    // MARK: - 整列

    @Test("中央揃えは、指定した位置が文字列の中央になる")
    func centerAlignmentCentersOnThePoint() throws {
        let left = try makeCanvas()
        try left.draw {
            left.background(black)
            left.fill(white)
            left.text("mokume", 30, 60)
        }
        let centered = try makeCanvas()
        try centered.draw {
            centered.background(black)
            centered.fill(white)
            centered.textAlign(.center)
            centered.text("mokume", 30 + centered.textWidth("mokume") / 2, 60)
        }
        #expect(try pixels(of: left).bytes == pixels(of: centered).bytes)
    }

    @Test("右揃えは、指定した位置で文字列が終わる")
    func rightAlignmentEndsAtThePoint() throws {
        let left = try makeCanvas()
        try left.draw {
            left.background(black)
            left.fill(white)
            left.text("mokume", 30, 60)
        }
        let right = try makeCanvas()
        try right.draw {
            right.background(black)
            right.fill(white)
            right.textAlign(.right)
            right.text("mokume", 30 + right.textWidth("mokume"), 60)
        }
        #expect(try pixels(of: left).bytes == pixels(of: right).bytes)
    }

    @Test("上揃えは、基準線を字の高さのぶん下げたのと同じ")
    func topAlignmentDropsByTheAscent() throws {
        let baseline = try makeCanvas()
        try baseline.draw {
            baseline.background(black)
            baseline.fill(white)
            baseline.text("Ag", 24, 20 + baseline.textAscent())
        }
        let top = try makeCanvas()
        try top.draw {
            top.background(black)
            top.fill(white)
            top.textAlign(.left, .top)
            top.text("Ag", 24, 20)
        }
        #expect(try pixels(of: baseline).bytes == pixels(of: top).bytes)
    }

    @Test("下揃えは、基準線を字の深さのぶん上げたのと同じ")
    func bottomAlignmentLiftsByTheDescent() throws {
        let baseline = try makeCanvas()
        try baseline.draw {
            baseline.background(black)
            baseline.fill(white)
            baseline.text("Ag", 24, 70 - baseline.textDescent())
        }
        let bottom = try makeCanvas()
        try bottom.draw {
            bottom.background(black)
            bottom.fill(white)
            bottom.textAlign(.left, .bottom)
            bottom.text("Ag", 24, 70)
        }
        #expect(try pixels(of: baseline).bytes == pixels(of: bottom).bytes)
    }

    // MARK: - 行

    @Test("改行で行が分かれ、間隔は指定した行送りになる")
    func newlineStartsALineAtTheGivenLeading() throws {
        let canvas = try makeCanvas(width: 96, height: 128)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textLeading(40)
            canvas.text("L\nL", 20, 40)
        }

        let image = try pixels(of: canvas)
        // 各行の墨がある行番号を集め、2 つの塊に分かれることと、その間隔を見る
        var rows: [Int] = []
        for y in 0..<128 where (0..<96).contains(where: { image[$0, y].red > 8 }) {
            rows.append(y)
        }
        let gaps = zip(rows, rows.dropFirst()).filter { $1 - $0 > 1 }
        #expect(gaps.count == 1)
        let first = try #require(rows.first)
        #expect(rows.contains(first + 40))
    }

    @Test("行送りを指定しなければ、大きさから決まる")
    func leadingDefaultsToTheSize() throws {
        let canvas = try makeCanvas()
        canvas.textSize(40)
        #expect(canvas.resolvedTextLeading == 40 * Canvas.leadingRatio)
        canvas.textLeading(12)
        #expect(canvas.resolvedTextLeading == 12)
    }

    // MARK: - 書体

    @Test("この環境に無い書体を指定しても、いま使っている書体は変わらない")
    func unknownFontIsIgnored() throws {
        let canvas = try makeCanvas()
        let before = canvas.textWidth("mokume")
        canvas.textFont("ThisFontDoesNotExistAnywhere")
        #expect(canvas.textWidth("mokume") == before)
    }

    @Test("指定した書体が覆えない文字も描ける")
    func charactersOutsideTheFontStillDraw() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            // 欧文の書体には無い字。環境の別の書体から引ける
            canvas.text("あ", 30, 60)
        }
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) != nil)
    }

    @Test("太さと傾きを変えると絵が変わる")
    func styleChangesTheDrawing() throws {
        let plain = try makeCanvas()
        try plain.draw {
            plain.background(black)
            plain.fill(white)
            plain.text("mokume", 20, 60)
        }
        let bold = try makeCanvas()
        try bold.draw {
            bold.background(black)
            bold.fill(white)
            bold.textStyle(.bold)
            bold.text("mokume", 20, 60)
        }
        #expect(try pixels(of: plain).bytes != pixels(of: bold).bytes)
    }

    // MARK: - 描かないとき

    @Test("塗りを止めていると何も描かない")
    func noFillDrawsNothing() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.text("mokume", 20, 60)
        }
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil)
    }

    @Test("大きさが 0 なら何も描かない")
    func zeroSizeDrawsNothing() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(0)
            canvas.text("mokume", 20, 60)
        }
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil)
    }

    // MARK: - 状態の積み降ろし

    @Test("文字の設定はスタイルと一緒に積み降ろしされる")
    func textSettingsRideOnTheStyleStack() throws {
        let canvas = try makeCanvas()
        let before = canvas.textWidth("mokume")
        canvas.pushStyle()
        canvas.textSize(64)
        canvas.textAlign(.right, .top)
        canvas.textLeading(99)
        #expect(canvas.textWidth("mokume") != before)
        canvas.popStyle()
        #expect(canvas.textWidth("mokume") == before)
        #expect(canvas.currentHorizontalTextAlign == .left)
        #expect(canvas.currentVerticalTextAlign == .baseline)
        #expect(canvas.currentTextLeading == nil)
    }

    // MARK: - 折り返し

    @Test("幅に収まらない語は次の行へ送られる")
    func wordsMoveToTheNextLine() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let lines = canvas.wrapped("aa bb cc dd", face: canvas.typeface, within: canvas.textWidth("aa bb"))
        #expect(lines.map(String.init) == ["aa bb", "cc dd"])
    }

    @Test("折るために消費するのは、切れ目の空白だけ")
    func onlyTheBreakingSpaceIsConsumed() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let source = "alpha beta gamma delta"
        let lines = canvas.wrapped(
            source, face: canvas.typeface, within: canvas.textWidth("alpha beta"))
        #expect(lines.map(String.init).joined(separator: " ") == source)
        for line in lines {
            #expect(canvas.textWidth(String(line)) <= canvas.textWidth("alpha beta"))
        }
    }

    @Test("幅より長い 1 語は、その語の中で折る")
    func aWordWiderThanTheBoxBreaksInside() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let lines = canvas.wrapped(
            "supercalifragilistic", face: canvas.typeface, within: canvas.textWidth("super"))
        #expect(lines.count > 1)
        #expect(lines.map(String.init).joined() == "supercalifragilistic")
    }

    @Test("文字の切れ目で折るときは、語の途中でも折る")
    func characterWrapBreaksInsideWords() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        canvas.textWrap(.character)
        let lines = canvas.wrapped(
            "aa bb cc dd", face: canvas.typeface, within: canvas.textWidth("aa bb"))
        #expect(lines.map(String.init).joined() == "aa bb cc dd")
        #expect(lines.count > 1)
        // 語の切れ目を待たないので、行の末尾が語の終わりとは限らない
        #expect(lines.map(String.init) != ["aa bb", "cc dd"])
    }

    @Test("改行は幅に関わらず必ず行を分ける")
    func newlineAlwaysBreaks() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let lines = canvas.wrapped("a\nb", face: canvas.typeface, within: 1000)
        #expect(lines.map(String.init) == ["a", "b"])
    }

    // MARK: - 矩形への流し込み

    @Test("収まりきらなかった続きが返り、次の矩形へ流せる")
    func theRemainderCanBePouredIntoTheNextBox() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        canvas.textSize(16)
        let source = "alpha beta gamma delta epsilon zeta"
        var short = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            // 1 行ぶんしか入らない高さ
            short = canvas.text(source, 10, 10, 80, canvas.textAscent() + canvas.textDescent())
        }
        #expect(short.lineCount == 1)
        #expect(short.isTruncated)

        let rest = try makeCanvas(width: 200, height: 200)
        rest.textSize(16)
        var all = TextFlow(lineCount: 0, height: 0, remainder: "")
        try rest.draw {
            rest.background(black)
            rest.fill(white)
            all = rest.text(source, 10, 10, 80, 180)
        }
        #expect(!all.isTruncated)
        // 続きだけを流し直すと、全体から 1 行ぶん減る
        let continued = rest.text(short.remainder, 10, 10, 80, 180)
        #expect(continued.lineCount == all.lineCount - 1)
        #expect(!continued.isTruncated)
    }

    @Test("返る高さは、置いた行数から決まる")
    func theReturnedHeightFollowsTheLineCount() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        canvas.textSize(16)
        canvas.textLeading(24)
        let block = canvas.textAscent() + canvas.textDescent()
        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text("aa\nbb\ncc", 10, 10, 100, 180)
        }
        #expect(flow.lineCount == 3)
        #expect(flow.height == block + 2 * 24)
    }

    @Test("矩形の 4 つの数は、矩形を描くときと同じ読み方をする")
    func theBoxFollowsRectMode() throws {
        let corner = try makeCanvas(width: 200, height: 120)
        corner.textSize(16)
        try corner.draw {
            corner.background(black)
            corner.fill(white)
            corner.text("alpha beta gamma", 20, 20, 80, 80)
        }
        let center = try makeCanvas(width: 200, height: 120)
        center.textSize(16)
        try center.draw {
            center.background(black)
            center.fill(white)
            center.rectMode(.center)
            center.text("alpha beta gamma", 60, 60, 80, 80)
        }
        #expect(try pixels(of: corner).bytes == pixels(of: center).bytes)
    }

    @Test("幅か高さが無い矩形へは、何も置かない")
    func anEmptyBoxPlacesNothing() throws {
        let canvas = try makeCanvas()
        var flow = TextFlow(lineCount: 1, height: 1, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text("mokume", 10, 10, 0, 50)
        }
        #expect(flow.lineCount == 0)
        #expect(flow.remainder == "mokume")
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil)
    }

    // MARK: - 輪郭

    @Test("輪郭は、描いた字と同じ場所に出る")
    func theOutlineLandsWhereTheTextIsDrawn() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("Agj", 24, 60)
        }
        let ink = try #require(inkBounds(try pixels(of: canvas), width: 160, height: 96))

        let contours = canvas.textOutline("Agj", 24, 60)
        let points = contours.flatMap(\.points)
        let left = points.map(\.x).min()!
        let right = points.map(\.x).max()!
        let top = points.map(\.y).min()!
        let bottom = points.map(\.y).max()!

        #expect(abs(left - Float(ink.left)) <= 2)
        #expect(abs(right - Float(ink.right)) <= 2)
        #expect(abs(top - Float(ink.top)) <= 2)
        #expect(abs(bottom - Float(ink.bottom)) <= 2)
    }

    @Test("穴のある字は、外側の周と穴に分かれる")
    func glyphsWithHolesReportThem() throws {
        let canvas = try makeCanvas()
        let o = canvas.textOutline("o", 10, 50)
        #expect(o.count == 2)
        #expect(o.filter(\.isHole).count == 1)
        // 外側が先に並ぶ
        #expect(o.first?.isHole == false)

        #expect(canvas.textOutline("L", 10, 50).allSatisfy { !$0.isHole })
    }

    @Test("周を持たない字は輪郭を出さない")
    func blankGlyphsHaveNoContours() throws {
        #expect(try makeCanvas().textOutline("   ", 10, 50).isEmpty)
    }

    @Test("輪郭も整列に従う")
    func theOutlineFollowsAlignment() throws {
        let canvas = try makeCanvas()
        canvas.textAlign(.right)
        let contours = canvas.textOutline("mokume", 120, 60)
        let right = contours.flatMap(\.points).map(\.x).max()!
        // 送りの終わりが 120。最後の字の右端はそれより左に来る
        #expect(right <= 120)
        #expect(right > 120 - canvas.textWidth("mokume"))
    }

    // MARK: - 焼き場

    @Test("焼き場を広げても、それまでに置いた字は元のまま描かれる")
    func growingTheAtlasKeepsEarlierGlyphsIntact() throws {
        let alone = try makeCanvas(width: 160, height: 128)
        try alone.draw {
            alone.background(black)
            alone.fill(white)
            alone.textSize(96)
            alone.text("A", 10, 100)
        }
        #expect(alone.atlas.size == GlyphAtlas.initialSize)

        // 同じ「A」を置いたあと、面に収まらないだけの字を焼かせる。面は差し替わるが、
        // 先に置いた字は前の面を指したまま描かれなければならない
        let crowded = try makeCanvas(width: 160, height: 128)
        try crowded.draw {
            crowded.background(black)
            crowded.fill(white)
            crowded.textSize(96)
            crowded.text("A", 10, 100)
            crowded.text("BCDEFGHIJKLMNOPQRSTUVWXYZ", 10, 4096)
        }
        #expect(crowded.atlas.size > GlyphAtlas.initialSize)

        #expect(try pixels(of: alone).bytes == pixels(of: crowded).bytes)
    }

    /// 上限の面にも収まらない大きさ。**倍にして、丸めや余白では届かない側へ振る。**
    private var overwhelmingSize: Float { Float(GlyphAtlas.maximumSize) * 2 }

    @Test("焼き場に入りきらない字形は、理由を『大きすぎる』として名乗る")
    func anOversizedGlyphNamesItsReason() throws {
        let canvas = try makeCanvas()
        canvas.textSize(overwhelmingSize)
        let face = canvas.typeface
        let resolved = try #require(face.glyph(for: "M"))
        let key = GlyphAtlas.Key(
            fontKey: resolved.fontKey, size: overwhelmingSize, style: .normal,
            glyph: resolved.glyph)

        let lookup = canvas.atlas.entry(for: key, font: resolved.font)
        guard case .tooLarge = lookup else {
            Issue.record(
                """
                上限の面より大きい字形を頼んだのに、面は「\(lookup)」と答えた。

                引けなかった理由が「満杯」と「字形が面より大きい」で分かれていないと、
                受け取る側は広げれば入ると読んで、入らないものを追って広げ続ける
                ([#738](https://github.com/mokume-metal/mokume/issues/738))。
                """)
            return
        }
    }

    @Test("上限の面にも入らない字形を頼んでも、焼き場は広がらない")
    func anOversizedGlyphDoesNotGrowTheAtlas() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(self.black)
            canvas.fill(self.white)
            canvas.textSize(self.overwhelmingSize)
            canvas.text("M", 10, 100)
        }
        #expect(
            canvas.atlas.size == GlyphAtlas.initialSize,
            """
            広げても入らない字形のために、焼き場が \(canvas.atlas.size) まで広がった。

            広げるたびに焼いた字形は全部捨てられるので、これは入らない 1 字のために
            他の字を焼き直させ続ける形になる。上限まで行っても入らないので、回復もしない
            ([#738](https://github.com/mokume-metal/mokume/issues/738))。
            """)
    }

    // MARK: - 色を持つ字形

    /// 色を持つ字形を検査に使う。**その字が無い環境なら見送る** — 検査の対象は
    /// 「色が失われないこと」であって、この環境に絵文字があることではない。
    private let coloredScalar: Unicode.Scalar = "\u{1F534}"  // 🔴

    /// 描いた絵の中で、いちばん彩度の高い画素。
    private func mostSaturated(_ image: DisplayImage, width: Int, height: Int) -> (
        red: Int, green: Int, blue: Int, saturation: Int
    ) {
        var best = (red: 0, green: 0, blue: 0, saturation: -1)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = image[x, y]
                let high = Int(max(pixel.red, max(pixel.green, pixel.blue)))
                let low = Int(min(pixel.red, min(pixel.green, pixel.blue)))
                if high - low > best.saturation {
                    best = (Int(pixel.red), Int(pixel.green), Int(pixel.blue), high - low)
                }
            }
        }
        return best
    }

    /// 色を持つ字を 1 つ描いて読み戻す。この環境にその字が無ければ `nil`。
    private func drawColoredGlyph(fill: LinearRGBA, background: LinearRGBA = .linear(
        red: 0, green: 0, blue: 0)) throws -> DisplayImage? {
        let canvas = try makeCanvas(width: 64, height: 64)
        canvas.noTextFont()
        canvas.textSize(40)
        guard canvas.typeface.glyph(for: coloredScalar) != nil else { return nil }
        try canvas.draw {
            canvas.background(background)
            canvas.fill(fill)
            canvas.text(String(self.coloredScalar), 8, 48)
        }
        return try pixels(of: canvas)
    }

    @Test("色を持つ字形は、色のまま描かれる")
    func aColoredGlyphKeepsItsColor() throws {
        guard let image = try drawColoredGlyph(fill: white) else { return }
        let brightest = mostSaturated(image, width: 64, height: 64)
        // 塗りは白なので、色が出ているなら字形の側が持っていた色である
        #expect(brightest.saturation > 64)
        #expect(brightest.red > brightest.green)
        #expect(brightest.red > brightest.blue)
    }

    @Test("色を持つ字形に、塗りの色は掛からない")
    func theFillColorDoesNotTintAColoredGlyph() throws {
        guard let onWhite = try drawColoredGlyph(fill: white),
            let onBlue = try drawColoredGlyph(fill: .linear(red: 0, green: 0, blue: 1))
        else { return }
        // 塗りを青にしても、字形の色は動かない。
        // **画素の並びごとではなく代表の 1 点で比べる** — 食い違ったときに、
        // 面いっぱいのバイト列ではなく色そのものが表示に出る
        #expect(
            mostSaturated(onWhite, width: 64, height: 64)
                == mostSaturated(onBlue, width: 64, height: 64))
        #expect(onWhite == onBlue)
    }

    @Test("色を持つ字形にも、塗りの透明度は効く")
    func theFillAlphaStillReachesAColoredGlyph() throws {
        let half = LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 0.5)
        guard let opaque = try drawColoredGlyph(fill: white),
            let faded = try drawColoredGlyph(fill: half)
        else { return }
        let solid = mostSaturated(opaque, width: 64, height: 64)
        let thin = mostSaturated(faded, width: 64, height: 64)
        // 黒地の上なので、薄くすれば色も彩度も引く
        #expect(thin.saturation < solid.saturation)
        #expect(thin.red < solid.red)
    }

    @Test("単色の字は、いままでどおり塗りの色で出る")
    func aMonochromeGlyphStillTakesTheFillColor() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        try canvas.draw {
            canvas.background(self.black)
            canvas.fill(.linear(red: 0, green: 1, blue: 0))
            canvas.text("A", 8, 48)
        }
        let image = try pixels(of: canvas)
        let brightest = mostSaturated(image, width: 64, height: 64)
        #expect(brightest.green > 200)
        #expect(brightest.red < 32)
        #expect(brightest.blue < 32)
    }

    @Test("焼き場は、色を持つ字形だけを色つきと見分ける")
    func theAtlasMarksOnlyColoredGlyphs() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        canvas.noTextFont()
        canvas.textSize(40)
        let face = canvas.typeface
        guard let colored = face.glyph(for: coloredScalar),
            let plain = face.glyph(for: "A")
        else { return }
        #expect(canvas.glyphEntry(for: colored)?.isColored == true)
        #expect(canvas.glyphEntry(for: plain)?.isColored == false)
    }
}
