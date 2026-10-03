// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// シーンの記述の口を、**口ごとに**フレームの外で呼ぶ ([#1670])。GPU を要する。
///
/// 約束は ADR-0021 決定 4 の「シーンの記述をフレームの外で書いたら、警告して無視する。
/// 黙って捨てない」である。守りは口ごとの `guard admits(…)` (変換とスタイルは
/// `guard isShaping`) で、**書き落とした口が黙る**。これまで変換 ([#941])・切り抜き
/// ([#1505])・効果 ([#1605])・`noLights()` ([#1670]) を 1 件ずつ見つけてきた。
///
/// **この表は範囲の検査の片割れである。** `scripts/api-surface.py` の `PORT_KINDS` が
/// `Sketch` と `Canvas` の公開の口をすべて種類に分け、「シーンの記述」の口の名前がこの
/// ファイルに字面で現れなければ `make api` が赤になる (`check_port_kinds`)。口を足した
/// ときに種類を決め、シーンの記述ならここへ行を足す — 足せば、注意を出すかをここが回す。
///
/// **口ごとに新しい面を作る。** 注意は初回だけ言う仕組みに載っているので、1 つの面で
/// 続けて呼ぶと最初の 1 本しか確かめられない — 残りの guard を外しても緑のままになる。
///
/// [#941]: https://github.com/mokume-metal/mokume/issues/941
/// [#1505]: https://github.com/mokume-metal/mokume/issues/1505
/// [#1605]: https://github.com/mokume-metal/mokume/issues/1605
/// [#1670]: https://github.com/mokume-metal/mokume/issues/1670
@Suite(
    "フレームの外のシーンの記述",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SceneOutsideFrameTests {
    /// 1 つの口。`says` は言うはずの注意で、`push()` のように 2 つの口へ転送する口は
    /// 両方を言う (鍵は種類ごとに分かれている)。
    private struct Mouth {
        let name: String
        let says: [Canvas.OutsideFrame]
        let write: (Canvas) throws -> Void

        init(_ name: String, _ says: Canvas.OutsideFrame..., write: @escaping (Canvas) throws -> Void) {
            self.name = name
            self.says = says
            self.write = write
        }
    }

    /// `Canvas` の口。**同名で引数の違う口は別の行にする** — 転送先が違いうる
    /// (`ambientLight(_:)` の数の形は色の形へ転送するが、転送が要らない書き方もできる)。
    ///
    /// **呼び出しは `$0.` / `canvas.` / `sketch.` から書く。** `check_port_kinds` はその形の
    /// 呼び出しだけを数え、口の多重定義の数 (`Canvas` の側) より少なければ赤にする — 文字列・
    /// 列挙子・読んだ値に同じ名前が出ても、行を足したことにはならない。
    private var mouths: [Mouth] {
        let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        // 恒等でない行列。恒等を渡すと、効いてしまっても「変換は既定のまま」に見える
        var moved = Transform.identity
        moved.translate(x: 5, y: 5)
        return [
            // 視点・投影
            Mouth("camera()", .camera) { $0.camera() },
            Mouth("camera(9)", .camera) { $0.camera(0, 0, 100, 0, 0, 0, 0, 1, 0) },
            Mouth("setCamera", .camera) { $0.setCamera($0.currentCamera) },
            Mouth("perspective()", .camera) { $0.perspective() },
            Mouth("perspective(4)", .camera) { $0.perspective(Float.pi / 3, 1, 1, 1000) },
            Mouth("ortho()", .camera) { $0.ortho() },
            Mouth("ortho(6)", .camera) { $0.ortho(-8, 8, -8, 8, 1, 1000) },
            // 変換 (#941)
            Mouth("translate(x,y)", .transform) { $0.translate(10, 20) },
            Mouth("translate(x,y,z)", .transform) { $0.translate(10, 20, 30) },
            Mouth("rotate", .transform) { $0.rotate(Float.pi / 4) },
            Mouth("rotateX", .transform) { $0.rotateX(Float.pi / 4) },
            Mouth("rotateY", .transform) { $0.rotateY(Float.pi / 4) },
            Mouth("rotateZ", .transform) { $0.rotateZ(Float.pi / 4) },
            Mouth("scale(x,y)", .transform) { $0.scale(2, 3) },
            Mouth("scale(x,y,z)", .transform) { $0.scale(2, 3, 4) },
            Mouth("shearX", .transform) { $0.shearX(0.3) },
            Mouth("shearY", .transform) { $0.shearY(0.3) },
            Mouth("applyMatrix", .transform) { $0.applyMatrix(moved) },
            Mouth("resetMatrix", .transform) { $0.resetMatrix() },
            Mouth("pushMatrix", .transform) { $0.pushMatrix() },
            Mouth("popMatrix", .transform) { $0.popMatrix() },
            // 積んだ履歴もフレームに属する (ADR-0021 決定 4 の 2026-09-06 の追補・#925)
            Mouth("pushStyle", .style) { $0.pushStyle() },
            Mouth("popStyle", .style) { $0.popStyle() },
            Mouth("push", .transform, .style) { $0.push() },
            Mouth("pop", .transform, .style) { $0.pop() },
            // 切り抜き (#1505)
            Mouth("clip", .clip) { $0.clip(0, 0, 8, 8) },
            Mouth("noClip", .clip) { $0.noClip() },
            // 効果 (#1605)
            Mouth("effects", .effects) { $0.effects([.invert()]) },
            // 光。`noLights()` は取り除く光が無くても言う (#1670)
            Mouth("ambientLight(color)", .light) { $0.ambientLight(white) },
            Mouth("ambientLight(gray)", .light) { $0.ambientLight(200) },
            Mouth("ambientLight(r,g,b)", .light) { $0.ambientLight(200, 180, 160) },
            Mouth("directionalLight(color)", .light) { $0.directionalLight(white, 0, 1, -1) },
            Mouth("directionalLight(r,g,b)", .light) { $0.directionalLight(200, 180, 160, 0, 1, -1) },
            Mouth("pointLight(color)", .light) { $0.pointLight(white, 8, 8, 50) },
            Mouth("pointLight(r,g,b)", .light) { $0.pointLight(200, 180, 160, 8, 8, 50) },
            Mouth("spotLight(color)", .light) { $0.spotLight(white, 8, 8, 50, 0, 0, -1) },
            Mouth("spotLight(r,g,b)", .light) { $0.spotLight(200, 180, 160, 8, 8, 50, 0, 0, -1) },
            Mouth("lights", .light) { $0.lights() },
            Mouth("noLights", .light) { $0.noLights() },
            // 材質
            Mouth("ambient(color)", .material) { $0.ambient(white) },
            Mouth("ambient(gray)", .material) { $0.ambient(200) },
            Mouth("ambient(r,g,b)", .material) { $0.ambient(200, 180, 160) },
            Mouth("emissive(color)", .material) { $0.emissive(white) },
            Mouth("emissive(gray)", .material) { $0.emissive(200) },
            Mouth("emissive(r,g,b)", .material) { $0.emissive(200, 180, 160) },
            Mouth("metalness", .material) { $0.metalness(0.5) },
            Mouth("shininess", .material) { $0.shininess(8) },
            // 影
            Mouth("shadows", .shadow) { $0.shadows(true) },
            Mouth("shadowRange", .shadow) { $0.shadowRange(200) },
            Mouth("shadowDetail", .shadow) { $0.shadowDetail(512) },
            Mouth("shadowBias", .shadow) { $0.shadowBias(0.01) },
            Mouth("castShadow", .shadow) { $0.castShadow(false) },
            Mouth("receiveShadow", .shadow) { $0.receiveShadow(false) },
            // 周囲の光
            Mouth("surroundings", .surroundings) { $0.surroundings(.sky) },
            // 粒と計算。表 (ADR-0021 決定 4) には無いが、フレームの中でだけ扱い、外では注意して
            // 無視する口 (`Canvas.isShaping` の説明が挙げる並び)
            Mouth("particles", .particles) { $0.particles(try $0.makeParticles(count: 4)) },
            Mouth("force", .particles) { $0.force(try $0.makeParticles(count: 4), [.gravity(0, 90)]) },
            Mouth("compute(1D)", .compute) { canvas in
                let heat = try canvas.makeNumbers(count: 4)
                let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
                canvas.compute(ramp, over: 4, writes: [heat])
            },
            Mouth("compute(2D)", .compute) { canvas in
                let heat = try canvas.makeNumbers(count: 4)
                let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
                canvas.compute(ramp, over: 2, by: 2, writes: [heat])
            },
        ]
    }

    /// `ComputeTests` の断片と同じ形。中身は問わない (頼んだ時点で断られる)。
    private static let ramp = """
        kernel void ramp(device float *out [[buffer(0)]],
                         constant Values &values [[buffer(MOKUME_VALUES)]],
                         uint id [[thread_position_in_grid]])
        {
            out[id] = float(id) * values.scale;
        }
        """

    @Test("シーンの記述の口は、フレームの外で呼ぶと注意して無視する")
    func sceneDescriptionsOutsideAFrameAreIgnored() throws {
        let gpu = try RenderDevice()
        for mouth in mouths {
            let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
            try mouth.write(canvas)
            for subject in mouth.says {
                #expect(
                    canvas.warnings.hasWarned(subject.warning),
                    "\(mouth.name) がフレームの外で黙って捨てている (\(subject) の注意が無い)")
            }
            expectUntouched(canvas, after: mouth.name)
        }
    }

    /// 形の組み立て (`createShape`) の中は、変換とスタイルの積み降ろしだけが形に焼き付いて
    /// 意味を持つ (ADR-0021 決定 4 の 2026-09-15 の追補)。**それ以外のシーンの記述は形に
    /// 焼き付かない**ので、組み立ての中でもフレームの外のままである。守りを `isShaping` で
    /// 書くと、ここだけ黙る (効果と切り抜きが `isShaping` ではなく `admits` を通る理由)。
    @Test("形の組み立ての中でも、形に焼き付かないシーンの記述はフレームの外として注意する")
    func sceneDescriptionsInsideAShapeOutsideAFrameAreIgnored() throws {
        let gpu = try RenderDevice()
        let shaping: Set<Canvas.OutsideFrame> = [.transform, .style]
        for mouth in mouths where shaping.isDisjoint(with: mouth.says) {
            let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
            var failure: (any Error)?
            _ = canvas.createShape {
                do { try mouth.write(canvas) } catch { failure = error }
            }
            #expect(failure == nil, "\(mouth.name) が組み立ての中で投げた: \(String(describing: failure))")
            for subject in mouth.says {
                #expect(
                    canvas.warnings.hasWarned(subject.warning),
                    "\(mouth.name) が組み立ての中で黙って効いている (\(subject) の注意が無い)")
            }
            expectUntouched(canvas, after: mouth.name)
        }
    }

    /// `draw()` の中で組み立てても、形に焼き付かないシーンの記述は効かない ([#1529] の案 A)。
    /// 以前は守りが `isDrawing` だけを見ていたので素通りし、`Style` に入っている切り抜き・
    /// 材質・影の落とし方は形にも入らず出口で黙って消え、光・視点・効果などはそのフレームに
    /// 効いていた — `setup()` で組み立てたときと扱いが割れていた。
    ///
    /// 見るのは 3 つ: 組み立ての注意 (フレームの外の注意ではない) を言う・`ShapeExitTests` の表で
    /// 「断る」に載る状態がどれも変わらない・返った形が中で呼ばなかった形と同じ。
    ///
    /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
    @Test("フレームの中の形の組み立てでも、形に焼き付かないシーンの記述は注意して無視する (#1529)")
    func sceneDescriptionsInsideAShapeInsideAFrameAreIgnored() throws {
        let gpu = try RenderDevice()
        let shaping: Set<Canvas.OutsideFrame> = [.transform, .style]
        let refused = ShapeExit.refusedNames
        for mouth in mouths where shaping.isDisjoint(with: mouth.says) {
            let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
            var failure: (any Error)?
            var before: [String: String] = [:]
            var after: [String: String] = [:]
            var plain = Shape.empty
            var written = Shape.empty
            try canvas.draw {
                plain = canvas.createShape { canvas.rect(2, 2, 4, 4) }
                before = ShapeExit.fingerprint(of: canvas, refused)
                written = canvas.createShape {
                    do { try mouth.write(canvas) } catch { failure = error }
                    canvas.rect(2, 2, 4, 4)
                }
                after = ShapeExit.fingerprint(of: canvas, refused)
            }
            #expect(failure == nil, "\(mouth.name) が組み立ての中で投げた: \(String(describing: failure))")
            for subject in mouth.says {
                let inside = try #require(
                    Canvas.InsideShape.allCases.first { $0.outsideFrame == subject },
                    "\(subject) に組み立ての中の種類が無い")
                #expect(
                    canvas.warnings.message(for: inside.warning) == inside.notice,
                    "\(mouth.name) が組み立ての中で黙って効いている (\(inside) の注意が無い)")
                #expect(
                    !canvas.warnings.hasWarned(subject.warning),
                    "\(mouth.name) がフレームの中なのに、フレームの外の注意を言った")
            }
            for name in refused.sorted() {
                #expect(after[name] == before[name], "\(mouth.name) で \(name) が変わった")
            }
            expectUntouched(canvas, after: mouth.name)
            #expect(written.runs == plain.runs, "\(mouth.name) で形の区間の設定が変わった")
            #expect("\(written.vertices)" == "\(plain.vertices)", "\(mouth.name) で形の頂点が変わった")
            #expect(written.solidVertices.count == plain.solidVertices.count, "\(mouth.name) で形に立体が入った")
        }
    }

    /// 無視したこと =**シーンの記述がどれも既定のまま**であること。口ごとに見る先を選ばず
    /// 全部を見るので、別の種類の状態へ漏れて効いた場合も拾う。積んだ履歴は外から読めない
    /// ので、ここでは見ない (`CanvasTests.transformsOutsideAFrameLeaveThePictureAlone`)。
    private func expectUntouched(_ canvas: Canvas, after name: String) {
        #expect(canvas.transform == .identity, "\(name) で変換が効いている")
        #expect(canvas.cameraStorage == nil, "\(name) で視点が効いている")
        #expect(canvas.style.clip == nil, "\(name) で切り抜きが効いている")
        #expect(canvas.pendingEffects.isEmpty, "\(name) で効果が残っている")
        #expect(canvas.activeLights.isEmpty, "\(name) で光が残っている")
        #expect(canvas.activeSurroundings == nil, "\(name) で周囲が残っている")
        #expect(canvas.style.material == .default, "\(name) で材質が効いている")
        #expect(!canvas.shadowsEnabled, "\(name) で影が効いている")
        #expect(canvas.shadowRangeValue == nil, "\(name) で影の範囲が効いている")
        #expect(canvas.shadowDetailValue == ShadowMap.defaultDetail, "\(name) で影の細かさが効いている")
        #expect(canvas.shadowBiasValue == ShadowMap.defaultBias, "\(name) で影のずらしが効いている")
        #expect(canvas.style.castsShadow && canvas.style.receivesShadow, "\(name) で影の落とし方が効いている")
        #expect(canvas.pendingComputations.isEmpty, "\(name) で計算が残っている")
    }

    // MARK: - Sketch にだけある口

    /// `setup()` で 1 つの口を呼ぶスケッチ。`setup()` は最初のフレームより前に走る
    /// (``SketchRuntime/start()``) ので、ここで書いたシーンの記述はどのフレームにも属さない。
    final class CallsInSetup: Sketch {
        var write: (CallsInSetup) -> Void = { _ in }
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func setup() { write(self) }
        func draw() {}
    }

    /// `Canvas` に転送先を持たない口は、`Sketch` の側で呼ぶ。どちらも中で `Canvas` の
    /// 守られた口 (視点・粒) を通るので、言う注意はその口のものである。
    private var sketchMouths: [(name: String, says: Canvas.OutsideFrame, write: (any Sketch) -> Void)] {
        [
            ("orbitControl", .camera, { $0.orbitControl() }),
            (
                "emit", .particles,
                { sketch in
                    guard let dust = try? sketch.makeParticles(count: 4) else { return }
                    sketch.emit(dust, from: .point(8, 8), rate: 60)
                }
            ),
        ]
    }

    /// `draw()` の中で形を組み立て、その中で 1 つの口を呼ぶスケッチ。
    final class CallsInsideAShape: Sketch {
        var write: (CallsInsideAShape) -> Void = { _ in }
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() { _ = createShape { write(self) } }
    }

    /// `Sketch` にだけある口を、`draw()` の中の組み立てで呼ぶ (#1684 の反証)。守りは `Canvas` の
    /// 口と同じ ``Canvas/admits(_:)`` を通るが、`orbitControl()` は**守りより前に道具の状態を
    /// 進めうる**口なので (#1670 の反証)、組み立ての中でも慣性と食った印が進まないことを見る。
    @Test("Sketch にだけある口も、draw() の中の組み立てで呼ぶと注意して無視する (#1529)")
    func sketchOnlyMouthsInsideAShapeInsideAFrameAreIgnored() throws {
        let gpu = try RenderDevice()
        for mouth in sketchMouths {
            let sketch = CallsInsideAShape()
            sketch.write = { mouth.write($0) }
            let runtime = try SketchRuntime(sketch: sketch, gpu: gpu)
            runtime.start()
            try runtime.advance()
            let inside = try #require(Canvas.InsideShape.allCases.first { $0.outsideFrame == mouth.says })
            #expect(
                runtime.canvas.warnings.message(for: inside.warning) == inside.notice,
                "\(mouth.name) が draw() の中の組み立てで黙って効いている")
            #expect(
                !runtime.canvas.warnings.hasWarned(mouth.says.warning),
                "\(mouth.name) がフレームの中なのに、フレームの外の注意を言った")
            expectUntouched(runtime.canvas, after: mouth.name)
            #expect(runtime.orbit == nil, "\(mouth.name) が組み立ての中で視点の道具を進めている")
            #expect(runtime.orbitAdvancedAt == -1, "\(mouth.name) が組み立ての中で視点の道具を進めている")
        }
    }

    @Test("Sketch にだけある口も、setup() で呼ぶと注意して無視する")
    func sketchOnlyMouthsOutsideAFrameAreIgnored() throws {
        let gpu = try RenderDevice()
        for mouth in sketchMouths {
            let sketch = CallsInSetup()
            sketch.write = mouth.write
            let runtime = try SketchRuntime(sketch: sketch, gpu: gpu)
            runtime.start()
            #expect(
                runtime.canvas.warnings.hasWarned(mouth.says.warning),
                "\(mouth.name) が setup() で黙って捨てている")
            expectUntouched(runtime.canvas, after: mouth.name)
            // 視点を操る道具の状態も進めない。進めてから断ると、注意は出ても慣性と
            // 引きずった量を食った印だけが 1 段進む (#1670 の反証で見つかった)
            #expect(runtime.orbit == nil, "\(mouth.name) が setup() で視点の道具を進めている")
            #expect(runtime.orbitAdvancedAt == -1, "\(mouth.name) が setup() で視点の道具を進めている")
        }
    }
}
