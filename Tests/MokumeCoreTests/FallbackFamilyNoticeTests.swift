// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 代わりの書体の面の知らせが、**家族に頼んだ面が無い**ことと、**その字を頼んだ面で持つ書体の例**を
/// 名乗る ([#2924])。字の描き方は変えない — 細い面のまま描く。
///
/// 太字を持たない欧文の書体に混ぜたハングル・タイ文字は、CoreText が太字を持たない家族
/// (AppleMyungjo・Ayuthaya) を選び、その家族の中に引き直せる面が無い。候補の列
/// (`CTFontCopyDefaultCascadeList`) にも、その字を太字で持つ別の家族は入っていない (実測は #2924)。
/// 直せないので、知らせの言い方を正す。
///
/// **CoreText への問い合わせは、被検査の `Typeface` を通さずに書く。**
///
/// [#2924]: https://github.com/mokume-metal/mokume/issues/2924
@Suite("代わりの書体の家族の知らせ")
struct FallbackFamilyNoticeTests {
    private static func font(_ name: String, _ size: CGFloat = 32) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    private static func traits(_ font: CTFont) -> CTFontSymbolicTraits { CTFontGetSymbolicTraits(font) }

    private static func fallback(of scalar: Unicode.Scalar, in name: String) -> CTFont {
        let text = String(scalar) as CFString
        return CTFontCreateForString(font(name), text, CFRangeMake(0, CFStringGetLength(text)))
    }

    private static func psName(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }

    /// 知らせの文面は `Canvas` が持つので、GPU を要する。入れ子の `@Suite` に分けて条件を掛ける
    /// (`GPUGateTests`)。
    @Suite(
        "文面",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct Notices {
        // MARK: - 本文の 3 件 (条件 1・2・3)

        /// 本文の表 (macOS 27)。指定した書体 (PostScript 名)・字・CoreText が引く代わりの書体。
        nonisolated static var reportedCases:
            [(font: String, family: String, scalar: Unicode.Scalar, fallback: String)]
        {
            [
                ("Apple Chancery", "Apple-Chancery", "한", "AppleMyungjo"),
                ("Zapfino", "Zapfino", "한", "AppleMyungjo"),
                ("Andale Mono", "AndaleMono", "ก", "Ayuthaya"),
            ]
        }

        @Test(
            "太字の無い書体に混ぜたハングル・タイ文字は、家族に太字が無いと名乗り、例を挙げ、字は細いまま描く",
            arguments: Notices.reportedCases)
        func theNoticeSaysTheFamilyHasNoBoldFace(
            _ item: (font: String, family: String, scalar: Unicode.Scalar, fallback: String)
        ) throws {
            try #require(
                FallbackFamilyNoticeTests.psName(FallbackFamilyNoticeTests.font(item.font)) == item.family, "前提: この環境に \(item.font) がある")
            // 独立に確かめる: CoreText が引く代わりの書体は太字の面を持たない家族のもの
            let picked = FallbackFamilyNoticeTests.fallback(of: item.scalar, in: item.font)
            try #require(
                FallbackFamilyNoticeTests.psName(picked) == item.fallback,
                "前提: CoreText は \(item.font) に無い \(item.scalar) を \(item.fallback) から引く")
            let lacking = CTFontCreateCopyWithSymbolicTraits(picked, 32, nil, .traitBold, .traitBold)
            try #require(
                lacking.map { !FallbackFamilyNoticeTests.traits($0).contains(.traitBold) } ?? true,
                "前提: \(item.fallback) の家族に太字の面が無い")

            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
            canvas.textFont(item.font)
            canvas.textStyle(.bold)
            _ = canvas.textWidth("a\(item.scalar)")

            // 字の描き方は変えない: 細い代わりの書体の面のまま
            let drawn = try #require(canvas.typeface.glyph(for: item.scalar))
            #expect(FallbackFamilyNoticeTests.psName(drawn.font) == item.fallback, "描く書体が替わった: \(FallbackFamilyNoticeTests.psName(drawn.font))")
            #expect(!FallbackFamilyNoticeTests.traits(drawn.font).contains(.traitBold))

