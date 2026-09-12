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
