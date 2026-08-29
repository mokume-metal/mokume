// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// 効果を通すためのパイプラインと、中間の置き場。
///
/// **中間の置き場はここが 1 か所で持つ** ([ADR-0023] 決定 5 — 毎フレーム走る段は
/// フレームごとに新しい置き場を確保しない)。段ごとに持たせると、段数の違う効果を
/// 併用したときに枚数が変わり、変わるたびに確保が走る。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
final class EffectPipeline {
    /// 利用者が渡した値の口の番号 (シェーダ側の `buffer(0)`)。
    static let valuesBufferIndex = 0
    /// 組み込みの効果に効く設定の口の番号 (シェーダ側の `buffer(1)`)。
    static let controlBufferIndex = 1
    /// 面の大きさと時刻の口の番号 (シェーダ側の `buffer(2)`)。
    static let frameBufferIndex = 2
    /// 入りの絵の口の番号 (シェーダ側の `texture(0)`)。
    static let sourceTextureIndex = 0
    /// 組み合わせる相手の絵の口の番号 (シェーダ側の `texture(1)`)。
    static let pairedTextureIndex = 1

    /// 入口の関数の名前。**組み込みも利用者の効果も同じ**。
    static let vertexFunctionName = "mokume_effectVertexMain"
    static let fragmentFunctionName = "mokume_effectMain"

    /// 1 段ぶんの置き場の間隔 (バイト)。設定 32 / 面 16 / 値の順に詰める。
    static let passStride = 256
    static let controlOffset = 0
    static let frameOffset = 32
    static let valuesOffset = 64
    /// 1 つの効果が渡せる値の数。
    static let valueSlotCapacity = (passStride - valuesOffset) / MemoryLayout<Float>.stride

    private let gpu: RenderDevice
    private let compiler: any MTL4Compiler
    private let pixelFormat: MTLPixelFormat

    /// 組み込みの効果を通すパイプライン。
    let builtin: any MTLRenderPipelineState

    /// 段ごとの引数のテーブル。**段ごとに別のものを使う** — 1 枚を使い回して番地を
    /// 書き換えると、まだ走っていない段の束ね先まで変わる (計算の段と同じ理由)。
    private var tables: [any MTL4ArgumentTable] = []
    /// テーブルを組んだ回数。**使い回せているかを数で見る。**
    private(set) var tablesBuilt = 0

    /// 段ごとの設定・面・値を置く領域。足りなければ伸ばす。
    private(set) var passBuffer: any MTLBuffer
    private var passCapacity: Int
    /// 置き場を取り直した回数。**長回しで増えないことを検査が見る。**
    private(set) var buffersBuilt = 0

    /// 中間の絵。**使い回す**ので、フレームごとには作らない。
    private var scratch: [RenderTarget] = []
    /// 中間の絵を確保した回数。
    private(set) var scratchBuilt = 0
    private let width: Int
    private let height: Int

    init(gpu: RenderDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat)
        throws(RenderFailure)
    {
        self.gpu = gpu
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat

        let descriptor = MTL4CompilerDescriptor()
        descriptor.label = "mokume.effect.compiler"
        guard let compiler = try? gpu.device.makeCompiler(descriptor: descriptor) else {
            throw .shaderCompilerUnavailable
        }
        self.compiler = compiler

        let library = try gpu.makeEffectLibrary(
            named: "builtin", body: try gpu.bundledShaderSource(named: "Builtin"))
        self.builtin = try Self.makeState(
            compiler: compiler, library: library, pixelFormat: pixelFormat,
            label: "mokume.effect.builtin")

        passCapacity = 8
        passBuffer = try gpu.makeReadableBuffer(byteCount: passCapacity * Self.passStride)
        buffersBuilt = 1
    }

    /// 利用者の効果のパイプラインを組む。
    func makeState(library: any MTLLibrary, label: String) throws(RenderFailure)
        -> any MTLRenderPipelineState
    {
        try Self.makeState(
            compiler: compiler, library: library, pixelFormat: pixelFormat, label: label)
    }

    private static func makeState(
        compiler: any MTL4Compiler, library: any MTLLibrary, pixelFormat: MTLPixelFormat,
        label: String
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = vertexFunctionName
        vertexFunction.library = library

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = fragmentFunctionName
        fragmentFunction.library = library

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = fragmentFunction
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        // **混ぜない。** 段は入りの絵を丸ごと受け取って出りの絵を丸ごと書くので、
        // 下地と混ぜる余地が無い (混ぜたい効果は自分で相手を読む)
        attachment.blendingState = .disabled

        do {
            return try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }
    }

    /// `index` 段目のテーブル。足りなければ伸ばす。
    func table(at index: Int) throws(RenderFailure) -> any MTL4ArgumentTable {
        while tables.count <= index {
            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.label = "mokume.effect.arguments.\(tables.count)"
            descriptor.maxBufferBindCount = 3
            descriptor.maxTextureBindCount = 2
            guard let table = try? gpu.device.makeArgumentTable(descriptor: descriptor) else {
                throw .argumentTableUnavailable(reason: "効果の段 \(tables.count) 枚目")
            }
            tables.append(table)
            tablesBuilt += 1
        }
        return tables[index]
    }

    /// 段の数だけ置き場を確保する。**足りているうちは取り直さない。**
    func reservePasses(_ count: Int) throws(RenderFailure) {
        guard count > passCapacity else { return }
        let capacity = max(count, passCapacity * 2)
        passBuffer = try gpu.makeReadableBuffer(byteCount: capacity * Self.passStride)
        passCapacity = capacity
        buffersBuilt += 1
    }

    /// `index` 枚目の中間の絵。足りなければ確保する。
    func scratch(at index: Int) throws(RenderFailure) -> RenderTarget {
        while scratch.count <= index {
            scratch.append(try RenderTarget(gpu: gpu, width: width, height: height))
            scratchBuilt += 1
        }
        return scratch[index]
    }
}
