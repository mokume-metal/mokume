// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// `mokume watch` の試聴 (#3565): 区画 `watch` の要求で入る・出る。入っている間、保存はプレビューだけを新しい版にし、
/// 作品の窓が映す本番の子は止まらない。
///
/// **GPU も窓も使わない。** 台は作らず、台の側の約束 (目録を採る・採らない) は ``WatchAuditionStageTests`` と
/// `SharedFrameStageTests` が見る。ここは見張りの判断 — どの子を起こし、どの子を止め、何を名乗り、
/// 台へ何を伝えるか — を、本物の子 (`/bin/sh`) で見る。
@Suite("試聴に入ると、保存は試聴の子だけを起こし、本番の子は止まらない", .signalStateKept)
@MainActor
struct WatchAuditionTests {
    /// 見張りと台の外側。
    final class Harness {
        let session: WatchSession
        /// 起こした順の子。
        private(set) var gens: [Process] = []
        private var stampCount = 0
        private var requestCount = 0
        /// プレビューへ出した行。
        var previewLines: [String] = []
        /// 台へ伝えた内容。
        var held: [[Int32]] = []
        var returned: [Int32] = []
        var relinquished: [[Int32]] = []
        /// 台が戻れるか (番号ごと)。既定は戻れる。
        var canReturn: (Int32) -> Bool = { _ in true }
        /// 作品の窓が映している世代の番号。既定は、いま走っている本番 (映っている前の世代があればそれ)。
        var windowShows: (() -> Int32?)?
        /// 立てると、次の作り直しは ``releaseRebuild()`` まで終わらない。
        var holdRebuild = false
        private var rebuildGate: CheckedContinuation<Void, Never>?
        /// 作り直しが門で止まっているか。
        var isRebuildHeld: Bool { rebuildGate != nil }

        func waitForRebuildGate() async {
            await withCheckedContinuation { rebuildGate = $0 }
        }

        /// 止めていた作り直しを進める。
        func releaseRebuild() {
            holdRebuild = false
            rebuildGate?.resume()
            rebuildGate = nil
        }

        /// 新しい本番の子を起こしたら、台が乗り換えた合図を送るか。
        var autoPromote = true
        /// 起こす子の台本 (`sh -c`)。
        private let script: String

        init(
            overlapsGenerations: Bool = true, stopTimeout: TimeInterval = 0.5,
            script: String =
                "read line; case \"$line\" in crash) kill -KILL $$;; fail) exit 3;; *) exit 0;; esac"
        ) throws {
            self.script = script
            let directory = try TestScratch.directory("mokume-watch-audition")
            let box = Box()
            session = WatchSession(
                directory: directory, context: testContext(),
                hooks: WatchSession.Hooks(
                    rebuild: { directory in
                        // 作り直しの途中で止めておく (作り直しの最中の出来事を演じる)
                        if let harness = box.harness, harness.holdRebuild { await harness.waitForRebuildGate() }
                        return RunCommand.Rebuilt(
                            status: 0, output: "", executable: URL(fileURLWithPath: "/bin/sh"),
                            binPath: directory, product: "sketch")
                    },
                    launch: { executable, _, _, _ throws(CommandFailure) in
                        guard let harness = box.harness else {
                            throw .cannotLaunch(tool: "sh", place: "", reason: "no harness")
                        }
                        return try harness.launch(executable)
                    },
                    now: { 0 },
                    stamp: { _ in box.harness?.stamp }),
                stopTimeout: stopTimeout, finishTimeout: 0.5)
            session.overlapsGenerations = overlapsGenerations
            box.harness = self
            session.holdsPreviewGeneration = { [unowned self] pids in held.append(pids) }
            session.returnsPreviewToGeneration = { [unowned self] pid in
                returned.append(pid)
                return canReturn(pid)
            }
            session.windowShowsPID = { [unowned self] in
                if let windowShows { return windowShows() }
                return (session.outgoing ?? session.child)?.processIdentifier
            }
            session.relinquishesDisplay = { [unowned self] pids in relinquished.append(pids) }
            session.serveRequests()
        }

        final class Box { weak var harness: Harness? }

        /// 立てると、`save()` を介さずに、ソースの世代をこの値に変える (元に戻した回を演じる)。
        var stampOverride: String?

        private var stamp: String? {
            if let stampOverride { return stampOverride }
            return stampCount == 0 ? nil : "s\(stampCount)"
        }

