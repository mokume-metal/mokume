// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// `mokume watch` の試聴 (#3565) の、反証で見つかった穴を塞いだ約束。台本と見張りは ``WatchAuditionTests`` と同じ。
///
/// **GPU も窓も使わない。** 台の側の約束は `WatchAuditionStageTests` と `SharedFrameStageTests` が見る。
@Suite("試聴の反証で見つかった穴は、塞がっている", .signalStateKept)
@MainActor
struct WatchAuditionRefutationTests {
    typealias Harness = WatchAuditionTests.Harness

    /// 区画 `build` の記録 (JSON)。
    private func buildRecord(_ harness: Harness) throws -> [String: Any] {
        let data = try Data(contentsOf: BuildReport.statusURL(under: harness.session.facetBase))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 生きている子は「本番 + 試聴」の 2 つまで

    @Test("乗り換えを待つ前の本番が居る間の試聴の保存は、前の本番を畳んでから試聴の子を起こし、生きている子は 2 つまで")
    func savingWhileProductionAwaitsPromotionRetiresThePreviousProductionFirst() async throws {
        let harness = try Harness()
        let previous = try #require(await harness.save())
        let production = try #require(await harness.save())
        #expect(harness.session.outgoing === previous && harness.session.waitingGeneration === production)
        _ = try await harness.ask("audition")
        #expect(harness.alive().count == 2, "入る要求だけでは何も動かない")

        let first = try #require(await harness.save())
        #expect(!previous.isRunning, "前の本番を畳まずに試聴の子を起こした")
        #expect(harness.alive().count == 2, "生きている子は「本番 + 試聴」の 2 つまで: \(harness.alive().count)")
        #expect(harness.session.outgoing == nil && harness.session.child === production)
        #expect(harness.session.waitingGeneration === production, "本番は乗り換えを待ったまま")
        #expect(
            harness.relinquished.contains([previous.processIdentifier]),
            "畳んだ前の本番を台へ伝えていない (通常の保存と同じ作法)")

        let second = try #require(await harness.save())
        #expect(!first.isRunning && second.isRunning && production.isRunning)
        #expect(harness.alive().count == 2)
    }

    // MARK: - 出る要求の戻り先

    @Test("乗り換えを待つ間に出る要求は、作品の窓が最終的に映す新しい側へ戻す。戻れなければ前の世代へ")
    func leavingWhileProductionAwaitsPromotionReturnsToTheNewerSide() async throws {
        let harness = try Harness()
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

    @Test("本番の子が番号を名乗らないなら、入る要求は断る。映っていない窓でも断る")
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

    @Test("試聴の子が番号を名乗らなかったら、どちらの窓も採らず、巡回が試聴の子を止めて名乗る。本番は走り続ける")
    func anUnidentifiedAuditionIsStoppedAndNamed() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let session = harness.session
        // 試聴に入っていなければ、番号を名乗らない目録は、これまでどおりどちらの窓も採る
        #expect(session.windowAccepts(pid: nil) && session.previewAccepts(pid: nil))
        #expect(!session.auditionIsUnidentified)

        _ = try await harness.ask("audition")
        let audition = try #require(await harness.save())
        #expect(!session.windowAccepts(pid: nil), "試聴の間、作品の窓が番号を名乗らない目録を採る")
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

    @Test("試聴の子が居る間は、番号を名乗らない受け取れない知らせ (読めない目録) で、乗り換えを待つ本番を乗り換え済みとしない")
    func anAnonymousUndeliverableNoticeDoesNotSettleProductionDuringAudition() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let session = harness.session
        #expect(session.waitingGeneration === production)
        _ = try await harness.ask("audition")
        _ = try #require(await harness.save())
        let result = await session.retireAfterUndeliverable(waiting: production, pid: nil)
        #expect(result == nil)
        #expect(session.waitingGeneration === production, "誰のものか分からない知らせで、本番の待ちが下りた")

        // 試聴に入っていなければ、これまでどおり受ける
        let plain = try Harness()
        let waiting = try #require(await plain.save())
        #expect(await plain.session.retireAfterUndeliverable(waiting: waiting, pid: nil) != nil)
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

    @Test("書き残した続きは子ごとに持つ: 片方の窓の途中の行は、もう片方への入力で捨てられない")
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

        // 作品の窓 (本番) への入力で、プレビューの途中の行が捨てられない
        session.send("touch\n")
        #expect(session.unsentInputBytes(for: audition) == held, "別の窓への入力で、途中の行が捨てられた")
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
}
