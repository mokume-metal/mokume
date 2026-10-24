// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCore

/// 作り直しをまたいで作者の時計を渡す (`mokume watch --keep-time`・[#2414])。GPU は要らない。
///
/// **渡す値を作る純関数** (``ClockHandover/Snapshot/start(at:writerIsAlive:)``) と、**渡された値から始まる
/// ``FrameTiming``**、**書く側** (``ClockHandover/publish(seconds:isHeld:kind:frames:at:)``・
/// ``ClockHandover/FileSink``) を、時計を差し替えて確かめる。窓の振る舞い (止めた秒で止まったまま新しい世代が出る)
/// は見張りの実走で見る。
///
/// [#2414]: https://github.com/mokume-metal/mokume/issues/2414
@Suite("作り直しをまたぐ作者の時計")
@MainActor
struct ClockHandoverTests {
    private func snapshot(
        _ seconds: Double, held: Bool = false, still: Bool = false, rate: Double? = 1, at: Double = 100,
        writer: Int32 = 4242, generation: Double = 1
    ) -> ClockHandover.Snapshot {
        ClockHandover.Snapshot(
            seconds: seconds, isHeld: held, isStill: still, rate: rate, at: at, writer: writer,
            generation: generation)
    }

    /// 読む順に値を返す箱。最後の値は繰り返す。読んだ回数を数える。
    final class Readings {
        var queue: [ClockHandover.Reading]
        private(set) var count = 0
        init(_ queue: [ClockHandover.Reading]) { self.queue = queue }
        func next() -> ClockHandover.Reading {
            count += 1
            guard !queue.isEmpty else { return .absent }
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }

    final class Box {
        var values: [ClockHandover.Snapshot] = []
        /// 範囲の外は `nil` (書かれなかった回に落ちずに、期待で赤にする)。
        subscript(index: Int) -> ClockHandover.Snapshot? {
            values.indices.contains(index) ? values[index] : nil
        }
    }

    final class Said {
        var lines: [String] = []
    }

    private func handover(
        _ readings: Readings = Readings([]), alive: Bool = true, written: Box? = nil, said: Said? = nil,
        path: String? = "/tmp/mokume-keep-time-test", generation: Double = 5
    ) -> ClockHandover {
        ClockHandover(
            read: { readings.next() }, write: { written?.values.append($0) },
            isAlive: { _ in alive }, warn: { said?.lines.append($0) }, writer: 7, generation: generation,
            path: path)
    }

    private func timing(
        _ clock: Clock, _ handover: ClockHandover?, now: @escaping () -> Double
    ) -> FrameTiming {
        FrameTiming(clock: clock, frameRate: 60, now: now, handover: handover)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-handover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 純関数

    @Test("止めていれば止めた秒のまま、止めていなければ書いた後に流れた時間に進み方を掛けたぶん進め、居ない書き手の間は進めない")
    func startComputesThePredecessorsSecond() {
        #expect(snapshot(8, held: true).start(at: 120) == (8, true))
        #expect(snapshot(8, held: true).start(at: 120, writerIsAlive: false) == (8, true))
        let running = snapshot(12.5, at: 100).start(at: 103.6)
        #expect(abs(running.seconds - 16.1) < 1e-9)
        #expect(running.isHeld == false)
        // 進み方が 0.5 (重いフレームでフレームの時計が半分の速さで進んでいた世代)
        let slow = snapshot(12.5, rate: 0.5, at: 100).start(at: 103.6)
        #expect(abs(slow.seconds - 14.3) < 1e-9)
        // 書き手がもう居なければ、書いた秒のまま (落ちた世代を、消えていた時間ぶん先から始めない)
        #expect(snapshot(12.5, at: 100).start(at: 160, writerIsAlive: false) == (12.5, false))
        // 時刻が戻っていても (端末の時計を直した等)、秒は戻さない
        #expect(snapshot(12.5, at: 100).start(at: 90) == (12.5, false))
    }

    @Test("書き手が生きているかは、番号のプロセスの有無で決まる")
    func aWritersLifeIsReadFromItsProcess() throws {
        #expect(ClockHandover.processIsAlive(getpid()))
        #expect(!ClockHandover.processIsAlive(0))
        // 終わって回収したプロセスの番号は、もう生きていない
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(!ClockHandover.processIsAlive(process.processIdentifier))
    }

    @Test("読めないファイル・壊れたファイル・非有限の秒は使えない。環境の値は絶対パスだけを受ける")
    func unreadableHandoverIsNotUsable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path

        #expect(ClockHandover.read(path: path) == .absent, "ファイルが無い")
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        guard case .unusable = ClockHandover.read(path: path) else {
            Issue.record("壊れたファイルを使える扱いにした")
            return
        }
        try Data(
            #"{"version":1,"seconds":1e999,"isHeld":false,"isStill":false,"rate":1,"at":1,"writer":1,"generation":1}"#
                .utf8
        ).write(to: URL(fileURLWithPath: path))
        guard case .unusable(let reason) = ClockHandover.read(path: path) else {
            Issue.record("非有限の秒を使える扱いにした")
            return
        }
        #expect(!reason.isEmpty)

        #expect(ClockHandover.path(from: nil) == nil)
        #expect(ClockHandover.path(from: "  ") == nil)
        #expect(ClockHandover.path(from: "relative/clock") == nil)
        #expect(ClockHandover.path(from: " /tmp/clock ") == "/tmp/clock")
    }

