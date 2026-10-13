// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 太斜体の面の引き当て (#2562)。**GPU を使わない** — `Typeface` を直接作り、書体の性質と
/// PostScript 名だけを読む (警告の文面は `TextTests` が Canvas で見る)。
///
/// 頼んだ性質が揃わないときの順序は「太斜体 → 太字だけ → 斜体だけ → 元の面」。太字と斜体の
/// 両方を持つのに太斜体だけ無い書体は、太字を取る。
@Suite("太斜体の面の引き当て")
struct TypefaceStyleTests {
    /// その書体 (ファミリー名か PostScript 名) が、その性質の面を持つか。被検査の `Typeface` を通さない。
    nonisolated private static func hasFace(_ name: String, _ traits: CTFontSymbolicTraits) -> Bool {
        let base = CTFontCreateWithName(name as CFString, 12, nil)
        guard let styled = CTFontCreateCopyWithSymbolicTraits(base, 12, nil, traits, traits) else {
            return false
        }
        return CTFontGetSymbolicTraits(styled).contains(traits)
    }

    private static func face(_ name: String, _ style: TextStyle) -> Typeface {
        Typeface(request: TypefaceRequest(name: name, size: 12, style: style))
    }

    private static func traits(of typeface: Typeface) -> (bold: Bool, italic: Bool) {
        let traits = CTFontGetSymbolicTraits(typeface.base)
        return (traits.contains(.traitBold), traits.contains(.traitItalic))
    }

    private static func postScript(_ typeface: Typeface) -> String {
        CTFontCopyPostScriptName(typeface.base) as String
    }

    /// 環境の全ファミリー (内部名を除く)。
    private static func families() -> [String] {
        var names = Set<String>()
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        for descriptor in CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? [] {
            let name = CTFontCopyFamilyName(CTFontCreateWithFontDescriptor(descriptor, 12, nil)) as String
            // 名前で引き直した書体が同じ家族のものとは限らない (別名) 書体は除く
            if !name.hasPrefix("."),
                CTFontCopyFamilyName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name
            {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    // MARK: - 名指しの書体 (macOS 同梱。前提は検査の頭で確かめる)

    /// (書体, 頼む太さ・傾き, 描く面の PostScript 名, 太字か, 斜体か)。
    nonisolated static var named: [(font: String, style: TextStyle, drawn: String, bold: Bool, italic: Bool)] {
        [
            // 太斜体がある書体は、太斜体のまま
            ("Helvetica", .boldItalic, "Helvetica-BoldOblique", true, true),
            // 斜体が無く太字がある書体は、太字
            ("HiraginoSans-W3", .boldItalic, "HiraginoSans-W6", true, false),
            // 太字も斜体もあるが太斜体だけ無い書体は、太字を取り、斜体を捨てる
            ("Futura", .boldItalic, "Futura-Bold", true, false),
            // 斜体だけがある書体は、斜体
            ("Bodoni 72 Oldstyle", .boldItalic, "BodoniSvtyTwoOSITCTT-BookIt", false, true),
            ("PT Serif Caption", .boldItalic, "PTSerif-CaptionItalic", false, true),
        ]
    }

    @Test("太斜体が引けないときは、太字だけ・斜体だけの順で引ける面を使う", arguments: named)
    func partialFacesAreUsedInOrder(
        _ item: (font: String, style: TextStyle, drawn: String, bold: Bool, italic: Bool)
    ) throws {
        try #require(
            CTFontCopyPostScriptName(CTFontCreateWithName(item.drawn as CFString, 12, nil)) as String
                == item.drawn,
            "前提: この環境に \(item.drawn) がある")
        let typeface = Self.face(item.font, item.style)
        #expect(Self.postScript(typeface) == item.drawn)
        let (bold, italic) = Self.traits(of: typeface)
        #expect(bold == item.bold && italic == item.italic)
        #expect(typeface.lacksRequestedStyle == !(item.bold && item.italic))
    }

    @Test("太字も斜体もあるのに太斜体だけ無い書体 (Futura) で、前提を確かめる")
    func futuraHasBoldAndItalicButNoBoldItalic() throws {
        try #require(Self.hasFace("Futura", .traitBold), "前提: Futura は太字を持つ")
        try #require(Self.hasFace("Futura", .traitItalic), "前提: Futura は斜体を持つ")
        try #require(
            !Self.hasFace("Futura", [.traitBold, .traitItalic]), "前提: Futura は太斜体を持たない")
    }

    @Test("斜体だけを持つ書体で、前提を確かめる", arguments: ["Bodoni 72 Oldstyle", "PT Serif Caption"])
    func anItalicOnlyFamilyHasNoBold(_ name: String) throws {
        try #require(Self.hasFace(name, .traitItalic), "前提: \(name) は斜体を持つ")
        try #require(!Self.hasFace(name, .traitBold), "前提: \(name) は太字を持たない")
    }

    // MARK: - 環境の全ファミリー

    /// 全ファミリーで、順序どおりの面を使う。**期待する性質は、頼む前に CoreText へ独立に問い合わせて決める**
    /// (太斜体があれば太斜体・無ければ太字があれば太字・無ければ斜体があれば斜体)。
    @Test("どのファミリーも、太斜体 → 太字 → 斜体の順に、引ける性質を捨てない")
    func everyFamilyKeepsTheBestAvailableTraits() throws {
        let families = Self.families()
        try #require(families.contains("Helvetica"), "前提: 書体の一覧に Helvetica がある")
        var seen = (full: 0, boldOnly: 0, italicOnly: 0, neither: 0, boldOverItalic: 0)
        var wrong: [String] = []
        for family in families {
            let full = Self.hasFace(family, [.traitBold, .traitItalic])
            let bold = Self.hasFace(family, .traitBold)
            let italic = Self.hasFace(family, .traitItalic)
            let expected: (bold: Bool, italic: Bool)?
            if full {
                expected = (true, true)
                seen.full += 1
            } else if bold {
                expected = (true, false)
                seen.boldOnly += 1
                if italic { seen.boldOverItalic += 1 }
            } else if italic {
                expected = (false, true)
                seen.italicOnly += 1
            } else {
                expected = nil
                seen.neither += 1
            }
            let typeface = Self.face(family, .boldItalic)
            guard let expected else {
                if !typeface.lacksRequestedStyle { wrong.append("\(family): 面が無いのに警告が立たない") }
                continue
            }
            let got = Self.traits(of: typeface)
            // 太字の面を持つ書体が太斜体だけ無いとき、写しが太字に斜体まで持つことは無いはず
            if got.bold != expected.bold || got.italic != expected.italic
                || typeface.lacksRequestedStyle != !full
            {
                wrong.append("\(family): 期待 \(expected) 実際 \(got) (\(Self.postScript(typeface)))")
            }
        }
        // 前提: この環境に、4 つの場合がそれぞれ在る
        try #require(seen.full > 10, "前提: 太斜体を持つ家族が在る (\(seen))")
        try #require(seen.boldOnly > 10, "前提: 太字だけを持つ家族が在る (\(seen))")
        try #require(seen.boldOverItalic > 0, "前提: 太字も斜体もあるが太斜体が無い家族が在る (\(seen))")
        try #require(seen.italicOnly > 0, "前提: 斜体だけを持つ家族が在る (\(seen))")
        #expect(wrong.isEmpty, "\(wrong.count) 件: \(wrong.prefix(10))")
    }
}
