// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// `mokume watch` の試聴 (#3565) の、反証で見つかった穴を塞いだ約束。台本と見張りは ``WatchAuditionTests`` と同じ。
///
/// **GPU もウィンドウも使わない。** 台の側の約束は `WatchAuditionStageTests` と `SharedFrameStageTests` が見る。
@Suite("試聴の反証で見つかった穴は、塞がっている", .signalStateKept)
@MainActor
struct WatchAuditionRefutationTests {
    typealias Harness = WatchAuditionTests.Harness

    /// 区画 `build` の記録 (JSON)。
    private func buildRecord(_ harness: Harness) throws -> [String: Any] {
        let data = try Data(contentsOf: BuildReport.statusURL(under: harness.session.facetBase))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 本番が乗り換えを待つ間は、試聴の子を起こさない

    @Test("本番が乗り換えを待つ間の試聴の保存は、前の本番を畳まず試聴の子を保留し、乗り換えが決着してから起こす")
    func auditionIsHeldWhileProductionAwaitsPromotion() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        let previous = try #require(await harness.save())
        let production = try #require(await harness.save())
        #expect(harness.session.outgoing === previous && harness.session.waitingGeneration === production)
        _ = try await harness.ask("audition")

        #expect(await harness.save() == nil, "乗り換えを待つ間に、試聴の子を起こした")
        #expect(previous.isRunning && production.isRunning, "前の本番を畳んだ")
        #expect(harness.alive().count == 2 && harness.session.auditionChild == nil)
        let held = try buildRecord(harness)
        #expect(held["audition"] as? Bool == true && held["launched"] as? Bool == false)
        #expect(
            (held["notStartedReason"] as? String)?.hasPrefix(BuildReport.auditionDeferredNotice) == true,
            "\(held)")

