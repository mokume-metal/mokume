// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
        #expect(session.stopRebuilding() == .notRunning)
        let stopped = try #require(session.lastReport, "止めた記録が残っていない")
        #expect(!stopped.ok)
        #expect(!stopped.launched)
        #expect(stopped.output == WatchSession.stoppedRebuildNotice)
        #expect(
            try writtenOutput(of: session) == WatchSession.stoppedRebuildNotice,
            "区画に止めた記録が書かれていない")
        #expect(session.stopRebuilding() == nil, "同じ作り直しを 2 度止めた")

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
    func stoppingWithoutARebuildWritesNothing() throws {
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: WatchSessionTests.Recorder().hooks())

        #expect(session.stopRebuilding() == nil, "作り直していないのに止めたと答えた")
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

        #expect(session.stopRebuilding() == .terminated, "SIGINT で頼んでいない")
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

        WatchCommand.finish(session)
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
        let deadline = Date().addingTimeInterval(seconds)
        while await !condition(), Date() < deadline {
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
