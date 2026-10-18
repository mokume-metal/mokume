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
    private var tablePool: ArgumentTablePool
    /// テーブルを作った回数。**毎フレーム確保していないことを検査が数で見る**
    /// (``ArgumentTablePool/built``)。
    var tablesBuilt: Int { tablePool.built }

    private let gpu: RenderDevice
    private let compiler: any MTL4Compiler

    init(gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        self.tablePool = ArgumentTablePool(
            gpu: gpu, label: "mokume.compute.arguments",
            bufferBindCount: Self.valuesBufferIndex + 1)
        self.compiler = try gpu.shaders.compiler()
    }

    /// 位置に対応するテーブル。**足りなければ伸ばす** (``ArgumentTablePool``)。
    func table(at index: Int) throws(RenderFailure) -> any MTL4ArgumentTable {
        try tablePool.table(at: index)
    }

    /// 利用者の断片から計算のパイプラインを組む。
    ///
    /// - Parameter fragment: 入口の関数が無いときに断片が名乗る名前
    ///   (``ShaderSource/bodyName(_:url:)``)。省けば `functionName`。
    func makeState(
        library: any MTLLibrary, functionName: String, label: String, fragment: String? = nil
    ) throws(RenderFailure) -> any MTLComputePipelineState {
        try stateJob(functionName: functionName, label: label, fragment: fragment)
            .makeNow(library: library)
    }

    /// ``makeState(library:functionName:label:)`` を、ライブラリが出来る前に用意する。裏で組む
    /// 経路 (``ShaderBox``・[#2365]) が使う。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    func stateJob(functionName: String, label: String, fragment: String? = nil) -> StateJob {
        StateJob(
            compiler: compiler, functionName: functionName, label: label,
            fragment: fragment ?? functionName)
    }

    /// 1 本の組み方。main で決めた値だけを持つので、裏の糸でも組める
    /// (``ShapePipeline/StatePlan`` と同じ理由)。
    nonisolated struct StateJob: Sendable {
        let compiler: any MTL4Compiler
        let functionName: String
        let label: String
        /// 入口の関数が無いときに、断片が名乗る名前。
        let fragment: String

        /// **入口の関数がライブラリに無ければ、パイプラインを作る前に断る** (#2782)。
        ///
        /// 無い名前のままパイプラインを作ると、Metal は投げずに assert でプロセスごと落とす
        /// (`computeFunction must not be nil`)。作るときも保存して差し替えるときも、利用者が
        /// `kernel void` の名前を書き違えただけで作品が止まる。`kernel` でない関数 (修飾の無い関数や
        /// `[[visible]]`) も入口にならないので同じく断る。理由は書いた断片の側で直す言葉で言う
        /// (``ShaderEntryPoint/missingKernel(named:in:)``)。
        private func checkEntryPoint(in library: any MTLLibrary) throws(RenderFailure) {
            guard library.makeFunction(name: functionName)?.functionType != .kernel else { return }
            throw .shaderCompilationFailed(
                name: functionName,
                reason: ShaderEntryPoint.missingKernel(named: functionName, in: fragment))
        }

        private func descriptor(library: any MTLLibrary) -> MTL4ComputePipelineDescriptor {
            let function = MTL4LibraryFunctionDescriptor()
            function.name = functionName
            function.library = library

            let descriptor = MTL4ComputePipelineDescriptor()
            descriptor.label = label
            descriptor.computeFunctionDescriptor = function
            return descriptor
        }

        /// その場で組む。
        func makeNow(library: any MTLLibrary) throws(RenderFailure) -> any MTLComputePipelineState {
            try checkEntryPoint(in: library)
            do {
                return try compiler.makeComputePipelineState(descriptor: descriptor(library: library))
            } catch {
                throw .pipelineUnavailable(reason: error.localizedDescription)
            }
        }

        /// 裏で組む。組んでいる間、呼んだ側の糸を塞がない。
        func make(library: any MTLLibrary) async throws(RenderFailure) -> any MTLComputePipelineState {
            try checkEntryPoint(in: library)
            do {
                return try await compiler.makeComputePipelineState(descriptor: descriptor(library: library))
            } catch {
                throw .pipelineUnavailable(reason: error.localizedDescription)
            }
        }
    }
}
