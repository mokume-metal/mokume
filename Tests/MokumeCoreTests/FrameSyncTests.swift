// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 描き切りが GPU の完了を待たなくなったことと、それでも壊れないことの検査。GPU を要する。
///
/// **GPU が速い機械でも決定的にする。** 待ちが要るかどうかは GPU が終わっているかで
/// 決まるので、「まだ終わっていない」を構造で作る — 数百万回まわる計算を同じフレームに
/// 積み、描き切りが返った時点で GPU が確実に走っているようにする。回転が短すぎれば
/// `#require` が「何も見ていない」と名乗って赤くなる。
///
/// [#727](https://github.com/mokume-metal/mokume/issues/727)
@Suite(
    "描き切りの待ち",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameSyncTests {
    /// GPU を数十 ms 以上占める計算。**1 本の糸が長い依存の鎖をたどる**ので、幅を
    /// 広げても速くならず、最適化で畳まれもしない。
    private static let spin = """
        kernel void spin(device float *out [[buffer(0)]],
                         uint id [[thread_position_in_grid]])
        {
            float acc = 0.5;
            for (uint i = 0; i < 6000000u; ++i) { acc = fma(acc, 1.0000001f, 0.25f); }
            out[id] = acc;
        }
        """

    private struct Bench {
        let gpu: RenderDevice
        let canvas: Canvas
        let scratch: Numbers
        let spin: Computation

        /// このフレームの描き切りに、GPU を占める計算を積む。**`draw` の中で呼ぶ。**
        func keepGPUBusy() {
            canvas.compute(spin, over: 1, writes: [scratch])
        }
    }

    private func makeBench(width: Int = 32, height: Int = 32) throws -> Bench {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        let canvas = try Canvas(target: target, gpu: gpu)
        let scratch = try canvas.makeNumbers(count: 1)
        let spin = try canvas.makeComputation(Self.spin, name: "spin")
        return Bench(gpu: gpu, canvas: canvas, scratch: scratch, spin: spin)
    }

    private let red = LinearRGBA.opaque(red: 1, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)

    @Test("描き切りは GPU の完了を待たずに返り、画素を読むときに待つ")
    func flushReturnsBeforeTheGPUFinishes() throws {
        let bench = try makeBench()
        let canvas = bench.canvas

        try canvas.draw {
            bench.keepGPUBusy()
            canvas.background(black)
            canvas.fill(red)
            canvas.rect(0, 0, 32, 32)
        }
        // **ここが本題。** 待っていたら GPU はもう終わっている
        try #require(!bench.gpu.isIdle, "描き切りが返った時点で GPU が終わっている — 回転が短いか、待っている")

        let pixels = try canvas.target.readPixels()
        #expect(bench.gpu.isIdle, "画素を読んだ後なのに GPU が終わっていない")
        try #require(bench.gpu.blockingWaits > 0, "一度も止まっていない — 読む前の待ちが効いていない")
        #expect(pixels[16, 16].red == 1)
        #expect(pixels[16, 16].green == 0)
    }

    @Test("数の並びへ書く口は、書く直前に待つ")
    func numbersWaitBeforeWriting() throws {
        let bench = try makeBench()
        let numbers = try bench.canvas.makeNumbers(count: 4)

        try bench.canvas.draw { bench.keepGPUBusy() }
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        let before = bench.gpu.settleCalls
        numbers.set(1, at: 0)
        #expect(bench.gpu.settleCalls == before + 1, "書く口が待ちを頼んでいない")
        #expect(bench.gpu.isIdle, "書いた時点で GPU が終わっていない")
    }

    @Test("計算の結果を読む口は、溜まりが空でも待つ")
    func readingNumbersWaitsEvenWithNothingPending() throws {
        let bench = try makeBench()

        try bench.canvas.draw { bench.keepGPUBusy() }
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        // 回転の結果は fma の鎖なので、1 つの値に収束している。0 (初期値) でなければ
        // 「終わってから読んだ」ことになる
        let values = bench.canvas.read(bench.scratch)
        #expect(bench.gpu.isIdle)
        #expect(values[0] != 0, "計算が終わる前の値を読んでいる")
    }

    @Test("画像を面へ送る口は、送る直前に待つ")
    func imageUploadWaitsBeforeReplacing() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        let image = try canvas.createImage(2, 2)

        try canvas.draw {
            bench.keepGPUBusy()
            canvas.image(image, 0, 0)
        }
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        // CPU 側を書き換える (面へはまだ送らない)
        image.set(0, 0, red)
        var idleWhenPlaced = false
        try canvas.draw {
            // 置く直前に面へ送る。その送りが待つ
            canvas.image(image, 0, 0)
            idleWhenPlaced = bench.gpu.isIdle
        }
        #expect(idleWhenPlaced, "面を書き換えた時点で、前のフレームの GPU が終わっていない")
    }

    @Test("字形を焼く口は、焼く直前に待つ")
    func glyphBakingWaitsBeforeReplacing() throws {
        let bench = try makeBench(width: 64, height: 64)
        let canvas = bench.canvas

        try canvas.draw { bench.keepGPUBusy() }
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        var idleAfterBaking = false
        try canvas.draw {
            // 初めて出る字形なので、ここで焼く
            canvas.text("A", 8, 40)
            idleAfterBaking = bench.gpu.isIdle
        }
        #expect(idleAfterBaking, "字形を焼いた時点で、前のフレームの GPU が終わっていない")
    }

    @Test("前のフレームの GPU が読んでいる置き場を、次のフレームの CPU が書き換えない")
    func nextFrameDoesNotOverwriteBuffersStillBeingRead() throws {
        let bench = try makeBench()
        let canvas = bench.canvas

        // フレーム N: 左半分を白く。GPU はこの頂点をしばらく読み続ける
        try canvas.draw {
            bench.keepGPUBusy()
            canvas.background(black)
            canvas.fill(white)
            canvas.rect(0, 0, 16, 32)
        }
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        // フレーム N+1: 右半分を赤く。同じ頂点の置き場へ書く — 待たずに書けば N の絵が壊れる
        // が、N の絵は上書きされるので、壊れは「N+1 の絵が期待と違う」形でしか見えない。
        // だから N+1 を単独で描いた絵と比べる
        try canvas.draw {
            canvas.background(black)
            canvas.fill(red)
            canvas.rect(16, 0, 16, 32)
        }
        let actual = try canvas.target.encodeForDisplay()

        let fresh = try makeBench()
        try fresh.canvas.draw {
            fresh.canvas.background(black)
            fresh.canvas.fill(red)
            fresh.canvas.rect(16, 0, 16, 32)
        }
        let expected = try fresh.canvas.target.encodeForDisplay()

        #expect(actual.bytes == expected.bytes)
        #expect(bench.gpu.resetsWhileInFlight == 0)
    }

    // MARK: - フレームごとに書く置き場の環 (#754)

    /// 環が 1 周するのに要る描き切りの数より多く回す。
    private var framesPastOneLap: Int { RenderDevice.defaultSlotCount + 3 }

    @Test("GPU を占めたフレームの次のフレームは、書く前に投入済みの全完了を待たない")
    func theNextFrameWritesWithoutDrainingTheGPU() throws {
        let bench = try makeBench()
        let canvas = bench.canvas

        // **先に温める。** 置き場を初めて取るフレームは取り直しの中で待つので、
        // 「毎フレーム待っているか」を見るにはそこを過ぎてから測る
        for _ in 0..<framesPastOneLap {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(red)
                canvas.rect(0, 0, 32, 32)
            }
        }

        try canvas.draw {
            bench.keepGPUBusy()
            canvas.background(black)
            canvas.fill(red)
            canvas.rect(0, 0, 32, 32)
        }
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        let waits = bench.gpu.blockingWaits
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.rect(0, 0, 16, 32)
        }

        #expect(
            bench.gpu.blockingWaits == waits,
            "描き切りが投入済みの全完了を待っている — 環が効いていない")
        #expect(
            !bench.gpu.isIdle,
            "次のフレームを書き終えた時点で GPU が空いている — どこかで全完了を待っている")
    }

    @Test("環は、そのスロットを読む投入が終わるまで返らない")
    func advancingWaitsForTheSubmissionThatReadsTheSlot() throws {
        let bench = try makeBench()
        // **描き切りが使う環とは別に、この検査だけの環を持つ。** 見たいのは機構そのもの
        // (進めて・記録して・1 周したら待つ) で、描き切りの都合を混ぜない
        let ring = FrameRing(gpu: bench.gpu)

        try ring.advance()
        try bench.canvas.draw { bench.keepGPUBusy() }
        // いま投入した描き切りが、このスロットの置き場を読む
        ring.noteSubmission()
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        // 途中のスロットはまだ誰にも読まれていないので、待たずに通り抜ける
        for _ in 1..<ring.slotCount {
            try ring.advance()
            #expect(!bench.gpu.isIdle, "誰も読んでいないスロットで待っている")
        }

        // 1 周して戻ってきた。記録した投入が終わっていなければならない
        try ring.advance()
        #expect(
            bench.gpu.isIdle,
            "環が 1 周したのに、そのスロットを読む投入がまだ走っている — advance が待っていない")
    }

    @Test("環が浅い土台では、そのスロットを読む投入だけを待つ")
    func aShallowRingWaitsForItsOwnSlotOnly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderFailure.deviceUnavailable
        }
        // 置き場を 1 本にすると、**次の描き切りに必ず同じスロットが回ってくる**
        let gpu = try RenderDevice(device: device, slotCount: 1)
        let target = try RenderTarget(gpu: gpu, width: 32, height: 32)
        let canvas = try Canvas(target: target, gpu: gpu)
        let scratch = try canvas.makeNumbers(count: 1)
        let spin = try canvas.makeComputation(Self.spin, name: "spin")

        func frame() throws {
            try canvas.draw {
                canvas.compute(spin, over: 1, writes: [scratch])
                canvas.background(black)
                canvas.fill(red)
                canvas.rect(0, 0, 32, 32)
            }
        }

        // **組み立ての待ちは数えない。** 描画先を透明な黒で塗る仕事や字形の面の用意は
        // 1 度きりで、フレームの経路には乗らない
        try frame()
        let waits = gpu.blockingWaits
        let ringWaits = gpu.ringWaits
        for _ in 0..<4 { try frame() }

        #expect(gpu.ringWaits > ringWaits, "環が 1 段しか無いのに一度も待っていない")
        #expect(
            gpu.blockingWaits == waits,
            "投入済みの全完了を待っている — 待ちが縮んでいない")
        #expect(gpu.resetsWhileInFlight == 0)
    }

    /// **見るのは絵で、見えるのは「置き場が分かれていること」である。**
    ///
    /// 環の**待ち**のほうはここでは見えない — コマンドの置き場の環が同じ深さで先に待つので、
    /// `advance()` の待ちを外しても絵は壊れない (実際に外して確かめた)。待ちが自分の
    /// 不変条件を自分で守っていることは、1 つ上の検査が直に見る。
    ///
    /// ここが見るのは、**スロットごとに別の置き場へ書いていること**である。1 本に戻すと、
    /// まだ読まれている置き場を次のフレームが書き潰し、帯が抜ける。差し出しを挟むのは
    /// コマンドの置き場の環を倍の速さで回して、覆いを 1.5 フレームぶんまで浅くするため。
    @Test("差し出しを挟んで環が 1 周しても、前のフレームが読んでいる置き場を書き換えない")
    func framesAcrossOneLapDoNotOverwriteBuffersStillBeingRead() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderFailure.deviceUnavailable
        }
        let gpu = try RenderDevice(device: device)
        let target = try RenderTarget(gpu: gpu, width: 64, height: 64)
        let canvas = try Canvas(target: target, gpu: gpu)
        let scratch = try canvas.makeNumbers(count: 1)
        let spin = try canvas.makeComputation(Self.spin, name: "spin")
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let layer = SurfaceFixture.make(device, size: 64)
        let bands = framesPastOneLap

        // **`background` を呼ばない**ので、フレームの絵は前のフレームの上に積み上がる
        // (描画先の読み込みが `.load` になる)。壊れたフレームの跡が最後まで残るので、
        // 1 度読むだけで全フレームぶんを見られる
        try canvas.draw {
            canvas.compute(spin, over: 1, writes: [scratch])
            canvas.background(black)
        }
        var presented = 0
        for band in 0..<bands {
            try canvas.draw {
                // **毎フレーム GPU を占める。** 占めなければ CPU が追いつかれてしまい、
                // 環が守っているのか偶然終わっていたのかが分けられない
                canvas.compute(spin, over: 1, writes: [scratch])
                Self.paintBand(on: canvas, at: band, of: bands)
            }
            if try presenter.present(target, to: layer) { presented += 1 }
        }
        try #require(!gpu.isIdle, "回転が短い — この検査は何も見ていない")
        try #require(presented > 0, "面を 1 度も取れていない — 差し出しが投入を積んでいない")

        let pixels = try canvas.target.readPixels()
        for band in 0..<bands {
            let expected = Self.bandColor(at: band, of: bands)
            let (x, y) = Self.bandProbe(at: band, of: bands)
            let actual = pixels[x, y]
            #expect(
                abs(actual.red - expected.red) < 0.02
                    && abs(actual.green - expected.green) < 0.02
                    && abs(actual.blue - expected.blue) < 0.02,
                """
                \(band) 本目の帯が壊れている (期待 \(expected)、実際 \(actual))。
                そのフレームの置き場を、次のフレームの CPU が読まれている間に書き換えている
                """)
        }
        #expect(gpu.resetsWhileInFlight == 0)
    }

    /// 1 フレームぶんの帯を描く。**列を 2 つ以上持たせる** — 切り取りを切り替えると
    /// 列が閉じるので、列ごとの置き場 (行列・値・材質・周囲) も同じフレームで 2 区画
    /// 使われる。
    private static func paintBand(on canvas: Canvas, at index: Int, of count: Int) {
        let height = 64 / Float(count)
        let top = Float(index) * height
        let color = bandColor(at: index, of: count)
        for half in 0..<2 {
            canvas.clip(Float(half) * 32, top, 32, height)
            canvas.fill(color)
            canvas.rect(0, top, 64, height)
        }
        canvas.noClip()
    }

    /// 帯ごとの色。**帯どうしを区別できる**ように、番号から作る。
    private static func bandColor(at index: Int, of count: Int) -> LinearRGBA {
        let step = Float(index + 1) / Float(count + 1)
        return .opaque(red: step, green: 1 - step, blue: 0.5)
    }

    /// その帯を代表する画素。帯の真ん中を見る (縁の丸めを踏まない)。
    private static func bandProbe(at index: Int, of count: Int) -> (Int, Int) {
        let height = 64 / count
        return (16, index * height + height / 2)
    }

    @Test("描画の土台を手放すときは、実行中のコマンドが終わるのを待つ")
    func droppingTheDeviceWaitsForInFlightWork() throws {
        // まず回転 1 回ぶんの長さを、同じ絵で測る (機械ごとに違うので自分で測る)
        let clock = ContinuousClock()
        let reference = try makeBench()
        let measured = clock.now
        try reference.canvas.draw { reference.keepGPUBusy() }
        try reference.gpu.settle()
        let spinDuration = clock.now - measured
        try #require(spinDuration > .milliseconds(20), "回転が短すぎて、待ちの有無を時間で分けられない")

        // 待たずに手放す。土台が畳まれる前に GPU の完了を待っていれば、その時間ぶんかかる
        let dropped = clock.now
        try autoreleasepool {
            let bench = try makeBench()
            try bench.canvas.draw { bench.keepGPUBusy() }
            try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")
        }
        let dropDuration = clock.now - dropped
        #expect(
            dropDuration >= spinDuration / 2,
            "土台が GPU の完了を待たずに畳まれた (手放しに \(dropDuration)、回転は \(spinDuration))")
    }

    @Test("draw の中で作って手放した絵は、GPU が終わるまで生きる")
    func resourcesDroppedDuringDrawOutliveTheGPU() throws {
        let bench = try makeBench()
        let canvas = bench.canvas

        // 見るのは GPU が実際に読む面。`Image` そのものは列が抱えないので、利用者が
        // 手放せばすぐ消える (それでよい — GPU が読むのは面のほう)
        weak var droppedTexture: (any MTLTexture)?
        try canvas.draw {
            bench.keepGPUBusy()
            let image = try? canvas.createImage(2, 2)
            image?.set(0, 0, red)
            if let image { canvas.image(image, 0, 0) }
            droppedTexture = image?.texture
        }
        try #require(!bench.gpu.isIdle, "回転が短い — この検査は何も見ていない")

        // 呼ぶ側の参照は落ちたが、GPU がまだ読んでいる間は生きている
        #expect(droppedTexture != nil, "GPU が読んでいる途中で面が解放された")
        #expect(bench.gpu.heldResourceCount > 0)

        try bench.gpu.settle()
        #expect(bench.gpu.heldResourceCount == 0, "終わったのに抱え続けている")
        // ここで消えるかどうかは常駐の集合が面を保持するかで決まる。保持するなら消えず、
        // それはそれで安全 (#738 が別に見ている)。だから消えることは要求しない
    }
}
