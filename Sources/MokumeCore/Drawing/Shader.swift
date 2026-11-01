// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics

/// 利用者が書いた塗り。
///
/// 使い方は ``SketchPart/loadShader(_:values:surfaces:)`` にある。
public final class Shader {
    /// 断片・値・保存の拾い直しを持つ骨。**3 者で 1 つ** (``ShaderBox``)。
    private let box: ShaderBox

    /// 断片の在処。保存を拾い直すのに使う。
    public var url: URL? { box.url }
    /// いまのファイルの中身で差し替えられていなければ、その理由 (読めない・組み立てに失敗した)。
    ///
    /// **いま効いている断片とファイルが揃えば下りる** — 直して組み上がったときだけでなく、失敗した
    /// 後で、いま効いている中身へ戻して保存したときも下りる。同じ中身・同じ理由の失敗は、保存を
    /// 何度拾っても組み直さず、注意も 1 度しか出さない (#1830)。
    public var failure: String? { box.failure }
    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    public var generation: Int { box.generation }
    let name: String
    /// いま効いている値。
    var values: [String: ShaderValue] { box.values }
    var watcher: FileWatcher? { box.watcher }
    /// 診断: 差し替えの失敗を知らせた回数 (``ShaderBox/failureReports``)。
    var failureReports: Int { box.failureReports }
    /// 診断: 裏で組みに行った回数 (``ShaderBox`` の「裏で組む」)。
    var backgroundBuildsStarted: Int { box.backgroundBuildsStarted }
    /// 診断: 裏で組んでいる仕事があるか。
    var isBuildingInBackground: Bool { box.isBuildingInBackground }
    /// 診断: 裏で組んでいる仕事が組み上がっているか (まだ差し替えていない)。
    var backgroundBuildFinished: Bool { box.backgroundBuildFinished }

    /// いま渡している面。**名前ごとに口を 1 つ使う** ([#407])。
    ///
    /// 値と別に持つのは詰め先が違うからで、値は列ごとの 1 区画へ、面は口へ載る。
    ///
    /// [#407]: https://github.com/mokume-metal/mokume/issues/407
    private(set) var surfaces: [String: ShaderSurface] {
        didSet { drawnSurfaces = Self.drawn(in: surfaces) }
    }

    /// 渡している面のうち、描き場所 (``ShaderSurface/graphics(_:)``)。
    ///
    /// 置いた図形がこれを読むことを、置くたびに記録する (``Canvas/notePaintPlacement()``・#1653)。
    /// 図形を積むたびに通る口が読むので、面の辞書を毎回たどらずに済むよう控えておく。
    private(set) var drawnSurfaces: [Canvas] = []

    private static func drawn(in surfaces: [String: ShaderSurface]) -> [Canvas] {
        surfaces.values.compactMap {
            if case .graphics(let graphics) = $0 { return graphics }
            return nil
        }
    }

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
    /// 正の寸法の球・箱・平面・円柱を塗るときのパイプライン (``ShapePipeline/unitShapeStates`` の、
    /// この断片の版)。
    /// 断片は ``solidStates`` と同じで、3 組は**揃って**差し替わる (``reload()``)。
    private(set) var unitShapeStates: ShapePipeline.BlendStates

