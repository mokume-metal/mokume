// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 残り時間を測る値 `Countdown` ([#2602](https://github.com/mokume-metal/mokume/issues/2602))。
///
/// 時計 (`FrameTiming`) を直に回し、その積み上げを渡して読むので、GPU を要さない。
@Suite("Countdown")
@MainActor
struct CountdownTests {
    /// 実時間を揺らしたフレームの時計。フレームの時計はこれを読まない。
    private func framesClock(rate: Int = 60) -> (FrameTiming, (Double) -> Void) {
        var now = 1000.0
        let timing = FrameTiming(clock: .frameIndex(frameRate: rate), frameRate: rate, now: { now })
        return (timing, { now += $0 })
    }

    // MARK: - 完了条件 1

    @Test("60 fps のフレームの時計で、1 秒は 59 枚目まで終わらず、60 枚目で終わる")
    func oneSecondEndsOnTheSixtiethFrame() {
        let (timing, pass) = framesClock()
        let countdown = Countdown(seconds: 1)
        var finished: [Bool] = []
        for frame in 1...61 {
            pass(frame % 5 == 0 ? 0.04 : 0.01)
            timing.advance()
            finished.append(countdown.isFinished(at: timing.elapsed))
        }
        #expect(finished[0..<59].allSatisfy { !$0 }, "59 枚目までに終わった")
        #expect(finished[59], "60 枚目で終わらない")
        #expect(finished[60])
        #expect(countdown.remaining(at: timing.elapsed) == 0, "0 を下回らない")
    }

    @Test("途中で数え直すと、その枚から数える (0.1 秒は 6 枚)")
    func restartingCountsFromThatFrame() {
        let (timing, pass) = framesClock()
        for _ in 0..<37 { pass(0.02); timing.advance() }
        // restart() と同じ — いまの積み上げを起点にする
        var countdown = Countdown(seconds: 0.1)
        countdown.restart(at: timing.elapsed)
        var finishedAt: Int?
        for frame in 1...10 {
            timing.advance()
            if finishedAt == nil, countdown.isFinished(at: timing.elapsed) { finishedAt = frame }
        }
        #expect(finishedAt == 6)
    }

    // MARK: - 完了条件 2・3

    @Test("pauseTime() の間は remaining が減らない")
    func pausingHoldsTheRemaining() {
        let (timing, pass) = framesClock()
        let countdown = Countdown(seconds: 2)
        for _ in 0..<10 { pass(0.016); timing.advance() }
        let before = countdown.remaining(at: timing.elapsed)
        #expect(abs(before - (2 - 10.0 / 60)) < 1e-5)
        timing.pauseTime()
        for _ in 0..<30 {
            pass(0.5)
            timing.advance()
            #expect(countdown.remaining(at: timing.elapsed) == before)
        }
        timing.playTime()
        timing.advance()
        #expect(abs(countdown.remaining(at: timing.elapsed) - (before - Float(1.0 / 60))) < 1e-5)
    }

    @Test("時刻を指定した観測の 1 枚と jumpTime() の枚では remaining が変わらない")
    func observedAndJumpedFramesDoNotCount() {
        let (timing, pass) = framesClock()
        let countdown = Countdown(seconds: 1)
        for _ in 0..<12 { pass(0.016); timing.advance() }
        let before = countdown.remaining(at: timing.elapsed)
        timing.advance(at: 30)
        #expect(countdown.remaining(at: timing.elapsed) == before, "観測の枚で減った")
        timing.jumpTime(0)
        timing.advance()
        #expect(countdown.remaining(at: timing.elapsed) == before, "飛んだ枚で減った")
        timing.advance()
        #expect(countdown.remaining(at: timing.elapsed) < before, "次の枚からは減る")
    }

    @Test("noLoop()・外からの停止の間 (枚が来ない) は、どれだけ実時間が流れても減らない")
    func stoppedFramesDoNotCount() {
        let (timing, pass) = framesClock()
        let countdown = Countdown(seconds: 1)
        for _ in 0..<12 { pass(0.016); timing.advance() }
        let before = countdown.remaining(at: timing.elapsed)
        pass(30)
        timing.resync()
        #expect(countdown.remaining(at: timing.elapsed) == before)
        timing.stepOneFrameNext()
        timing.advance()
        #expect(abs(countdown.remaining(at: timing.elapsed) - (before - Float(1.0 / 60))) < 1e-5)
    }

    // MARK: - 完了条件 4

