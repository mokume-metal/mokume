// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `.word` の切れ目を Unicode の行分割の規則 (UAX #14) で決めたときの折り返し ([#2448])。
///
/// **折る位置は、空白だけでなく和文の字と字の間にも立つ。** 行頭に「、」「。」「」」が来ず、
/// 行末に「「」が残らず、和欧混在の文が空白の手前で短く切れない。位置の計算は字ごとの送り幅の
/// 和のままで、期待する行は折り返しの実装から借りずに、**行の性質** (行頭・行末の字・幅に
/// 収まる最後の切れ目まで詰まっていること・並べ直すと元の文に戻ること) から書く。
///
/// 送り幅は CoreText の値なので、書体と大きさを固定する。
///
/// [#2448]: https://github.com/mokume-metal/mokume/issues/2448
@Suite(
    "語の切れ目 (UAX #14)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct WrapWordBreakTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 検査で使う書体。**版が変わりにくいものを選ぶ** (``TextTests`` と同じ理由)。
    private let fontName = "Helvetica"

    /// 参照スケッチと docc の流し込みの例文。
    private let paragraph =
        "矩形へ流し込むと、指定した幅で折り返し、指定した高さに収まる行だけが置かれる。入りきらなかった分は remainder に残るので、続きを別の場所へ流せる。"

    /// 同じ文から欧文の語 (と、その前後の空白) を除いたもの。
    private let noSpaces =
        "矩形へ流し込むと、指定した幅で折り返し、指定した高さに収まる行だけが置かれる。入りきらなかった分は続きに残るので、続きを別の場所へ流せる。"

    private func makeCanvas(size: Float) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 240, height: 220)
        canvas.textFont(fontName)
        canvas.textSize(size)
        return canvas
    }

    private func lines(_ canvas: Canvas, _ source: String, within limit: Float) -> [String] {
        canvas.wrapped(source, face: canvas.typeface, within: limit).map(String.init)
    }

    /// 矩形へ流し込んで、返った結果を受け取る。
    private func pour(
        _ canvas: Canvas, _ source: String, x: Float = 0, width: Float, height: Float
    ) throws -> TextFlow {
        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text(source, x, 0, width, height)
        }
        return flow
    }

    private static let noLineStart: Set<Character> = ["、", "。", "」"]
    private static let noLineEnd: Set<Character> = ["「"]

    // MARK: - 行頭・行末の禁則 (条件 1)

    @Test(
        "本文の作例と docc の例文は、どの行も「、」「。」「」」で始まらない",
        arguments: [(Float(17), Float(130)), (Float(18), Float(160)), (Float(18), Float(150))])
    func noLineStartsWithClosingPunctuation(_ size: Float, _ width: Float) throws {
        let canvas = try makeCanvas(size: size)
        let result = lines(canvas, paragraph, within: width)
        try #require(result.count > 3)
        for line in result {
            #expect(!Self.noLineStart.contains(line.first!), "行頭に句読点: \(line)")
        }
        // 折っても字は 1 つも落ちない。落ちうるのは、空白で折った切れ目の空白だけ
        #expect(result.joined().filter { $0 != " " } == paragraph.filter { $0 != " " })
        // 空白の無い和文の切れ目は何も消費しない
        #expect(lines(canvas, noSpaces, within: width).joined() == noSpaces)
    }

    @Test("変更前は 2 行目が「、指定した幅で折」で始まった例が、「と、」ごと次の行へ送られる")
    func theReportedLineNoLongerStartsWithTheComma() throws {
        let canvas = try makeCanvas(size: 18)
        let result = lines(canvas, paragraph, within: 160)
        #expect(result.contains { $0.hasPrefix("、指定した幅で折") } == false)
        // 「と」と「、」は同じ行に並ぶ
        let line = try #require(result.first { $0.contains("、指定した幅") })
        #expect(line.contains("と、指定した幅"))
    }

    @Test("行末に「「」が残らず、「「」は次の字と同じ行に置かれる")
    func noLineEndsWithAnOpeningBracket() throws {
        let canvas = try makeCanvas(size: 17)
        let source = "あいう「えお」かき"
        // 「あいう「」までは入り、「え」で溢れる幅 — 空白だけの切れ目なら「「」で行が終わる
        let limit = canvas.textWidth("あいう「") + 1
        try #require(canvas.textWidth("あいう「え") > limit)

        let result = lines(canvas, source, within: limit)
        for line in result {
            #expect(!Self.noLineEnd.contains(line.last!), "行末に始め括弧: \(line)")
        }
        #expect(result.first == "あいう")
        #expect(result.joined() == source)
    }

    @Test("行頭に来そうな「。」と「」」は、前の字ごと次の行へ送られる")
    func aFullStopAndAClosingBracketTravelWithTheirLetter() throws {
        let canvas = try makeCanvas(size: 17)
        for (source, tail) in [("あいうえお。かき", "お。"), ("あいう「え」かき", "え」")] {
            // 「あいうえお」(「あいう「え」」) までは入り、「。」(「」」) で溢れる幅
            let fitting = String(source.prefix(while: { $0 != tail.last! }))
            let limit = canvas.textWidth(fitting) + 1
            try #require(canvas.textWidth(fitting + String(tail.last!)) > limit)

            let result = lines(canvas, source, within: limit)
            for line in result {
                #expect(!Self.noLineStart.contains(line.first!), "行頭に句読点: \(line)")
            }
            #expect(result.contains { $0.contains(tail) })
            #expect(result.joined() == source)
        }
    }

    // MARK: - 和欧混在 (条件 2)

    @Test("和欧混在の文は、幅に収まる最後の切れ目まで 1 行目に詰まる")
    func aMixedSentencePacksTheFirstLine() throws {
        let canvas = try makeCanvas(size: 18)
        let source = "今日は mokume を使って長い日本語の文章を枠へ流し込んで折り返しを確かめる"
        let result = lines(canvas, source, within: 200)
        let first = try #require(result.first)

        // 変更前の 1 行目は「今日は mokume」(幅 124/200)。空白の手前で短く切れていた
        #expect(first.count > "今日は mokume".count)
        #expect(first.hasPrefix("今日は mokume を"))
        #expect(canvas.textWidth(first) <= 200)
        // 次の字を足すと溢れる = 収まる最後の切れ目まで詰まっている
        let following = result[1].first!
        #expect(canvas.textWidth(first + String(following)) > 200)
        // 全体は、空白 1 つ (「は mokume」の前後の切れ目で消費したもの) を除いて元に戻る
        #expect(result.joined().filter { $0 != " " } == source.filter { $0 != " " })
    }

    // MARK: - 欧文 (条件 3)

    @Test("欧文だけの文は空白の後ろで折れ、折り位置は空白で数えたときと同じ")
    func latinTextStillBreaksAtSpaces() throws {
        let canvas = try makeCanvas(size: 16)
        let source = "the quick brown fox jumps over the lazy dog again and again"
        let limit = canvas.textWidth("the quick brown ") + 1
        let result = lines(canvas, source, within: limit)

        #expect(result.first == "the quick brown")
        #expect(result.allSatisfy { $0.first != " " && $0.last != " " })
        #expect(result.joined(separator: " ") == source)
    }

    @Test("改行しない空白は、和文に挟まれても前後で折らない")
    func noBreakSpaceStaysTogetherBesideJapanese() throws {
        let canvas = try makeCanvas(size: 17)
        let source = "あいう10\u{00A0}kmえお"
        // 「あいう10」までは入り、NBSP で溢れる幅 — NBSP が切れ目なら「10」で行が終わる
        let limit = canvas.textWidth("あいう10") + 1
        try #require(canvas.textWidth("あいう10\u{00A0}") > limit)

        let result = lines(canvas, source, within: limit)
        #expect(!result.contains { $0.hasSuffix("10") })
        #expect(!result.contains { $0.hasPrefix("km") })
        #expect(result.joined() == source)
    }

    // MARK: - 語が幅より長いとき (条件 5)

    @Test("1 語が幅より長いときは、その語の中の字の切れ目へ倒れる")
    func aWordLongerThanTheWidthBreaksInsideIt() throws {
        let canvas = try makeCanvas(size: 16)
        let word = "abcdefghijklmnopqrstuvwxyz"
        let source = "あ\(word)い"
        let limit = canvas.textWidth("abcdefgh") + 1
        try #require(canvas.textWidth(word) > limit)

        let result = lines(canvas, source, within: limit)
        #expect(result.count >= 3)
        #expect(result.allSatisfy { canvas.textWidth($0) <= limit })
        #expect(result.joined() == source)
    }

    @Test("字下げの空白は切れ目にならず、行に残る")
    func theIndentationStays() throws {
        let canvas = try makeCanvas(size: 17)
        let source = "  あいうえおかきくけこ"
        let result = lines(canvas, source, within: canvas.textWidth("  あいう") + 1)
        #expect(result.first?.hasPrefix("  あ") == true)
        #expect(result.joined() == source)
    }

    // MARK: - remainder (条件 4)

    @Test("3 つの枠へ remainder で渡すと、置いた行と残りを連ねて元の文に戻る")
    func threeFramesCarryTheTextWithoutLoss() throws {
        let canvas = try makeCanvas(size: 17)
        var rest = noSpaces
        var placed: [String] = []
        for _ in 0..<3 {
            let flow = try pour(canvas, rest, width: 130, height: 60)
            try #require(flow.lineCount > 0)
            let all = canvas.wrapped(rest, face: canvas.typeface, within: 130)
            placed += all.prefix(flow.lineCount).map(String.init)
            rest = flow.remainder
            if let first = rest.first {
                #expect(!Self.noLineStart.contains(first), "続きが句読点から始まる: \(rest)")
            }
        }
        // 空白の無い和文の切れ目では何も消費しないので、連ねると元の文そのものに戻る
        #expect(placed.joined() + rest == noSpaces)
        #expect(!rest.isEmpty)
    }

    @Test("空白で折った切れ目では、続いた空白だけが消費され、残りは次の語から始まる")
    func spacesAtTheBreakAreTheOnlyThingConsumed() throws {
        let canvas = try makeCanvas(size: 17)
        let source = "今日は  mokume  を使って  長い文章を枠へ流し込んで確かめる"
        var rest = source
        var consumed = ""
        for _ in 0..<4 where !rest.isEmpty {
            let flow = try pour(canvas, rest, width: 130, height: 40)
            try #require(flow.lineCount > 0)
            let kept = String(rest.dropLast(flow.remainder.count))
            consumed += kept
            rest = flow.remainder
            if let first = rest.first { #expect(first != " ") }
        }
        #expect(consumed.filter { $0 != " " } + rest.filter { $0 != " " } == source.filter { $0 != " " })
    }

    // MARK: - .character は変えない (条件 6)

    @Test("`.character` は規則を見ず、どの字の間でも折る")
    func characterWrapIgnoresTheRules() throws {
        let canvas = try makeCanvas(size: 17)
        canvas.textWrap(.character)
        let limit = canvas.textWidth("あ") + 1
        let result = lines(canvas, "あ、い", within: limit)
        #expect(result == ["あ", "、", "い"])
    }
}
