// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 作り直しをまたいで作者の時計を渡す (`mokume watch --keep-time`・[#2414])。GPU は要らない。
///
/// **渡す値を作る純関数** (``ClockHandover/Snapshot/start(at:)``) と、**渡された値から始まる ``FrameTiming``** を、
/// 時計を差し替えて確かめる。窓の振る舞い (止めた秒で止まったまま新しい世代が出る) は見張りの実走で見る。
///
/// [#2414]: https://github.com/mokume-metal/mokume/issues/2414
@Suite("作り直しをまたぐ作者の時計")
@MainActor
struct ClockHandoverTests {
    private func snapshot(
        _ seconds: Double, held: Bool = false, realtime: Bool = true, at: Double = 100
    ) -> ClockHandover.Snapshot {
        ClockHandover.Snapshot(seconds: seconds, isHeld: held, isRealtime: realtime, at: at)
    }

    /// 渡された値で始まる時計。書いたものは `written` に集める。
    private func timing(
        _ clock: Clock, inherited: ClockHandover.Snapshot?, now: @escaping () -> Double,
        written: Box? = nil
    ) -> FrameTiming {
        let handover = ClockHandover(inherited: inherited) { written?.values.append($0) }
        return FrameTiming(clock: clock, frameRate: 60, now: now, handover: handover)
    }

    final class Box {
        var values: [ClockHandover.Snapshot] = []
        /// 範囲の外は `nil` (書かれなかった回に落ちずに、期待で赤にする)。
        subscript(index: Int) -> ClockHandover.Snapshot? {
            values.indices.contains(index) ? values[index] : nil
        }
    }

    // MARK: - 純関数

    @Test("止めていれば止めた秒のまま、実時間で止めていなければ書いた後に流れた時間ぶん進め、フレームの時計は外挿しない")
    func startComputesThePredecessorsSecond() {
        #expect(snapshot(8, held: true).start(at: 120) == (8, true))
        #expect(snapshot(8, held: true, realtime: false).start(at: 120) == (8, true))
        let running = snapshot(12.5, at: 100).start(at: 103.6)
        #expect(abs(running.seconds - 16.1) < 1e-9)
        #expect(running.isHeld == false)
        #expect(snapshot(12.5, realtime: false, at: 100).start(at: 103.6) == (12.5, false))
        // 時刻が戻っていても (端末の時計を直した等)、秒は戻さない
        #expect(snapshot(12.5, at: 100).start(at: 90) == (12.5, false))
    }

    @Test("読めないファイル・壊れたファイル・非有限の秒は引き継がない。環境の値は絶対パスだけを受ける")
    func unreadableHandoverIsNotInherited() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-handover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path

        #expect(ClockHandover.read(path: path) == nil, "ファイルが無い")
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(ClockHandover.read(path: path) == nil, "壊れている")
        try Data(#"{"seconds":1e999,"isHeld":false,"isRealtime":true,"at":1}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        #expect(ClockHandover.read(path: path) == nil, "非有限の秒")

        #expect(ClockHandover.path(from: nil) == nil)
        #expect(ClockHandover.path(from: "  ") == nil)
        #expect(ClockHandover.path(from: "relative/clock") == nil)
        #expect(ClockHandover.path(from: " /tmp/clock ") == "/tmp/clock")
    }

    @Test("書いたものを次の世代が同じ値で読める。倍精度の秒は丸めずに運ぶ")
    func writtenSnapshotIsReadBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-handover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path