    @Test("環境の合図は読んだら消し、渡されていなければ何もしない。ここではファイルを読まない")
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
        #expect(given != nil)
        #expect(unset == [key])
        #expect(StartupReads.all.contains(StartupReads.keepTime))
        #expect(StartupReads.keepTime.origin == .environment)
        #expect(StartupReads.keepTime.decidedBy == .tool)
    }

    // MARK: - 読む

    @Test("前の世代を読むたびに、無ければ nil・使えなければ 1 度だけ原因と次にすることを言って nil・読めれば書き手の生死とともに返す")
    func readingThePredecessor() {
        let said = Said()
        let absent = handover(Readings([.absent]), said: said)
        #expect(absent.predecessor() == nil)
        #expect(said.lines.isEmpty, "最初の世代ではファイルが無いのが当たり前で、言わない")

        let broken = handover(Readings([.unusable(reason: "boom")]), said: said)
        #expect(broken.predecessor() == nil)
        #expect(broken.predecessor() == nil)
        #expect(said.lines.count == 1, "1 度だけ言う: \(said.lines)")
        let line = said.lines[0]
        #expect(line.contains("--keep-time") && line.contains("boom"))
        #expect(line.contains("/tmp/mokume-keep-time-test"), "場所")
        #expect(line.contains("TMPDIR") && line.contains("0 s"), "次にすること: \(line)")

        let found = handover(Readings([.found(snapshot(8, generation: 3))]), alive: false)
        #expect(
            found.predecessor()
                == ClockHandover.Predecessor(snapshot: snapshot(8, generation: 3), writerIsAlive: false))
    }

    @Test("世代の番号は読めたかによらず、後に起きたものほど大きい。読めない版は使えない")
    func generationsOnlyGrowAndUnknownVersionsAreRefused() throws {
        // 前の世代が読めなくても (壊れた・読めない版)、後の世代の番号は前の世代より大きい
        let older = ClockHandover(read: { .absent }, write: { _ in })
        let newer = ClockHandover(read: { .unusable(reason: "broken") }, write: { _ in }, warn: { _ in })
        _ = newer.predecessor()
        #expect(newer.generation > older.generation)

        // 読めない版
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        try Data(
            #"{"version":99,"seconds":1,"isHeld":false,"isStill":false,"rate":1,"at":1,"writer":1,"generation":1}"#
                .utf8
        ).write(to: URL(fileURLWithPath: path))
        guard case .unusable(let reason) = ClockHandover.read(path: path) else {
            Issue.record("読めない版を使える扱いにした")
            return
        }
        #expect(reason.contains("99"), "\(reason)")
        // 版の無い書式 (この版より前に書かれたもの)
        try Data(#"{"seconds":1,"isHeld":false,"rate":1,"at":1,"writer":1,"generation":1}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        guard case .unusable = ClockHandover.read(path: path) else {
            Issue.record("版の無い書式を使える扱いにした")
            return
        }
        // 読めない版は、読む側が 1 度だけ言って 0 秒から始める
        let said = LockedLines()
        let reader = ClockHandover(path: path, warn: { said.append($0) })
        #expect(reader.predecessor() == nil)
        #expect(reader.predecessor() == nil)
        #expect(said.lines.count == 1 && said.lines[0].contains(path), "\(said.lines)")
    }

    // MARK: - 渡された値から始まる時計

    @Test("止めた秒を運ぶ: 最初の枚から time はその秒で止まったまま、deltaTime は 0 (実時間の時計)")
    func aHeldSecondIsCarriedOnTheWallClock() {
        var now = 500.0
        let clock = timing(
            .wallClock, handover(Readings([.found(snapshot(8, held: true, at: 90))])), now: { now })
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
        var now = 100.0
        // 前の世代は 100 の時点で 12.5 秒を描いていた。新しい世代の最初の枚は 3.6 秒後
        let clock = timing(.wallClock, handover(Readings([.found(snapshot(12.5, at: 100))])), now: { now })
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
            .frameIndex(frameRate: 60), handover(Readings([.found(snapshot(40, at: 500))])), now: { now })
        var seen: [(Int, Double, Float)] = []
        for _ in 0..<3 {
            now += 0.5
            clock.advance()
            seen.append((clock.frameCount, clock.seconds, clock.deltaTime))
        }
        #expect(seen.map(\.0) == [1, 2, 3], "frameCount は運ばない")
        // 最初の枚は、前の世代が書いた時刻から 0.5 秒後 (書き手が生きていて進み方 1 の外挿)
        for (index, row) in seen.enumerated() {
            #expect(abs(row.1 - (40.5 + Double(index) / 60)) < 1e-9, "\(row)")
            #expect(row.2 == Float(1.0 / 60))
        }
        // 止めた秒は、フレームの時計でも止まったまま
        let held = timing(
            .frameIndex(frameRate: 60), handover(Readings([.found(snapshot(8, held: true))])), now: { now })
        held.advance()
        held.advance()
        #expect(held.time == 8 && held.deltaTime == 0)
    }

    @Test("フレームの時計の乗り換えで時刻が後ろへ戻らない: 前の世代が回っていた隙間ぶん、1 フレーム以内の差で続く")
    func theFrameClockDoesNotStepBackAcrossTheGap() {
        let now = 503.6
        // 前の世代は 500 の時点で 40 秒、実時間と同じ進み方で回っていた。新しい世代の最初の枚は 3.6 秒後
        let clock = timing(
            .frameIndex(frameRate: 60), handover(Readings([.found(snapshot(40, at: 500))])), now: { now })
        clock.advance()
        let previousGeneration = 40 + 3.6
        #expect(abs(clock.seconds - previousGeneration) <= 1.0 / 60, "続きの差: \(clock.seconds)")
        #expect(clock.seconds >= 40, "書いた秒より後ろへ戻らない")
    }

    @Test("落ちて居ない書き手の世代は、消えていた時間を足さず、最後に書いた秒から始める")
    func aCrashedPredecessorIsNotExtrapolated() {
        var now = 560.0
        // 8.2 秒で落ちた世代 (500 の時点)。60 秒後に直した新しい世代
        let clock = timing(
            .wallClock, handover(Readings([.found(snapshot(8.2, at: 500))]), alive: false), now: { now })
        clock.advance()
        #expect(clock.seconds == 8.2, "外挿しない: \(clock.seconds)")
        now += 1.0 / 60
        clock.advance()
        #expect(abs(clock.seconds - (8.2 + 1.0 / 60)) < 1e-9, "以後は進む")
    }

    @Test("引き継いだ後に playTime() すれば止めた秒から進み、pauseTime() すればそこで止まる")
    func theInheritedClockAnswersToPauseAndPlay() {
        var now = 500.0
        let clock = timing(.wallClock, handover(Readings([.found(snapshot(8, held: true))])), now: { now })
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

    // MARK: - setup() の明示 (#2414 の反証)

    /// 前の世代が `seeded` を書いていて、`setup()` で `setup` を呼んだ実行の、最初の数枚の秒。
    /// `fresh` は最初の枚の時点で読み直したときのファイル (省けば同じ)。
    private func carriedRun(
        predecessor seeded: ClockHandover.Snapshot, fresh: ClockHandover.Snapshot? = nil,
        setup: (FrameTiming) -> Void = { _ in }, frames: Int = 4
    ) -> (seconds: [Double], reads: Int) {
        var now = 500.0
        let readings = Readings([.found(seeded), .found(fresh ?? seeded)])
        let clock = timing(.wallClock, handover(readings), now: { now })
        clock.beginHandover()
        setup(clock)
        var seconds: [Double] = []
        for _ in 0..<frames {
            now += 1.0 / 60
            clock.advance()
            seconds.append(clock.seconds)
        }
        return (seconds, readings.count)
    }

    private func expectSeconds(
        _ actual: [Double], _ expected: [Double], _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            actual.count == expected.count
                && zip(actual, expected).allSatisfy { abs($0 - $1) < 1e-9 },
            "\(label): \(actual) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test("setup() の jumpTime・pauseTime・playTime は、前の世代が止めていても回っていても、2 枚目以降も通常どおり勝つ")
    func theAuthorsSetupWinsWhateverThePredecessorWas() {
        let held = snapshot(8, held: true, at: 500)
        let running = snapshot(8, at: 500)
        let step = 1.0 / 60

        // 止めていた世代
        expectSeconds(carriedRun(predecessor: held).seconds, [8, 8, 8, 8], "止めていた・何も呼ばない")
        expectSeconds(
            carriedRun(predecessor: held, setup: { $0.jumpTime(2) }).seconds, [2, 2, 2, 2],
            "止めていた・jumpTime(2) は 2 枚目以降も 2 で止まる")
        expectSeconds(
            carriedRun(predecessor: held, setup: { $0.pauseTime() }).seconds, [8, 8, 8, 8],
            "止めていた・pauseTime()")
        expectSeconds(
            carriedRun(predecessor: held, setup: { $0.playTime() }).seconds,
            [8, 8 + step, 8 + 2 * step, 8 + 3 * step], "止めていた・playTime() は止めた秒から進む")

        // 回っていた世代
        expectSeconds(
            carriedRun(predecessor: running).seconds,
            [8 + step, 8 + 2 * step, 8 + 3 * step, 8 + 4 * step], "回っていた・何も呼ばない")
        expectSeconds(
            carriedRun(predecessor: running, setup: { $0.jumpTime(2) }).seconds,
            [2, 2 + step, 2 + 2 * step, 2 + 3 * step], "回っていた・jumpTime(2)")
        expectSeconds(
            carriedRun(predecessor: running, setup: { $0.pauseTime() }).seconds, [8, 8, 8, 8],
            "回っていた・pauseTime() は setup() から見えた秒で止まる")
        expectSeconds(
            carriedRun(predecessor: running, setup: { $0.playTime() }).seconds,
            [8 + step, 8 + 2 * step, 8 + 3 * step, 8 + 4 * step], "回っていた・playTime()")
    }

    @Test("setup() から見える秒と止めているかは、前の世代の続きになる")
    func setupSeesTheInheritedSecond() {
        var now = 500.0
        let clock = timing(.wallClock, handover(Readings([.found(snapshot(8, held: true))])), now: { now })
        clock.beginHandover()
        #expect(clock.authorTime == 8, "setup() が読む time")
        clock.beginHandover()  // 2 度目は何もしない
        now += 1.0 / 60
        clock.advance()
        #expect(clock.seconds == 8)
        // 引き継ぎの口が無い実行は 0 のまま
        let plain = timing(.wallClock, nil, now: { now })
        plain.beginHandover()
        #expect(plain.authorTime == 0)
    }

    // MARK: - 最初の枚の時点で読み直す

    @Test("setup() が時計に触っていなければ、最初の枚の時点でファイルを読み直して始め直す")
    func theFirstFrameReadsAgainWhenSetupLeftTheClockAlone() {
        let step = 1.0 / 60
        // 読んだ後に前の世代が止めて 9 秒で止まった
        let stopped = carriedRun(
            predecessor: snapshot(8, at: 500), fresh: snapshot(9, held: true, at: 500.5))
        expectSeconds(stopped.seconds, [9, 9, 9, 9], "読んだ後に止まった")
        #expect(stopped.reads == 2)
        // 止めていたのが、読んだ後に再開して先へ飛んだ (前の世代は 0.1 秒前の時点で 30 秒を描いていた)
        let resumed = carriedRun(
            predecessor: snapshot(8, held: true, at: 500), fresh: snapshot(30, at: 499.9))
        let first = 30 + (500 + step - 499.9)
        expectSeconds(resumed.seconds, (0..<4).map { first + Double($0) * step }, "読んだ後に再開して飛んだ")
        // 触っていれば読み直さない (作者の明示が勝つ)。土台は setup() の前に読んだ値
        let touched = carriedRun(
            predecessor: snapshot(8, at: 500), fresh: snapshot(9, held: true, at: 500.5),
            setup: { $0.playTime() })
        expectSeconds(
            touched.seconds, [8 + step, 8 + 2 * step, 8 + 3 * step, 8 + 4 * step], "触っていれば読み直さない")
        #expect(touched.reads == 1)
    }

    @Test("読み直しが読めなければ、setup() の前に読んだ値で始める")
    func aFailedRereadFallsBackToTheEarlierRead() {
        var now = 500.0
        let readings = Readings([.found(snapshot(8, held: true)), .absent])
        let clock = timing(.wallClock, handover(readings), now: { now })
        clock.beginHandover()
        now += 1.0 / 60
        clock.advance()
        #expect(clock.seconds == 8 && clock.deltaTime == 0)
    }

    @Test("引き継ぐものが無い実行は 0 秒から始まる。無かったファイルが最初の枚の時点であれば、それで始める")
    func withNothingToInheritTheClockStartsAtZero() {
        var now = 500.0
        let written = Box()
        let plain = FrameTiming(clock: .wallClock, frameRate: 60, now: { now })
        now += 3
        plain.advance()
        #expect(plain.time == 0)
        // 読めるものが無い (最初の世代) 実行も 0 秒から始まるが、書き始める
        let fresh = timing(.wallClock, handover(Readings([.absent]), written: written), now: { now })
        now += 1.0 / 60
        fresh.advance()
        #expect(fresh.time == 0)
        #expect(written.values.count == 1)
        // setup() の前には無く、最初の枚の時点であったファイル
        let late = timing(
            .wallClock, handover(Readings([.absent, .found(snapshot(5, held: true))])), now: { now })
        late.beginHandover()
        now += 1.0 / 60
        late.advance()
        #expect(late.seconds == 5)
    }

    // MARK: - 書く

    @Test("実時間の時計は、変わらない間は書き直さず、止めた・戻した・飛んだとき、しばらく経ったときに書き直す")
    func theWallClockWritesOnlyWhenNeeded() {
        var now = 500.0
        let written = Box()
        let clock = timing(.wallClock, handover(written: written), now: { now })
        for _ in 0..<30 {
            now += 1.0 / 60
            clock.advance()
        }
        #expect(written.values.count == 1, "外挿が合っている間は書き直さない: \(written.values.count)")
        #expect(written[0].map { $0.rate == 1 && !$0.isHeld && $0.writer == 7 && $0.generation == 5 } == true)

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

    @Test("フレームの時計は、毎枚ではなく進み方の測り直しの間隔で書き、重いフレームで半分の速さで進んでも続きの差が 1 フレーム以内に収まる")
    func theFrameClockWritesRarelyAndExtrapolatesWithItsMeasuredRate() {
        var now = 500.0
        let written = Box()
        let clock = timing(.frameIndex(frameRate: 60), handover(written: written), now: { now })
        // 60 fps の目標に対して 30 fps でしか回れない世代 (1 枚に 1/60 秒しか進まない)。3 秒回す
        for _ in 0..<90 {
            now += 1.0 / 30
            clock.advance()
        }
        #expect(written.values.count <= 20, "毎枚 (90 回) ではなく間隔を空けて書く: \(written.values.count)")
        let last = try! #require(written.values.last)
        #expect(abs((last.rate ?? 0) - 0.5) < 0.02, "測った進み方: \(String(describing: last.rate))")
        // 新しい世代の最初の枚が 3.6 秒後に出る。前の世代はその間も同じ進み方で回る
        let arrival = now + 3.6
        let truth = clock.seconds + 0.5 * 3.6
        let predicted = last.start(at: arrival).seconds
        #expect(abs(predicted - truth) <= 1.0 / 60, "続きの差: \(predicted - truth)")
    }

    @Test("フレームの時計で、実時間に追いついて回る世代は進み方 1 のまま、秒が動いても毎枚は書かない")
    func aSteadyFrameClockWritesOnlyOnTheRefreshInterval() {
        var now = 500.0
        let written = Box()
        let clock = timing(.frameIndex(frameRate: 60), handover(written: written), now: { now })
        for _ in 0..<120 {
            now += 1.0 / 60
            clock.advance()
        }
        #expect(written.values.count <= 6, "2 秒で \(written.values.count) 回")
        #expect(written.values.dropFirst().allSatisfy { abs(($0.rate ?? 0) - 1) < 0.02 })
    }

    @Test("毎枚 jumpTime する作品でも、状態の変わり目でなければ 1 秒に 20 回までしか書かない")
    func aJumpOnEveryFrameIsThrottled() {
        var now = 500.0
        let written = Box()
        let clock = timing(.wallClock, handover(written: written), now: { now })
        for index in 0..<120 {
            now += 1.0 / 60
            clock.jumpTime(Double(index % 7))
            clock.advance()
        }
        // 2 秒ぶん。毎枚 (120 回) ではなく、50 ms あけて
        #expect(written.values.count <= 2 * 20 + 1, "\(written.values.count) 回")
        #expect(written.values.count >= 10, "止まってはいない: \(written.values.count) 回")
    }

    @Test("観測の指定秒ではなく作者の時計の秒を書く")
    func theAuthorsSecondIsWrittenNotTheObservedOne() {
        var now = 500.0
        let written = Box()
        let clock = timing(.frameIndex(frameRate: 60), handover(written: written), now: { now })
        for _ in 0..<3 {
            now += 0.06
            clock.advance()
        }
        // 秒が進まない (止めている) 前に、作者の時計の秒で 1 度書いてある
        let before = written.values.count
        clock.jumpTime(70)
        now += 0.06
        clock.advance(at: 99)
        #expect(clock.time == 99)
        #expect(written.values.count == before + 1)
        #expect(abs((written.values.last?.seconds ?? -1) - 70) < 1e-9)
    }

    @Test("長く回した世代の秒は、書いて読み戻しても倍精度のまま (単精度の刻みへ戻らない)")
    func aLongRunningSecondKeepsItsPrecision() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        // 6 日ぶん回した世代。単精度の `time` では 60 fps の刻みが区別できない
        let seconds = 6.0 * 86_400 + 1.0 / 60
        let sink = ClockHandover.FileSink(path: path, warn: { _ in })
        sink.submit(snapshot(seconds, held: true, at: 7))
        sink.settle()
        guard case .found(let read) = ClockHandover.read(path: path) else {
            Issue.record("書いたものが読めない")
            return
        }
        #expect(read == snapshot(seconds, held: true, at: 7))
        #expect(read.seconds == seconds, "倍精度のまま")
        #expect(Float(seconds) == Float(seconds + 1.0 / 60), "(確認) 単精度ではこの刻みは区別できない")
    }

    // MARK: - 枚が止まっているとき (noLoop())

    @Test("枚が止まっている世代・進み方がまだ測れていない世代は外挿しない。止めていなければ従来どおり進める")
    func aStillOrUnmeasuredPredecessorIsNotExtrapolated() {
        #expect(snapshot(12.5, still: true, at: 100).start(at: 160) == (12.5, false), "枚が止まっている")
        #expect(snapshot(12.5, rate: nil, at: 100).start(at: 160) == (12.5, false), "進み方が未測定")
        #expect(snapshot(12.5, held: true, still: true, at: 100).start(at: 160) == (12.5, true))
        let running = snapshot(12.5, at: 100).start(at: 103.6)
        #expect(abs(running.seconds - 16.1) < 1e-9)
    }

    @Test("noLoop() で枚が止まったら、その枚の秒を止まっていると書く。60 秒眺めてから保存しても、新しい世代は同じ秒から始まる")
    func aStoppedSketchHandsOverTheShownSecondNotTheElapsedOne() {
        for clock in [Clock.wallClock, Clock.frameIndex(frameRate: 60)] {
            var now = 500.0
            let written = Box()
            let readings = Readings([.absent])
            let old = timing(clock, handover(readings, written: written), now: { now })
            for _ in 0..<30 {
                now += 1.0 / 60
                old.advance()
            }
            let shown = old.seconds
            let before = written.values.count
            old.noteStill(true)
            #expect(written.values.count == before + 1, "止まった枚の秒をその場で書く: \(clock)")
            let last = written.values.last
            #expect(last?.isStill == true && last?.seconds == shown, "\(String(describing: last))")
            // 止まったまま眺める。枚は来ない。同じ状態を何度告げても書き直さない
            old.noteStill(true)
            #expect(written.values.count == before + 1)

            // 60 秒後に保存して作り直した世代は、窓に出ている秒から始まる
            now += 60
            let new = timing(clock, handover(Readings([.found(last!)])), now: { now })
            new.beginHandover()
            new.advance()
            #expect(abs(new.seconds - shown) < 1e-9, "止まっていた間の 60 秒を足さない: \(clock) \(new.seconds) vs \(shown)")
        }
    }

    @Test("動き出したときは、次の枚が動いていると書く。最初の枚の前に止められても、書かずに控える")
    func resumingIsWrittenByTheNextFrame() {
        var now = 500.0
        let written = Box()
        let clock = timing(.wallClock, handover(written: written), now: { now })
        // 最初の枚の前 (setup() の noLoop()): まだ秒が無いので書かない
        clock.noteStill(true)
        #expect(written.values.isEmpty)
        now += 1.0 / 60
        clock.advance()
        #expect(written.values.last?.isStill == true, "控えた状態のまま最初の枚が書く")
        clock.noteStill(false)
        #expect(written.values.last?.isStill == true, "動き出しはここでは書かない")
        now += 1.0 / 60
        clock.advance()
        #expect(written.values.last?.isStill == false, "次の枚が動いていると書く")
    }

    @Test("フレームの時計は、進み方が測れるまで nil を書く。測れたら書き直す")
    func theFrameClockWritesNoRateUntilItIsMeasured() {
        var now = 500.0
        let written = Box()
        let clock = timing(.frameIndex(frameRate: 60), handover(written: written), now: { now })
        now += 1.0 / 60
        clock.advance()
        #expect(written[0]?.rate == nil)
        for _ in 0..<40 {
            now += 1.0 / 60
            clock.advance()
        }
        let measured = written.values.last
        #expect(measured?.rate != nil, "0.5 秒で測れて書き直した")
        // 書く前の世代は、続きの秒を求められない (外挿せず書いた秒から始める)
        #expect(written[0]?.start(at: now + 100).seconds == written[0]?.seconds)
    }

    // MARK: - 書く側の口 (main の外)

    @Test("続けて頼んでも最新のものだけが、間隔を空けて書かれ、頼みが止んでも最後の 1 つは届く")
    func theSinkCoalescesAndStillLandsTheLastOne() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let sink = ClockHandover.FileSink(path: path, warn: { _ in })
        for index in 0..<200 {
            sink.submit(snapshot(Double(index), at: Double(index)))
        }
        sink.settle()
        guard case .found(let read) = ClockHandover.read(path: path) else {
            Issue.record("書かれていない")
            return
        }
        #expect(read.seconds == 199, "最後の頼みが届く: \(read.seconds)")
        #expect(sink.writeCount < 10, "200 回の頼みを \(sink.writeCount) 回に畳む")
    }

    @Test("より新しい世代の書き手が生きている間、古い世代は書かずに見送り、居なくなれば見送りは取り消される")
    func anOlderGenerationYieldsOnlyWhileTheNewerWriterLives() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let newerLives = Mutex(true)
        let old = ClockHandover.FileSink(
            path: path, warn: { _ in }, isAlive: { _ in newerLives.withLock { $0 } })
        let new = ClockHandover.FileSink(path: path, warn: { _ in })

        old.submit(snapshot(1, writer: 10, generation: 1))
        old.settle()
        new.submit(snapshot(9, held: true, writer: 11, generation: 2))
        new.settle()
        // 古い世代は止め終えるまで書き続ける
        old.submit(snapshot(5, writer: 10, generation: 1))
        old.settle()
        old.submit(snapshot(6, writer: 10, generation: 1))
        old.settle()
        guard case .found(let read) = ClockHandover.read(path: path) else {
            Issue.record("読めない")
            return
        }
        #expect(read.generation == 2 && read.seconds == 9 && read.isHeld, "新しい世代が残る: \(read)")
        #expect(old.writeCount == 1 && new.writeCount == 1, "古い世代は見送って書いていない")
        // 新しい世代は自分の世代を書き直せる
        new.submit(snapshot(10, held: true, writer: 11, generation: 2))
        new.settle()
        // 新しい世代の書き手が居なくなった (落ちた)。見送りは取り消され、古い世代が書く
        newerLives.withLock { $0 = false }
        old.submit(snapshot(7, writer: 10, generation: 1))
        old.settle()
        guard case .found(let again) = ClockHandover.read(path: path) else {
            Issue.record("読めない")
            return
        }
        #expect(again.generation == 1 && again.seconds == 7, "書き手が居なければ古い世代が書く: \(again)")
    }

    @Test("読めないファイルの上へは、世代によらず書く (読めない世代が、新しい世代を永久に黙らせない)")
    func anUnreadableFileIsWrittenOver() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let sink = ClockHandover.FileSink(path: path, warn: { _ in }, isAlive: { _ in true })
        sink.submit(snapshot(3, writer: 10, generation: 1))
        sink.settle()
        guard case .found(let read) = ClockHandover.read(path: path) else {
            Issue.record("書かれていない")
            return
        }
        #expect(read.seconds == 3)
    }

    @Test("原子的な置き方は AtomicFile を通る: 落とされた書き手の残した一時ファイルを片付け、自分の一時ファイルを残さない")
    func writesGoThroughAtomicFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        // 書いている途中に SIGKILL された子が残した一時ファイル (持ち主の番号は、終わって回収したプロセスのもの)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let abandoned = directory.appendingPathComponent(".clock.\(process.processIdentifier)-3.tmp")
        try Data("half".utf8).write(to: abandoned)

        let sink = ClockHandover.FileSink(path: path, warn: { _ in })
        sink.submit(snapshot(2))
        sink.settle()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(!names.contains(abandoned.lastPathComponent), "落とされた書き手の一時ファイルが残っている: \(names)")
        #expect(names.filter { $0.hasSuffix(".tmp") }.isEmpty, "自分の一時ファイルが残っている: \(names)")
        guard case .found = ClockHandover.read(path: path) else {
            Issue.record("置けていない")
            return
        }
    }

    @Test("書けないとき・読めないときは、黙って 0 秒に戻さず、1 度だけ原因と次にすることを言う")
    func failuresToWriteAreSaidOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 置き場を作れない場所 (置き場の名前を普通のファイルが使っている)
        let blocker = directory.appendingPathComponent("blocker")
        try Data("file".utf8).write(to: blocker)
        let path = blocker.appendingPathComponent("clock").path
        let said = LockedLines()
        let sink = ClockHandover.FileSink(path: path, warn: { said.append($0) })
        sink.submit(snapshot(1))
        sink.settle()
        sink.submit(snapshot(2))
        sink.settle()
        #expect(said.lines.count == 1, "1 度だけ: \(said.lines)")
        let line = said.lines.first ?? ""
        #expect(line.contains("--keep-time") && line.contains(path), "\(line)")
        #expect(line.contains("TMPDIR") && line.contains("0 s"), "次にすること: \(line)")

        // 中身が壊れたファイルは、読む側が言う (ファイルが無いのとは違う)
        let broken = directory.appendingPathComponent("broken").path
        try Data("not json".utf8).write(to: URL(fileURLWithPath: broken))
        let readSaid = LockedLines()
        let reader = ClockHandover(path: broken, warn: { readSaid.append($0) })
        #expect(reader.predecessor() == nil)
        #expect(readSaid.lines.count == 1 && readSaid.lines[0].contains(broken), "\(readSaid.lines)")
    }

    nonisolated final class LockedLines: Sendable {
        private let storage = Mutex<[String]>([])
        func append(_ line: String) { storage.withLock { $0.append(line) } }
        var lines: [String] { storage.withLock { $0 } }
    }

    // MARK: - ファイルをはさんだ受け渡し

    @Test("前の世代が書いたファイルから、次の世代が止めた秒を受け取り、世代が 1 つ進む")
    func twoGenerationsThroughTheFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path

        var now = 500.0
        let firstHandover = ClockHandover(path: path, warn: { _ in })
        let first = timing(.wallClock, firstHandover, now: { now })
        first.beginHandover()
        for _ in 0..<5 {
            now += 1.0 / 60
            first.advance()
        }
        first.jumpTime(8)
        now += 1.0 / 60
        first.advance()
        first.pauseTime()
        now += 1.0 / 60
        first.advance()
        // 書く処理は main の外なので、前の世代のぶんが届くまで待つ (本番は次の世代が起きるまでに十分な時間がある)
        var waited = 0
        while waited < 300 {
            if case .found(let seen) = ClockHandover.read(path: path), seen.isHeld { break }
            Thread.sleep(forTimeInterval: 0.01)
            waited += 1
        }
        let second = ClockHandover(path: path, warn: { _ in })
        let secondTiming = timing(.wallClock, second, now: { now })
        now += 3.6
        secondTiming.beginHandover()
        secondTiming.advance()
        #expect(secondTiming.seconds == 8, "止めた秒を運ぶ: \(secondTiming.seconds)")
        #expect(second.generation > firstHandover.generation, "後に起きた世代ほど番号が大きい")
    }
}