    private let pipeline: ShapePipeline
    private let gpu: RenderDevice
    /// この塗りを当てた面 (``Canvas/shader(_:)``)。値や面を変えるときに列を閉じてもらう。
    ///
    /// **作った面ではなく、当てた面を覚える** ([#1652])。塗りは面をまたいで使えるので、
    /// 作った面にしか知らせないと、他の面で置いた図形が後の値で描かれる。弱く持つ —
    /// 面は利用者が持つもので、塗りが寿命を延ばす筋合いが無い。
    ///
    /// [#1652]: https://github.com/mokume-metal/mokume/issues/1652
    private var users: [Canvas.WeakCanvas] = []

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        surfaces: [String: ShaderSurface] = [:],
        gpu: RenderDevice, pipeline: ShapePipeline
    ) throws(RenderFailure) {
        self.name = name
        self.surfaces = surfaces
        self.drawnSurfaces = Self.drawn(in: surfaces)
        self.gpu = gpu
        self.pipeline = pipeline
        self.box = ShaderBox(
            name: name, url: url, body: body, values: values,
            label: "shader", valuesHint: "loadShader's values")

        let library = try gpu.shaders.makeShapeLibrary(
            named: name, body: body, bodyName: box.bodyName, values: values, surfaces: surfaces)
        self.states = try pipeline.makeStates(
            fragmentLibrary: library, label: "mokume.shader.\(name)")
        self.solidStates = try pipeline.makeStates(
            fragmentLibrary: library, label: "mokume.shader.\(name).solid",
            vertexFunctionName: ShapePipeline.solidVertexFunctionName)
        self.unitShapeStates = try pipeline.makeStates(
            fragmentLibrary: library, label: "mokume.shader.\(name).unit-shape",
            vertexFunctionName: ShapePipeline.unitShapeVertexFunctionName)

        box.watch { [weak self] in self?.reload() }
    }

    /// 渡す値を書き換える。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。増やすかどうかは
    /// 読み込むときに決める。
    public func set(_ name: String, _ value: ShaderValue) {
        // **断る入力と同じ値の書き直しでは、列を閉じない** (#2789)。値が変わると分かってから、旧値を
        // 持つ列を閉じる。比べるのはビット列で、+0 と -0・NaN の違いは別の値として扱う
        box.assign(name, value) { paintWillChange() }
    }

    /// 渡す値を、Swift の値のまま書き換える (``ShaderValueConvertible``)。
    ///
    /// `Float`・`Int`・`Double` の変数も、`Vector2`・`Vector3`・`LinearRGBA`・`Bool`・`Transform` も
    /// 包まずに渡せる。宣言と違う型の値は警告して断る。
    public func set(_ name: String, _ value: some ShaderValueConvertible) {
        set(name, value.shaderValue)
    }

    /// 渡す面を差し替える。
    ///
    /// **宣言していない名前は受け付けない** — 面の宣言も断片と一緒に組み上がるので、
    /// 後から名前を増やすと組み直しになる (値と同じ規則)。
    public func set(_ name: String, _ surface: ShaderSurface) {
        paintWillChange()
        guard surfaces[name] != nil else {
            Diagnostics.warn(
                "shader: \"\(name)\" was never declared as a surface, so it cannot be passed. "
                    + "Write it in loadShader's surfaces "
                    + "(what is there now: \(surfaces.keys.sorted().joined(separator: ", ")))")
            return
        }
        surfaces[name] = surface
    }

    /// この塗りを当てた面を覚える。**同じ面は 1 度だけ。** 覚えるついでに、死んだ面を落とす。
    func note(usedBy canvas: Canvas) {
        guard !users.contains(where: { $0.canvas === canvas }) else { return }
        users.removeAll { $0.canvas == nil }
        users.append(Canvas.WeakCanvas(canvas: canvas))
    }

    /// 値か面が変わる。**当てた面のうち、いまこの塗りで置いている面の列を閉じる。**
    private func paintWillChange() {
        for user in users { user.canvas?.shaderWillChange(self) }
    }

    /// いまの値を、シェーダへ渡す並びに詰めたもの。
    var packedValues: [Float] { box.packedValues }

    // MARK: - 差し替え

    /// 断片を読み直して組み直す。**読み直しと控えの更新は骨が持つ** (``ShaderBox/reload(inBackground:prepare:adopt:)``)。
    ///
    /// 窓の経路では裏で組み、組み上がった後のフレームの頭で差し替える (``ShaderBox`` の「裏で組む」)。
    func reload() {
        box.reload(
            inBackground: gpu.shaderRebuildsRunInBackground,
            prepare: { (body: String) throws(RenderFailure) -> BuildJob<Rebuilt> in
                let library = try gpu.shaders.shapeLibraryJob(
                    named: name, body: body, bodyName: box.bodyName, values: values,
                    surfaces: surfaces)
                let flat = pipeline.statesJob(label: "mokume.shader.\(name)")
                let solid = pipeline.statesJob(
                    label: "mokume.shader.\(name).solid",
                    vertexFunctionName: ShapePipeline.solidVertexFunctionName)
                let unitShape = pipeline.statesJob(
                    label: "mokume.shader.\(name).unit-shape",
                    vertexFunctionName: ShapePipeline.unitShapeVertexFunctionName)
                return BuildJob(
                    now: { () throws(RenderFailure) in
                        let made = try library.runNow()
                        return Rebuilt(
                            flat: try flat.makeNow(fragmentLibrary: made),
                            solid: try solid.makeNow(fragmentLibrary: made),
                            unitShape: try unitShape.makeNow(fragmentLibrary: made))
                    },
                    later: { () async throws(RenderFailure) in
                        let made = try await library.run()
                        return Rebuilt(
                            flat: try await flat.make(fragmentLibrary: made),
                            solid: try await solid.make(fragmentLibrary: made),
                            unitShape: try await unitShape.make(fragmentLibrary: made))
                    })
            },
            adopt: { rebuilt in
                // **全部が組み上がってから差し替える。** 1 組だけ差し替わると、平面と
                // 立体 (と単位の形) で違う断片が効いている状態になる
                // **入れ替えた古い状態は、投入済みのフレームが終わるまで抱える** (#1830 の 2 回目の
                // 反証 2・``RenderDevice/holdUntilSubmittedWorkFinishes(_:)``)。列が抱えるのは塗り
                // そのもので、前のフレームが組んだ状態は誰も抱えていない
                gpu.holdUntilSubmittedWorkFinishes(
                    states.all + solidStates.all + unitShapeStates.all)
                states = ShapePipeline.BlendStates(rebuilt.flat)
                solidStates = ShapePipeline.BlendStates(rebuilt.solid)
                unitShapeStates = ShapePipeline.BlendStates(rebuilt.unitShape)
            })
    }

    /// 組み直した平面・立体・単位の形の 3 本ずつ。
    struct Rebuilt: Sendable {
        let flat: ShapePipeline.BuiltStates
        let solid: ShapePipeline.BuiltStates
        let unitShape: ShapePipeline.BuiltStates
    }
}
