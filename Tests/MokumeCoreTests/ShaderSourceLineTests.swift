// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 組み立てた原稿の、区切りごとの名乗り (#2457)。**GPU を使わない** — 原稿の文字列だけを見る
/// (組み立ての誤りが実際にその名前と行で出ることは `ShaderErrorLineTests` が GPU で見る)。
///
/// 利用者の断片は、値の宣言・面の宣言・前置き (`Kinds.metal` と `Common`/`Effect`/`Compute.metal`)
/// の後ろにつないで組まれる。区切りの頭に `#line 1 "<名前>"` を差せば、誤りの行は区切りの中で
/// 数え直され、名前はその区切りの名前になる。**本文の名乗りが本文の 1 行目の直前に無いと、
/// 誤りの行は前置きのぶんだけずれる。** 前置きにも名乗りが無いと、前置きの中の誤りが利用者の
/// 名前で出る。
@Suite("組み立てた原稿の名乗り")
struct ShaderSourceLineTests {
    /// 名乗りの行 (`#line 1 "<名前>"`) と、そのすぐ次の行の組。原稿の上から順に。
    private static func directives(in source: String) -> [(name: String, next: String)] {
        let lines = source.components(separatedBy: "\n")
        var found: [(String, String)] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#line ") {
            found.append((line, index + 1 < lines.count ? lines[index + 1] : ""))
        }
        return found
    }

    private static let prelude: [ShaderSource.Part] = [
        .init(name: "mokume/Kinds.metal", text: "// kinds 1\n// kinds 2"),
        .init(name: "mokume/Common.metal", text: "// common 1\n// common 2\n"),
    ]

    @Test("値の宣言・前置きの各ファイル・本文の頭に、それぞれの名前で 1 行目を名乗る")
    func everyPartNamesItsFirstLine() throws {
        let body = "float4 paint(Fragment in, Values values) {\n    return foo;\n}"
        let source = ShaderSource.assemble(
            prelude: Self.prelude, values: ["level": 0.5],
            body: .init(name: "shader", text: body))
        let found = Self.directives(in: source)
        #expect(
            found.map(\.name) == [
                "#line 1 \"mokume/Values\"", "#line 1 \"mokume/Kinds.metal\"",
                "#line 1 \"mokume/Common.metal\"", "#line 1 \"shader\"",
            ], "\(source)")
        // 名乗りのすぐ次が、その区切りの 1 行目
        #expect(
            found.map(\.next) == [
                "struct Values {", "// kinds 1", "// common 1", "float4 paint(Fragment in, Values values) {",
            ])
        // 本文の 2 行目は、本文の名乗りから数えて 2 行目にある (誤りの `shader:2:12` がここを指す)
        let lines = source.components(separatedBy: "\n")
        let bodyStart = try #require(lines.lastIndex(of: "#line 1 \"shader\""))
        #expect(lines[bodyStart + 2] == "    return foo;")
    }

    @Test("本文はファイルから読めばファイル名、文字列から作れば name: の名前を名乗る")
    func theBodyIsNamedByItsFileOrItsName() {
        let url = URL(fileURLWithPath: "/tmp/sketch/assets/waves.metal")
        #expect(ShaderSource.bodyName("waves", url: url) == "waves.metal")
        #expect(ShaderSource.bodyName("shader", url: nil) == "shader")
        #expect(ShaderSource.bodyName("ripple", url: nil) == "ripple")
    }

    /// `name:` は利用者が何でも書ける。名乗りは C の文字列なので、`"` と `\` を逃がし、改行と
    /// 制御文字 (NUL を含む) は空白にし、`?` は三文字表記を作らないよう `\?` と書く — 逃がさないと、
    /// 名前の途中で文字列が閉じる・原稿が NUL で切れる・`??!` が `|` に読み替えられる。
    @Test("名前の中の引用符・逆斜線・改行・制御文字・疑問符は、名乗りを壊さない形にする", arguments: [
        ("my \"odd\" name", "#line 1 \"my \\\"odd\\\" name\""),
        ("back\\slash", "#line 1 \"back\\\\slash\""),
        ("two\nlines", "#line 1 \"two lines\""),
        ("crlf\r\nname", "#line 1 \"crlf name\""),
        ("nul\u{0}name", "#line 1 \"nul name\""),
        ("tab\tname", "#line 1 \"tab name\""),
        ("what??!", "#line 1 \"what\\?\\?!\""),
    ])
    func oddNamesAreEscaped(_ name: String, _ directive: String) {
        let source = ShaderSource.assemble(
            prelude: [], values: [:], body: .init(name: name, text: "// body"))
        let found = Self.directives(in: source)
        #expect(found.last?.name == directive, "\(source)")
        #expect(found.last?.next == "// body")
    }

    @Test("前置きの区切りは、本文の名前を名乗らない")
    func thePreludeNeverTakesTheBodysName() {
        let source = ShaderSource.assemble(
            prelude: Self.prelude, values: [:], body: .init(name: "Common.metal", text: "// body"))
        let names = Self.directives(in: source).map(\.name)
        // 利用者のファイルが Common.metal でも、前置きは mokume/ で見分けがつく
        #expect(names.filter { $0 == "#line 1 \"Common.metal\"" }.count == 1)
        #expect(names.last == "#line 1 \"Common.metal\"")
    }

    /// 本番の前置きの名前。区切りの名乗りは `ShaderLibraries.prelude(named:)` が付ける。
    @Test("本体が同梱する断片は mokume/ を頭に付けて名乗る")
    func bundledPartsAreNamedAsMokumes() {
        #expect(ShaderLibraries.bundledName("Common") == "mokume/Common.metal")
        #expect(ShaderLibraries.bundledName("Kinds") == "mokume/Kinds.metal")
    }
}
