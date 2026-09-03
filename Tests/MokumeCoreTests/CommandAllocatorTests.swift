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
            try source.fill(with: .opaque(red: Float(index % 2), green: 0.2, blue: 0.3))
            // 差し出す経路 (待たない)
            if try presenter.present(source, to: layer) { presented += 1 }
        }
        return (gpu, presented)
    }

    @Test("置き場が 1 本しか無くても、実行中のものを巻き戻さない")
    func waitsBeforeReusingTheOnlyAllocator() throws {
        // 1 本にすると、待たない経路の**直後に必ず**同じ置き場が回ってくる
        let (gpu, presented) = try runFrames(60, slotCount: 1)
        try #require(presented > 0, "面を 1 度も取れていない — この検査は何も見ていない")

        #expect(gpu.resetsWhileInFlight == 0)
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
    /// CPU が次の `beginCommands()` へ戻る前に終わっていれば待ちは 0 になる — 負荷の
    /// かかった機械 (CPU が押されている) では実際にそうなった
    /// ([#765](https://github.com/mokume-metal/mokume/issues/765))。毎フレームの描き切りに
    /// GPU を占める計算を積めば、機械の速さと負荷に依らず「まだ終わっていない」が立つ。
    @Test("描き切りと差し出しが続いても、置き場が 1 本なら待ってから巻き戻す")
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
                canvas.background(.opaque(red: Float(index % 2), green: 0.2, blue: 0.3))
                canvas.fill(.opaque(red: 1, green: 1, blue: 1))
                canvas.rect(8, 8, 48, 48)
            }
            if !gpu.isIdle { busyAfterFlush += 1 }
            if try presenter.present(target, to: layer) { presented += 1 }
        }
        try #require(presented > 0, "面を 1 度も取れていない — この検査は何も見ていない")
        try #require(busyAfterFlush > 0, "描き切りが返った時点で GPU が毎回終わっている — 回転が短く、この検査は何も見ていない")

        #expect(gpu.resetsWhileInFlight == 0)
        #expect(gpu.slotWaits > 0, "一度も待っていない — 待たない経路が置き場を返していない")
    }

    @Test("環の既定の本数でも、実行中のものを巻き戻さない")
    func neverResetsAnAllocatorInFlightWithTheDefaultRing() throws {
        let (gpu, presented) = try runFrames(120, slotCount: RenderDevice.defaultSlotCount)
        try #require(presented > 0, "面を 1 度も取れていない — この検査は何も見ていない")

        #expect(gpu.resetsWhileInFlight == 0)
        // 環の本数は速さのための値なので、**待ちが常態になっていない**ことも見る。
        // 1 本に減らすとここが赤くなり、既定の 3 本が効いていることが分かる
        #expect(
            gpu.slotWaits < presented,
            "既定の環でも毎回待っている — 本数が足りていない")
    }
}
