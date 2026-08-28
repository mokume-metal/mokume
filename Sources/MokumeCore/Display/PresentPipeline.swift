// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// 描いた絵を表示できる面へ写すためのパイプライン。
///
/// 描画そのものには手を入れない — [ADR-0012] 決定 1 のとおり、画面表示は成果物の
/// テクスチャを受け取る経路の 1 つにすぎない。
///
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
final class PresentPipeline {
    /// 写す元のテクスチャを渡す口の番号 (シェーダ側の `texture(0)`)。
    static let sourceTextureIndex = 0
    /// 読み取り方を渡す口の番号 (シェーダ側の `sampler(0)`)。
    static let samplerIndex = 0
    /// 明るさを写す段の設定を渡す口の番号 (シェーダ側の `buffer(0)`)。
    static let brightnessBufferIndex = 0

    let state: any MTLRenderPipelineState
    let argumentTable: any MTL4ArgumentTable
    private let sampler: any MTLSamplerState
    /// 明るさを写す段の設定を置く領域。フレームごとに書き換える。
    private let brightnessBuffer: any MTLBuffer

    init(gpu: RenderDevice, pixelFormat: MTLPixelFormat) throws(RenderFailure) {
        let library = try gpu.makeLibrary(named: "Present")

        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = "presentVertexMain"
        vertexFunction.library = library

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = "presentFragmentMain"
        fragmentFunction.library = library

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "mokume.present"
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = fragmentFunction
        descriptor.colorAttachments[0]!.pixelFormat = pixelFormat

        let compilerDescriptor = MTL4CompilerDescriptor()
        compilerDescriptor.label = "mokume.present.compiler"
        guard let compiler = try? gpu.device.makeCompiler(descriptor: compilerDescriptor) else {
            throw .shaderCompilerUnavailable
        }
        do {
            state = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.supportArgumentBuffers = true
        guard let sampler = gpu.device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw .samplerUnavailable
        }
        self.sampler = sampler

        brightnessBuffer = try gpu.makeReadableBuffer(byteCount: 16)

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.label = "mokume.present.arguments"
        tableDescriptor.maxBufferBindCount = 1
        tableDescriptor.maxTextureBindCount = 1
        tableDescriptor.maxSamplerStateBindCount = 1
        do {
            argumentTable = try gpu.device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
        argumentTable.setSamplerState(sampler.gpuResourceID, index: Self.samplerIndex)
    }

    /// 写す元のテクスチャを差し替える。
    func setSource(_ texture: any MTLTexture) {
        argumentTable.setTexture(texture.gpuResourceID, index: Self.sourceTextureIndex)
    }

    /// 明るさを写す段の設定を差し替える。
    ///
    /// **折れ始める明るさも一緒に渡す。** 断片の側に同じ定数を書くと、片方だけ
    /// 直したときに画面と書き出しが静かに食い違う。
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
