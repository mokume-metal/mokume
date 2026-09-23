// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 語の切れ目に空白が続くときの折り返し ([#1412])。
///
/// **切れ目に続いた空白は、まとめて消費される。** 溢れる直前に見た空白 1 つだけを切れ目に
/// すると、それより前の空白が行の末尾に残り、行の幅が空白の分だけ広く数えられる — 矩形の
/// 中で右揃え・中央揃えにした行が、その幅だけ左へずれる。
///
/// 期待する行と絵は、折り返しの実装から借りずに**空白を除いた語**から書く。絵はバイト列で
/// 比べ、保存した絵とは比べない (ADR-0019 決定 4)。
///
/// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
@Suite(
    "語の切れ目に続いた空白",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct WrapWhitespaceTests {
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

    // MARK: - 行への切り分け (条件 1)

    @Test("溢れたのが続いた空白の 2 つ目でも、続いた空白はどちらの行にも入らない")
    func aRunOverflowingAtItsSecondSpaceIsConsumedWhole() throws {
        let canvas = try makeCanvas()
        // 「aa bb 」までは入り、2 つ目の空白で溢れる ([#1412] の再現そのもの)
        let limit = canvas.textWidth("aa bb ") + 1
        try #require(canvas.textWidth("aa bb  ") > limit)

        let result = lines(canvas, "aa bb  cc", within: limit)
        #expect(result == ["aa bb", "cc"])
        // 行の幅は、空白を除いた語の幅そのもの
        #expect(result.map { canvas.textWidth($0) } == ["aa bb", "cc"].map { canvas.textWidth($0) })
    }

    @Test(
        "溢れたのが続いた空白の後の字でも、続いた空白はどちらの行にも入らない",
        arguments: ["  ", "   "])
    func aRunBeforeTheOverflowingLetterIsConsumedWhole(_ run: String) throws {
        let canvas = try makeCanvas()
        // 続いた空白と次の語の 1 字目までは入り、2 字目で溢れる
        let limit = canvas.textWidth("aa bb\(run)c") + 0.5
        try #require(canvas.textWidth("aa bb\(run)cc") > limit)

        #expect(lines(canvas, "aa bb\(run)cc", within: limit) == ["aa bb", "cc"])
    }

    @Test("行の中ほどで続いた空白は、切れ目にならなければ行に残る")
    func aRunInsideALineStays() throws {
        let canvas = try makeCanvas()
        // 「aa  bb」までが 1 行に入り、その後の空白で溢れる。どちらの行にも、切れ目に
        // ならない続いた空白がある
        let limit = canvas.textWidth("aa  bb")
        #expect(lines(canvas, "aa  bb  cc  dd", within: limit) == ["aa  bb", "cc  dd"])
        // 折れない幅なら、続いた空白はどこにあっても残る
        #expect(lines(canvas, "aa   bb  cc", within: 1000) == ["aa   bb  cc"])
    }

    /// 段落の頭の空白は、前に語が無いので語の切れ目ではない。**字下げの途中で折ると、
    /// 空白だけの行ができる** — 続いた空白の前のほうが行に残るのと同じ形である。
    @Test("段落の頭の空白 (字下げ) は切れ目にならず、最初の語と同じ行に残る")
    func anIndentIsNotABreak() throws {
        let canvas = try makeCanvas()
        // 字下げと最初の語の 2 字までが入り、3 字目で溢れる。語の切れ目が無いので、
        // 1 語が幅より長いときと同じく語の中で折る
        let limit = canvas.textWidth("  aa")
        #expect(lines(canvas, "  aaaa", within: limit) == ["  aa", "aa"])
    }

    // MARK: - 続き

    /// 続き (``TextFlow/remainder``) は**元の文の後ろの部分そのもの**なので、消費した空白の
    /// 数は失われない — 元の文から続きを除いた前半の末尾に、そのまま残っている。
    @Test("続いた空白の切れ目で残った続きは、次の語から始まり、消費した空白の数を元の文から読める")
    func theRemainderAfterARunStartsAtTheNextWord() throws {
        let canvas = try makeCanvas()
        let words = ["alpha", "beta", "gamma", "delta"]
        // 1 つ目の切れ目は空白 2 つ、置いた行と続きの間の切れ目は空白 3 つ
        let source = "alpha  beta   gamma delta"
        // 1 語ずつの行になる幅
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
        #expect(flow.remainder == "gamma delta")
        let placed = source.dropLast(flow.remainder.count)
        #expect(placed.reversed().prefix(while: \.isWhitespace).count == 3)
        #expect(placed + flow.remainder == source)
    }

    // MARK: - 矩形への流し込み (条件 2)

    /// 横の置き方と、切れ目に続く空白。左揃えは行の末尾の空白が見えないので数えない。
    nonisolated static var runCases: [(horizontal: HorizontalTextAlign, run: String)] {
        [HorizontalTextAlign.center, .right].flatMap { horizontal in
            ["  ", "   "].map { (horizontal, $0) }
        }
    }

    @Test(
        "切れ目に空白が続いた行も、右揃え・中央揃えで、空白を除いた語を 1 行ずつ描いた絵と一致する",
        arguments: runCases)
    func alignedLinesDoNotCountTheConsumedRun(
        _ sample: (horizontal: HorizontalTextAlign, run: String)
    ) throws {
        let words = ["alpha", "beta", "gamma"]
        let (boxX, boxY, boxHeight, leading): (Float, Float, Float, Float) = (30, 20, 180, 40)

        let poured = try makeCanvas(size: 32)
        // **幅は、どの 1 語も収まり、2 語は収まらない大きさにする。** 置かれる行が 1 語ずつに
        // 決まるので、期待する行を折り返しの実装から借りずに書ける
        let widest = try #require(words.map { poured.textWidth($0) }.max())
        let boxWidth = (widest + 8).rounded(.up)
        try #require(
            zip(words, words.dropFirst()).allSatisfy { poured.textWidth("\($0) \($1)") > boxWidth })
        // **切れ目の語の後ろに空白 1 つが収まる幅でもある。** 収まらないと溢れるのが続いた
        // 空白の 1 つ目になり、直す前のコードでも空白が行に入らない — 検査が何も見なくなる
        try #require(words.dropLast().allSatisfy { poured.textWidth($0 + " ") <= boxWidth })

        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try poured.draw {
            poured.background(black)
            poured.fill(white)
            poured.textLeading(leading)
            poured.textAlign(sample.horizontal, .top)
            flow = poured.text(words.joined(separator: sample.run), boxX, boxY, boxWidth, boxHeight)
        }
        #expect(flow.lineCount == words.count)
        #expect(!flow.isTruncated)

        // 上揃えなので、最初の行の上端が矩形の上辺に来る。寸法はどれも 1/64 画素の倍数
        // なので、式の組み方を変えても浮動小数の丸めは入らない
        let byLine = try makeCanvas(size: 32)
        let ascent = byLine.textAscent()
        try byLine.draw {
            byLine.background(black)
            byLine.fill(white)
            for (index, word) in words.enumerated() {
                let width = byLine.textWidth(word)
                let x: Float =
                    switch sample.horizontal {
                    case .left: boxX
                    case .center: boxX + (boxWidth - width) / 2
                    case .right: boxX + boxWidth - width
                    }
                byLine.text(word, x, boxY + ascent + Float(index) * leading)
            }
        }

        #expect(
            try poured.target.encodeForDisplay().bytes == byLine.target.encodeForDisplay().bytes)
    }
}
