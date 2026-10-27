// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 保存して差し替えに失敗したときの、端末の警告の 1 行 (#2784)。**GPU を使わない** — Metal の
/// 理由の文面の例を入れて、警告を組む規則だけを見る (実際の断片で出ることは `ShaderErrorLineTests` が
/// GPU で見る)。
///
/// 変更前の警告は `Cannot build the shader: waves` で止まり、直す行 (`waves.metal:2:12`) は観測の
/// `failure` にしか載らなかった。
@Suite("差し替えの失敗の警告")
struct ShaderRebuildWarningTests {
    /// 前置きの警告が前に並ぶ、実測の形の理由 (#2782 の実測・2026-10-18)。
    private static let reasonWithWarnings = """
        mokume/Common.metal:330:22: warning: unused function 'mokume_unused' [-Wunused-function]
        static float mokume_unused(float x) { return x; }
                     ^
        waves.metal:2:12: error: use of undeclared identifier 'foo'
            return foo;
                   ^
        waves.metal:5:3: error: expected ';' after expression
        """

    private static func failure(_ reason: String) -> RenderFailure {
        .shaderCompilationFailed(name: "waves", reason: reason)
    }

    @Test("組み立ての誤りは、警告の 1 行の後ろに最初の error: の行が続き、改行は入らない")
    func theFirstErrorLineIsAppended() {
        let reason = "waves.metal:2:12: error: use of undeclared identifier 'foo'\n    return foo;\n           ^"
        let warning = ShaderBox.rebuildWarning(for: Self.failure(reason))
        #expect(
            warning
                == "could not rebuild the fragment: Cannot build the shader: waves — "
                + "waves.metal:2:12: error: use of undeclared identifier 'foo'")
        #expect(!warning.contains("\n"))
    }

    @Test("前に警告の行があっても、載るのは最初の error: の行で、2 つ目の error: は載らない")
    func warningsBeforeTheErrorAreSkipped() {
        let warning = ShaderBox.rebuildWarning(for: Self.failure(Self.reasonWithWarnings))
        #expect(warning.hasSuffix(" — waves.metal:2:12: error: use of undeclared identifier 'foo'"), "\(warning)")
        #expect(!warning.contains("warning:"), "\(warning)")
        #expect(!warning.contains("5:3"), "\(warning)")
        #expect(!warning.contains("\n"))
    }

    @Test("入口を書き違えた断片は、Metal の Undefined symbol(s) ではなく、言い直しの行が載る (#2782)")
    func aRestatedEntryWinsOverTheLinkerLine() {
        let metal = """
            Undefined symbol(s) for architecture 'air64':
              '_Z5paint8Fragment6Values', referenced from:
                  mokume_shapeColor in program_object_0
            error: symbol(s) not found for target 'air64-apple-macosx27.0.0'
            """
        let reason = ShaderEntryPoint.paint(surfaces: false).restating(metal, in: "waves.metal")
        let warning = ShaderBox.rebuildWarning(for: Self.failure(reason))
        #expect(
            warning.contains(
                " — waves.metal: error: the fragment does not define its entry point "
                    + "float4 paint(Fragment in, Values values)"),
            "\(warning)")
        #expect(!warning.contains("Undefined symbol"), "\(warning)")
        #expect(!warning.contains("\n"))
    }

    @Test("error: の行が無い理由と、組み立てでない失敗は、今までどおり 1 行目だけ")
    func otherFailuresKeepTheHeadline() {
        let plain = ShaderBox.rebuildWarning(for: Self.failure("unexpected failure of the compiler"))
        #expect(plain == "could not rebuild the fragment: Cannot build the shader: waves")
        let missing = ShaderBox.rebuildWarning(for: .shaderSourceMissing(name: "Common.metal"))
        #expect(
            missing
                == "could not rebuild the fragment: "
                + "Cannot find the source of a shader that ships with mokume: Common.metal")
        // 理由に `error:` の行があっても、組み立ての誤りでなければ足さない
        let pipeline = ShaderBox.rebuildWarning(for: .pipelineUnavailable(reason: "waves.metal:1:1: error: odd"))
        #expect(pipeline == "could not rebuild the fragment: Cannot create the render pipeline: waves.metal:1:1: error: odd")
    }

    /// 警告の側だけを変える。観測の `failure` と投げる理由 (`description`) は、全文のまま。
    @Test("保存して差し替えに失敗すると、警告に行が載り、観測の failure と理由の全文は変わらない")
    func theWarningCarriesTheLineButTheFailureStaysWhole() throws {
        let directory = try TestScratch.directory("mokume-shader-warning")
        let url = directory.appendingPathComponent("waves.metal")
        try "good".write(to: url, atomically: false, encoding: .utf8)
        let box = ShaderBox(
            name: "waves", url: url, body: "good", values: [:], label: "shader", valuesHint: "")
        try "float4 paint() { return foo; }".write(to: url, atomically: false, encoding: .utf8)

        let digest = WarningDigest()
        let error = Self.failure(Self.reasonWithWarnings)
        Diagnostics.$digest.withValue(digest) {
            box.reload { (_: String) throws(RenderFailure) in throw error }
        }
        #expect(
            digest.takeUnreported()
                == [
                    "shader: could not rebuild the fragment: Cannot build the shader: waves — "
                        + "waves.metal:2:12: error: use of undeclared identifier 'foo'"
                ])
        #expect(box.failure == "\(error)")
        #expect("\(error)".contains("mokume/Common.metal:330:22: warning"), "理由の全文が削れた")
    }
}
