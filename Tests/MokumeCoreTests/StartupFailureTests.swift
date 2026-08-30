// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 起動できなかったときに出る文面 (#527)。GPU は要らない。
///
/// **見ているのは 3 つ** — どの失敗も次にすることを持った文面を出すこと、その文面に
/// 内部の名前が漏れていないこと、起動の行がその文面を経由すること。3 つ目は
/// `\(error)` へ戻る退行を捕まえるためにある。
@Suite("起動できなかったときの名乗り")
struct StartupFailureTests {
    /// 文面を確かめる検体。**``RenderFailure`` の全 case を 1 つずつ持つ。**
    ///
    /// 覆えているかは下の検査が原文と突き合わせるので、case を足した人がここへ
    /// 足し忘れると赤くなる。
    static let samples: [RenderFailure] = [
        .deviceUnavailable,
        .commandQueueUnavailable,
        .commandAllocatorUnavailable,
        .commandBufferUnavailable,
        .residencySetUnavailable(reason: "常駐の宣言が多すぎる"),
        .synchronizationUnavailable,
        .textureUnavailable(width: 8192, height: 8192),
        .bufferUnavailable(byteCount: 1024),
        .encoderUnavailable,
        .timedOut(seconds: 5),
        .invalidSize(width: 0, height: 120),
        .invalidPixelDensity(1.5),
        .upscalerUnavailable(reason: "拡大器を作れない"),
        .shaderSourceMissing(name: "Shapes.metal"),
        .shaderCompilationFailed(name: "blur", reason: "unknown identifier 'radius'"),
        .shaderCompilerUnavailable,
        .pipelineUnavailable(reason: "入口が見つからない"),
        .argumentTableUnavailable(reason: "テーブルを作れない"),
        .samplerUnavailable,
        .displaySurfaceUnavailable,
    ]

    /// case の綴り。付随する値を持つものは `Mirror` の札が、持たないものは記述がそれになる。
    static func caseName(of failure: RenderFailure) -> String {
        Mirror(reflecting: failure).children.first?.label ?? String(describing: failure)
    }

    /// 原文が宣言している case の綴り。
    ///
    /// 読むのは宣言の側だけ — `switch` の中の `case .〜` は `.` で始まるので拾わない。
    static func declaredCases() throws -> Set<String> {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ直下
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
        let covered = Set(Self.samples.map(Self.caseName(of:)))
        let missing = declared.subtracting(covered).sorted()
        #expect(missing.isEmpty, "文面を確かめていない case がある: \(missing.joined(separator: " / "))")
    }

    @Test("どの失敗も、次にすることまで書いた文面を出す")
    func everyFailureSaysWhatToDoNext() {
        for failure in Self.samples {
            let text = failure.message
            let lines = text.split(separator: "\n")
            #expect(lines.count >= 2, "\(Self.caseName(of: failure)) の文面が状態の報告だけで終わっている")
        }
    }

    @Test("文面に内部の名前が出ない")
    func theMessagesDoNotLeakInternalNames() {
        for failure in Self.samples {
            let text = failure.message
            #expect(!text.contains(Self.caseName(of: failure)))
            #expect(!text.contains(String(describing: failure)))
        }
    }

    @Test("同梱の断片が見つからないときは、包みの中を見るよう促す")
    func theMissingShaderMessagePointsIntoTheBundle() {
        let text = RenderFailure.shaderSourceMissing(name: "Shapes.metal").message
        #expect(text.contains("Shapes.metal"))
        #expect(text.contains("\(ModuleResources.bundleName).bundle"))
    }

    @Test("起動できなかったときに出るのは、人が読む側の文面")
    func theStartupTextCarriesTheReadableMessage() {
        let failure = RenderFailure.shaderSourceMissing(name: "Shapes.metal")
        let text = startupFailureText(failure)
        #expect(text.contains(failure.message))
        #expect(!text.contains(String(describing: failure)))
        #expect(text.hasSuffix("\n"))
    }
}
