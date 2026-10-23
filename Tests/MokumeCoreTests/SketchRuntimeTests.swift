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

    @Test("実時間の時計は、最初の枚から実際に流れた時間を返す")
    func wallClockReportsElapsedTime() {
        let clock = ManualClock(100)
        let timing = FrameTiming(clock: .wallClock, now: clock.provider)
        clock.now = 100
        timing.advance()
        // 上限 (目標フレーム間隔の 10 倍) に当たらない範囲で見る。当たったときの
        // 振る舞いは「止めていた時間は上限で頭打ちになる」が別に固定している
        clock.now = 100.1
        timing.advance()
        #expect(abs(timing.time - 0.1) < 1e-5)
        #expect(abs(timing.deltaTime - 0.1) < 1e-5)
    }

    /// **最初の枚は、時計によらず `time == 0`・経過は目標の 1 フレームぶん** (`Sketch.time` の
    /// 説明・[#2413](https://github.com/mokume-metal/mokume/issues/2413))。時計を作ってから
    /// 最初の枚までの間 (アプリの起動・窓・`setup()`) は乗らない。
    @Test("実時間の時計でも、時計を作ってから最初の枚までの長さは time にも経過にも乗らない", arguments: [0.1, 2.0, 600.0])
    func wallClockStartsAtTheFirstFrame(gap: Double) {
        let clock = ManualClock(100)
        let timing = FrameTiming(clock: .wallClock, frameRate: 60, now: clock.provider)
        clock.now = 100 + gap
        timing.advance()
        #expect(timing.time == 0)
        #expect(timing.deltaTime == Float(1.0 / 60))

        // 2 枚目からは、前の枚からの実際の経過 (上限に当たらない幅)
        clock.now = 100 + gap + 0.02
        timing.advance()
        #expect(abs(Double(timing.time) - 0.02) < 1e-5)
        #expect(abs(timing.deltaTime - 0.02) < 1e-5)
    }

    /// 時刻を指定した観測が最初の枚に当たっても、作者の時計はその枚を起点に進む
    /// ([#2328](https://github.com/mokume-metal/mokume/issues/2328) の帳簿)。2 枚目は
    /// 指定秒や起動からの経過ではなく、最初の枚からの実経過になる。
    @Test("時刻を指定した観測が最初の枚に当たっても、2 枚目は最初の枚からの実経過で始まる")
    func anObservedFirstFrameStillStartsTheAuthorsClock() {
        let clock = ManualClock(100)
        let timing = FrameTiming(clock: .wallClock, frameRate: 60, now: clock.provider)
        clock.now = 102
        timing.advance(at: 5)
        #expect(timing.time == 5)
        #expect(timing.deltaTime == 0)

        clock.now = 102 + 1.0 / 60
        timing.advance()
        #expect(abs(Double(timing.time) - 1.0 / 60) < 1e-5)
        #expect(abs(Double(timing.deltaTime) - 1.0 / 60) < 1e-5)
    }

    /// **寄せ直せない止まり方がある。** ディスプレイのスリープや駆動源の停止は
    /// `pause()` を通らないので ``FrameTiming/resync()`` が呼ばれない
    /// ([#874](https://github.com/mokume-metal/mokume/issues/874))。上限が無いと、
    /// 止まっていた時間まるごとが 1 枚に乗って積分する側が吹き飛ぶ。
    @Test("寄せ直せなくても、止めていた時間は上限で頭打ちになる")
    func theGapIsCappedEvenWithoutResync() {
        let clock = ManualClock(0)
        let cap = FrameTiming.maximumDeltaTime(frameRate: 60)
        let timing = FrameTiming(clock: .wallClock, frameRate: 60, now: clock.provider)
        timing.advance()
        // 10 秒止めてから再開した、を寄せ直さずに再現する
        clock.now = 10.016
        timing.advance()
        #expect(timing.deltaTime <= Float(cap))
        // **時刻のほうは詰めない。** 止まっていた 10 秒は経過として残る
        #expect(abs(timing.time - 10.016) < 1e-2)
    }

    /// 複数の実行を揃えるときに合うのは ``FrameTiming/time`` である ([ADR-0025])。
    /// **止まった長さによらず追いつく**ことを固定する — 追いつかない実装にすると、
    /// 端末ごとにフレーム落ちの起き方が違うだけで位相がずれる。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    @Test("どれだけ止まっても、実時間の時刻は追いつく", arguments: [0.5, 10.0, 600.0])
    func wallClockCatchesUpAfterAnyStall(gap: Double) {
        let clock = ManualClock(0)
        let timing = FrameTiming(clock: .wallClock, now: clock.provider)
        timing.advance()
        clock.now = gap
        timing.advance()
        #expect(abs(Double(timing.time) - gap) < 1e-2)
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

    /// 作者が止めていたところから描く 1 枚 ([#1366](https://github.com/mokume-metal/mokume/issues/1366))。
    /// 寄せ直してすぐ描くと経過がほぼ 0 になり、`deltaTime` で動かすものが進まない。
    @Test("止めていたところから描く 1 枚は、実時間の時計でも目標の 1 フレームぶん進み、時刻は実時間のまま")
    func stepAfterStopReportsOneTargetFrame() {
        let clock = ManualClock(0)
        let timing = FrameTiming(clock: .wallClock, frameRate: 30, now: clock.provider)
        timing.advance()

        clock.now = 7
        timing.stepOneFrameNext()
        timing.advance()
        #expect(timing.deltaTime == 1 / Float(30))
        #expect(timing.time == 7)

        // **効くのは 1 枚だけ。** 次からは実際に流れた時間に戻る
        clock.now = 7.02
        timing.advance()
        #expect(abs(timing.deltaTime - 0.02) < 1e-5)
    }

    @Test("フレーム番号から導く時計では、止めていたところから描く 1 枚も時計の刻みのまま")
    func stepLeavesTheFrameIndexClockAlone() {
        let clock = ManualClock(0)
        // 時計の刻み (24) と目標 (60) を違えておく。印が目標の側で上書きすると 1/60 になる
        let timing = FrameTiming(clock: .frameIndex(frameRate: 24), frameRate: 60, now: clock.provider)
        timing.advance()
        clock.now = 7
        timing.stepOneFrameNext()
        timing.advance()
        #expect(timing.deltaTime == Float(1.0 / 24))
        #expect(timing.time == Float(1.0 / 24))
    }

    @Test("時間が巻き戻っても経過は負にならない")
    func timeGoingBackwardsDoesNotProduceNegativeDelta() {
        let clock = ManualClock(100)
        let timing = FrameTiming(clock: .wallClock, now: clock.provider)
        timing.advance()
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
            background(.linear(red: 0, green: 0, blue: 0))
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

    /// `Sketch.time` の説明「最初のフレームは 0」は時計によらない
    /// ([#2413](https://github.com/mokume-metal/mokume/issues/2413))。窓の実時間の時計では、
    /// ランタイムを作ってから最初の枚までにアプリの起動・窓の作成・`setup()` が挟まる。
    @Test("実時間の時計でも、setup() にかかった時間は最初の枚の time にも deltaTime にも乗らない")
    func setupTimeIsNotCountedOnTheWallClock() throws {
        /// `setup()` で時計を 2 秒進め (重い準備の代わり)、描いた枚の時刻と経過を控える。
        final class SlowSetup: Sketch {
            var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
            var onSetup: () -> Void = {}
            var seen: [(time: Float, delta: Float)] = []
            init() {}
            func setup() { onSetup() }
            func draw() {
                seen.append((time, deltaTime))
                background(.linear(red: 0, green: 0, blue: 0))
            }
        }

        let clock = FrameTimingTests.ManualClock(100)
        let sketch = SlowSetup()
        sketch.onSetup = { clock.now += 2 }
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .wallClock, now: clock.provider)
        try runtime.advance()
        clock.now += 0.02
        try runtime.advance()

        try #require(sketch.seen.count == 2)
        // 変更前は 2.0 と上限 (60 fps で 1/6 秒)
        #expect(sketch.seen[0].time == 0)
        #expect(sketch.seen[0].delta == Float(1.0 / 60))
        // 2 枚目からは、前の枚からの実際の経過
        #expect(abs(sketch.seen[1].time - 0.02) < 1e-5)
        #expect(abs(sketch.seen[1].delta - 0.02) < 1e-5)
    }

    /// `setup()` で時計を 2 秒進め、描いた枚の時刻と経過を控えるスケッチ ([#2390])。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    private final class SlowSetupSketch: Sketch {
        var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
        var onSetup: () -> Void = {}
        var seen: [(time: Float, delta: Float)] = []
        init() {}
        func setup() { onSetup() }
        func draw() {
            seen.append((time, deltaTime))
            background(.linear(red: 0, green: 0, blue: 0))
        }
    }

    /// **#2413 の約束は、表示の予定の時刻で進むときにも守る** ([#2390])。窓の経路では、予定の時刻は
    /// コールバックの時点で決まり (`setup()` の前)、`setup()` は最初の枚の `advance` の中で走る。
    /// 予定の時刻を起点にすると、`setup()` にかかった時間が 2 枚目の `time`・`deltaTime` に戻る。
    /// **実際の順** — 予定の時刻 → `setup()` が 2 秒 → 進める — で通す。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    @Test("表示の予定の時刻で進めても、setup() にかかった時間は 2 枚目の time にも deltaTime にも戻らない")
    func setupTimeIsNotCountedWhenAdvancingByTheDisplayTime() throws {
        let step = 1.0 / 60
        let clock = FrameTimingTests.ManualClock(100)
        let sketch = SlowSetupSketch()
        sketch.onSetup = { clock.now += 2 }
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .wallClock, now: clock.provider)
        // 1 枚目のコールバックが 100 秒に来て、予定の時刻は 1 刻み先。`setup()` はこの後に 2 秒かかる
        try runtime.advance(displayTime: 100 + step)
        // 2 枚目のコールバックは `setup()` と 1 枚目を描き終えた後 (102.005 秒)。予定の時刻は次の刻みの 1 つ先
        clock.now = 102.005
        try runtime.advance(displayTime: 102 + 2 * step)

        try #require(sketch.seen.count == 2)
        #expect(sketch.seen[0].time == 0)
        #expect(sketch.seen[0].delta == Float(step))
        // 変更前 (予定の時刻を起点にしていた) は time ≈ 2.03・deltaTime は上限 (1/6)
        #expect(sketch.seen[1].time < Float(3 * step), "setup() の 2 秒が 2 枚目の time に戻った")
        #expect(sketch.seen[1].delta < Float(3 * step), "setup() の 2 秒が 2 枚目の deltaTime に戻った")
        #expect(sketch.seen[1].time > 0)
    }

    /// 先に `start()` を呼ぶ使い方 (公開の `start()`・時刻を指定した観測) も同じ。予定の時刻は
    /// `start()` の前に決まっている。
    @Test("先に start() を呼んだ後に、古い予定の時刻で進めても、setup() にかかった時間は戻らない")
    func setupTimeIsNotCountedWhenStartedBeforeTheDisplayTime() throws {
        let step = 1.0 / 60
        let clock = FrameTimingTests.ManualClock(100)
        let sketch = SlowSetupSketch()
        sketch.onSetup = { clock.now += 2 }
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .wallClock, now: clock.provider)
        runtime.start()
        // 予定の時刻は `start()` より前に決まっていた (100 秒のコールバック)
        try runtime.advance(displayTime: 100 + step)
        clock.now = 102.005
        try runtime.advance(displayTime: 102 + 2 * step)

        try #require(sketch.seen.count == 2)
        #expect(sketch.seen[0].time == 0)
        #expect(sketch.seen[1].time < Float(3 * step))
        #expect(sketch.seen[1].delta < Float(3 * step))
    }

    /// **いまの振る舞いを固定するだけ** (直さない)。最初の枚の起点は描き始め (`advance`) なので、
    /// 最初のフレームの中で使った時間 — 最初の `draw()` の重い準備、`setup()` で置いて最初の
    /// フレームへ持ち越した図形・画素を組む時間 — は、ほかのフレームと同じく 2 枚目の経過に乗る
    /// (上限まで)。[#2413](https://github.com/mokume-metal/mokume/issues/2413) が寄せたのは
    /// `setup()` の中で済む計算までである。
    @Test("実時間の時計で、最初の draw() にかかった時間は 2 枚目の time と deltaTime に乗る (deltaTime は上限まで)")
    func firstDrawTimeLandsOnTheSecondFrame() throws {
        /// 最初の `draw()` で時計を 0.5 秒進め (重い準備の代わり)、描いた枚の時刻と経過を控える。
        final class HeavyFirstDraw: Sketch {
            var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
            var onFirstDraw: () -> Void = {}
            var seen: [(time: Float, delta: Float)] = []
            init() {}
            func draw() {
                seen.append((time, deltaTime))
                if frameCount == 1 { onFirstDraw() }
                background(.linear(red: 0, green: 0, blue: 0))
            }
        }

        let clock = FrameTimingTests.ManualClock(100)
        let sketch = HeavyFirstDraw()
        sketch.onFirstDraw = { clock.now += 0.5 }
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .wallClock, now: clock.provider)
        try runtime.advance()
        try runtime.advance()

        try #require(sketch.seen.count == 2)
        #expect(sketch.seen[0].time == 0)
        #expect(sketch.seen[0].delta == Float(1.0 / 60))
        // 2 枚目の時刻は最初の draw() の 0.5 秒ごと進み、経過は上限 (60 fps で 1/6 秒) で頭打ち
        #expect(abs(sketch.seen[1].time - 0.5) < 1e-5)
        #expect(sketch.seen[1].delta == Float(FrameTiming.maximumDeltaTime(frameRate: 60)))
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
                background(.linear(red: 0, green: 0, blue: 0))
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
