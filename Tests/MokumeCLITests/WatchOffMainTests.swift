// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing
import mokume

@testable import MokumeCLI

/// 作り直しが main actor を塞がないこと。
///
/// **見ているのは時間ではなく順序である。** 「何ミリ秒で終わったか」で判定すると、機械が
/// 混んでいる日に赤くなる検査になる — ここで確かめたいのは速さではなく、作り直しを待って
/// いる**間に**別の仕事が進めるかどうかだからである
/// ([#834](https://github.com/mokume-metal/mokume/issues/834))。
///
/// 待ちには期限を持たせる。`.timeLimit` は使わない — あれは検査**全体**の時計で測られる
/// ので、検査が増えた日に無関係な変更が無関係な検査を赤くする (AGENTS.md・#564)。
@Suite("作り直しは main を塞がない")
struct WatchOffMainTests {
    /// 外から開けるまで待たせる関門。
    ///
    /// **壁時計で待たない。** 「そろそろ作り直しに入ったころだ」と眠って測る形は、機械の
    /// 都合でいくらでもずれる。入ったことは関門自身が名乗る。
    @MainActor
    final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        /// いま待っているか。
        private(set) var isWaiting = false

        /// 開けられるまで待つ。
        func wait() async {
            isWaiting = true
            await withCheckedContinuation { waiting.append($0) }
            isWaiting = false
        }

