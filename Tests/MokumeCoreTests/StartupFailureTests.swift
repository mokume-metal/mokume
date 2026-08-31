// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 起動できなかったときに出る文面 (#527・#600)。GPU は要らない。
///
/// **見ているのは 4 つ** — どの失敗も次にすることを持った文面を出すこと、その文面に
/// 内部の名前が漏れていないこと、起動の行がその文面を経由すること、走っている最中の
/// 警告が 1 行に収まっていること。
///
/// アンブレラ 1 つ (`import mokume`) の視界から文面へ届くかは、ここでは見られない
/// (`@testable` で internal まで見えてしまうため)。そちらは `PackageStructureTests` が持つ。
@Suite("起動できなかったときの名乗り")
struct StartupFailureTests {
    /// 文面を確かめる検体。**``RenderFailure`` の全 case を 1 つずつ持つ。**
    ///
    /// **綴りは手で書く。** ``RenderFailure`` を `CustomStringConvertible` へ準拠させたので
    /// `String(describing:)` は人の文面を返すようになり、付随値を持たない case の綴りを
    /// 反射から得る道が無くなった (#600)。覆えているかは下の検査が原文と突き合わせるので、
    /// case を足した人がここへ足し忘れると赤くなる。
    static let samples: [(name: String, failure: RenderFailure)] = [
        ("deviceUnavailable", .deviceUnavailable),
        ("commandQueueUnavailable", .commandQueueUnavailable),
        ("commandAllocatorUnavailable", .commandAllocatorUnavailable),
        ("commandBufferUnavailable", .commandBufferUnavailable),
        ("residencySetUnavailable", .residencySetUnavailable(reason: "常駐の宣言が多すぎる")),
        ("synchronizationUnavailable", .synchronizationUnavailable),
        ("textureUnavailable", .textureUnavailable(width: 8192, height: 8192)),
        ("bufferUnavailable", .bufferUnavailable(byteCount: 1024)),
        ("encoderUnavailable", .encoderUnavailable),
        ("timedOut", .timedOut(seconds: 5)),
        ("invalidSize", .invalidSize(width: 0, height: 120)),
        ("invalidPixelDensity", .invalidPixelDensity(1.5)),
        ("upscalerUnavailable", .upscalerUnavailable(reason: "拡大器を作れない")),
        ("shaderSourceMissing", .shaderSourceMissing(name: "Shapes.metal")),
        (
            "shaderCompilationFailed",
            .shaderCompilationFailed(name: "blur", reason: "unknown identifier 'radius'")
        ),
        ("shaderCompilerUnavailable", .shaderCompilerUnavailable),
        ("pipelineUnavailable", .pipelineUnavailable(reason: "入口が見つからない")),
        ("argumentTableUnavailable", .argumentTableUnavailable(reason: "テーブルを作れない")),
        ("samplerUnavailable", .samplerUnavailable),
        ("displaySurfaceUnavailable", .displaySurfaceUnavailable),
    ]