        /// 1 行読んで、`crash` なら信号 (KILL) で、`fail` なら終了コード 3 で、それ以外は 0 で終わる子。
        private func launch(_ executable: URL) throws(CommandFailure) -> Process {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-c", script]
            process.standardInput = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                throw .cannotLaunch(tool: "sh", place: "", reason: "\(error)")
            }
            gens.append(process)
            return process
        }

        deinit { for process in gens where process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        /// 1 拍。
        func beat() async {
            await WatchCommand.step(
                session, stopped: { false }, preview: { [self] line, _ in
                    if let line { previewLines.append(line) }
                })
        }

        /// 保存して、作り直しが通り、子が起きるまで 1 拍回す。
        @discardableResult
        func save() async -> Process? {
            stampCount += 1
            let before = gens.count
            await beat()
            // 窓の台が新しい本番に乗り換えたことを演じる (この検査は台を作らない)。**乗り換えを待つ間を調べる検査は
            // `autoPromote` を下ろす** — 試聴の子は、本番が乗り換えを待つ間は起こされない
            if gens.count > before, autoPromote, let last = gens.last, session.child === last {
                await session.generationPromoted(pid: last.processIdentifier)
            }
            return gens.count > before ? gens.last : nil
        }

        /// 区画 `watch` へ要求を置き、1 拍回して応答を読む。
        func ask(_ action: String) async throws -> [String: Any] {
            try await ask(json: #"{"id":"r\#(nextID())","action":"\#(action)"}"#)
        }

        private func nextID() -> Int {
            requestCount += 1
            return requestCount
        }

        func ask(json: String) async throws -> [String: Any] {
            let facet = session.watchFacet
            try AtomicFile.write(Data(json.utf8), to: WorkDirectory.requestURL(under: facet))
            await beat()
            return try report()
        }

        func report() throws -> [String: Any] {
            let data = try Data(contentsOf: WorkDirectory.reportURL(under: session.watchFacet))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        /// 子が 1 行読んで、指定のとおりに終わる。
        func tell(_ process: Process, _ line: String, timeout: TimeInterval = 3) {
            guard process.isRunning, let pipe = process.standardInput as? Pipe else { return }
            try? pipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            wait(process, timeout: timeout)
        }

        func wait(_ process: Process, timeout: TimeInterval = 3) {
            let deadline = DispatchTime.now() + timeout
            while process.isRunning, DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        }

        func alive() -> [Process] { gens.filter(\.isRunning) }
    }

    private func stampOf(_ part: Any?) -> String? { (part as? [String: Any])?["stamp"] as? String }
    private func pidOf(_ part: Any?) -> Int32? { ((part as? [String: Any])?["pid"] as? NSNumber)?.int32Value }

    // MARK: - 要求への答え (完了条件 2)

    @Test("入る要求を受け、本番の pid と stamp を名乗る。同じ要求は二度処理しない")
    func auditionIsAcceptedAndNamesProduction() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let report = try await harness.ask("audition")
        #expect(report["accepted"] as? Bool == true)
        #expect(report["reason"] == nil)
        #expect(report["auditioning"] as? Bool == true)
        #expect(report["action"] as? String == "audition")
        #expect(pidOf(report["production"]) == production.processIdentifier)
        #expect(stampOf(report["production"]) == "s1")
        #expect(report["audition"] == nil, "試聴の子はまだ居ない")
        #expect(harness.session.isAuditioning)
        #expect(harness.held == [[production.processIdentifier]], "戻り先の本番を台に留めていない")
        // 拍を重ねても、同じ識別子は二度処理しない (応答が書き直されない)
        let again = try await harness.ask(json: #"{"id":"r1","action":"leave"}"#)
        #expect(again["action"] as? String == "audition", "answered id was processed again: \(again)")
    }

    @Test("試聴に入っていないのに出る要求は、断った理由と、いまの本番を名乗って断る")
    func leaveWithoutAuditionIsDeclinedWithAReason() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let report = try await harness.ask("leave")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "notAuditioning")
        #expect(report["auditioning"] as? Bool == false)
        #expect(pidOf(report["production"]) == production.processIdentifier)
        #expect(!harness.session.isAuditioning)
    }

