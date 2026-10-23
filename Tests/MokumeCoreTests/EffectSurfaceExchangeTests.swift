// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 効果を通すフレームが、描く先と効果の控えの面を**取り替える**ことの帰結 ([#2388])。
///
/// 描き場所の面は、効果を通すと別のテクスチャへ入れ替わる。「描き場所の面は、描き場所が生きている間ずっと
/// 同じテクスチャ」という約束に頼っていた側 — 面を溜める側 (保持した形・貼った塗り)・常駐の持ち主・出し直しの
/// 印・戻しの待ち・打ち切られた投入の取り消し — が、入れ替わった後も正しいことを見る。
///
/// [#2388]: https://github.com/mokume-metal/mokume/issues/2388
@Suite(
    "効果の面の取り替えと、面を持ち歩く側",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectSurfaceExchangeTests {
    private static let darkening: [Effect] = [.vignette(amount: 0.6)]
    private static let victim = DroppedWorkReadersTests.victim

    /// 隅が中央より明らかに暗い = 周辺減光を通した絵。
    private static func isVignetted(_ pixels: PixelBuffer) -> Bool {
        let corner = pixels[2, 2]
        let centre = pixels[pixels.width / 2, pixels.height / 2]
        return corner.red < centre.red * 0.8
    }

    /// 積んである投入の結末がすべて届くまで待つ。
    private func awaitOutcomes(_ gpu: RenderDevice) {
        _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
    }

    private static func same(_ a: any MTLTexture, _ b: any MTLTexture) -> Bool {
        (a as AnyObject) === (b as AnyObject)
    }

    // MARK: - 面を溜める側が、いまの面を読む (反証 1)

    /// 保持した形が `texture(描き場所)` を貼り、描き場所が効果を使うとき、形は**効果を通した絵**を毎フレーム
    /// 出す。組んだ時点の面を値で持ち歩くと、取り替えの後は効果を通す前の絵と通した絵を交互に出し (毎フレーム
    /// 塗り直すとき)、塗り直さないなら効果を通す前の絵しか出さなかった。
    @Test("描き場所の面を貼った保持した形は、効果を通した絵を毎フレーム出す", arguments: [true, false])
    func aRetainedShapeShowsTheEffectPicture(repaints: Bool) throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let layer = try host.createGraphics(64, 64)
        var shape = Shape.empty

        func layerFrame(_ first: Bool) {
            layer.beginDraw()
            if repaints || first { layer.background(235) } else { layer.circle(6, 6, 4) }
            layer.effects(Self.darkening)
            layer.endDraw()
        }

        // **形は、描き場所が効果を通す前に組む** (組んだ時点の面が、のちに取り替わる側の面になる)
        try host.draw {
            host.noStroke()
            shape = host.createShape {
                host.texture(layer)
                host.rect(0, 0, 64, 64)
            }
            host.noTexture()
        }
        layerFrame(true)
        try host.draw { host.shape(shape) }
        #expect(Self.isVignetted(try host.output.readPixels()), "1 枚目が効果を通した絵でない")

        for frame in 1...4 {
            layerFrame(false)
            try host.draw { host.shape(shape) }
            #expect(
                Self.isVignetted(try host.output.readPixels()),
                "\(frame) 枚目の形が、効果を通した絵でない (取り替えた後の面を読んでいない)")
        }
        // 描き場所が何も描かないフレームの後も、形は最後に効果を通した絵を出す
        try host.draw { host.shape(shape) }
        #expect(Self.isVignetted(try host.output.readPixels()), "描き場所が止まった後の形が、効果を通した絵でない")
    }

    /// 断片へ渡した面 (`surfaces`) も、同じ約束で読む。
    @Test("描き場所の面を断片へ渡した保持した形は、効果を通した絵を毎フレーム出す")
    func aRetainedPaintShowsTheEffectPicture() throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let layer = try host.createGraphics(64, 64)
        let shader = try host.makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.body, in.place);
            }
            """,
            surfaces: ["body": .graphics(layer)])
        var shape = Shape.empty

        func layerFrame() {
            layer.beginDraw()
            layer.background(235)
            layer.effects(Self.darkening)
            layer.endDraw()
        }
        try host.draw {
            host.noStroke()
            shape = host.createShape {
                host.shader(shader)
                host.rect(0, 0, 64, 64)
                host.resetShader()
            }
        }
        layerFrame()
        try host.draw { host.shape(shape) }
        #expect(Self.isVignetted(try host.output.readPixels()), "1 枚目が効果を通した絵でない")
        for frame in 1...3 {
            layerFrame()
            try host.draw { host.shape(shape) }
            #expect(
                Self.isVignetted(try host.output.readPixels()),
                "\(frame) 枚目の断片の面が、効果を通した絵でない")
        }
    }

    // MARK: - 取り替えた後の面も、持ち主が生きている間は常駐する (反証 2)

    /// 描き場所の効果を通すフレームを何回か済ませてから手放しても、それを置いた投入が終わるまで、**2 枚の面の
    /// どちらも**常駐に残る。組んだ時点の面の持ち主 (描き場所) だけが残り、取り替えの相手 (控え) が先に死んで
    /// 面を退かせると、形は常駐から外れた面を読む ([#1079]・[#1178] と同じ型)。
    ///
    /// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
    /// [#1178]: https://github.com/mokume-metal/mokume/issues/1178
    @Test("効果を通した描き場所を手放しても、置いた投入が終わるまで 2 枚の面が常駐に残る", arguments: [1, 2])
    func bothSurfacesStayResidentUntilTheReaderFinishes(effectFrames: Int) throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        var faces: [any MTLTexture] = []
        var failure: (any Error)?

        try host.draw {
            do {
                let graphics = try host.createGraphics(16, 16)
                for _ in 0..<effectFrames {
                    try graphics.draw {
                        graphics.background(235)
                        graphics.effects(Self.darkening)
                    }
                }
                let carry = try #require(graphics.effectPipelineStorage?.existingCarry)
                faces = [graphics.output.texture, carry.texture]
                // 描き場所自身の投入を、手放す前に終わらせる。刈りが描き場所の番を確実に過ぎる
                try gpu.settle()
                host.image(graphics, 0, 0)
            } catch {
                failure = error
            }
        }
        try #require(failure == nil)
        try #require(faces.count == 2)
        try #require(!Self.same(faces[0], faces[1]))

        for (index, face) in faces.enumerated() {
            #expect(
                gpu.residencySet.containsAllocation(face),
                "\(index) 枚目の面が、置いた投入が終わる前に常駐から外れた (取り替えの相手を抱えていない)")
        }
        try gpu.settle()
        for (index, face) in faces.enumerated() {
            #expect(!gpu.residencySet.containsAllocation(face), "\(index) 枚目の面が、読み終えた後も常駐に残っている")
        }
        #expect(gpu.retiredResourceCount == 0)
    }

    // MARK: - 戻しの取り替えの後の待ち (反証 3)

    /// 止まっている間に書いた画素を控えへ重ねた (``Canvas/encodeKeepChanged(into:)``) 後、次のフレームの頭が
    /// 控えと描く先を取り替える。取り替えた後の描く先は、重ね段が書いた面なので、描く先へのパスはその書き込みが
    /// 終わるのを待つ。待たなければ、書いた画素が次のフレームの入りから欠ける。写していた頃は、戻しの blit が待っていた。
    @Test("止まっている間に画素を書いたなら、次のフレームの描く先へのパスは重ね段の書き込みを待ち、画素は残る")
    func theNextFrameWaitsForTheKeptPixels() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 160, height: 160)
        try canvas.draw {
            canvas.background(235)
            canvas.effects(Self.darkening)
        }
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)

        // 書かずに次のフレームへ進むなら、待ちは積まない (戻すだけの取り替えは何も積まない)
        try canvas.draw {}
        #expect(canvas.effectRestoreBarriersEncoded == 0, "書いていないのに待ちを積んだ")

        try canvas.draw {
            canvas.background(235)
            canvas.effects(Self.darkening)
        }
        canvas.carriesOver = true
        canvas.set(80, 80, red)
        canvas.carriesOver = false
        try canvas.draw {}
        #expect(canvas.effectRestoreBarriersEncoded == 1, "重ね段の書き込みを待つ仕掛けを積んでいない")
        let pixels = try canvas.output.readPixels()
        let kept = pixels[80, 80]
        #expect(kept.red > 0.99 && kept.green < 0.01 && kept.blue < 0.01, "書いた画素が次のフレームへ残っていない")
    }

    // MARK: - 打ち切られた投入の取り消し (反証 4・5)

    /// 塗り直さないフレーム (頭の戻しと最後の段の 2 回の取り替えを含む) が打ち切られたら、面は投入の前の姿に
    /// 戻り、描く先は前のフレームの効果を通した絵のままである (2 回の取り替えは面の割り当てを元に戻している)。
    /// 1 回だけ戻すと、描く先が効果を通す前の絵になり、窓は前の絵を出し続けるのに、読む画素・書き出しは
    /// 効果を通していない絵を返す。
    @Test("塗り直さないフレームが打ち切られても、描く先は前の効果を通した絵の面のままで、印も戻る", arguments: [true, false])
    func aDroppedFlushThatRestoredLeavesTheSurfacesAsTheyWere(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try canvas.draw {
            canvas.background(LinearRGBA.linear(red: 0, green: 0, blue: 1))
            canvas.effects(Self.darkening)
        }
        let shown = canvas.target.texture
        let carry = try #require(canvas.effectPipelineStorage?.existingCarry)
        let beforeEffects = carry.texture
        #expect(canvas.carriesPictureBeforeEffects, "前提が崩れている")

        // 塗り直さずに描き足して、もう一度効果を通す。この描き切りが頭で戻し、最後の段で取り替える
        try canvas.draw {
            canvas.circle(8, 8, 4)
            canvas.effects(Self.darkening)
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        #expect(canvas.effectRestoresExchanged == 1, "前提が崩れている (戻していない)")
        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()

        let carryNow = try #require(canvas.effectPipelineStorage?.existingCarry)
        #expect(Self.same(canvas.target.texture, shown), "描く先が、前の効果を通した絵の面でなくなった")
        #expect(Self.same(carryNow.texture, beforeEffects), "控えが、効果を通す前の絵の面でなくなった")
        #expect(canvas.carriesPictureBeforeEffects, "控えを戻す印が下りた (次のフレームは控えから戻せる)")
    }

    /// 打ち切られたら、持ち替えた面の中身が変わったと名乗る。止まっているスケッチの窓は、出し直しの印
    /// (``RenderTarget/contentRevision``) が変わらなければ出し直しを飛ばし、取り替えが戻った絵を出さない。
    @Test("打ち切られた投入の取り替えを戻すと、出し直しの印が進む。打ち切りが無ければ進まない", arguments: [true, false])
    func revertingAnExchangeBumpsTheContentRevision(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try canvas.draw {
            canvas.background(LinearRGBA.linear(red: 0, green: 0, blue: 1))
            canvas.effects(Self.darkening)
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        let before = canvas.output.contentRevision
        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        #expect((canvas.output.contentRevision != before) == dropped, "出し直しの印の進み方が違う")
    }

    // MARK: - 結末の前に次のフレームが戻した (2 回目の反証 1)

    /// 塗り直した効果のフレーム S が打ち切られ、その結末が届く前に次のフレーム S' の頭が戻すと、記帳は S' に
    /// 上書きされて取り消せない。**名乗って受け入れる代償** (メンテナの判断 2026-10-23) なので、結末が届いたとき、
    /// 戻された後の打ち切りだと見つけて 1 度だけ知らせる。順番は、結末の照会を止めて S' を組んで作る。
    @Test("結末が届く前に次のフレームが戻していたら、打ち切りの結末で効果が焼き込まれたかもしれないと 1 度知らせる",
        arguments: [true, false])
    func aDropAfterTheNextFrameRestoredIsAnnounced(restoredBefore: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        // 結末の前に S' を組むなら照会を止めて描く。そうでなければ、S の結末を受けてから S' を組む
        if restoredBefore { gpu.holdRevocations() }
        try canvas.draw {
            canvas.background(LinearRGBA.linear(red: 0, green: 0, blue: 1))
            canvas.effects(Self.darkening)
            gpu.dropsNextSubmissionForTesting = Self.victim
        }
        if !restoredBefore {
            awaitOutcomes(gpu)
            gpu.revokeDroppedDeliveries()
        }
        // S' — 塗り直さず、印を見て戻す
        try canvas.draw { canvas.circle(8, 8, 4) }
        // 結末の前に組んだ S' は印だけを見て戻す。結末を受けた後の S' は、印が下りているので戻さない
        #expect(canvas.effectRestoresExchanged == (restoredBefore ? 1 : 0), "前提が崩れている")
        if restoredBefore { gpu.releaseRevocations() }
        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()

        #expect(canvas.warnings.hasWarned(.effectBakedAfterDrop) == restoredBefore)
        #expect(canvas.carriedAwaitingOutcome.isEmpty, "結末が届いたのに覚えが残っている")
    }

    /// 打ち切りの取り消しは、描き切りの外で出す先の面を取り替える口である (#1942 の登録簿)。置いた側が
    /// 溜めている間に取り消すなら、取り替える前に置いた時点の絵を写させる。
    @Test("打ち切りの取り消しが面を取り替えるときは、置いた側に変わる前の絵を写させる")
    func theRevertGivesPlacersThePictureBeforeTheChange() throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let layer = try host.createGraphics(16, 16)
        gpu.holdRevocations()
        layer.beginDraw()
        layer.background(LinearRGBA.linear(red: 0, green: 0, blue: 1))
        layer.effects(Self.darkening)
        gpu.dropsNextSubmissionForTesting = Self.victim
        layer.endDraw()
        let copied = host.placedPicturesCopied
        let exchanged = layer.target.texture
        try host.draw {
            host.image(layer, 0, 0)
            #expect(!layer.output.drawer!.placers.isEmpty, "置いた記録が無い — 前提が崩れている")
            gpu.releaseRevocations()
            awaitOutcomes(gpu)
            gpu.revokeDroppedDeliveries()
            #expect(!Self.same(layer.target.texture, exchanged), "取り替えを戻していない — 前提が崩れている")
            #expect(host.placedPicturesCopied == copied + 1, "置いた側に、変わる前の絵を写させていない")
        }
    }

    // MARK: - 最初の効果を通すフレームの出す面 (反証 6)

    /// 出す面は、頼まれた時点 (``Canvas/effects(_:)``) で塗って作る。書かれる前に読まれても (最初の効果を通す
    /// フレームが打ち切られ、取り替えが戻るまでの間) 透明な黒で、未定義ではない。塗るのは自分の投入を 1 本
    /// 積むので組み立ての最中にはできず、頼んだ手前で 1 度だけ払う。
    @Test("効果を頼んだ時点で、出す面を塗って 1 度だけ作る")
    func theOutputSurfaceIsMadeClearedWhenEffectsAreAsked() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        #expect(canvas.effectPipelineStorage?.existingCarry == nil)
        let submissions = gpu.submissionCount

        try canvas.draw {
            canvas.effects(Self.darkening)
            #expect(gpu.submissionCount == submissions + 1, "出す面を塗って作る投入を 1 本積んでいない")
            canvas.effects(Self.darkening)
            #expect(gpu.submissionCount == submissions + 1, "2 度目の依頼で、また塗った")
        }
        let carry = try #require(canvas.effectPipelineStorage?.existingCarry)
        #expect(canvas.effectPipelineStorage?.carriesBuilt == 1)
        // 書かれる前の中身は透明な黒
        let sample = try Self.bytes(of: carry.texture, gpu: gpu)
        #expect(sample.allSatisfy { $0 == 0 }, "出す面が透明な黒でない")
    }

    @Test("効果を頼まなければ、出す面を作らず何も払わない")
    func noEffectsNoOutputSurface() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let submissions = gpu.submissionCount
        try canvas.draw {
            canvas.effects([])
            canvas.background(235)
        }
        #expect(canvas.effectPipelineStorage?.existingCarry == nil)
        #expect(gpu.submissionCount == submissions + 1, "効果を頼まないのに投入が増えた")
    }

    /// GPU 専用の面の中身を、読める置き場へ写して返す。
    private static func bytes(of texture: any MTLTexture, gpu: RenderDevice) throws -> [UInt8] {
        try gpu.settle()
        let bytesPerRow = texture.width * RenderTarget.bytesPerPixel
        let length = bytesPerRow * texture.height
        let buffer = try gpu.makeReadableBuffer(byteCount: length)
        defer { gpu.retire(buffer) }
        try gpu.withCommands { commands throws(RenderFailure) in
            guard let encoder = commands.makeComputeCommandEncoder() else {
                throw .encoderUnavailable
            }
            encoder.copy(
                sourceTexture: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                destinationBuffer: buffer, destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: 0)
            encoder.endEncoding()
            try gpu.commitAndWait(commands)
        }
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt8.self, capacity: length), count: length))
    }
}
