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
        #expect(harness.previewLines.contains(WatchCommand.auditionDiscardedLine(productionRunning: true)))
        #expect(try statusObject(harness)["audition"] == nil, "記録は本番の版のまま")
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

    @Test("読みの最中に頼んだ作り直しは、その読みが拾った保存より後の出来事で、頼みを読んだ時点の役で作り直す")
    func aRebuildAskedDuringAReadOvertakesTheSaveItPicksUp() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        // 本番のまま保存 s2 を読み始め、その読みの最中に試聴へ入ってから作り直しを頼む
        let reading = try await harness.holdRead()
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        #expect(try await harness.ask("rebuild")["accepted"] as? Bool == true)
        harness.releaseStamp()
        await reading.value
        // 頼みが後なので、s2 は頼みを読んだ時点の役 (試聴) で 1 回作り直す。本番は動かない
        let started = try #require(harness.gens.last)
        #expect(started !== production)
        #expect(harness.session.isAuditionGeneration(pid: started.processIdentifier))
        #expect(harness.session.child === production && production.isRunning)
        let record = try statusObject(harness)
        #expect(record["audition"] as? Bool == true)
        #expect(record["requested"] as? String == "rebuild")
        #expect(record["stamp"] as? String == "s2")
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
        #expect(harness.clockRenewals == 1)
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
        #expect(harness.clockRenewals == 1)
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
        #expect(harness.clockRenewals == 0)
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
        #expect(harness.clockRenewals == 0)
    }

    // MARK: - 時計の場所 (完了条件 2 の `--keep-time`)

    @Test("時計を渡す場所は、替えるたびに同じディレクトリの別の名前になり、旗の無い見張りでは替えない")
    func theClockPlaceRenewsWithinItsDirectory() {
        let place = WatchSession.Hooks.ClockPlace("/tmp/mokume-keep-time-1/clock")
        #expect(place.path == "/tmp/mokume-keep-time-1/clock")
        place.renew()
        let first = place.path
        place.renew()
        #expect(first == "/tmp/mokume-keep-time-1/clock-1")
        #expect(place.path == "/tmp/mokume-keep-time-1/clock-2")
        let none = WatchSession.Hooks.ClockPlace(nil)
        none.renew()
        #expect(none.path == nil)
    }
}
