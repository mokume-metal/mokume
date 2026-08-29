// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

// 検査の原文を読み、**GPU を要する検査に GPU の有無の条件が掛かっているか**を見る。
//
// ## なぜ要るか
//
// `RenderDevice.isAvailable` は実際に GPU へ問い合わせるので、**手元では必ず真になる**。
// つまり「GPU が無いときの経路」は手元からは踏めない分岐で、条件を付け忘れた検査は
// push して CI が赤くなるまで分からない ([#336](https://github.com/mokume-metal/mokume/pull/336)
// で 6 本が `commandQueueUnavailable` で落ちた・[#338](https://github.com/mokume-metal/mokume/issues/338))。
//
// 実行して確かめられない以上、**原文を読んで確かめる**しかない。
//
// ## 規則
//
// > `Tests/` の中で GPU を作れる場所は、`.enabled(if: RenderDevice.isAvailable, …)` が
// > 掛かった `@Suite` の内側だけ。
//
// 条件を **`@Test` ごとの注記ではなく `@Suite` の構造**で表す。注記は 1 本ずつ付ける物なので
// 付け忘れが起きる (#336 がまさにそれ) が、置き場所なら**同居している時点で分かる**。
// Swift Testing の trait は入れ子の `@Suite` と `@Test` へ継承されるので、表現力は落ちない —
// GPU を要する検査と要さない検査を 1 ファイルに置きたいときは、入れ子の `@Suite` に分ける
// (`ModelTests` がその形)。
//
// 判定が「型の入れ子」だけで済むのは、`RenderDevice` の生成が**唯一の根**だからである。
// `Canvas` も `RenderTarget` も `gpu:` を受け取る側なので、GPU を要する経路は必ずここから始まる。
//
// ## ここが見ないもの
//
// - **製品の側が内部で `RenderDevice` を作る経路** (`SketchApplication` など)。検査の原文には
//   現れないので、この検査では捕まらない。実害が出てから足す ([ADR-0008](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md))
// - 文字列の**補間の中にさらに文字列**が入る書き方。字句の追い方が単純なので取り違えうる
//   (この検査自身の見本も含め、いまの原文には無い)

/// GPU を作る場所に、GPU の有無の条件が掛かっているかを原文から見る。
@Suite("GPU の条件の付け忘れ")
struct GPUGateTests {
    @Test("GPU を作る検査には、必ず GPU の条件が掛かっている")
    func everyPlaceThatBuildsAGPUIsGated() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests

        // 原文が読めなければ**黙って通さない**。読めないまま緑にすると、この検査が
        // 効いているのかどうかが誰にも分からなくなる
        let names = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(!names.isEmpty, "検査の原文が 1 つも見つからない (\(root.path))")

        var reports: [String] = []
        for name in names {
            let source = try String(contentsOf: root.appending(path: name), encoding: .utf8)
            for violation in GPUGateScan.violations(in: source) {
                reports.append("Tests/\(name):\(violation.line) — \(violation.reason.explanation)")
            }
        }