        // 乗り換えが決着する (本番が映った) と、前の本番が畳まれ、保留していた試聴の子が起きる
        await harness.session.generationPromoted(pid: production.processIdentifier)
        #expect(!previous.isRunning)
        await harness.beat()
        let audition = try #require(harness.session.auditionChild, "決着したのに、保留した試聴の子を起こさない")
        #expect(harness.alive().count == 2 && audition.isRunning && production.isRunning)
        #expect(try buildRecord(harness)["launched"] as? Bool == true)
        #expect(harness.session.lastStamp == "s3")
        // 起こした後は、もう保留は無い
        let again = harness.gens.count
        await harness.beat()
        #expect(harness.gens.count == again)
    }

    @Test("乗り換えを待つ新しい本番が 1 枚目の前に落ちたら、前の本番へ戻り、保留していた試聴の子を起こす。作品のウィンドウは凍らない")
    func theNewProductionFailingBeforeItsFirstFrameFallsBackToThePreviousOne() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        let previous = try #require(await harness.save())
        harness.session.generationShown(pid: previous.processIdentifier)
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        #expect(await harness.save() == nil)

        harness.tell(production, "fail")
        harness.previewLines.removeAll()
        await harness.beat()

        #expect(harness.session.child === previous && previous.isRunning, "前の本番へ戻れず、作品のウィンドウが凍る")
        #expect(harness.session.waitingGeneration == nil)
        let audition = try #require(harness.session.auditionChild, "戻った後に、保留していた試聴の子を起こさない")
        #expect(audition.isRunning && harness.alive().count == 2)
        #expect(harness.session.outgoing == nil)
    }

    @Test("試聴の保存が保留されている間に出たら、保留は捨てられ、試聴の子は起こされない")
    func leavingDropsTheHeldAudition() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        _ = try await harness.save()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        #expect(await harness.save() == nil)
        _ = try await harness.ask("leave")
        await harness.session.generationPromoted(pid: production.processIdentifier)
        let launched = harness.gens.count
        await harness.beat()
        await harness.beat()
        #expect(harness.session.auditionChild == nil && !harness.session.isAuditioning)
        #expect(harness.gens.count == launched, "出た後に、保留していた試聴の子を起こした")
    }

    // MARK: - 出る要求の戻り先

    @Test("乗り換えを待つ間に出る要求は、作品のウィンドウが最終的に映す新しい側へ戻す。戻れなければ前の世代へ")
    func leavingWhileProductionAwaitsPromotionReturnsToTheNewerSide() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        let previous = try #require(await harness.save())
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let report = try await harness.ask("leave")
        #expect(report["accepted"] as? Bool == true)
        #expect(
            harness.returned == [production.processIdentifier],
            "前の世代 (畳まれる側) へ戻した: \(harness.returned)")
        #expect(harness.held == [[previous.processIdentifier, production.processIdentifier], []])

        // 新しい側へ戻れないとき (目録が押し出された・面を引けない) は、まだ映っている前の世代へ
        let other = try Harness()
        other.autoPromote = false
        let oldest = try #require(await other.save())
        let newest = try #require(await other.save())
        other.canReturn = { $0 != newest.processIdentifier }
        _ = try await other.ask("audition")
        let fallback = try await other.ask("leave")
        #expect(fallback["accepted"] as? Bool == true)
        #expect(other.returned == [newest.processIdentifier, oldest.processIdentifier], "\(other.returned)")
    }

    // MARK: - 要求は 1 本ずつ

    @Test("要求は 1 本ずつ処理する: 出る応答を書き終えるまで次の要求は読まれず、応答は出た後の状態を名乗る")
    func requestsAreAnsweredOneAtATime() async throws {
        let harness = try Harness()
        _ = await harness.save()
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())

        let facet = harness.session.watchFacet
        try AtomicFile.write(
            Data(#"{"id":"L1","action":"leave"}"#.utf8), to: WorkDirectory.requestURL(under: facet))
        // 出る要求は、試聴の子を止める待ちで main actor を手放す。その間に次の拍が来て、入る要求が置かれた
        let leaving = Task { await harness.beat() }
        await Task.yield()
        try AtomicFile.write(
            Data(#"{"id":"A2","action":"audition"}"#.utf8), to: WorkDirectory.requestURL(under: facet))
        await harness.beat()
        #expect(
            !harness.session.isAuditioning,
            "出る応答を書き終える前に、次の要求 (入る) を処理した")
        await leaving.value

        let left = try harness.report()
        #expect(left["id"] as? String == "L1")
        #expect(left["auditioning"] as? Bool == false, "出る応答が、直後の要求の状態を名乗っている: \(left)")
        #expect(left["audition"] == nil, "出る応答が、新しい試聴の子を名乗っている")

        // 置かれた要求は消えず、次の拍が拾う
        await harness.beat()
        let entered = try harness.report()
        #expect(entered["id"] as? String == "A2" && entered["accepted"] as? Bool == true)
        #expect(harness.session.isAuditioning)
    }

    @Test("要求に答えている最中に区画を閉じたら、応答は書かず、区画は復活しない")
    func aClosedFacetIsNotRevivedByAReplyInFlight() async throws {
        let harness = try Harness()
        _ = await harness.save()
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())
        let facet = harness.session.watchFacet
        try AtomicFile.write(
            Data(#"{"id":"L1","action":"leave"}"#.utf8), to: WorkDirectory.requestURL(under: facet))
        let answering = Task { await harness.session.answerRequests() }
        await Task.yield()
        // 試聴の子を止める待ちの間に、見張りが終わる
        harness.session.closeRequests()
        _ = await answering.value
        #expect(
            !FileManager.default.fileExists(atPath: facet.path),
            "閉じた後に応答を書いて、区画 watch が復活した")
    }

    @Test("区画 watch を作れなかったら、理由を返し、要求には答えない。口の側がそれを名乗る")
    func aFacetThatCannotBeCreatedIsNamed() async throws {
        let directory = try TestScratch.directory("mokume-watch-audition-nofacet")
        let session = WatchSession(directory: directory, context: testContext())
        // 区画の親 (`.mokume`) の場所をふつうのファイルで塞ぐ
        let blocker = session.watchFacet.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: blocker)
        try Data("x".utf8).write(to: blocker)
        let reason = try #require(session.serveRequests(), "作れなかったのに理由を返さない")
        #expect(!reason.isEmpty)
        #expect(await session.answerRequests() == nil)
        #expect(WatchCommand.requestFacetFailedLine(reason: reason).contains(reason))

        // 作れるときは `nil`
        let fine = WatchSession(
            directory: try TestScratch.directory("mokume-watch-audition-facet"), context: testContext())
        #expect(fine.serveRequests() == nil)
    }

    // MARK: - 番号を名乗らない子

    @Test("本番の子が番号を名乗らないなら、入る要求は断る。映っていないウィンドウでも断る")
    func auditionIsRefusedWhenTheWindowShowsNoIdentifiedGeneration() async throws {
        let harness = try Harness()
        _ = await harness.save()
        harness.windowShows = { nil }
        let report = try await harness.ask("audition")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "unidentifiedGeneration")
        #expect(report["auditioning"] as? Bool == false)
        #expect(!harness.session.isAuditioning && harness.held.isEmpty, "断ったのに、何かが動いた")
        // 番号を名乗る本番になれば入れる
        harness.windowShows = { harness.session.child?.processIdentifier }
        let entered = try await harness.ask("audition")
        #expect(entered["accepted"] as? Bool == true)
    }

    @Test("試聴の子が番号を名乗らなかったら、どちらのウィンドウも採らず、巡回が試聴の子を止めて名乗る。本番は走り続ける")
    func anUnidentifiedAuditionIsStoppedAndNamed() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let session = harness.session
        // 試聴に入っていなければ、番号を名乗らない目録は、これまでどおりどちらのウィンドウも採る
        #expect(session.windowAccepts(pid: nil) && session.previewAccepts(pid: nil))
        #expect(!session.auditionIsUnidentified)

        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        #expect(!session.windowAccepts(pid: nil), "試聴の間、作品のウィンドウが番号を名乗らない目録を採る")
        #expect(!session.previewAccepts(pid: nil), "プレビューが番号を名乗らない目録を採る")
        #expect(session.auditionIsUnidentified)

        harness.previewLines.removeAll()
        await harness.beat()
        #expect(!audition.isRunning, "番号を名乗らない試聴の子を止めていない")
        #expect(production.isRunning && session.isAuditioning)
        #expect(!session.auditionIsUnidentified)
        let line = try #require(harness.previewLines.last)
        #expect(line.contains("does not name itself"), "\(line)")

        // 保存すれば、また試聴の子が起きる
        #expect(await harness.save() != nil)
    }

    @Test("乗り換えを待つ本番が居る間は試聴の子が居ないので、番号を名乗らない受け取れない知らせは、本番のものとして受ける")
    func anAnonymousUndeliverableNoticeSettlesTheWaitingProductionDuringAudition() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        _ = try await harness.save()
        let production = try #require(await harness.save())
        let session = harness.session
        _ = try await harness.ask("audition")
        #expect(await harness.save() == nil)
        #expect(session.auditionChild == nil, "乗り換えを待つ間は、取り違える試聴の子を起こさない")
        let result = await session.retireAfterUndeliverable(waiting: production, pid: nil)
        #expect(result != nil, "試聴の間も、待っている本番の知らせを握りつぶした")
        #expect(session.waitingGeneration == nil)
    }

    // MARK: - 出た時点のソースのままの入り直しは何も起こさない (#3794)

    @Test("出た後、ソースを変えずに入り直しても、入る拍では試聴の子を起こさない。次の保存で起こす (#3794)")
    func reenteringWithTheSourceLeftAsItWasStartsNothing() async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let first = try #require(await harness.save())
        _ = try await harness.ask("leave")
        #expect(!first.isRunning && session.child === production)

        // 入り直す。ソースは出た時点 (試聴の版 s2) のまま
        let launched = harness.gens.count
        let report = try await harness.ask("audition")
        #expect(report["accepted"] as? Bool == true)
        #expect(harness.gens.count == launched, "入り直した拍で、出た時点の版の試聴の子を起こした")
        #expect(session.auditionChild == nil && session.child === production && production.isRunning)
        await harness.beat()
        #expect(harness.gens.count == launched, "入り直した後の拍で、出た時点の版の試聴の子を起こした")

        // 別の版へ直して保存すれば、試聴の子が起きる (本番は動かない)
        let next = try #require(await harness.save())
        #expect(session.auditionChild === next, "入り直した後の保存が、試聴の子を起こさない")
        #expect(session.child === production && production.isRunning)
    }

    // MARK: - 区画 build の記録

    @Test("区画 build の記録は、試聴の版に audition: true を付け、出る要求で本番の版へ戻る。ソースを戻しても作り直されない")
    func theBuildRecordFollowsTheAudition() async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())
        let before = try buildRecord(harness)
        #expect(before["stamp"] as? String == "s1" && before["audition"] == nil)

        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())
        let during = try buildRecord(harness)
        #expect(during["stamp"] as? String == "s2")
        #expect(during["launched"] as? Bool == true && during["audition"] as? Bool == true)
        #expect(session.lastStamp == "s2")

        _ = try await harness.ask("leave")
        let after = try buildRecord(harness)
        #expect(after["stamp"] as? String == "s1", "出た後も試聴の版の記録が残る")
        #expect(after["audition"] == nil, "出た後の記録が試聴の版のままである")
        #expect(session.lastStamp == "s1", "ソースの世代の控えが試聴の版のままで、同じ中身を保存しても作り直されない")

        // 出る要求は本番を動かさない: 出た時点のソース (s2) のままの間は、次の拍が試聴の版を本番へ作り直さない
        let launchedBefore = harness.gens.count
        await harness.beat()
        #expect(harness.gens.count == launchedBefore, "出た直後の拍が、試聴の版を本番へ作り直した")
        #expect(session.child === production && production.isRunning)
        #expect(session.lastStamp == "s1")

        // 試聴の版を捨てる (ソースを本番の版 s1 へ戻す) と、世代が一致するので作り直されない
        harness.stampOverride = "s1"
        await harness.beat()
        #expect(harness.gens.count == launchedBefore, "ソースを本番の版へ戻したのに作り直した")

        // 別の版へ直せば、普段どおり作り直される
        harness.stampOverride = "s3"
        await harness.beat()
        #expect(harness.gens.count == launchedBefore + 1, "出た後の保存が作り直されない")
        let rebuilt = try buildRecord(harness)
        #expect(rebuilt["stamp"] as? String == "s3" && rebuilt["audition"] == nil)
    }

    @Test("試聴の間に本番が起こせなかった回の記録は、試聴の版のものにしない")
    func aProductionFailedStartDuringAuditionIsNotRecordedAsAudition() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())
        harness.tell(production, "fail")
        await harness.beat()
        let record = try buildRecord(harness)
        #expect(record["launched"] as? Bool == false)
        #expect(record["audition"] == nil, "本番の版の記録に audition が付いた: \(record)")
    }

    // MARK: - 書き残した入力

    @Test("書き残した続きは子ごとに持つ: 片方のウィンドウの途中の行は、もう片方への入力で捨てられない")
    func unsentInputIsKeptPerChild() async throws {
        // 標準入力を読まない子: 管が埋まって、大きな行は途中で短く書ける
        let harness = try Harness(script: "exec sleep 30")
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        let session = harness.session

        let big = String(repeating: "a", count: 300_000) + "\n"
        // **合図の受け口を書き換える間は、main actor を手放さない** (``SignalState``)
        let kept = SignalState.current()
        signal(SIGPIPE, SIG_IGN)
        session.send(big, shownBy: audition.processIdentifier)
        let held = session.unsentInputBytes(for: audition)
        #expect(held > 0 && held < big.utf8.count, "短く書けて残りを持つはずが \(held) バイト")

        // 作品のウィンドウ (本番) への入力で、プレビューの途中の行が捨てられない
        session.send("touch\n")
        #expect(session.unsentInputBytes(for: audition) == held, "別のウィンドウへの入力で、途中の行が捨てられた")
        // 本番にも途中の行ができても、お互いに残る。書き残している間に来た同じ子への行は割り込ませない
        session.send(big)
        let productionHeld = session.unsentInputBytes(for: production)
        #expect(productionHeld > 0)
        session.send("extra\n", shownBy: audition.processIdentifier)
        session.flushPendingInput()
        #expect(session.unsentInputBytes(for: audition) == held, "同じ子への行が途中の行に割り込んだ")
        #expect(session.unsentInputBytes(for: production) == productionHeld)
        #expect(session.unsentInputBytes == held + productionHeld)
        kept.restore()

        // 子が畳まれたら、その子の続きは捨てられる
        _ = try await harness.ask("leave")
        session.flushPendingInput()
        #expect(session.unsentInputBytes(for: audition) == 0)
        #expect(session.unsentInputBytes(for: production) == productionHeld)
    }

    // MARK: - 出た後の本番と記録 (2 回目の反証)

    @Test("本番は居るがプレビューを戻せなかった回は、出た時点のソースを作り直して両方のウィンドウに出す (保留しない)")
    func leavingWithoutBeingAbleToReturnRebuildsTheSource() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        harness.canReturn = { _ in false }
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())
        let launched = harness.gens.count
        _ = try await harness.ask("leave")
        #expect(harness.gens.count == launched + 1, "戻れなかったのに、出た時点のソースが作り直されない")
        #expect(harness.session.child !== production)
        #expect(try buildRecord(harness)["audition"] == nil && harness.session.lastStamp == "s2")
    }

    // MARK: - 保存の役は、保存を読んだ時点で決まる (#3796)

    /// 読みや作り直しが進行中の間に、試聴を出入りする時刻。
    enum Moment: String, CaseIterable, CustomTestStringConvertible {
        /// 世代の読みの最中 (保存を読み始めた後、作り直しに取りかかる前)。
        case whileReading
        /// 作り直しの最中。
        case whileBuilding
        /// 作り直しが済んで、子を起こした後。
        case afterBuild

        var testDescription: String {
            switch self {
            case .whileReading: "読みの最中"
            case .whileBuilding: "作り直しの最中"
            case .afterBuild: "作り直しの後"
            }
        }
    }

    /// 保存を置き、見張りがその保存を読む拍を `moment` の時点で止めて `request` を出し、止めた拍を最後まで進める。
    /// `afterBuild` は止めずに保存の拍を済ませてから `request` を出す。
    private func place(
        _ harness: Harness, at moment: Moment, then request: String
    ) async throws -> [String: Any] {
        switch moment {
        case .whileReading:
            let reading = try await harness.holdRead()
            let reply = try await harness.ask(request)
            harness.releaseStamp()
            await reading.value
            return reply
        case .whileBuilding:
            let building = try await harness.holdBuild()
            #expect(harness.session.isRebuilding)
            let reply = try await harness.ask(request)
            harness.releaseRebuild()
            await building.value
            return reply
        case .afterBuild:
            _ = await harness.save()
            return try await harness.ask(request)
        }
    }

    @Test(
        "試聴の中で読んだ保存の版は、読みの最中・作り直しの最中・作り直しの後のどこで出ても本番にならない (#3796)",
        arguments: Moment.allCases)
    func aSaveReadDuringTheAuditionNeverBecomesProduction(_ moment: Moment) async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())  // s1
        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())  // s2 (試聴の子)
        #expect(session.auditionChild === audition)
        let launched = harness.gens.count

        // s3 を試聴の中で読み、`moment` の時点で出る
        let reply = try await place(harness, at: moment, then: "leave")
        #expect(reply["accepted"] as? Bool == true)

        // 本番は動かない。試聴の中で読んだ版 (s3) は、試聴の版として捨てる
        #expect(!session.isAuditioning && session.auditionChild == nil)
        #expect(session.child === production && production.isRunning, "試聴の中で読んだ版が本番に入れ替わった")
        #expect(harness.alive() == [production], "生きている子が本番だけでない: \(harness.alive().count) 個")
        // 作り直しの後に出た回だけ、s3 の試聴の子を起こしている (出る要求が止めた)
        #expect(harness.gens.count == launched + (moment == .afterBuild ? 1 : 0), "本番の子を起こした")
        let record = try buildRecord(harness)
        #expect(record["stamp"] as? String == "s1" && record["audition"] == nil, "区画 build の記録が本番の版でない: \(record)")
        #expect(session.lastStamp == "s1")

        // 次の拍も、試聴の中で読んだ版を本番へ作り直さない (ソースは s3 のまま)
        let afterLeave = harness.gens.count
        await harness.beat()
        #expect(harness.gens.count == afterLeave, "出た後の拍が、試聴の中で読んだ版を本番へ作り直した")
        #expect(session.child === production)

        // 中身を変えて保存すれば、本番の版として作り直す
        let next = try #require(await harness.save(), "出た後の保存が作り直されない")  // s4
        #expect(session.child === next && session.auditionChild == nil)
        #expect(try buildRecord(harness)["stamp"] as? String == "s4")
    }

    @Test(
        "本番のまま読んだ保存の版は、読みの最中・作り直しの最中に試聴へ入っても本番の版になり、試聴の子にならない (#3796)",
        arguments: [Moment.whileReading, .whileBuilding])
    func aSaveReadBeforeEnteringBecomesProduction(_ moment: Moment) async throws {
        let harness = try Harness()
        let session = harness.session
        let first = try #require(await harness.save())  // s1
        let launched = harness.gens.count

        // s2 を本番のまま読み、`moment` の時点で入る
        let reply = try await place(harness, at: moment, then: "audition")
        #expect(reply["accepted"] as? Bool == true)
        #expect(session.isAuditioning)

        #expect(harness.gens.count == launched + 1, "本番のまま読んだ版の子が起きない")
        let next = try #require(harness.gens.last)
        #expect(session.child === next, "本番のまま読んだ版が、本番の子にならない")
        #expect(session.auditionChild == nil && !session.isAuditionGeneration(pid: next.processIdentifier))
        let record = try buildRecord(harness)
        #expect(record["stamp"] as? String == "s2" && record["audition"] == nil, "区画 build の記録が本番の版でない: \(record)")
        // 出るときの戻り先 (プレビューが覚える本番の世代) に、新しい本番の子が入る
        #expect(harness.held.last?.contains(next.processIdentifier) == true, "覚えた本番の世代: \(harness.held)")

        // 乗り換えが決着した後の保存は、試聴の子を起こし、本番は動かない
        await session.generationPromoted(pid: next.processIdentifier)
        #expect(!first.isRunning)
        let audition = try #require(await harness.save())  // s3
        #expect(session.auditionChild === audition && session.child === next && next.isRunning)

        // 出ると、プレビューは新しい本番へ戻る
        _ = try await harness.ask("leave")
        #expect(harness.returned.last == next.processIdentifier)
        #expect(session.child === next && next.isRunning && !audition.isRunning)
    }

    // MARK: - 作り直しの最中に読んだ保存の役 (#3796 の反証)

    /// 保存を置いて、その作り直しを門で止める。止めた拍の `Task` を返す (期限は ``WatchAuditionTests/Harness/holdBuild()``)。
    private func holdBuild(_ harness: Harness) async throws -> Task<Void, Never> {
        try await harness.holdBuild()
    }

    /// 止めていた作り直しを進め、その拍を済ませる。
    private func release(_ harness: Harness, _ building: Task<Void, Never>) async {
        harness.releaseRebuild()
        await building.value
    }

    /// 試聴の中で、作り直しの最中に読んだ保存を、いつ出るか。
    enum LeaveAfterSecondRead: String, CaseIterable, CustomTestStringConvertible {
        /// 前の版 (s3) の作り直しの最中。
        case whileFirstBuilds
        /// 前の版の作り直しが済んで、後の版 (s4) に取りかかる前。
        case beforeSecondStarts
        /// 後の版の試聴の子が起きた後。
        case afterSecondStarts

        var testDescription: String {
            switch self {
            case .whileFirstBuilds: "前の版の作り直しの最中"
            case .beforeSecondStarts: "後の版に取りかかる前"
            case .afterSecondStarts: "後の版を起こした後"
            }
        }
    }

    @Test(
        "試聴の中で、作り直しの最中に読んだ保存も試聴の版で、いつ出ても本番にならない (#3796 の反証 1)",
        arguments: LeaveAfterSecondRead.allCases)
    func aSaveReadWhileAnotherBuildsKeepsItsAuditionRole(_ moment: LeaveAfterSecondRead) async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())  // s1
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())  // s2 (試聴の子)
        let building = try await holdBuild(harness)  // s3 (試聴の版) を作り直している
        harness.placeSave()  // s4
        await harness.beat()  // s4 を試聴の中で読む (作り直しの最中なので取りかからない)
        switch moment {
        case .whileFirstBuilds:
            _ = try await harness.ask("leave")
            await release(harness, building)
        case .beforeSecondStarts:
            await release(harness, building)
            _ = try await harness.ask("leave")
        case .afterSecondStarts:
            await release(harness, building)
            await harness.beat()
            #expect(session.auditionChild != nil, "後の版の試聴の子が起きない")
            _ = try await harness.ask("leave")
        }
        let launched = harness.gens.count
        await harness.beat()
        await harness.beat()
        #expect(harness.gens.count == launched, "出た後の拍が、試聴の中で読んだ版を本番へ作り直した")
        #expect(session.child === production && production.isRunning, "試聴の中で読んだ版が本番に入れ替わった")
        #expect(harness.alive() == [production])
        #expect(session.lastStamp == "s1")
        let record = try buildRecord(harness)
        #expect(record["stamp"] as? String == "s1" && record["audition"] == nil, "区画 build の記録が本番の版でない: \(record)")
        // 中身を変えれば、本番の版として作り直す
        let next = try #require(await harness.save())  // s5
        #expect(session.child === next)
    }

    @Test("作り直しを捨てたら、端末とプレビューに捨てたことを名乗り、回る印を止める (#3796 の反証 3)")
    func aDiscardedBuildSaysSoAndStopsSpinning() async throws {
        let harness = try Harness()
        _ = try #require(await harness.save())
        _ = try await harness.ask("audition")
        let building = try await holdBuild(harness)  // s2 (試聴の版)
        _ = try await harness.ask("leave")
        let before = harness.previewLines.count
        await release(harness, building)
        let shown = Array(harness.previewLines[before...])
        #expect(
            shown == [WatchCommand.auditionDiscardedLine(productionRunning: true)],
            "捨てた作り直しの後にプレビューへ出た行: \(shown)")
        #expect(harness.previewSpinning.last == false, "捨てた後もプレビューが回る印のまま")
        // 捨てたことは 1 度だけ名乗る
        await harness.beat()
        #expect(harness.previewLines.count == before + 1)
    }

    @Test("出た後に止めた試聴の作り直しは、戻した本番の記録を上書きしない (#3796 の反証 4)")
    func stoppingADiscardedBuildKeepsTheProductionRecord() async throws {
        let harness = try Harness()
        _ = try #require(await harness.save())  // s1
        _ = try await harness.ask("audition")
        let building = try await holdBuild(harness)  // s2 (試聴の版)
        _ = try await harness.ask("leave")
        harness.session.noteStopRequested()
        _ = await harness.session.stopRebuilding()
        let record = try buildRecord(harness)
        #expect(record["stamp"] as? String == "s1" && record["audition"] == nil, "止めた試聴の版の記録で上書きした: \(record)")
        await release(harness, building)
        #expect(try buildRecord(harness)["audition"] == nil)
    }

    @Test("本番のまま読んだ版の作り直しの最中に入って出ると、その版が本番になる。後で本番の前の版へ戻すと作り直す (#3796 の反証 5)")
    func leavingDuringAProductionBuildLetsThatVersionBecomeProduction() async throws {
        let harness = try Harness()
        let session = harness.session
        _ = try #require(await harness.save())  // s1
        let building = try await holdBuild(harness)  // s2 (本番の版)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        #expect(session.lastStamp == "s2", "進行中の本番の版の世代の控えを、前の本番の版へ戻した")
        await release(harness, building)
        let started = try #require(harness.gens.last)
        #expect(session.child === started && started.isRunning, "進行中の本番の版が本番にならない")
        #expect(try buildRecord(harness)["stamp"] as? String == "s2" && buildRecord(harness)["audition"] == nil)
        // 進行中だった版が本番なので、ソースを前の本番の版へ戻したら作り直す
        let launched = harness.gens.count
        harness.stampOverride = "s1"
        await harness.beat()
        #expect(harness.gens.count == launched + 1, "本番の版と違うソースへ戻したのに、作り直されない")
    }

    /// 本番のまま、作り直しの最中に読んだ保存に対して、いつ入るか。
    enum EnterAfterSecondRead: String, CaseIterable, CustomTestStringConvertible {
        case whileFirstBuilds, beforeSecondStarts
        var testDescription: String {
            self == .whileFirstBuilds ? "前の版の作り直しの最中" : "後の版に取りかかる前"
        }
    }

    @Test(
        "本番のまま、作り直しの最中に読んだ保存は、その後いつ入っても本番の版になる (#3796 の反証 2)",
        arguments: EnterAfterSecondRead.allCases)
    func aSaveReadWhileAProductionBuildRunsStaysProduction(_ moment: EnterAfterSecondRead) async throws {
        let harness = try Harness()
        let session = harness.session
        _ = try #require(await harness.save())  // s1
        let building = try await holdBuild(harness)  // s2 (本番の版)
        harness.placeSave()  // s3
        await harness.beat()  // s3 を本番のまま読む
        switch moment {
        case .whileFirstBuilds:
            #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
            await release(harness, building)
            await harness.beat()
        case .beforeSecondStarts:
            await release(harness, building)
            // 入る要求の拍で s3 に取りかかる
            #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        }
        #expect(session.isAuditioning)
        let last = try #require(harness.gens.last)
        #expect(session.child === last && session.auditionChild == nil, "本番のまま読んだ版が本番の子にならない")
        #expect(!session.isAuditionGeneration(pid: last.processIdentifier))
        #expect(try buildRecord(harness)["stamp"] as? String == "s3" && buildRecord(harness)["audition"] == nil)
    }

    @Test("作り直しの最中に中身がさらに変わったら、その保存を拾った読みの役で作り直す (#3796 の反証 1)")
    func aNewerSaveTakesTheRoleOfTheReadThatPickedItUp() async throws {
        let harness = try Harness()
        let session = harness.session
        let first = try #require(await harness.save())  // s1
        let building = try await holdBuild(harness)  // s2 (本番の版)
        harness.placeSave()  // s3 を本番のまま読む
        await harness.beat()
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.placeSave()  // s4 を試聴の中で読む
        await harness.beat()
        await release(harness, building)  // s2 が本番になる
        let production = try #require(harness.gens.last)
        #expect(session.child === production)
        await session.generationPromoted(pid: production.processIdentifier)
        #expect(!first.isRunning)
        await harness.beat()  // s4 に取りかかる
        let audition = try #require(harness.gens.last)
        #expect(session.auditionChild === audition, "試聴の中で読んだ s4 が、試聴の子にならない")
        #expect(session.child === production && production.isRunning)
        #expect(try buildRecord(harness)["stamp"] as? String == "s4" && buildRecord(harness)["audition"] as? Bool == true)
    }

    @Test("作り直しの最中に読んだ版が、作り直している版へ戻ったら控えを捨てる。後でまた変えた中身は、その時の読みが役を決める (#3796 の反証 1)")
    func revertingToTheVersionBeingBuiltDropsTheHeldRead() async throws {
        let harness = try Harness()
        let session = harness.session
        _ = try #require(await harness.save())  // s1
        let building = try await holdBuild(harness)  // s2 (本番の版)
        harness.stampOverride = "s3"  // s3 を本番のまま読む
        await harness.beat()
        harness.stampOverride = "s2"  // 作り直している版へ戻す
        await harness.beat()
        await release(harness, building)
        let production = try #require(harness.gens.last)
        #expect(session.child === production)
        await session.generationPromoted(pid: production.processIdentifier)
        let launched = harness.gens.count
        await harness.beat()
        #expect(harness.gens.count == launched, "作り直した版へ戻したのに、もう 1 度作り直した")
        // 入った後に s3 へ変えた中身は、入った後の読みで試聴の版になる (本番のまま読んだ前の読みの役を引き継がない)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.stampOverride = "s3"
        await harness.beat()
        #expect(harness.gens.count == launched + 1)
        #expect(session.auditionChild === harness.gens.last, "入った後に読んだ版が試聴の子にならない")
        #expect(session.child === production && production.isRunning)
    }

    /// 前の試聴の作り直しが、いつの出入りの後に済むか。
    enum ReentryMoment: String, CaseIterable, CustomTestStringConvertible {
        case whileReading, whileBuilding
        var testDescription: String { self == .whileReading ? "読みの最中" : "作り直しの最中" }
    }

    @Test(
        "前の試聴で読んだ版は、出て入り直した後に読み・作り直しが済んでも、新しい試聴の版にならない (#3796 の反証 7)",
        arguments: ReentryMoment.allCases)
    func aVersionFromAnEndedAuditionNeverJoinsTheNextOne(_ moment: ReentryMoment) async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())  // s1
        _ = try await harness.ask("audition")
        let launched = harness.gens.count
        switch moment {
        case .whileReading:
            let reading = try await harness.holdRead()  // s2
            _ = try await harness.ask("leave")
            _ = try await harness.ask("audition")
            harness.releaseStamp()
            await reading.value
        case .whileBuilding:
            let building = try await holdBuild(harness)  // s2
            _ = try await harness.ask("leave")
            _ = try await harness.ask("audition")
            await release(harness, building)
        }
        #expect(session.isAuditioning)
        await harness.beat()
        #expect(harness.gens.count == launched, "前の試聴で読んだ版の子を起こした")
        #expect(session.auditionChild == nil && session.child === production)
        // 新しい試聴の中で中身を変えれば、試聴の子が起きる
        let next = try #require(await harness.save())  // s3
        #expect(session.auditionChild === next && session.child === production)
    }

    @Test("「試聴の版を起こした」の行は、試聴の版の記録だけに出る。試聴の間に起きた本番の版には出ない (#3796 の反証 8)")
    func theAuditionStartedLineFollowsTheRecord() {
        let timings = BuildReport.Timings(detectMs: nil, buildMs: 0, relaunchMs: 0)
        let production = BuildReport.launched(output: "", stamp: "s2", configuration: "debug", timings: timings)
        var audition = production
        audition.audition = true
        #expect(WatchCommand.auditionLines(for: production).isEmpty)
        #expect(WatchCommand.auditionLines(for: audition) == [WatchCommand.auditionStartedLine])
        var failed = BuildReport.failed(status: 1, output: "", stamp: "s2", configuration: "debug", timings: timings)
        failed.audition = true
        #expect(WatchCommand.auditionLines(for: failed).isEmpty)
    }

    @Test("出た後に入り直し、保存せずにまた出ても、試聴の中で読んだ版を本番へ作り直さない (#3796)")
    func leavingAgainWithoutSavingKeepsProduction() async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())  // s1
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())  // s2 (試聴の版)
        _ = try await harness.ask("leave")
        _ = try await harness.ask("audition")
        let launched = harness.gens.count
        _ = try await harness.ask("leave")
        await harness.beat()
        #expect(harness.gens.count == launched, "2 度目に出た後の拍が、試聴の中で読んだ版を本番へ作り直した")
        #expect(session.child === production && production.isRunning)
        #expect(session.lastStamp == "s1")
    }

    @Test("試聴の間の本番の昇格は、試聴の記録を書き換えず、本番の版の記録の firstFrameMs を落とさない。出ると戻る")
    func aPromotionDuringAuditionKeepsTheProductionRecordAndItsMeasurement() async throws {
        let harness = try Harness()
        harness.autoPromote = false
        let first = try #require(await harness.save())
        await harness.session.generationPromoted(pid: first.processIdentifier)
        let production = try #require(await harness.save())
        _ = try await harness.ask("audition")
        _ = try await harness.save()  // 試聴の保存は保留される

        // 試聴の記録 (保留の記録) が区画に在る間に、本番が映った
        await harness.session.generationPromoted(pid: production.processIdentifier)
        let during = try buildRecord(harness)
        #expect(during["audition"] as? Bool == true, "本番の昇格が試聴の記録を書き換えた")
        #expect((during["timings"] as? [String: Any])?["firstFrameMs"] == nil)

        await harness.beat()  // 保留していた試聴の子が起きる
        _ = try await harness.ask("leave")
        let after = try buildRecord(harness)
        #expect(after["audition"] == nil && after["stamp"] as? String == "s2")
        #expect(
            (after["timings"] as? [String: Any])?["firstFrameMs"] != nil,
            "試聴の記録が、本番の昇格の測定を落とした: \(after)")
    }

    @Test("試聴の子が居ない間に来た番号を名乗らない目録は断るが、試聴の子が名乗らなかったとは控えない")
    func anAnonymousManifestBeforeTheAuditionChildExistsIsNotBlamedOnIt() async throws {
        let harness = try Harness()
        _ = try #require(await harness.save())
        _ = try await harness.ask("audition")
        #expect(!harness.session.previewAccepts(pid: nil))
        #expect(!harness.session.auditionIsUnidentified, "試聴の子が居ないのに、名乗らなかったと控えた")
        _ = try #require(await harness.save())
        #expect(!harness.session.previewAccepts(pid: nil))
        #expect(harness.session.auditionIsUnidentified)
    }

    // MARK: - 2 回目の反証 (#3796)

    /// 捨てたことを名乗る行 (本番が走っている・いない)。
    private var droppedLines: [String] {
        [true, false].map { WatchCommand.auditionDiscardedLine(productionRunning: $0) }
    }

    /// 出る要求が「出た時点のソースを本番に作り直す」と決める出方。
    enum WayBack: String, CaseIterable, CustomTestStringConvertible {
        /// 本番が居ない (``WatchSession/Left/starts``)。
        case productionGone
        /// 本番は居るが、プレビューを戻せない (``WatchSession/Left/rebuilds``)。
        case previewStuck

        var testDescription: String { self == .productionGone ? "本番が居ない" : "プレビューを戻せない" }
    }

    @Test(
        "試聴の版の作り直しの最中に、出た時点のソースを本番に作り直す出方で出ると、その作り直しを本番の版として引き継ぐ。捨てたと名乗らず、同じ版を 2 度作り直さない (#3796 の 2 回目の反証 1)",
        arguments: WayBack.allCases)
    func leavingWithoutAWayBackTakesOverTheBuildingVersion(_ way: WayBack) async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())  // s1
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())  // s2 (試聴の子)
        switch way {
        case .productionGone:
            harness.tell(production, "bye")
            await harness.beat()
        case .previewStuck:
            harness.canReturn = { _ in false }
        }
        let building = try await holdBuild(harness)  // s3 (試聴の版) を作り直している
        let rebuilds = harness.rebuilds
        let launched = harness.gens.count
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        #expect(session.lastStamp == "s3", "引き継ぐ版の世代を控えていない: \(session.lastStamp ?? "-")")
        let linesBefore = harness.previewLines.count
        await release(harness, building)
        await harness.beat()
        await harness.beat()
        #expect(harness.rebuilds == rebuilds, "出た時点のソース (進行中の版と同じ) をもう 1 度作り直した")
        #expect(harness.gens.count == launched + 1, "引き継いだ版の本番の子が 1 つ起きない: \(harness.gens.count - launched)")
        let started = try #require(harness.gens.last)
        #expect(session.child === started && started.isRunning, "引き継いだ版が本番にならない")
        #expect(!session.isAuditionGeneration(pid: started.processIdentifier))
        let record = try buildRecord(harness)
        #expect(record["stamp"] as? String == "s3" && record["audition"] == nil, "区画 build の記録が引き継いだ本番の版でない: \(record)")
        let shown = harness.previewLines[linesBefore...]
        #expect(!shown.contains { droppedLines.contains($0) }, "本番の版にした版を、捨てたと名乗った: \(Array(shown))")
    }

    @Test(
        "本番の版の作り直しの最中に出た試聴で読んだ版は、作り直しの後に捨て、捨てたことを端末とプレビューに名乗る (#3796 の 2 回目の反証 2)")
    func aVersionReadInAnEndedAuditionIsDroppedWithANotice() async throws {
        let harness = try Harness()
        let session = harness.session
        _ = try #require(await harness.save())  // s1
        let building = try await holdBuild(harness)  // s2 (本番の版)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.placeSave()  // s3
        await harness.beat()  // s3 を試聴の中で読む (作り直しの最中なので取りかからない)
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        await release(harness, building)  // s2 が本番になる
        let production = try #require(harness.gens.last)
        #expect(session.child === production)
        let launched = harness.gens.count
        let linesBefore = harness.previewLines.count
        await harness.beat()  // s3 を捨てる
        #expect(harness.gens.count == launched, "試聴の中で読んだ版を起こした")
        #expect(
            Array(harness.previewLines[linesBefore...]) == [WatchCommand.auditionDiscardedLine(productionRunning: true)],
            "捨てたことを名乗らない: \(Array(harness.previewLines[linesBefore...]))")
        #expect(harness.previewSpinning.last == false)
        // 名乗るのは 1 度。次の拍は何も起こさない
        await harness.beat()
        #expect(harness.gens.count == launched && harness.previewLines.count == linesBefore + 1)
        #expect(session.lastStamp == "s2" && session.child === production)
    }

    @Test(
        "本番の版の作り直しの最中に出て、その作り直しが通らなかったら、本番が居なければ試聴の中で読んだ版を本番に起こし、居れば捨てて名乗る (#3796 の 2 回目の反証 3)",
        arguments: [false, true])
    func aFailedProductionBuildAfterLeavingDecidesTheAuditionVersion(_ productionStays: Bool) async throws {
        let harness = try Harness()
        let session = harness.session
        let first = try #require(await harness.save())  // s1
        let building = try await holdBuild(harness)  // s2 (本番の版)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        if !productionStays {
            harness.tell(first, "bye")  // 試聴の間に本番が落ちる
            await harness.beat()
        }
        harness.placeSave()  // s3
        await harness.beat()  // s3 を試聴の中で読む
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        let launched = harness.gens.count
        harness.buildFails = true
        await release(harness, building)  // s2 は通らない
        harness.buildFails = false
        let linesBefore = harness.previewLines.count
        await harness.beat()
        await harness.beat()
        let shown = Array(harness.previewLines[linesBefore...])
        if productionStays {
            #expect(harness.gens.count == launched, "本番が居るのに、試聴の中で読んだ版を起こした")
            #expect(session.child === first && first.isRunning)
            #expect(shown == [WatchCommand.auditionDiscardedLine(productionRunning: true)], "捨てたことを名乗らない: \(shown)")
        } else {
            #expect(harness.gens.count == launched + 1, "本番が居ないのに、出た時点のソース (s3) を起こさない")
            let started = try #require(harness.gens.last)
            #expect(session.child === started && started.isRunning)
            #expect(!session.isAuditionGeneration(pid: started.processIdentifier))
            let record = try buildRecord(harness)
            #expect(record["stamp"] as? String == "s3" && record["audition"] == nil, "\(record)")
            #expect(!shown.contains { droppedLines.contains($0) }, "本番に起こした版を、捨てたと名乗った: \(shown)")
        }
    }

    @Test("読みの最中に置いた保存は、走っている読みが拾えば、その読みを始めた時点の役になる (#3796 の 2 回目の反証 5)")
    func aSaveThatARunningReadPicksUpTakesTheRoleOfThatRead() async throws {
        let harness = try Harness()
        let session = harness.session
        let production = try #require(await harness.save())  // s1
        _ = try await harness.ask("audition")
        let launched = harness.gens.count
        // 試聴の中で読みを始め (ソースはまだ s1)、読みの最中に s2 を置き、出る。読みは s2 を拾って戻る
        harness.stampReadsAtEnd = true
        let reading = try await harness.holdRead(placing: false)
        harness.placeSave()  // s2
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        let linesBefore = harness.previewLines.count
        harness.releaseStamp()
        await reading.value
        harness.stampReadsAtEnd = false
        #expect(harness.gens.count == launched, "試聴の中で始めた読みが拾った保存を起こした")
        #expect(session.child === production && production.isRunning)
        #expect(
            Array(harness.previewLines[linesBefore...]) == [WatchCommand.auditionDiscardedLine(productionRunning: true)],
            "捨てたことを名乗らない: \(Array(harness.previewLines[linesBefore...]))")
        await harness.beat()
        #expect(harness.gens.count == launched, "出た後の拍が、試聴の中の読みが拾った版を本番へ作り直した")
        // 出た後に置いた保存は、出た後に始めた読みが拾うので本番の版
        let next = try #require(await harness.save())  // s3
        #expect(session.child === next && !session.isAuditionGeneration(pid: next.processIdentifier))
    }

    @Test("試聴に入る前に読んだ本番の版を試聴の中で起こした回も、最初の絵までの時間を区画 build の記録に書く (#3796 の 2 回目の反証 9)")
    func aProductionVersionStartedDuringTheAuditionRecordsItsFirstFrame() async throws {
        let harness = try Harness()
        let session = harness.session
        harness.autoPromote = false
        let first = try #require(await harness.save())  // s1
        await session.generationPromoted(pid: first.processIdentifier)
        let building = try await holdBuild(harness)  // s2 (本番の版)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        await release(harness, building)
        let production = try #require(harness.gens.last)
        #expect(session.child === production)
        await session.generationPromoted(pid: production.processIdentifier)
        let record = try buildRecord(harness)
        #expect(record["stamp"] as? String == "s2" && record["audition"] == nil, "\(record)")
        #expect(
            (record["timings"] as? [String: Any])?["firstFrameMs"] != nil,
            "本番の報告にだけ足して、区画の記録に書かない: \(record)")
    }
}
