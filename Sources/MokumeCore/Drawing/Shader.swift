// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics

/// 利用者が書いた塗り。
///
/// 使い方は ``Sketch/loadShader(_:values:surfaces:)`` にある。
public final class Shader {
    /// 断片・値・保存の拾い直しを持つ骨。**3 者で 1 つ** (``ShaderBox``)。
    private let box: ShaderBox

    /// 断片の在処。保存を拾い直すのに使う。
    public var url: URL? { box.url }
    /// 直近の差し替えが失敗していれば、その理由。
    public var failure: String? { box.failure }
    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    public var generation: Int { box.generation }
    let name: String
    /// いま効いている値。
    var values: [String: ShaderValue] { box.values }
    var watcher: FileWatcher? { box.watcher }

    /// いま渡している面。**名前ごとに口を 1 つ使う** ([#407])。
    ///
    /// 値と別に持つのは詰め先が違うからで、値は列ごとの 1 区画へ、面は口へ載る。
    ///
    /// [#407]: https://github.com/mokume-metal/mokume/issues/407
    private(set) var surfaces: [String: ShaderSurface]

    /// 口へ束ねる順に並べた面。**原稿が宣言した並びと同じ (名前順)** — ここが食い違うと、
    /// 断片が「木目」と書いたところへ「汚し」が届く。
    var orderedSurfaces: [ShaderSurface] {
        surfaces.sorted { $0.key < $1.key }.map(\.value)
    }

    /// いま描くのに使うパイプライン。差し替えに失敗しても**前のものが残る**。
    private(set) var states: ShapePipeline.BlendStates

    /// 立体を塗るときのパイプライン。
    ///
    /// **断片は 1 つで、頂点の落とし方だけが違う。** 平面と立体で断片を別々に
    /// 組み立てると、同じ断片なのに片方だけ差し替わる状態が作れてしまう。
    private(set) var solidStates: ShapePipeline.BlendStates

    private let pipeline: ShapePipeline
    private let gpu: RenderDevice
    /// この塗りを作った面。値を変えるときに列を閉じてもらう。
    weak var canvas: Canvas?

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        surfaces: [String: ShaderSurface] = [:],
        gpu: RenderDevice, pipeline: ShapePipeline
    ) throws(RenderFailure) {
        self.name = name
        self.surfaces = surfaces
        self.gpu = gpu
        self.pipeline = pipeline
        self.box = ShaderBox(
            name: name, url: url, body: body, values: values,
            label: "shader", valuesHint: "loadShader の values")

        let library = try gpu.makeShapeLibrary(
            named: name, body: body, values: values, surfaces: surfaces)
        self.states = try pipeline.makeStates(
            fragmentLibrary: library, label: "mokume.shader.\(name)")
        self.solidStates = try pipeline.makeStates(
            fragmentLibrary: library, label: "mokume.shader.\(name).solid",
            vertexFunctionName: ShapePipeline.solidVertexFunctionName)

        box.watch { [weak self] in self?.reload() }
    }

    /// 渡す値を書き換える。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。増やすかどうかは
    /// 読み込むときに決める。
    public func set(_ name: String, _ value: ShaderValue) {
        canvas?.shaderValuesWillChange()
        box.assign(name, value)
    }

    /// 渡す面を差し替える。
    ///
    /// **宣言していない名前は受け付けない** — 面の宣言も断片と一緒に組み上がるので、
    /// 後から名前を増やすと組み直しになる (値と同じ規則)。
    public func set(_ name: String, _ surface: ShaderSurface) {
        canvas?.shaderValuesWillChange()
        guard surfaces[name] != nil else {
            Diagnostics.warn(
                "shader: 宣言していない面 \"\(name)\" は渡せません。"
                    + "loadShader の surfaces に書いてください"
                    + "(いまの面: \(surfaces.keys.sorted().joined(separator: ", ")))")
            return
        }
        surfaces[name] = surface
    }

    /// いまの値を、シェーダへ渡す並びに詰めたもの。
    var packedValues: [Float] { box.packedValues }

    // MARK: - 差し替え

    /// 断片を読み直して組み直す。**読み直しと控えの更新は骨が持つ** (``ShaderBox/reload(_:)``)。
    func reload() {
        box.reload { (body: String) throws(RenderFailure) in
            let library = try gpu.makeShapeLibrary(
                named: name, body: body, values: values, surfaces: surfaces)
            // **両方が組み上がってから差し替える。** 片方だけ差し替わると、平面と
            // 立体で違う断片が効いている状態になる
            let flat = try pipeline.makeStates(
                fragmentLibrary: library, label: "mokume.shader.\(name)")
            let solid = try pipeline.makeStates(
                fragmentLibrary: library, label: "mokume.shader.\(name).solid",
                vertexFunctionName: ShapePipeline.solidVertexFunctionName)
            states = flat
            solidStates = solid
        }
    }
}
