// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// ひな形の差し込み ([#2489](https://github.com/mokume-metal/mokume/issues/2489))。
///
/// **差し込んだ値は、打たれたとおりに出る。** 値を 1 つずつ順に置換していた頃は、値の中の
/// `{{鍵}}` が後から差し込む鍵に置き換えられ、`Dictionary` の並び (プロセスごとに変わる) で
/// 結果が変わった。
@Suite("ひな形の差し込み")
struct TemplatesTests {
    /// 値が互いの鍵を全部運ぶ組。**どの順で差し込んでも、先に差し込まれた値は後の鍵に
    /// 置き換えられる** — 並びが偶然合って緑になる余地が無い (鍵が 2 つ以上あれば、先頭に
    /// 処理される鍵の値の中に、後ろの鍵が必ず居る)。
    private static let keys = ["A", "B", "C", "D", "E"]
    private static let everyPlaceholder = keys.map { "{{\($0)}}" }.joined()

    @Test("値の中の {{鍵}} は、差し込まれた後に置き換え直されない (どの並びでも)")
    func aValueIsNotSubstitutedAgain() {
        let values = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, Self.everyPlaceholder) })
        let text = Self.keys.map { "{{\($0)}}" }.joined(separator: "|")
        let expected = Self.keys.map { _ in Self.everyPlaceholder }.joined(separator: "|")
        #expect(Templates.substitute(text, values) == expected)
    }

    /// 完了条件の例そのもの。
    ///
    /// **この組は並びが合えば直す前でも緑になる** (B が先に差し込まれる回)。直す前に確実に赤に
    /// なるのは上の組で、これは例の記録である。
    @Test("{{A}}{{B}} に A = {{B}}・B = x を渡すと、いつも {{B}}x")
    func theExampleFromTheIssue() {
        #expect(Templates.substitute("{{A}}{{B}}", ["A": "{{B}}", "B": "x"]) == "{{B}}x")
    }

    /// 変わらないこと。**値の無い鍵は、そのまま出力に残る** (`substitute` の説明) — ひな形に
    /// 鍵を足して渡し忘れたとき、検査が見つけられる。
    @Test("値の無い鍵と、鍵でない {{ }} は、そのまま残る")
    func unknownKeysAndStrayBracesStayAsTheyAre() {
        #expect(Templates.substitute("{{A}} {{NOPE}}", ["A": "x"]) == "x {{NOPE}}")
        #expect(Templates.substitute("{{ A }}", ["A": "x"]) == "{{ A }}")
        #expect(Templates.substitute("{{A", ["A": "x"]) == "{{A")
        #expect(Templates.substitute("A}}", ["A": "x"]) == "A}}")
        #expect(Templates.substitute("{{}}", ["A": "x"]) == "{{}}")
        #expect(Templates.substitute("", ["A": "x"]) == "")
        #expect(Templates.substitute("{{A}}", [:]) == "{{A}}")
    }

    /// 同じ鍵が何度出ても、毎回差し込まれる。鍵の外側の波括弧は置換を邪魔しない。
    @Test("同じ鍵は何度でも差し込まれ、外側の波括弧は置換を妨げない")
    func repeatedKeysAndSurroundingBraces() {
        #expect(Templates.substitute("{{A}}{{A}}", ["A": "x"]) == "xx")
        #expect(Templates.substitute("{{{A}}}", ["A": "x"]) == "{x}")
        #expect(Templates.substitute("{{{{A}}", ["A": "x"]) == "{{x")
        // 値に日本語や改行があっても、そのまま
        #expect(Templates.substitute("<{{A}}>", ["A": "日本\n語"]) == "<日本\n語>")
    }

    /// `new s --local '/libs/{{TYPE}}'` — 差し込む値のうち `{{鍵}}` を運べるのは `--local` から
    /// 作る `DEPENDENCY` だけで (`NAME`・`TARGET`・`TYPE` は `isValid(name:)` が `{` を通さない)、
    /// その場所が `Package.swift` にそのまま書かれる。
    ///
    /// **この検査は並びが合えば直す前でも緑になる** (`DEPENDENCY` が最後に差し込まれる回 —
    /// 鍵 5 つのうちの 1 通り)。確実に赤になるのは 1 つ目の組で、こちらは `new` の口から
    /// 同じ約束が守られていることを見る。
    @Test("--local に {{TYPE}} などがあっても、Package.swift には打たれたとおりに書かれる")
    func aLocalCarryingPlaceholdersIsWrittenAsTyped() throws {
        let local = "/libs/{{TYPE}}/{{NAME}}/{{TARGET}}/{{PACKAGE}}"
        let manifest = try #require(
            try NewCommand.files(for: .init(name: "s", local: local))
                .first { $0.0 == "Package.swift" }?.1)
        #expect(manifest.contains(".package(path: \"\(local)\")"), "差し込み直された: \(manifest)")
    }
}
