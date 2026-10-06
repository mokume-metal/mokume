// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 作者が時刻を止める・再開する・飛ぶ ([#1286](https://github.com/mokume-metal/mokume/issues/1286))。
/// 時計 (`FrameTiming`) を直に回すので、GPU を要さない。
@Suite("作者が時刻を止める・飛ぶ")
struct TimeControlTests {
    private let step = 1.0 / 60

    /// `.frameIndex(60)` の時計を `count` 枚進め、各枚の (time, deltaTime, frameCount) を返す。
    private func run(_ timing: FrameTiming, _ count: Int) -> [(Float, Float, Int)] {
        (0..<count).map { _ in
            timing.advance()
            return (timing.time, timing.deltaTime, timing.frameCount)
        }
    }

    @Test("止めた間の枚は止めた秒のまま経過 0 で、再開した次の枚は止めた秒 + 1/60")
    func pausingHoldsTheTimeAndResumesFromIt() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(timing, 30)
        let held = timing.time
        #expect(held == Float(29.0 / 60))

        timing.pauseTime()
        let paused = run(timing, 10)
        #expect(paused.map(\.0) == Array(repeating: held, count: 10))
        #expect(paused.map(\.1) == Array(repeating: 0, count: 10))
        #expect(paused.map(\.2) == Array(31...40), "止めてもフレームは 1 枚ずつ進む")

        timing.playTime()
        timing.advance()
        #expect(abs(Double(timing.time) - (29.0 / 60 + step)) < 1e-6, "再開した枚が \(timing.time)")
        #expect(timing.deltaTime == Float(step))
    }

    @Test("止めたまま二度止めても、止めた秒は動かない")
    func pausingTwiceKeepsTheFirstSecond() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(timing, 5)
        timing.pauseTime()
        _ = run(timing, 3)
        timing.pauseTime()
        _ = run(timing, 3)
        #expect(timing.time == Float(4.0 / 60))
    }

    @Test("飛んだ枚は指定の秒で経過 0、次の枚からそこから元の刻みで進む")
    func jumpingLandsOnTheSecondThenTicksOn() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(timing, 10)
        timing.jumpTime(5)
        timing.advance()
        #expect(timing.time == 5)
        #expect(timing.deltaTime == 0)
        timing.advance()
        #expect(abs(Double(timing.time) - (5 + step)) < 1e-6)
        #expect(timing.deltaTime == Float(step))
        // 後ろへも飛べる
        timing.jumpTime(-1)
        timing.advance()
        #expect(timing.time == -1)
    }

    @Test("実時間の時計でも、飛んだ先から実時間の経過ぶんだけ進み、起動からの経過へ跳ね戻らない")
    func theWallClockFollowsTheJumpToo() {
        var clock = 100.0
        let timing = FrameTiming(clock: .wallClock, now: { clock })
        for _ in 0..<3 {
            clock += 0.5
            timing.advance()
        }
        #expect(timing.time == 1.5)

        timing.jumpTime(10)
        clock += 0.5
        timing.advance()
        #expect(timing.time == 10)
        #expect(timing.deltaTime == 0)
        // 経過の上限 (60 fps で 1/6 秒) に当たらない幅で進める
        clock += 0.125
        timing.advance()
        #expect(timing.time == 10.125)
        #expect(timing.deltaTime == 0.125)
    }

    @Test("実時間の時計で長く止めても、再開した枚は止めた秒 + 1 枚ぶんで、止めていた間は乗らない")
    func theWallClockResumesWhereItPaused() {
        var clock = 0.0
        let timing = FrameTiming(clock: .wallClock, now: { clock })
        clock = 2
        timing.advance()
        timing.pauseTime()
        for _ in 0..<5 {
            clock += 0.1
            timing.advance()
            #expect(timing.time == 2)
            #expect(timing.deltaTime == 0)
        }
        timing.playTime()
        clock += 0.1
        timing.advance()
        #expect(abs(timing.time - 2.1) < 1e-5, "再開した枚が \(timing.time)")
        #expect(abs(timing.deltaTime - 0.1) < 1e-5)
    }

    @Test("止めている間に飛ぶと、その秒で止まり続ける。同じ枚で飛んでから止めても同じ")
    func jumpingWhilePausedHoldsTheNewSecond() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(timing, 5)
        timing.pauseTime()
        timing.jumpTime(3)
        #expect(run(timing, 3).map(\.0) == [3, 3, 3])

        timing.playTime()
        timing.jumpTime(7)
        timing.pauseTime()
        #expect(run(timing, 3).map(\.0) == [7, 7, 7])
    }

    @Test("観測の指定秒で撮った後は、止めた秒へ戻る")
    func anObservationDoesNotMoveTheHeldSecond() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(timing, 5)
        timing.pauseTime()
        timing.advance(at: 42)
        #expect(timing.time == 42)
        timing.advance()
        #expect(timing.time == Float(4.0 / 60))
    }

    @Test("口を使わなければ、時刻は口が入る前と同じ値")
    func untouchedClocksKeepTheirValues() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        let times = run(timing, 120).map(\.0)
        #expect(times == (0..<120).map { Float(Double($0) / 60) })
    }
}

/// 作者の口が時計まで届くこと。GPU を要する。
@Suite(
    "作者が時刻を止める・飛ぶ (スケッチから)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchTimeControlTests {
    final class Scrub: Sketch {
        var settings = SketchSettings(width: 8, height: 4)
        /// フレーム番号ごとに呼ぶもの。
        var at: [Int: (Scrub) -> Void] = [:]
        var times: [Float] = []
        var deltas: [Float] = []

        init() {}
        func draw() {
            times.append(time)
            deltas.append(deltaTime)
            background(0)
            at[frameCount]?(self)
        }
    }

    @Test("draw() から止める・飛ぶ・再開すると、次のフレームから効く")
    func theSketchDrivesTheClock() throws {
        let sketch = Scrub()
        sketch.at = [
            3: { $0.pauseTime() },
            5: { $0.jumpTime(10) },
            7: { $0.playTime() },
        ]
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        for _ in 0..<8 { try runtime.advance() }

        let s = Float(1.0 / 60)
        #expect(sketch.times[0..<4] == [0, s, 2 * s, 2 * s])
        #expect(sketch.times[4] == 2 * s)
        #expect(sketch.times[5..<7] == [10, 10], "止めている間に飛ぶと、そこで止まる")
        #expect(abs(sketch.times[7] - (10 + s)) < 1e-5)
        #expect(sketch.deltas[3..<7] == [0, 0, 0, 0])
        #expect(sketch.deltas[7] == s)
    }

    @Test("呼び出しの外から頼むと、効かない")
    func callsFromOutsideAreIgnored() throws {
        let sketch = Scrub()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        sketch.pauseTime()
        sketch.jumpTime(9)
        try runtime.advance()
        #expect(sketch.times == [0, Float(1.0 / 60)])
    }
}