            // 指定した書体の知らせは今までどおり 1 度、代わりの書体の知らせも 1 度
            #expect(canvas.warnings.hasWarned(.missingTypefaceStyle))
            let message = try #require(canvas.warnings.message(for: .missingFallbackTypefaceStyle))
            #expect(
                message.contains("The family of \"\(item.fallback)\" has no .bold face"),
                "家族に面が無いと言っていない: \(message)")
            // 引かなかったと読める書き方はしない
            #expect(!message.contains("could not find") && !message.contains("did not pick"), "\(message)")
            // 例: その字を太字で持つ書体の名前。環境から引くので、名前そのものではなく性質で見る
            let example = try #require(
                Self.exampleName(in: message), "例が挙がっていない: \(message)")
            let shown = FallbackFamilyNoticeTests.font(example)
            #expect(FallbackFamilyNoticeTests.psName(shown) == example, "例の名前が textFont() に渡せない: \(example)")
            #expect(FallbackFamilyNoticeTests.traits(shown).contains(.traitBold), "例が太字でない: \(example)")
            var units = Array(String(item.scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(shown, &units, &glyphs, units.count)
            #expect(glyphs[0] != 0, "例が字形を持たない: \(example)")
        }

        /// 文面の `for example "<名前>"` の名前。
        private static func exampleName(in message: String) -> String? {
            guard let range = message.range(of: "for example \"") else { return nil }
            let rest = message[range.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }

        // MARK: - 言い間違えない (家族が面を持つとき・例が頼んだ面を持たないとき)

        /// 家族が頼んだ面を持つのに、その面に字形だけが無いなら、「家族に面が無い」とは言わない。
        @Test("家族が面を持つが、その面に字形が無いときは、家族に面が無いとは言わない")
        func aFamilyWithTheFaceButNotTheGlyphIsNotSaidToLackIt() throws {
            let italic = CTFontCreateCopyWithSymbolicTraits(
                FallbackFamilyNoticeTests.font("EuphemiaUCAS"), 32, nil, .traitItalic, .traitItalic)
            try #require(
                italic.map { FallbackFamilyNoticeTests.psName($0) == "EuphemiaUCAS-Italic" } == true, "前提: Euphemia UCAS の斜体がある")
            try #require(
                FallbackFamilyNoticeTests.psName(FallbackFamilyNoticeTests.fallback(of: "\u{1400}", in: "EuphemiaUCAS")) == "EuphemiaUCAS",
                "前提: 斜体に無い U+1400 を、同じ家族の立体から引く")

            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
            canvas.textFont("EuphemiaUCAS")
            canvas.textStyle(.italic)
            _ = canvas.textWidth("\u{1400}")
            let message = try #require(canvas.warnings.message(for: .missingFallbackTypefaceStyle))
            #expect(!message.contains("The family of"), "家族は斜体を持つのに、無いと言った: \(message)")
        }

        /// 例を挙げるのは、返った書体が字形と頼んだ面の両方を持つときだけ。ヒラギノ角ゴシックの斜体は
        /// 無いので、システムの UI 書体の斜体から引いても頼んだ面は返らない。
        @Test("例が頼んだ面を持たなければ、例を挙げない")
        func noExampleWhenNothingHasTheFace() throws {
            let picked = FallbackFamilyNoticeTests.fallback(of: "あ", in: "Helvetica-Oblique")
            try #require(FallbackFamilyNoticeTests.psName(picked) == "HiraginoSans-W3", "前提: 斜体に無い「あ」をヒラギノ角ゴシックから引く")
            let system = try #require(CTFontCreateUIFontForLanguage(.system, 32, nil))
            let styled =
                CTFontCreateCopyWithSymbolicTraits(system, 32, nil, .traitItalic, .traitItalic) ?? system
            let found = CTFontCreateForString(styled, "あ" as CFString, CFRangeMake(0, 1))
            try #require(
                !FallbackFamilyNoticeTests.traits(found).contains(.traitItalic), "前提: システムの UI 書体の斜体から「あ」を引いても斜体の面は返らない")

            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
            canvas.textFont("Helvetica")
            canvas.textStyle(.italic)
            _ = canvas.textWidth("あ")
            let message = try #require(canvas.warnings.message(for: .missingFallbackTypefaceStyle))
            #expect(!message.contains("for example"), "例を挙げた: \(message)")
            // 家族に斜体が無いことは、いままでの文面に加えて名乗る
            #expect(message.contains("The family of \"HiraginoSans-W3\" has no .italic face"), "\(message)")
        }
    }

    // MARK: - 取り出す口 (GPU を使わない)

    @Test("頼んだ面が何も無ければ、家族に面が無いとも例を挙げるとも言わない")
    func nothingRequestedSaysNothing() {
        #expect(!Typeface.familyLacksFace(of: Self.font("AppleMyungjo"), requested: []))
        #expect(Typeface.exampleTypeface(for: "한", requested: [], size: 32) == nil)
    }

    @Test("太字の無い家族は面が無く、太字を持つ家族は面がある")
    func familiesAreToldApart() throws {
        let myungjo = Self.font("AppleMyungjo")
        try #require(Self.psName(myungjo) == "AppleMyungjo", "前提: AppleMyungjo がある")
        #expect(Typeface.familyLacksFace(of: myungjo, requested: .traitBold))
        let sdGothic = Self.font("AppleSDGothicNeo-Regular")
        try #require(Self.psName(sdGothic) == "AppleSDGothicNeo-Regular", "前提: AppleSDGothicNeo がある")
        #expect(!Typeface.familyLacksFace(of: sdGothic, requested: .traitBold))
    }

    @Test("例は、字形と頼んだ面の両方を持つ名前だけで、内部名は挙げない")
    func theExampleHasTheGlyphAndTheFace() throws {
        let name = try #require(
            Typeface.exampleTypeface(for: "한", requested: .traitBold, size: 32),
            "前提: この環境にハングルを太字で持つ書体がある")
        #expect(!name.hasPrefix("."))
        let font = Self.font(name)
        #expect(Self.psName(font) == name)
        #expect(Self.traits(font).contains(.traitBold))
        // 豆腐 (私用領域) の字は、どの太字も持たない
        #expect(Typeface.exampleTypeface(for: "\u{E000}", requested: .traitBold, size: 32) == nil)
    }
}