        /// 待っているものを全部通す。
        func open() {
            let waited = waiting
            waiting = []
            for continuation in waited { continuation.resume() }
        }
    }

    /// どのスレッドからでも立てられる印。**要約は main actor の外で呼ばれうる** (#2518)。
    nonisolated final class Flag: Sendable {
        private let raised = Mutex(false)
        func raise() { raised.withLock { $0 = true } }
        var isRaised: Bool { raised.withLock { $0 } }
    }

    /// 起きた順に積む帳面。**検査が見るのはこの並びである。**
    @MainActor
    final class Log {
        private(set) var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }

    /// 作り直しを待たせた状態の見張りを組む。
    ///
    /// - Returns: 記録係・関門・見張り。関門は呼び手が開ける。
    @MainActor
    private func makeWaitingSession(log: Log? = nil) throws -> (
        recorder: WatchSessionTests.Recorder, gate: Gate, session: WatchSession
    ) {
        let recorder = WatchSessionTests.Recorder()
        let gate = Gate()
        if let log { recorder.onBuild = { log.append("作り直しに入る") } }
        recorder.whileBuilding = { await gate.wait() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        return (recorder, gate, session)
    }

    @Test("作り直しの最中も、main actor は別の仕事を進められる")
    @MainActor
    func theMainActorIsFreeWhileRebuilding() async throws {
        let log = Log()
        let (_, gate, session) = try makeWaitingSession(log: log)

        let building = Task { @MainActor () -> BuildReport in
            let report = await session.start()
            log.append("作り直しを終える")
            return report
        }
        try await waitUntil { gate.isWaiting }

        // 巡回・窓の描き直し・× の問いの代わり。**どれも main actor の仕事**なので、
        // 塞がっていればここは作り直しが終わるまで走れない
        Task { @MainActor in log.append("別の仕事が進む") }
        try await waitUntil { log.entries.contains("別の仕事が進む") }
        #expect(gate.isWaiting, "作り直しが終わってから走っている")

        gate.open()
        #expect(await building.value.ok)
        #expect(log.entries == ["作り直しに入る", "別の仕事が進む", "作り直しを終える"])
    }

    @Test("作り直しの最中に来た巡回は、二重に作り直さない")
    @MainActor
    func doesNotStartASecondRebuildWhileOneIsRunning() async throws {
        let log = Log()
        let (recorder, gate, session) = try makeWaitingSession()

        let building = Task { await session.start() }
        try await waitUntil { gate.isWaiting }

        // **待たずに戻ることを、期限つきで見る。** 印が無い実装では 2 本目がそのまま関門で
        // 待つので、素直に `await` すると検査は赤くならずに**固まる**
        #expect(try await returnsWithoutWaiting(log, "1 度目") { await session.tick() } == nil)
        // 待っている間の保存。**落としてはいけない**
        recorder.stamp = "bbb"
        #expect(try await returnsWithoutWaiting(log, "2 度目") { await session.tick() } == nil)

        gate.open()
        _ = await building.value
        #expect(recorder.builds == 1)

        // **終わってから 1 回だけ追いかける。** 世代の刻印を更新するのは作り直しの側なので、
        // 次の巡回が新しい刻印を見つける
        recorder.whileBuilding = {}
        #expect(try #require(await session.tick()).ok)
        #expect(recorder.builds == 2)
        #expect(await session.tick() == nil, "同じ保存で 2 度追いかけている")
    }

    @Test("作り直しの最中に来た巡回は、いま作っている世代を変化と読まない")
    @MainActor
    func theRebuildInFlightIsNotSeenAsAChange() async throws {
        let log = Log()
        let (recorder, gate, session) = try makeWaitingSession()

        let building = Task { await session.start() }
        try await waitUntil { gate.isWaiting }
        #expect(try await returnsWithoutWaiting(log, "最中の巡回") { await session.tick() } == nil)
        gate.open()
        _ = await building.value

        // **気付いた時刻を汚していない。** 汚れていると、次に保存したときの `detect_ms` に
        // 作り直しを待っていた時間までが乗る (手元で 12 秒を実測したのがこの形である)
        recorder.whileBuilding = {}
        recorder.stamp = "bbb"
        let report = try #require(await session.tick())
        #expect(try #require(report.timings.detectMs) == 0, "気付いた時刻が作り直しの最中に置かれている")
        #expect(recorder.builds == 2)
    }

    @Test("終われと言われたら、作り直しの終わりを待たずに抜ける")
    @MainActor
    func leavesWithoutWaitingForTheBuild() async throws {
        let (recorder, gate, session) = try makeWaitingSession()

        let building = Task { await session.start() }
        try await waitUntil { gate.isWaiting }

        #expect(await !WatchCommand.step(session, stopped: { true }), "抜けていない")
        #expect(gate.isWaiting, "作り直しの終わりを待ってから抜けている")

        // **抜けた後に終わった作り直しは、子を起こさない。** 起こしても、もう止める者が
        // 居ない — #454 の孤児と同じ形になる
        gate.open()
        #expect(await building.value.ok, "作り直しそのものは通っている")
        // **起こしていないことは、起こす口が呼ばれた回数で見る。** 記録の `launched` は
        // 替え玉が `nil` を返す以上どちらでも false なので、ここでは何も言えない
        #expect(recorder.launches == 0, "終われと言われた後に子を起こしている")
    }

    @Test("子を待つ経路は、main actor の外から呼べる")
    @MainActor
    func theWaitingPathRunsOffTheMainActor() async throws {
        // **`Process` は閉じた中で作る** (送れる値ではない)。ここが `nonisolated` でなければ
        // この検査はコンパイルから落ちる — 型検査がそのまま見張り役になる
        let waiting = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf hi; sleep 0.3"]
            return try RunCommand.capture(process, capturing: true, errors: .discard)
        }

        let log = Log()
        Task { @MainActor in log.append("待っている間に進む") }
        try await waitUntil { log.entries.contains("待っている間に進む") }

        let result = try await waiting.value
        #expect(result.status == 0)
        #expect(result.output == "hi")
    }

    // MARK: - 世代を取る仕事も main を塞がない (#2518)

    /// 世代を待たせた状態の見張りを組む。**最初の作り直しは済ませてある** — 巡回で見たいので。
    @MainActor
    private func makeStampingSession() async throws -> (
        recorder: WatchSessionTests.Recorder, gate: Gate, session: WatchSession
    ) {
        let recorder = WatchSessionTests.Recorder()
        let gate = Gate()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()
        recorder.whileStamping = { await gate.wait() }
        recorder.stamp = "bbb"
        return (recorder, gate, session)
    }

    /// **大きな資材の要約は数百 ms かかる** (512 MiB で約 263 ms)。巡回が main actor で
    /// 待つと、そのあいだ道具の窓が止まる ([#2518](https://github.com/mokume-metal/mokume/issues/2518))。
    @Test("巡回が世代を待っている最中も、main actor は別の仕事を進められる")
    @MainActor
    func theMainActorIsFreeWhileTheTickTakesTheStamp() async throws {
        let log = Log()
        let (recorder, gate, session) = try await makeStampingSession()

        let ticking = Task { @MainActor () -> BuildReport? in
            let report = await session.tick()
            log.append("巡回を終える")
            return report
        }
        try await waitUntil { gate.isWaiting }
        Task { @MainActor in log.append("別の仕事が進む") }
        try await waitUntil { log.entries.contains("別の仕事が進む") }
        #expect(gate.isWaiting, "世代を取り終えてから走っている")

        gate.open()
        #expect(try #require(await ticking.value).ok, "世代が変わったのに作り直していない")
        #expect(log.entries == ["別の仕事が進む", "巡回を終える"])
        #expect(recorder.builds == 2)
    }

    @Test("最初の作り直しの前に世代を待つ間も、main actor は別の仕事を進められる")
    @MainActor
    func theMainActorIsFreeWhileTheStartTakesTheStamp() async throws {
        let log = Log()
        let recorder = WatchSessionTests.Recorder()
        let gate = Gate()
        recorder.whileStamping = { await gate.wait() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())

        let starting = Task { @MainActor () -> BuildReport in
            let report = await session.start()
            log.append("最初の作り直しを終える")
            return report
        }
        try await waitUntil { gate.isWaiting }
        Task { @MainActor in log.append("別の仕事が進む") }
        try await waitUntil { log.entries.contains("別の仕事が進む") }
        #expect(recorder.builds == 0, "世代を取り終える前に作り直している")

        // **最初の世代を待つ間に来た巡回も、読みを重ねない。** 見張りの口は最初の 1 拍で
        // 作り直しを始め、続く拍で巡回する (``WatchCommand/watch(_:viewer:)``)
        #expect(try await returnsWithoutWaiting(log, "最中の巡回") { await session.tick() } == nil)
        #expect(recorder.stampings == 1, "最初の世代を待つ間に、巡回が世代を取り直した")

        gate.open()
        #expect(await starting.value.ok)
        #expect(log.entries == ["別の仕事が進む", "最中の巡回", "最初の作り直しを終える"])
        #expect(recorder.builds == 1)
    }

    /// **巡回は 0.25 秒ごとに来る。** 大きな資材の要約はそれより長いので、印が無いと
    /// 読み終わる前に次の読みが積み上がる。
    @Test("世代を待っている最中に来た巡回は、世代を取り直さずに戻る")
    @MainActor
    func doesNotTakeASecondStampWhileOneIsPending() async throws {
        let log = Log()
        let (recorder, gate, session) = try await makeStampingSession()

        let ticking = Task { await session.tick() }
        try await waitUntil { gate.isWaiting }
        #expect(try await returnsWithoutWaiting(log, "1 度目") { await session.tick() } == nil)
        #expect(try await returnsWithoutWaiting(log, "2 度目") { await session.tick() } == nil)
        // 最初の作り直しの 1 回と、いま待っている 1 回
        #expect(recorder.stampings == 2, "待っている間の巡回が世代を取り直した")

        gate.open()
        #expect(try #require(await ticking.value).ok)
        #expect(recorder.builds == 2, "1 つの変化で作り直しが重なった")
    }

    /// **合図を見るのは口の側で、待っている巡回は止められない。** 見直さないと、終われと
    /// 言われた後で作り直しを始め、`swift build` が置き場の鍵を握ったまま残る (#834・#1147)。
    @Test("世代を待っている間に終われと言われたら、戻っても作り直さない")
    @MainActor
    func aStopRequestedWhileTakingTheStampStartsNothing() async throws {
        let (recorder, gate, session) = try await makeStampingSession()

        let ticking = Task { await session.tick() }
        try await waitUntil { gate.isWaiting }
        #expect(await !WatchCommand.step(session, stopped: { true }), "抜けていない")

        gate.open()
        #expect(await ticking.value == nil, "終われと言われた後に作り直した")
        #expect(recorder.builds == 1, "終われと言われた後に作り直した")
        #expect(recorder.launches == 1, "終われと言われた後に子を起こした")
    }

    /// **最初の世代を待つのはいちばん長い回である** (控えが無く資材を全部読む)。その間に来た
    /// 合図を見直さないと、終われと言われた後に「作り直しを始める」と名乗って `swift build` を
    /// 起こし、「途中で止めた」記録が書かれうる (#2518 の反証)。
    @Test("最初の世代を待っている間に終われと言われたら、作り直しを始めず、始めなかったと記録する")
    @MainActor
    func aStopRequestedWhileTheStartTakesTheStampStartsNothing() async throws {
        let recorder = WatchSessionTests.Recorder()
        let gate = Gate()
        recorder.whileStamping = { await gate.wait() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        var announced = 0
        session.willRebuild = { _ in announced += 1 }

        let starting = Task { await session.start() }
        try await waitUntil { gate.isWaiting }
        #expect(await !WatchCommand.step(session, stopped: { true }), "抜けていない")

        gate.open()
        let report = await starting.value
        #expect(recorder.builds == 0, "終われと言われた後に作り直した")
        #expect(announced == 0, "終われと言われた後に、作り直しを始めると名乗った")
        #expect(recorder.launches == 0, "終われと言われた後に子を起こした")
        #expect(!report.ok)
        #expect(!report.launched)
        #expect(report.output == WatchSession.notStartedNotice)
        #expect(try writtenOutput(of: session) == WatchSession.notStartedNotice, "始めなかったことを記録していない")
    }

    /// **本物の口が外で読むこと。** 上の検査は替え玉の `stamp` が関門で待つ形なので、
    /// `live` の側で main actor のまま読む形に戻っても緑のままになる。ここでは本物の読み手の
    /// 要約の中から、2 つを見る:
    ///
    /// - 要約が main で呼ばれていないこと (呼ばれたら塞がずに名乗る — 塞ぐと固まる)
    /// - 要約の最中に main が空いていること。**main へ仕事を 1 つ積み、それが走るまで要約を
    ///   終えない** — 外で読んでいても main を塞いで待つ形 (同期で待ち合わせる形) なら、積んだ
    ///   仕事は要約が終わるまで走れない
    ///
    /// **時間ではなく、積んだ仕事が走ったかで見る。** 走るまでの待ちには期限を持たせるが、
    /// それは塞がれたまま固まらないための上限で、混んだ日に赤くならないよう十分長く取る —
    /// main actor の検査が並ぶと、空くまで数十秒待つことがある (手元の cli の全件で 60 秒を
    /// 越えた)。緑の実装では main が空いた時点で抜けるので、長く取っても待ちは延びない。
    @Test("本物の世代の口は、要約を main actor の外で取り、その間 main を空ける")
    @MainActor
    func theLiveStampSummarizesOffTheMainActor() async throws {
        let sketch = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: sketch) }
        try "// swift-tools-version: 6.2\n".write(
            to: sketch.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let onMain = Flag()
        let mainRanMeanwhile = Flag()
        let reader = SourceStamp.Reader(summarize: { url in
            if Thread.isMainThread {
                onMain.raise()
            } else {
                let ran = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { ran.signal() }
                if ran.wait(timeout: .now() + 300) == .success { mainRanMeanwhile.raise() }
            }
            return SourceStamp.Reader.digest(of: url)
        })
        let running = RunningBuild()
        let hooks = WatchSession.Hooks.live(
            resolver: .live(in: sketch, invocation: Invocation(), running: running),
            running: running, stamps: reader)

        let stamp = await hooks.stamp(sketch)
        #expect(!onMain.isRaised, "要約を main actor で取っている")
        #expect(
            onMain.isRaised || mainRanMeanwhile.isRaised,
            "要約の最中に main へ積んだ仕事が走らなかった — 世代を待つ間 main が塞がっている")
        #expect(stamp == SourceStamp.current(for: sketch))
    }

    /// 待たずに戻ることを、期限つきで見る。
    ///
    /// **戻らない検査は赤くならずに固まる。** ここで見たいのは「作り直しの最中に来た巡回が
    /// **待たずに**戻る」ことで、印を落とした実装では 2 本目が関門に入ったまま返らない —
    /// 素直に `await` すると、検査は落ちるのではなく走り続ける。
    ///
    /// - Parameter mark: 帳面に積む名前。同じ検査で 2 度使うので、見分けが要る。
    @MainActor
    private func returnsWithoutWaiting<T: Sendable>(
        _ log: Log, _ mark: String, within seconds: Double = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ work: @escaping @MainActor () async -> T
    ) async throws -> T {
        let running = Task { @MainActor () -> T in
            let value = await work()
            log.append(mark)
            return value
        }
        try await waitUntil(
            { log.entries.contains(mark) }, within: seconds, sourceLocation: sourceLocation)
        return await running.value
    }

    // MARK: - 終えるときに作り直しを止める (#1147)

    /// 区画に書かれた作り直しの記録の本文。**書かれていなければ `nil`。**
    private func writtenOutput(of session: WatchSession) throws -> String? {
        let url = BuildReport.statusURL(under: session.facetBase)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return (object as? [String: Any])?["output"] as? String
    }

    /// **止めた作り直しも、いずれ終了コードを持って戻ってくる。** そこで失敗として書き直すと
    /// 「途中で止めた」が「壊れていた」に化け、子を起こせば止める者の居ない子が残る
    /// ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    @Test("作り直しの最中に止めると、止めた記録を書き、戻ってきた結果で書き直さない")
    @MainActor
    func stoppingARebuildRecordsItAndIgnoresTheLateResult() async throws {
        let (recorder, gate, session) = try makeWaitingSession()
        // **戻ってきたら失敗として書かれる形にしておく** — 止めた子はふつう 0 以外で戻る
        recorder.buildStatus = 2
        recorder.buildOutput = "error: interrupted"

        let building = Task { await session.start() }
        try await waitUntil { gate.isWaiting }

        // 替え玉の作り直しは子を起こさないので、止める相手は居ない
        #expect(await session.stopRebuilding() == .notRunning)
        let stopped = try #require(session.lastReport, "止めた記録が残っていない")
        #expect(!stopped.ok)
        #expect(!stopped.launched)
        #expect(stopped.output == WatchSession.stoppedRebuildNotice)
        #expect(
            try writtenOutput(of: session) == WatchSession.stoppedRebuildNotice,
            "区画に止めた記録が書かれていない")
        #expect(await session.stopRebuilding() == nil, "同じ作り直しを 2 度止めた")

        gate.open()
        #expect(await building.value == stopped, "止めた記録が、戻ってきた結果で書き直された")
        #expect(session.lastReport == stopped)
        #expect(
            try writtenOutput(of: session) == WatchSession.stoppedRebuildNotice,
            "区画の記録が、戻ってきた結果で書き直された")
        #expect(recorder.launches == 0, "止めた作り直しの後に子を起こした")
    }

    @Test("作り直していなければ、止めても何も書かない")
    @MainActor
    func stoppingWithoutARebuildWritesNothing() async throws {
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: WatchSessionTests.Recorder().hooks())

        #expect(await session.stopRebuilding() == nil, "作り直していないのに止めたと答えた")
        #expect(session.lastReport == nil)
        #expect(try writtenOutput(of: session) == nil, "作り直していないのに記録を書いた")
    }

    /// **`SIGTERM` では `swift build` の配下が残る。** SwiftPM が畳みの処理を持つのは `SIGINT`
    /// の側で、`SIGTERM` では本体だけが死に、`swift-driver` と `swift-frontend` が launchd に
    /// 付け替えられて残った (#1147 の実測)。ここでは `SIGTERM` に応えず `SIGINT` にだけ応える
    /// 子で模す — `SIGTERM` で頼めば期限まで待たされて `.killed` になる。
    @Test("作り直しは SIGINT で頼んで止める")
    @MainActor
    func theRebuildIsAskedToStopWithAnInterrupt() async throws {
        let recorder = WatchSessionTests.Recorder()
        let gate = Gate()
        recorder.whileBuilding = { await gate.wait() }

        // **眠らせずに、来ない入力を待たせる。** 眠らせると、落とした後に眠りだけが残る
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = ["-c", "trap '' TERM; trap 'exit 0' INT; echo ready; read line"]
        let output = Pipe()
        build.standardInput = Pipe()
        build.standardOutput = output
        build.standardError = FileHandle.nullDevice
        try build.run()
        defer { if build.isRunning { kill(build.processIdentifier, SIGKILL) } }
        // **仕掛け終わるまで待つ。** 起こした直後に撃つと、罠を張る前の既定の振る舞いで死ぬ
        _ = output.fileHandleForReading.availableData

        var hooks = recorder.hooks()
        hooks.stopRebuild = { build }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: hooks, stopTimeout: 1)
        let building = Task { await session.start() }
        try await waitUntil { gate.isWaiting }

        #expect(await session.stopRebuilding() == .terminated, "SIGINT で頼んでいない")
        #expect(!build.isRunning)

        gate.open()
        _ = await building.value
    }

    /// **口から通す。** 止める判断が在っても、終えるときに呼ばれなければ `swift build` は残る。
    @Test("見張りを終えると、走っている作り直しも止まる")
    @MainActor
    func finishingStopsTheRebuild() async throws {
        let (_, gate, session) = try makeWaitingSession()
        let building = Task { await session.start() }
        try await waitUntil { gate.isWaiting }

        await WatchCommand.finish(session)
        #expect(
            session.lastReport?.output == WatchSession.stoppedRebuildNotice,
            "終えるときに作り直しを止めていない")

        gate.open()
        _ = await building.value
    }

    /// 条件が成り立つまで待つ。**期限は待つ側が持つ。**
    ///
    /// 綴りは `Tests/MokumeCoreTests/FrameSyncTests.swift` の同名の助けに合わせてある。
    private func waitUntil(
        _ condition: @MainActor () -> Bool, within seconds: Double = 5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = DispatchTime.now() + seconds
        while await !condition(), DispatchTime.now() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(
            await condition(), "\(seconds) 秒待っても届かなかった", sourceLocation: sourceLocation)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watch-off-main-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
