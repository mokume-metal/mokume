// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// この環境の書体を、CoreText への独立な問い合わせで調べる道具 (#2562)。**被検査の `Typeface` を通さない。**
///
/// **書体の面の構成は、macOS の版・入っている資産で機械ごとに違う** (Bodoni 72 Oldstyle の太字が
/// CI にはあり、この手元には無い、など)。だから検査は書体を名指しせず (必ず太斜体を持つ Helvetica を除く)、
/// 期待を「その環境で CoreText に問い合わせた結果」から導く。
enum FamilySurvey {
    /// その書体 (ファミリー名か PostScript 名) が、その性質の面を持つか。
    nonisolated static func hasFace(_ name: String, _ traits: CTFontSymbolicTraits) -> Bool {
        face(name, traits).map { CTFontGetSymbolicTraits($0).contains(traits) } ?? false
    }

    /// その性質を頼んだときに CoreText が返す写し。
    nonisolated static func face(_ name: String, _ traits: CTFontSymbolicTraits) -> CTFont? {
        let base = CTFontCreateWithName(name as CFString, 12, nil)
        return CTFontCreateCopyWithSymbolicTraits(base, 12, nil, traits, traits)
    }

    /// 環境の全ファミリー (内部名と、名前で引き直すと別の家族になる別名を除く)。
    nonisolated static func families() -> [String] {
        var names = Set<String>()
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        for descriptor in CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? [] {
            let name = CTFontCopyFamilyName(CTFontCreateWithFontDescriptor(descriptor, 12, nil)) as String
            if !name.hasPrefix("."),
                CTFontCopyFamilyName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name
            {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    /// 太斜体を頼んだときの期待。**太斜体が引ければ太斜体、無ければ太字、無ければ斜体、全て無ければ `nil`**
    /// (面が無い)。引ける面は CoreText に独立に問い合わせて決める。
    nonisolated static func expectedBoldItalic(
        of family: String
    ) -> (postScript: String, bold: Bool, italic: Bool, exact: Bool)? {
        let both: CTFontSymbolicTraits = [.traitBold, .traitItalic]
        for (traits, exact) in [(both, true), (.traitBold, false), (.traitItalic, false)] {
            if let font = face(family, traits), CTFontGetSymbolicTraits(font).contains(traits) {
                return (
                    CTFontCopyPostScriptName(font) as String, traits.contains(.traitBold),
                    traits.contains(.traitItalic), exact
                )
            }
        }
        return nil
    }

    /// 環境から、期待の種類ごとに最大 `limit` 件の家族を拾う。**1 件も無ければ空** — その場合、
    /// 引数の無い検査は何も走らない (環境に無い構成を、前提の失敗として赤にしない)。
    nonisolated static func examples(
        limit: Int = 2, where kind: (_ full: Bool, _ bold: Bool, _ italic: Bool) -> Bool
    ) -> [String] {
        var found: [String] = []
        for family in families() {
            let full = hasFace(family, [.traitBold, .traitItalic])
            if kind(full, hasFace(family, .traitBold), hasFace(family, .traitItalic)) {
                found.append(family)
                if found.count == limit { break }
            }
        }
        return found
    }
}

/// 太斜体の面の引き当て (#2562)。**GPU を使わない** — `Typeface` を直接作り、書体の性質と
/// PostScript 名だけを読む (警告の文面は `TextTests` が Canvas で見る)。
///
/// 頼んだ性質が揃わないときの順序は「太斜体 → 太字だけ → 斜体だけ → 元の面」。太字と斜体の
/// 両方を持つのに太斜体だけ無い書体は、太字を取る。
@Suite("太斜体の面の引き当て")
struct TypefaceStyleTests {
    private static func face(_ name: String, _ style: TextStyle) -> Typeface {
        Typeface(request: TypefaceRequest(name: name, size: 12, style: style))
    }

    private static func traits(of font: CTFont) -> (bold: Bool, italic: Bool) {
        let traits = CTFontGetSymbolicTraits(font)
        return (traits.contains(.traitBold), traits.contains(.traitItalic))
    }

    // MARK: - 順序 (合成の材料。どの機械でも同じ答え)

    /// Helvetica の面 (どの macOS にもある) を「書体が持つ面」に見立てる。`offered` に含まれる性質の
    /// 組だけ、その面を返す。それ以外は `nil` (面が無い書体)。
    private static func order(
        request: CTFontSymbolicTraits, offered: [CTFontSymbolicTraits]
    ) -> (postScript: String, lacks: Bool) {
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let faces: [(CTFontSymbolicTraits, String)] = [
            ([.traitBold, .traitItalic], "Helvetica-BoldOblique"), (.traitBold, "Helvetica-Bold"),
            (.traitItalic, "Helvetica-Oblique"),
        ]
        let result = Typeface.styledFace(of: helvetica, traits: request) { wanted in
            guard offered.contains(wanted), let name = faces.first(where: { $0.0 == wanted })?.1
            else { return nil }
            return CTFontCreateWithName(name as CFString, 12, nil)
        }
        return (CTFontCopyPostScriptName(result.font) as String, result.lacksStyle)
    }

    @Test("太斜体が引けないときの順序: 太斜体 → 太字だけ → 斜体だけ → 元の面", arguments: [
        // (書体が出す面, 期待する面, 面が無かったか)
        ([[.traitBold, .traitItalic], .traitBold, .traitItalic], "Helvetica-BoldOblique", false),
        ([.traitBold, .traitItalic], "Helvetica-Bold", true),  // 太字も斜体もあるが太斜体が無い: 太字を取る
        ([.traitBold], "Helvetica-Bold", true),
        ([.traitItalic], "Helvetica-Oblique", true),  // 斜体だけ
        ([], "Helvetica", true),  // 何も無い: 元の面
    ] as [([CTFontSymbolicTraits], String, Bool)])
    func partialFacesAreUsedInOrder(
        _ offered: [CTFontSymbolicTraits], _ drawn: String, _ lacks: Bool
    ) {
        let result = Self.order(request: [.traitBold, .traitItalic], offered: offered)
        #expect(result.postScript == drawn)
        #expect(result.lacks == lacks)
    }

    @Test("太字・斜体だけを頼んだときは、順序の対象外 (頼んだ面か、無ければ元の面)")
    func aSinglePropertyRequestIsNotReordered() {
        #expect(Self.order(request: .traitBold, offered: [.traitItalic]) == ("Helvetica", true))
        #expect(Self.order(request: .traitItalic, offered: [.traitBold]) == ("Helvetica", true))
        #expect(Self.order(request: .traitBold, offered: [.traitBold]) == ("Helvetica-Bold", false))
    }

    // MARK: - 環境の書体 (期待は CoreText への独立な問い合わせから導く)

    @Test("Helvetica は太斜体を持つので、太斜体のまま")
    func helveticaKeepsBoldItalic() {
        let typeface = Self.face("Helvetica", .boldItalic)
        #expect(CTFontCopyPostScriptName(typeface.base) as String == "Helvetica-BoldOblique")
        #expect(!typeface.lacksRequestedStyle)
    }

    /// 全ファミリーで、順序どおりの面を使う。**家族の分類 (太斜体・太字だけ・斜体だけ・無い) は
    /// この環境で決まる** ので、ある分類が 1 件も無い機械ではその分類の検査は何も見ない
    /// (順序そのものは上の合成の検査が見る)。
    @Test("どのファミリーも、太斜体 → 太字 → 斜体の順に、引ける性質を捨てない")
    func everyFamilyKeepsTheBestAvailableTraits() throws {
        let families = FamilySurvey.families()
        try #require(families.contains("Helvetica"), "前提: 書体の一覧に Helvetica がある")
        var wrong: [String] = []
        for family in families {
            let typeface = Self.face(family, .boldItalic)
            guard let expected = FamilySurvey.expectedBoldItalic(of: family) else {
                if !typeface.lacksRequestedStyle { wrong.append("\(family): 面が無いのに警告が立たない") }
                continue
            }
            let got = Self.traits(of: typeface.base)
            if CTFontCopyPostScriptName(typeface.base) as String != expected.postScript
                || got.bold != expected.bold || got.italic != expected.italic
                || typeface.lacksRequestedStyle == expected.exact
            {
                wrong.append(
                    "\(family): 期待 \(expected.postScript) 実際 \(CTFontCopyPostScriptName(typeface.base) as String)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) 件: \(wrong.prefix(10))")
    }
}
