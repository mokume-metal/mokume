// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 子を止める待ちが main actor を塞がないこと
/// ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
///
/// 止める待ちは、頼んでから期限 (3 秒) まで・強制終了してから消えるまで (0.5 秒) で、最悪は
/// 3.5 秒続く。main の上で眠って待つと、そのあいだ道具の窓の描き直し・× の問い・巡回が
/// まとめて止まる (#2518 が世代の取得で直したのと同じ形)。
///
/// **見ているのは時間ではなく順序である** (``WatchOffMainTests`` と同じ)。応えない子へ
/// SIGTERM が届いたことを、子自身が印のファイルで名乗る。**印が main の上で読めた時点で、
/// 子はまだ生きている** — 待っている間に main が働けた証拠で、main が塞がっていれば印が
/// 読めるのは待ちが終わった後 (子が強制終了された後) になる。期限は待つ側が持ち、
/// `.timeLimit` は使わない。
@Suite("子を止める待ちは main を塞がない", .signalStateKept)
@MainActor
struct WatchStopOffMainTests {
    /// SIGTERM を受けたことを印で名乗り、応えずに回り続ける子を起こす外側。
    ///
    /// **印は子ごとに別のファイル** (`marks[i]` が `i` 番目の子の印)。起こした順に溜まる。
    @MainActor
    final class Stubborn {
        /// 起こした子。
        private(set) var children: [Process] = []
        /// 起こした子が SIGTERM を受けたときに 1 行足す印のファイル。
        private(set) var marks: [URL] = []
        /// 子ごとの仕掛け完了の名乗り。
        let ready = WatchSessionTests.Ready()
        /// 起こしたとき、前の子がまだ生きていたか (止めてから起こす約束を見る)。
        private(set) var previousWasAliveAtLaunch: [Bool] = []
        private let folder: URL

        init(folder: URL) { self.folder = folder }

        func hooks() -> WatchSession.Hooks {
            WatchSession.Hooks(
                rebuild: { directory in
                    RunCommand.Rebuilt(
                        status: 0, output: "", executable: URL(fileURLWithPath: "/bin/sh"),
                        binPath: directory, product: "sketch")
                },
                launch: { executable, _, _, _ throws(CommandFailure) in
                    self.previousWasAliveAtLaunch.append(self.children.last?.isRunning ?? false)
                    let mark = self.folder.appendingPathComponent("term-\(self.children.count)")
                    let process = Process()
                    process.executableURL = executable
                    // **印は SIGTERM の罠が作る。応えずに回り続ける。** 眠りは短く刻む — 罠は
                    // 実行中の外部コマンドが終わってから走るので、長く眠ると印が遅れる
                    process.arguments = [
                        "-c", "trap 'echo x >> \"$0\"' TERM; echo ready; while :; do sleep 0.05; done",
                        mark.path,
                    ]
                    let pipe = Pipe()
                    process.standardInput = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                    } catch {
                        throw .cannotLaunch(tool: "sh", place: "", reason: "\(error)")
                    }
                    self.ready.pipes.append(pipe)
                    self.children.append(process)
                    self.marks.append(mark)
                    return process
                },
                now: { 0 },
                stamp: { _ in UUID().uuidString })
        }

        /// 最後に起こした子が仕掛け終わる (罠を張り終える) まで待つ。
        func waitUntilReady() { ready.waitForLast() }

        /// `index` 番目の子が SIGTERM を受けたか。
        func received(_ index: Int) -> Bool { terms(of: index) > 0 }

        /// `index` 番目の子が SIGTERM を受けた回数。**重ねて頼まれたかを見る。**
        func terms(of index: Int) -> Int {
            guard marks.indices.contains(index),
                let text = try? String(contentsOf: marks[index], encoding: .utf8)
            else { return 0 }
            return text.split(separator: "\n").count
        }