    @Test("断る理由: 既に試聴中・本番が居ない・プレビューが無い・知らない動作・読めない要求")
    func everyRefusalNamesItsReason() async throws {
        // 本番が居ない
        let empty = try Harness()
        let noProduction = try await empty.ask("audition")
        #expect(noProduction["reason"] as? String == "noProduction")
        #expect(noProduction["accepted"] as? Bool == false && !empty.session.isAuditioning)

        // プレビューが無い (窓を出せなかった見張り)
        let windowless = try Harness(overlapsGenerations: false)
        _ = await windowless.save()
        let noPreview = try await windowless.ask("audition")
        #expect(noPreview["reason"] as? String == "noPreview")
        #expect(!windowless.session.isAuditioning)

        let harness = try Harness()
        _ = await harness.save()
        _ = try await harness.ask("audition")
        _ = await harness.save()
        let again = try await harness.ask("audition")
        #expect(again["reason"] as? String == "alreadyAuditioning")
        #expect(again["auditioning"] as? Bool == true)
        #expect(pidOf(again["audition"]) == harness.gens.last?.processIdentifier, "試聴の子の pid も名乗る")
        #expect(stampOf(again["audition"]) == "s2")

        // `send` は後の段が足す。この段は知らない動作として断る
        let send = try await harness.ask("send")
        #expect(send["reason"] as? String == "unknownAction")
        #expect(send["action"] as? String == "send")

        // 型の違う `action` は解けないが、`id` は読めるので応える
        let unreadable = try await harness.ask(json: #"{"id":"bad","action":5}"#)
        #expect(unreadable["id"] as? String == "bad")
        #expect(unreadable["reason"] as? String == "unreadable")
        #expect((unreadable["detail"] as? String)?.isEmpty == false)
        #expect(unreadable["action"] == nil)
        // 断った要求は何も変えない
        #expect(harness.session.isAuditioning)
    }

    // MARK: - 保存はプレビューだけを変える (完了条件 1・3)

    @Test("試聴中の保存は試聴の子を起こすだけで、本番の子は止まらず、役も動かない")
    func savingWhileAuditioningStartsOnlyTheAuditionChild() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")

        let first = try #require(await harness.save())
        #expect(production.isRunning && first.isRunning)
        #expect(harness.session.child === production, "本番の子が入れ替わった")
        #expect(harness.session.outgoing == nil)
        #expect(harness.session.auditionChild === first)
        #expect(harness.session.waitingGeneration == nil, "試聴の子を起こして、本番が乗り換えを待つ形になった")

        // 試聴中にもう 1 度保存: 前の試聴の子を先に止めてから新しい試聴の子を起こす。本番は止まらない
        let second = try #require(await harness.save())
        #expect(!first.isRunning, "試聴の子が重なった")
        #expect(second.isRunning && production.isRunning)
        #expect(harness.session.child === production && harness.session.auditionChild === second)
        #expect(harness.alive().count == 2, "生きている子は「本番 + 試聴」の 2 つまで")

        let report = try await harness.ask(json: #"{"id":"look","action":"audition"}"#)
        #expect(pidOf(report["production"]) == production.processIdentifier)
        #expect(stampOf(report["production"]) == "s1", "本番の stamp は据え置き")
        #expect(pidOf(report["audition"]) == second.processIdentifier)
        #expect(stampOf(report["audition"]) == "s3")
    }

    @Test("試聴に入らない見張りは、保存したら本番が入れ替わり、試聴の枠は使われない (これまでどおり)")
    func withoutAuditionSavingReplacesProduction() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        let first = try #require(await harness.save())
        let second = try #require(await harness.save())
        #expect(harness.session.child === second && harness.session.outgoing === first)
        #expect(harness.session.auditionChild == nil && !harness.session.isAuditioning)
        #expect(harness.session.auditionPIDs.isEmpty)
        // 関所は何も弾かない
        #expect(harness.session.windowAccepts(pid: second.processIdentifier))
        #expect(harness.session.previewAccepts(pid: second.processIdentifier))
    }

    // MARK: - 合図は本番のものだけを受ける

    @Test("試聴の子の乗り換えの合図は、本番の待ちも前の世代も動かさない")
    func promotionsOfTheAuditionDoNotTouchProduction() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        #expect(harness.session.waitingGeneration == nil)

