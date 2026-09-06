// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics

/// 利用者が書いた計算。
///
/// 使い方は ``Sketch/makeComputation(_:name:values:)`` にある。
// `Canvas` と同じ隔離で使う型なので隔離を明示する。**理由は `RenderDevice` の冒頭が
// 持つ** (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
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
    /// いま効いている値を、断片へ渡す並びに詰めたもの。
    ///
    /// **GPU の置き場は持たない。** 頼み (``ComputeDispatch``) が積まれた時点でここを
    /// 写し、流す段で頼みごとの区画へ書く ([#932])。1 本の置き場を持って書き換えて
    /// いたときは、溜めた頼みが流す段で**最後の値だけ**を読んだので、同じ計算を値を
    /// 変えて 2 度頼むと後の値が両方に効いた。
    ///
    /// [#932]: https://github.com/mokume-metal/mokume/issues/932
    var packedValues: [Float] { box.packedValues }

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
        box.watch { [weak self] in self?.reload() }
    }

    /// 渡す値を書き換える。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。増やすかどうかは作るときに決める。
    ///
    /// **効くのは、この後に頼んだ計算からである。** 既に頼んである計算は積まれた時点の
    /// 値を持っているので、ここでの書き換えに引きずられない ([#932])。
    ///
    /// [#932]: https://github.com/mokume-metal/mokume/issues/932
    public func set(_ name: String, _ value: ShaderValue) {
        box.assign(name, value)
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
