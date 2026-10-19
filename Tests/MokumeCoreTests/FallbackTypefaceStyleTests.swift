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

    // MARK: - 頼んだ面の引き直し (#2770)
    //
    // CoreText は代わりの書体を、頼んだ面を持てなかった (劣化した) base に合わせて選ぶ。引いた書体が頼んだ
    // 面を持つなら、その面で引き直す。引き直しの判断は `Typeface.restyledFallback` の純粋な関数に切り出して
    // あり、字形の有無を問う閉包を差し替えて検査する。

    // **代わりの書体の家族は、機械の言語の設定で変わる。** 「あ」の代わりは、手元ではヒラギノ (明朝・角ゴシック)、
    // CI 機では中文の宋体 (STSongti-SC) だった。だから検査は書体の名前ではなく**性質**で見る: 太さ・傾きを
    // 頼まずに引いた代わりの面 (その機械の家族) を基準にし、頼んだ側がその家族の太字の面に替わること。

    private static func traits(_ font: CTFont) -> CTFontSymbolicTraits { CTFontGetSymbolicTraits(font) }
    private static func family(_ font: CTFont) -> String { CTFontCopyFamilyName(font) as String }

    /// 何も頼まずに引いた、その機械の代わりの面。
    private static func plainFallback(_ name: String, _ scalar: Unicode.Scalar) throws -> ResolvedGlyph {
        let plain = Typeface(request: TypefaceRequest(name: name, size: 32, style: .normal)) { _, _, _ in }
        return try #require(plain.glyph(for: scalar), "前提: \(name) に混ぜた「\(scalar)」を引ける")
    }

    /// 太字の面を持たない欧文の書体を指定して、混ぜた日本語を引く。(書体・太さ・字)
    nonisolated static var restyledFaces: [(name: String, style: TextStyle, scalar: Unicode.Scalar)] {
        [
            ("Apple-Chancery", .bold, "あ"),
            ("AndaleMono", .bold, "あ"),
            ("Apple-Chancery", .boldItalic, "あ"),  // 太斜体は太字だけの面 (#2562 の順)
        ]
    }

    @Test(
        "太字の面を持たない書体の和文は、代わりの書体の太字の面で引く",
        arguments: restyledFaces)
    func aFallbackIsRestyledToTheRequestedFace(
        _ item: (name: String, style: TextStyle, scalar: Unicode.Scalar)
    ) throws {
        try #require(
            CTFontCopyPostScriptName(Self.font(item.name)) as String == item.name,
            "前提: この環境に \(item.name) がある")
        let normal = try Self.plainFallback(item.name, item.scalar)
        try #require(
            !Self.traits(normal.font).contains(.traitBold), "前提: 何も頼まない代わりの面は太字でない")
        let bold = CTFontCreateCopyWithSymbolicTraits(normal.font, 32, nil, .traitBold, .traitBold)
        try #require(
            bold.map { Self.traits($0).contains(.traitBold) } == true,
            "前提: 代わりの書体 (\(normal.fontKey)) に太字の面がある")

        let reports = Reports()
        let face = Typeface(request: TypefaceRequest(name: item.name, size: 32, style: item.style)) {
            _, scalar, fallback in
            reports.items.append((scalar, CTFontCopyPostScriptName(fallback) as String))
        }
        let resolved = try #require(face.glyph(for: item.scalar))
        #expect(resolved.glyph != 0)
        #expect(Self.traits(resolved.font).contains(.traitBold), "\(item.name) の \(item.style): \(resolved.fontKey)")
        #expect(resolved.fontKey != normal.fontKey, "細い面 (\(normal.fontKey)) のまま")
        #expect(
            Self.family(resolved.font) == Self.family(normal.font) || resolved.fontKey.hasPrefix("."),
            "別の家族へ替わった: \(normal.fontKey) → \(resolved.fontKey)")
        // 太斜体は斜体を欠く面で描くので、その面を名乗って 1 度だけ知らせる。太字は欠かないので知らせない
        _ = face.advance(of: "\(item.scalar)\(item.scalar)")
        if item.style == .boldItalic {
            #expect(!Self.traits(resolved.font).contains(.traitItalic))
            #expect(reports.items.map(\.postScript) == [resolved.fontKey], "\(reports.items)")
        } else {
            #expect(reports.items.isEmpty, "\(reports.items)")
        }
        // 引き直し前の答えは、頼んだ面より細い (でなければ、この検査は引き直しを見ていない)
        let before = CTFontCreateForString(face.base, String(item.scalar) as CFString, CFRangeMake(0, 1))
        try #require(
            !Self.traits(before).contains(.traitBold), "前提: 劣化した base から引くと、太字でない面になる")
    }

    @Test("変わらない側: 元から太字の代わり・斜体の面が無い代わり・絵文字・何も頼まない字は引き直さない")
    func restylingLeavesTheOtherCasesAlone() throws {
        func resolve(_ name: String, _ style: TextStyle, _ scalar: Unicode.Scalar) throws -> (Typeface, ResolvedGlyph) {
            try #require(CTFontCopyPostScriptName(Self.font(name)) as String == name, "前提: \(name) がある")
            let face = Typeface(request: TypefaceRequest(name: name, size: 32, style: style)) { _, _, _ in }
            return (face, try #require(face.glyph(for: scalar)))
        }
        func before(_ face: Typeface, _ scalar: Unicode.Scalar) -> CTFont {
            CTFontCreateForString(face.base, String(scalar) as CFString, CFRangeMake(0, 1))
        }
        // 太字の面を持つ書体は、CoreText が最初から太字の代わりを選ぶ (引き直さなくても太字)
        let (_, helveticaBold) = try resolve("Helvetica", .bold, "あ")
        #expect(Self.traits(helveticaBold.font).contains(.traitBold))
        // 代わりの書体に斜体の面が無ければ、引き直しても替わらない (合成もしない)
        let (italicFace, italic) = try resolve("Helvetica", .italic, "あ")
        let italicBefore = before(italicFace, "あ")
        let italicCopy = CTFontCreateCopyWithSymbolicTraits(italicBefore, 32, nil, .traitItalic, .traitItalic)
        try #require(
            italicCopy.map { !Self.traits($0).contains(.traitItalic) } ?? true,
            "前提: 代わりの書体 (\(CTFontCopyPostScriptName(italicBefore) as String)) に斜体の面が無い")
        #expect(italic.fontKey == CTFontCopyPostScriptName(italicBefore) as String)
        // 色の書体の字は、太字を頼んでも絵文字のまま
        let (_, emoji) = try resolve("Apple-Chancery", .bold, "😀")
        #expect(Self.traits(emoji.font).contains(.traitColorGlyphs), "\(emoji.fontKey)")
        // 何も頼まなければ、引いた代わりの面をそのまま使う
        let (plainFace, plain) = try resolve("Apple-Chancery", .normal, "あ")
        #expect(
            plain.fontKey == CTFontCopyPostScriptName(before(plainFace, "あ")) as String,
            "何も頼まない「あ」は面を引き直さない: \(plain.fontKey)")
    }

    /// 合成の材料: 引き直しの判断を、CoreText の答えではなく差し替えた閉包で見る。
    private static func restyle(
        from name: String, requested: CTFontSymbolicTraits, copyReturns: String?, glyph: CGGlyph
    ) -> (font: CTFont, glyph: CGGlyph, lacksStyle: Bool) {
        let from = font(name)
        return Typeface.restyledFallback(
            from, glyph: 7, requested: requested,
            copy: { _ in copyReturns.map(font) }, glyphIndex: { _ in glyph })
    }

    @Test("引き直した面が字形を持たなければ、写す前の面のまま描き、字を落とさない")
    func aRestyledFaceWithoutTheGlyphKeepsTheOriginal() throws {
        for name in ["HiraginoSans-W3", "HiraginoSans-W6"] {
            try #require(CTFontCopyPostScriptName(Self.font(name)) as String == name, "前提: \(name) がある")
        }
        let none = Self.restyle(from: "HiraginoSans-W3", requested: .traitBold, copyReturns: "HiraginoSans-W6", glyph: 0)
        #expect(CTFontCopyPostScriptName(none.font) as String == "HiraginoSans-W3")
        #expect(none.glyph == 7)
        #expect(none.lacksStyle, "太字を欠いたままなので、知らせる側に欠くと伝える")
        let found = Self.restyle(from: "HiraginoSans-W3", requested: .traitBold, copyReturns: "HiraginoSans-W6", glyph: 9)
        #expect(CTFontCopyPostScriptName(found.font) as String == "HiraginoSans-W6")
        #expect(found.glyph == 9)
        #expect(!found.lacksStyle, "太字で描けたので、欠くと伝えない")
    }

    @Test("頼んだ性質に近づかない面・面が引けない書体・既に頼んだ面を持つ代わりは、引き直さない")
    func aRestyleThatGainsNothingKeepsTheOriginal() throws {
        // 面が引けない (nil)
        let unavailable = Self.restyle(from: "HiraginoSans-W3", requested: .traitBold, copyReturns: nil, glyph: 9)
        #expect(CTFontCopyPostScriptName(unavailable.font) as String == "HiraginoSans-W3")
        // 返った面が、頼んだ性質を持たない別の面
        let sideways = Self.restyle(
            from: "HiraginoSans-W3", requested: .traitBold, copyReturns: "HiraMinProN-W3", glyph: 9)
        #expect(CTFontCopyPostScriptName(sideways.font) as String == "HiraginoSans-W3")
        // 代わりが既に頼んだ面を持つ: 閉包は呼ばれない
        var asked = false
        let already = Typeface.restyledFallback(
            Self.font("HiraginoSans-W6"), glyph: 7, requested: .traitBold,
            copy: { _ in asked = true; return nil }, glyphIndex: { _ in asked = true; return 9 })
        #expect(!asked)
        #expect(already.glyph == 7)
    }
}
