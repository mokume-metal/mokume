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
    /// フレームを通して変わらない値を渡す口の番号 (シェーダ側の `buffer(4)`)。
    static let uniformsBufferIndex = 4
    /// 利用者が渡した値の口の番号 (シェーダ側の `buffer(5)`)。
    static let valuesBufferIndex = 5
    /// この列に効く光の区間を渡す口の番号 (シェーダ側の `buffer(6)`)。
    static let lightingBufferIndex = 6
    /// 置いた光を渡す口の番号 (シェーダ側の `buffer(7)`)。
    static let lightsBufferIndex = 7
    /// この列の材質を渡す口の番号 (シェーダ側の `buffer(8)`)。
    static let materialBufferIndex = 8
    /// この列に効く周囲を渡す口の番号 (シェーダ側の `buffer(9)`)。
    static let surroundingsBufferIndex = 9
    /// 立体の置き場所を渡す口の番号 (シェーダ側の `buffer(10)`)。
    static let instanceBufferIndex = 10
    /// 塗りが読む数の並びを渡す口の番号 (シェーダ側の `buffer(11)`)。
    static let numbersBufferIndex = 11
    /// 読む面を渡す口の番号 (シェーダ側の `texture(0)`)。
    static let textureIndex = 0
    /// 焼き付けた影を渡す口の番号 (シェーダ側の `texture(1)`)。
    static let shadowTextureIndex = 1
    /// 利用者が宣言した面を渡す口の、最初の番号 (シェーダ側の `texture(2)` から)。
    static let surfaceTextureIndex = 2
    /// 1 つの断片へ渡せる面の枚数。**上限の正典はここ 1 か所**で、原稿を組み立てる側
    /// (`ShaderSource`)・入口 (`Common.metal`)・断る側 (`Canvas.loadShader`) が
    /// これを見る ([#407](https://github.com/mokume-metal/mokume/issues/407))。
    ///
    /// 口は使う枚数によらず全部が束ねられる。**空きの口にも何かを束ねる**ので、
    /// 宣言より多く読もうとした断片も、絵が乱れるだけで異常終了はしない。
    static let surfaceCapacity = 4

    /// 組み込みの塗りで描くパイプライン。
    let state: any MTLRenderPipelineState

    /// 立体を組み込みの塗りで描くパイプライン。頂点の落とし方だけが違う。
    let solidState: any MTLRenderPipelineState

    /// 光から見た奥行きを焼き付けるパイプライン。**頂点だけで、断片を持たない。**
    ///
    /// 焼くのは奥行きの面 1 枚で、それは前後判定が書く。色の面が無いので断片には
    /// 書く先が無く、置かない ([#757](https://github.com/mokume-metal/mokume/issues/757))。
    let shadowState: any MTLRenderPipelineState

    /// 平面の基本図形を距離関数で描くパイプライン ([#752])。
    ///
    /// 頂点も断片も専用で、利用者の断片は差し替えられない — 断片が読む面・頂点の
    /// 属性を契約に持つ利用者の断片は、三角形の経路 (``state``) に居続ける。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    let formState: any MTLRenderPipelineState

    /// 平面の奥行きの扱い — **常に通し、書かない**。
    ///
    /// 平面は奥行きを持たない挿入レイヤーなので ([ADR-0021] 決定 2)、書かないことで
    /// 後から来た立体の前後関係を汚さない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    let flatDepthState: (any MTLDepthStencilState)?

    /// 立体の奥行きの扱い — **手前だけを通し、書く**。
    let solidDepthState: (any MTLDepthStencilState)?

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
        self.solidState = try Self.makeState(
            compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
            pixelFormat: pixelFormat, label: "mokume.solids",
            vertexFunctionName: Self.solidVertexFunctionName)

        self.shadowState = try Self.makeDepthOnlyState(
            compiler: compiler, vertexLibrary: library, label: "mokume.shadow",
            vertexFunctionName: Self.solidVertexFunctionName)
        self.formState = try Self.makeState(
            compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
            pixelFormat: pixelFormat, label: "mokume.forms",
            vertexFunctionName: Self.formVertexFunctionName,
            fragmentFunctionName: Self.formFragmentFunctionName)

        let flat = MTLDepthStencilDescriptor()
        flat.label = "mokume.depth.flat"
        flat.depthCompareFunction = .always
        flat.isDepthWriteEnabled = false
        self.flatDepthState = gpu.device.makeDepthStencilState(descriptor: flat)

        let solid = MTLDepthStencilDescriptor()
        solid.label = "mokume.depth.solid"
        solid.depthCompareFunction = .lessEqual
        solid.isDepthWriteEnabled = true
        self.solidDepthState = gpu.device.makeDepthStencilState(descriptor: solid)

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.label = "mokume.shapes.arguments"
        tableDescriptor.maxBufferBindCount = 12
        tableDescriptor.maxTextureBindCount = Self.surfaceTextureIndex + Self.surfaceCapacity
        do {
            argumentTable = try gpu.device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
    }

    /// 平面の頂点を落とす関数の名前。
    static let flatVertexFunctionName = "shapeVertexMain"
    /// 立体の頂点を落とす関数の名前。
    static let solidVertexFunctionName = "solidVertexMain"
    /// 基本図形のクアッドを置く頂点関数の名前。
    static let formVertexFunctionName = "formVertexMain"
    /// 基本図形を距離関数で塗る断片の名前。
    static let formFragmentFunctionName = "mokume_formFragment"

    /// 利用者の断片で塗るパイプラインを組む。
    func makeState(
        fragmentLibrary: any MTLLibrary, label: String,
        vertexFunctionName: String = ShapePipeline.flatVertexFunctionName
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        try Self.makeState(
            compiler: compiler, vertexLibrary: vertexLibrary, fragmentLibrary: fragmentLibrary,
            pixelFormat: pixelFormat, label: label, vertexFunctionName: vertexFunctionName)
    }

    private static func makeState(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary,
        fragmentLibrary: any MTLLibrary, pixelFormat: MTLPixelFormat, label: String,
        vertexFunctionName: String = ShapePipeline.flatVertexFunctionName,
        fragmentFunctionName: String = "mokume_fragmentMain"
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = vertexFunctionName
        vertexFunction.library = vertexLibrary

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = fragmentFunctionName
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

    /// 奥行きだけを書くパイプラインを組む (影の焼き付け)。
    ///
    /// 断片を渡さないと、ラスタライズと前後判定だけが走る。色の面は 1 つも宣言しない —
    /// 宣言すると、書く断片が無いのに面が付いている形になる。
    private static func makeDepthOnlyState(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary, label: String,
        vertexFunctionName: String
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = vertexFunctionName
        vertexFunction.library = vertexLibrary

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = nil

        do {
            return try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }
    }
}
