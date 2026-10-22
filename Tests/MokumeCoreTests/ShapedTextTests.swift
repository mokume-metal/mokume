// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 組版した文字列を描く・測る入口 (`shapedText`・`shapedTextWidth`・`shapedTextBounds`・#2404)。
///
/// 既存の `text()`・`textWidth()` (スカラ 1 つずつ・幅の加法性) は変えない。**新しい口は、描く・幅・整列・
/// 墨の範囲が 1 つの組版結果から出る。** 物差しは、書体の版に依らない性質 — 1 字で出る (字形の数・描いた画素の
/// かたまりの数)・墨の枠が描いた画素と合う・整列が幅だけずれる — に置く。
@Suite("組版した文字列")
struct ShapedTextTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 絵文字の列 (#2311 の例)。肌色の修飾子・国旗・ZWJ の家族・異体字セレクタ・囲み。
    private static let emoji = ["👍🏽", "🇯🇵", "👨‍👩‍👧", "❤️", "1️⃣"]

    private func face(size: Float = 40) -> Typeface {
        Typeface(
            request: TypefaceRequest(name: "Helvetica", size: size, style: .normal),
            onFallbackLackingStyle: { _, _, _ in })
    }

    // MARK: - 組版の結果 (GPU を要らない)

    @Test(
        "複数のスカラでできた絵文字は、組版すると 1 つの字形になり、幅は 1 字ぶん。スカラ 1 つずつでは部品に分かれる",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
    func composedEmojiAreOneGlyph() {
        let face = face()
        for string in Self.emoji {
            let line = face.shape(string)
            #expect(line.glyphs.count == 1, "\(string): 字形 \(line.glyphs.count) 個")
            // 1 字ぶん (大きさと同じ幅の升目)。部品の幅の和にならない
            #expect(abs(line.width - 40) < 1, "\(string): 幅 \(line.width)")
        }
        // スカラ 1 つずつの幅は、修飾子・国旗・家族では 2 字・3 字ぶんになる
        #expect(face.advance(of: "👍🏽") > face.shape("👍🏽").width + 1)
        #expect(face.advance(of: "👨‍👩‍👧") > face.shape("👨‍👩‍👧").width + 1)
    }

    @Test("結合文字は、基の字と 1 つの位置に重なる (幅は基の字の幅のまま、分かれた字形は基の上に載る)")
    func combiningMarkOverlapsItsBase() {
        let face = face()
        let line = face.shape("e\u{0301}")
        let base = face.shape("e")
        #expect(abs(line.width - base.width) < 0.01, "幅 \(line.width) / e の幅 \(base.width)")
        // 字形が分かれる書体でも、結合記号は基の字の送りの内に置かれる (右へ送らない)
        for glyph in line.glyphs { #expect(glyph.x < base.width, "字形が \(glyph.x) に置かれた") }
    }

    @Test("組版した幅は部分の和にならない (カーニング) が、text() の幅は和のまま")
    func shapedWidthIsNotAdditiveButTheOldOneIs() {
        let face = face()
        let kerned = face.shape("AV").width
        let apart = face.shape("A").width + face.shape("V").width
        #expect(kerned < apart - 0.5, "AV: 組版 \(kerned) / 部品の和 \(apart)")
        // 既存の口は動かない
        #expect(face.advance(of: "AV") == face.advance(of: "A") + face.advance(of: "V"))
        #expect(face.advance(of: "👍🏽") == face.advance(of: "👍") + face.advance(of: "🏽"))
    }

    @Test("同じ文字列の組版は控えから返り、控えは上限を越えて育たない")
    func shapedLinesAreCachedAndBounded() {
        let face = face()
        #expect(face.shape("mokume") === face.shape("mokume"))
        for number in 0..<1000 { _ = face.shape("n\(number)") }
        #expect(face.shaped.count <= 256)
        // 控えが空になった後も、同じ値が組める
        #expect(face.shape("AV").width == face.shape("AV").width)
    }

    // MARK: - 描く・測る (GPU を要する)

    @Suite(
        "描く・測る",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct Drawing {
        private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
        private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        private static let width = 400
        private static let height = 100

        private func makeCanvas(size: Float = 40) throws -> Canvas {
            let canvas = try CanvasFixture.make(
                gpu: RenderDevice(), width: Self.width, height: Self.height)
            canvas.textFont("Helvetica")
            canvas.textSize(size)
            return canvas
        }

        /// 1 フレーム描いて読み戻す。
        private func render(_ canvas: Canvas, _ body: () -> Void) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                body()
            }
            return try canvas.target.encodeForDisplay()
        }

        private func isInk(_ image: DisplayImage, _ x: Int, _ y: Int) -> Bool {
            let pixel = image[x, y]
            return pixel.red > 8 || pixel.green > 8 || pixel.blue > 8
        }

        /// 墨の外接矩形。何も描かれていなければ `nil`。
        private func inkBounds(_ image: DisplayImage) -> (left: Int, top: Int, right: Int, bottom: Int)? {
            var (left, top, right, bottom) = (Int.max, Int.max, Int.min, Int.min)
            for y in 0..<Self.height {
                for x in 0..<Self.width where isInk(image, x, y) {
                    left = min(left, x)
                    top = min(top, y)
                    right = max(right, x)
                    bottom = max(bottom, y)
                }
            }
            return left <= right ? (left, top, right, bottom) : nil
        }

        /// 横に並んだ墨のかたまりの数。墨の列が `gap` 画素より離れたら別のかたまり。
        private func inkClusters(_ image: DisplayImage, gap: Int = 3) -> Int {
            var clusters = 0
            var lastInkColumn = -gap - 1
            for x in 0..<Self.width {
                guard (0..<Self.height).contains(where: { isInk(image, x, $0) }) else { continue }
                if x - lastInkColumn > gap { clusters += 1 }
                lastInkColumn = x
            }
            return clusters
        }

        @Test(
            "#2311 の 5 つの絵文字は、組版すると 5 つのかたまりで描かれ、墨の枠が描いた画素と合う",
            .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
        func fiveEmojiAreFiveShapes() throws {
            let string = ShapedTextTests.emoji.joined(separator: " ")
            let canvas = try makeCanvas()
            let image = try render(canvas) { canvas.shapedText(string, 10, 70) }
            #expect(inkClusters(image) == 5)
            let ink = try #require(inkBounds(image))
            let bounds = try #require(canvas.shapedTextBounds(string, 10, 70))
            #expect(abs(bounds.x - Float(ink.left)) <= 2)
            #expect(abs(bounds.y - Float(ink.top)) <= 2)
            #expect(abs(bounds.x + bounds.width - Float(ink.right)) <= 2)
            #expect(abs(bounds.y + bounds.height - Float(ink.bottom)) <= 2)
            // 幅は 5 字と 4 つの空白
            let expected = 5 * 40 + 4 * canvas.shapedTextWidth(" ")
            #expect(abs(canvas.shapedTextWidth(string) - expected) < 1)

            // 同じ文字列をスカラ 1 つずつで描くと、5 つより広く、部品に分かれる
            let old = try render(canvas) { canvas.text(string, 10, 70) }
            let oldInk = try #require(inkBounds(old))
            #expect(oldInk.right > ink.right + 20, "スカラ 1 つずつの墨 \(oldInk.right) / 組版 \(ink.right)")
        }

        /// `e` + 結合アクセントは、この書体では合成済みの字形 1 つになる。`x` + 結合アクセントは合成済みの
        /// 字形が無く、結合記号の字形を基の字の上へずらして置く (字形の位置の `y` が 0 でない)。
        @Test("結合文字は、組版すると 1 つの位置に重なって描かれ、アクセントは基の字の上に載る", arguments: ["e", "x"])
        func combiningAccentSitsOnTheLetter(base: String) throws {
            let canvas = try makeCanvas(size: 60)
            let accented = base + "\u{0301}"
            let image = try render(canvas) { canvas.shapedText(accented, 40, 70) }
            let plain = try render(canvas) { canvas.shapedText(base, 40, 70) }
            let ink = try #require(inkBounds(image))
            let plainInk = try #require(inkBounds(plain))
            // アクセントの分だけ上に伸び、横には基の字の墨より外へ出ない
            #expect(ink.top < plainInk.top - 3, "アクセントの上端 \(ink.top) / 基の字の上端 \(plainInk.top)")
            #expect(ink.left >= plainInk.left - 2 && ink.right <= plainInk.right + 2)
            #expect(ink.bottom == plainInk.bottom)
            let bounds = try #require(canvas.shapedTextBounds(accented, 40, 70))
            #expect(abs(bounds.y - Float(ink.top)) <= 2)
            #expect(abs(bounds.x + bounds.width - Float(ink.right)) <= 2)
            #expect(abs(bounds.x - Float(ink.left)) <= 2)
        }

        @Test("重ねた結合記号は、字形ごとの縦の位置 (y) で積み上がる: o + 分音記号 + アクセントは、ö より高い")
        func stackedMarksRiseByTheirOwnOffsets() throws {
            let canvas = try makeCanvas(size: 60)
            let stacked = try render(canvas) { canvas.shapedText("o\u{0308}\u{0301}", 40, 70) }
            let single = try render(canvas) { canvas.shapedText("\u{00F6}", 40, 70) }
            let stackedInk = try #require(inkBounds(stacked))
            let singleInk = try #require(inkBounds(single))
            #expect(
                stackedInk.top < singleInk.top - 5,
                "積んだ記号の上端 \(stackedInk.top) / ö の上端 \(singleInk.top)")
            let bounds = try #require(canvas.shapedTextBounds("o\u{0308}\u{0301}", 40, 70))
            #expect(abs(bounds.y - Float(stackedInk.top)) <= 2)
        }

        @Test("横の整列は、組版した行の幅だけ書き始めをずらし、墨の枠も同じだけずれる")
        func alignmentUsesTheShapedWidth() throws {
            let canvas = try makeCanvas()
            let string = "AV Wave"
            let width = canvas.shapedTextWidth(string)
            canvas.textAlign(.left, .baseline)
            let left = try #require(canvas.shapedTextBounds(string, 200, 60))
            canvas.textAlign(.center, .baseline)
            let center = try #require(canvas.shapedTextBounds(string, 200, 60))
            canvas.textAlign(.right, .baseline)
            let right = try #require(canvas.shapedTextBounds(string, 200, 60))
            #expect(abs(center.x - (left.x - width / 2)) < 0.01)
            #expect(abs(right.x - (left.x - width)) < 0.01)
            #expect(center.width == left.width && center.y == left.y)
        }

        @Test("墨の枠は、描いた画素と合う。改行は行を分け、縦の整列は行数で決まる")
        func boundsMatchTheDrawnInk() throws {
            let canvas = try makeCanvas()
            for string in ["Agj 1", "AV", "Wave\nfi"] {
                let image = try render(canvas) { canvas.shapedText(string, 20, 40) }
                let ink = try #require(inkBounds(image))
                let bounds = try #require(canvas.shapedTextBounds(string, 20, 40))
                #expect(abs(bounds.x - Float(ink.left)) <= 2, "\(string.debugDescription)")
                #expect(abs(bounds.y - Float(ink.top)) <= 2, "\(string.debugDescription)")
                #expect(abs(bounds.x + bounds.width - Float(ink.right)) <= 2, "\(string.debugDescription)")
                #expect(abs(bounds.y + bounds.height - Float(ink.bottom)) <= 2, "\(string.debugDescription)")
            }
        }

        @Test("ラテンの詰め: AV は組版すると、スカラ 1 つずつより狭い")
        func latinPairsAreKerned() throws {
            let canvas = try makeCanvas(size: 80)
            #expect(canvas.shapedTextWidth("AV") < canvas.textWidth("AV") - 1)
            let shaped = try render(canvas) { canvas.shapedText("AV", 20, 80) }
            let apart = try render(canvas) { canvas.text("AV", 20, 80) }
            let shapedInk = try #require(inkBounds(shaped))
            let apartInk = try #require(inkBounds(apart))
            #expect(shapedInk.right < apartInk.right - 1)
        }

        @Test("墨の無い文字列・大きさ 0・数でない位置は、幅 0 と枠なし。大きさ 0 では何も描かない")
        func emptyInputs() throws {
            let canvas = try makeCanvas()
            #expect(canvas.shapedTextWidth("") == 0)
            #expect(canvas.shapedTextBounds("", 10, 10) == nil)
            #expect(canvas.shapedTextBounds("  \n ", 10, 10) == nil)
            #expect(canvas.shapedTextBounds("A", Float.nan, 10) == nil)
            #expect(canvas.shapedTextBounds("A", 10, Float.infinity) == nil)
            canvas.textSize(0)
            #expect(canvas.shapedTextWidth("A") == 0)
            #expect(canvas.shapedTextBounds("A", 10, 10) == nil)
            let image = try render(canvas) { canvas.shapedText("A", 10, 40) }
            #expect(inkBounds(image) == nil)
        }

        @Test("既存の text()・textWidth() は組版を始めない: 加法性が保たれ、描く絵が変わらない")
        func theOldEntryIsUnchanged() throws {
            let canvas = try makeCanvas()
            #expect(canvas.textWidth("AV") == canvas.textWidth("A") + canvas.textWidth("V"))
            // 同じ文字列の text() の絵は、shapedText() を呼んだ後も同じ
            let before = try render(canvas) { canvas.text("AV Wave", 10, 60) }
            _ = try render(canvas) { canvas.shapedText("AV Wave", 10, 60) }
            let after = try render(canvas) { canvas.text("AV Wave", 10, 60) }
            #expect(before.bytes == after.bytes)
        }
    }
}
