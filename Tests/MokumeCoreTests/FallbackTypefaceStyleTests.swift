// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 代わりの書体から引いた字の面 (#2561)。**GPU を使わない** — `Typeface` を直接作り、引き当てが
/// 知らせの口を呼ぶかだけを見る (警告の文面と「1 度だけ」は `TextTests` が Canvas で見る)。
///
/// 指定した書体が覆えない字は CoreText が別の書体から引く。その面が頼んだ太さ・傾きを持たない
/// (欧文の斜体に混ぜた日本語がヒラギノ角ゴシックの立体で引かれる) なら知らせる。知らせても直す手が
/// 無い字 — 色の字形を持つ書体の字と、墨を持たない字 — は外す。知らせは面ごとに 1 度きりなので、
/// 外さないと先に鳴って、直せる字の知らせを使い切る。
@Suite("代わりの書体の面")
struct FallbackTypefaceStyleTests {
    private static func font(_ name: String) -> CTFont {
        CTFontCreateWithName(name as CFString, 12, nil)
    }

    /// その書体の中での字形の番号。持っていなければ 0。被検査の `Typeface` を通さない。
    private static func glyph(of scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs[0]
    }

    /// 面の判定。書体と字は名指しし、前提 (その書体が環境にあり、その字を持つ) を各行の頭で確かめる。
    nonisolated static var judgements: [(font: String, scalar: Unicode.Scalar, requested: TextStyle, lacks: Bool)] {
        [
            ("HiraginoSans-W3", "あ", .italic, true),  // 斜体を頼んだのに立体
            ("HiraginoSans-W6", "あ", .bold, false),  // 太字を頼んで太字
            ("HiraginoSans-W6", "あ", .boldItalic, true),  // 太字だけで斜体が欠ける
            ("HiraginoSans-W3", "あ", .bold, true),  // 太字を頼んだのに太字でない
            ("HiraginoSans-W3", "あ", .normal, false),  // 何も頼んでいない
            ("Helvetica-BoldOblique", "a", .boldItalic, false),
            ("AppleColorEmoji", "😀", .bold, false),  // 色の字形を持つ書体は欠かないと見る
            ("AppleColorEmoji", "😀", .boldItalic, false),
            ("ZapfDingbatsITC", "\u{2764}", .bold, true),  // 単色の書体の ❤ は知らせる
            ("HiraginoSans-W3", "\u{3000}", .italic, false),  // 道筋の無い字 (和文の空白)
            ("LucidaGrande", "\u{FE0E}", .italic, false),  // 道筋の無い字 (異体字セレクタ・送り幅 0)
            ("LastResort", "\u{E000}", .italic, false),  // 豆腐 (道筋はあるが、字の代わり)
            ("LucidaGrande", "\u{20E3}", .italic, true),  // 送り幅 0 でも墨のある結合文字は知らせる
        ]
    }

    @Test(
        "代わりの書体の字は、面が頼んだ性質を欠き、墨を持つときだけ欠くと見る。色の字形を持つ書体は欠かない",
        arguments: judgements)
    func theFallbackFaceIsJudgedByItsTraits(
        _ item: (font: String, scalar: Unicode.Scalar, requested: TextStyle, lacks: Bool)
    ) throws {
        let font = Self.font(item.font)
        try #require(CTFontCopyPostScriptName(font) as String == item.font, "前提: この環境に \(item.font) がある")
        let glyph = Self.glyph(of: item.scalar, in: font)
        try #require(glyph != 0, "前提: \(item.font) は U+\(String(item.scalar.value, radix: 16)) を持つ")
        #expect(
            Typeface.lacksStyle(fallback: font, glyph: glyph, requested: Typeface.traits(of: item.requested))
                == item.lacks,
            "\(item.font) の U+\(String(item.scalar.value, radix: 16)) を \(item.requested) で引いた")
    }

    /// 引き当てが知らせの口へ渡したもの。
    private final class Reports {
        var items: [(scalar: Unicode.Scalar, postScript: String)] = []
    }

    private static func typeface(_ style: TextStyle, into reports: Reports) -> Typeface {
        Typeface(request: TypefaceRequest(name: "Helvetica", size: 32, style: style)) { _, scalar, fallback in
            reports.items.append((scalar, CTFontCopyPostScriptName(fallback) as String))
        }
    }

    @Test("斜体に混ぜた日本語は、字の種類ごとに 1 度、引いた書体を添えて知らせる")
    func aFallbackWithoutTheStyleIsReportedOncePerCharacter() throws {
        let reports = Reports()
        let face = Self.typeface(.italic, into: reports)
        try #require(face.glyph(for: "a")?.fontKey == "Helvetica-Oblique", "前提: Helvetica の斜体の面がある")
        // 幅から先に引いても、字を引いても、同じ字は 1 度だけ
        _ = face.advance(of: "aあ")
        _ = face.glyph(for: "あ")
        _ = face.advance(of: "ああa")
        #expect(reports.items.map(\.scalar) == ["あ"])
        try #require(reports.items.first?.postScript == "HiraginoSans-W3", "前提: 「あ」を HiraginoSans-W3 から引く")
        _ = face.glyph(for: "も")
        #expect(reports.items.map(\.scalar) == ["あ", "も"])
    }

    /// 墨を持たない字が先に引かれても、後の和文が知らされる (知らせを使い切らない)。異体字セレクタ
    /// (U+FE0E。テキストで描く印)・私用領域 (U+E000。LastResort の豆腐)・和文の空白 (U+3000)。
    @Test("墨を持たない字は知らせず、後から引く和文を知らせる", arguments: ["\u{FE0E}", "\u{E000}", "\u{3000}"])
    func inklessCharactersAreNotReported(_ lead: String) {
        let reports = Reports()
        _ = Self.typeface(.italic, into: reports).advance(of: "a\(lead)も")
        #expect(reports.items.map(\.scalar) == ["も"], "\(reports.items.map { "\($0.scalar) \($0.postScript)" })")
    }

    @Test("指定した書体が覆う字・頼んだ面を持つ代わり・絵文字・何も頼まない字は知らせない")
    func coveredOrStyledFallbacksAreNotReported() {
        let reports = Reports()
        _ = Self.typeface(.italic, into: reports).advance(of: "Mokume 😀")
        _ = Self.typeface(.bold, into: reports).advance(of: "Mokume あ😀")
        _ = Self.typeface(.normal, into: reports).advance(of: "Mokume あ😀")
        #expect(reports.items.isEmpty, "\(reports.items.map { "\($0.scalar) \($0.postScript)" })")
    }
}