        // 6 日ぶん回した世代の秒。単精度に落とすと約 15.6 ms の刻みになる (#2415 が避けたもの)
        let seconds = 6 * 86_400 + 1.0 / 60
        let first = ClockHandover(path: path)
        #expect(first.inherited == nil)
        first.publish(snapshot(seconds, held: true, at: 7))
        let next = ClockHandover(path: path)
        #expect(next.inherited == snapshot(seconds, held: true, at: 7))
        #expect(next.inherited?.seconds == seconds, "倍精度のまま")
        #expect(Float(seconds) == Float(seconds + 1.0 / 60), "(確認) 単精度ではこの刻みは区別できない")
    }

    @Test("環境の合図は読んだら消し、渡されていなければ何もしない")
    func startupTakesTheSignalOutOfTheEnvironment() {
        let key = StartupReads.keepTime.key
        var unset: [String] = []
        let none = ClockHandover.startup(environment: [:], unset: { unset.append($0) })
        #expect(none == nil && unset.isEmpty)

        let relative = ClockHandover.startup(environment: [key: "rel"], unset: { unset.append($0) })
        #expect(relative == nil)
        #expect(unset == [key], "絶対パスでなくても、合図は環境から消す")

        unset = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-handover-\(UUID().uuidString)").path
        let given = ClockHandover.startup(environment: [key: directory], unset: { unset.append($0) })
        #expect(given != nil && given?.inherited == nil)
        #expect(unset == [key])
        #expect(StartupReads.all.contains(StartupReads.keepTime))
        #expect(StartupReads.keepTime.origin == .environment)
        #expect(StartupReads.keepTime.decidedBy == .tool)
    }

    // MARK: - 渡された値から始まる時計

    @Test("止めた秒を運ぶ: 最初の枚から time はその秒で止まったまま、deltaTime は 0 (実時間の時計)")
    func aHeldSecondIsCarriedOnTheWallClock() {
        var now = 500.0
        let clock = timing(.wallClock, inherited: snapshot(8, held: true, at: 90), now: { now })
        for _ in 0..<4 {
            now += 1.0 / 60
            clock.advance()
            #expect(clock.time == 8)
            #expect(clock.deltaTime == 0)
        }
        #expect(clock.seconds == 8)
    }

    @Test("止めていなければ続きから進む: 最初の枚の time は前の世代が描いていた秒で、以後は実時間で進む")
    func aRunningSecondContinuesOnTheWallClock() {
        var now = 500.0
        // 前の世代は 100 の時点で 12.5 秒を描いていた。新しい世代の最初の枚は 3.6 秒後
        let clock = timing(.wallClock, inherited: snapshot(12.5, at: 100), now: { now })
        now = 103.6
        clock.advance()
        #expect(abs(clock.seconds - 16.1) < 1e-9, "続きの秒: \(clock.seconds)")
        #expect(abs(Double(clock.deltaTime) - 1.0 / 60) < 1e-6, "最初の枚の deltaTime は目標の 1 フレームぶん")
        now += 1.0 / 60
        clock.advance()
        #expect(abs(clock.seconds - (16.1 + 1.0 / 60)) < 1e-9)
        #expect(abs(Double(clock.deltaTime) - 1.0 / 60) < 1e-6)
    }

    @Test("フレームの時計でも運ぶ: time は引き継いだ秒から 1/fps ずつ進み、frameCount は 1 から数え、最初の deltaTime は 1/fps")
    func theFrameClockContinuesFromTheInheritedSecond() {
        var now = 500.0
        let clock = timing(
            .frameIndex(frameRate: 60), inherited: snapshot(40, realtime: false, at: 3), now: { now })
        var seen: [(Int, Double, Float)] = []
        for _ in 0..<3 {
            now += 0.5
            clock.advance()
            seen.append((clock.frameCount, clock.seconds, clock.deltaTime))
        }
        #expect(seen.map(\.0) == [1, 2, 3], "frameCount は運ばない")
        for (index, row) in seen.enumerated() {
            #expect(abs(row.1 - (40 + Double(index) / 60)) < 1e-9)
            #expect(row.2 == Float(1.0 / 60))
        }
        // 止めた秒は、フレームの時計でも止まったまま
        let held = timing(
            .frameIndex(frameRate: 60), inherited: snapshot(8, held: true, realtime: false), now: { now })
        held.advance()
        held.advance()
        #expect(held.time == 8 && held.deltaTime == 0)
    }

    @Test("引き継いだ後に playTime() すれば止めた秒から進み、pauseTime() すればそこで止まる")
    func theInheritedClockAnswersToPauseAndPlay() {
        var now = 500.0
        let clock = timing(.wallClock, inherited: snapshot(8, held: true), now: { now })
        now += 1.0 / 60
        clock.advance()
        #expect(clock.time == 8)
        clock.playTime()
        now += 1.0 / 60
        clock.advance()
        now += 1.0 / 60
        clock.advance()
        #expect(abs(clock.seconds - (8 + 2.0 / 60)) < 1e-6, "止めた秒から進む: \(clock.seconds)")
        clock.pauseTime()
        let stopped = clock.seconds
        now += 1.0
        clock.advance()
        #expect(clock.seconds == stopped)
    }

    @Test("setup() で作者が頼んだ jumpTime(_:) は、引き継ぎに勝つ")
    func theAuthorsJumpWinsOverTheInheritance() {
        var now = 500.0
        let clock = timing(.wallClock, inherited: snapshot(8, held: true), now: { now })
        clock.jumpTime(2)
        now += 1.0 / 60
        clock.advance()
        #expect(clock.time == 2)
    }

    @Test("引き継がない実行は 0 秒から始まり、何も書かない")
    func withoutHandoverTheClockStartsAtZeroAndWritesNothing() {
        var now = 500.0
        let clock = FrameTiming(clock: .wallClock, frameRate: 60, now: { now })
        now += 3
        clock.advance()
        #expect(clock.time == 0)
        // 引き継ぐものが無い (読めなかった) 実行も、0 秒から始まるが、書き始める
        let written = Box()
        let fresh = timing(.wallClock, inherited: nil, now: { now }, written: written)
        now += 1.0 / 60
        fresh.advance()
        #expect(fresh.time == 0)
        #expect(written.values.count == 1)
    }

    // MARK: - 書く

    @Test("実時間の時計は、変わらない間は書き直さず、止めた・戻した・飛んだとき、しばらく経ったときに書き直す")
    func theWallClockWritesOnlyWhenNeeded() {
        var now = 500.0
        let written = Box()
        let clock = timing(.wallClock, inherited: nil, now: { now }, written: written)
        for _ in 0..<30 {
            now += 1.0 / 60
            clock.advance()
        }
        #expect(written.values.count == 1, "外挿が合っている間は書き直さない: \(written.values.count)")
        #expect(written[0].map { $0.isRealtime && !$0.isHeld } == true)

        // 飛んだ
        clock.jumpTime(50)
        now += 1.0 / 60
        clock.advance()
        #expect(written.values.count == 2)
        #expect(abs((written[1]?.seconds ?? -1) - 50) < 1e-9)

        // 止めた
        clock.pauseTime()
        now += 1.0 / 60
        clock.advance()
        #expect(written.values.count == 3)
        #expect(written[2]?.isHeld == true)
        // 止めている間は、秒が変わらなければ書かない
        for _ in 0..<5 {
            now += 1.0 / 60
            clock.advance()
        }
        #expect(written.values.count == 3)

        // 再開
        clock.playTime()
        now += 1.0 / 60
        clock.advance()
        #expect(written.values.count == 4)
        #expect(written[3]?.isHeld == false)

        // しばらく経ったら、外挿が合っていても書き直す
        now += ClockHandover.refreshInterval + 0.1
        clock.advance()
        #expect(written.values.count == 5)
    }

    @Test("長く回した世代の秒は、引き継いでも書き直しても倍精度のまま (単精度の刻みへ戻らない)")
    func aLongRunningSecondKeepsItsPrecision() {
        var now = 500.0
        let written = Box()
        // 6 日ぶん回した世代。単精度の `time` では 60 fps の刻みが区別できない
        let base = 6.0 * 86_400
        let clock = timing(
            .frameIndex(frameRate: 60), inherited: snapshot(base, realtime: false), now: { now },
            written: written)
        for _ in 0..<5 {
            now += 0.01
            clock.advance()
        }
        #expect(abs(clock.seconds - (base + 4.0 / 60)) < 1e-9)
        #expect(abs((written[4]?.seconds ?? -1) - (base + 4.0 / 60)) < 1e-9)
        #expect(Float(base + 3.0 / 60) == Float(base + 4.0 / 60), "(確認) 単精度の time ではこの刻みは区別できない")
    }

    @Test("フレームの時計は、秒が動くたびに書く。観測の指定秒ではなく作者の時計の秒を書く")
    func theFrameClockWritesEveryFrameWithTheAuthorsSecond() {
        var now = 500.0
        let written = Box()
        let clock = timing(.frameIndex(frameRate: 60), inherited: nil, now: { now }, written: written)
        for _ in 0..<3 {
            now += 0.01
            clock.advance()
        }
        #expect(written.values.count == 3)
        #expect(written.values.allSatisfy { !$0.isRealtime })
        // 観測の指定秒は、見せる time だけを動かし、書くのは作者の時計の秒
        now += 0.01
        clock.advance(at: 99)
        #expect(clock.time == 99)
        #expect(abs((written.values.last?.seconds ?? -1) - 3.0 / 60) < 1e-9)
    }
}

