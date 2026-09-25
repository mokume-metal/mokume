// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 文字の切れ目で折ったときの、切れ目の空白 ([#1424])。
///
/// **文字の切れ目でも、切れ目に続いた空白はまとめて消費する** — 語の切れ目 ([#1412]・
/// ``WrapWhitespaceTests``) と同じ扱いである。行の末尾に収まった空白も、溢れて次の行へ
/// 送られるはずだった空白も、どちらの行にも入れない。行の末尾に空白が残ると右揃え・
/// 中央揃えの行が空白の幅だけずれ、行の頭に残ると左揃えの行がその幅だけ右へずれる。
/// 段落の末尾の空白で溢れたときは、空白だけの行が 1 行に数えられて、行数と高さが 1 行
/// ぶん増える ([#1419] と同じ形)。
///
/// 段落の頭の空白 (字下げ) と、切れ目にならない行の中ほどの空白は行に残る。
///
/// 期待する行と絵は、折り返しの実装から借りずに**空白を除いた語**から書く。絵はバイト列で
/// 比べ、保存した絵とは比べない (ADR-0019 決定 4)。
///
/// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
/// [#1419]: https://github.com/mokume-metal/mokume/issues/1419
/// [#1424]: https://github.com/mokume-metal/mokume/issues/1424
@Suite(
    "文字の切れ目の空白",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct WrapCharacterBreakTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 検査で使う書体。**版が変わりにくいものを選ぶ** (``TextTests`` と同じ理由)。
    private let fontName = "Helvetica"

    private func makeCanvas(width: Int = 240, height: Int = 220, size: Float = 16) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        canvas.textFont(fontName)
        canvas.textSize(size)
        canvas.textWrap(.character)
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

    @Test("切れ目の空白で溢れても、空白はどちらの行にも入らない", arguments: [" ", "  ", "   "])
    func theOverflowingRunIsConsumed(_ run: String) throws {
        let canvas = try makeCanvas()
        // Issue の幅。「alpha」がちょうど収まり、後ろの空白で溢れる
        let limit = canvas.textWidth("alpha")
        try #require(canvas.textWidth("alpha ") > limit)

        // 続きの語の頭にも、段落の末尾にも、空白を残さない
        #expect(lines(canvas, "alpha\(run)beta", within: limit) == ["alpha", "beta"])
        #expect(lines(canvas, "alpha\(run)", within: limit) == ["alpha"])
        #expect(lines(canvas, "alpha\(run)\nbeta", within: limit) == ["alpha", "beta"])
    }

    /// 切れ目の空白のうち、行に収まったのがいくつでも同じ行になる。0 個は上の検査と同じ形で、
    /// 全部が収まれば溢れるのは次の語の 1 字目になる — 空白が行の末尾に残る形である。
    @Test("切れ目の空白が行の末尾に収まっても、空白はどちらの行にも入らない", arguments: [1, 2, 3])
    func aRunThatFitsIsConsumedToo(_ count: Int) throws {
        let canvas = try makeCanvas()
        let run = String(repeating: " ", count: count)
        for fitting in 0...count {
            let limit = canvas.textWidth("ab" + String(repeating: " ", count: fitting))
            // 収まらなかった分があれば空白で、全部が収まれば次の語の 1 字目で溢れる
            try #require(canvas.textWidth(String("ab\(run)c".prefix(2 + fitting + 1))) > limit)

            #expect(
                lines(canvas, "ab\(run)cd", within: limit) == ["ab", "cd"],
                "空白 \(count) つのうち \(fitting) つが収まる幅")
        }
    }

    // MARK: - 行に残る空白 (条件 2)

    @Test("段落の頭の空白 (字下げ) は、文字の切れ目で折っても行に残る")
    func anIndentStays() throws {
        let canvas = try makeCanvas()
        // 字下げと語の 3 字までが入り、4 字目で溢れる
        #expect(lines(canvas, "  alpha", within: canvas.textWidth("  alp")) == ["  alp", "ha"])
        // 字下げと語までが入り、後ろの空白で溢れる。消費するのは切れ目の空白だけである
        #expect(
            lines(canvas, "  alpha beta", within: canvas.textWidth("  alpha"))
                == ["  alpha", "beta"])
    }

    @Test("行の中ほどで続いた空白は、切れ目にならなければ行に残る")
    func aRunInsideALineStays() throws {
        let canvas = try makeCanvas()
        // 語の途中で折れる。1 行目の中ほどの空白 2 つも、2 行目の空白 1 つも切れ目ではない
        #expect(
            lines(canvas, "aa  bbbb cc", within: canvas.textWidth("aa  bb"))
                == ["aa  bb", "bb cc"])
        // 折れない幅なら、続いた空白はどこにあっても残る
        #expect(lines(canvas, "aa   bb  cc", within: 1000) == ["aa   bb  cc"])
    }

    // MARK: - 矩形への流し込み (条件 3)

    /// 続き (``TextFlow/remainder``) は**元の文の後ろの部分そのもの**なので、消費した空白の
    /// 数は失われない — 元の文から続きを除いた前半の末尾に、そのまま残っている。
    @Test("文字の切れ目で残った続きは、切れ目の空白の先の字から始まる", arguments: [" ", "  ", "   "])
    func theRemainderStartsAfterTheRun(_ run: String) throws {
        let canvas = try makeCanvas()
        let limit = canvas.textWidth("alpha")
        // 1 行ぶんの高さ
        let block = canvas.textAscent() + canvas.textDescent()
        let source = "alpha\(run)beta"

        let flow = try pour(canvas, source, width: limit, height: block)
        #expect(flow.lineCount == 1)
        #expect(flow.height == block)
        #expect(flow.remainder == "beta")
        // 前半の末尾に、消費した空白が元の数のまま残る
        #expect(String(source.dropLast(flow.remainder.count)) == "alpha\(run)")
    }

    @Test("段落の末尾の空白で溢れても、行数と高さは字を置いた行だけを数える")
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

        // 段落が続いても、段落ごとに空白だけの行を足さない
        let paragraphs = try pour(canvas, "alpha \nbeta ", width: limit, height: block + 60)
        #expect(paragraphs.lineCount == 2)
        #expect(paragraphs.height == block + 20)
        #expect(!paragraphs.isTruncated)
    }

    /// 横の置き方と、切れ目の空白。**空白 1 つは右揃え・中央揃えだけ**で見る — 行の末尾に
    /// 収まった空白は、左揃えでは見えない。空白 2 つは 1 つ目が行の末尾に収まり、2 つ目が
    /// 溢れる幅なので、直す前は次の行の頭にも空白が来て、左揃えでも行がずれる。
    nonisolated static var alignmentCases: [(horizontal: HorizontalTextAlign, run: String)] {
        [(.left, "  "), (.center, " "), (.center, "  "), (.right, " "), (.right, "  ")]
    }

    @Test(
        "文字の切れ目で折った行も、左・中央・右揃えで、空白を除いた語を 1 行ずつ描いた絵と一致する",
        arguments: alignmentCases)
    func alignedLinesDoNotCountTheBreakingRun(
        _ sample: (horizontal: HorizontalTextAlign, run: String)
    ) throws {
        // **送り幅の揃った語を並べる。** どの語の後ろにも空白 1 つだけが収まる幅を 1 つに
        // 決めるには、語の幅の差が空白 1 つの幅より小さくなければならない
        let words = ["bone", "dune", "hope"]
        let (boxX, boxY, boxHeight, leading): (Float, Float, Float, Float) = (30, 20, 180, 40)

        let poured = try makeCanvas(size: 32)
        // **幅は、どの語の後ろにも空白 1 つが収まり、2 つは収まらない大きさにする。** 空白
        // 1 つが収まらないと、直す前のコードでも行の末尾に空白が入らない — 検査が何も
        // 見なくなる
        let followed = words.dropLast()
        let boxWidth = try #require(followed.map { poured.textWidth($0 + " ") }.max()).rounded(.up)
        try #require(followed.allSatisfy { poured.textWidth($0 + "  ") > boxWidth })
        try #require(words.allSatisfy { poured.textWidth($0) <= boxWidth })
        // 空白の次の字は収まらない。語の中で折れず、置かれる行が 1 語ずつに決まるので、
        // 期待する行を折り返しの実装から借りずに書ける
        try #require(
            zip(words, words.dropFirst()).allSatisfy {
                poured.textWidth("\($0) \($1.prefix(1))") > boxWidth
            })

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

        // 上揃えなので、最初の行の上端が矩形の上辺に来る
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