/// 窓の経路の組み立てが、渡された時計を `FrameTiming` まで運び、`setup()` の前に入れること ([#2414])。GPU を要する。
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
        var setupTime: Float?
        var jumpsInSetup: Float?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 8, height: 4) }
        func setup() {
            setupTime = time
            if let jumpsInSetup { jumpTime(jumpsInSetup) }
        }
        func draw() {
            background(0)
            seen.append(time)
        }
    }

    private func handover(_ snapshot: ClockHandover.Snapshot?) -> ClockHandover {
        ClockHandover(
            read: { snapshot.map { .found($0) } ?? .absent }, write: { _ in }, isAlive: { _ in true },
            warn: { _ in })
    }

    private func held(_ seconds: Double) -> ClockHandover.Snapshot {
        ClockHandover.Snapshot(
            seconds: seconds, isHeld: true, isStill: false, rate: 1, at: 90, writer: 1, generation: 1)
    }

    @Test("窓の経路で組んだ実行は、渡された止めた秒から始まり、止まったまま動く。setup() はその秒を見る")
    func theRuntimeStartsFromTheHandedSecond() throws {
        var now = 500.0
        let sketch = Probe()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { now }, onScreen: true,
            handover: handover(held(8)))
        for _ in 0..<3 {
            now += 1.0 / 60
            try runtime.advance()
        }
        #expect(sketch.seen == [8, 8, 8])
        #expect(sketch.setupTime == 8, "setup() が読む time も前の世代の続き")
        // 渡さなければ 0 秒から始まる
        let plain = Probe()
        let fresh = try SketchRuntime(
            sketch: plain, gpu: RenderDevice(), clock: nil, now: { now }, onScreen: true)
        now += 1.0 / 60
        try fresh.advance()
        #expect(plain.seen == [0])
        #expect(plain.setupTime == 0)
    }

    @Test("前の世代が止めていても、setup() の jumpTime(_:) は 2 枚目以降も勝つ")
    func aJumpInSetupWinsOnEveryFrame() throws {
        var now = 500.0
        let sketch = Probe()
        sketch.jumpsInSetup = 2
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { now }, onScreen: true,
            handover: handover(held(8)))
        for _ in 0..<4 {
            now += 1.0 / 60
            try runtime.advance()
        }
        #expect(sketch.seen == [2, 2, 2, 2])
    }

    final class Written {
        var values: [ClockHandover.Snapshot] = []
    }

    final class Stopper: Sketch {
        var frames = 0
        init() {}
        var settings: SketchSettings { SketchSettings(width: 8, height: 4) }
        func draw() {
            background(0)
            frames += 1
            if frames == 3 { noLoop() }
        }
    }

    @Test("draw() の中の noLoop() も外からの停止も、止まった枚の秒を止まっていると書く。動き出せば次の枚が書き直す")
    func aStoppedRuntimeWritesItsShownSecond() throws {
        var now = 500.0
        let written = Written()
        let handover = ClockHandover(
            read: { .absent }, write: { written.values.append($0) }, isAlive: { _ in true }, warn: { _ in })
        let sketch = Stopper()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { now }, onScreen: true, handover: handover)
        for _ in 0..<3 {
            now += 1.0 / 60
            try runtime.advance()
        }
        let stopped = try #require(written.values.last)
        #expect(stopped.isStill && !stopped.isHeld, "noLoop() の枚で止まったと書く: \(stopped)")
        #expect(abs(stopped.seconds - 2.0 / 60) < 1e-9, "窓に出ている枚の秒: \(stopped.seconds)")

        // 外からの停止と再開
        runtime.loop()
        now += 1.0 / 60
        try runtime.advance()
        #expect(written.values.last?.isStill == false, "動き出して描いた枚は、動いていると書く")
        runtime.pause()
        #expect(written.values.last?.isStill == true, "外から止めた")
        runtime.resume()
        now += 1.0 / 60
        try runtime.advance()
        #expect(written.values.last?.isStill == false)
    }

    @Test("書き出しの頼みが在れば、渡された時計は使わない")
    func aRenderRequestIgnoresTheHandover() throws {
        let given = handover(nil)
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 1, destination: "/tmp/mokume-never-written.mov"))
        #expect(SketchApplication.handover(given: given, render: request) == nil)
        #expect(SketchApplication.handover(given: given, render: nil) === given)
        #expect(SketchApplication.handover(given: nil, render: nil) == nil)
    }
}
