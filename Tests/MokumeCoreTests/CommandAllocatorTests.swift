// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore
import Testing

@testable import MokumeCore

/// コマンドの置き場を巻き戻す規律の検査。GPU を要する。
///
/// **待たない経路 (表示) を挟んだときが本番。** 描画と読み戻しは GPU の完了まで待つので、
/// その 2 つだけを回しても規律は勝手に守られてしまい、検査が何も見ないまま緑になる
/// ([#222](https://github.com/mokume-metal/mokume/issues/222))。
@Suite(
    "コマンドの置き場",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CommandAllocatorTests {
    /// 描く → 差し出す (待たない) を繰り返し、置き場の使われ方を返す。
    private func runFrames(
        _ count: Int, slotCount: Int, size: Int = 64
    ) throws -> (gpu: RenderDevice, presented: Int) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gpu = try RenderDevice(device: device, slotCount: slotCount)
        let source = try RenderTarget(gpu: gpu, width: size, height: size)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let layer = SurfaceFixture.make(device, size: size)

        var presented = 0
        for index in 0..<count {
            // 描く経路 (GPU の完了まで待つ)
            try source.fill(with: .linear(red: Float(index % 2), green: 0.2, blue: 0.3))
            // 差し出す経路 (待たない)
            if try presenter.present(source, to: layer) { presented += 1 }
        }
        return (gpu, presented)
    }

    @Test("置き場が 1 本しか無いと、待たない経路の直後に必ず待ちが起きる")
    func waitsBeforeReusingTheOnlyAllocator() throws {
        // 1 本にすると、待たない経路の**直後に必ず**同じ置き場が回ってくる
        let (gpu, presented) = try runFrames(60, slotCount: 1)
        try #require(presented > 0, "面を 1 度も取れていない — この検査は何も見ていない")

        #expect(gpu.slotWaits > 0, "一度も待っていない — 待たない経路が置き場を返していない")
    }

    /// GPU を数 ms 以上占める計算。**1 本の糸が長い依存の鎖をたどる**ので、幅を広げても
    /// 速くならず、最適化で畳まれもしない (`FrameSyncTests` と同じ手)。
    private static let spin = """
        kernel void spin(device float *out [[buffer(0)]],
                         uint id [[thread_position_in_grid]])
        {
            float acc = 0.5;
            for (uint i = 0; i < 2000000u; ++i) { acc = fma(acc, 1.0000001f, 0.25f); }
            out[id] = acc;
        }
        """

    /// **実際の描き切りで**回す。`fill` は待つ経路なので、描き切りが待たなくなった
    /// ([#727](https://github.com/mokume-metal/mokume/issues/727)) ことをそちらでは見られない。
    /// 描き切り (待たない) → 差し出し (待たない) と、待たない経路が 2 つ続く形になる。
    ///
    /// **待ちが起きることを構造で作る。** 64×64 の描き切りは GPU が数十 µs で終えるので、
    /// CPU が次の `withCommands(_:)` へ戻る前に終わっていれば待ちは 0 になる — 負荷の
    /// かかった機械 (CPU が押されている) では実際にそうなった
    /// ([#765](https://github.com/mokume-metal/mokume/issues/765))。毎フレームの描き切りに
    /// GPU を占める計算を積めば、機械の速さと負荷に依らず「まだ終わっていない」が立つ。
    @Test("描き切りと差し出しが続いても、置き場が 1 本なら待ちが起きる")
    func waitsBetweenUnwaitedFlushAndPresent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gpu = try RenderDevice(device: device, slotCount: 1)
        let target = try RenderTarget(gpu: gpu, width: 64, height: 64)
        let canvas = try Canvas(target: target, gpu: gpu)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let layer = SurfaceFixture.make(device, size: 64)
        let scratch = try canvas.makeNumbers(count: 1)
        let spin = try canvas.makeComputation(Self.spin, name: "spin")

        var presented = 0
        var busyAfterFlush = 0
        for index in 0..<20 {
            try canvas.draw {
                canvas.compute(spin, over: 1, writes: [scratch])
                canvas.background(.linear(red: Float(index % 2), green: 0.2, blue: 0.3))
                canvas.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.rect(8, 8, 48, 48)
            }
            if !gpu.isIdle { busyAfterFlush += 1 }
            if try presenter.present(target, to: layer) { presented += 1 }
        }
        try #require(presented > 0, "面を 1 度も取れていない — この検査は何も見ていない")
        try #require(busyAfterFlush > 0, "描き切りが返った時点で GPU が毎回終わっている — 回転が短く、この検査は何も見ていない")

        #expect(gpu.slotWaits > 0, "一度も待っていない — 待たない経路が置き場を返していない")
    }

    /// **#222 の不変条件そのものを見る、唯一の検査。**
    ///
    /// 上の 2 本が見ているのは「待ちが起きたこと」(`slotWaits`) までで、その待ちが
    /// **実際に終わりまで待ったか**は見ていない。土台の側にも置けない — 判定に使える
    /// 合図は `waitForSlot` が待っているのと同じもの 1 つきりなので、中に書くと待ちの
    /// 事後条件を 1 行あとで自己申告するだけになる ([#790](https://github.com/mokume-metal/mokume/issues/790))。
    ///
    /// **外から見るために、置き場を 1 本にする。** 1 本なら「その置き場へ積んだ投入」と
    /// 「投入済みの全部」が一致するので、組み立ての口 (`withCommands(_:)`) が本体を呼んだ
    /// 時点の `isIdle` がそのまま事後条件になる。待ちを外すとここが赤くなる (実測)。
    ///
    /// **本体の最初の文で読む。** 口は巻き戻してから本体を呼ぶまでの間に GPU を待たないので、
    /// ここで読む値は巻き戻した時点のものと同じ意味を持つ (かつては開く口を直に呼び、
    /// 返った時点で読んでいた — 開く口は #1180 で外から呼べなくなった)。
    @Test("置き場を取り直す口は、その置き場を読む投入が終わってから巻き戻す")
    func withCommandsWaitsForTheSubmissionThatReadsTheSlot() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gpu = try RenderDevice(device: device, slotCount: 1)
        let target = try RenderTarget(gpu: gpu, width: 64, height: 64)
        let canvas = try Canvas(target: target, gpu: gpu)
        let scratch = try canvas.makeNumbers(count: 1)
        let spin = try canvas.makeComputation(Self.spin, name: "spin")

        // **「まだ終わっていない」を構造で作る** (この suite の他の検査と同じ手)
        try canvas.draw {
            canvas.compute(spin, over: 1, writes: [scratch])
            canvas.background(.linear(red: 0, green: 0, blue: 0))
        }
        try #require(!gpu.isIdle, "回転が短い — この検査は何も見ていない")

        let waits = gpu.slotWaits
        let (waitsWhenOpened, idleWhenOpened) = try gpu.withCommands {
            commands throws(RenderFailure) in
            let observed = (gpu.slotWaits, gpu.isIdle)
            // 開いたままにしない (この 1 本は絵を持たないので、空のまま投入して畳む)
            gpu.commit(commands)
            return observed
        }
        try gpu.settle()

        #expect(
            waitsWhenOpened == waits + 1,
            "実行中の置き場を取り直したのに、待ちに入っていない")
        #expect(
            idleWhenOpened,
            "置き場を巻き戻したのに、そこへ積んだ投入がまだ走っている — #222 の不変条件が破れている")
    }

    /// 塗った面を頼む口 (`RenderDevice.makeClearedTexture`) は自分のコマンドを 1 本開くので、
    /// 組み立て中に呼ぶと環が二重に開かれる。断ること自体は前からしていたが、投げていたのが
    /// 資源枯渇の case で、文面が「走ったままのスケッチを閉じてから試す」と言っていた —
    /// 閉じても何も変わらないので、踏んだ人を必ず間違った方向へ送っていた
    /// ([#792](https://github.com/mokume-metal/mokume/issues/792))。
    @Test("コマンドを組み立てている最中に塗った面を頼むと、呼び出し順の誤りとして断る")
    func refusesAClearedTextureWhileCommandsAreOpen() throws {
        let gpu = try RenderDevice()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        // 開いていなければ通る。**「いつでも投げる」を見ていない**ことの担保
        _ = try gpu.makeClearedTexture(descriptor: descriptor)

        try gpu.withCommands { commands throws(RenderFailure) in
            #expect(throws: RenderFailure.commandsAlreadyOpen) {
                _ = try gpu.makeClearedTexture(descriptor: descriptor)
            }
            // 開いたままにしない (この 1 本は絵を持たないので、空のまま投入して畳む)
            gpu.commit(commands)
        }
        try gpu.settle()
    }

    // MARK: - 投入されずに抜けたコマンド (#1180)

    /// 検査で塗る色。読み戻した値と比べるので、作業空間で丸めの出ない値にしてある。
    private static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)

    /// **組み立ての口の中で、encoder を開いたまま投げる。** 片付けにとって最悪の形である —
    /// 開いた encoder があるとコマンドを閉じられず (`endCommandBuffer()` が検証層の表明で
    /// 落ちる)、閉じずに同じ置き場を使うと次の巻き戻しで落ちる (#1180 の実測)。
    ///
    /// **encoder は外の変数に持たせて、次の組み立てが済むまで生かす。** 捨てたコマンドより
    /// encoder のほうが長生きする手放し順も、同じ検査で覆う。
    ///
    /// 置き場を 1 本にしてあるので、捨てたコマンドの載っていた置き場が次の組み立てに必ず
    /// 回ってくる。検証層を載せた実行 (`make test`) では、手放さずに巻き戻すとここで
    /// プロセスが落ちる。
    @Test("組み立ての途中で投げても、塗った面を作れ、同じ置き場で描き続けられる")
    func assemblyThatThrowsLeavesTheDeviceUsable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gpu = try RenderDevice(device: device, slotCount: 1)
        let target = try RenderTarget(gpu: gpu, width: 4, height: 4)

        var leftOpen: (any MTL4RenderCommandEncoder)?
        #expect(throws: RenderFailure.encoderUnavailable) {
            try gpu.withCommands { commands throws(RenderFailure) in
                leftOpen = commands.makeRenderCommandEncoder(
                    descriptor: target.makeRenderPass(clearColor: nil))
                throw .encoderUnavailable
            }
        }
        try #require(leftOpen != nil, "encoder を開けていない — 最悪の形を作れていない")

        // 記録が残っていれば、ここで「組み立て中」として断られる
        _ = try RenderTarget(gpu: gpu, width: 4, height: 4)

        try target.fill(with: Self.red)
        leftOpen = nil
        try target.fill(with: Self.red)
        #expect(try target.readPixels()[0, 0] == Self.red)
        #expect(gpu.commandFaultCount == 0, "GPU が仕事を打ち切った: \(gpu.lastCommandFault ?? "")")
    }

    /// **実在の経路で投げる** — 描き切りの途中、組み立てを始めた後で。伸びる置き場は
    /// 2 度目の取り直しから古い置き場を常駐から外すために全完了を待つので、そこへ
    /// 「待てなかった」を差し込むと、画面の encoder を開いたまま `.timedOut` が上がる。
    ///
    /// **投げたのが組み立ての後であることは、捨てた数で確かめる。** 描き切りの手順が
    /// 入れ替わって取り直しが組み立ての前へ移れば、この検査は何も見なくなるので赤にする。
    /// 数は見張りで、正しさは作れた面と読めた絵のほうで見る。
    @Test("描き切りの途中で投げても、同じ土台で描き場所を作れ、続くフレームが描ける")
    func flushThatThrowsMidAssemblyLeavesTheDeviceUsable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gpu = try RenderDevice(device: device, slotCount: 1)
        let target = try RenderTarget(gpu: gpu, width: 16, height: 16)
        let canvas = try Canvas(target: target, gpu: gpu)
        // 置き場を 1 度取らせる (1 度目の取り直しは外す古い置き場が無いので待たない)
        try canvas.draw { canvas.rect(0, 0, 1, 1) }

        let abandoned = gpu.abandonedCommands
        gpu.failSettleForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)
        #expect(throws: RenderFailure.timedOut(seconds: RenderDevice.waitLimitSeconds)) {
            try canvas.draw {
                for index in 0..<2000 { canvas.rect(index % 16, index / 16 % 16, 1, 1) }
            }
        }
        gpu.failSettleForTesting = nil
        try #require(
            gpu.abandonedCommands == abandoned + 1,
            "投げたのが組み立てを始める前 — この検査は何も見ていない")

        // 記録が残っていれば、ここで「組み立て中」として断られる
        _ = try RenderTarget(gpu: gpu, width: 4, height: 4)

        try canvas.draw { canvas.background(Self.red) }
        #expect(try target.readPixels()[0, 0] == Self.red)
        #expect(gpu.commandFaultCount == 0, "GPU が仕事を打ち切った: \(gpu.lastCommandFault ?? "")")
    }

    /// **投入した後で投げたものは、捨てたことにしない。** 待つ投入 (`commitAndWait`) は
    /// 投入してから待つので、待ちが期限切れになったときのコマンドは GPU が読んでいる最中で
    /// ある。これを捨てたことにすると、走っている仕事の載った置き場を手放す。
    @Test("投入した後で待てなかったコマンドは、置き場を手放さない")
    func submittedCommandsAreNotAbandonedWhenTheWaitFails() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 4, height: 4)

        let abandoned = gpu.abandonedCommands
        gpu.failSettleForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)
        #expect(throws: RenderFailure.timedOut(seconds: RenderDevice.waitLimitSeconds)) {
            try target.fill(with: Self.red)
        }
        gpu.failSettleForTesting = nil

        #expect(gpu.abandonedCommands == abandoned, "投入済みのコマンドを捨てたことにしている")
        try gpu.settle()
        #expect(try target.readPixels()[0, 0] == Self.red, "投入したはずの塗りが描かれていない")
    }

    @Test("環が既定の本数なら、毎フレームは待たない")
    func theDefaultRingDoesNotWaitEveryFrame() throws {
        let (gpu, presented) = try runFrames(120, slotCount: RenderDevice.defaultSlotCount)
        try #require(presented > 0, "面を 1 度も取れていない — この検査は何も見ていない")

        // 環の本数は速さのための値なので、**待ちが常態になっていない**ことを見る。
        // 1 本に減らすとここが赤くなり、既定の 3 本が効いていることが分かる。
        // 正しさ (待つべきときに待つ) の側は 1 つ上の検査が持つ
        #expect(
            gpu.slotWaits < presented,
            "既定の環でも毎回待っている — 本数が足りていない")
    }
}