        /// 後始末。**応えない子は残さない。**
        func killAll() {
            for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func makeStubborn() throws -> (Stubborn, URL) {
        let folder = try makeDirectory()
        return (Stubborn(folder: folder), folder)
    }

    /// 期限は長く取る。**待つ検査は子を自分で強制終了して打ち切る** ので、緑のときは長さに
    /// 効かない。赤のとき (main が塞がっているとき) だけ、この期限まで待たされる。
    ///
    /// **同じ走者の他の検査が main を数秒塞ぐことがある** (見張りの口の検査は本物の `swift` を
    /// 起こす)。期限が短いと、検査が印を見る前に実装が子を落としてしまう。
    ///
    /// **120 秒にしたのは、並列の幅を広げたホスト (3 コア) で 30 秒を越えたから** (#3196)。
    /// 入れ子の `swift build` と重なると子の立ち上げと印の待ちが遅れ、「退役の途中の子」の検査が
    /// 36.7 秒で、退役の子が期限で落とされた後に `isRunning` を見て赤になった (#3199 の
    /// run 40183767303)
    private static let stopTimeout: TimeInterval = 120

    // MARK: - 差し替え

    /// 窓を持たない見張りは、止めてから起こす。**止める待ちの最中も main が働けること。**
    @Test("差し替えで応えない子を止めている最中も、main actor は別の仕事を進められる")
    func theMainActorIsFreeWhileASwapStopsTheChild() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout)
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)

        let swapping = Task { await session.tick() }
        // 頼んだ (SIGTERM が届いた) ことを、子が名乗るまで待つ。**待っている間に main が
        // 空いていなければ、ここは待ちが終わった後でしか返らない**
        try await waitUntil { stubborn.received(0) }
        #expect(first.isRunning, "止める待ちが終わってからでないと main が働けていない")

        // 応えない子は、こちらが落として待ちを打ち切る
        kill(first.processIdentifier, SIGKILL)
        _ = await swapping.value
        #expect(session.lastStop == .terminated, "待っている間に子が落ちたのに、強制終了と名乗っている")
        // **止めてから起こす。** 前の子が生きたまま次の子を起こしていない
        #expect(stubborn.previousWasAliveAtLaunch == [false, false])
        #expect(stubborn.children.count == 2)
    }

    // MARK: - 退役

    /// 窓が新しい世代へ入れ替わった合図で、前の世代を止める。**合図は窓から main に来る。**
    @Test("入れ替わりの合図で前の世代を止めている最中も、main actor は別の仕事を進められる")
    func theMainActorIsFreeWhileTheOutgoingChildRetires() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout)
        session.overlapsGenerations = true
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)
        await session.tick()
        stubborn.waitUntilReady()
        #expect(session.outgoing === first, "前の世代を控えていない")

        let retiring = Task { await session.generationPromoted() }
        try await waitUntil { stubborn.received(0) }
        #expect(first.isRunning, "止める待ちが終わってからでないと main が働けていない")

        kill(first.processIdentifier, SIGKILL)
        #expect(await retiring.value == .terminated)
        #expect(session.outgoing == nil)
    }

    /// **乗り換えの合図の後、前の世代を止め終えるまで `outgoing` は残るが、台は既に新しい子へ映している**
    /// ([#2983])。この間に次の保存が来ても、映っている新しい子の頼みを手放させない — 「前の世代が居る」を
    /// 「まだ乗り換えていない」と読むと、生きて映っている世代のカーソルの頼みが下りる。
    ///
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    @Test("乗り換えの合図の後、前の世代を止めている最中に次の保存が来ても、映っている世代を手放させない")
    func aSwapWhileTheOutgoingStopsDoesNotRelinquishTheDisplayedGeneration() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout)
        session.overlapsGenerations = true
        var told = 0
        session.relinquishesDisplay = { _ in told += 1 }
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)
        await session.tick()
        stubborn.waitUntilReady()
        #expect(session.outgoing === first)

        // 新しい子が乗り換えた合図。前の世代は止まらないので、止め終わるまで `outgoing` が残る
        let retiring = Task { await session.generationPromoted() }
        try await waitUntil { stubborn.received(0) }
        #expect(session.outgoing === first, "検査の前提: 止め終えるまで前の世代が残る")

        // その間に次の保存。映っているのは乗り換えた新しい子なので、台へ手放したとは伝えない
        let swapping = Task { await session.tick() }
        try await Task.sleep(for: .milliseconds(100))
        kill(first.processIdentifier, SIGKILL)
        _ = await retiring.value
        _ = await swapping.value
        stubborn.waitUntilReady()
        #expect(told == 0, "映っている新しい子の頼みを手放させた")
    }

    /// **前の世代を止める待ちの間に、台が次の世代へ乗り換えることがある** ([#2983] の反証)。台の乗り換えは表示の
    /// 拍で同期に起き、見張りが待ちを下ろすのは合図の `Task` が走ってからである。判定を待つ前にだけ決めて
    /// 待った後に伝えると、生きて映っている新しい世代の頼みを下ろす。番号を名乗らない世代では、番号で
    /// 外せないので、待った後にもう 1 度、まだ乗り換えを待っているかを見る。
    ///
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    @Test("前の世代を止めている間に台が乗り換えたら、映っている世代を手放させない")
    func aPromotionDuringTheStopDoesNotRelinquishTheNewDisplayedGeneration() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout)
        session.overlapsGenerations = true
        var told = 0
        session.relinquishesDisplay = { _ in told += 1 }
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)
        await session.tick()
        stubborn.waitUntilReady()
        #expect(session.outgoing === first)

        // 合図が来ないまま次の保存: 映っている世代 (first) を止め始める
        let swapping = Task { await session.tick() }
        try await waitUntil { stubborn.received(0) }
        // 止めている間に、台が待っていた世代へ乗り換えた合図 (番号を名乗らない世代)
        let promoting = Task { await session.generationPromoted() }
        kill(first.processIdentifier, SIGKILL)
        _ = await swapping.value
        _ = await promoting.value
        stubborn.waitUntilReady()
        #expect(told == 0, "止めている間に台が乗り換えたのに、映っている世代を手放させた")
    }

    /// **合図は窓ごとに来て、2 度呼ばれる。** 止めている最中に 2 度目が来ても、同じ子を
    /// 重ねて止めない — 名乗りも 1 度である。
    @Test("退役の合図が重なっても、同じ子を 1 度しか止めない")
    func aSecondSignalDuringRetirementJoinsTheFirst() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout)
        session.overlapsGenerations = true
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)
        await session.tick()
        stubborn.waitUntilReady()

        let one = Task { await session.generationPromoted() }
        let two = Task { await session.generationPromoted() }
        try await waitUntil { stubborn.received(0) }
        kill(first.processIdentifier, SIGKILL)

        // **2 度目を先に待つ。** 2 度目は止め終わるまで戻らない (置いていかない)
        let second = await two.value
        #expect(!first.isRunning, "2 度目の合図が、止め終わる前に戻っている")
        let outcomes = [await one.value, second]
        #expect(outcomes.compactMap { $0 } == [.terminated], "止めたことを 2 度名乗っている")
        #expect(stubborn.terms(of: 0) == 1, "同じ子へ SIGTERM を重ねて撃っている")
    }

    // MARK: - 終える

    /// 終えるときは窓が開いたまま待つ (撮っていた動画を閉じ終えるまで最大 38 秒)。
    @Test("終えるときに子を止めている最中も、main actor は別の仕事を進められる")
    func theMainActorIsFreeWhileTheEndStopsTheChild() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout, finishTimeout: Self.stopTimeout)
        await session.start()
        stubborn.waitUntilReady()
        let child = try #require(session.child)

        let ending = Task { await session.end() }
        try await waitUntil { stubborn.received(0) }
        #expect(child.isRunning, "止める待ちが終わってからでないと main が働けていない")

        kill(child.processIdentifier, SIGKILL)
        #expect(await ending.value == .terminated)
        #expect(session.child == nil)
    }

    /// **口から通す。** 判断が async でも、後始末の口が待たずに抜ければ子は残る。
    @Test("見張りの後始末は、子を止め終えてから戻り、待っている間 main actor を塞がない")
    func finishWaitsForTheChildWithoutBlockingMain() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout, finishTimeout: Self.stopTimeout)
        await session.start()
        stubborn.waitUntilReady()
        let child = try #require(session.child)

        let finishing = Task { await WatchCommand.finish(session) }
        try await waitUntil { stubborn.received(0) }
        #expect(child.isRunning, "止める待ちが終わってからでないと main が働けていない")

        kill(child.processIdentifier, SIGKILL)
        await finishing.value
        #expect(!child.isRunning, "子を止め終える前に戻っている")
        #expect(session.child == nil)
    }

    /// **退役の途中の子も、終えるときは置いていかない。** 退役を始めたのは窓の合図で、終える
    /// 手続きとは別の口である — 外していない子 (まだ消えていない) を待たずに戻ると、止める者が
    /// 居ない子を残す (#454)。
    @Test("終えるときは、退役の途中の子が止め終わるまで戻らない")
    func endWaitsForARetirementInFlight() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout, finishTimeout: Self.stopTimeout)
        session.overlapsGenerations = true
        await session.start()
        stubborn.waitUntilReady()
        let retired = try #require(session.child)
        await session.tick()
        stubborn.waitUntilReady()
        let current = try #require(session.child)

        let retiring = Task { await session.generationPromoted() }
        try await waitUntil { stubborn.received(0) }
        var ended = false
        let ending = Task { () -> WatchSession.StopOutcome in
            let outcome = await session.end()
            ended = true
            return outcome
        }
        // 現役の子も止めに入る。**こちらを先に落としても、退役の途中の子が済むまでは戻らない**
        try await waitUntil { stubborn.received(1) }
        kill(current.processIdentifier, SIGKILL)
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(retired.isRunning)
        #expect(!ended, "退役の途中の子が残っているのに戻っている")

        kill(retired.processIdentifier, SIGKILL)
        _ = await retiring.value
        _ = await ending.value
        #expect(ended)
        #expect(!retired.isRunning)
        #expect(session.child == nil)
        #expect(session.outgoing == nil)
    }

    // MARK: - 待っている間に来た合図

    /// 止める待ちの最中に main が空くので、**その間に終われと言われうる**。待ちが終わった
    /// 後で、終われと言われた回に新しい子を起こさない (起こすと止める者が居ない — #454)。
    @Test("差し替えで止めている最中に終われと言われたら、止め終えても次の子を起こさない")
    func aStopRequestedDuringASwapStartsNoNewChild() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout, finishTimeout: Self.stopTimeout)
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)

        let swapping = Task { await session.tick() }
        try await waitUntil { stubborn.received(0) }

        // 見張りを終える。**差し替えの止めと同じ子を止めに行く** — 1 つの止め方に畳まれる
        session.noteStopRequested()
        let finishing = Task { await WatchCommand.finish(session) }
        // **重ねて頼むなら届く隙を渡す。** 子の罠は 50 ミリ秒ごとに走る
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(stubborn.terms(of: 0) == 1, "同じ子へ SIGTERM を重ねて撃っている")
        kill(first.processIdentifier, SIGKILL)
        await finishing.value
        _ = await swapping.value

        #expect(stubborn.children.count == 1, "終われと言われた後に次の子を起こした")
        #expect(!first.isRunning)
        #expect(session.child == nil, "止めた子を持ったままでいる")
        #expect(session.outgoing == nil)
    }

    /// 作り直しを止めている最中に、止めた作り直しが戻ってくる。**止めた記録は書き直されない。**
    ///
    /// 止める待ちが main actor を塞いでいた頃は、止めた記録を書き終えるまで作り直しの続きは
    /// 走れなかった。塞がなくなると、続きが先に走って失敗の記録を書き、止めた記録を上書き
    /// (または、止めた記録の後で失敗を返す) しうる (#1147 の約束)。
    @Test("作り直しを止めている最中に作り直しが戻ってきても、止めた記録のままになる")
    func aRebuildReturningWhileItIsBeingStoppedKeepsTheStoppedRecord() async throws {
        let folder = try makeDirectory()
        let mark = folder.appendingPathComponent("int")
        // **SIGINT に応えない作り直し。** こちらが落とすまで、止める待ちが続く
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = [
            "-c", "trap ': > \"$0\"' INT; echo ready; while :; do sleep 0.05; done", mark.path,
        ]
        let output = Pipe()
        build.standardInput = Pipe()
        build.standardOutput = output
        build.standardError = FileHandle.nullDevice
        try build.run()
        defer { if build.isRunning { kill(build.processIdentifier, SIGKILL) } }
        _ = output.fileHandleForReading.availableData

        let recorder = WatchSessionTests.Recorder()
        let gate = WatchOffMainTests.Gate()
        recorder.whileBuilding = { await gate.wait() }
        // **戻ってきたら失敗として書かれる形にしておく** — 止めた子はふつう 0 以外で戻る
        recorder.buildStatus = 2
        recorder.buildOutput = "error: interrupted"
        var hooks = recorder.hooks()
        hooks.stopRebuild = { build }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: hooks,
            stopTimeout: Self.stopTimeout)

        let building = Task { await session.start() }
        try await waitUntil { gate.isWaiting }
        let stopping = Task { await session.stopRebuilding() }
        try await waitUntil { FileManager.default.fileExists(atPath: mark.path) }
        #expect(build.isRunning, "止める待ちが終わってからでないと main が働けていない")

        // **止めている最中に、作り直しが戻ってくる。** 続きが走る隙を渡す (止め終わるまでは、
        // 続きは記録を決めない)
        gate.open()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        kill(build.processIdentifier, SIGKILL)
        #expect(await stopping.value == .terminated)

        let stopped = try #require(session.lastReport, "止めた記録が残っていない")
        #expect(stopped.output == WatchSession.stoppedRebuildNotice, "止めた記録が失敗で書き直された")
        #expect(await building.value == stopped, "戻ってきた結果が、止めた記録と別のものになっている")
        #expect(recorder.launches == 0, "止めた作り直しの後に子を起こした")
    }

    // MARK: - 後始末の入口

    /// **終わりの経路は 2 つある** (巡回を抜けるとき・道具立ての終了)。2 つ目は、先の手続きが
    /// 済むまで待って戻る — 重ねて子を止めない・名乗りを重ねない。
    @Test("後始末が重なっても、子を止めるのは 1 度で、後から来た側も止め終わるまで戻らない")
    func aSecondFinishWaitsForTheFirst() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout, finishTimeout: Self.stopTimeout)
        await session.start()
        stubborn.waitUntilReady()
        let child = try #require(session.child)

        let first = Task { await WatchCommand.finish(session) }
        try await waitUntil { stubborn.received(0) }
        var secondReturned = false
        let second = Task {
            await WatchCommand.finish(session)
            secondReturned = true
        }
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!secondReturned, "先の手続きが済む前に戻っている")
        #expect(stubborn.terms(of: 0) == 1, "同じ子へ SIGTERM を重ねて撃っている")

        kill(child.processIdentifier, SIGKILL)
        await first.value
        await second.value
        #expect(secondReturned)
        #expect(session.finishStage == .done)
        #expect(!child.isRunning)
    }

    /// 通常の終わり方は窓を開いたまま済むので、道具立てが終わる直前の後始末は取りこぼしを拾うだけ。
    /// **済んでいれば何もしない / 済んでいなければ、同じ手順で止める** (置いていかない)。
    @Test("プロセスが終わる直前の後始末は、済んでいれば何もせず、残っていれば同じ手順で止める")
    func theBlockingFinishOnlyCatchesWhatIsLeft() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: 0.3, finishTimeout: 0.3)
        await session.start()
        stubborn.waitUntilReady()
        let child = try #require(session.child)

        // 残っていれば、同じ手順 (頼む → 期限 → 強制終了) で止める
        WatchCommand.finishBlocking(session)
        #expect(!child.isRunning, "残っていた子を止めていない")
        #expect(session.finishStage == .done)
        #expect(session.lastStop == .killed)

        // 済んでいれば何もしない
        let other = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: 0.3, finishTimeout: 0.3)
        await other.start()
        stubborn.waitUntilReady()
        let alive = try #require(other.child)
        other.finishStage = .done
        WatchCommand.finishBlocking(other)
        #expect(alive.isRunning, "済んでいる後始末が、子を止めた")
    }

    // MARK: - 手順

    /// 止める手順は、待たずに 1 歩ずつ進む。**頼む → 期限 → (延ばす) → 強制終了 → 消えるのを待つ。**
    @Test("止める手順は、延ばす待ちを 1 度だけ名乗り、強制終了で決着する")
    func theShutdownStepsInOrder() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks())
        await session.start()
        stubborn.waitUntilReady()
        let child = try #require(session.child)

        var shutdown = WatchSession.Shutdown(
            child, timeout: 0.3, stopTimeout: 0.1, killGrace: 2, interrupting: false)
        var extensions: [TimeInterval] = []
        var outcome: WatchSession.StopOutcome?
        let deadline = DispatchTime.now() + 10
        while outcome == nil, DispatchTime.now() < deadline {
            switch shutdown.poll(now: DispatchTime.now()) {
            case .waiting: break
            case .extending(let remaining): extensions.append(remaining)
            case .finished(let result): outcome = result
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(outcome == .killed)
        // 最初の期限 (0.1) を越えたら、残り (0.2) を 1 度だけ名乗る
        #expect(extensions.count == 1)
        #expect(abs((extensions.first ?? 0) - 0.2) < 0.001)
    }

    // MARK: - 止めている最中の子は、勝手に消えたと名乗らない

    /// 止める待ちが main actor を塞がなくなったので、子が死んでから ``WatchSession/child`` を外すまでの
    /// 間に巡回 (`departed()`) が来る。**道具が止めている子を、スケッチが自分で消えたと名乗らない。**
    @Test("止めている最中の子は、死んでも勝手に消えたと名乗られない")
    func aChildBeingStoppedIsNotNamedAsDeparted() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout)
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)

        let swapping = Task { await session.tick() }
        try await waitUntil { stubborn.received(0) }

        // 子を落とし、**止める側が結果を持ち帰る前** (main を塞いだまま) に巡回が来る形を作る
        kill(first.processIdentifier, SIGKILL)
        let deadline = DispatchTime.now() + 5
        while first.isRunning, DispatchTime.now() < deadline { usleep(5000) }
        #expect(!first.isRunning)
        #expect(session.child === first, "止め終える前に child を外している")
        #expect(session.departed() == nil, "道具が止めている子を、勝手に消えたと名乗った")

        _ = await swapping.value
        #expect(session.lastStop == .terminated)
    }

    // MARK: - 止められる作り直しがあるときだけ、止めた記録を書く

    /// 差し替えの最中は、作り直しは建ち終えている。**止めた記録を書くと、建ち終えた回が
    /// 「途中で止めた」ことになる。**
    @Test("差し替えの最中に作り直しを止めようとしても、止めた記録は書かない")
    func stoppingTheRebuildDuringASwapWritesNoStoppedRecord() async throws {
        let (stubborn, _) = try makeStubborn()
        defer { stubborn.killAll() }
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: stubborn.hooks(),
            stopTimeout: Self.stopTimeout, finishTimeout: Self.stopTimeout)
        await session.start()
        stubborn.waitUntilReady()
        let first = try #require(session.child)

        let swapping = Task { await session.tick() }
        try await waitUntil { stubborn.received(0) }
        // 差し替えの最中 (`swift` は走っていない) に、終わりの手続きが作り直しを止めに来る
        #expect(await session.stopRebuilding() == nil, "走っていない作り直しを止めたと答えた")
        #expect(session.lastReport?.output != WatchSession.stoppedRebuildNotice, "止めた記録を書いている")

        session.noteStopRequested()
        kill(first.processIdentifier, SIGKILL)
        let report = try #require(await swapping.value)
        // 建ち終えた回は、終わりで起こさなかった回として記録される (止めた記録ではない)
        #expect(report.ok)
        #expect(report.output.hasPrefix(WatchSession.stopRequestedNotice))
        #expect(stubborn.children.count == 1)
    }

    // MARK: - 道具立ての終了 (Dock・⌘Q・ログアウト)

    /// `terminate(_:)` が main actor の仕事から呼ばれると、`Task` の続きは永久に来ず、終わりが
    /// 保留されたまま固まる (実測・`SketchApplicationDelegate.shouldTerminate` の作法)。**止める仕事は
    /// 窓の × と同じ印で既にある道に任せ、済んだかは Timer から見に来る。**
    @Test("終了の問いは、終われの印を立てて保留し、止め終えたら 1 度だけ返す")
    func terminationIsDeferredUntilTheChildIsStopped() {
        var stops = 0
        var finished = false
        var replies: [Bool] = []
        let delegate = WatchCommand.ApplicationDelegate(
            stopRequested: { stops += 1 }, isFinished: { finished }, teardown: {},
            reply: { replies.append($0) })
        defer { finished = true; delegate.pollFinish() }

        #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
        #expect(stops == 1, "終われと言われたことを伝えていない")
        #expect(delegate.isWaitingToTerminate)
        // 2 度目の問いも保留のまま (見に来る仕掛けは 1 つ)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
        #expect(stops == 2)

        delegate.pollFinish()
        #expect(replies.isEmpty, "止め終える前に返している")

        finished = true
        delegate.pollFinish()
        #expect(replies == [true])
        #expect(!delegate.isWaitingToTerminate)
        delegate.pollFinish()
        #expect(replies == [true], "返事を重ねている")
    }

    @Test("止め終えているときの終了の問いは、保留せずに終わらせる")
    func terminationIsImmediateWhenAlreadyStopped() {
        var replies: [Bool] = []
        let delegate = WatchCommand.ApplicationDelegate(
            stopRequested: {}, isFinished: { true }, teardown: {}, reply: { replies.append($0) })
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
        #expect(!delegate.isWaitingToTerminate)
        #expect(replies.isEmpty)
    }

    /// 原文を読む (#600 と同じ形)。**終了の問いの中で `Task` を使わない** — 使うと、上の実測の
    /// 固まりが戻る。呼んで確かめる道が無い (固まりは実機の `terminate(_:)` の呼ばれ方に依る)。
    @Test("終了の問いの中に Task が無い")
    func theTerminationQuestionSpawnsNoTask() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MokumeCLI/WatchCommand.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "func applicationShouldTerminate"))
        let rest = text[start.lowerBound...]
        let end = try #require(rest.range(of: "func pollFinish"))
        let body = rest[..<end.lowerBound]
        let code = body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!code.joined().contains("Task"), "終了の問いが Task を起こしている")
    }

    // MARK: - 助け

    /// 条件が成り立つまで待つ。**期限は待つ側が持つが、壁時計では数えない。**
    ///
    /// 同じ走者の他の検査が main を数秒塞ぐと、壁時計の期限は「main が空いた途端に切れて」
    /// いる — 条件を満たす側の仕事も同じ main で待たされているので、順番が回る前に諦めてしまう。
    /// 数えるのは **main が空いて回ってきた回数** で、塞がっている間は進まない。
    private func waitUntil(
        _ condition: @MainActor () -> Bool, turns: Int = 2000,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var turn = 0
        while !condition(), turn < turns {
            try await Task.sleep(for: .milliseconds(5))
            turn += 1
        }
        try #require(
            condition(), "\(turns) 回待っても届かなかった", sourceLocation: sourceLocation)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watch-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
