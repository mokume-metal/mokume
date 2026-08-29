// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 計算をさせるためのパイプラインと、資源の受け渡し口。
///
/// 図形の側 (``ShapePipeline``) と同じ役割を、計算の段に対して持つ。組み立て器を
/// 分けて持っているのは、口の数が違う (計算は利用者の並びを何本も束ねる) ためである。
final class ComputePipeline {
    /// 利用者が渡した値が載る口の番号。断片からは `MOKUME_VALUES` で引ける。
    static let valuesBufferIndex = 15
    /// 1 回の計算に束ねられる並びの本数 (口 0…14)。
    ///
    /// 上限があるのは引数のテーブルを固定の大きさで作るためで、**超えた要求は黙って
    /// 落とさず断る**。
    static let maximumBufferCount = 15

    /// 頼みごとの引数のテーブル。
    ///
    /// **1 枚を使い回さない。** 同じ口に載った計算は並行に走りうるので、1 枚の番地を
    /// 書き換えながら積むと、走っている計算の足元で束ね先が変わる。位置ごとに 1 枚を
    /// 持ち、**要るところまで伸ばしてからは作り直さない** ([ADR-0023] 決定 5)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private var tables: [any MTL4ArgumentTable] = []
    /// テーブルを作った回数 (組んでから通算)。**毎フレーム確保していないことを数える。**
    private(set) var tablesBuilt = 0

    private let gpu: RenderDevice
    private let compiler: any MTL4Compiler

    init(gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        let compilerDescriptor = MTL4CompilerDescriptor()
        compilerDescriptor.label = "mokume.compute.compiler"
        guard let compiler = try? gpu.device.makeCompiler(descriptor: compilerDescriptor) else {
            throw .shaderCompilerUnavailable
        }
        self.compiler = compiler

    }

    /// 位置に対応するテーブル。**足りなければ伸ばす。**
    func table(at index: Int) throws(RenderFailure) -> any MTL4ArgumentTable {
        while tables.count <= index {
            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.label = "mokume.compute.arguments.\(tables.count)"
            descriptor.maxBufferBindCount = Self.valuesBufferIndex + 1
            do {
                tables.append(try gpu.device.makeArgumentTable(descriptor: descriptor))
            } catch {
                throw .argumentTableUnavailable(reason: error.localizedDescription)
            }
            tablesBuilt += 1
        }
        return tables[index]
    }

    /// 利用者の断片から計算のパイプラインを組む。
    func makeState(
        library: any MTLLibrary, functionName: String, label: String
    ) throws(RenderFailure) -> any MTLComputePipelineState {
        let function = MTL4LibraryFunctionDescriptor()
        function.name = functionName
        function.library = library

        let descriptor = MTL4ComputePipelineDescriptor()
        descriptor.label = label
        descriptor.computeFunctionDescriptor = function

        do {
            return try compiler.makeComputePipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }
    }
}
