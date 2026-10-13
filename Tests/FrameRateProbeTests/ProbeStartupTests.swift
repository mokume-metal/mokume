// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import frame_rate_probe

/// 測り始める前の準備に失敗したとき、名乗って落ちること (#2541)。
///
/// 裸の `try` のままだと Swift ランタイムの既定処理へ落ち、`Fatal error: Error raised at top
/// level: …` と内部の姿をそのまま出して trap していた。
@Suite("frame-rate-probe の起動失敗")
struct ProbeStartupTests {
    /// 描画の土台が投げる失敗の代役。**中身を持つのは失敗の側** (`RenderFailure` は
    /// 何が足りないかと次にすることを自分の文面に持つ) なので、道具はそれを書き換えない。
    private struct Stub: Error, CustomStringConvertible {
        let description: String
    }

    @Test("見出しと失敗の中身を出し、ランタイムの既定の文面を使わない")
    func namesWhatFailedAndWhy() {
        let message = ProbeStartup.message(for: Stub(description: "Cannot find the source of a shader: probe.metal"))
        #expect(message.hasPrefix(ProbeStartup.headline + "\n"))
        // 失敗の中身 (何が足りないか) が、そのまま載る
        #expect(message.contains("Cannot find the source of a shader: probe.metal"))
        #expect(message.hasSuffix("\n"))
        #expect(!message.contains("Fatal error"))
        #expect(!message.contains("Error raised at top level"))
    }

    /// `main.swift` が文面の組み立てへ繋がっていること。
    ///
    /// **原文をテキストとして読む。** 最上位は走らせると窓を開くので、呼んで確かめる道が無い
    /// (`Tests/MokumeCoreTests/StartupFailureTests.swift` の `theReferenceSketchCatchesItsFailures`
    /// と同じ形・#600)。裸の `try` へ戻すと上の検査は緑のままなので、ここで見る。
    @Test("入口に裸の try が残らず、失敗は名乗って exit(1) に至る")
    func theEntryCatchesItsFailures() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FrameRateProbeTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ直下
            .appendingPathComponent("Sources/frame-rate-probe/main.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        var found = 0
        var bare: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 説明文の中の `try` は落とす。**語として切ってから見る** — 部分一致だと別の語が当たる
            let words = trimmed.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            guard !trimmed.hasPrefix("//"), words.contains("try") else { continue }
            found += 1
            // 字下げの外 (= do の外) に try がある。引数の解き方 (`try ProbeArguments.parse`) は
            // 自分の do/catch の中にあるので字下げされている
            if line.first?.isWhitespace != true { bare.append(trimmed) }
        }
        #expect(found > 0, "try を含む行が 1 つも無い — 検査が空回りしている")
        #expect(bare.isEmpty, "do の外に try が残っている: \(bare.joined(separator: " / "))")

        // 失敗は ProbeStartup の文面を標準エラーへ書いて exit(1) へ至る
        let handler = try #require(
            text.range(of: "ProbeStartup.message(for: error)").map { String(text[$0.lowerBound...]) },
            "起動の失敗が ProbeStartup.message を通っていない")
        let afterMessage = handler.split(separator: "\n").prefix(3).joined(separator: "\n")
        #expect(afterMessage.contains("exit(1)"), "名乗った後に exit(1) で終わっていない")
    }
}
