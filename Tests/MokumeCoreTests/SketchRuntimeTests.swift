// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 進め方だけを見る検査 (GPU を要さない)。
@Suite("フレームの時刻")
struct FrameTimingTests {
    /// 検査から動かせる時計。
    final class ManualClock {
        var now: Double
        init(_ start: Double) { now = start }
        var provider: () -> Double { { [self] in now } }
    }

    @Test("フレーム番号から導く時計は、実時間に依存しない")
    func frameIndexClockIgnoresWallClock() {
        let clock = ManualClock(1_000)
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: clock.provider)
        // 実時間をでたらめに進めても、時刻はフレーム番号だけで決まる
        timing.advance()
        #expect(timing.frameCount == 1)
        #expect(timing.time == 0)
        #expect(timing.deltaTime == Float(1.0 / 60))

        clock.now = 9_999
        timing.advance()
        #expect(timing.frameCount == 2)
        #expect(timing.time == Float(1.0 / 60))
        #expect(timing.deltaTime == Float(1.0 / 60))
    }

    @Test("実時間の時計は、実際に流れた時間を返す")
    func wallClockReportsElapsedTime() {
        let clock = ManualClock(100)
        let timing = FrameTiming(clock: .wallClock, now: clock.provider)
        clock.now = 100.5
        timing.advance()
        #expect(abs(timing.time - 0.5) < 1e-5)
        #expect(abs(timing.deltaTime - 0.5) < 1e-5)
    }

    @Test("寄せ直さないと、止めていた時間が 1 フレームの経過に化ける")
    func withoutResyncTheGapLandsOnOneFrame() {
        let clock = ManualClock(0)
        let timing = FrameTiming(clock: .wallClock, now: clock.provider)
        clock.now = 0.016
        timing.advance()
        // 10 秒止めてから再開した、を寄せ直さずに再現する
        clock.now = 10.016
        timing.advance()
        #expect(timing.deltaTime > 9)
    }

    @Test("寄せ直せば、再開後の最初の経過は 1 フレームぶんに収まる")
    func resyncKeepsTheFirstFrameAfterResumeSmall() {
        let clock = ManualClock(0)
        let timing = FrameTiming(clock: .wallClock, now: clock.provider)
        clock.now = 0.016
        timing.advance()
        clock.now = 10.0
        timing.resync()
        clock.now = 10.016
        timing.advance()
        #expect(abs(timing.deltaTime - 0.016) < 1e-5)
    }

    @Test("時間が巻き戻っても経過は負にならない")
    func timeGoingBackwardsDoesNotProduceNegativeDelta() {
        let clock = ManualClock(100)
        let timing = FrameTiming(clock: .wallClock, now: clock.provider)
        clock.now = 90
        timing.advance()
        #expect(timing.deltaTime == 0)
    }
}

/// スケッチを走らせる検査。GPU を要する。
@Suite(
    "スケッチの進み",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchRuntimeTests {
    /// 呼ばれた回数と、そのときのフレーム番号を数えるだけのスケッチ。
    final class CountingSketch: Sketch {
        var settings = SketchSettings(width: 16, height: 16, frameRate: 60)
        var setupCalls = 0
        var drawCalls = 0
        var seenFrameCounts: [Int] = []
        var seenTimes: [Float] = []

        init() {}
        func setup() { setupCalls += 1 }
        func draw() {
            drawCalls += 1
            seenFrameCounts.append(frameCount)
            seenTimes.append(time)
            background(.opaque(red: 0, green: 0, blue: 0))
        }
    }

    private func makeRuntime(_ sketch: CountingSketch, clock: Clock? = nil) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: clock)
    }

    @Test("1 枚だけ進めると、描画はちょうど 1 回・フレーム番号は 1")
    func advancingOnceDrawsExactlyOneFrame() throws {
        let sketch = CountingSketch()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        #expect(sketch.setupCalls == 1)
        #expect(sketch.drawCalls == 1)
        #expect(sketch.seenFrameCounts == [1])
    }

    @Test("初期化は何度進めても 1 回だけ")
    func setupRunsOnlyOnce() throws {
        let sketch = CountingSketch()
        let runtime = try makeRuntime(sketch)
        for _ in 0..<3 { try runtime.advance() }

        #expect(sketch.setupCalls == 1)
        #expect(sketch.drawCalls == 3)
        #expect(sketch.seenFrameCounts == [1, 2, 3])
    }

    @Test("既定の時計はフレーム番号から導く")
    func defaultClockIsDerivedFromTheFrameIndex() throws {
        let sketch = CountingSketch()
        let runtime = try makeRuntime(sketch)
        for _ in 0..<3 { try runtime.advance() }

        #expect(sketch.seenTimes == [0, Float(1.0 / 60), Float(2.0 / 60)])
    }

    @Test("止めている間は進まない")
    func pausedRuntimeDoesNotAdvance() throws {
        let sketch = CountingSketch()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()
        runtime.pause()
        try runtime.advance()
        try runtime.advance()

        #expect(sketch.drawCalls == 1)
        #expect(runtime.isRunning == false)

        runtime.resume()
        try runtime.advance()
        #expect(sketch.drawCalls == 2)
        #expect(runtime.isRunning)
    }

    @Test("止めて再開したとき、再開後の最初の経過は 1 フレームぶんに収まる")
    func resumeResyncsTheClock() throws {
        /// 経過時間を記録するだけのスケッチ。
        final class DeltaSketch: Sketch {
            var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
            var seenDeltas: [Float] = []
            init() {}
            func draw() {
                seenDeltas.append(deltaTime)
                background(.opaque(red: 0, green: 0, blue: 0))
            }
        }

        let sketch = DeltaSketch()
        var now: Double = 0
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .wallClock, now: { now })

        now = 0.016
        try runtime.advance()

        // 10 秒止めて、再開する
        runtime.pause()
        now = 10.0
        runtime.resume()
        now = 10.016
        try runtime.advance()

        // 寄せ直していなければ、ここが 10 秒になる
        #expect(sketch.seenDeltas.count == 2)
        #expect(abs(sketch.seenDeltas[1] - 0.016) < 1e-5)
    }

    @Test("走っていないときに描画 API へ届く道が無い")
    func drawingApiIsNotReachableWhileNothingRuns() throws {
        // ランタイムを作っただけでは差し込まれない。差し込みは setup / draw の間だけ。
        let sketch = CountingSketch()
        _ = try makeRuntime(sketch)
        #expect(runningSketch == nil)
    }

    @Test("同じスケッチを 2 回走らせると、書き出した絵が一致する")
    func runningTheSameSketchTwiceProducesTheSameImage() throws {
        /// フレーム番号と時刻から絵が決まるスケッチ。
        final class MovingSketch: Sketch {
            var settings = SketchSettings(width: 64, height: 64, frameRate: 60)
            init() {}
            func draw() {
                background(.display(red: 0.1, green: 0.1, blue: 0.1))
                fill(.display(red: 1, green: 0.5, blue: 0.2))
                circle(32 + time * 60, 32, 20)
            }
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mokume-runtime-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var contents: [Data] = []
        for attempt in 0..<2 {
            let runtime = try SketchRuntime(sketch: MovingSketch(), gpu: try RenderDevice())
            // 何枚か進めてから書き出す — 1 枚目だけでは時刻が効いているか分からない
            for _ in 0..<5 { try runtime.advance() }
            let url = directory.appendingPathComponent("run-\(attempt).png")
            try runtime.target.writePNG(to: url)
            contents.append(try Data(contentsOf: url))
        }
        #expect(contents[0] == contents[1])
    }
}