    /// リポジトリ直下。原文を読む検査が使う。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ直下
    }

    /// 原文が宣言している case の綴り。
    ///
    /// 読むのは宣言の側だけ — `switch` の中の `case .〜` は `.` で始まるので拾わない。
    static func declaredCases() throws -> Set<String> {
        let source = repositoryRoot
            .appendingPathComponent("Sources/MokumeCore/Rendering/RenderFailure.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        return Set(
            text.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("case ") else { return nil }
                let name = trimmed.dropFirst("case ".count).prefix { $0.isLetter || $0.isNumber }
                return name.isEmpty ? nil : String(name)
            })
    }

    @Test("検体が全 case を覆っている")
    func theSamplesCoverEveryCase() throws {
        let declared = try Self.declaredCases()
        #expect(!declared.isEmpty)
        let covered = Set(Self.samples.map(\.name))
        let missing = declared.subtracting(covered).sorted()
        #expect(missing.isEmpty, "文面を確かめていない case がある: \(missing.joined(separator: " / "))")
        // 綴りを手で書くので、宣言に無い名前が残っていないかも見る (case を消した人の
        // 消し忘れ・打ち間違いがここで出る)
        let unknown = covered.subtracting(declared).sorted()
        #expect(unknown.isEmpty, "宣言に無い綴りが検体に残っている: \(unknown.joined(separator: " / "))")
    }

    @Test("どの失敗も、次にすることまで書いた文面を出す")
    func everyFailureSaysWhatToDoNext() {
        for (name, failure) in Self.samples {
            let lines = failure.description.split(separator: "\n")
            #expect(lines.count >= 2, "\(name) の文面が状態の報告だけで終わっている")
        }
    }

    @Test("文面に内部の名前が出ない")
    func theMessagesDoNotLeakInternalNames() {
        for (name, failure) in Self.samples {
            let text = failure.description
            #expect(!text.contains(name), "\(name) の文面に case の綴りが漏れている")
            #expect(!text.contains("RenderFailure"), "\(name) の文面に型の名前が漏れている")
        }
    }

    @Test("同梱の断片が見つからないときは、包みの中を見るよう促す")
    func theMissingShaderMessagePointsIntoTheBundle() {
        let text = RenderFailure.shaderSourceMissing(name: "Shapes.metal").description
        #expect(text.contains("Shapes.metal"))
        #expect(text.contains("\(ModuleResources.bundleName).bundle"))
    }

    @Test("起動できなかったときに出るのは、人が読む側の文面")
    func theStartupTextCarriesTheReadableMessage() {
        let failure = RenderFailure.shaderSourceMissing(name: "Shapes.metal")
        let text = startupFailureText(failure)
        #expect(text.contains(failure.description))
        #expect(!text.contains("shaderSourceMissing"))
        #expect(text.hasSuffix("\n"))
    }

    /// 走っている最中の警告は 1 行に保つ (#600)。
    ///
    /// `Diagnostics.warn` は宣言自身が「1 行、標準エラーへ書く」と名乗っており、毎フレーム
    /// 起こりうる失敗に多行を流すと本当に読むべき行が埋まる。準拠を入れた副作用で
    /// `\(failure)` が多行になったので、そちらの経路が 1 行のままかをここで見る。
    @Test("走っている最中に出す行は 1 行で、文面の先頭行と一致する")
    func theHeadlineStaysOneLine() {
        for (name, failure) in Self.samples {
            let headline = failure.headline
            #expect(!headline.contains("\n"), "\(name) の 1 行が多行になっている")
            #expect(!headline.isEmpty, "\(name) の 1 行が空になっている")
            #expect(
                failure.description.hasPrefix(headline),
                "\(name) の 1 行が文面の先頭行と食い違っている")
        }
    }

    /// 参照スケッチが裸の `try` へ戻る退行を捕まえる (#600)。
    ///
    /// **原文をテキストとして読む。** `reference-sketches` は独立した executableTarget で
    /// どこからも import できないので、振る舞いを呼んで確かめる道が無い。top-level の
    /// 裸の `try` は Swift ランタイムの既定処理へ落ちて内部の姿をそのまま出すため、
    /// 「throw しうる行がすべて `do` の中 (= 字下げの中) にある」ことを見る。
    @Test("参照スケッチの入口に裸の try が残っていない")
    func theReferenceSketchCatchesItsFailures() throws {
        let source = Self.repositoryRoot.appendingPathComponent("Sketches/main.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        var found = 0
        var bare: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 説明文の中の `try` は落とす (この検査自身の理由も `try` の話なので必ず当たる)。
            // **語として切ってから見る** — 部分一致で拾うと `let entry = …` が当たる
            let words = trimmed.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            guard !trimmed.hasPrefix("//"), words.contains("try") else { continue }
            found += 1
            if line.first?.isWhitespace != true { bare.append(trimmed) }
        }
        #expect(found > 0, "try を含む行が 1 つも無い — 検査が空回りしている")
        #expect(bare.isEmpty, "do の外に try が残っている: \(bare.joined(separator: " / "))")
    }
}
