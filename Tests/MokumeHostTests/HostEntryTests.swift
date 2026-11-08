// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

/// `MokumeHost` はスケッチを書く人の入口 `mokume` から再エクスポートしない (ADR-0048 決定 1・#3870)。
///
/// 「`import mokume` だけのファイルで `HeadlessRun` が見えない」は、組めないことなので検査で組んで確かめ
/// られない。代わりに、見えるようになる 2 つの道 (アンブレラが再エクスポートする・依存に入る) を原文で塞ぐ。
@Suite("MokumeHost の入口")
nonisolated struct HostEntryTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/MokumeHostTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // パッケージの根

    @Test("アンブレラ mokume は MokumeHost を再エクスポートしない")
    func umbrellaDoesNotReexport() throws {
        let umbrella = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/mokume/Umbrella.swift"), encoding: .utf8)
        let imports = umbrella.split(separator: "\n").filter { $0.contains("import") && $0.contains("MokumeHost") }
        #expect(imports.isEmpty, "Umbrella.swift が MokumeHost を import している: \(imports)")
    }

    @Test("アンブレラ mokume のターゲットは MokumeHost に依存しない")
    func umbrellaDoesNotDependOnHost() throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        // `.target(name: "mokume", …)` から次のターゲットの宣言までが、アンブレラの宣言
        let start = try #require(
            manifest.range(of: #"\.target\(\s*name: "mokume","#, options: .regularExpression))
        let rest = manifest[start.upperBound...]
        let end = rest.range(of: ".target(")?.lowerBound ?? rest.endIndex
        #expect(!rest[..<end].contains("MokumeHost"))
    }
}
