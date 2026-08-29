// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 出力段を通した絵を、**面に描かずに**書き出すためのパイプライン。
///
/// [ADR-0024] 決定 6 が要求する「取り出す道」の本体である。画面へ差し出す経路
/// (``PresentPipeline``) と**同じシェーダのファイルを読む** — 明るさの曲線と
/// 伝達関数を 2 箇所に持つと、同じフレームなのに出口ごとに違う絵が出る。
///
/// 違いは書き先だけで、あちらは面 (線形の広い形式・帯と収まりを伴う) へ、
/// こちらは絵と同じ大きさの 8 bit のテクスチャへ書く。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
final class OutputPass {
    /// 出力段を通した絵の画素の形式。
    ///
    /// **伝達関数は断片が掛けるので、`_srgb` の付かない形式を使う。** 付けると
    /// 土台がもう一度掛けて二重になる。量子化 ([ADR-0011] 決定 6) だけを
    /// 書き込みの丸めに任せる。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static let pixelFormat: MTLPixelFormat = .rgba8Unorm

    /// 1 画素あたりのバイト数 (4 成分 × 1 バイト)。
    static let bytesPerPixel = 4

    /// 読む元のテクスチャを渡す口の番号 (シェーダ側の `texture(0)`)。
    static let sourceTextureIndex = 0
    /// 明るさを写す段の設定を渡す口の番号 (シェーダ側の `buffer(0)`)。
    static let brightnessBufferIndex = 0

    let state: any MTLRenderPipelineState
    let argumentTable: any MTL4ArgumentTable
    /// 明るさを写す段の設定を置く領域。取り出すたびに書き換える。
    private let brightnessBuffer: any MTLBuffer

    init(gpu: RenderDevice) throws(RenderFailure) {
        let library = try gpu.makeLibrary(named: "Present")

        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = "presentVertexMain"
        vertexFunction.library = library

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = "presentEncodeFragmentMain"
        fragmentFunction.library = library

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "mokume.output.encode"
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = fragmentFunction
        descriptor.colorAttachments[0]!.pixelFormat = Self.pixelFormat

        let compilerDescriptor = MTL4CompilerDescriptor()
        compilerDescriptor.label = "mokume.output.compiler"
        guard let compiler = try? gpu.device.makeCompiler(descriptor: compilerDescriptor) else {
            throw .shaderCompilerUnavailable
        }
        do {
            state = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }

        brightnessBuffer = try gpu.makeReadableBuffer(byteCount: 16)

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.label = "mokume.output.arguments"
        tableDescriptor.maxBufferBindCount = 1
        tableDescriptor.maxTextureBindCount = 1
        do {
            argumentTable = try gpu.device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
    }

    /// 読む元のテクスチャを差し替える。
    func setSource(_ texture: any MTLTexture) {
        argumentTable.setTexture(texture.gpuResourceID, index: Self.sourceTextureIndex)
    }

    /// 明るさを写す段の設定を差し替える。
    ///
    /// **並びは ``PresentPipeline/setBrightness(_:)`` と同じ。** 断片の側が同じ
    /// 構造体を読むので、片方だけ並べ替えると絵が静かに食い違う。
    func setBrightness(_ brightness: Brightness) {
        let slot = brightnessBuffer.contents().assumingMemoryBound(to: Float.self)
        slot[0] = brightness.exposure
        slot[1] = Brightness.knee
        brightnessBuffer.contents().advanced(by: 8)
            .assumingMemoryBound(to: UInt32.self)
            .pointee = brightness.toneMapping.rawIndex
        argumentTable.setAddress(
            brightnessBuffer.gpuAddress, index: Self.brightnessBufferIndex)
    }
}