        #expect(
            reports.isEmpty,
            """
            GPU を作っているのに、GPU の有無の条件が掛かっていない:

            \(reports.joined(separator: "\n"))

            その場所を囲む @Suite に .enabled(if: RenderDevice.isAvailable, "…") を掛ける。
            GPU を要さない検査と同居させたいときは、入れ子の @Suite に分ける。
            """)
    }

    // MARK: - 走査器そのものの検査
    //
    // 原文を読む検査は、**読み違えたときに黙って緑になる**のがいちばん危ない。
    // 見本の原文を直書きして、通す側と落とす側の両方を押さえる。

    @Test("条件の掛かった Suite の中なら通る")
    func aGatedSuitePasses() {
        let source = """
            @Suite("面", .enabled(if: RenderDevice.isAvailable, "GPU が要る"))
            struct SurfaceTests {
                @Test func draws() throws { let gpu = try RenderDevice() }
            }
            """
        #expect(GPUGateScan.violations(in: source).isEmpty)
    }

    @Test("条件の無い Suite の中は落ちる")
    func anUngatedSuiteFails() {
        let source = """
            @Suite("面")
            struct SurfaceTests {
                @Test func draws() throws { let gpu = try RenderDevice() }
            }
            """
        #expect(
            GPUGateScan.violations(in: source)
                == [.init(line: 3, reason: .ungatedType("SurfaceTests"))])
    }

    @Test("条件は入れ子の Suite へ継がれる")
    func nestedSuitesInheritTheGate() {
        let source = """
            @Suite("面", .enabled(if: RenderDevice.isAvailable, "GPU が要る"))
            struct SurfaceTests {
                @Suite("影")
                struct ShadowTests {
                    @Test func draws() throws { let gpu = try RenderDevice() }
                }
            }
            """
        #expect(GPUGateScan.violations(in: source).isEmpty)
    }

    @Test("外側に条件が無くても、内側の Suite に掛かっていれば通る")
    func aGatedNestedSuiteIsEnough() {
        let source = """
            @Suite("読み込み")
            struct ModelTests {
                @Test func parses() {}

                @Suite("面へ置く", .enabled(if: RenderDevice.isAvailable, "面を作るので GPU が要る"))
                struct OnCanvas {
                    @Test func draws() throws { let gpu = try RenderDevice() }
                }
            }
            """
        #expect(GPUGateScan.violations(in: source).isEmpty)
    }

    @Test("修飾子や属性が並んでいても、条件を読み落とさない")
    func modifiersAndOtherAttributesDoNotHideTheGate() {
        let source = """
            @MainActor
            @Suite(
                "面",
                .enabled(
                    if: RenderDevice.isAvailable,
                    "GPU が要る")
            )
            private final class SurfaceTests {
                @Test func draws() throws { let gpu = try RenderDevice() }
            }
            """
        #expect(GPUGateScan.violations(in: source).isEmpty)
    }

    @Test("注釈の中の見た目だけの出現は数えない")
    func occurrencesInCommentsAreIgnored() {
        let source = """
            /// 使い方は `let gpu = try RenderDevice()`。
            // let gpu = try RenderDevice()
            /* let gpu = try RenderDevice() */
            @Suite("面の寸法")
            struct FitTests {
                @Test func fits() {}
            }
            """
        #expect(GPUGateScan.violations(in: source).isEmpty)
    }

    @Test("文字列の中の見た目だけの出現は数えない")
    func occurrencesInStringLiteralsAreIgnored() {
        let source = #"""
            @Suite("見本")
            struct SampleTests {
                let single = "try RenderDevice()"
                let multi = """
                    try RenderDevice()
                    """
                @Test func holds() {}
            }
            """#
        #expect(GPUGateScan.violations(in: source).isEmpty)
    }

    @Test("型の外で GPU を作るのは、条件を掛けようがないので落とす")
    func occurrencesOutsideAnyTypeFail() {
        let source = """
            func sharedCanvas() throws -> Canvas {
                let gpu = try RenderDevice()
                return try Canvas(target: RenderTarget(gpu: gpu, width: 8, height: 8), gpu: gpu)
            }
            """
        #expect(GPUGateScan.violations(in: source) == [.init(line: 2, reason: .outsideAnyType)])
    }

    @Test("波括弧を含む文字列があっても、型の範囲を取り違えない")
    func bracesInsideStringsDoNotBreakTheScopes() {
        let source = #"""
            @Suite("見本")
            struct SampleTests {
                let broken = "}{"
                @Test func draws() throws { let gpu = try RenderDevice() }
            }
            """#
        #expect(
            GPUGateScan.violations(in: source)
                == [.init(line: 4, reason: .ungatedType("SampleTests"))])
    }
}

/// Swift の原文から「型の入れ子」と「語の出現」だけを取り出す、この検査のためだけの走査器。
///
/// 本物の構文解析はしない — 見たいのが「どの型の中に居るか」と「条件が掛かっているか」の
/// 2 点だけで、そこに要るのは**注釈と文字列を潰した上での波括弧の対応**だけだからである。
enum GPUGateScan {
    /// なぜ落ちたか。
    enum Reason: Equatable {
        /// この型 (と外側のどれか) に条件が掛かっていない。
        case ungatedType(String)
        /// 型の外に居るので、条件を掛けようがない。
        case outsideAnyType

        var explanation: String {
            switch self {
            case .ungatedType(let name):
                "\(name) に .enabled(if: RenderDevice.isAvailable, …) が掛かっていない"
            case .outsideAnyType:
                "型の外で GPU を作っている (条件を掛けようがない)"
            }
        }
    }

    struct Violation: Equatable {
        let line: Int
        let reason: Reason
    }

    /// GPU を作る根。`Canvas` も `RenderTarget` も `gpu:` を受け取る側なので、ここだけ見ればよい。
    private static let root = Array("RenderDevice(")
    /// 条件が掛かっていると認める書き方。
    private static let gate = Array("RenderDevice.isAvailable")

    static func violations(in source: String) -> [Violation] {
        let code = strippingCommentsAndStrings(Array(source))
        let types = typeScopes(in: code)

        return occurrences(of: root, in: code).compactMap { position -> Violation? in
            let line = lineNumber(of: position, in: code)
            guard let innermost = innermostType(containing: position, among: types) else {
                return Violation(line: line, reason: .outsideAnyType)
            }
            if isGated(types[innermost], among: types) { return nil }
            return Violation(line: line, reason: .ungatedType(types[innermost].name))
        }
    }

    // MARK: - 型の入れ子

    private struct TypeScope {
        let name: String
        /// 宣言の手前に並んでいた属性の原文 (`@Suite(…)` など)。
        let attributes: String
        /// 本体の `{` と、対応する `}` の位置。
        let bodyStart: Int
        let bodyEnd: Int
        /// この型を囲む型 (`typeScopes` の添字)。
        var parent: Int?
    }

    private static let declarationKeywords: Set<String> = [
        "struct", "class", "enum", "actor", "extension",
    ]
    /// 属性と宣言の間に挟まりうる語。ここを飛ばさないと属性まで遡れない。
    private static let modifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "package", "open", "final", "static",
        "indirect", "nonisolated",
    ]

    private static func typeScopes(in code: [Character]) -> [TypeScope] {
        var scopes: [TypeScope] = []
        var index = 0
        while index < code.count {
            guard isIdentifier(code[index]) else {
                index += 1
                continue
            }
            let wordStart = index
            while index < code.count, isIdentifier(code[index]) { index += 1 }
            // 直前が識別子の一部や `.` なら、それは宣言の始まりではない
            if wordStart > 0, isIdentifier(code[wordStart - 1]) || code[wordStart - 1] == "." {
                continue
            }
            guard declarationKeywords.contains(String(code[wordStart..<index])) else { continue }
            guard let name = identifier(after: index, in: code),
                let bodyStart = code[index...].firstIndex(of: "{"),
                let bodyEnd = matchingBrace(from: bodyStart, in: code)
            else { continue }
            scopes.append(
                TypeScope(
                    name: name, attributes: attributes(before: wordStart, in: code),
                    bodyStart: bodyStart, bodyEnd: bodyEnd, parent: nil))
        }

        // 左から順に見つけているので、自分より前に始まってまだ閉じていない型が親になる
        for child in scopes.indices {
            for candidate in stride(from: child - 1, through: 0, by: -1)
            where scopes[candidate].bodyEnd > scopes[child].bodyStart {
                scopes[child].parent = candidate
                break
            }
        }
        return scopes
    }

    private static func innermostType(containing position: Int, among types: [TypeScope]) -> Int? {
        types.indices
            .filter { types[$0].bodyStart < position && position < types[$0].bodyEnd }
            .max { types[$0].bodyStart < types[$1].bodyStart }
    }

    private static func isGated(_ type: TypeScope, among types: [TypeScope]) -> Bool {
        if Array(type.attributes).contains(subsequence: gate) { return true }
        guard let parent = type.parent else { return false }
        return isGated(types[parent], among: types)
    }

    /// 宣言の手前に並ぶ属性を、修飾子を飛ばしながら遡って集める。
    private static func attributes(before start: Int, in code: [Character]) -> String {
        var earliest = start
        var cursor = start - 1
        while cursor >= 0 {
            while cursor >= 0, code[cursor].isWhitespace { cursor -= 1 }
            guard cursor >= 0 else { break }

            // `@Suite(…)` のような引数つきの属性は、閉じ括弧から遡る
            if code[cursor] == ")" {
                guard let open = matchingParen(from: cursor, in: code) else { break }
                cursor = open - 1
                while cursor >= 0, code[cursor].isWhitespace { cursor -= 1 }
            }
            guard cursor >= 0, isIdentifier(code[cursor]) else { break }
            while cursor >= 0, isIdentifier(code[cursor]) { cursor -= 1 }
            let word = String(code[(cursor + 1)...].prefix { isIdentifier($0) })
            if cursor >= 0, code[cursor] == "@" {
                earliest = cursor
                cursor -= 1
                continue
            }
            guard modifiers.contains(word) else { break }
            earliest = cursor + 1
        }
        return String(code[earliest..<start])
    }

    // MARK: - 注釈と文字列を潰す

    /// 注釈と文字列リテラルを空白へ潰す。**長さと改行はそのまま**にするので、位置がそのまま
    /// 元の原文の行番号に使える。
    static func strippingCommentsAndStrings(_ source: [Character]) -> [Character] {
        var output = source
        var index = 0

        func blank(_ range: Range<Int>) {
            for position in range where output[position] != "\n" { output[position] = " " }
        }
        func next(_ position: Int) -> Character? {
            position + 1 < source.count ? source[position + 1] : nil
        }

        while index < source.count {
            if source[index] == "/", next(index) == "/" {
                var end = index
                while end < source.count, source[end] != "\n" { end += 1 }
                blank(index..<end)
                index = end
                continue
            }
            if source[index] == "/", next(index) == "*" {
                let end = endOfBlockComment(from: index, in: source)
                blank(index..<end)
                index = end
                continue
            }
            // 生文字列 (`##"…"##`) を含めて、引用符の手前の `#` を数える
            if source[index] == "#" || source[index] == "\"" {
                var hashes = 0
                var quote = index
                while quote < source.count, source[quote] == "#" {
                    hashes += 1
                    quote += 1
                }
                if quote < source.count, source[quote] == "\"" {
                    let end = endOfStringLiteral(quoteAt: quote, hashes: hashes, in: source)
                    blank(index..<end)
                    index = end
                    continue
                }
            }
            index += 1
        }
        return output
    }

    private static func endOfBlockComment(from start: Int, in source: [Character]) -> Int {
        var depth = 0
        var index = start
        while index < source.count {
            if source[index] == "/", index + 1 < source.count, source[index + 1] == "*" {
                depth += 1
                index += 2
                continue
            }
            if source[index] == "*", index + 1 < source.count, source[index + 1] == "/" {
                depth -= 1
                index += 2
                if depth == 0 { return index }
                continue
            }
            index += 1
        }
        return source.count
    }

    private static func endOfStringLiteral(quoteAt quote: Int, hashes: Int, in source: [Character])
        -> Int
    {
        let isMultiline =
            quote + 2 < source.count && source[quote + 1] == "\"" && source[quote + 2] == "\""
        let width = isMultiline ? 3 : 1

        func skippingHashes(from position: Int) -> Int? {
            var cursor = position
            var seen = 0
            while seen < hashes, cursor < source.count, source[cursor] == "#" {
                cursor += 1
                seen += 1
            }
            return seen == hashes ? cursor : nil
        }

        var index = quote + width
        while index < source.count {
            if source[index] == "\\", let after = skippingHashes(from: index + 1) {
                index = after + 1
                continue
            }
            // 1 行の文字列は閉じ忘れても行を跨がない (跨ぐと以降を丸ごと潰してしまう)
            if !isMultiline, source[index] == "\n" { return index }
            if source[index] == "\"" {
                var quotes = 0
                while quotes < width, index + quotes < source.count, source[index + quotes] == "\"" {
                    quotes += 1
                }
                if quotes == width, let after = skippingHashes(from: index + width) { return after }
                index += quotes
                continue
            }
            index += 1
        }
        return source.count
    }

    // MARK: - 細かい道具

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func identifier(after start: Int, in code: [Character]) -> String? {
        var index = start
        while index < code.count, code[index].isWhitespace { index += 1 }
        let name = String(code[index...].prefix { isIdentifier($0) || $0 == "." })
        return name.isEmpty ? nil : name
    }

    private static func matchingBrace(from start: Int, in code: [Character]) -> Int? {
        var depth = 0
        for index in start..<code.count {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func matchingParen(from start: Int, in code: [Character]) -> Int? {
        var depth = 0
        for index in stride(from: start, through: 0, by: -1) {
            if code[index] == ")" { depth += 1 }
            if code[index] == "(" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func occurrences(of needle: [Character], in code: [Character]) -> [Int] {
        guard code.count >= needle.count else { return [] }
        return (0...(code.count - needle.count)).filter {
            Array(code[$0..<($0 + needle.count)]) == needle
        }
    }

    private static func lineNumber(of position: Int, in code: [Character]) -> Int {
        code[..<position].filter { $0 == "\n" }.count + 1
    }
}

extension Array where Element == Character {
    fileprivate func contains(subsequence needle: [Character]) -> Bool {
        guard count >= needle.count else { return false }
        return (0...(count - needle.count)).contains {
            Array(self[$0..<($0 + needle.count)]) == needle
        }
    }
}
