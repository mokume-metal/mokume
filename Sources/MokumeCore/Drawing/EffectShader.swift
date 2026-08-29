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
    /// この効果の名前。
    public let name: String
    /// 直近の差し替えが失敗していれば、その理由。
    public private(set) var failure: String?
    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    public private(set) var generation = 0

    /// いま通すパイプライン。差し替えに失敗しても**前のものが残る**。
    private(set) var state: any MTLRenderPipelineState
    private(set) var values: [String: ShaderValue]

    /// 断片の在処。保存を拾い直すのに使う。
    ///
    /// **公開しない。** 面に出せば外の語彙 (`URL`) が一覧に載るので、指し直したい需要が
    /// 出てから開ける ([ADR-0020] 決定 6・[ADR-0008])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
    let url: URL?

    private let gpu: RenderDevice
    private let pipeline: EffectPipeline
    /// 最後に組み上がった断片の中身。**同じものを組み直さない**ための控え。
    private var compiledBody: String
    private(set) var watcher: FileWatcher?

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        gpu: RenderDevice, pipeline: EffectPipeline
    ) throws(RenderFailure) {
        self.name = name
        self.url = url
        self.values = values
        self.gpu = gpu
        self.pipeline = pipeline

        let library = try gpu.makeEffectLibrary(named: name, body: body, values: values)
        self.state = try pipeline.makeState(library: library, label: "mokume.effect.\(name)")
        self.compiledBody = body

        if let url {
            watcher = FileWatcher(url: url) { [weak self] in self?.reload() }
        }
    }

    /// いまの値を並べたもの。
    var packedValues: [Float] { ShaderSource.pack(values) }

    /// 渡す値を書き換える。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。
    public func set(_ name: String, _ value: ShaderValue) {
        guard let existing = values[name] else {
            Diagnostics.warn(
                "effect: 宣言していない値 \"\(name)\" は渡せません。"
                    + "作るときの values に書いてください "
                    + "(いまの値: \(values.keys.sorted().joined(separator: ", ")))")
            return
        }
        guard existing.componentCount == value.componentCount else {
            Diagnostics.warn(
                "effect: 値 \"\(name)\" の形が宣言と違います "
                    + "(\(existing.metalType) のところへ \(value.metalType))")
            return
        }
        values[name] = value
    }

    /// 断片を読み直して組み直す。
    ///
    /// **失敗しても前のものを消さない。** 削ってから入れ直す形にすると、組み立てに
    /// 失敗した瞬間に元の効果ごと消えて絵が変わる。新しいものが組み上がってはじめて
    /// 差し替える。
    func reload() {
        guard let url else { return }
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            failure = "断片を読めませんでした: \(url.path)"
            Diagnostics.warn("effect: \(failure!)")
            return
        }
        // **同じ中身なら組み直さない。** 1 度の保存でファイル側と親ディレクトリ側の
        // 両方が反応するため
        guard body != compiledBody else { return }
        do {
            let library = try gpu.makeEffectLibrary(named: name, body: body, values: values)
            state = try pipeline.makeState(library: library, label: "mokume.effect.\(name)")
            compiledBody = body
            failure = nil
            generation += 1
        } catch {
            failure = "\(error)"
            Diagnostics.warn("effect: 断片を組み立て直せませんでした: \(error)")
        }
    }
}