        // 試聴の子の合図は、本番の側の何も動かさない (記録の測定にも触れない)
        let outcome = await harness.session.generationPromoted(pid: audition.processIdentifier)
        #expect(outcome == nil)
        #expect(production.isRunning && audition.isRunning && harness.session.child === production)
    }

    @Test("試聴の子の乗り換えられない知らせ・倒れた知らせは、本番を畳まない")
    func undeliverableOrFallenAuditionDoesNotRetireProduction() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())

        // 台が試聴の子の絵を受け取れない知らせ (目録が名乗る番号つき)
        let undelivered = await harness.session.retireAfterUndeliverable(
            waiting: production, pid: audition.processIdentifier)
        #expect(undelivered == nil)
        #expect(production.isRunning, "試聴の子の知らせで本番を畳んだ")

        // 試聴の子が倒れた目印は、本番を待たせている世代の知らせとは読まれない
        let facet = WatchCommand.viewportFacet(under: harness.session.facetBase)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        try Data().write(to: WorkDirectory.fellBackURL(forProcess: audition.processIdentifier, under: facet))
        #expect(await harness.session.retireAfterFallback() == nil)
        #expect(harness.session.auditionFellBack(), "試聴の子の倒れた目印を見つけない")
        #expect(!harness.session.auditionFellBack(), "目印は見たら消える")
        #expect(production.isRunning && audition.isRunning)
    }

    // MARK: - 試聴の版が落ちても本番は回り続ける (完了条件 4)

    @Test("試聴の版が 1 枚目より後に落ちても、本番は畳まれず、試聴を続けられる")
    func theAuditionVersionCrashingLeavesProductionRunning() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        // 1 枚目は出した (台が知らせた)
        harness.session.generationShown(pid: audition.processIdentifier)

        harness.tell(audition, "crash")
        #expect(!audition.isRunning)
        harness.previewLines.removeAll()
        await harness.beat()

        #expect(production.isRunning, "試聴の版が落ちて本番を畳んだ")
        #expect(harness.session.child === production)
        #expect(harness.session.isAuditioning, "試聴の版が落ちて試聴が終わった")
        #expect(harness.session.auditionChild == nil)
        let line = try #require(harness.previewLines.last, "プレビューに落ちたことが書かれていない")
        #expect(line.contains("version under audition crashed"), "\(line)")
        #expect(line.contains("work's window keeps running"), "\(line)")
        #expect(harness.relinquished.contains([audition.processIdentifier]), "止まった絵の頼みを下ろしていない")

        // 名乗るのは 1 度きり
        harness.previewLines.removeAll()
        await harness.beat()
        #expect(harness.previewLines.isEmpty)

        // 保存すれば、また試聴の子が起きる。本番はそのまま
        let next = try #require(await harness.save())
        #expect(harness.session.auditionChild === next && harness.session.child === production && production.isRunning)
    }

    @Test("試聴の版が 1 枚も描かずに落ちた回は、起こせなかった回として名乗り、本番は走り続ける")
    func theAuditionVersionFailingToStartKeepsProduction() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        // 1 枚目を出さずに失敗で終わる
        harness.tell(audition, "fail")
        harness.previewLines.removeAll()
        await harness.beat()
        #expect(production.isRunning)
        let line = try #require(harness.previewLines.last)
        #expect(line.contains("exited with code 3"), "\(line)")
        #expect(harness.session.lastReport?.launched == false, "起こせなかった回として記録を書き直す")
        #expect(harness.session.child === production)
    }

    // MARK: - 出る (完了条件 5)

    @Test("出る要求で試聴の子が止まり、プレビューは本番へ戻される。次の保存は両方の窓を入れ替える")
    func leavingStopsTheAuditionAndReturnsThePreview() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        #expect(harness.session.previewAccepts(pid: audition.processIdentifier))

        let report = try await harness.ask("leave")
        #expect(report["accepted"] as? Bool == true)
        #expect(report["auditioning"] as? Bool == false)
        #expect(report["audition"] == nil, "止めた後に試聴の子を名乗っている")
        #expect(pidOf(report["production"]) == production.processIdentifier)
        #expect(!audition.isRunning && production.isRunning)
        #expect(harness.returned == [production.processIdentifier], "プレビューを本番へ戻していない")
        #expect(harness.held == [[production.processIdentifier], []], "留めた本番を外していない")
        #expect(harness.relinquished.contains([audition.processIdentifier]))
        #expect(!harness.session.isAuditioning && harness.session.auditionChild == nil)
        // 出た後、試聴の子の目録は、どちらの窓にも採られない
        #expect(!harness.session.previewAccepts(pid: audition.processIdentifier))
        #expect(!harness.session.windowAccepts(pid: audition.processIdentifier))
        #expect(harness.session.previewAccepts(pid: production.processIdentifier))

        // 次の保存は、これまでどおり両方の窓を入れ替える
        harness.autoPromote = false
        let next = try #require(await harness.save())
        #expect(harness.session.child === next && harness.session.outgoing === production)
        #expect(harness.session.auditionPIDs.isEmpty, "通常の差し替えで試聴の覚えを捨てていない")
        #expect(harness.session.windowAccepts(pid: next.processIdentifier))
        #expect(harness.session.previewAccepts(pid: next.processIdentifier))
    }

    @Test("出る要求のとき本番が居なければ、戻れなかったと名乗り、試聴の子は止める")
    func leavingWithoutProductionStillStopsTheAudition() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        harness.tell(production, "bye")
        await harness.beat()
        #expect(harness.session.isAuditioning && audition.isRunning, "本番が消えても、試聴は続く")

        let report = try await harness.ask("leave")
        #expect(report["accepted"] as? Bool == true)
        #expect(report["production"] == nil)
        #expect(!audition.isRunning)
        #expect(harness.returned.isEmpty, "居ない本番へ戻ろうとした")
        // 守る相手が居ないので、出た時点のソースで本番を起こし直す (作り直す道を閉じない)。同じ拍の巡回が起こした
        let restarted = try #require(harness.session.child)
        #expect(restarted !== production && restarted.isRunning, "出た後に本番が居ないまま、作り直されない")
        #expect(harness.session.lastStamp == "s2")
        #expect(try buildRecord(harness)["audition"] == nil, "出た後の記録が試聴の版のままである")
    }

    /// 区画 `build` の記録 (JSON)。
    func buildRecord(_ harness: Harness) throws -> [String: Any] {
        let data = try Data(contentsOf: BuildReport.statusURL(under: harness.session.facetBase))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 試聴中に本番が自分で消えた回 (完了条件 10)

    @Test("試聴中に本番が自分で消えたら、作品の窓は最後の絵のまま、試聴は続き、試聴中の言葉で名乗る")
    func productionDepartingDuringAuditionKeepsTheAudition() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())

        harness.tell(production, "bye")
        harness.previewLines.removeAll()
        await harness.beat()

        #expect(audition.isRunning && harness.session.isAuditioning && harness.session.auditionChild === audition)
        let line = try #require(harness.previewLines.last, "本番が消えたことを名乗っていない")
        #expect(line.contains("work's window"), "\(line)")
        #expect(line.contains("audition goes on"), "\(line)")
        #expect(!line.contains("Save and it gets rebuilt"), "保存しても本番は起きないのに、起こし直すと言った")
        #expect(harness.relinquished.contains { $0.contains(production.processIdentifier) }, "窓の頼みを下ろしていない")

        // 以後の保存も試聴の子を起こす
        let next = try #require(await harness.save())
        #expect(harness.session.auditionChild === next)
        let report = try await harness.ask(json: #"{"id":"look","action":"audition"}"#)
        #expect(report["production"] == nil && pidOf(report["audition"]) == next.processIdentifier)
    }

    // MARK: - 入力の宛先 (完了条件 7)

    @Test("試聴中、プレビューで触った出来事は試聴の子へ、作品の窓で触った出来事は本番の子へ届く")
    func inputGoesToTheGenerationEachWindowShows() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())

        // プレビューは試聴の子を映している
        harness.session.send("touch\n", shownBy: audition.processIdentifier)
        harness.wait(audition)
        #expect(!audition.isRunning, "プレビューで触った出来事が試聴の子へ届かない")
        #expect(production.isRunning, "プレビューで触った出来事が本番へ届いた")

        // 作品の窓 (引数なし) は本番
        harness.session.send("touch\n")
        harness.wait(production)
        #expect(!production.isRunning, "作品の窓で触った出来事が本番へ届かない")
    }

    @Test("試聴の子を起こすまでプレビューは本番を映しているので、その出来事は本番へ届く。映す世代が消えていれば、どこへも届かない")
    func inputFollowsWhatThePreviewShows() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")

        // まだ試聴の子は居ない: プレビューが映す本番へ
        harness.session.send("touch\n", shownBy: production.processIdentifier)
        harness.wait(production)
        #expect(!production.isRunning)

        // 映している世代が居ない (落ちた試聴の子の止まった絵) 場合は、どこへも送らない
        let harness2 = try Harness()
        let live = try #require(await harness2.save())
        _ = try await harness2.ask("audition")
        let audition = try #require(await harness2.save())
        harness2.tell(audition, "bye")
        await harness2.beat()
        harness2.session.send("touch\n", shownBy: audition.processIdentifier)
        try await Task.sleep(for: .milliseconds(50))
        #expect(live.isRunning, "止まった試聴の絵への出来事が、本番へ届いた")
    }

    @Test("試聴に入っていなければ、プレビューの宛先の引数は読まず、これまでどおり映っている世代へ送る")
    func inputIgnoresTheShownPIDOutsideAudition() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        _ = await harness.save()
        let production = try #require(await harness.save())
        // 引数が別の世代を指していても、試聴に入っていなければ読まない: 映っている前の世代 (outgoing) へ
        let previous = try #require(harness.session.outgoing)
        harness.session.send("touch\n", shownBy: production.processIdentifier)
        harness.wait(previous)
        #expect(!previous.isRunning && production.isRunning)
    }

    // MARK: - 台に採らせる目録の選び方 (完了条件 8・9 の見張りの側)

    @Test("作品の窓は試聴の子の番号の目録を採らず、プレビューは試聴の子を起こした後はその目録だけを採る")
    func theGatesFollowTheRolesByPid() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let session = harness.session
        // 入る前は、どちらも何も弾かない
        for pid in [production.processIdentifier, 12345] {
            #expect(session.windowAccepts(pid: pid) && session.previewAccepts(pid: pid))
        }
        _ = try await harness.ask("audition")
        // 入っても、試聴の子を起こすまでは何も弾かない (プレビューはまだ本番を映す)
        #expect(session.previewAccepts(pid: production.processIdentifier))

        let audition = try #require(await harness.save())
        let a = audition.processIdentifier
        let p = production.processIdentifier
        #expect(!session.windowAccepts(pid: a), "作品の窓が試聴の子の目録を採る")
        #expect(session.windowAccepts(pid: p))
        #expect(session.previewAccepts(pid: a))
        #expect(!session.previewAccepts(pid: p), "試聴中にプレビューが本番の目録を採る")
        // 番号を名乗らない目録は、試聴の間はどちらの窓も採らない (試聴に入れるのは番号を名乗る本番だけで、
        // 名乗らない目録は試聴の子のもの)
        #expect(!session.windowAccepts(pid: nil) && !session.previewAccepts(pid: nil))

        // 試聴の子が入れ替わっても、新しい子だけをプレビューが追い、前の試聴の子は採らない
        let second = try #require(await harness.save())
        #expect(session.previewAccepts(pid: second.processIdentifier))
        #expect(!session.previewAccepts(pid: a) && !session.windowAccepts(pid: a))
        #expect(!session.windowAccepts(pid: second.processIdentifier))
    }

    // MARK: - 終わるとき・前の見張りの残り

    @Test("見張りを終えるとき、試聴の子も止める")
    func endingStopsTheAuditionChildToo() async throws {
        let harness = try Harness()
        _ = await harness.save()
        _ = try await harness.ask("audition")
        _ = await harness.save()
        #expect(harness.alive().count == 2)
        await harness.session.end()
        #expect(harness.alive().isEmpty, "終えた後に子が残っている: \(harness.alive().count)")
        #expect(harness.session.auditionChild == nil)
    }

    @Test("前の見張りが残した要求と応答は引き継がず、区画は終わるときに畳まれる")
    func staleRequestsFromAPreviousWatcherAreDropped() async throws {
        let directory = try TestScratch.directory("mokume-watch-audition-stale")
        let facet = WorkDirectory.facet(WorkDirectory.watchFacetName, under: directory)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        try Data(#"{"id":"old","action":"audition"}"#.utf8).write(to: WorkDirectory.requestURL(under: facet))
        try Data(#"{"schemaVersion":1,"id":"older"}"#.utf8).write(to: WorkDirectory.reportURL(under: facet))

        let session = WatchSession(directory: directory, context: testContext())
        session.overlapsGenerations = true
        session.serveRequests()
        #expect(!FileManager.default.fileExists(atPath: WorkDirectory.requestURL(under: facet).path))
        #expect(!FileManager.default.fileExists(atPath: WorkDirectory.reportURL(under: facet).path))
        #expect(await session.answerRequests() == nil, "前の見張りの要求に答えた")
        #expect(!session.isAuditioning)

        session.closeRequests()
        #expect(!FileManager.default.fileExists(atPath: facet.path))
    }
}
