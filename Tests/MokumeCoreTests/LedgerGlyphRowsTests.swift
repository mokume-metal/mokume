// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 台帳の字形を写す行 (`os=` を持つ行) の読み方と、比べるかどうかの決め方 (#1559)。
///
/// GPU を要さない。台帳の検査 (`SceneLedgerTests`) は GPU が無い機械では丸ごと飛ぶが、
/// どの行をどの機械で比べるかは、そこと無関係に決まっていなければならない。
@Suite("台帳の字形を写す行")
struct LedgerGlyphRowsTests {
    @Test("os= を持つ行は、指紋と基準の版を読む")
    func readsTheBaseVersion() {
        let entries = Ledger.parse(
            """
            # 注記
            shapes 0a1b
            text 2c3d os=27
            """)
        #expect(entries["shapes"] == Ledger.Entry(digest: "0a1b", baseOS: nil))
        #expect(entries["text"] == Ledger.Entry(digest: "2c3d", baseOS: 27))
    }

    @Test("os= の形でない 3 つ目の語を持つ行は、台帳に無いことになる")
    func ignoresAMalformedThirdWord() {
        let entries = Ledger.parse(
            """
            text 2c3d macos27
            textFlow 4e5f os=
            """)
        #expect(entries.isEmpty)
    }

    @Test("書き出す 1 行は、読むと同じ行に戻る", arguments: [nil, 27] as [Int?])
    func writtenLineReadsBack(_ base: Int?) {
        let line = Ledger.line("text", digest: "2c3d", baseOS: base)
        #expect(Ledger.parse(line)["text"] == Ledger.Entry(digest: "2c3d", baseOS: base))
    }

    @Test("基準の版と同じ機械でだけ比べる")
    func comparesOnlyOnTheBaseVersion() {
        #expect(Ledger.comparable(base: 27, host: 27))
        #expect(!Ledger.comparable(base: 27, host: 26))
        #expect(!Ledger.comparable(base: 27, host: 28))
        // 版がそろっていない (基準が決まらない) 台帳では、どの機械でも比べない
        #expect(!Ledger.comparable(base: nil, host: 27))
    }

    @Test("基準の版は、os= を持つ行がすべて同じ版のときだけ決まる")
    func theBaseIsSharedByAllGlyphRows() {
        #expect(Ledger.glyphBase(of: Ledger.parse("a 1\nb 2 os=27\nc 3 os=27")) == 27)
        #expect(Ledger.glyphBase(of: Ledger.parse("a 1\nb 2 os=27\nc 3 os=28")) == nil)
        #expect(Ledger.glyphBase(of: Ledger.parse("a 1\nb 2")) == nil)
    }

    /// いまの台帳の `os=` がそろっていること。そろっていないと、字形を写す行はどの機械でも
    /// 比べられなくなり、黙って見られない行が残る。
    @Test("いまの台帳の os= の版はそろっている")
    func theLedgerNamesOneBase() throws {
        let entries = try Ledger.load()
        #expect(entries.values.contains { $0.baseOS != nil }, "字形を写す行が 1 つも無い")
        #expect(Ledger.glyphBase(of: entries) != nil, "os= の版がそろっていない")
    }
}

/// 字形を置かない旗 (``Canvas/placesGlyphs``)。GPU を要する。
@Suite(
    "字形を置かない旗",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GlyphPlacementFlagTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas() throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 96)
        canvas.textFont("Helvetica")
        canvas.textSize(32)
        return canvas
    }

    /// 旗を下ろすと、字は 1 画素も写らず、字形の四角も数えられない。
    @Test("旗を下ろすと、字形は置かれない")
    func loweredFlagPlacesNothing() throws {
        let canvas = try makeCanvas()
        canvas.placesGlyphs = false
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("mokume", 20, 60)
        }
        let image = try canvas.target.encodeForDisplay()
        var inked = 0
        for y in 0..<96 {
            for x in 0..<160 where image[x, y].red > 0 { inked += 1 }
        }
        #expect(inked == 0)
        #expect(canvas.glyphQuadsPlaced == 0)
    }

    /// 上げたまま (既定) なら、同じ字は置かれる。上の検査が「そもそも描けていない」で
    /// 通っていないことの確かめでもある。
    @Test("既定では字形を置く")
    func raisedFlagPlacesGlyphs() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("mokume", 20, 60)
        }
        #expect(canvas.glyphQuadsPlaced == 6)
    }

    /// 組版は旗に依らない。測る口の値も、流し込みの結果も変わらない。
    @Test("旗を下ろしても、字の測り方と流し込みは変わらない")
    func loweringTheFlagKeepsTheLayout() throws {
        let raised = try makeCanvas()
        let lowered = try makeCanvas()
        lowered.placesGlyphs = false
        var flows: [TextFlow] = []
        for canvas in [raised, lowered] {
            try canvas.draw { flows.append(canvas.text("mokume, the grain of wood", 10, 10, 80, 60)) }
        }
        #expect(flows.count == 2 && flows[0] == flows[1])
        // 矩形に収まらず残りが出る長さにしてある。折り返しが起きていなければ、比べる意味が無い
        #expect(flows.first.map { !$0.remainder.isEmpty } == true, "流し込みが矩形に収まってしまった")
        #expect(raised.textWidth("mokume") == lowered.textWidth("mokume"))
        #expect(raised.textAscent() == lowered.textAscent())
    }

    /// 描き場所は、作った面の旗を引き継ぐ。描き場所に書いた字も、同じ行の絵に載るから。
    @Test("描き場所は旗を引き継ぐ")
    func graphicsInheritTheFlag() throws {
        let canvas = try makeCanvas()
        canvas.placesGlyphs = false
        let graphics = try canvas.createGraphics(40, 40)
        #expect(!graphics.placesGlyphs)
    }
}
