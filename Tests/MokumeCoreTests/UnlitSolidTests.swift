// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 光も周囲も置かない立体の塗りを、光の枝を外した断片で描く特化の検査 ([#1795])。GPU を要する。
///
/// **この特化は速さだけを変え、画素は 1 ビットも変えない。** 枝は光・周囲・背景がどれも無い列では
/// 必ず偽になるので、外し損ねても (入れ損ねても) 絵が崩れるのは「枝が要る列に外した断片を使った」
/// ときだけである — それを光の検査 (`LightTests` ほか) と、ここの「特化あり / なしで画素が全部同じ」が
/// 受け持つ。逆向き (外せる列に外さない) は絵に出ないので、判定の述語そのものと、組んだ本数をここで見る。
///
/// [#1795]: https://github.com/mokume-metal/mokume/issues/1795
@Suite(
    "光なしの立体の塗りの特化",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct UnlitSolidTests {
    private let grey = LinearRGBA.linear(red: 0.5, green: 0.5, blue: 0.5)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 96, height: 96)
    }

    /// 絵を描いて、作業空間の画素をそのまま返す。`unlit` が偽なら、特化を止めて枝を残した断片で描く。
    private func render(unlit: Bool, sharesUnitShapes: Bool = true, scene: (Canvas) -> Void) throws
        -> PixelBuffer
    {
        let canvas = try makeCanvas()
        canvas.specializesUnlitSolids = unlit
        canvas.sharesUnitShapes = sharesUnitShapes
        try canvas.draw {
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
            scene(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// 特化あり / なしで、画素が 1 ビットも違わないこと。
    private func expectSamePicture(
        _ name: String, sharesUnitShapes: Bool = true, scene: (Canvas) -> Void
    ) throws {
        let plain = try render(unlit: false, sharesUnitShapes: sharesUnitShapes, scene: scene)
        let specialized = try render(unlit: true, sharesUnitShapes: sharesUnitShapes, scene: scene)
        #expect(plain == specialized, "\(name): 特化で画素が変わった")
        // 何も描いていない絵で一致しても何も言えない
        var drawn = false
        for y in 0..<plain.height where !drawn {
            for x in 0..<plain.width where plain[x, y] != plain[0, 0] {
                drawn = true
                break
            }
        }
        #expect(drawn, "\(name): 絵が空")
    }

    private func solids(_ canvas: Canvas) {
        canvas.noStroke()
        canvas.fill(.display(red: 0.9, green: 0.5, blue: 0.2))
        canvas.push()
        canvas.translate(30, 30, 0)
        canvas.rotateX(0.5)
        canvas.rotateY(0.7)
        canvas.box(36)
        canvas.pop()
        canvas.fill(.display(red: 0.2, green: 0.7, blue: 0.9, alpha: 0.6))
        canvas.push()
        canvas.translate(62, 58, 4)
        canvas.sphere(22)
        canvas.pop()
        canvas.fill(.display(red: 0.6, green: 0.9, blue: 0.3))
        canvas.push()
        canvas.translate(30, 70, 0)
        canvas.rotateX(1.0)
        canvas.torus(14, 5)
        canvas.pop()
        canvas.push()
        canvas.translate(70, 24, 0)
        canvas.cone(12, 30)
        canvas.pop()
    }

    // MARK: - 画素が変わらない

    @Test("光も周囲も無い立体の塗りは、特化しても画素が全部同じ (単位の形)")
    func unitShapesKeepTheirPixels() throws {
        try expectSamePicture("単位の形") { solids($0) }
    }

    @Test("光も周囲も無い立体の塗りは、特化しても画素が全部同じ (寸法ごとの形)")
    func sizedShapesKeepTheirPixels() throws {
        try expectSamePicture("寸法ごとの形", sharesUnitShapes: false) { solids($0) }
    }

    @Test("重ねる・置き換える以外の混ぜ方の列も、画素が全部同じ")
    func compositedColumnsKeepTheirPixels() throws {
        for mode in [BlendMode.add, .multiply, .screen, .replace] {
            try expectSamePicture("混ぜ方 \(mode)") { canvas in
                canvas.blendMode(mode)
                solids(canvas)
            }
        }
    }

    @Test("1 フレームの中で光あり → なし → ありと切り替えても、画素が全部同じ")
    func switchingLightsInsideAFrameKeepsThePixels() throws {
        try expectSamePicture("光の切り替え") { canvas in
            canvas.noStroke()
            canvas.fill(.display(red: 0.9, green: 0.9, blue: 0.9))
            for (index, lit) in [true, false, true, false].enumerated() {
                canvas.noLights()
                if lit {
                    canvas.ambientLight(grey)
                    canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), 0.3, 0.8, -0.5)
                }
                canvas.push()
                canvas.translate(16 + Float(index) * 20, 40 + Float(index % 2) * 18, 0)
                canvas.box(16)
                canvas.pop()
            }
        }
    }

    @Test("周囲を置いた列・周囲を背景にした列は特化せず、画素が全部同じ")
    func surroundingsKeepTheirPixels() throws {
        try expectSamePicture("周囲") { canvas in
            canvas.surroundings(.sunset)
            solids(canvas)
        }
        try expectSamePicture("周囲の背景") { canvas in
            canvas.surroundings(.sky)
            canvas.background(.sky)
            solids(canvas)
        }
    }

    /// **粒も同じ断片を通る** (`solidStates`)。光の無い粒の列も特化で描くので、画素が変わらないことを
    /// 粒の経路 (GPU が置き場所を書く列) で見る。
    @Test("光の無い粒の列も、特化しても画素が全部同じ")
    func particlesKeepTheirPixels() throws {
        func picture(unlit: Bool, route: Canvas.ParticleRoute) throws -> PixelBuffer {
            let canvas = try makeCanvas()
            canvas.specializesUnlitSolids = unlit
            canvas.particleRoute = route
            var randomness = Randomness(seed: 20_260_829)
            let dust = try canvas.makeParticles(count: 512)
            for _ in 0..<8 {
                var stream = randomness
                try canvas.draw {
                    canvas.background(.display(red: 0, green: 0, blue: 0))
                    canvas.emit(
                        dust, from: .point(48, 20), toward: .plane(0...(2 * Float.pi)), rate: 600,
                        speed: 20...45, life: 0.4...1.2, size: 3...6,
                        color: .linear(red: 1, green: 0.6, blue: 0.2), using: &stream)
                    canvas.force(dust, [.gravity(0, 60), .drag(0.5)])
                    canvas.particles(dust)
                }
                randomness = stream
            }
            return try canvas.target.readPixels()
        }
        for route in [Canvas.ParticleRoute.instanced, .reference] {
            let plain = try picture(unlit: false, route: route)
            let specialized = try picture(unlit: true, route: route)
            var brightest: Float = 0
            for value in plain.components { brightest = max(brightest, Float(value)) }
            #expect(brightest > 0.1, "粒が出ていない (\(route))")
            #expect(plain == specialized, "粒の画素が変わった (\(route))")
        }
    }

    // MARK: - 判定

    /// 判定の述語を、列を閉じたまま取り出して見る。
    private func closedBatch(specializing: Bool = true, _ scene: (Canvas) -> Void) throws -> Canvas.Batch {
        let canvas = try makeCanvas()
        canvas.specializesUnlitSolids = specializing
        var batch: Canvas.Batch?
        try canvas.draw {
            canvas.noStroke()
            scene(canvas)
            canvas.closeBatch()
            batch = canvas.batches.last
        }
        return try #require(batch)
    }

    @Test("光も周囲も置かない立体の塗りの列だけが、特化で描く")
    func onlyUnlitSolidFillsAreSpecialized() throws {
        var specializing = true
        func decide(_ scene: (Canvas) -> Void) throws -> Bool {
            try closedBatch(specializing: specializing, scene).unlitSolid != nil
        }
        // 光も周囲も無い
        #expect(try decide { $0.box(20) })
        // 1 つでも置いた列は特化しない (光・底上げ・周囲)
        #expect(try !decide { $0.pointLight(.linear(red: 1, green: 1, blue: 1), 0, 0, 50); $0.box(20) })
        #expect(try !decide { $0.ambientLight(grey); $0.box(20) })
        #expect(try !decide { $0.surroundings(.sky); $0.box(20) })
        // 光を置いた後に消したら、また特化する
        #expect(try decide { $0.ambientLight(grey); $0.noLights(); $0.box(20) })
        // 平面は立体の列ではない
        #expect(try !decide { $0.rect(0, 0, 10, 10) })
        // 特化を止めれば使わない (検査が枝を残した断片と比べる口)
        specializing = false
        #expect(try !decide { $0.box(20) })
    }

    @Test("利用者の断片の列は特化しない")
    func userShadersAreNotSpecialized() throws {
        let canvas = try makeCanvas()
        let plain = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        var batch: Canvas.Batch?
        try canvas.draw {
            canvas.noStroke()
            canvas.shader(plain)
            canvas.box(20)
            canvas.closeBatch()
            batch = canvas.batches.last
        }
        #expect(try #require(batch).unlitSolid == nil)
    }

    // MARK: - 組む本数

    @Test("光を置いた列だけの絵は特化の組を 1 本も組まず、光を置かない列は使う分だけ組む")
    func buildsOnlyWhatTheFrameUses() throws {
        let canvas = try makeCanvas()
        let pipeline = canvas.pipeline
        #expect(pipeline.builtUnlitSolidStateCount == 0, "起動で組んでいる")
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.ambientLight(grey)
            canvas.box(20)
        }
        #expect(pipeline.builtUnlitSolidStateCount == 0, "光を置いた絵で組んだ")
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.box(20)
        }
        // 重ねる列の単位の形 1 本だけ
        #expect(pipeline.builtUnlitSolidStateCount == 1)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.box(20)
        }
        #expect(pipeline.builtUnlitSolidStateCount == 1, "同じ組を組み直した")
    }

    /// 切り抜きを置いたままの `background(色)` は、面を置き換える板を列として積む。板は光を持たない
    /// (`lightRange` が空) が、特化の組を使わない — 光を置いた絵の背景の置き換えが、置き換える列の
    /// 組を 1 本増やさない。
    @Test("切り抜きの下の背景の置き換えは特化の組を使わず、光を置いた絵は 1 本も組まない")
    func surfaceReplacementsDoNotBuildSpecializedPipelines() throws {
        let canvas = try makeCanvas()
        var replacement: Canvas.Batch?
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.ambientLight(grey)
            canvas.box(20)
            canvas.clip(10, 10, 40, 40)
            canvas.background(.display(red: 0.3, green: 0.1, blue: 0.1))
            replacement = canvas.batches.last
        }
        let batch = try #require(replacement)
        #expect(batch.replacesSurface, "置き換える板が積まれていない")
        #expect(batch.unlitSolid == nil)
        #expect(canvas.pipeline.builtUnlitSolidStateCount == 0, "光を置いた絵の背景の置き換えで組んだ")
        // 光を置かない絵でも、組むのは箱の列の 1 本だけ (置き換える列は組まない)
        let unlit = try makeCanvas()
        try unlit.draw {
            unlit.background(0)
            unlit.noStroke()
            unlit.box(20)
            unlit.clip(10, 10, 40, 40)
            unlit.background(.display(red: 0.3, green: 0.1, blue: 0.1))
        }
        #expect(unlit.pipeline.builtUnlitSolidStateCount == 1)
    }

    /// 列は閉じるときに鍵を決める — 描き切りは述語を評価し直さない。閉じたあとで旗を変えても、
    /// 閉じた列は閉じたときの答えで描く。
    @Test("特化できるかは列を閉じるときに決まり、描き切りでは評価し直さない")
    func theDecisionIsMadeWhenTheBatchCloses() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.box(20)
            canvas.closeBatch()
            canvas.specializesUnlitSolids = false
        }
        #expect(canvas.pipeline.builtUnlitSolidStateCount == 1)
    }

    // MARK: - 列の選び方 (既定の組と同じ)

    /// 置き換える列のうち、細い線を広げた頂点を持つ列は、下地を読む列で描く (#1637)。特化した組もその列を
    /// 使う — 述語に細い線の被覆を写して外すのではなく、既定の組と同じ選び方で列を決める。
    @Test("細い線を広げた頂点を持つ置き換える列は、下地を読む列の特化で描き、画素が全部同じ")
    func thinCoverageReplaceColumnsUseTheCompositeColumn() throws {
        func scene(_ canvas: Canvas) {
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(0.4)
            canvas.blendMode(.replace)
            let shape = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(-30, -30, 0)
                canvas.vertex(30, -30, 0)
                canvas.vertex(30, 30, 0)
                canvas.endShape(.close)
            }
            canvas.translate(48, 48, 0)
            canvas.shape(shape)
        }
        let batch = try closedBatch(scene)
        #expect(batch.thinCoverage, "細い線の被覆が立っていない")
        #expect(batch.run.mode == .replace)
        let key = try #require(batch.unlitSolid, "特化の対象でない")
        #expect(key.column == .composite, "置き換える列のまま特化した")
        try expectSamePicture("細い線の置き換え", scene: scene)
    }

    // MARK: - 組めなかったとき

    /// 特化は速さだけを変える。組めなければ 1 度だけ言い、その列は起動で組み済みの既定の組で描く —
    /// フレームが描けなくなったり、絵が変わったりしない。
    @Test("特化の組を組めなくても、1 度だけ言って既定の組で描き、画素は変わらない")
    func fallsBackToTheGeneralPipelineWhenABuildFails() throws {
        let reference = try render(unlit: false, scene: { solids($0) })
        let canvas = try makeCanvas()
        canvas.pipeline.failBuildingUnlitSolidsForTesting(.pipelineUnavailable(reason: "injected"))
        for _ in 0..<2 {
            try canvas.draw {
                canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
                solids(canvas)
            }
        }
        #expect(canvas.warnings.hasWarned(.solidVariantUnavailable))
        #expect(canvas.pipeline.builtUnlitSolidStateCount == 0)
        #expect(try canvas.target.readPixels() == reference, "既定の組へ戻した絵が変わった")
        // 口を戻しても、組めなかった鍵は組み直さない (毎フレームのコンパイルを避ける)
        canvas.pipeline.failBuildingUnlitSolidsForTesting(nil)
        try canvas.draw {
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
            solids(canvas)
        }
        #expect(canvas.pipeline.builtUnlitSolidStateCount == 0)
        #expect(try canvas.target.readPixels() == reference)
    }

    /// 控えはデバイスで共有なので、2 つ目以降のキャンバスは組もうとしない。それでも、そのキャンバスが
    /// 既定の組で描いていることは、キャンバスごとに 1 度言う (反証 2 回目)。
    @Test("控えが組めなかった鍵だけで描く 2 つ目のキャンバスにも、1 度だけ言う")
    func warnsOnEveryCanvasThatFallsBack() throws {
        let gpu = try RenderDevice()
        let first = try CanvasFixture.make(gpu: gpu, width: 96, height: 96)
        first.pipeline.failBuildingUnlitSolidsForTesting(.pipelineUnavailable(reason: "injected"))
        try first.draw {
            first.background(.display(red: 0.1, green: 0.1, blue: 0.2))
            solids(first)
        }
        #expect(first.warnings.hasWarned(.solidVariantUnavailable))
        // 2 つ目は組もうとしない (口を戻しても控えの失敗を読む) — だが、既定の組で描くことは言う
        first.pipeline.failBuildingUnlitSolidsForTesting(nil)
        let second = try CanvasFixture.make(gpu: gpu, width: 96, height: 96)
        #expect(!second.warnings.hasWarned(.solidVariantUnavailable))
        try second.draw {
            second.background(.display(red: 0.1, green: 0.1, blue: 0.2))
            solids(second)
        }
        #expect(second.pipeline.builtUnlitSolidStateCount == 0, "組み直した")
        #expect(second.warnings.hasWarned(.solidVariantUnavailable), "2 つ目のキャンバスが黙って既定の組で描いた")
    }

    @Test("特化の組は、頂点関数が枝を残す立体でも光の枝を外す値を渡す")
    func theAssemblyPassesUnlitThrough() {
        typealias Constants = ShapePipeline.FragmentConstants
        for vertex in [ShapePipeline.solidVertexFunctionName, ShapePipeline.unitShapeVertexFunctionName] {
            #expect(
                ShapePipeline.fragmentConstants(vertexFunctionName: vertex, formFlags: nil)
                    == Constants(lit: true))
            #expect(
                ShapePipeline.fragmentConstants(vertexFunctionName: vertex, formFlags: nil, unlit: true)
                    == Constants(lit: false))
        }
    }
}
