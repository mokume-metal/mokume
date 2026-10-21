// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// フレームごとの GPU 時間 (投入の幅) が、結末から集まること
/// ([#2378](https://github.com/mokume-metal/mokume/issues/2378))。GPU を要する。
///
/// **追加の待ちを作らない**のが条件の 1 つで、時刻はハンドラが錠の中へ書くだけで、読む口
/// (`lastGPUFrameTime`) も待たない。待ちの数は `settleCalls`・`blockingWaits`・`ringWaits` で見る。
/// 結末は投入より後に届くので、揃うまでは**期限つきで待つ** (時計の速さを前提にしない)。
@Suite(
    "フレームの GPU 時間",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameGPUTimeTests {
    /// 毎フレーム背景と矩形を描く。
    final class Plain: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        func draw() {
            background(.display(red: 0.1, green: 0.1, blue: 0.1))
            fill(.display(red: 0.9, green: 0.3, blue: 0.2))
            rect(8, 8, 32, 24)
        }
    }

    /// 結末が揃うまで、期限つきで待って読む。**待つのは検査の側で、GPU 側の待ちではない。**
    private func awaitFrameTime(
        _ gpu: RenderDevice, where accept: (RenderDevice.GPUFrameTime) -> Bool = { _ in true }
    ) -> RenderDevice.GPUFrameTime? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let time = gpu.lastGPUFrameTime, accept(time) { return time }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    @Test("フレームを回すと、完了したフレームの GPU 時間が正の値で揃う")
    func aFrameTimeArrivesFromTheOutcomes() throws {
        let runtime = try SketchRuntime(sketch: Plain(), gpu: try RenderDevice())
        let gpu = runtime.target.gpu
        for _ in 0..<6 { try runtime.advance() }

        let time = try #require(awaitFrameTime(gpu), "結末が揃わなかった (期限切れ)")
        // 6 フレーム目は進行中。完了したのは 1〜5
        #expect((1...5).contains(time.frame), "進行中のフレームを数えた: \(time.frame)")
        #expect(time.span.submissions >= 1)
        #expect(time.milliseconds > 0 && time.milliseconds < 1000, "桁が違う: \(time.milliseconds) ms")
        try gpu.settle()
    }

    /// **待ちが増えないこと** (完了条件 1)。読む口は時刻を読むだけで、`settle()` も名指しの待ちも
    /// 呼ばない。時刻を集める前後で、待ちの数が同じである。
    @Test("GPU 時間を集めて読んでも、待ちは 1 つも増えない")
    func collectingTheTimesAddsNoWaits() throws {
        let runtime = try SketchRuntime(sketch: Plain(), gpu: try RenderDevice())
        let gpu = runtime.target.gpu
        for _ in 0..<8 { try runtime.advance() }
        let before = (gpu.settleCalls, gpu.blockingWaits, gpu.ringWaits)

        _ = try #require(awaitFrameTime(gpu), "結末が揃わなかった (期限切れ)")
        for _ in 0..<20 { _ = gpu.lastGPUFrameTime }

        let after = (gpu.settleCalls, gpu.blockingWaits, gpu.ringWaits)
        #expect(before == after, "時刻を読む口が待ちを増やした: \(before) → \(after)")
        #expect(after.0 == 0, "フレームを回すだけで settle を頼んでいる: \(after)")
        #expect(after.1 == 0, "フレームを回すだけで GPU の完了を待っている: \(after)")
        try gpu.settle()
    }

    /// 1 フレームに複数の投入があるとき、幅は 1 つにまとまる。投入の無いフレームは飛ばす。
    @Test("1 フレームの複数の投入は 1 つの幅になり、投入の無いフレームは飛ばす")
    func severalSubmissionsMakeOneFrame() throws {
        let gpu = try RenderDevice()
        gpu.markFrameStart()
        for _ in 0..<3 {
            try gpu.withCommands { commands throws(RenderFailure) in gpu.commit(commands) }
        }
        gpu.markFrameStart()  // フレーム 2 の頭。ここから投入は無い
        gpu.markFrameStart()  // フレーム 3 の頭

        let time = try #require(awaitFrameTime(gpu), "結末が揃わなかった (期限切れ)")
        #expect(time.frame == 1, "投入の無いフレームを返した: \(time.frame)")
        #expect(time.span.submissions == 3)
        #expect(gpu.completedGPUFrameTimes.map(\.frame) == [1], "完了フレームの並びが違う")
        try gpu.settle()
    }
}
