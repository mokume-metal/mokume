// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 改行しない空白の折り返し ([#1540])。
///
/// **改行しない空白 (U+00A0・U+202F・U+2007) は、字と同じに扱う。** Unicode の改行規則
/// (UAX #14) で、この 3 つは前後で折らない類 (GL) である。「10 km」のように、切らないために
/// 置く空白である。Swift の `Character.isWhitespace` はこの 3 つにも true を返すので、流し込みは
/// ここで語を切り、切れ目の後ろなら消費し、行末なら削っていた。
///
/// 期待する行は、折り返しの実装から借りずに文字列から書く。
///
/// [#1540]: https://github.com/mokume-metal/mokume/issues/1540
@Suite(
    "改行しない空白の折り返し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct WrapNoBreakSpaceTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 改行しない空白。NO-BREAK SPACE・NARROW NO-BREAK SPACE・FIGURE SPACE。
    nonisolated static var noBreakSpaces: [String] { ["\u{00A0}", "\u{202F}", "\u{2007}"] }

    /// 折る空白。SPACE・THIN SPACE・IDEOGRAPHIC SPACE・タブ。
    nonisolated static var breakingSpaces: [String] { [" ", "\u{2009}", "\u{3000}", "\t"] }

    /// Issue の条件どおり、既定の書体・大きさ 20・左上揃えにする。
    private func makeCanvas() throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        canvas.textSize(20)
        canvas.textAlign(.left, .top)
        return canvas
    }

    /// 1 行だけ入る高さの矩形へ流し込んで、結果を受け取る。
    private func pour(_ canvas: Canvas, _ source: String, width: Float) throws -> TextFlow {
        let height = canvas.textAscent() + canvas.textDescent() + 1
        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text(source, 10, 10, width, height)
        }
        return flow
    }

    // MARK: - 語の切れ目 (条件 1〜3)

    @Test("改行しない空白では折らず、1 語として語の中で折る", arguments: noBreakSpaces)
    func aNoBreakSpaceIsNotABreak(_ space: String) throws {
        let canvas = try makeCanvas()
        let width = canvas.textWidth("aaaa" + space + "bb") + 0.5
        let flow = try pour(canvas, "aaaa" + space + "bbbb", width: width)
        #expect(flow.lineCount == 1)
        #expect(flow.remainder == "bb")
    }

    @Test("2 語なら、改行しない空白ではなく普通の空白のほうで折る")
    func twoWordsBreakAtTheOrdinarySpace() throws {
        let canvas = try makeCanvas()
        let first = try pour(
            canvas, "xx aaaa\u{00A0}bbbb", width: canvas.textWidth("xx aaaa\u{00A0}b") + 0.5)
        #expect(first.remainder == "aaaa\u{00A0}bbbb")

        let second = try pour(
            canvas, "dist 10\u{00A0}km", width: canvas.textWidth("dist 10\u{00A0}k") + 0.5)
        #expect(second.remainder == "10\u{00A0}km")
    }

    @Test("折る空白は、いままでどおり折る", arguments: breakingSpaces)
    func aBreakingSpaceStillBreaks(_ space: String) throws {
        let canvas = try makeCanvas()
        let width = canvas.textWidth("aaaa" + space + "bb") + 0.5
        let flow = try pour(canvas, "aaaa" + space + "bbbb", width: width)
        #expect(flow.remainder == "bbbb")
    }

    @Test("改行しない空白の直後の普通の空白は、切れ目になる")
    func anOrdinarySpaceAfterANoBreakSpaceBreaks() throws {
        let canvas = try makeCanvas()
        // 切れ目は「字の後ろの空白」に置く。改行しない空白は字なので、その後ろの空白も切れ目
        let flow = try pour(
            canvas, "aaaa\u{00A0} bbbb", width: canvas.textWidth("aaaa\u{00A0} bb") + 0.5)
        #expect(flow.remainder == "bbbb")
    }

    @Test("語の切れ目の後ろに続いた改行しない空白は、消費せず次の行の頭に残す")
    func theWordBreakKeepsAFollowingNoBreakSpace() throws {
        let canvas = try makeCanvas()
        let flow = try pour(canvas, "xx \u{00A0}aaaa", width: canvas.textWidth("xx \u{00A0}a") + 0.5)
        #expect(flow.remainder == "\u{00A0}aaaa")
    }

    // MARK: - 文字の切れ目 (条件 4)

    @Test("文字の切れ目でも、改行しない空白は消費せず次の行の頭に残す")
    func theCharacterBreakKeepsANoBreakSpace() throws {
        let canvas = try makeCanvas()
        canvas.textWrap(.character)
        let flow = try pour(canvas, "aaaa\u{00A0}bbbb", width: canvas.textWidth("aaaa") + 0.5)
        #expect(flow.lineCount == 1)
        #expect(flow.remainder == "\u{00A0}bbbb")
    }

    @Test("文字の切れ目で改行しない空白で終わった行は、字で終わった行と同じく溢れた空白を消費する")
    func aLineEndingInANoBreakSpaceConsumesTheOverflowingSpace() throws {
        let canvas = try makeCanvas()
        canvas.textWrap(.character)
        let flow = try pour(
            canvas, "aaa\u{00A0} bbbb", width: canvas.textWidth("aaa\u{00A0}") + 0.5)
        #expect(flow.remainder == "bbbb")
    }

    // MARK: - 行末 (条件 5)

    /// 右揃えで矩形 (10, 10, 140, 60) へ置いた墨の右端。何も描かれなければ `nil`。
    private func inkRight(_ source: String) throws -> Int? {
        let canvas = try makeCanvas()
        canvas.textAlign(.right, .top)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text(source, 10, 10, 140, 60)
        }
        let image = try canvas.target.encodeForDisplay()
        var right: Int?
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].red > 8 {
                right = max(right ?? x, x)
            }
        }
        return right
    }

    @Test("行末の改行しない空白は削らず、右揃えの行がその幅だけ左へ寄る")
    func aTrailingNoBreakSpaceIsKept() throws {
        let plain = try #require(try inkRight("ab"))
        let kept = try #require(try inkRight("ab\u{00A0}"))
        let space = try makeCanvas().textWidth("\u{00A0}")
        #expect(abs(Float(plain - kept) - space) <= 1)
        // 普通の空白は、いままでどおり削る ([#1452])
        #expect(try inkRight("ab ") == plain)
    }
}
