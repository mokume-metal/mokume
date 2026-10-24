// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 立体の塗りを、列の中身に合わせて特化したパイプラインで描く検査 ([#1795]・[#2366])。GPU を要する。
///
/// - **光も周囲も置かない列は、光の枝を外した断片で描く** (#1795)
/// - **塗りの α がちょうど 1 と CPU で分かる列は、ブレンドなしで描く** (#2366)
///
/// **この特化は速さだけを変え、画素は 1 ビットも変えない。** 枝は光・周囲・背景がどれも無い列では
/// 必ず偽になるので、外し損ねても (入れ損ねても) 絵が崩れるのは「枝が要る列に外した断片を使った」
/// ときだけである — それを光の検査 (`LightTests` ほか) と、ここの「特化あり / なしで画素が全部同じ」が
/// 受け持つ。ブレンドも同じで、α が 1 でない列をブレンドなしで描くと下地が消える・引かれる。逆向き
/// (特化できる列に特化しない) は絵に出ないので、判定の述語そのものと、組んだ本数をここで見る。
///
/// [#1795]: https://github.com/mokume-metal/mokume/issues/1795
/// [#2366]: https://github.com/mokume-metal/mokume/issues/2366
@Suite(
    "特化した立体の塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct UnlitSolidTests {
    private let grey = LinearRGBA.linear(red: 0.5, green: 0.5, blue: 0.5)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 96, height: 96)
    }

    /// 絵を描いて、作業空間の画素をそのまま返す。`unlit` が偽なら光の枝を残した断片で、`opaque` が偽なら
    /// ブレンドありで描く (特化を止める)。
    private func render(
        unlit: Bool, opaque: Bool = false, sharesUnitShapes: Bool = true, scene: (Canvas) -> Void
    ) throws -> PixelBuffer {
        let canvas = try makeCanvas()
        canvas.specializesUnlitSolids = unlit
        canvas.specializesOpaqueSolids = opaque
        canvas.sharesUnitShapes = sharesUnitShapes
        try canvas.draw {
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
            scene(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// 半精度の成分を、ビットのまま並べる。**数でない値を含む絵を比べるのに使う** (`Float16` の `==` は
    /// 数でない値どうしを等しいと言わない)。
    private func bits(_ buffer: PixelBuffer) -> [UInt16] {
        buffer.components.map(\.bitPattern)
    }

    /// 特化あり / なしで、画素が 1 ビットも違わないこと。
    private func expectSamePicture(
        _ name: String, unlit: Bool = true, opaque: Bool = false, sharesUnitShapes: Bool = true,
        scene: (Canvas) -> Void
    ) throws {
        let plain = try render(unlit: false, sharesUnitShapes: sharesUnitShapes, scene: scene)
        let specialized = try render(
            unlit: unlit, opaque: opaque, sharesUnitShapes: sharesUnitShapes, scene: scene)
        #expect(bits(plain) == bits(specialized), "\(name): 特化で画素が変わった")
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
            canvas.specializesOpaqueSolids = unlit
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
    private func closedBatch(
        unlit: Bool = true, opaque: Bool = true, _ scene: (Canvas) -> Void
    ) throws -> Canvas.Batch {
        let canvas = try makeCanvas()
        canvas.specializesUnlitSolids = unlit
        canvas.specializesOpaqueSolids = opaque
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
            try closedBatch(unlit: specializing, opaque: false, scene).solidVariant?.unlit == true
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
        #expect(try #require(batch).solidVariant == nil)
    }

    // MARK: - 組む本数

    @Test("光を置いた列だけの絵は特化の組を 1 本も組まず、光を置かない列は使う分だけ組む")
    func buildsOnlyWhatTheFrameUses() throws {
        let canvas = try makeCanvas()
        canvas.specializesOpaqueSolids = false
        let pipeline = canvas.pipeline
        #expect(pipeline.builtSolidVariantCount == 0, "起動で組んでいる")
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.ambientLight(grey)
            canvas.box(20)
        }
        #expect(pipeline.builtSolidVariantCount == 0, "光を置いた絵で組んだ")
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.box(20)
        }
        // 重ねる列の単位の形 1 本だけ
        #expect(pipeline.builtSolidVariantCount == 1)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.box(20)
        }
        #expect(pipeline.builtSolidVariantCount == 1, "同じ組を組み直した")
    }

    /// 切り抜きを置いたままの `background(色)` は、面を置き換える板を列として積む。板は光を持たない
    /// (`lightRange` が空) が、特化の組を使わない — 光を置いた絵の背景の置き換えが、置き換える列の
    /// 組を 1 本増やさない。
    @Test("切り抜きの下の背景の置き換えは特化の組を使わず、光を置いた絵は 1 本も組まない")
    func surfaceReplacementsDoNotBuildSpecializedPipelines() throws {
        let canvas = try makeCanvas()
        canvas.specializesOpaqueSolids = false
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
        #expect(batch.solidVariant == nil)
        #expect(canvas.pipeline.builtSolidVariantCount == 0, "光を置いた絵の背景の置き換えで組んだ")
        // 光を置かない絵でも、組むのは箱の列の 1 本だけ (置き換える列は組まない)
        let unlit = try makeCanvas()
        unlit.specializesOpaqueSolids = false
        try unlit.draw {
            unlit.background(0)
            unlit.noStroke()
            unlit.box(20)
            unlit.clip(10, 10, 40, 40)
            unlit.background(.display(red: 0.3, green: 0.1, blue: 0.1))
        }
        #expect(unlit.pipeline.builtSolidVariantCount == 1)
    }

    /// 列は閉じるときに鍵を決める — 描き切りは述語を評価し直さない。閉じたあとで旗を変えても、
    /// 閉じた列は閉じたときの答えで描く。
    @Test("特化できるかは列を閉じるときに決まり、描き切りでは評価し直さない")
    func theDecisionIsMadeWhenTheBatchCloses() throws {
        let canvas = try makeCanvas()
        canvas.specializesOpaqueSolids = false
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.box(20)
            canvas.closeBatch()
            canvas.specializesUnlitSolids = false
        }
        #expect(canvas.pipeline.builtSolidVariantCount == 1)
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
        let key = try #require(batch.solidVariant, "特化の対象でない")
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
        canvas.pipeline.failBuildingSolidVariantsForTesting(.pipelineUnavailable(reason: "injected"))
        for _ in 0..<2 {
            try canvas.draw {
                canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
                solids(canvas)
            }
        }
        #expect(canvas.warnings.hasWarned(.solidVariantUnavailable))
        #expect(canvas.pipeline.builtSolidVariantCount == 0)
        #expect(try canvas.target.readPixels() == reference, "既定の組へ戻した絵が変わった")
        // 口を戻しても、組めなかった鍵は組み直さない (毎フレームのコンパイルを避ける)
        canvas.pipeline.failBuildingSolidVariantsForTesting(nil)
        try canvas.draw {
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
            solids(canvas)
        }
        #expect(canvas.pipeline.builtSolidVariantCount == 0)
        #expect(try canvas.target.readPixels() == reference)
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

    // MARK: - 不透明な列のブレンドなし (#2366)

    /// 奥から手前へ重ねた不透明の箱・球。ブレンドなしで描いて、重なりが変わらないことを見る。
    private func layeredOpaque(_ canvas: Canvas) {
        canvas.noStroke()
        for layer in 0..<5 {
            canvas.fill(
                .display(red: 0.2 + 0.15 * Float(layer), green: 0.6 - 0.1 * Float(layer), blue: 0.8))
            canvas.push()
            canvas.translate(24 + Float(layer) * 10, 28 + Float(layer) * 8, Float(layer - 5) * 6)
            canvas.rotateY(0.3 * Float(layer))
            if layer.isMultiple(of: 2) { canvas.box(34) } else { canvas.sphere(20) }
            canvas.pop()
        }
        canvas.fill(.display(red: 0.9, green: 0.8, blue: 0.2))
        canvas.push()
        canvas.translate(66, 70, 2)
        canvas.plane(30, 22)
        canvas.pop()
    }

    /// 重なる 4 層の三角形を、頂点を並べてその場で置く。`translucentVertex` 番目の頂点だけ α を 0.5 にし、
    /// `strokeAlpha` が 1 でなければ輪郭を引く (輪郭の頂点の α がそれになる)。
    private func freeformTriangles(
        _ canvas: Canvas, translucentVertex: Int = -1, strokeAlpha: Float = 1
    ) {
        canvas.noStroke()
        if strokeAlpha != 1 {
            canvas.stroke(.display(red: 1, green: 1, blue: 1, alpha: strokeAlpha))
            canvas.strokeWeight(2)
        }
        var index = 0
        for layer in 0..<4 {
            let z = Float(layer - 4) * 8
            let shift = Float(layer) * 9
            canvas.beginShape(.triangles)
            for (x, y) in [(10, 14), (58, 18), (30, 60)] as [(Float, Float)] {
                let alpha: Float = index == translucentVertex ? 0.5 : 1
                canvas.fill(
                    .display(
                        red: 0.2 + 0.2 * Float(layer), green: 0.7, blue: 0.9 - 0.2 * Float(layer),
                        alpha: alpha))
                canvas.vertex(x + shift, y + shift * 0.5, z)
                index += 1
            }
            canvas.endShape()
        }
    }

    @Test("不透明な立体の列は、ブレンドなしでも画素が全部同じ (光なし・光あり)")
    func opaqueColumnsKeepTheirPixels() throws {
        for (name, lights) in [("光なし", false), ("光あり", true)] {
            for unlit in [false, true] {
                try expectSamePicture("不透明 \(name) 特化 \(unlit)", unlit: unlit, opaque: true) { canvas in
                    if lights {
                        canvas.ambientLight(grey)
                        canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), 0.3, 0.8, -0.5)
                    }
                    layeredOpaque(canvas)
                }
            }
        }
    }

    @Test("寸法ごとの形の不透明な列も、画素が全部同じ")
    func opaqueSizedShapesKeepTheirPixels() throws {
        try expectSamePicture("寸法ごとの形", unlit: false, opaque: true, sharesUnitShapes: false) {
            layeredOpaque($0)
        }
    }

    @Test("半透明・透けた画素・重ねない混ぜ方が混ざる絵は、ブレンドなしにした列だけで画素が全部同じ")
    func translucentColumnsKeepTheirPixels() throws {
        try expectSamePicture("半透明が間に挟まる", unlit: true, opaque: true) { canvas in
            canvas.noStroke()
            canvas.fill(.display(red: 0.9, green: 0.4, blue: 0.2))
            canvas.push()
            canvas.translate(40, 40, -20)
            canvas.box(50)
            canvas.pop()
            canvas.fill(.display(red: 0.2, green: 0.8, blue: 0.9, alpha: 0.5))
            canvas.push()
            canvas.translate(52, 52, 0)
            canvas.sphere(30)
            canvas.pop()
            canvas.fill(.display(red: 0.7, green: 0.9, blue: 0.3))
            canvas.push()
            canvas.translate(60, 36, 10)
            canvas.box(26)
            canvas.pop()
            canvas.blendMode(.add)
            canvas.fill(.display(red: 0.4, green: 0.1, blue: 0.1))
            canvas.push()
            canvas.translate(30, 62, 20)
            canvas.box(30)
            canvas.pop()
        }
    }

    // MARK: - 不透明の判定 (α がちょうど 1)

    @Test("塗りの α がちょうど 1 の組み込みの形の列だけが、ブレンドなしで描く")
    func onlyAlphaOfExactlyOneIsUnblended() throws {
        func opaque(_ scene: (Canvas) -> Void) throws -> Bool {
            try closedBatch(unlit: false, scene).solidVariant?.opaque == true
        }
        #expect(try opaque { $0.fill(.display(red: 1, green: 0, blue: 0)); $0.box(20) })
        // 光は関係しない
        #expect(try opaque { $0.ambientLight(grey); $0.box(20) })
        // 半透明の塗り・重ねない混ぜ方は、ブレンドを残す
        #expect(try !opaque { $0.fill(.display(red: 1, green: 0, blue: 0, alpha: 0.5)); $0.box(20) })
        #expect(try !opaque { $0.blendMode(.add); $0.box(20) })
        // **1 を超える不透明度は、締めずに渡る口** (``LinearRGBA/init(premultipliedRed:green:blue:alpha:)``)。
        // source-over は下地を引くので、ブレンドなしにすると画素が変わる
        let over = LinearRGBA(premultipliedRed: 0.6, green: 0.3, blue: 0.1, alpha: 1.5)
        #expect(try !opaque { $0.fill(over); $0.box(20) })
        // ちょうど 1 の隣の値も同じ (1 に満たない側)
        let under = LinearRGBA(
            premultipliedRed: 0.6, green: 0.3, blue: 0.1, alpha: Float(1).nextDown)
        #expect(try !opaque { $0.fill(under); $0.box(20) })
        // 平面は立体の列ではない
        #expect(try !opaque { $0.rect(0, 0, 10, 10) })
        // 特化を止めれば使わない (検査が、ブレンドありと比べる口)
        #expect(try closedBatch(opaque: false) { $0.box(20) }.solidVariant?.opaque != true)
    }

    @Test("1 を超える不透明度の塗りは、ブレンドなしにせず、画素が全部同じ")
    func alphaAboveOneKeepsItsPixels() throws {
        let over = LinearRGBA(premultipliedRed: 0.6, green: 0.3, blue: 0.1, alpha: 1.5)
        try expectSamePicture("α 1.5", unlit: true, opaque: true) { canvas in
            canvas.noStroke()
            canvas.fill(.display(red: 0.2, green: 0.5, blue: 0.9))
            canvas.push()
            canvas.translate(40, 40, -20)
            canvas.box(50)
            canvas.pop()
            canvas.fill(over)
            canvas.push()
            canvas.translate(52, 52, 0)
            canvas.box(34)
            canvas.pop()
            canvas.push()
            canvas.translate(30, 62, 10)
            canvas.sphere(18)
            canvas.pop()
        }
    }

    // MARK: - 不透明の判定 (頂点の色を CPU が持つ経路)

    @Test("その場で並べた頂点は、全部の α がちょうど 1 のときだけブレンドなしで描く")
    func freeformColumnsAreUnblendedOnlyWhenEveryVertexIsOpaque() throws {
        func variant(_ scene: @escaping (Canvas) -> Void) throws -> ShapePipeline.SolidVariantKey? {
            try closedBatch(unlit: false, scene).solidVariant
        }
        #expect(try variant { self.freeformTriangles($0) }?.opaque == true)
        // 1 つでも透ける頂点があれば、列ごとブレンドを残す
        #expect(try variant { self.freeformTriangles($0, translucentVertex: 5) }?.opaque != true)
        // 輪郭の頂点も数える
        #expect(try variant { self.freeformTriangles($0, strokeAlpha: 0.5) }?.opaque != true)
    }

    @Test("その場で並べた不透明な頂点も、透ける頂点が混ざる絵も、ブレンドなしで画素が全部同じ")
    func freeformColumnsKeepTheirPixels() throws {
        try expectSamePicture("頂点の並び", unlit: true, opaque: true) { canvas in
            canvas.ambientLight(grey)
            freeformTriangles(canvas)
        }
        try expectSamePicture("透ける頂点", unlit: true, opaque: true) { canvas in
            freeformTriangles(canvas, translucentVertex: 7)
        }
        try expectSamePicture("透ける輪郭", unlit: true, opaque: true) { canvas in
            freeformTriangles(canvas, strokeAlpha: 0.5)
        }
    }

    /// 保持した形の絵。形の 2 つ目の箱の α だけを変えられる。
    private func retainedBoxes(_ canvas: Canvas, secondAlpha: Float) {
        canvas.noStroke()
        let shape = canvas.createShape {
            canvas.fill(.display(red: 1, green: 0, blue: 0))
            canvas.box(20)
            canvas.fill(.display(red: 0, green: 0.5, blue: 1, alpha: secondAlpha))
            canvas.push()
            canvas.translate(14, 6, -10)
            canvas.box(20)
            canvas.pop()
        }
        canvas.fill(.display(red: 1, green: 1, blue: 1))
        for index in 0..<4 {
            canvas.push()
            canvas.translate(24 + Float(index) * 12, 30 + Float(index) * 9, Float(index - 4) * 6)
            canvas.shape(shape)
            canvas.pop()
        }
    }

    @Test("保持した形は、全部の頂点と置き場所の α がちょうど 1 のときだけブレンドなしで描く")
    func retainedShapesAreUnblendedOnlyWhenEveryColorIsOpaque() throws {
        func variants(secondAlpha: Float) throws -> [ShapePipeline.SolidVariantKey?] {
            let canvas = try makeCanvas()
            var found: [ShapePipeline.SolidVariantKey?] = []
            try canvas.draw {
                retainedBoxes(canvas, secondAlpha: secondAlpha)
                canvas.closeBatch()
                for batch in canvas.batches {
                    if case .retained = batch.solidSource { found.append(batch.solidVariant) }
                }
            }
            return found
        }
        let opaque = try variants(secondAlpha: 1)
        #expect(!opaque.isEmpty && opaque.allSatisfy { $0?.opaque == true }, "不透明な保持した形をブレンドありで描いた")
        let translucent = try variants(secondAlpha: 0.5)
        #expect(!translucent.isEmpty && translucent.allSatisfy { $0?.opaque != true }, "透ける頂点を持つ保持した形をブレンドなしにした")
        // 置き場所の色が透ける (``Placement/fill``) ときも、頂点が不透明でもブレンドを残す
        let canvas = try makeCanvas()
        var tinted: [ShapePipeline.SolidVariantKey?] = []
        try canvas.draw {
            canvas.noStroke()
            let shape = canvas.createShape {
                canvas.fill(.display(red: 1, green: 0, blue: 0))
                canvas.box(20)
            }
            canvas.shape(shape, at: [Placement(x: 30, y: 30, fill: .display(red: 1, green: 1, blue: 1, alpha: 0.5))])
            canvas.closeBatch()
            for batch in canvas.batches {
                if case .retained = batch.solidSource { tinted.append(batch.solidVariant) }
            }
        }
        #expect(!tinted.isEmpty && tinted.allSatisfy { $0?.opaque != true })
    }

    @Test("保持した形は、頂点が不透明でも透けていても、ブレンドなしで画素が全部同じ")
    func retainedShapesKeepTheirPixels() throws {
        for alpha in [Float(1), 0.5] {
            try expectSamePicture("保持した形 α \(alpha)", unlit: true, opaque: true) {
                retainedBoxes($0, secondAlpha: alpha)
            }
        }
    }

    /// 読み込んだモデルを 3 つ重ねて置く。
    private func loadedPyramids(_ canvas: Canvas, _ model: Model, alpha: Float) {
        canvas.noStroke()
        for index in 0..<3 {
            // `display(...)` は不透明度を 1 に締めるので、1 を超える値は乗算済みの形で渡す
            canvas.fill(
                alpha > 1
                    ? LinearRGBA(premultipliedRed: 0.9, green: 0.4, blue: 0.2, alpha: alpha)
                    : .display(red: 0.9, green: 0.6 - 0.2 * Float(index), blue: 0.3, alpha: alpha))
            canvas.push()
            canvas.translate(30 + Float(index) * 14, 50 - Float(index) * 6, Float(index - 3) * 8)
            canvas.scale(0.5, 0.5, 0.5)
            canvas.model(model)
            canvas.pop()
        }
    }

    @Test("読み込んだモデルは、塗りの α がちょうど 1 のときだけブレンドなしで描く")
    func loadedModelsAreUnblendedOnlyWhenTheFillIsOpaque() throws {
        func variants(alpha: Float) throws -> [ShapePipeline.SolidVariantKey?] {
            let canvas = try makeCanvas()
            let model = try canvas.loadModel(ModelFixture.pyramid)
            var found: [ShapePipeline.SolidVariantKey?] = []
            try canvas.draw {
                loadedPyramids(canvas, model, alpha: alpha)
                canvas.closeBatch()
                for batch in canvas.batches {
                    if case .model = batch.solidSource { found.append(batch.solidVariant) }
                }
            }
            return found
        }
        let opaque = try variants(alpha: 1)
        #expect(!opaque.isEmpty && opaque.allSatisfy { $0?.opaque == true })
        let translucent = try variants(alpha: 0.5)
        #expect(!translucent.isEmpty && translucent.allSatisfy { $0?.opaque != true })
        // 1 を超える不透明度
        let over = try variants(alpha: 1.5)
        #expect(!over.isEmpty && over.allSatisfy { $0?.opaque != true })
    }

    @Test("読み込んだモデルは、ブレンドなしで画素が全部同じ")
    func loadedModelsKeepTheirPixels() throws {
        for alpha in [Float(1), 0.5] {
            let plain = try makeCanvas()
            plain.specializesUnlitSolids = false
            plain.specializesOpaqueSolids = false
            let special = try makeCanvas()
            for canvas in [plain, special] {
                let model = try canvas.loadModel(ModelFixture.pyramid)
                try canvas.draw {
                    canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
                    loadedPyramids(canvas, model, alpha: alpha)
                }
            }
            #expect(
                try bits(plain.target.readPixels()) == bits(special.target.readPixels()),
                "モデル α \(alpha): 特化で画素が変わった")
        }
    }

    @Test("粒の列は、CPU が色の α を知らないので、ブレンドなしにしない")
    func particleColumnsAreNeverUnblended() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 7)
        let dust = try canvas.makeParticles(count: 64)
        var found: [ShapePipeline.SolidVariantKey?] = []
        try canvas.draw {
            canvas.emit(
                dust, from: .point(48, 20), toward: .plane(0...(2 * Float.pi)), rate: 600,
                speed: 20...45, life: 0.4...1.2, size: 3...6,
                color: .linear(red: 1, green: 0.6, blue: 0.2), using: &randomness)
            canvas.particles(dust)
            canvas.closeBatch()
            for batch in canvas.batches where batch.indirectArguments != nil {
                found.append(batch.solidVariant)
            }
        }
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0?.opaque != true })
    }

    @Test("光を置いても不透明なら、特化の組は光の枝を残してブレンドだけを外す")
    func opaqueLitColumnsBuildTheirOwnPipeline() throws {
        let canvas = try makeCanvas()
        let pipeline = canvas.pipeline
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.ambientLight(grey)
            canvas.box(20)
        }
        #expect(pipeline.builtSolidVariantCount == 1)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.ambientLight(grey)
            canvas.fill(.display(red: 1, green: 0, blue: 0, alpha: 0.5))
            canvas.box(20)
        }
        #expect(pipeline.builtSolidVariantCount == 1, "半透明の列で組んだ")
    }

    // MARK: - 下地が数でない画素 (約束の外)

    /// 下地の画素に数でない値・無限の値を**画素の口で書いて**、その上に不透明な箱を重ねる。描く道では作れない
    /// (足し込みは半精度の上限で止まり、利用者の `shader()` が返した数でない値は断片の出口で 0 に落ちる)
    /// ので、`set()` で書く。
    private func nonFiniteBackdrop(_ canvas: Canvas, value: Float) {
        let bad = LinearRGBA(premultipliedRed: value, green: value, blue: value, alpha: 1)
        for y in 0..<96 {
            for x in 0..<96 { canvas.set(x, y, bad) }
        }
        layeredOpaque(canvas)
    }

    /// **約束の外であることを、違いごと固定する** (#2366)。α がちょうど 1 の source-over は
    /// `source + destination × 0` で、下地が数でないと `0 × NaN`・`0 × Inf` が数でない値になり、箱の上まで
    /// 数でない値で埋まる。ブレンドなしは下地を読まず `source` を書くので、箱は有限の色で出る。
    /// **下地が有限の画素では 2 つは 1 ビットも違わない** (この検査の `1` の行)。数でない値は利用者の
    /// 計算が作るもので、箱の上まで数でない値に染めることを守る理由が無いので、ブレンドなしの側へ寄せた。
    @Test("下地が数でない値・無限の画素の上では、ブレンドなしは箱の色を書き、ブレンドありは数でない値のまま")
    func nonFiniteBackdropsAreOutsideThePromise() throws {
        let background = LinearRGBA.display(red: 0.1, green: 0.1, blue: 0.2)
        func picture(opaque: Bool, value: Float) throws -> PixelBuffer {
            let canvas = try makeCanvas()
            canvas.specializesUnlitSolids = false
            canvas.specializesOpaqueSolids = opaque
            try canvas.draw {
                canvas.background(background)
                nonFiniteBackdrop(canvas, value: value)
            }
            return try canvas.target.readPixels()
        }
        // 箱に覆われる画素 (下地が有限のときの絵が、下地の色と違う所)
        let finite = try picture(opaque: false, value: 1)
        let ground = LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1)
        let covered = [(40, 40), (64, 60), (24, 28)].filter { finite[$0.0, $0.1] != ground }
        #expect(covered.count == 3, "箱に覆われる画素を取り損ねた")
        // 下地が有限なら、ブレンドの有無で画素は 1 ビットも違わない
        #expect(try bits(picture(opaque: true, value: 1)) == bits(finite))

        for (name, value) in [("NaN", Float.nan), ("+Inf", .infinity), ("-Inf", -.infinity)] {
            let blended = try picture(opaque: false, value: value)
            let unblended = try picture(opaque: true, value: value)
            for (x, y) in covered {
                #expect(!blended[x, y].red.isFinite, "\(name): ブレンドありの箱 (\(x), \(y)) は数でない値のまま")
                #expect(unblended[x, y] == finite[x, y], "\(name): ブレンドなしの箱 (\(x), \(y)) が有限の色で出ていない")
            }
            // 箱の外の下地は、どちらも書いた値のまま
            #expect(bits(blended)[0] == bits(unblended)[0])
            #expect(!unblended[2, 2].red.isFinite && !blended[2, 2].red.isFinite)
        }
    }

    // MARK: - 貼る絵

    /// 市松に透けた画素を持つ絵。貼った面は透けた画素から奥が見える。
    private func checkeredPicture(_ canvas: Canvas) -> Image {
        guard let image = try? canvas.createImage(4, 4) else { fatalError("絵を作れない") }
        for y in 0..<4 {
            for x in 0..<4 {
                image.set(
                    x, y,
                    (x + y).isMultiple(of: 2) ? .linear(red: 0.9, green: 0.2, blue: 0.2) : .transparent)
            }
        }
        return image
    }

    @Test("貼る絵のある列は、塗りの α が 1 でもブレンドなしにせず、画素が全部同じ")
    func pictureFillsStayBlended() throws {
        func scene(_ canvas: Canvas) {
            canvas.noStroke()
            canvas.fill(.display(red: 0.2, green: 0.5, blue: 0.9))
            canvas.push()
            canvas.translate(40, 40, -20)
            canvas.box(50)
            canvas.pop()
            canvas.texture(checkeredPicture(canvas))
            canvas.fill(.display(red: 1, green: 1, blue: 1))
            canvas.push()
            canvas.translate(52, 52, 0)
            canvas.box(34)
            canvas.pop()
            canvas.noTexture()
        }
        let batch = try closedBatch(unlit: false) { canvas in
            canvas.texture(checkeredPicture(canvas))
            canvas.fill(.display(red: 1, green: 1, blue: 1))
            canvas.box(20)
        }
        #expect(batch.solidVariant?.opaque != true, "貼る絵のある列をブレンドなしにした")
        try expectSamePicture("貼る絵", unlit: true, opaque: true, scene: scene)
    }

    // MARK: - 細い線の被覆

    /// 1 画素より細い立体の線は、被覆 (1 未満) を α に掛けて出す。α を下げる列なので、頂点の α が 1 でも
    /// ブレンドなしにしない (下地に混ぜる)。
    @Test("細い線を広げた頂点を持つ重ねる列は、ブレンドなしにせず、画素が全部同じ")
    func thinCoverageColumnsStayBlended() throws {
        func scene(_ canvas: Canvas) {
            canvas.noStroke()
            canvas.fill(.display(red: 0.8, green: 0.8, blue: 0.2))
            canvas.push()
            canvas.translate(48, 48, -20)
            canvas.box(70)
            canvas.pop()
            canvas.noFill()
            canvas.stroke(.display(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(0.4)
            canvas.push()
            canvas.translate(48, 48, 0)
            canvas.beginShape()
            canvas.vertex(-30, -30, 0)
            canvas.vertex(30, -30, 0)
            canvas.vertex(30, 30, 0)
            canvas.endShape(.close)
            canvas.pop()
        }
        let batch = try closedBatch(unlit: false, scene)
        #expect(batch.thinCoverage, "細い線の被覆が立っていない")
        #expect(batch.run.mode == .blend)
        #expect(batch.solidVariant?.opaque != true, "細い線の被覆を持つ列をブレンドなしにした")
        try expectSamePicture("細い線", unlit: true, opaque: true, scene: scene)
    }
}
