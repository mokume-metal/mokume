// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// 図形を描くためのパイプラインと、資源の受け渡し口。
///
/// この世代の Metal では、シェーダへ資源を渡すのは**引数のテーブル**で、GPU 上の
/// 番地を指す。テーブルの用意とパイプラインの構築をここにまとめる。
final class ShapePipeline {
    /// 頂点の並びを渡す口の番号 (シェーダ側の `buffer(0)`)。
    static let vertexBufferIndex = 0
    /// 描画先の座標へ落とす行列を渡す口の番号 (シェーダ側の `buffer(1)`)。
    static let projectionBufferIndex = 1

    let state: any MTLRenderPipelineState
    let argumentTable: any MTL4ArgumentTable

    init(gpu: RenderDevice, pixelFormat: MTLPixelFormat) throws(RenderFailure) {
        let library = try gpu.makeLibrary(named: "Shapes")

        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = "shapeVertexMain"
        vertexFunction.library = library

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = "shapeFragmentMain"
        fragmentFunction.library = library

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "mokume.shapes"
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = fragmentFunction

        // 色は乗算済みで運ぶので、重ね方も乗算済み向けの式にする
        // (ADR-0011 決定 4)。乗算していない色向けの式を使うと、半透明の重なりが濁る。
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.blendingState = .enabled
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let compilerDescriptor = MTL4CompilerDescriptor()
        compilerDescriptor.label = "mokume.compiler"
        guard let compiler = try? gpu.device.makeCompiler(descriptor: compilerDescriptor) else {
            throw .shaderCompilerUnavailable
        }
        do {
            state = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.label = "mokume.shapes.arguments"
        tableDescriptor.maxBufferBindCount = 2
        do {
            argumentTable = try gpu.device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
    }

}
