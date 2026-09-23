// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 段落の最後の行の末尾の空白 ([#1452])。
///
/// **段落の最後の行も、末尾の空白を行に入れない。** 切れ目で折った行は、切れ目に続いた
/// 空白を消費する ([#1412]・[#1424])。段落の終わりに達した行は切れ目で折らないので、末尾の
/// 空白がそのまま行に残っていた — 右揃えではその空白の幅だけ、中央揃えではその半分だけ、
/// 行が左へずれる。折らない 1 行でも、改行で区切った各段落でも、折った後の最後の行でも
/// 同じ形になる。
///
/// 段落の頭の空白 (字下げ) と、空白だけの段落は行に残る。範囲は矩形の流し込みだけで、
/// ``Canvas/textWidth(_:)`` と点の形の ``Canvas/text(_:_:_:)`` は末尾の空白も数える —
/// 作者が渡した文字列を、作者が選んだ位置で終わらせる形だからである。
///
/// 期待する行と絵は、折り返しの実装から借りずに**空白を除いた語**から書く。絵はバイト列で
/// 比べ、保存した絵とは比べない (ADR-0019 決定 4)。
///
/// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
/// [#1424]: https://github.com/mokume-metal/mokume/issues/1424
/// [#1452]: https://github.com/mokume-metal/mokume/issues/1452
@Suite(
    "段落の最後の行の末尾の空白",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct WrapLineEndTests {
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

    /// Issue の再現を 1 枚描く。大きさ 28 で、`(0, 60)` から幅 150・高さ 60 の矩形へ流す。
    private func issueShot(
        _ source: String, _ horizontal: HorizontalTextAlign
    ) throws -> (flow: TextFlow, bytes: [UInt8]) {
        let canvas = try makeCanvas(size: 28)
        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textAlign(horizontal, .top)
            flow = canvas.text(source, 0, 60, 150, 60)
        }
        return (flow, try canvas.target.encodeForDisplay().bytes)
    }

    /// 2 枚の絵で、色の違う画素の数。**0 ならバイト列で一致する。** 違ったときに何画素
    /// ずれたかを読めるよう、バイト列をそのまま比べずに数える。
    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) throws -> Int {
        try #require(a.count == b.count)
        return stride(from: 0, to: a.count, by: 4).count { a[$0..<$0 + 4] != b[$0..<$0 + 4] }
    }

    /// 末尾に続く空白の数。
    nonisolated static var runs: [String] { [" ", "  ", "   "] }

    /// 折り方と、末尾に続く空白。
    nonisolated static var wrapCases: [(wrap: TextWrap, run: String)] {
        [TextWrap.word, .character].flatMap { wrap in runs.map { (wrap, $0) } }
    }

    // MARK: - 行への切り分け (条件 1)

    @Test("折らない段落の最後の行は、末尾の空白を行に入れない", arguments: wrapCases)
    func anUnbrokenParagraphDropsItsTrailingRun(_ sample: (wrap: TextWrap, run: String)) throws {
        let canvas = try makeCanvas()
        canvas.textWrap(sample.wrap)
        let run = sample.run

        // 折らない 1 行
        #expect(lines(canvas, "mokume\(run)", within: 1000) == ["mokume"])
        // 改行で区切った各段落 (段落の終わりの改行の手前でも、文の終わりでも)
        #expect(lines(canvas, "mokume\(run)\nmetal ", within: 1000) == ["mokume", "metal"])
        #expect(lines(canvas, "mokume\(run)\nmetal\(run)", within: 1000) == ["mokume", "metal"])
    }

    @Test("折った後の最後の行も、末尾の空白を行に入れない", arguments: wrapCases)
    func theLastLineAfterABreakDropsItsTrailingRun(_ sample: (wrap: TextWrap, run: String)) throws {
        let canvas = try makeCanvas()
        canvas.textWrap(sample.wrap)
        let run = sample.run
        // **幅は、最後の行が末尾の空白ごと収まる `beta` + 空白の幅にする。** 空白で溢れると
        // 切れ目で折る形になり、直す前のコードでも空白は行に入らない — 検査が何も見なくなる。
        // 空白 1 つでは、その幅に alpha が収まらない (`beta ` のほうが狭い) ので、alpha の幅まで
        // 広げる。広げても `beta` + 空白は収まったままである
        let limit = max(canvas.textWidth("beta" + run), canvas.textWidth("alpha"))
        try #require(canvas.textWidth("beta" + run) <= limit)
        // alpha は収まり、alpha beta は収まらない。置かれる行が 1 語ずつに決まるので、期待する
        // 行を折り返しの実装から借りずに書ける
        try #require(canvas.textWidth("alpha") <= limit)
        try #require(canvas.textWidth("alpha beta") > limit)

        #expect(lines(canvas, "alpha beta\(run)", within: limit) == ["alpha", "beta"])
    }

    // MARK: - 矩形への流し込み (条件 2)

    /// 横の置き方と、末尾に続く空白。左揃えは行の末尾の空白が見えないので、条件 3 で別に見る。
    nonisolated static var alignedCases: [(horizontal: HorizontalTextAlign, run: String)] {
        [HorizontalTextAlign.right, .center].flatMap { horizontal in
            runs.map { (horizontal, $0) }
        }
    }

    @Test(
        "右揃え・中央揃えで流し込んだ最後の行は、末尾の空白が無い行と同じ絵になる",
        arguments: alignedCases)
    func alignedLastLinesDoNotCountTheTrailingRun(
        _ sample: (horizontal: HorizontalTextAlign, run: String)
    ) throws {
        let spaced = try issueShot("mokume\(sample.run)", sample.horizontal)
        let bare = try issueShot("mokume", sample.horizontal)
        // どちらも折らずに 1 行だけ置く
        #expect(spaced.flow == TextFlow(lineCount: 1, height: spaced.flow.height, remainder: ""))
        #expect(bare.flow == spaced.flow)
        // 字が描かれている (どちらも下地だけなら、比べても何も見ない)
        #expect(stride(from: 0, to: bare.bytes.count, by: 4).contains { bare.bytes[$0] > 0 })

        let differing = try differingPixels(spaced.bytes, bare.bytes)
        #expect(differing == 0)
    }

    // MARK: - 変えないもの (条件 3)

    @Test("左揃えで流し込んだ最後の行は、いままでどおり末尾の空白が無い行と同じ絵になる", arguments: runs)
    func leftAlignedLastLinesStayTheSame(_ run: String) throws {
        let spaced = try issueShot("mokume\(run)", .left)
        let bare = try issueShot("mokume", .left)
        #expect(spaced.flow.lineCount == 1)
        let differing = try differingPixels(spaced.bytes, bare.bytes)
        #expect(differing == 0)
    }

    @Test("段落の頭の空白 (字下げ) は、最後の行でも行に残る", arguments: [TextWrap.word, .character])
    func anIndentStaysOnTheLastLine(_ wrap: TextWrap) throws {
        let canvas = try makeCanvas()
        canvas.textWrap(wrap)
        #expect(lines(canvas, "  mokume  ", within: 1000) == ["  mokume"])
    }

    @Test("空白だけの段落は、空白ごと 1 行に数える", arguments: [TextWrap.word, .character])
    func aParagraphOfOnlySpacesStaysOneLine(_ wrap: TextWrap) throws {
        let canvas = try makeCanvas()
        canvas.textWrap(wrap)
        canvas.textLeading(20)
        let source = "alpha\n   \nbeta"
        #expect(lines(canvas, source, within: 1000) == ["alpha", "   ", "beta"])

        // 3 行入る矩形へ流すと、3 行とも置く
        let block = canvas.textAscent() + canvas.textDescent()
        let flow = try pour(canvas, source, width: 1000, height: block + 40)
        #expect(flow.lineCount == 3)
        #expect(flow.height == block + 40)
        #expect(!flow.isTruncated)
    }

    /// 続き (``TextFlow/remainder``) は次の行の**頭**から取るので、最後の行の末尾を削っても
    /// 変わらない。削った空白は、元の文から続きを除いた前半の末尾に、そのまま残っている。
    @Test("最後の行の末尾の空白を削っても、続きは次の段落の先頭から始まる", arguments: runs)
    func theRemainderStaysTheSame(_ run: String) throws {
        let canvas = try makeCanvas()
        // 1 行ぶんの高さ
        let block = canvas.textAscent() + canvas.textDescent()
        let source = "mokume\(run)\nmetal"

        let flow = try pour(canvas, source, width: 1000, height: block)
        #expect(flow.lineCount == 1)
        #expect(flow.height == block)
        #expect(flow.remainder == "metal")
        #expect(String(source.dropLast(flow.remainder.count)) == "mokume\(run)\n")
    }

    // MARK: - 同じ読み戻し (条件 4)

    /// 末尾の空白の読み戻しは、段落の終わりと文字の切れ目 ([#1424]) で同じものを使う。
    /// **行の頭から空白しか無ければ読み戻さない** — 段落の終わりでは上の空白だけの段落が、
    /// 文字の切れ目では字下げだけで溢れた行がそれに当たる。字下げは切れ目ではないので、
    /// 溢れても空白を消費しない。
    @Test("字下げだけで溢れた行は、文字の切れ目でも空白を消費しない", arguments: [TextWrap.word, .character])
    func anIndentThatOverflowsIsNotConsumed(_ wrap: TextWrap) throws {
        let canvas = try makeCanvas()
        canvas.textWrap(wrap)
        // 字下げの空白 2 つまでが入り、3 つ目で溢れる。語の切れ目も無いので、どちらの折り方
        // でも文字の切れ目で折る
        let limit = canvas.textWidth("  ")
        try #require(canvas.textWidth("   ") > limit)

        let result = lines(canvas, "   ab", within: limit)
        #expect(result.first == "  ")
        // 空白は 1 つも消費されず、行を繋ぐと元の文に戻る
        #expect(result.joined() == "   ab")
    }

    // MARK: - 矩形の外 (条件 5)

    @Test("文字列の幅は、いままでどおり末尾の空白も数える")
    func textWidthStillCountsTheTrailingRun() throws {
        let canvas = try makeCanvas()
        #expect(
            canvas.textWidth("mokume  ") == canvas.textWidth("mokume") + 2 * canvas.textWidth(" "))
    }

    @Test("点の形で右揃えに描いた文字列は、いままでどおり末尾の空白の幅だけ左へ寄る")
    func pointTextStillCountsTheTrailingRun() throws {
        let spaced = try makeCanvas()
        try spaced.draw {
            spaced.background(black)
            spaced.fill(white)
            spaced.textAlign(.right)
            spaced.text("mokume  ", 150, 100)
        }

        let shifted = try makeCanvas()
        let space = shifted.textWidth(" ")
        try shifted.draw {
            shifted.background(black)
            shifted.fill(white)
            shifted.textAlign(.right)
            shifted.text("mokume", 150 - 2 * space, 100)
        }

        let differing = try differingPixels(
            spaced.target.encodeForDisplay().bytes, shifted.target.encodeForDisplay().bytes)
        #expect(differing == 0)
    }
}
