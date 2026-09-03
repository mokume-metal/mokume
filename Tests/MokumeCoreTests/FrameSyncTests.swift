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
