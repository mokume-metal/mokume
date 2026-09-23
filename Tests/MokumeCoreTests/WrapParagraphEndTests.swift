// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 段落の末尾の空白で折ったときの行 ([#1419])。
///
/// **語の切れ目の後ろに段落の終わりしか無ければ、空の行は足さない。** 切れ目の空白を消費した
/// 先が段落の終わりなので、次の行に置く字が無い — それを空の行に数えると、行数と高さが
/// 1 行ぶん増え、続きが改行から始まり、矩形の中で下揃え・中央揃えにした塊が空の行の分だけ
/// 上へずれる。空白が 1 つでも起きるので、続いた空白の前のほうが行に残る形 ([#1412]・
/// ``WrapWhitespaceTests``) とは別に見る。
///
/// 元からある空の行 (改行が続いたところ) は、いままでどおり 1 行に数える。
///
/// 期待する行と絵は、折り返しの実装から借りずに**語**から書く。絵はバイト列で比べ、保存した
/// 絵とは比べない (ADR-0019 決定 4)。
///
/// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
/// [#1419]: https://github.com/mokume-metal/mokume/issues/1419
@Suite(
    "段落の末尾の空白で折った行",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct WrapParagraphEndTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 検査で使う書体。**版が変わりにくいものを選ぶ** (``TextTests`` と同じ理由)。
    private let fontName = "Helvetica"

    private func makeCanvas(width: Int = 240, height: Int = 220, size: Float = 16) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        canvas.textFont(fontName)
        canvas.textSize(size)
        return canvas
    }

    private func lines(_ canvas: Canvas, _ source: String, within limit: Float) -> [String] {
        canvas.wrapped(source, face: canvas.typeface, within: limit).map(String.init)
    }

    /// 矩形へ流し込んで、返った結果を受け取る。
    private func pour(
        _ canvas: Canvas, _ source: String, width: Float, height: Float
    ) throws -> TextFlow {
        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text(source, 0, 0, width, height)
        }
        return flow
    }

    // MARK: - 行への切り分け (条件 1)

    @Test("段落の末尾の空白で折っても、空の行を足さない", arguments: [" ", "  ", "   "])
    func aBreakAtTheParagraphEndAddsNoEmptyLine(_ run: String) throws {
        let canvas = try makeCanvas()
        // Issue の幅。「alpha」がちょうど収まり、後ろの空白で溢れる
        let limit = canvas.textWidth("alpha")
        try #require(canvas.textWidth("alpha ") > limit)

        // 文の終わりでも、改行の手前でも
        #expect(lines(canvas, "alpha\(run)", within: limit) == ["alpha"])
        #expect(lines(canvas, "alpha\(run)\nbeta", within: limit) == ["alpha", "beta"])
    }

    @Test("語が 2 つ入った行の後ろの空白で溢れても、空の行を足さない")
    func aBreakAfterALongerLineAddsNoEmptyLine() throws {
        let canvas = try makeCanvas()
        let limit = canvas.textWidth("alpha beta")
        #expect(lines(canvas, "alpha beta ", within: limit) == ["alpha beta"])
        #expect(
            lines(canvas, "gamma alpha beta \ndelta", within: limit)
                == ["gamma", "alpha beta", "delta"])
    }

    // MARK: - 元からある空の行 (条件 3)

    @Test("元からある空の行は、段落の末尾の空白で折った後ろでも 1 行に数える")
    func anOriginalBlankLineStillCounts() throws {
        let canvas = try makeCanvas()
        let limit = canvas.textWidth("alpha")
        #expect(lines(canvas, "alpha\n\nbeta", within: limit) == ["alpha", "", "beta"])
        #expect(lines(canvas, "alpha \n\nbeta", within: limit) == ["alpha", "", "beta"])
        // 空の行が続けば、続いた数だけ数える
        #expect(lines(canvas, "alpha \n\n\nbeta", within: limit) == ["alpha", "", "", "beta"])
    }

    @Test("元からある空の行は、矩形へ流しても 1 行に数え、置けなければ続きの先頭に残る")
    func anOriginalBlankLineCountsInTheFlow() throws {
        let canvas = try makeCanvas()
        canvas.textLeading(20)
        let limit = canvas.textWidth("alpha")
        let block = canvas.textAscent() + canvas.textDescent()
        let source = "alpha \n\nbeta"

        // 1 行ぶんの高さ: 置いたのは alpha だけで、空の行は続きに残る
        let one = try pour(canvas, source, width: limit, height: block)
        #expect(one.lineCount == 1)
        #expect(one.remainder == "\nbeta")

        // 2 行ぶんの高さ: 空の行も 1 行に数えて置く
        let two = try pour(canvas, source, width: limit, height: block + 20)
        #expect(two.lineCount == 2)
        #expect(two.height == block + 20)
        #expect(two.remainder == "beta")
    }

    // MARK: - 矩形への流し込み (条件 2)

    /// 続き (``TextFlow/remainder``) は**元の文の後ろの部分そのもの**なので、消費した空白と
    /// 改行は失われない — 元の文から続きを除いた前半の末尾に、そのまま残っている。
    @Test("段落の末尾の空白で折った続きは、次の段落の先頭から始まる", arguments: [" ", "  "])
    func theRemainderStartsAtTheNextParagraph(_ run: String) throws {
        let canvas = try makeCanvas()
        let limit = canvas.textWidth("alpha")
        // 1 行ぶんの高さ
        let block = canvas.textAscent() + canvas.textDescent()
        let source = "alpha\(run)\nbeta"

        let flow = try pour(canvas, source, width: limit, height: block)
        #expect(flow.lineCount == 1)
        #expect(flow.height == block)
        #expect(flow.remainder == "beta")
        // 前半の末尾に、消費した空白と改行 1 つが元のまま残る
        #expect(String(source.dropLast(flow.remainder.count)) == "alpha\(run)\n")
    }

    @Test("段落の末尾の空白で折っても、行数と高さは字を置いた行だけを数える")
    func theLineCountAndHeightCountOnlyPlacedLines() throws {
        let canvas = try makeCanvas()
        canvas.textLeading(20)
        let limit = canvas.textWidth("alpha")
        let block = canvas.textAscent() + canvas.textDescent()

        // 余裕のある高さ (Issue の再現)。置く字は 1 行ぶん
        let single = try pour(canvas, "alpha ", width: limit, height: block + 60)
        #expect(single.lineCount == 1)
        #expect(single.height == block)
        #expect(!single.isTruncated)

        // 段落が続いても、段落ごとに空の行を足さない
        let paragraphs = try pour(canvas, "alpha \nbeta ", width: limit, height: block + 60)
        #expect(paragraphs.lineCount == 2)
        #expect(paragraphs.height == block + 20)
        #expect(!paragraphs.isTruncated)
    }

    /// 縦の置き方。上揃えは塊の上端が矩形の上辺に来るので、末尾の空の行が増えても字の位置は
    /// 動かない — 数えない。
    nonisolated static var verticalCases: [VerticalTextAlign] { [.bottom, .center] }

    @Test(
        "段落の末尾の空白で折った塊も、下揃え・中央揃えで、語を 1 行ずつ描いた絵と一致する",
        arguments: verticalCases)
    func verticallyAlignedBlocksDoNotCountAnEmptyLine(_ vertical: VerticalTextAlign) throws {
        let words = ["alpha", "beta", "gamma"]
        let (boxX, boxY, boxHeight, leading): (Float, Float, Float, Float) = (30, 20, 180, 40)

        let poured = try makeCanvas(size: 32)
        // **幅は、最後の語がちょうど収まる大きさにする。** 最後の語の後ろの空白で溢れるので、
        // 段落の末尾の空白で折る形になる。末尾の空白が収まる幅だと空白は行に残って折れず、
        // 直す前のコードでも空の行ができない — 検査が何も見なくなる
        let last = try #require(words.last)
        let boxWidth = poured.textWidth(last).rounded(.up)
        try #require(poured.textWidth(last + " ") > boxWidth)
        // どの 1 語も収まり、2 語は収まらない。置かれる行が 1 語ずつに決まるので、期待する行を
        // 折り返しの実装から借りずに書ける
        try #require(words.allSatisfy { poured.textWidth($0) <= boxWidth })
        try #require(
            zip(words, words.dropFirst()).allSatisfy { poured.textWidth("\($0) \($1)") > boxWidth })

        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try poured.draw {
            poured.background(black)
            poured.fill(white)
            poured.textLeading(leading)
            poured.textAlign(.left, vertical)
            flow = poured.text(words.joined(separator: " ") + " ", boxX, boxY, boxWidth, boxHeight)
        }
        #expect(flow.lineCount == words.count)
        #expect(!flow.isTruncated)

        // 行の塊は、最初の行の上端 (字の高さ) から最後の行の下端 (字の深さ) まで。寸法は
        // どれも 1/64 画素の倍数なので、式の組み方を変えても浮動小数の丸めは入らない
        let byLine = try makeCanvas(size: 32)
        let ascent = byLine.textAscent()
        let block = ascent + byLine.textDescent() + Float(words.count - 1) * leading
        #expect(flow.height == block)
        let top: Float =
            switch vertical {
            case .top, .baseline: boxY
            case .center: boxY + (boxHeight - block) / 2
            case .bottom: boxY + boxHeight - block
            }
        try byLine.draw {
            byLine.background(black)
            byLine.fill(white)
            for (index, word) in words.enumerated() {
                byLine.text(word, boxX, top + ascent + Float(index) * leading)
            }
        }

        #expect(
            try poured.target.encodeForDisplay().bytes == byLine.target.encodeForDisplay().bytes)
    }
}