/// 窓の経路の組み立てが、渡された時計を `FrameTiming` まで運ぶこと ([#2414])。GPU を要する。
///
/// [#2414]: https://github.com/mokume-metal/mokume/issues/2414
@Suite(
    "作り直しをまたぐ作者の時計 (ランタイム)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ClockHandoverRuntimeTests {
    final class Probe: Sketch {
        var seen: [Float] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 8, height: 4) }
        func draw() {
            background(0)
            seen.append(time)
        }
    }

    @Test("窓の経路で組んだ実行は、渡された止めた秒から始まり、止まったまま動く")
    func theRuntimeStartsFromTheHandedSecond() throws {
        var now = 500.0
        let handover = ClockHandover(
            inherited: ClockHandover.Snapshot(seconds: 8, isHeld: true, isRealtime: true, at: 90)
        ) { _ in }
        let sketch = Probe()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { now }, onScreen: true,
            handover: handover)
        for _ in 0..<3 {
            now += 1.0 / 60
            try runtime.advance()
        }
        #expect(sketch.seen == [8, 8, 8])
        // 渡さなければ 0 秒から始まる
        let plain = Probe()
        let fresh = try SketchRuntime(
            sketch: plain, gpu: RenderDevice(), clock: nil, now: { now }, onScreen: true)
        now += 1.0 / 60
        try fresh.advance()
        #expect(plain.seen == [0])
    }

    @Test("書き出しの頼みが在れば、渡された時計は使わない")
    func aRenderRequestIgnoresTheHandover() throws {
        let handover = ClockHandover(inherited: nil) { _ in }
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 1, destination: "/tmp/mokume-never-written.mov"))
        #expect(SketchApplication.handover(given: handover, render: request) == nil)
        #expect(SketchApplication.handover(given: handover, render: nil) === handover)
        #expect(SketchApplication.handover(given: nil, render: nil) == nil)
    }
}
