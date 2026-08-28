// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics

/// 利用者が書いた塗り。
///
/// 使い方は ``Sketch/loadShader(_:values:)`` にある。
public final class Shader {
    /// 断片の在処。保存を拾い直すのに使う。
    public let url: URL?
    /// いま効いている値。
    private(set) var values: [String: ShaderValue]

    /// いま描くのに使うパイプライン。差し替えに失敗しても**前のものが残る**。
    private(set) var state: any MTLRenderPipelineState

    /// 立体を塗るときのパイプライン。
    ///
    /// **断片は 1 つで、頂点の落とし方だけが違う。** 平面と立体で断片を別々に
    /// 組み立てると、同じ断片なのに片方だけ差し替わる状態が作れてしまう。
    private(set) var solidState: any MTLRenderPipelineState

    /// 直近の差し替えが失敗していれば、その理由。
    public private(set) var failure: String?

    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    public private(set) var generation = 0

    private let pipeline: ShapePipeline
    private let gpu: RenderDevice
    let name: String
    /// この塗りを作った面。値を変えるときに列を閉じてもらう。
    weak var canvas: Canvas?
    private(set) var watcher: FileWatcher?
    /// 最後に組み上がった断片の中身。**同じものを組み直さない**ための控え。
    private var compiledBody: String

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        gpu: RenderDevice, pipeline: ShapePipeline
    ) throws(RenderFailure) {
        self.name = name
        self.url = url
        self.values = values
        self.gpu = gpu
        self.pipeline = pipeline

        let library = try gpu.makeShapeLibrary(named: name, body: body, values: values)
        self.state = try pipeline.makeState(fragmentLibrary: library, label: "mokume.shader.\(name)")
        self.solidState = try pipeline.makeState(
            fragmentLibrary: library, label: "mokume.shader.\(name).solid",
            vertexFunctionName: ShapePipeline.solidVertexFunctionName)
        self.compiledBody = body

        if let url {
            watcher = FileWatcher(url: url) { [weak self] in self?.reload() }
        }
    }

    /// 渡す値を書き換える。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。増やすかどうかは
    /// 読み込むときに決める。
    public func set(_ name: String, _ value: ShaderValue) {
        canvas?.shaderValuesWillChange()
        guard let existing = values[name] else {
            Diagnostics.warn(
                "shader: 宣言していない値 \"\(name)\" は渡せません。"
                    + "loadShader の values に書いてください (いまの値: \(values.keys.sorted().joined(separator: ", ")))")
            return
        }
        guard existing.componentCount == value.componentCount else {
            Diagnostics.warn(
                "shader: 値 \"\(name)\" の形が宣言と違います (\(existing.metalType) のところへ \(value.metalType))")
            return
        }
        values[name] = value
    }

    /// いまの値を、シェーダへ渡す並びに詰めたもの。
    var packedValues: [Float] { ShaderSource.pack(values) }

    // MARK: - 差し替え

    /// 断片を読み直して組み直す。
    ///
    /// **失敗しても前のものを消さない。** 削ってから入れ直す形にすると、組み立てに
    /// 失敗した瞬間に元の断片ごと消えて絵が出なくなる。ここでは新しいものが組み上がって
    /// はじめて差し替える。
    func reload() {
        guard let url else { return }
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            failure = "断片を読めませんでした: \(url.path)"
            Diagnostics.warn("shader: \(failure!)")
            return
        }
        // **同じ中身なら組み直さない。** 1 度の保存でファイル側と親ディレクトリ側の
        // 両方が反応するので、素直に組み直すと 1 度の保存で 2 度組み立てることになる
        guard body != compiledBody else { return }
        do {
            let library = try gpu.makeShapeLibrary(named: name, body: body, values: values)
            // **両方が組み上がってから差し替える。** 片方だけ差し替わると、平面と
            // 立体で違う断片が効いている状態になる
            let flat = try pipeline.makeState(
                fragmentLibrary: library, label: "mokume.shader.\(name)")
            let solid = try pipeline.makeState(
                fragmentLibrary: library, label: "mokume.shader.\(name).solid",
                vertexFunctionName: ShapePipeline.solidVertexFunctionName)
            state = flat
            solidState = solid
            compiledBody = body
            failure = nil
            generation += 1
        } catch {
            failure = "\(error)"
            Diagnostics.warn("shader: 断片を組み立て直せませんでした: \(error)")
        }
    }
}
