// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// GPU が打ち切った投入が届けたはずの中身を、結末が届いた後の最初の描き切りが届け直す
/// ([#2199](https://github.com/mokume-metal/mokume/issues/2199))。
///
/// 投入の後に「届いた・焼けた・書き戻した・拡大した」と記す記帳は結末を見ずに進むので、打ち切られると
/// 後のフレームは届いていない中身を届いたものとして使い続けた。取り戻すのは CPU の側に正本がある
/// もの — 画像と数の並びへの書き込み・影の焼き付けの指紋・書いた画素の書き戻し・拡大の追い付き。
///
/// **打ち切りは GPU を止めずに作る** ([#1065] の完了条件 4)。`dropsNextSubmissionForTesting` は結末の
/// 記録だけを打ち切りにし、GPU の仕事は普通に走る。だから絵は変わらず、見るのは届け直し・焼き直し・
/// 書き戻し直し・拡大し直しの回数である。**結末が届くのを待ってから次の描き切りを呼ぶ**
/// (``awaitOutcomes(_:)``)。どの検査も打ち切りの有無の 2 通りで回し、無い側では何もやり直さない
/// ことを見る。
///
/// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
@Suite(
    "打ち切られた投入の届け直し",
    .serialized,
    .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct DroppedWorkRedeliveryTests {
    static let victim = DroppedWorkReadersTests.victim
    static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    static let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    /// 積んである投入の結末がすべて届くまで待つ。
    private func awaitOutcomes(_ gpu: RenderDevice) {
        _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
    }

    /// 打ち切りの有無で、取り消した数が揃っているか。無ければ 0。
    private func expectRevoked(_ gpu: RenderDevice, dropped: Bool) {
        if dropped {
            #expect(gpu.droppedDeliveriesRevoked > 0, "打ち切られた投入の記帳を取り消していない")
        } else {
            #expect(gpu.droppedDeliveriesRevoked == 0, "打ち切りが無いのに記帳を取り消した")
        }
    }

    // MARK: - 画像 (完了条件 1)

    @Test("画像を届けた投入が打ち切られると、結末が届いた後の描き切りが届け直す。無ければ届け直さない",
        arguments: [true, false])
    func anImageWhoseUploadWasDroppedIsSentAgain(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let image = try canvas.createImage(8, 8)
        image.fill(Self.red)
        try canvas.draw {
            canvas.image(image, 0, 0)
            // 次の投入は、このフレームの終わりの描き切り (画像を届ける)
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        #expect(image.pendingUploadByteCount == 0, "届けた記帳が下りていない — 前提が崩れている")

        awaitOutcomes(gpu)
        // 描き切りの頭と同じ照会。届け直す前の控えを見る
        gpu.revokeDroppedDeliveries()
        #expect((image.pendingUploadByteCount > 0) == dropped, "控え: \(image.pendingUploadByteCount)")

        let barriers = canvas.uploadBarriersEncoded
        try canvas.draw { canvas.image(image, 0, 0) }
        #expect(canvas.uploadBarriersEncoded - barriers == (dropped ? 1 : 0), "届け直した回数が違う")
        #expect(image.pendingUploadByteCount == 0, "届け直した後も控えが残っている")
        expectRevoked(gpu, dropped: dropped)
    }

    // MARK: - 数の並び (完了条件 2)

    /// 区間を書いて届けた投入の経路。
    enum Delivery: CaseIterable, CustomTestStringConvertible {
        /// フレームの終わりの描き切り。
        case frame
        /// 計算と控えの早い投入 (`read(_:)` が流す)。
        case early

        var testDescription: String {
            switch self {
            case .frame: "描き切り"
            case .early: "早い投入"
            }
        }
    }

    @Test("数の並びの区間を届けた投入が打ち切られると、その区間だけを届け直す。無ければ届け直さない",
        arguments: Delivery.allCases, [true, false])
    func aNumberRangeWhoseUploadWasDroppedIsSentAgain(delivery: Delivery, dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let numbers = try canvas.makeNumbers(count: 64)
        for index in 10..<20 { numbers.set(Float(index), at: index) }
        let range = 10 * MemoryLayout<Float>.stride
        #expect(numbers.pendingUploadByteCount == range)

        switch delivery {
        case .frame:
            try canvas.draw {
                if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
            }
        case .early:
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
            #expect(canvas.read(numbers)[10...19] == ArraySlice((10..<20).map(Float.init)))
        }
        #expect(numbers.pendingUploadByteCount == 0, "届けた記帳が下りていない — 前提が崩れている")

        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        // 区間の外 (計算が書き換えうる) は届けない
        #expect(numbers.pendingUploadByteCount == (dropped ? range : 0), "控え: \(numbers.pendingUploadByteCount)")

        try canvas.draw {}
        #expect(numbers.pendingUploadByteCount == 0, "届け直した後も控えが残っている")
        expectRevoked(gpu, dropped: dropped)
    }

    /// 数の並びを読む口 (`read(_:)`) は描き切りを通らない。流すものがあるかを見る前に打ち切りを照らさない
    /// と、届け直す控えが登録簿に無いまま読んで返る。
    @Test("早い投入が打ち切られた後に数の並びを読むと、読む前に区間を届け直す。無ければ届けない",
        arguments: [true, false])
    func readingNumbersSendsADroppedRangeAgainFirst(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let numbers = try canvas.makeNumbers(count: 64)
        for index in 10..<20 { numbers.set(Float(index), at: index) }
        if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        _ = canvas.read(numbers)

        awaitOutcomes(gpu)
        let barriers = canvas.uploadBarriersEncoded
        #expect(canvas.read(numbers)[10...19] == ArraySlice((10..<20).map(Float.init)))
        #expect(canvas.uploadBarriersEncoded - barriers == (dropped ? 1 : 0), "届け直した回数が違う")
        #expect(numbers.pendingUploadByteCount == 0)
        expectRevoked(gpu, dropped: dropped)
    }

    static let stamp = """
        kernel void stamp(device float *out [[buffer(0)]],
                          constant Values &values [[buffer(MOKUME_VALUES)]],
                          uint id [[thread_position_in_grid]])
        {
            out[id] = values.amount;
        }
        """

    /// **打ち切りの後に計算がその並びへ書いていれば、届け直さない** (#2199 の反証 4)。届け直しは CPU が
    /// 最後に書いた値へ戻すので、計算が進めた中身 (粒なら進めた位置) を潰す。
    ///
    /// 描き切りは頭で照会するので、「結末が届く前に計算が書いた」を描き切りでは決定的に作れない。照会を
    /// 止めて (`holdRevocations()`) 計算を流してから、止めを戻して照会する。
    @Test("数の並びを届けた投入が打ち切られても、その後に計算がその並びへ書いていれば届け直さない",
        arguments: [true, false])
    func aNumberRangeWrittenByALaterComputationIsNotSentAgain(computedAfter: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let numbers = try canvas.makeNumbers(count: 64)
        let stamp = try canvas.makeComputation(Self.stamp, name: "stamp", values: ["amount": 7])
        for index in 10..<20 { numbers.set(Float(index), at: index) }
        try canvas.draw { gpu.dropsNextSubmissionForTesting = Self.victim }

        gpu.holdRevocations()
        if computedAfter {
            try canvas.draw { canvas.compute(stamp, over: 64, writes: [numbers]) }
        } else {
            try canvas.draw {}
        }
        gpu.releaseRevocations()
        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        let range = 10 * MemoryLayout<Float>.stride
        #expect(numbers.pendingUploadByteCount == (computedAfter ? 0 : range), "控え: \(numbers.pendingUploadByteCount)")
        if computedAfter { #expect(canvas.read(numbers)[15] == 7, "計算の結果を潰した") }
    }

    /// **結末を失っただけの投入では取り消さない** (#2199 の反証 5)。知らせが失われただけで仕事は走って
    /// いたかもしれず、取り消すと正しく届いた中身を CPU の値で潰す。
    @Test("結末の知らせを失った投入は、届け直しの対象にせず、預けも残さない")
    func aLostOutcomeIsNotRevoked() throws {
        let gpu = try RenderDevice()
        gpu.outcomeWaitLimit = .milliseconds(100)
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let numbers = try canvas.makeNumbers(count: 64)
        for index in 10..<20 { numbers.set(Float(index), at: index) }
        try canvas.draw { gpu.losesNextOutcomeForTesting = true }

        // 投げる読む口と同じ待ちで、失われた結末を打ち切りとして記させる
        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        #expect(numbers.pendingUploadByteCount == 0, "結末を失った投入の区間を届け直した")
        #expect(gpu.droppedDeliveriesRevoked == 0)
        #expect(gpu.pendingRevocationCount == 0, "結末を失った投入の預けが残っている")
    }

    // MARK: - 影 (完了条件 3)

    /// 床と球の影の場面を組む (描き切らない)。`offset` で球をずらす。
    private func drawScene(_ canvas: Canvas, offset: Float = 0) {
        canvas.background(.linear(red: 0, green: 0, blue: 0))
        canvas.camera(32, -12, 85, 32, 7, 0, 0, 1, 0)
        canvas.perspective(Float.pi / 3, 1, 1, 250)
        canvas.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
        canvas.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.6, 0.6, -0.5)
        canvas.shadows(true)
        canvas.noStroke()
        canvas.castShadow(false)
        canvas.push()
        canvas.translate(32, 20, -10)
        canvas.box(95, 4, 95)
        canvas.pop()
        sphere(canvas, offset: offset)
    }

    private func sphere(_ canvas: Canvas, offset: Float) {
        canvas.castShadow(true)
        canvas.push()
        canvas.translate(32 + offset, 4, 0)
        canvas.sphere(14)
        canvas.pop()
    }

    @Test("影を焼いた投入が打ち切られると、同じ入力の次のフレームは使い回さずに焼き直す。無ければ使い回す",
        arguments: [true, false])
    func aShadowWhoseBakeWasDroppedIsBakedAgain(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        try canvas.draw {
            drawScene(canvas)
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        #expect(canvas.shadowBakesEncoded == 1, "1 枚目で焼いていない — 前提が崩れている")

        awaitOutcomes(gpu)
        let reused = canvas.shadowBakesReused
        try canvas.draw { drawScene(canvas) }
        #expect(canvas.shadowBakesReused - reused == (dropped ? 0 : 1), "使い回した回数が違う")
        #expect(canvas.shadowBakesEncoded == (dropped ? 2 : 1), "焼いた回数: \(canvas.shadowBakesEncoded)")
        expectRevoked(gpu, dropped: dropped)
    }

    @Test("区切りで影を焼いた投入が打ち切られると、フレームの終わりはその面に足さずに全部から焼く。無ければ足す",
        arguments: [true, false])
    func aShadowAddedOntoADroppedBakeIsBakedWhole(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        try canvas.draw {
            drawScene(canvas, offset: -12)
            // 区切りの描き切りが、ここまでの落とす列を焼く
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
            _ = canvas.get(4, 4)
            awaitOutcomes(gpu)
            // この回の列を足す。フレームの終わりは、区切りで焼いた面に足して焼くかを選ぶ
            sphere(canvas, offset: 12)
        }
        #expect(canvas.shadowBakesEncoded == 2, "焼いた回数: \(canvas.shadowBakesEncoded) — 前提が崩れている")
        #expect(canvas.shadowBakesAdded == (dropped ? 0 : 1), "足して焼いた回数: \(canvas.shadowBakesAdded)")
        expectRevoked(gpu, dropped: dropped)
    }

    // MARK: - 書き戻し (完了条件 4)

    /// 前のフレームを赤で塗り、写しを作ってから、このフレームで (4, 4) に青を書いて書き戻す。
    private func writeBlue(_ canvas: Canvas, dropped: Bool) throws {
        try canvas.draw { canvas.background(Self.red) }
        _ = try canvas.output.readPixels()
        try canvas.draw {
            canvas.set(4, 4, Self.blue)
            // 次の投入は、このフレームの終わりの描き切り (書いた画素の書き戻し)
            if dropped { canvas.gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        #expect(!canvas.output.hasPendingPixelWrites, "書き戻した記帳が下りていない — 前提が崩れている")
    }

    /// (4, 4) には触れずに描き足す。この面へ触る描き切り。
    private func drawElsewhere(_ canvas: Canvas) throws {
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(Self.blue)
            canvas.rect(12, 12, 2, 2)
        }
    }

    @Test("書いた画素の書き戻しが打ち切られると、投げる読む口を呼ばなくても次の描き切りが書き戻し直す。無ければ書き戻さない",
        arguments: [true, false])
    func pixelsWhoseWriteBackWasDroppedAreWrittenBackWithoutAThrowingRead(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try writeBlue(canvas, dropped: dropped)

        awaitOutcomes(gpu)
        let writeBacks = canvas.output.pixelWriteBacksEncoded
        try drawElsewhere(canvas)
        #expect(canvas.output.pixelWriteBacksEncoded - writeBacks == (dropped ? 1 : 0), "書き戻し直した回数が違う")
        try drawElsewhere(canvas)
        #expect(canvas.output.pixelWriteBacksEncoded - writeBacks == (dropped ? 1 : 0), "2 度書き戻した")
        expectRevoked(gpu, dropped: dropped)
    }

    /// **打ち切りの後にこの面へ書いた投入があれば、書き戻しを立て直さない** (#2199 の反証 1)。書き戻しは
    /// 写しの全面を戻すので、立て直すと後から描いた絵を打ち切る前の絵へ巻き戻す。
    ///
    /// 描き切りは頭で取り消すので、「結末が届く前にこの面へ書いた」を描き切りでは決定的に作れない。
    /// この面へ書く投入を (中身の無いパスで) 直に積んでから、描き切りの頭と同じ照会を呼ぶ。
    @Test("書き戻しが打ち切られた後にこの面へ書く投入があれば、書き込み待ちを立て直さない (後の絵を巻き戻さない)",
        arguments: [true, false])
    func aWriteBackIsNotRebuiltOverLaterWrites(writtenAfter: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try writeBlue(canvas, dropped: true)
        awaitOutcomes(gpu)
        if writtenAfter {
            let pass = canvas.output.makeRenderPass(clearColor: nil)
            try gpu.withCommands { commands throws(RenderFailure) in
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                    throw .encoderUnavailable
                }
                encoder.endEncoding()
                gpu.commit(commands, writing: [canvas.output])
            }
        }
        gpu.revokeDroppedDeliveries()
        #expect(canvas.output.hasPendingPixelWrites == !writtenAfter, "書き込み待ちの立て直し方が違う")
    }

    /// 投げる読む口の立て直し (#1932) と土台の取り消しは、同じ 1 つの関数を通る。先に読む口が立て直し
    /// ても、後の描き切りの取り消しがもう 1 度立て直さない。
    @Test("投げる読む口が先に立て直した書き戻しを、描き切りの取り消しが二重に書き戻さない")
    func aWriteBackRebuiltByAThrowingReadIsNotWrittenBackTwice() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try writeBlue(canvas, dropped: true)
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try canvas.output.readPixels() }
        #expect(canvas.output.hasPendingPixelWrites, "読む口が書き込み待ちを立て直していない")

        let writeBacks = canvas.output.pixelWriteBacksEncoded
        try drawElsewhere(canvas)
        try drawElsewhere(canvas)
        #expect(canvas.output.pixelWriteBacksEncoded - writeBacks == 1, "書き戻した回数が 1 でない")
        let read = try canvas.output.readPixels()
        #expect(read[4, 4].blue == 1 && read[4, 4].red == 0, "書いた画素が失われた: \(read[4, 4])")
    }

    // MARK: - 読み戻しの「映した」(#2199 の反証 1)

    /// 投げない口 (`pixels`) が積んだ読み戻しが打ち切られると、写しは古いのに「映した」の印が付いた
    /// ままだった。止まっている間ずっと古い写しを返し、`set()` の書き戻しは古い写しの全面で面を壊す。
    @Test("投げない口の読み戻しが打ち切られると、次の読みが映し直す。無ければ映し直さない",
        arguments: [true, false])
    func aDroppedReadbackOfANonThrowingReadIsReadAgain(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try canvas.draw { canvas.background(Self.blue) }
        if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        _ = canvas.output.pixels

        awaitOutcomes(gpu)
        let readbacks = canvas.output.pixelReadbacksEncoded
        let read = canvas.output.pixels[4, 4]
        #expect(canvas.output.pixelReadbacksEncoded - readbacks == (dropped ? 1 : 0), "映し直した回数が違う")
        #expect(read.blue == 1 && read.red == 0)
    }

    // MARK: - 作ったときの塗り (#2199 の反証 2)

    @Test("面を作るときの塗りが打ち切られると、後に書く投入が無ければ塗り直す。書いていれば塗らない。無ければ塗らない",
        arguments: ["打ち切り", "打ち切りの後に書く", "打ち切りなし"])
    func aDroppedClearOfANewSurfaceIsRepeated(kind: String) throws {
        let gpu = try RenderDevice()
        if kind != "打ち切りなし" { gpu.dropsNextSubmissionForTesting = Self.victim }
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        if kind == "打ち切りの後に書く" {
            let pass = target.makeRenderPass(clearColor: Self.red)
            try gpu.withCommands { commands throws(RenderFailure) in
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                    throw .encoderUnavailable
                }
                encoder.endEncoding()
                gpu.commit(commands, writing: [target])
            }
        }
        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        #expect(target.surfaceClearsRepeated == (kind == "打ち切り" ? 1 : 0), "塗り直した回数が違う")
    }

    // MARK: - 3 回目の反証 (C)

    /// 大きな入力は、復号した後の編集だけを届けることがある。復号を届けた投入が打ち切られたのに、
    /// 後の編集だけの届けを「全体を届けた最後の投入」と覚えると、復号は次に書くまで面に届かない (C1)。
    @Test("大きな入力の復号を届けた投入が打ち切られると、後に編集だけを届けていても復号から届け直す。無ければ届け直さない",
        arguments: [true, false])
    func aDroppedDecodeIsSentAgainAfterAnEditOnlyUpload(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let side = 1024
        let image = try canvas.createImage(side, side)
        image.write(DisplayImage(width: side, height: side, bytes: Array(repeating: 127, count: side * side * 4)))
        try canvas.draw {
            canvas.image(image, 0, 0, 16, 16)
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        #expect(image.displayInput != nil, "大きな入力の経路を通っていない — 前提が崩れている")

        // 編集だけを届ける。結末が届く前に照会されないよう、照会を止めて描く
        gpu.holdRevocations()
        image.set(0, 0, Self.red)
        try canvas.draw { canvas.image(image, 0, 0, 16, 16) }
        gpu.releaseRevocations()
        #expect(!image.needsUpload, "編集を届けていない — 前提が崩れている")

        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        #expect(image.needsUpload == dropped, "届け直す旗の立ち方が違う")
        #expect(image.inputNeedsDecode == dropped, "復号から届け直していない")
    }

    /// 効果を通した絵を出す面へ書いた投入が打ち切られると、出す面は書かれていない (初めてなら中身が無い)。
    /// 印が立ったままだと、次のフレームの最初の描き切りが、書かれていない面を描く先へ戻す (C2)。
    /// 初めての効果を通すフレームなので、投入の前も印は立っていない — 戻した後も下りている。
    @Test("効果を通した絵を書いた投入が打ち切られると、控えを戻す印を投入の前に戻す。無ければ戻さない",
        arguments: [true, false])
    func aDroppedCarryIsNotRestored(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try canvas.draw {
            canvas.background(Self.blue)
            canvas.effects([.vignette(amount: 0.6)])
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        #expect(canvas.carriesPictureBeforeEffects, "効果を通した絵を出す面へ書いていない — 前提が崩れている")

        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        #expect(canvas.carriesPictureBeforeEffects == !dropped, "控えを戻す印の扱いが違う")
    }

    /// 効果を通した絵を出す面へ書いた投入が打ち切られると、出す面は書かれていない。面を取り替えたままだと、
    /// 次のフレームの入りが書かれていない面になる (#2388)。取り替えを戻せば、効果を通す前の絵が描く先に残る。
    @Test("効果を通した絵を書いた投入が打ち切られると、面の取り替えを戻す。無ければ戻さない",
        arguments: [true, false])
    func aDroppedEffectFrameGivesTheSurfacesBack(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let drawn = canvas.target.texture
        try canvas.draw {
            canvas.background(Self.blue)
            canvas.effects([.vignette(amount: 0.6)])
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        #expect(!Self.same(canvas.target.texture, drawn), "面を取り替えていない — 前提が崩れている")

        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        let given = Self.same(canvas.target.texture, drawn)
        #expect(given == dropped, "面の取り替えの扱いが違う")
    }

    private static func same(_ a: any MTLTexture, _ b: any MTLTexture) -> Bool {
        (a as AnyObject) === (b as AnyObject)
    }

    /// 届けるものが無い描き切りでも、登録簿から届け終えた持ち主を降ろす (C6)。逃げ道で直接書いた
    /// 持ち主は、空でない届けが来るまで載ったままだった。
    @Test("届けるものが無い描き切りでも、直接書いて届け終えた持ち主を登録簿から降ろす")
    func finishedOwnersLeaveTheRegistryOnAnEmptyFlush() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let numbers = try canvas.makeNumbers(count: 64)
        numbers.dirtyRangeLimit = 0
        numbers.set(1, at: 3)
        #expect(numbers.directUploads == 1, "直接書いていない — 前提が崩れている")
        #expect(numbers.isQueuedForUpload)
        try canvas.draw {}
        #expect(!numbers.isQueuedForUpload, "届け終えた持ち主が登録簿に残っている")
    }

    /// 完了の知らせは、結末を記してから積む (C8)。知らせの照会だけで、描き切りを挟まずに取り消しが
    /// 届く。頭で照会しない口 (止まっている間の追い付き・出す先を読む口) は、これに頼る。
    @Test("描き切りを挟まなくても、完了の知らせが打ち切られた投入の記帳を取り消す")
    func theCompletionNoticeRevokesWithoutAnotherFlush() async throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try writeBlue(canvas, dropped: true)
        awaitOutcomes(gpu)
        // 知らせは main actor で走る。譲りながら、期限つきで待つ
        let deadline = ContinuousClock.now + .seconds(5)
        while !canvas.output.hasPendingPixelWrites, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(canvas.output.hasPendingPixelWrites, "知らせが取り消していない")
    }

    /// 作った面の塗りが打ち切られた後、塗られていない面を映した写しへ CPU が書いていたら、塗り直さない
    /// (C9)。塗り直しても、書き戻しが写しの全面 (塗られていない中身 + 書いた画素) で上書きする。
    @Test("作った面の塗りが打ち切られても、写しへ書いた画素が戻っていなければ塗り直さない。書いていなければ塗り直す",
        arguments: [true, false])
    func aDroppedClearIsNotRepeatedUnderPendingPixelWrites(written: Bool) throws {
        let gpu = try RenderDevice()
        gpu.dropsNextSubmissionForTesting = Self.victim
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        gpu.holdRevocations()
        var window = target.pixels
        if written { window[1, 1] = Self.red }
        gpu.releaseRevocations()
        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        #expect(target.surfaceClearsRepeated == (written ? 0 : 1), "塗り直した回数が違う")
        if !written {
            #expect(target.pixelMirror?.syncedThrough == 0, "塗り直した後も写しを映したままにしている")
        }
    }

    /// 粒を進めた投入が打ち切られると、GPU の寿命は減っていない。CPU の累計を戻さないと、生きている粒の
    /// 上書きを注意しなくなる (C3)。
    @Test("粒を進めた投入が打ち切られると、寿命の累計からその回の量を戻す。無ければ戻さない",
        arguments: [true, false])
    func aDroppedParticleAdvanceIsTakenBackFromTheLifeTotal(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let particles = try canvas.makeParticles(count: 16)
        let before = particles.consumed
        try canvas.draw {
            canvas.particles(particles)
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
        }
        let advanced = particles.consumed
        #expect(advanced > before, "粒を進めていない — 前提が崩れている")

        awaitOutcomes(gpu)
        gpu.revokeDroppedDeliveries()
        #expect(particles.consumed == (dropped ? before : advanced), "累計: \(particles.consumed)")
    }

    // MARK: - 照会の止め (#2199 の反証 7)

    /// 描き切りは頭で照会してから描く先を変えるかを数え、終わるまで照会を止める。入れ子の描き切りの頭が
    /// 照会すると、数えた後で書き込み待ちが立つ。
    @Test("照会を止めている間は取り消さず、止めを戻した後の照会で取り消す")
    func revocationsWaitWhileHeld() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try writeBlue(canvas, dropped: true)
        awaitOutcomes(gpu)
        gpu.holdRevocations()
        gpu.revokeDroppedDeliveries()
        #expect(!canvas.output.hasPendingPixelWrites, "止めている間に取り消した")
        gpu.releaseRevocations()
        gpu.revokeDroppedDeliveries()
        #expect(canvas.output.hasPendingPixelWrites, "止めを戻した後も取り消していない")
    }

    // MARK: - 拡大 (完了条件 5)

    /// 拡大を積む投入。
    enum Upscaling: CaseIterable, CustomTestStringConvertible {
        /// フレームの終わりの描き切り。
        case frameEnd
        /// 止まっている間に描く先を変えた後の、出す先を読む口の追い付き (``Canvas/catchUpOutput()``)。
        case catchUp

        var testDescription: String {
            switch self {
            case .frameEnd: "フレームの終わり"
            case .catchUp: "出す先を読む口の追い付き"
            }
        }
    }

    /// 拡大を積んだ投入を (打ち切りの有無を選んで) 投入し、結末が届いた後で描く先を変えない描き切りを
    /// 1 度通してから出す先を読む。読むのに積んだ投入の数を返す。
    private func readAfterUpscale(_ upscaling: Upscaling, dropped: Bool) throws -> UInt64 {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 32, height: 32)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        switch upscaling {
        case .frameEnd:
            try canvas.draw {
                canvas.background(Self.red)
                if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
            }
        case .catchUp:
            try canvas.draw { canvas.background(Self.blue) }
            // 止まっている間のコールバックを模す。塗って描き切らせ、描く先だけを変える (画素は書かない —
            // 書けば書き戻しの取り消しが同じ印を立てる)
            canvas.carriesOver = true
            canvas.background(Self.red)
            canvas.loadPixels()
            canvas.carriesOver = false
            #expect(canvas.targetChangedSinceUpscale, "描く先を変えていない — 前提が崩れている")
            if dropped { gpu.dropsNextSubmissionForTesting = Self.victim }
            _ = try canvas.output.encodeToImage().read()
        }
        #expect(!canvas.targetChangedSinceUpscale, "拡大を積めていない — 前提が崩れている")

        awaitOutcomes(gpu)
        // 描く先を変えない描き切り (読み戻しだけ)。頭で打ち切りを取り消す
        canvas.loadPixels()
        #expect(canvas.targetChangedSinceUpscale == dropped, "拡大の後に変わった印の立ち方が違う")

        let before = gpu.submissionCount
        let shown = try canvas.output.encodeToImage().read()
        #expect(shown[16, 16].red == 255)
        #expect(!canvas.targetChangedSinceUpscale, "出す先を読む口が追い付いていない")
        expectRevoked(gpu, dropped: dropped)
        return gpu.submissionCount - before
    }

    @Test("拡大を積んだ投入が打ち切られると、印が立ち直り、出す先を読む口の追い付きが拡大し直す。無ければ拡大し直さない",
        arguments: Upscaling.allCases)
    func aDroppedUpscaleIsCaughtUpAgain(upscaling: Upscaling) throws {
        let dropped = try readAfterUpscale(upscaling, dropped: true)
        let kept = try readAfterUpscale(upscaling, dropped: false)
        #expect(dropped == kept + 1, "読むのに積んだ投入: 打ち切りあり \(dropped)・なし \(kept)")
    }
}
