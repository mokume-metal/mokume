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
/// (欧文の斜体に混ぜた日本語がヒラギノ角ゴシックの立体で引かれる) なら知らせる。色の字形を持つ
/// 書体 (絵文字) は太さ・傾きの面を持たないので、知らせの外に置く。
@Suite("代わりの書体の面")
struct FallbackTypefaceStyleTests {
    private static func font(_ name: String) -> CTFont {
        CTFontCreateWithName(name as CFString, 12, nil)
    }

    /// 面の判定。書体は名指しし、前提 (その書体が環境にあり、その性質を持つ) を各行の頭で確かめる。
    nonisolated static var judgements: [(font: String, requested: TextStyle, lacks: Bool)] {
        [
            ("HiraginoSans-W3", .italic, true),  // 斜体を頼んだのに立体
            ("HiraginoSans-W6", .bold, false),  // 太字を頼んで太字
            ("HiraginoSans-W6", .boldItalic, true),  // 太字だけで斜体が欠ける
            ("HiraginoSans-W3", .bold, true),  // 太字を頼んだのに太字でない
            ("HiraginoSans-W3", .normal, false),  // 何も頼んでいない
            ("Helvetica-BoldOblique", .boldItalic, false),
            ("AppleColorEmoji", .bold, false),  // 色の字形を持つ書体は欠かないと見る
            ("AppleColorEmoji", .boldItalic, false),
        ]
    }

    @Test("代わりの書体の面は、頼んだ性質を欠くかで決まり、色の字形を持つ書体は欠かないと見る", arguments: judgements)
    func theFallbackFaceIsJudgedByItsTraits(_ item: (font: String, requested: TextStyle, lacks: Bool)) throws {
        let font = Self.font(item.font)
        try #require(CTFontCopyPostScriptName(font) as String == item.font, "前提: この環境に \(item.font) がある")
        #expect(
            Typeface.lacksStyle(fallback: font, requested: Typeface.traits(of: item.requested)) == item.lacks,
            "\(item.font) を \(item.requested) で引いた")
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

    @Test("指定した書体が覆う字・頼んだ面を持つ代わり・絵文字・何も頼まない字は知らせない")
    func coveredOrStyledFallbacksAreNotReported() {
        let reports = Reports()
        _ = Self.typeface(.italic, into: reports).advance(of: "Mokume 😀")
        _ = Self.typeface(.bold, into: reports).advance(of: "Mokume あ😀")
        _ = Self.typeface(.normal, into: reports).advance(of: "Mokume あ😀")
        #expect(reports.items.isEmpty, "\(reports.items.map { "\($0.scalar) \($0.postScript)" })")
    }
}
