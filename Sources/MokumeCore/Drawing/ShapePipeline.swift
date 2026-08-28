// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// 図形を描くためのパイプラインと、資源の受け渡し口。
///
/// この世代の Metal では、シェーダへ資源を渡すのは**引数のテーブル**で、GPU 上の
/// 番地を指す。テーブルの用意とパイプラインの構築をここにまとめる。
///
/// 頂点を組み立てる側は組み込みのものしかない — 利用者が差し替えるのは塗りだけなので、
/// **利用者の断片から作るパイプラインも、頂点側は同じものを使う。**
final class ShapePipeline {
    /// 頂点の並びを渡す口の番号 (シェーダ側の `buffer(0)`)。
    static let vertexBufferIndex = 0
    /// 描画先の座標へ落とす行列を渡す口の番号 (シェーダ側の `buffer(1)`)。
    static let projectionBufferIndex = 1
    /// 混ぜ方の番号を渡す口の番号 (シェーダ側の `buffer(2)`)。
    static let blendModeBufferIndex = 2
    /// 面の中身の種類を渡す口の番号 (シェーダ側の `buffer(3)`)。
    static let textureKindBufferIndex = 3
    /// フレームを通して変わらない値を渡す口の番号 (シェーダ側の `buffer(4)`)。
    static let uniformsBufferIndex = 4
    /// 利用者が渡した値の口の番号 (シェーダ側の `buffer(5)`)。
    static let valuesBufferIndex = 5
    /// 読む面を渡す口の番号 (シェーダ側の `texture(0)`)。
    static let textureIndex = 0

    /// 組み込みの塗りで描くパイプライン。
    let state: any MTLRenderPipelineState
    let argumentTable: any MTL4ArgumentTable

    private let vertexLibrary: any MTLLibrary
    private let compiler: any MTL4Compiler
    private let pixelFormat: MTLPixelFormat

    init(gpu: RenderDevice, pixelFormat: MTLPixelFormat) throws(RenderFailure) {
        self.pixelFormat = pixelFormat
        let library = try gpu.makeShapeLibrary(
            named: "Shapes", body: gpu.bundledShaderSource(named: "Shapes"))
        self.vertexLibrary = library

        let compilerDescriptor = MTL4CompilerDescriptor()
        compilerDescriptor.label = "mokume.compiler"
        guard let compiler = try? gpu.device.makeCompiler(descriptor: compilerDescriptor) else {
            throw .shaderCompilerUnavailable
        }
        self.compiler = compiler

        self.state = try Self.makeState(
            compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
            pixelFormat: pixelFormat, label: "mokume.shapes")

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.label = "mokume.shapes.arguments"
        tableDescriptor.maxBufferBindCount = 6
        tableDescriptor.maxTextureBindCount = 1
        do {
            argumentTable = try gpu.device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
    }

    /// 利用者の断片で塗るパイプラインを組む。
    func makeState(fragmentLibrary: any MTLLibrary, label: String) throws(RenderFailure)
        -> any MTLRenderPipelineState
    {
        try Self.makeState(
            compiler: compiler, vertexLibrary: vertexLibrary, fragmentLibrary: fragmentLibrary,
            pixelFormat: pixelFormat, label: label)
    }

    private static func makeState(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary,
        fragmentLibrary: any MTLLibrary, pixelFormat: MTLPixelFormat, label: String
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = "shapeVertexMain"
        vertexFunction.library = vertexLibrary

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = "mokume_fragmentMain"
        fragmentFunction.library = fragmentLibrary

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = fragmentFunction

        // **固定機能のブレンドは使わない。** 混ぜ方はすべてフラグメントで行う
        // (フラグメントが描画先を読めることは実測で確認済み)。係数で処理される分と
        // シェーダで処理される分に割れると、アルファの扱いがモードごとにばらつく
        // 余地が残るためである。
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.blendingState = .disabled

        do {
            return try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }
    }
}
