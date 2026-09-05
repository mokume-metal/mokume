// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics

/// 利用者が書いた効果。
///
/// 使い方は ``Sketch/loadEffect(_:values:)`` にある。**平面・立体の塗りと同じ規約**で
/// 書ける — 前置きは自動で足され、書くのは `float4 effect(Pixel in, Values values)`
/// 1 本だけである。
public final class EffectShader {
    /// 断片・値・保存の拾い直しを持つ骨。**3 者で 1 つ** (``ShaderBox``)。
    private let box: ShaderBox

    /// この効果の名前。
    public let name: String
    /// 直近の差し替えが失敗していれば、その理由。
    public var failure: String? { box.failure }
    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    public var generation: Int { box.generation }

    /// いま通すパイプライン。差し替えに失敗しても**前のものが残る**。
    private(set) var state: any MTLRenderPipelineState
    var values: [String: ShaderValue] { box.values }
    var watcher: FileWatcher? { box.watcher }

    /// 断片の在処。保存を拾い直すのに使う。
    ///
    /// **公開しない。** 面に出せば外の語彙 (`URL`) が一覧に載るので、指し直したい需要が
    /// 出てから開ける ([ADR-0020] 決定 6・[ADR-0008])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
    var url: URL? { box.url }

    private let gpu: RenderDevice
    private let pipeline: EffectPipeline

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        gpu: RenderDevice, pipeline: EffectPipeline
    ) throws(RenderFailure) {
        self.name = name
        self.gpu = gpu
        self.pipeline = pipeline
        self.box = ShaderBox(
            name: name, url: url, body: body, values: values,
            label: "effect", valuesHint: "作るときの values")

        let library = try gpu.makeEffectLibrary(named: name, body: body, values: values)
        self.state = try pipeline.makeState(library: library, label: "mokume.effect.\(name)")

        box.watch { [weak self] in self?.reload() }
    }

    /// いまの値を並べたもの。
    var packedValues: [Float] { box.packedValues }

    /// 渡す値を書き換える。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。
    public func set(_ name: String, _ value: ShaderValue) {
        box.assign(name, value)
    }

    /// 断片を読み直して組み直す。**読み直しと控えの更新は骨が持つ** (``ShaderBox/reload(_:)``)。
    func reload() {
        box.reload { (body: String) throws(RenderFailure) in
            let library = try gpu.makeEffectLibrary(named: name, body: body, values: values)
            state = try pipeline.makeState(library: library, label: "mokume.effect.\(name)")
        }
    }
}
