// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 特化した関数に付ける名前 (`MTL4SpecializedFunctionDescriptor.specializedName`) に
/// 何が要求されるかを、実際に走らせて確かめる ([#776])。GPU を要する。
///
/// ## なぜ検査で持つのか
///
/// **名前の綴りを誤ると、パイプラインの作成は成功したまま断片が 1 度も走らない。**
/// エラーも警告も返らず、検証層 (`MTL_DEBUG_LAYER` / `MTL_SHADER_VALIDATION`) も黙るので、
/// 症状は「その列の図形が画面から消える」だけになる。[#775] の作業中に実際に踏み、
/// 原因が「特化の中身」ではなく「付けた名前」だと分かるまでに数時間かかった。
///
/// 手掛かりが 1 つも無い以上、**分かった振る舞いをここで固定しておく以外に残す先が無い**。
/// この検査は Metal の側の振る舞いを写したもので、mokume の側の要求ではない。
///
/// ## 分かっていること
///
/// - 名前は**特化した関数の新しい名前**である。Metal 3 の同名の口 (`MTLFunctionDescriptor`)
///   はそう書いている — 「`visible` な関数を別々の特化で使い回すための、新しい名前」。
///   つまり付けているのは飾りの札ではなく識別子で、C の識別子
///   (`[A-Za-z_][A-Za-z0-9_]*`) に沿わない綴りは解決されず `nil` になる
/// - Metal 4 の側 (`MTL4SpecializedFunctionDescriptor.h`) にはその記述が無く、
///   「Assigns an optional name to the specialized function.」の 1 行しか無い。
///   **名前の形についての要求はどこにも書かれていない**
/// - 断片段だけが黙るのは、**断片を持たないパイプラインが合法だから**である
///   (`ShapePipeline.makeDepthOnlyState` がそれを組んでいる)。頂点段・計算段では
///   同じ `nil` が「関数が要る」の表明に当たって異常終了する — どちらの表明も名前に
///   ついては何も言わないので、表明文から `specializedName` へは辿れない。
///   **この検査は頂点段・計算段を踏まない** (表明は検査ごと落とすため)
///
/// ## 分かっていないこと
///
/// 名前が識別子でなければならないのが仕様なのか、任意の名前を許して黙って落として
/// いるのが不具合なのかは決められない。どちらであっても現状の挙動は書かれたものと
/// 合わないので、Apple への報告の文面を [#776] に用意してある。
///
/// **報告が通って挙動が変わったら、この検査が赤で知らせる。** そのときは
/// `ShapePipeline.specialized(_:formFlags:)` の注記とあわせて更新する。
///
/// [#775]: https://github.com/mokume-metal/mokume/pull/775
/// [#776]: https://github.com/mokume-metal/mokume/issues/776
@Suite(
    "特化した関数の名前",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SpecializedNameTests {
    /// 断片が走ったかどうかだけを見るための、最小のシェーダ 1 本。
    ///
    /// 断片は既定値を持たない function constant を読むので、**特化しなければ組めない** —
    /// 「特化が効いているのに走らない」ことだけがこの検査に残る。
    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        constant bool kProbeRan [[function_constant(0)]];

        vertex float4 probeVertex(uint id [[vertex_id]]) {
            const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
            return float4(corners[id], 0, 1);
        }

        fragment float4 probeFragment() {
            return kProbeRan ? float4(0, 1, 0, 1) : float4(1, 0, 0, 1);
        }
        """

    /// 名前を渡して 1 枚描き、**断片が走ったか**を返す。
    ///
    /// 描画先を不透明な黒で塗ってから、全面を覆う三角形を 1 枚描く。走った断片は緑を
    /// 書き、走らなければ塗った黒がそのまま残る。
    private func fragmentRuns(specializedName: String?) throws -> Bool {
        let gpu = try RenderDevice()
        let library = try gpu.device.makeLibrary(source: Self.source, options: nil)
        let compilerDescriptor = MTL4CompilerDescriptor()
        compilerDescriptor.label = "mokume.tests.specializedName"
        let compiler = try gpu.device.makeCompiler(descriptor: compilerDescriptor)

        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = "probeVertex"
        vertexFunction.library = library

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = "probeFragment"
        fragmentFunction.library = library

        let values = MTLFunctionConstantValues()
        var ran = true
        values.setConstantValue(&ran, type: .bool, index: 0)

        let specialized = MTL4SpecializedFunctionDescriptor()
        specialized.functionDescriptor = fragmentFunction
        specialized.constantValues = values
        specialized.specializedName = specializedName

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "mokume.tests.probe"
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = specialized
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba8Unorm
        attachment.blendingState = .disabled

        // **ここは成功する。** 名前が解決できなくても投げも返しもしないのが、この
        // Issue が記録している振る舞いそのものである
        let state = try compiler.makeRenderPipelineState(descriptor: descriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = try gpu.makeTexture(descriptor: textureDescriptor)

        let pass = MTL4RenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let commands = try gpu.beginCommands()
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            Issue.record("描画の記録口が作れない")
            return false
        }
        encoder.setRenderPipelineState(state)
        encoder.setViewport(
            MTLViewport(originX: 0, originY: 0, width: 1, height: 1, znear: 0, zfar: 1))
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        try gpu.commitAndWait(commands)

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: 4,
                from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        // 走った断片は緑を書く。走らなければ塗った黒がそのまま残る
        return pixel[1] == 255
    }

    // MARK: - 通る渡し方

    /// **名前を渡さなければ走る。** `ShapePipeline` がいま取っている形がこれ。
    @Test("名前を渡さない特化は走る")
    func specializationWithoutANameRuns() throws {
        #expect(try fragmentRuns(specializedName: nil), "特化した断片が走っていない")
    }

    /// **C の識別子なら渡しても走る。** 渡し方が無いのではなく、綴りが決まっている。
    ///
    /// 空文字も通る。**中で何になっているかは確かめていない** — 見ているのは
    /// 「断片が走る」ことだけである。
    @Test(
        "C の識別子の名前なら、渡しても走る",
        arguments: ["probeFragmentSpecialized", "_probe", "probe0", "P", ""])
    func specializationWithAnIdentifierNameRuns(_ name: String) throws {
        #expect(
            try fragmentRuns(specializedName: name),
            "識別子 \"\(name)\" を渡したら断片が走らなくなった")
    }

    // MARK: - 黙って落ちる渡し方

    /// **識別子でない名前を渡すと、作成は成功したまま断片が走らない。**
    ///
    /// 並べてあるのは実際に踏んだ綴り (`mokume.forms.blend` の形) と、その周辺 —
    /// 記号を混ぜたもの、数字で始まるもの。エラーは 1 つも返らない。
    ///
    /// **この検査が赤くなったら、それは退行ではなく Metal 側の変化である。**
    /// `ShapePipeline.specialized(_:formFlags:)` の注記と [#776] を更新する。
    ///
    /// [#776]: https://github.com/mokume-metal/mokume/issues/776
    @Test(
        "識別子でない名前を渡すと、作成は成功するのに断片が走らない",
        arguments: ["mokume.forms.blend", "probe-fragment", "probe fragment", "1probe"])
    func specializationWithANonIdentifierNameSilentlyDisappears(_ name: String) throws {
        #expect(
            try fragmentRuns(specializedName: name) == false,
            """
            \"\(name)\" を渡した断片が走った。

            Metal の側の振る舞いが変わっている (#776 で報告した挙動が直った) 可能性がある。
            確かめたうえで、この検査と ShapePipeline.specialized(_:formFlags:) の注記を
            あわせて更新する。
            """)
    }
}
