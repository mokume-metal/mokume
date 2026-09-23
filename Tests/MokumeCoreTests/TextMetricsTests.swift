// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 文字の寸法を、この環境の CoreText から**独立に**引いた値と照合する ([#1385] 条件 3〜8)。
///
/// `textAscent` / `textDescent` / `textWidth` は、整列と流し込みの検査 (``TextTests``) が
/// 物差しに使っている。物差しそのものがずれると、それを使う検査も一緒にずれて緑のままに
/// なるので、**物差しを CoreText の値と直に突き合わせる**。
///
/// 参照の書体は検査の側で CoreText に作らせる (``CoreTextReference``)。既定の書体は
/// `CTFontCreateUIFontForLanguage(.system, …)`、太さと傾きは**名前で引いた**書体
/// (`Times-Bold` など) で、実装が通る「書体に trait を付けて写す」経路を通らない。
///
/// 並べ方の検査 (縦の整列・矩形への流し込み) は、期待する絵を**仕様の量だけずらして
/// 1 行ずつ描いた絵**として作り、バイト列で比べる。保存した絵とは比べない (ADR-0019 決定 4)。
/// 寸法はどれも 1/64 画素の倍数なので、式の組み方を変えても浮動小数の丸めは入らない。
///
/// [#1385]: https://github.com/mokume-metal/mokume/issues/1385
@Suite(
    "文字の寸法を CoreText と照合する",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextMetricsTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 書体の名前 (`nil` は既定の書体) と大きさの組。
    ///
    /// **既定の書体と Helvetica の両方を見る。** 既定の書体は作者が何も書かなければ使う
    /// もので、Helvetica は版が変わりにくい (``TextTests`` が位置の土台にしている) もの。
    nonisolated static var faces: [(font: String?, size: Float)] {
        [(nil, 32), (nil, 64), ("Helvetica", 32), ("Helvetica", 64)]
    }

    private func makeCanvas(
        width: Int = 240, height: Int = 160, font: String? = nil, size: Float = 32
    ) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        if let font { canvas.textFont(font) }
        canvas.textSize(size)
        return canvas
    }

    /// 同じ書体を CoreText に作らせる。
    private func reference(_ font: String?, size: Float) throws -> CTFont {
        guard let font else { return try #require(CoreTextReference.defaultFont(size: size)) }
        return CoreTextReference.font(named: font, size: size)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 墨の乗っている画素の外接矩形。何も描かれていなければ `nil`。
    private func inkBounds(_ image: DisplayImage) -> (
        left: Int, top: Int, right: Int, bottom: Int
    )? {
        var left = Int.max
        var top = Int.max
        var right = Int.min
        var bottom = Int.min
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].red > 8 {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
            }
        }
        guard left <= right else { return nil }
        return (left, top, right, bottom)
    }

    // MARK: - 高さと深さ (条件 3)

    @Test("字の高さと深さは、CoreText が書体に持たせた値そのもの", arguments: faces)
    func ascentAndDescentAreTheFontsOwn(_ face: (font: String?, size: Float)) throws {
        let canvas = try makeCanvas(font: face.font, size: face.size)
        let font = try reference(face.font, size: face.size)
        #expect(canvas.textAscent() == Float(CTFontGetAscent(font)))
        #expect(canvas.textDescent() == Float(CTFontGetDescent(font)))
    }

    /// 説明の約束 (``Sketch/textAscent()`` / ``Sketch/textDescent()``) を墨で見る。
    ///
    /// **約束は既定の書体についてのもの**である。書体の値は「どの字形も越えない」ことまでは
    /// 保証せず、Helvetica の Å・É は字の高さを越える ([#1408])。
    ///
    /// [#1408]: https://github.com/mokume-metal/mokume/issues/1408
    @Test(
        "既定の書体では、アクセントの付いた大文字も下へ伸びる字も、高さと深さの線を越えない",
        arguments: [32, 64] as [Float])
    func inkStaysWithinTheLinesInTheDefaultFace(_ size: Float) throws {
        let canvas = try makeCanvas(width: 6 * Int(size), height: 3 * Int(size), size: size)
        let baseline = 2 * size
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("ÅÉgjy", size / 2, baseline)
        }
        let ink = try #require(inkBounds(pixels(of: canvas)))

        // **墨が線の近くまで来ていることを先に見る。** 輪と下へ伸びる部分が描かれて
        // いなければ、下の 2 つは何も見ていないことになる
        let font = try reference(nil, size: size)
        #expect(
            Float(ink.top) < baseline - Float(CTFontGetCapHeight(font)),
            "Å の輪が大文字の高さより上に出ていない")
        #expect(Float(ink.bottom) > baseline, "g j y が基準線より下へ伸びていない")

        // 線を画素の行へ落として比べる。線が通る行までは墨が乗ってよい (縁を滑らかに
        // する分の 1 行未満だけ許す)
        #expect(ink.top >= Int((baseline - canvas.textAscent()).rounded(.down)))
        #expect(ink.bottom <= Int((baseline + canvas.textDescent()).rounded(.down)))
    }

    // MARK: - 幅 (条件 4)

    @Test("幅は、CoreText の送り幅の合計と一致する", arguments: faces)
    func widthIsTheSumOfCoreTextAdvances(_ face: (font: String?, size: Float)) throws {
        let canvas = try makeCanvas(font: face.font, size: face.size)
        let font = try reference(face.font, size: face.size)
        let expected = try #require(CoreTextReference.advance(of: "mokume", in: font))
        #expect(abs(Double(canvas.textWidth("mokume")) - expected) < 1e-3)
    }

    /// **既定の書体では見ない。** 既定の書体は大きさに合わせて字形と送り幅を切り替える
    /// (光学サイズ) ので、幅が大きさに比例しない — 32 で 119.61・64 で 235.66 (2026-09-23
    /// 実測)。既定の書体の幅は、上の検査が大きさごとに CoreText と照合している。
    @Test("字形を大きさで切り替えない書体では、大きさを倍にすると幅も倍になる")
    func doublingTheSizeDoublesTheWidth() throws {
        let canvas = try makeCanvas(font: "Helvetica", size: 32)
        let small = canvas.textWidth("mokume")
        canvas.textSize(64)
        #expect(abs(canvas.textWidth("mokume") - 2 * small) < 1e-3)
    }

    // MARK: - 縦の整列 (条件 5)

    /// 縦の指定と、描く行。
    nonisolated static var verticalCases: [(align: VerticalTextAlign, lines: [String])] {
        [
            (.center, ["Ag"]),
            (.center, ["Ag", "jy", "Mo"]),
            (.bottom, ["Ag", "jy", "Mo"]),
            (.top, ["Ag", "jy", "Mo"]),
        ]
    }

    /// 仕様の量は ``VerticalTextAlign`` の説明から導く。行の囲みは最初の行の基準線から
    /// 字の高さぶん上 (上端) と、最後の行の基準線から字の深さぶん下 (下端) の間で、
    /// 上揃えは上端・中央揃えは中央・下揃えは下端を、指定した位置に合わせる。
    @Test("縦の整列は、基準線を仕様の量だけずらして 1 行ずつ描いた絵と一致する", arguments: verticalCases)
    func verticalAlignmentShiftsTheBaselineBySpec(
        _ sample: (align: VerticalTextAlign, lines: [String])
    ) throws {
        let (x, y, leading): (Float, Float, Float) = (20, 120, 40)

        let aligned = try makeCanvas(width: 120, height: 240, font: "Helvetica")
        try aligned.draw {
            aligned.background(black)
            aligned.fill(white)
            aligned.textLeading(leading)
            aligned.textAlign(.left, sample.align)
            aligned.text(sample.lines.joined(separator: "\n"), x, y)
        }

        let byLine = try makeCanvas(width: 120, height: 240, font: "Helvetica")
        let ascent = byLine.textAscent()
        let descent = byLine.textDescent()
        // 最初の行の基準線から、最後の行の基準線まで
        let span = Float(sample.lines.count - 1) * leading
        let first: Float =
            switch sample.align {
            case .baseline: y
            case .top: y + ascent
            case .center: y - (ascent + span + descent) / 2 + ascent
            case .bottom: y - descent - span
            }
        try byLine.draw {
            byLine.background(black)
            byLine.fill(white)
            for (index, line) in sample.lines.enumerated() {
                byLine.text(line, x, first + Float(index) * leading)
            }
        }

        #expect(try pixels(of: aligned).bytes == pixels(of: byLine).bytes)
    }

    // MARK: - 矩形への流し込み (条件 6)

    /// 横 3 通り × 縦 3 通り。矩形の中では基準線に意味が無い (上揃えと同じ) ので数えない。
    nonisolated static var boxPlacements:
        [(horizontal: HorizontalTextAlign, vertical: VerticalTextAlign)]
    {
        HorizontalTextAlign.allCases.flatMap { horizontal in
            [VerticalTextAlign.top, .center, .bottom].map { (horizontal, $0) }
        }
    }

    @Test(
        "矩形へ流し込んだ行は、置き方どおりの位置へ 1 行ずつ描いた絵と一致し、墨が矩形に収まる",
        arguments: boxPlacements)
    func pouredLinesLandWhereTheSpecSays(
        _ placement: (horizontal: HorizontalTextAlign, vertical: VerticalTextAlign)
    ) throws {
        let words = ["alpha", "beta", "gamma"]
        let (boxX, boxY, boxHeight, leading): (Float, Float, Float, Float) = (30, 20, 180, 40)

        let poured = try makeCanvas(width: 240, height: 220, font: "Helvetica")
        // **幅は、どの 1 語も収まり、2 語は収まらない大きさにする。** 置かれる行が
        // 1 語ずつに決まるので、期待する行を折り返しの実装から借りずに書ける
        let widest = try #require(words.map { poured.textWidth($0) }.max())
        let boxWidth = (widest + 8).rounded(.up)
        try #require(poured.textWidth("alpha beta") > boxWidth)
        try #require(poured.textWidth("beta gamma") > boxWidth)

        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try poured.draw {
            poured.background(black)
            poured.fill(white)
            poured.textLeading(leading)
            poured.textAlign(placement.horizontal, placement.vertical)
            flow = poured.text(words.joined(separator: " "), boxX, boxY, boxWidth, boxHeight)
        }
        #expect(flow.lineCount == words.count)
        #expect(!flow.isTruncated)

        // 行の塊は、最初の行の上端 (字の高さ) から最後の行の下端 (字の深さ) まで
        let byLine = try makeCanvas(width: 240, height: 220, font: "Helvetica")
        let ascent = byLine.textAscent()
        let block = ascent + byLine.textDescent() + Float(words.count - 1) * leading
        let top: Float =
            switch placement.vertical {
            case .top, .baseline: boxY
            case .center: boxY + (boxHeight - block) / 2
            case .bottom: boxY + boxHeight - block
            }
        try byLine.draw {
            byLine.background(black)
            byLine.fill(white)
            for (index, word) in words.enumerated() {
                let width = byLine.textWidth(word)
                let x: Float =
                    switch placement.horizontal {
                    case .left: boxX
                    case .center: boxX + (boxWidth - width) / 2
                    case .right: boxX + boxWidth - width
                    }
                byLine.text(word, x, top + ascent + Float(index) * leading)
            }
        }
        #expect(try pixels(of: poured).bytes == pixels(of: byLine).bytes)

        // 墨は矩形の内側。縁を滑らかにする分の 1 画素だけ許す
        let ink = try #require(inkBounds(pixels(of: poured)))
        #expect(ink.left >= Int(boxX) - 1)
        #expect(ink.right <= Int(boxX + boxWidth))
        #expect(ink.top >= Int(boxY) - 1)
        #expect(ink.bottom <= Int(boxY + boxHeight))
    }

    // MARK: - 続き (条件 7)

    /// 切れ目の空白は 1 つにしてある。**空白が続く切れ目では、前のほうの空白が行の末尾に
    /// 残る** ([#1412]) — 続きの側は正しく次の語から始まるが、行の幅が空白の分だけ広がる。
    ///
    /// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
    @Test("語の切れ目で残った続きは、切れ目の空白を消費した直後から始まり、つなぐと元の文に戻る")
    func theRemainderResumesAfterTheConsumedSpace() throws {
        let canvas = try makeCanvas(font: "Helvetica", size: 16)
        let words = ["alpha", "beta", "gamma", "delta"]
        let source = words.joined(separator: " ")
        // 1 語ずつの行になる幅 (上の流し込みと同じ決め方)
        let widest = try #require(words.map { canvas.textWidth($0) }.max())
        let boxWidth = (widest + 2).rounded(.up)
        try #require(
            zip(words, words.dropFirst()).allSatisfy { canvas.textWidth("\($0) \($1)") > boxWidth })
        canvas.textLeading(20)
        // 2 行ぶんだけ入る高さ
        let boxHeight = canvas.textAscent() + canvas.textDescent() + 20

        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text(source, 10, 10, boxWidth, boxHeight)
        }
        #expect(flow.lineCount == 2)
        // 置いた行は alpha と beta。**切れ目の空白はどちらの行にも続きにも入らない**
        #expect(flow.remainder == "gamma delta")
        #expect(words.prefix(2).joined(separator: " ") + " " + flow.remainder == source)
    }

    @Test("段落の切れ目で残った続きは、改行を 1 つ消費した直後から始まり、つなぐと元の文に戻る")
    func theRemainderResumesAfterTheConsumedNewline() throws {
        let canvas = try makeCanvas(font: "Helvetica", size: 16)
        // 1 行ぶんだけ入る高さ
        let boxHeight = canvas.textAscent() + canvas.textDescent()
        func remainder(of source: String) throws -> TextFlow {
            var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                flow = canvas.text(source, 10, 10, 200, boxHeight)
            }
            return flow
        }

        let paragraphs = try remainder(of: "alpha beta\ngamma")
        #expect(paragraphs.lineCount == 1)
        #expect(paragraphs.remainder == "gamma")
        #expect("alpha beta" + "\n" + paragraphs.remainder == "alpha beta\ngamma")

        // 空の行も 1 行に数えるので、置けなかった空の行は続きの先頭に残る
        let blank = try remainder(of: "alpha\n\nbeta")
        #expect(blank.lineCount == 1)
        #expect(blank.remainder == "\nbeta")
        #expect("alpha" + "\n" + blank.remainder == "alpha\n\nbeta")
    }

    // MARK: - 書体の戻しと、太さと傾き (条件 8)

    @Test("書体の指定をやめると、新しい面の既定の書体に戻る")
    func noTextFontReturnsToTheFreshDefault() throws {
        let fresh = try makeCanvas()
        let returned = try makeCanvas()
        returned.textFont("Courier")
        // **途中の書体が既定と違うことを先に見る。** 同じなら、戻ったかどうかが見えない
        #expect(returned.textWidth("mokume") != fresh.textWidth("mokume"))
        returned.noTextFont()
        #expect(returned.textWidth("mokume") == fresh.textWidth("mokume"))
        #expect(returned.textAscent() == fresh.textAscent())
        #expect(returned.textDescent() == fresh.textDescent())
    }

    /// 太さと傾きの 4 通りと、同じ族の書体の PostScript 名。
    ///
    /// **Times で見る。** Helvetica や既定の書体の斜体は正体を傾けただけで送り幅が同じなので、
    /// 傾きの指定が効いていなくても幅が一致してしまう。Times は 4 通りとも送り幅が違う。
    nonisolated static var styledFaces: [(style: TextStyle, postScriptName: String)] {
        [
            (.normal, "Times-Roman"),
            (.bold, "Times-Bold"),
            (.italic, "Times-Italic"),
            (.boldItalic, "Times-BoldItalic"),
        ]
    }

    @Test("太さと傾きの 4 通りの幅は、名前で引いた同じ族の書体の送り幅と一致する", arguments: styledFaces)
    func textStyleMatchesTheNamedFace(_ face: (style: TextStyle, postScriptName: String)) throws {
        let canvas = try makeCanvas(font: "Times")
        canvas.textStyle(face.style)
        let font = CoreTextReference.font(named: face.postScriptName, size: 32)
        // **引いた書体が本当にその名前のものか。** 無い名前でも CoreText は別の書体を返す
        #expect(CTFontCopyPostScriptName(font) as String == face.postScriptName)
        let expected = try #require(CoreTextReference.advance(of: "Mokume", in: font))
        #expect(abs(Double(canvas.textWidth("Mokume")) - expected) < 1e-3)
    }

    @Test("Times の 4 通りは、送り幅がどれも違う")
    func theFourTimesFacesDiffer() throws {
        // 上の検査が取り違えを見分けられることの裏付け。同じ幅の組があると、
        // その 2 つを取り違えても上の検査は緑のままになる
        let widths = try Self.styledFaces.map {
            try #require(
                CoreTextReference.advance(
                    of: "Mokume", in: CoreTextReference.font(named: $0.postScriptName, size: 32)))
        }
        #expect(Set(widths).count == widths.count)
    }
}

/// 検査の側で CoreText に作らせる書体と、その寸法。**実装 (``Typeface``) を通らない。**
enum CoreTextReference {
    /// 既定の書体。説明の「この環境の既定の書体」を、CoreText の既定の UI 書体として読む。
    static func defaultFont(size: Float) -> CTFont? {
        CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
    }

    /// 名前で引いた書体。
    static func font(named name: String, size: Float) -> CTFont {
        CTFontCreateWithName(name as CFString, CGFloat(size), nil)
    }

    /// 文字列の送り幅の合計。**字形の並びをまとめて CoreText に渡し、合計も CoreText に
    /// 取らせる** (実装は 1 文字ずつ引いて `Float` で積む)。書体が覆えない字があれば `nil`。
    static func advance(of string: String, in font: CTFont) -> Double? {
        var units = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return nil }
        return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, nil, glyphs.count)
    }
}