    /// フレーム番号つきの数え直しの列を流し、`isFinished` が真になった枚を返す。
    private func finishingFrames(restartsAt restarts: Set<Int>, jitter: (Int) -> Double) -> [Int] {
        var now = 0.0
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), frameRate: 60, now: { now })
        var countdown = Countdown(seconds: 0.5)
        var finished: [Int] = []
        var wasFinished = false
        for frame in 1...200 {
            now += jitter(frame)
            timing.advance()
            if restarts.contains(frame) {
                countdown.restart(at: timing.elapsed)
                wasFinished = false
            }
            let isFinished = countdown.isFinished(at: timing.elapsed)
            if isFinished, !wasFinished { finished.append(frame) }
            wasFinished = isFinished
        }
        return finished
    }

    @Test("同じ入力で 2 回走らせると、同じ枚で終わる")
    func theSameInputsFinishOnTheSameFrames() {
        let restarts: Set<Int> = [40, 75, 150]
        let steady = finishingFrames(restartsAt: restarts) { _ in 1.0 / 60 }
        let jittery = finishingFrames(restartsAt: restarts) { frame in
            frame % 9 == 0 ? 0.07 : 0.009 + Double(frame % 4) * 0.003
        }
        #expect(steady == [30, 70, 105, 180])
        #expect(steady == jittery)
    }

    // MARK: - 完了条件 5

    @Test("nonisolated な文脈から作れ、JSON で往復しても同じ値に戻る")
    nonisolated func roundTripsThroughJSONFromNonisolatedCode() throws {
        let countdown = Countdown(seconds: 1)
        let data = try JSONEncoder().encode(countdown)
        let decoded = try JSONDecoder().decode(Countdown.self, from: data)
        #expect(decoded == countdown)
        let sendable: any Sendable = countdown
        #expect(sendable is Countdown)
    }

    @Test("数え直した位置も JSON で往復する")
    func restartedPositionRoundTrips() throws {
        let (timing, pass) = framesClock()
        for _ in 0..<20 { pass(0.016); timing.advance() }
        var countdown = Countdown(seconds: 1)
        countdown.restart(at: timing.elapsed)
        let decoded = try JSONDecoder().decode(
            Countdown.self, from: JSONEncoder().encode(countdown))
        for _ in 0..<30 { timing.advance() }
        #expect(decoded.remaining(at: timing.elapsed) == countdown.remaining(at: timing.elapsed))
        #expect(abs(decoded.remaining(at: timing.elapsed) - 0.5) < 1e-6)
    }

    // MARK: - 境界

    @Test("0 秒は最初から終わっている。数でない値・負の値は 0 秒として受け取る")
    func invalidLengthsBecomeZero() {
        let start = 0.0
        #expect(Countdown(seconds: 0).isFinished(at: start))
        #expect(Countdown(seconds: Float.nan).isFinished(at: start))
        #expect(Countdown(seconds: -3).remaining(at: start) == 0)
        #expect(Countdown(seconds: Float.infinity).isFinished(at: start))
        #expect(!Countdown(seconds: 0.25).isFinished(at: start))
        #expect(Countdown(seconds: 0.25).remaining(at: start) == 0.25)
    }

    @Test("走っていないところで読むと、長さそのものと false を返す")
    func readingOutsideARunFallsBack() {
        let countdown = Countdown(seconds: 2)
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            #expect(countdown.remaining == 2)
            #expect(!countdown.isFinished)
        }
        #expect(log.messageForRead(of: "Countdown.remaining") != nil)
    }

    @Test("実時間の時計では、足した秒だけ減る")
    func theWallClockCountsSeconds() {
        var now = 10.0
        let timing = FrameTiming(clock: .wallClock, frameRate: 60, now: { now })
        let countdown = Countdown(seconds: 1)
        // 最初の枚は 1 フレームぶん、以後は実際に流れた秒
        timing.advance()
        for _ in 0..<4 {
            now += 0.1
            timing.advance()
        }
        #expect(abs(countdown.remaining(at: timing.elapsed) - Float(1 - 1.0 / 60 - 0.4)) < 1e-5)
    }
}

/// 走っているスケッチの中で `Countdown` を読む (#2602)。GPU を要する。
@Suite(
    "Countdown (スケッチから)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SketchCountdownTests {
    final class Waiting: Sketch {
        var settings = SketchSettings(width: 8, height: 4)
        var respawn = Countdown(seconds: 1)
        var restartAt: Int?
        var finished: [Bool] = []
        var remaining: [Float] = []
        init() {}
        func draw() {
            background(0)
            if frameCount == restartAt { respawn.restart() }
            finished.append(respawn.isFinished)
            remaining.append(respawn.remaining)
        }
    }

    @Test("プロパティの初期値で作った 1 秒は、60 枚目の draw() で終わる")
    func aPropertyCountdownEndsOnTheSixtiethFrame() throws {
        let sketch = Waiting()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60))
        for _ in 0..<61 { try runtime.advance() }
        #expect(sketch.finished[0..<59].allSatisfy { !$0 })
        #expect(sketch.finished[59])
        #expect(sketch.remaining[59] == 0)
    }

    @Test("draw() の中の restart() は、その枚から数え直す")
    func restartInsideDrawCountsFromThatFrame() throws {
        let sketch = Waiting()
        sketch.restartAt = 70
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60))
        for _ in 0..<131 { try runtime.advance() }
        #expect(sketch.finished[68], "数え直す前は終わっている")
        #expect(!sketch.finished[69], "数え直した枚は終わっていない")
        #expect(!sketch.finished[128])
        #expect(sketch.finished[129], "数え直してから 60 枚目で終わる")
    }
}
