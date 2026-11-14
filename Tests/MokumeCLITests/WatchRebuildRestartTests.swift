// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// `mokume watch` を止めずに作り直す `rebuild` と、作り直さずに最初から起こし直す `restart` (#3428)。
///
/// 区画 `watch` の要求で頼む。**頼んだ作り直しは保存と同じ経路に乗り** (役は頼みを読んだ時点の試聴の状態・#3796)、
/// 起こし直しは置き場の最後に通った作り直しの版が当たる子の版のときだけ起きる (2026-11-14 の決定)。生成した列は
/// ``WatchSessionModelTests`` が見る。ここは記録・名乗り・時計の場所を、決まった順で見る。
///
/// **GPU もウィンドウも使わない** (``WatchAuditionTests/Harness`` と同じ替え玉)。
@Suite("作り直す・起こし直す要求は、保存と同じ役の規則に乗り、起こし直しは置き場の版の子だけに当たる", .signalStateKept)
@MainActor
struct WatchRebuildRestartTests {
    typealias Harness = WatchAuditionTests.Harness

    private func status(_ harness: Harness) throws -> Data {
        try Data(contentsOf: BuildReport.statusURL(under: harness.session.facetBase))
    }

    private func statusObject(_ harness: Harness) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: status(harness)) as? [String: Any])
    }

    /// 要求を置き、その拍を作り直しの門で止める (頼んだ作り直しの最中の出来事を演じる)。**待つ側が期限を持つ** — 越えたら
    /// 門を開けて拍を畳んでから投げる。
    private func holdRequestedBuild(_ harness: Harness, id: String) async throws -> Task<Void, Never> {
        harness.holdRebuild = true
        try AtomicFile.write(
            Data(#"{"id":"\#(id)","action":"rebuild"}"#.utf8),
            to: WorkDirectory.requestURL(under: harness.session.watchFacet))
        let building = Task { await harness.beat() }
        guard await harness.waitUntil({ harness.isRebuildHeld }) else {
            harness.releaseRebuild()
            await building.value
            throw Harness.GateTimeout(description: "頼んだ作り直しが期限までに進行中にならない")
        }
        return building
    }

    // MARK: - 作り直す (完了条件 1・3)

    @Test("作り直す要求は、中身が変わっていなくても 1 回だけ作り直して差し替え、記録は頼まれた作り直しと名乗る")
    func aRebuildRequestRebuildsTheSameSourcesOnce() async throws {
        let harness = try Harness()
        let first = try #require(await harness.save())
        #expect(try statusObject(harness)["requested"] == nil, "保存の回の記録に requested を書いた")
        let rebuildsBefore = harness.rebuilds

        let report = try await harness.ask("rebuild")
        #expect(report["accepted"] as? Bool == true)
        #expect(harness.rebuilds == rebuildsBefore + 1)
        let second = try #require(harness.gens.last)
        #expect(second !== first)
        #expect(harness.session.child === second)
        let record = try statusObject(harness)
        #expect(record["requested"] as? String == "rebuild")
        #expect(record["stamp"] as? String == "s1", "中身は変えていない")

        // 頼みは 1 回きり。次の拍は何もしない
        await harness.beat()
        #expect(harness.rebuilds == rebuildsBefore + 1)
        // 保存の回は欄を持たない
        await harness.save()
        #expect(try statusObject(harness)["requested"] == nil)
    }

    @Test("頼んだ作り直しは、始まりの行と要約で頼まれたことを名乗り、保存による作り直しの要約は変えない (反証 9)")
    func aRequestedRebuildSaysItWasAskedFor() async throws {
        let harness = try Harness()
        var requestedAtStart: [Bool] = []
        harness.session.willRebuild = { [unowned session = harness.session] _ in
            requestedAtStart.append(session.rebuildingRequested)
        }
        try #require(await harness.save())
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        try #require(await harness.save())
        #expect(requestedAtStart == [false, true, false])
        let asked = try #require(harness.session.lastReport.map { report -> BuildReport in
            var report = report
            report.requested = .rebuild
            return report
        })
        #expect(asked.summary.hasSuffix(" requested=rebuild"), "\(asked.summary)")
        let saved = try #require(harness.session.lastReport)
        #expect(!saved.summary.contains("requested"), "\(saved.summary)")
        #expect(WatchCommand.requestedRebuildingLine != WatchCommand.rebuildingLine)
    }

    @Test("作り直しの最中に何度頼んでも、済んだ後の作り直しは 1 回だけ")
    func rebuildRequestsDuringABuildRunOnceAfterIt() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let before = harness.rebuilds
        let building = try await harness.holdBuild()
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        for _ in 0..<3 { await harness.beat() }
        #expect(harness.rebuilds == before + 2, "門で止めた作り直しと、頼んだ 1 回")
        #expect(try statusObject(harness)["requested"] as? String == "rebuild")
    }

    @Test("頼んだ作り直しが通らなければ、走っている版はそのままで、記録は頼まれた作り直しの失敗と名乗る")
    func aFailedRebuildRequestKeepsTheRunningVersion() async throws {
        let harness = try Harness()
        let running = try #require(await harness.save())
        harness.buildFails = true
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        let record = try statusObject(harness)
        #expect(record["ok"] as? Bool == false)
        #expect(record["requested"] as? String == "rebuild")
        #expect(running.isRunning)
        #expect(harness.session.child === running)
    }

    @Test("試聴の中で頼んだ作り直しは、その最中に出ると捨てて名乗り、本番は動かない (#3796 の規則)")
    func aRebuildAskedInAnAuditionIsDroppedWhenLeavingDuringIt() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        let building = try await holdRequestedBuild(harness, id: "rb")
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        let launched = harness.gens.count
        harness.releaseRebuild()
        await building.value
        await harness.beat()
        #expect(harness.gens.count == launched, "捨てた版の子を起こした")
        #expect(harness.session.child === production && production.isRunning)
        #expect(!audition.isRunning)
        // 捨てたのは頼みだけ (試聴の中の保存 s2 は作って起こした後) なので、保存した版を捨てたとは言わない (2 回目の反証 4)
        #expect(harness.previewLines.contains(WatchCommand.auditionRebuildDiscardedLine(productionRunning: true)))
        #expect(!harness.previewLines.contains(WatchCommand.auditionDiscardedLine(productionRunning: true)))
        #expect(try statusObject(harness)["audition"] == nil, "記録は本番の版のまま")
    }

    @Test("終わった試聴で頼んだ作り直しを取りかかる前に捨てた回も、頼みを捨てたと名乗る (2 回目の反証 4)")
    func aRebuildAskedInAnEndedAuditionIsNamedAsARequestWhenDroppedBeforeItStarts() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let building = try await harness.holdBuild()  // s2 (本番)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        for _ in 0..<2 { await harness.beat() }
        #expect(harness.rebuilds == 2, "s1・s2 (本番)。試聴の頼みは作らない")
        #expect(harness.previewLines.contains(WatchCommand.auditionRebuildDiscardedLine(productionRunning: true)))
        #expect(!harness.previewLines.contains(WatchCommand.auditionDiscardedLine(productionRunning: true)))
        #expect(harness.session.child !== production, "s2 が本番になる")
    }

    @Test("本番で頼んだ作り直しは、その最中に試聴へ入っても本番の版になる (#3796 の規則)")
    func aRebuildAskedInProductionStaysProductionWhenEnteringDuringIt() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let building = try await holdRequestedBuild(harness, id: "rb")
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        let started = try #require(harness.gens.last)
        #expect(harness.session.child === started)
        #expect(!harness.session.isAuditionGeneration(pid: started.processIdentifier))
        let record = try statusObject(harness)
        #expect(record["audition"] == nil)
        #expect(record["requested"] as? String == "rebuild")
    }

    @Test("読みの最中に試聴へ入って頼んだ作り直しは、その読みが拾った本番の保存を消さず、本番・試聴の順に 2 回作り直す")
    func aRebuildAskedDuringAReadKeepsTheSaveItPicksUp() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        // 本番のまま保存 s2 を読み始め、その読みの最中に試聴へ入ってから作り直しを頼む
        let reading = try await harness.holdRead()
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        harness.releaseStamp()
        await reading.value
        // 読みを始めたのは入る前なので s2 は本番の版 (#3796)。頼みは試聴の中なので、続けて試聴の版を 1 回 (役の違う項目は
        // 互いを消さない・反証 1)
        let productionS2 = try #require(harness.session.child)
        #expect(productionS2 !== production)
        await harness.session.generationPromoted(pid: productionS2.processIdentifier)
        for _ in 0..<2 { await harness.beat() }
        let audition = try #require(harness.session.auditionChild)
        #expect(harness.session.isAuditionGeneration(pid: audition.processIdentifier))
        #expect(harness.session.child === productionS2 && productionS2.isRunning)
        #expect(harness.events == ["build", "launch", "build", "launch", "build", "launch"])
        let record = try statusObject(harness)
        #expect(record["audition"] as? Bool == true)
        #expect(record["requested"] as? String == "rebuild")
        #expect(record["stamp"] as? String == "s2")
    }

    // MARK: - 役ごと・頼みごとの控え (反証 1・2・3)

    @Test("本番の作り直しの最中に読んだ本番の保存は、その後に試聴で頼んだ作り直しに役を奪われない (反証 1)")
    func aProductionSaveIsNotTakenOverByALaterAuditionRebuild() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let building = try await harness.holdBuild()  // s2 (本番)
        harness.placeSave()
        await harness.beat()  // s3 を本番の役で読む
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        // s3 は本番の版として作られ、本番の子になる。頼みは試聴の版として、その後に作られる (本番が乗り換えを待つ間は保留)
        for _ in 0..<2 { await harness.beat() }
        #expect(harness.rebuilds == 4, "s1・s2・s3 (本番)・s3 (試聴の頼み)")
        let productionS3 = try #require(harness.session.child)
        await harness.session.generationPromoted(pid: productionS3.processIdentifier)
        await harness.beat()
        let audition = try #require(harness.session.auditionChild)
        #expect(audition !== productionS3 && audition.isRunning)
        #expect(try statusObject(harness)["requested"] as? String == "rebuild")
        let report = try await harness.ask("leave")
        #expect((report["production"] as? [String: Any])?["stamp"] as? String == "s3", "\(report)")
        #expect(productionS3.isRunning)
    }

    @Test("試聴で読んだ保存を控えたまま本番の作り直しの最中に出て、本番で頼んだ作り直しは、捨てたことを名乗ってから作る (反証 1 の逆)")
    func anAuditionSaveIsDroppedWithANoticeBeforeTheProductionRebuild() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let building = try await harness.holdBuild()  // s2 (本番)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.placeSave()
        await harness.beat()  // s3 を試聴の役で読む
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        for _ in 0..<3 { await harness.beat() }
        let dropped = try #require(harness.previewLines.firstIndex(of: WatchCommand.auditionDiscardedLine(productionRunning: true)))
        #expect(harness.rebuilds == 3, "s1・s2・頼まれた本番の作り直し")
        #expect(try statusObject(harness)["requested"] as? String == "rebuild")
        #expect(try statusObject(harness)["audition"] == nil)
        #expect(dropped < harness.previewLines.count)
    }

    @Test("本番で頼んだ作り直しを控えている間に、試聴の中の保存が中身を変えたら、頼みは捨てて名乗り、本番には出さない (反証 2・Q1 の B)")
    func aProductionRebuildIsDroppedWithANoticeWhenAnAuditionSaveChangesTheSource() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let building = try await harness.holdBuild()  // s2 (本番)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.placeSave()
        await harness.beat()  // s3 を試聴の役で読む
        #expect(harness.previewLines.last == WatchSession.rebuildDroppedLine(audition: false))
        harness.releaseRebuild()
        await building.value
        let productionS2 = try #require(harness.session.child)
        await harness.session.generationPromoted(pid: productionS2.processIdentifier)
        for _ in 0..<2 { await harness.beat() }
        #expect(harness.session.child === productionS2, "試聴の中で保存した版が本番に出た")
        #expect(harness.rebuilds == 3, "s1・s2・s3 (試聴)")
        #expect(try statusObject(harness)["audition"] as? Bool == true)
    }

    @Test("出る要求が本番の版へ寄せた試聴の頼みを、次の試聴の保存が捨てたら、作品のウィンドウの頼みとして名乗る (2 回目の反証 5)")
    func aRebuildTakenOverAsProductionIsNamedAsTheWorksWhenDropped() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let building = try await harness.holdBuild()  // s2 (試聴 1)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        // プレビューを戻せない出方は、試聴 1 の版を本番の版として作る (頼みも本番の頼みになる)
        harness.canReturn = { _ in false }
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        harness.canReturn = { _ in true }
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.placeSave()
        await harness.beat()  // s3 を試聴 2 の役で読む
        #expect(harness.previewLines.last == WatchSession.rebuildDroppedLine(audition: false), "\(harness.previewLines)")
        harness.releaseRebuild()
        await building.value
        for _ in 0..<2 { await harness.beat() }
    }

    @Test("作り直しの最中に頼みの後に読んだ中身の変わる保存は頼みを追い越し、記録は保存の回になる (2 回目の反証 2)")
    func aSaveReadAfterARebuildRequestRecordsTheSave() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let building = try await harness.holdBuild()  // s2
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        harness.placeSave()
        await harness.beat()  // s3 を頼みの後に読む
        harness.releaseRebuild()
        await building.value
        for _ in 0..<2 { await harness.beat() }
        #expect(harness.rebuilds == 3, "s1・s2・s3 を 1 回")
        let record = try statusObject(harness)
        #expect(record["stamp"] as? String == "s3")
        #expect(record["requested"] == nil, "\(record)")
    }

    @Test("作り直しの最中に保存の後で頼んだ作り直しは、まとめた 1 回の記録を頼まれた作り直しの回にする (2 回目の反証 2)")
    func aRebuildRequestReadAfterASaveRecordsTheRequest() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let building = try await harness.holdBuild()  // s2
        harness.placeSave()
        await harness.beat()  // s3 を頼みの前に読む
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        for _ in 0..<2 { await harness.beat() }
        #expect(harness.rebuilds == 3, "s1・s2・s3 を 1 回")
        let record = try statusObject(harness)
        #expect(record["stamp"] as? String == "s3")
        #expect(record["requested"] as? String == "rebuild", "\(record)")
    }

    @Test("作り直しの最中に頼んだ作り直しと起こし直しは、頼んだ順に行う (反証 3)", arguments: [true, false])
    func rebuildAndRestartRunInTheOrderAsked(rebuildFirst: Bool) async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let building = try await harness.holdBuild()  // s2
        for action in rebuildFirst ? ["rebuild", "restart"] : ["restart", "rebuild"] {
            #expect(try await harness.ask(action)["accepted"] as? Bool == true)
        }
        harness.releaseRebuild()
        await building.value
        for _ in 0..<3 { await harness.beat() }
        // s1 (build・launch)・s2 (build・launch) の後
        let after = Array(harness.events.dropFirst(4))
        #expect(after == (rebuildFirst ? ["build", "launch", "launch"] : ["launch", "build", "launch"]), "\(harness.events)")
    }

    // MARK: - 置き場の版 (反証 7)

    @Test("作り直しが通らなかった後は、置き場の版が分からないので、起こし直しを notBuilt で断る (反証 7)")
    func aRestartAfterAFailedBuildIsDeclinedWithNotBuilt() async throws {
        let harness = try Harness()
        let running = try #require(await harness.save())
        harness.buildFails = true
        await harness.save()
        harness.buildFails = false
        let report = try await harness.ask("restart")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "notBuilt")
        #expect(harness.gens.count == 1 && running.isRunning)
    }

    @Test("試聴の中で同じ中身を作り直して出た後は、本番の子を起こした成果物が置き場に無いので notBuilt で断る (2 回目の反証 1)")
    func aRestartAfterAnAuditionRebuildOfTheSameSourcesIsDeclinedWithNotBuilt() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        // 世代に入らない資材を変えて頼んだ作り直し — ソースの世代は s1 のままでも、置き場には試聴の成果物ができる
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        let audition = try #require(harness.session.auditionChild)
        #expect(audition !== production)
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        let launched = harness.gens.count
        let report = try await harness.ask("restart")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "notBuilt")
        #expect(harness.gens.count == launched, "試聴の成果物で本番を起こし直した")
        #expect(harness.session.child === production && production.isRunning)
    }

    @Test("本番の中で同じ中身を作り直した後は、その成果物の子を起こし直せる")
    func aRestartAfterAProductionRebuildOfTheSameSourcesStartsIt() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        let rebuilt = try #require(harness.session.child)
        await harness.session.generationPromoted(pid: rebuilt.processIdentifier)
        let report = try await harness.ask("restart")
        #expect(report["accepted"] as? Bool == true)
        #expect(harness.session.child !== rebuilt)
    }

    // MARK: - 起こし直した子が最初の絵の前に落ちる (反証 6)

    @Test("起こし直した子が最初の絵の前に落ちたら、記録を書き換えず、起こし直しの失敗と名乗り、時計の場所を戻す (反証 6・5)")
    func aRestartedChildFailingBeforeItsFirstFrameKeepsTheRecord() async throws {
        let harness = try Harness()
        let first = try #require(await harness.save())
        harness.session.generationShown(pid: first.processIdentifier)
        let recordBefore = try status(harness)
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        let restarted = try #require(harness.gens.last)
        #expect(restarted !== first)
        harness.tell(restarted, "fail")
        await harness.beat()
        #expect(try status(harness) == recordBefore, "起こし直した子の失敗で、作り直しの記録を書き換えた")
        let line = try #require(harness.previewLines.last)
        #expect(line.hasPrefix("Could not restart it: "), "\(line)")
        #expect(!harness.previewLines.contains { $0.hasPrefix("Rebuilt, but could not start") })
        #expect(harness.session.child === first && first.isRunning, "前の版が走り続ける")
        // 次の保存の子は、起こし直す前の時計の場所を受ける
        try #require(await harness.save())
        #expect(harness.clocks == [0, 1, 0])
    }

    // MARK: - 時計の場所 (反証 4・5)

    @Test("試聴で起こし直して出た後の本番の保存は、本番の時計の場所を受ける (反証 4 (a))")
    func aProductionSaveAfterAnAuditionRestartReadsTheProductionClock() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        try #require(await harness.save())
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        try #require(await harness.save())
        #expect(harness.clocks == [0, 0, 1, 0], "本番 s1・試聴 s2・起こし直した試聴・本番 s3")
    }

    @Test("試聴中に本番を起こし直した後の試聴の作り直しは、試聴の子の時計の場所を受ける (反証 4 (b))")
    func anAuditionBuildAfterAProductionRestartReadsTheAuditionClock() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        // 本番の作り直しの最中に本番で起こし直しを頼み、済む前に試聴へ入る (起こし直しは本番の子に当たる)
        let building = try await harness.holdBuild()
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        await harness.beat()
        let restarted = try #require(harness.session.child)
        await harness.session.generationPromoted(pid: restarted.processIdentifier)
        try #require(await harness.save())
        // 本番 s1・本番 s2・起こし直した本番・試聴 s3
        #expect(harness.clocks == [0, 0, 1, 0], "\(harness.clocks)")
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        // 出た後の本番の保存は、起こし直した本番の場所
        try #require(await harness.save())
        #expect(harness.clocks.last == 1)
    }

    @Test("起こせなかった起こし直しの後の保存は、前と同じ時計の場所を受ける (反証 5)")
    func aSaveAfterAFailedRestartKeepsTheClock() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        harness.launchFails = true
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        #expect(harness.previewLines.last?.hasPrefix("Could not restart it: ") == true)
        harness.launchFails = false
        try #require(await harness.save())
        #expect(harness.clocks == [0, 0])
    }

    // MARK: - 起こし直す (完了条件 2・3)

    @Test("起こし直す要求は、作り直さず記録も書かずに、本番の版を最初から起こし直す。時計の場所は新しくなる")
    func aRestartStartsTheRunningVersionAgain() async throws {
        let harness = try Harness()
        let first = try #require(await harness.save())
        let rebuilds = harness.rebuilds
        let recordBefore = try status(harness)

        let report = try await harness.ask("restart")
        #expect(report["accepted"] as? Bool == true)
        #expect(harness.rebuilds == rebuilds, "起こし直しで作り直した")
        let restarted = try #require(harness.gens.last)
        #expect(restarted !== first)
        #expect(harness.session.child === restarted)
        #expect(try status(harness) == recordBefore, "起こし直しで記録を書いた")
        #expect(harness.clocks == [0, 1], "起こし直した子だけが新しい時計の場所を受ける")
        #expect(harness.previewLines.last == WatchSession.restartLine(.restarted(audition: false)))
        // 新しい子が映ったら、前の子は畳まれる
        await harness.session.generationPromoted(pid: restarted.processIdentifier)
        harness.wait(first)
        #expect(!first.isRunning)
        // 応答は起こし直した子の版を名乗る (次の要求の応答で見る)
        let next = try await harness.ask("leave")
        #expect((next["production"] as? [String: Any])?["stamp"] as? String == "s1")
    }

    @Test("試聴中の起こし直しは試聴の子だけを起こし直し、本番は動かない")
    func aRestartInAnAuditionRestartsOnlyTheVersionUnderAudition() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        let report = try await harness.ask("restart")
        #expect(report["accepted"] as? Bool == true)
        let restarted = try #require(harness.gens.last)
        #expect(restarted !== audition)
        harness.wait(audition)
        #expect(!audition.isRunning)
        #expect(harness.session.auditionChild === restarted)
        #expect(harness.session.previewFollowing == restarted.processIdentifier)
        #expect(harness.session.child === production && production.isRunning)
        #expect(harness.clocks == [0, 0, 1], "試聴の子は本番の場所を共有し、起こし直した試聴の子だけが新しい場所")
        #expect(harness.previewLines.last == WatchSession.restartLine(.restarted(audition: true)))
    }

    @Test("当たる子が居ない起こし直しは noTarget で断り、何もしない (最初の作り直しの失敗・試聴に入って保存の前)")
    func aRestartWithNothingToStartIsDeclinedWithNoTarget() async throws {
        let failed = try Harness()
        failed.buildFails = true
        await failed.save()
        let report = try await failed.ask("restart")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "noTarget")
        #expect(failed.gens.isEmpty)
        #expect(failed.previewLines.last == WatchSession.restartLine(.declined(.noTarget)))

        let entered = try Harness()
        let production = try #require(await entered.save())
        #expect(try await entered.ask("audition")["accepted"] as? Bool == true)
        let declined = try await entered.ask("restart")
        #expect(declined["reason"] as? String == "noTarget")
        #expect(entered.gens.count == 1 && production.isRunning)
    }

    @Test("置き場の最後に通った作り直しの版が当たる子の版でなければ notBuilt で断る (試聴で版を作って出た後)")
    func aRestartAfterAnAuditionBuiltAnotherVersionIsDeclinedWithNotBuilt() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        try #require(await harness.save())
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        let launched = harness.gens.count
        let report = try await harness.ask("restart")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "notBuilt")
        #expect(harness.gens.count == launched)
        #expect(harness.session.child === production && production.isRunning)
        #expect(harness.clocks.allSatisfy { $0 == 0 })
        #expect(harness.previewLines.last == WatchSession.restartLine(.declined(.notBuilt)))
        // 作り直す要求なら、いまのソースで本番を作り直せる
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        #expect(harness.gens.count == launched + 1)
    }

    @Test("作り直しの最中に頼んだ起こし直しは、済んでから 1 回だけ、済んだ版の子へ当たる")
    func aRestartAskedDuringABuildRunsAfterIt() async throws {
        let harness = try Harness()
        try #require(await harness.save())
        let rebuilds = harness.rebuilds
        let building = try await harness.holdBuild()
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        let built = try #require(harness.gens.last)
        for _ in 0..<3 { await harness.beat() }
        #expect(harness.rebuilds == rebuilds + 1)
        let restarted = try #require(harness.gens.last)
        #expect(restarted !== built, "済んだ版の子を起こし直していない")
        #expect(harness.gens.count == 3, "起こし直しは 1 回だけ")
        #expect(harness.previewLines.filter { $0 == WatchSession.restartLine(.restarted(audition: false)) }.count == 1)
    }

    @Test("試聴の中で頼んだ起こし直しは、行う前に試聴が終わると捨てて名乗る")
    func aRestartAskedInAnAuditionIsDroppedWhenItEndsFirst() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        try #require(await harness.save())
        let building = try await harness.holdBuild()
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        let launched = harness.gens.count
        harness.releaseRebuild()
        await building.value
        for _ in 0..<2 { await harness.beat() }
        #expect(harness.gens.count == launched)
        #expect(harness.session.child === production && production.isRunning)
        #expect(harness.previewLines.contains(WatchSession.restartLine(.dropped)))
        #expect(harness.clocks.allSatisfy { $0 == 0 })
    }

    // MARK: - 時計の場所 (完了条件 2 の `--keep-time`)

    @Test("時計を渡す場所は、番号ごとに同じディレクトリの別の名前になり、旗の無い見張りでは渡さない")
    func theClockPlaceNamesEachIndexWithinItsDirectory() {
        let place = WatchSession.Hooks.ClockPlace("/tmp/mokume-keep-time-1/clock")
        #expect(place.path == "/tmp/mokume-keep-time-1/clock")
        place.select(.init(place: 1))
        #expect(place.path == "/tmp/mokume-keep-time-1/clock-1")
        place.select(.init(place: 2))
        #expect(place.path == "/tmp/mokume-keep-time-1/clock-2")
        place.select(.init(place: 0))
        #expect(place.path == "/tmp/mokume-keep-time-1/clock")
        let none = WatchSession.Hooks.ClockPlace(nil)
        none.select(.init(place: 1))
        #expect(none.path == nil)
    }
}
