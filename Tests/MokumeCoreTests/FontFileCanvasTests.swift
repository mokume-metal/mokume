// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// `textFont(_: Font)`・`textWeight` を、描く面 (`Canvas`) を通して見る検査 ([#2445])。GPU を要する。
///
/// 書体の読み込みと面の選び方は ``FontFileTests`` (GPU を使わない)。ここで見るのは、面の上での
/// 約束 — 後から呼んだほうが勝つ・太さが焼き場の鍵に整数で入る・丸めと警告・測る口が同じ書体を使う・
/// 太さを動かしても字が欠けない。
///
/// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
@Suite(
    "書体のファイルと太さ (面)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FontFileCanvasTests {
    private func makeCanvas(width: Int = 160, height: Int = 96) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        canvas.textSize(40)
        return canvas
    }

    /// その面が、いま字を引くときの請求。
    private func request(of canvas: Canvas) -> TypefaceRequest { canvas.typeface.request }

    private func glyphKey(_ canvas: Canvas, _ character: Unicode.Scalar = "M") throws -> GlyphAtlas.Key {
        let resolved = try #require(canvas.typeface.glyph(for: character))
        return canvas.glyphKey(for: resolved)
    }

    // MARK: - 後勝ち

    @Test("textStyle(.bold) の後の textWeight(300) は 300、textWeight(300) の後の textStyle(.bold) は太字")
    func theLaterCallWins() throws {
        let canvas = try makeCanvas()
        canvas.textStyle(.bold)
        canvas.textWeight(300)
        #expect(request(of: canvas).weight == 300)
        #expect(request(of: canvas).style == .normal, "太さを頼んだら太字は落とす")

        canvas.textStyle(.bold)
        #expect(request(of: canvas).weight == nil)
        #expect(request(of: canvas).style == .bold)
    }

    @Test("傾きは太さの指定で消えない。後から textStyle を書けば太さは外れる")
    func italicSurvivesAWeight() throws {
        let canvas = try makeCanvas()
        canvas.textStyle(.boldItalic)
        canvas.textWeight(300)
        #expect(request(of: canvas).style == .italic)
        #expect(request(of: canvas).weight == 300)

        canvas.textStyle(.italic)
        #expect(request(of: canvas).weight == nil, "textStyle が太さを外さなかった")
    }

    @Test("textFont の名前とファイルは、後に書いたほうが勝ち、noTextFont で両方外れる")
    func theLaterFontWins() throws {
        let canvas = try makeCanvas()
        let font = try Font.load(FontFileTests.staticFile)
        canvas.textFont("Helvetica")
        canvas.textFont(font)
        #expect(request(of: canvas).file == font)
        #expect(request(of: canvas).name == nil)

        canvas.textFont("Helvetica")
        #expect(request(of: canvas).file == nil)
        #expect(request(of: canvas).name == "Helvetica")

        canvas.textFont(font)
        canvas.noTextFont()
        #expect(request(of: canvas).file == nil)
        #expect(request(of: canvas).name == nil)
    }

    @Test("pushStyle・popStyle は、選んだ書体と太さも積んで戻す")
    func theStyleStackKeepsTheFontAndWeight() throws {
        let canvas = try makeCanvas()
        let font = try Font.load(FontFileTests.staticFile)
        canvas.textFont(font)
        canvas.textWeight(300)
        try canvas.draw {
            canvas.pushStyle()
            canvas.textFont("Courier")
            canvas.textStyle(.bold)
            #expect(request(of: canvas).file == nil)
            #expect(request(of: canvas).weight == nil)
            canvas.popStyle()
            #expect(request(of: canvas).file == font)
            #expect(request(of: canvas).weight == 300)
        }
    }

    // MARK: - 鍵

    @Test("焼き場の鍵は太さを整数に丸めて持つ。500.2 と 500.4 は同じ字形で、500 と 501 は別に焼く")
    func theKeyHoldsTheRoundedWeight() throws {
        let canvas = try makeCanvas()
        canvas.textWeight(500.4)
        let a = try glyphKey(canvas)
        canvas.textWeight(500.2)
        let b = try glyphKey(canvas)
        #expect(a == b)
        #expect(a.weight == 500)

        canvas.textWeight(500)
        let five = try glyphKey(canvas)
        canvas.textWeight(501)
        let fiveOhOne = try glyphKey(canvas)
        #expect(five != fiveOhOne)
        #expect(fiveOhOne.weight == 501)
    }

    @Test("太さを頼まない字と、標準の 400 を頼んだ字は別の鍵 (頼んだことが鍵に残る)")
    func noWeightIsNotFourHundred() throws {
        let canvas = try makeCanvas()
        let plain = try glyphKey(canvas)
        canvas.textWeight(400)
        #expect(plain.weight == 0)
        #expect(try glyphKey(canvas).weight == 400)
    }

    // MARK: - 丸めと警告

    @Test("100 未満・900 超は端へ丸めて 1 度知らせ、数でない値は知らせて前の太さのまま")
    func outOfRangeIsRoundedAndNotANumberIsRefused() throws {
        let canvas = try makeCanvas()
        canvas.textWeight(50)
        #expect(request(of: canvas).weight == 100)
        let message = try #require(canvas.warnings.message(for: .badTextWeight))
        #expect(
            message
                == "textWeight(): the weight takes 100 to 900, but 50.0 was passed, so 100 was used",
            "\(message)")

        canvas.textWeight(1e30)
        #expect(request(of: canvas).weight == 900, "巨大な値で落ちず、端へ丸める")

        canvas.textWeight(650)
        canvas.textWeight(Float.nan)
        #expect(request(of: canvas).weight == 650, "数でない値で前の太さが消えた")
        let refused = try #require(canvas.warnings.message(for: .notANumberTextWeight))
        #expect(refused.hasPrefix("textWeight(): got nan"), "\(refused)")
        canvas.textWeight(Double.infinity)
        #expect(request(of: canvas).weight == 650)
    }

    @Test("Int や Double の変数もそのまま渡せる")
    func integersAndDoublesAreAccepted() throws {
        let canvas = try makeCanvas()
        let integer = 720
        canvas.textWeight(integer)
        #expect(request(of: canvas).weight == 720)
        let double = 310.0
        canvas.textWeight(double)
        #expect(request(of: canvas).weight == 310)
    }

    @Test("近い面が無い太さは、使った面を名乗って 1 度だけ警告し、近い面があれば警告しない")
    func aFarWeightIsWarnedOnce() throws {
        let canvas = try makeCanvas()
        canvas.textFont(try Font.load(FontFileTests.staticFile))
        canvas.textWeight(500)
        _ = canvas.typeface
        #expect(!canvas.warnings.hasWarned(.missingTypefaceWeight), "500 に 400 は近い")

        canvas.textWeight(900)
        _ = canvas.typeface
        let message = try #require(canvas.warnings.message(for: .missingTypefaceWeight))
        #expect(message.contains("has no face near 900"), "\(message)")
        #expect(message.contains("\"Helvetica-Bold\" (weight 700)"), "\(message)")

        // 別の太さで言い直さない
        canvas.textWeight(100)
        _ = canvas.typeface
        #expect(canvas.warnings.message(for: .missingTypefaceWeight) == message)
    }

    @Test("可変書体は、範囲の中の太さでは警告しない")
    func aVariableFaceDoesNotWarn() throws {
        let canvas = try makeCanvas()
        for weight in [100, 450, 900] {
            canvas.textWeight(weight)
            _ = canvas.typeface
        }
        #expect(!canvas.warnings.hasWarned(.missingTypefaceWeight))
    }

    // MARK: - 測る口は同じ書体を使う

    @Test("textWidth・textBounds・textOutline は、読んだ書体で測る")
    func measuringUsesTheLoadedFont() throws {
        let canvas = try makeCanvas()
        let font = try Font.load(FontFileTests.staticFile)
        canvas.textFont("Courier")
        let courier = canvas.textWidth("Mokume")
        let courierBounds = try #require(canvas.textBounds("Mokume", 0, 60))

        canvas.textFont(font)
        let loaded = canvas.textWidth("Mokume")
        let expected = FontFileTests.typefaceWidth(of: "Mokume", file: font, size: 40)
        #expect(loaded == expected, "読んだ書体の幅と食い違う")
        #expect(loaded != courier, "別の書体のまま測った")

        let bounds = try #require(canvas.textBounds("Mokume", 0, 60))
        #expect(bounds != courierBounds)
        #expect(!canvas.textOutline("Mokume", 0, 60).isEmpty)

        // 太さを頼めば、同じ書体の別の面で測る
        canvas.textWeight(300)
        let light = canvas.textWidth("Mokume")
        canvas.textWeight(700)
        #expect(light < canvas.textWidth("Mokume"), "Helvetica-Light より Helvetica-Bold のほうが広い")
    }

    @Test("同じ名前の書体が入っていても、textFont(名前) の結果は読んだファイルに左右されない")
    func loadingDoesNotChangeTheNamedFont() throws {
        let canvas = try makeCanvas()
        canvas.textFont("Helvetica")
        let before = canvas.textWidth("Mokume")
        _ = try Font.load(FontFileTests.staticFile)
        canvas.textFont("Helvetica")
        #expect(canvas.textWidth("Mokume") == before)
    }

    // MARK: - 描く

    /// 墨の量 (赤の総和)。
    private func ink(_ canvas: Canvas) throws -> Float {
        let image = try canvas.target.encodeForDisplay()
        var total: Float = 0
        for y in 0..<image.height {
            for x in 0..<image.width { total += Float(image[x, y].red) }
        }
        return total
    }

    @Test("読んだ可変書体は、太さを動かしても字が欠けず、太いほど墨が増える")
    func everyWeightDrawsAndHeavierMeansMoreInk() throws {
        let canvas = try makeCanvas(width: 120, height: 80)
        canvas.textFont(try Font.load(FontFileTests.variableFile))
        var previous: Float = 0
        for weight in stride(from: 100, through: 900, by: 100) {
            try canvas.draw {
                canvas.background(Color.linear(red: 0, green: 0, blue: 0))
                canvas.fill(Color.linear(red: 1, green: 1, blue: 1))
                canvas.textWeight(weight)
                canvas.text("M", 20, 60)
            }
            let amount = try ink(canvas)
            #expect(amount > 0, "太さ \(weight) で字が出ない")
            #expect(amount > previous, "太さ \(weight) の墨 \(amount) が、前の \(previous) より増えない")
            previous = amount
        }
    }

    @Test("太さを毎フレーム 1 刻みで動かし続けても、字は出続ける (焼き直しで欠けない)")
    func sweepingTheWeightKeepsDrawing() throws {
        let canvas = try makeCanvas(width: 120, height: 80)
        for weight in 100...900 where weight % 4 == 0 {
            try canvas.draw {
                canvas.background(Color.linear(red: 0, green: 0, blue: 0))
                canvas.fill(Color.linear(red: 1, green: 1, blue: 1))
                canvas.textWeight(weight)
                canvas.text("Mg", 20, 60)
            }
            #expect(try ink(canvas) > 0, "太さ \(weight) で字が出ない")
        }
    }
}
