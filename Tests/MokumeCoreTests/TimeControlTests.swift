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
        // 起点は最初の枚 (100.5 秒)
        #expect(timing.time == 1)

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
        timing.advance()
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

    // MARK: - 観測の枚でも、作者の時計は観測の秒に触れられない (#2328)

    @Test("観測の枚で止めると、観測の秒ではなく作者の時計のその枚の秒で止まる")
    func pausingOnAnObservedFrameHoldsTheAuthorsSecond() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(timing, 3)
        timing.advance(at: 5)
        #expect(timing.time == 5)
        timing.pauseTime()
        let held = run(timing, 4)
        #expect(held.map(\.0) == Array(repeating: Float(3.0 / 60), count: 4))
        #expect(held.map(\.1) == [0, 0, 0, 0])
    }

    @Test("実時間の時計でも、観測の枚で止めると、飛んだぶんを含む作者の時計のその枚の秒で止まる")
    func theWallClockPausesOnTheAuthorsSecondWhenObserved() {
        var clock = 100.0
        let timing = FrameTiming(clock: .wallClock, now: { clock })
        clock += 0.125
        timing.advance()
        // 原点のずれを 0 でなくしておく (作者の時計 = 起動からの経過 + ずれ)
        timing.jumpTime(10)
        clock += 0.125
        timing.advance()
        #expect(timing.time == 10)
        clock += 0.125
        timing.advance(at: 5)
        #expect(timing.time == 5)
        timing.pauseTime()
        for _ in 0..<3 {
            clock += 0.125
            timing.advance()
            #expect(timing.time == 10.125, "観測の枚の作者の時計 (0.375 + ずれ 9.75) で止まる")
            #expect(timing.deltaTime == 0)
        }
    }

    @Test("観測の枚で飛ぶと次の枚はその秒になり、飛んでから止めればその秒で止まる")
    func jumpingOnAnObservedFrameStillLands() {
        let jumped = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(jumped, 3)
        jumped.advance(at: 5)
        jumped.jumpTime(2)
        jumped.advance()
        #expect(jumped.time == 2)
        #expect(jumped.deltaTime == 0)

        let paused = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(paused, 3)
        paused.advance(at: 5)
        paused.jumpTime(2)
        paused.pauseTime()
        #expect(run(paused, 3).map(\.0) == [2, 2, 2])
    }

    @Test("陰性対照: 観測の枚で止めなければ、次の枚は作者の時計へ戻る")
    func anObservedFrameReturnsToTheAuthorsClock() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(timing, 3)
        timing.advance(at: 5)
        #expect(timing.deltaTime == 0)
        let after = run(timing, 4)
        #expect(after.map(\.0) == (4..<8).map { Float(Double($0) / 60) })
        #expect(after.map(\.1) == Array(repeating: Float(step), count: 4))
    }

    @Test("止めている間の観測の枚で再開してすぐ止め直すと、観測でない枚と同じく止めていた秒のまま")
    func repausingOnAnObservedFrameKeepsTheHeldSecond() {
        // 観測でない枚で同じ順に呼ぶと、止めていた秒のまま (比べる元)
        let unobserved = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(unobserved, 5)
        unobserved.pauseTime()
        _ = run(unobserved, 3)
        unobserved.playTime()
        unobserved.pauseTime()
        #expect(run(unobserved, 3).map(\.0) == Array(repeating: Float(4.0 / 60), count: 3))

        let observed = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        _ = run(observed, 5)
        observed.pauseTime()
        _ = run(observed, 2)
        observed.advance(at: 5)
        observed.playTime()
        observed.pauseTime()
        #expect(run(observed, 3).map(\.0) == Array(repeating: Float(4.0 / 60), count: 3))
    }

    /// 観測の枚は見せる時刻と経過だけを指定秒にし、作者の時計の帳簿 (飛び先の着地・止めている
    /// 間の寄せ直し) は観測が無い枚と同じに進める。`observing` で観測の有無を切り替えて、同じ
    /// 口の呼び方での後の枚を返す。
    private func authorsClockAround(
        observing: Bool, _ script: (FrameTiming, _ observe: () -> Void) -> [(Float, Float)]
    ) -> [(Float, Float)] {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        return script(timing) {
            timing.advance(at: observing ? 5 : nil)
            if observing {
                #expect(timing.time == 5)
                #expect(timing.deltaTime == 0)
            }
        }
    }

    @Test("前の枚で頼んだ飛び先が観測の枚をまたいでも、観測の後は観測が無いときと同じ作者の時計")
    func aJumpAcrossAnObservedFrameKeepsTheAuthorsClock() {
        func after(observing: Bool) -> [(Float, Float)] {
            authorsClockAround(observing: observing) { timing, observe in
                _ = run(timing, 3)
                timing.jumpTime(2)  // 4 枚目に着地する
                observe()  // 4 枚目
                return run(timing, 2).map { ($0.0, $0.1) }  // 5・6 枚目
            }
        }
        let observed = after(observing: true)
        let unobserved = after(observing: false)
        #expect(observed.map(\.0) == unobserved.map(\.0), "観測あり \(observed) / なし \(unobserved)")
        #expect(observed.map(\.1) == [Float(step), Float(step)], "観測の後に経過 0 の枚が増えない")
        #expect(abs(Double(observed[0].0) - (2 + step)) < 1e-6)
        #expect(abs(Double(observed[1].0) - (2 + 2 * step)) < 1e-6)
    }

    @Test("止めている間の観測の枚で再開すると、観測が無いときと同じく止めた秒 + 1 枚ぶんから進む")
    func resumingOnAnObservedFrameKeepsTheAuthorsClock() {
        func after(observing: Bool) -> [(Float, Float)] {
            authorsClockAround(observing: observing) { timing, observe in
                _ = run(timing, 5)
                timing.pauseTime()  // 4/60 で止まる
                _ = run(timing, 2)  // 6・7 枚目
                observe()  // 8 枚目
                timing.playTime()
                return run(timing, 2).map { ($0.0, $0.1) }  // 9・10 枚目
            }
        }
        let observed = after(observing: true)
        let unobserved = after(observing: false)
        #expect(observed.map(\.0) == unobserved.map(\.0), "観測あり \(observed) / なし \(unobserved)")
        #expect(abs(Double(observed[0].0) - 5.0 / 60) < 1e-6, "再開した枚が \(observed[0].0)")
        #expect(observed.map(\.1) == [Float(step), Float(step)])
    }

    @Test("実時間の時計でも、観測の枚をまたぐ飛び先と観測の枚での再開は、観測が無いときと同じ作者の時計")
    func theWallClockKeepsTheAuthorsBooksOnObservedFrames() {
        // 1 枚ずつ 0.125 秒進める (60 fps の経過の上限 1/6 秒に当たらない幅)
        func tick(_ timing: FrameTiming, _ advance: () -> Void) -> (Float, Float) {
            advance()
            return (timing.time, timing.deltaTime)
        }
        func jumped(observing: Bool) -> [(Float, Float)] {
            var now = 100.0
            let timing = FrameTiming(clock: .wallClock, now: { now })
            now += 0.125
            timing.advance()
            timing.jumpTime(10)
            now += 0.125
            timing.advance(at: observing ? 5 : nil)  // 飛び先が着地する枚
            return (0..<2).map { _ in
                tick(timing) {
                    now += 0.125
                    timing.advance()
                }
            }
        }
        let jumpObserved = jumped(observing: true)
        #expect(jumpObserved.map(\.0) == jumped(observing: false).map(\.0))
        #expect(jumpObserved.map(\.0) == [10.125, 10.25])
        #expect(jumpObserved.map(\.1) == [0.125, 0.125])

        func resumed(observing: Bool) -> [(Float, Float)] {
            var now = 100.0
            let timing = FrameTiming(clock: .wallClock, now: { now })
            for _ in 0..<2 {
                now += 0.125
                timing.advance()
            }
            timing.pauseTime()  // 起点は最初の枚なので、0.125 秒で止まる
            for _ in 0..<2 {
                now += 0.125
                timing.advance()
            }
            now += 0.125
            timing.advance(at: observing ? 5 : nil)
            if observing { #expect(timing.deltaTime == 0, "観測の枚の経過は 0") }
            timing.playTime()
            return (0..<2).map { _ in
                tick(timing) {
                    now += 0.125
                    timing.advance()
                }
            }
        }
        let resumeObserved = resumed(observing: true)
        #expect(resumeObserved.map(\.0) == resumed(observing: false).map(\.0))
        #expect(resumeObserved.map(\.0) == [0.25, 0.375])
        #expect(resumeObserved.map(\.1) == [0.125, 0.125])
    }

    @Test("口を使わなければ、時刻は口が入る前と同じ値")
    func untouchedClocksKeepTheirValues() {
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        let times = run(timing, 120).map(\.0)
        #expect(times == (0..<120).map { Float(Double($0) / 60) })
    }

    // MARK: - 数でない秒へは飛ばない (#2327)

    /// 時刻として受け取れない飛び先。`Float` から `Double` へ移しても非有限のまま届く。
    private let nonFiniteTargets: [Double] = [.nan, .infinity, -.infinity]

    @Test("数でない秒・無限へ飛ぼうとしても、時刻は口を呼ばなかったときと同じ列で進む")
    func aNonFiniteJumpLeavesTheClockAlone() {
        for target in nonFiniteTargets {
            let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 }, warn: { _ in })
            _ = run(timing, 2)
            timing.jumpTime(target)
            let after = run(timing, 6)
            #expect(after.map(\.0) == (2..<8).map { Float(Double($0) / 60) }, "jumpTime(\(target))")
            #expect(after.map(\.1) == Array(repeating: Float(step), count: 6), "jumpTime(\(target))")
        }
    }

    @Test("止めている間に数でない秒へ飛ぼうとしても、止めた秒のまま動かない")
    func aNonFiniteJumpWhilePausedKeepsTheHeldSecond() {
        for target in nonFiniteTargets {
            let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 }, warn: { _ in })
            _ = run(timing, 5)
            timing.pauseTime()
            _ = run(timing, 2)
            timing.jumpTime(target)
            #expect(
                run(timing, 3).map(\.0) == Array(repeating: Float(4.0 / 60), count: 3),
                "jumpTime(\(target))")
            // 再開すれば、止めた秒から元の刻みで進む
            timing.playTime()
            timing.advance()
            #expect(abs(Double(timing.time) - (4.0 / 60 + step)) < 1e-6, "jumpTime(\(target))")
        }
    }

    @Test("同じ枚で先に頼んだ飛び先は、後の数でない秒に取り消されない")
    func aNonFiniteJumpDoesNotCancelAnEarlierOne() {
        for target in nonFiniteTargets {
            let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 }, warn: { _ in })
            _ = run(timing, 3)
            timing.jumpTime(2)
            timing.jumpTime(target)
            timing.advance()
            #expect(timing.time == 2, "jumpTime(\(target))")
            #expect(timing.deltaTime == 0, "jumpTime(\(target))")
        }
    }

    @Test("数でない秒は 1 度だけ知らせ、文面は口の名前と渡した値を名乗る")
    func aNonFiniteJumpIsNoticedOnce() {
        var notices: [String] = []
        let timing = FrameTiming(
            clock: .frameIndex(frameRate: 60), now: { 0 }, warn: { notices.append($0) })
        _ = run(timing, 1)
        timing.jumpTime(.nan)
        timing.jumpTime(.infinity)
        _ = run(timing, 1)
        timing.jumpTime(-.infinity)
        _ = run(timing, 1)
        #expect(notices == ["jumpTime(): nan is not a time, so the time does not jump"])
    }

    @Test("陰性対照: 有限の秒は、負でも単精度の最大でも受けて、知らせない")
    func finiteJumpsAreTakenWithoutNotice() {
        var notices: [String] = []
        let timing = FrameTiming(
            clock: .frameIndex(frameRate: 60), now: { 0 }, warn: { notices.append($0) })
        _ = run(timing, 2)
        timing.jumpTime(-1)
        let negative = run(timing, 3).map(\.0)
        #expect(negative[0] == -1)
        #expect(abs(Double(negative[2]) - (-1 + 2 * step)) < 1e-6, "負の秒から元の刻みで進む: \(negative)")

        // 1/60 秒は単精度の最大の刻みより遥かに小さいので、進んでも同じ値に丸まる
        timing.jumpTime(Double(Float.greatestFiniteMagnitude))
        #expect(run(timing, 3).map(\.0) == Array(repeating: .greatestFiniteMagnitude, count: 3))
        #expect(notices.isEmpty)
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
