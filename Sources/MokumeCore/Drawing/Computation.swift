// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics

/// 利用者が書いた計算。
///
/// 使い方は ``Sketch/makeComputation(_:name:values:)`` にある。
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor public final class Computation {
    /// 断片・値・保存の拾い直しを持つ骨。**3 者で 1 つ** (``ShaderBox``)。
    private let box: ShaderBox

    /// この計算の名前。**断片の中の入口の関数もこの名前**で書く。
    public let name: String
    /// 直近の差し替えが失敗していれば、その理由。
    public var failure: String? { box.failure }
    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    public var generation: Int { box.generation }

    /// いま走らせるパイプライン。差し替えに失敗しても**前のものが残る**。
    private(set) var state: any MTLComputePipelineState
    /// いま効いている値。
    var values: [String: ShaderValue] { box.values }
    var watcher: FileWatcher? { box.watcher }
    /// 値を載せる置き場。**1 度だけ確保して使い回す** ([ADR-0023] 決定 5)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private(set) var valuesBuffer: any MTLBuffer

    /// 断片の在処。保存を拾い直すのに使う。
    ///
    /// **公開しない。** 面に出せば外の語彙 (`URL`) が一覧に載るので、指し直したい
    /// 需要が出てから開ける ([ADR-0020] 決定 6・[ADR-0008])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
    var url: URL? { box.url }

    private let gpu: RenderDevice
    private let pipeline: ComputePipeline

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        gpu: RenderDevice, pipeline: ComputePipeline
    ) throws(RenderFailure) {
        self.name = name
        self.gpu = gpu
        self.pipeline = pipeline
        self.box = ShaderBox(
            name: name, url: url, body: body, values: values,
            label: "computation", valuesHint: "作るときの values")

        let library = try gpu.makeComputeLibrary(named: name, body: body, values: values)
        self.state = try pipeline.makeState(
            library: library, functionName: name, label: "mokume.computation.\(name)")
        self.valuesBuffer = try gpu.makeReadableBuffer(
            byteCount: max(ShaderSource.pack(values).count, 4) * MemoryLayout<Float>.stride)
        writeValues()

        box.watch { [weak self] in self?.reload() }
    }

    /// **値の置き場を常駐から退かせる** ([#738])。常駐の集合が抱えている限り、計算を
    /// 手放しても解放されない。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    isolated deinit { gpu.retire(valuesBuffer) }

    /// 渡す値を書き換える。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。増やすかどうかは作るときに決める。
    public func set(_ name: String, _ value: ShaderValue) {
        // **受け付けた値だけを写す。** 断られた値で置き場を書き直すと、宣言と違う形の
        // 値が絵に出る余地が残る
        if box.assign(name, value) { writeValues() }
    }

    /// いまの値を置き場へ写す。
    ///
    /// **書き換えたその場で写す。** 走らせる直前にまとめて写す形にすると、値を変えた
    /// フレームと効くフレームがずれる余地が残る。
    private func writeValues() {
        // 前のフレームの計算がまだこの置き場を読んでいるかもしれない (描き切りは待たずに
        // 返る・#727)。書く直前に投入済みのものが終わるのを待つ
        gpu.settleQuietly(before: "計算の値を書く")
        var packed = box.packedValues
        let capacity = valuesBuffer.length / MemoryLayout<Float>.stride
        while packed.count < capacity { packed.append(0) }
        packed.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            valuesBuffer.contents().copyMemory(
                from: base, byteCount: min(source.count, valuesBuffer.length))
        }
    }

    // MARK: - 差し替え

    /// 断片を読み直して組み直す。**読み直しと控えの更新は骨が持つ** (``ShaderBox/reload(_:)``)。
    func reload() {
        box.reload { (body: String) throws(RenderFailure) in
            let library = try gpu.makeComputeLibrary(named: name, body: body, values: values)
            state = try pipeline.makeState(
                library: library, functionName: name, label: "mokume.computation.\(name)")
        }
    }
}
