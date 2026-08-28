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
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)

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
}
