// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCLI

/// 送る要求 — 試聴の版を本番にして、作品のウィンドウを乗り換え、前の本番を止める (#3566)。
///
/// 作品のウィンドウの台が送った世代へ乗り換えて頼みを当てるのは `SharedFrameStageTests` が見る。ここは見張りの側
/// (応答・本番の枠の入れ替え・前の本番の止め方・次の試聴の子を起こす順・断る回) を、決まった順で見る。
/// **GPU もウィンドウも使わない** (``WatchAuditionTests/Harness`` と同じ替え玉)。
@Suite("送る要求は、試聴の版を本番にして前の本番を止め、試聴に居続ける", .signalStateKept)
@MainActor
struct WatchSendTests {
    typealias Harness = WatchAuditionTests.Harness

    private func pidOf(_ part: Any?) -> Int32? { ((part as? [String: Any])?["pid"] as? NSNumber)?.int32Value }

    private func status(_ harness: Harness) throws -> [String: Any] {
        let data = try Data(contentsOf: BuildReport.statusURL(under: harness.session.facetBase))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("送ると、作品のウィンドウに試聴の子を採らせ、乗り換えの合図で前の本番が止まる。送った後も試聴に居る")
    func sendingSwitchesTheWorkWindowAndStopsThePreviousVersion() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())

        let report = try await harness.ask("send")
        #expect(report["accepted"] as? Bool == true, "\(report)")
        #expect(report["action"] as? String == "send")
        #expect(report["auditioning"] as? Bool == true, "送った後も試聴に居る")
        #expect(pidOf(report["production"]) == production.processIdentifier, "乗り換えまでは前の本番が映る")
        #expect(report["audition"] == nil, "送った子はもう試聴の子ではない")
        #expect(harness.adopted == [audition.processIdentifier], "作品のウィンドウに採らせていない")
        #expect(harness.session.child === audition && harness.session.outgoing === production)
        #expect(harness.session.auditionChild == nil)
        #expect(harness.session.windowAccepts(pid: audition.processIdentifier), "作品のウィンドウが送った子の目録を弾く")
        #expect(production.isRunning, "乗り換えの前に前の本番を止めた")
        // 区画 `build` の記録は、送った版が本番の版になる
        let record = try status(harness)
        #expect(record["stamp"] as? String == "s2" && record["audition"] == nil, "\(record)")

        // 台が送った子へ乗り換えた合図で、前の本番が止まる
        await harness.session.generationPromoted(pid: audition.processIdentifier)
        harness.wait(production)
        #expect(!production.isRunning, "前の本番が止まらない")
        #expect(audition.isRunning)
        #expect(harness.session.isAuditioning)
        // もう送る相手は居ない。本番は送った子
        let again = try await harness.ask("send")
        #expect(again["reason"] as? String == "noTarget")
        #expect(pidOf(again["production"]) == audition.processIdentifier)
    }

    @Test("送った後の保存は、前の本番が止まり終えるまで試聴の子を起こさず、止まり終えてから起こす")
    func theNextAuditionWaitsUntilThePreviousVersionHasStopped() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        #expect(try await harness.ask("send")["accepted"] as? Bool == true)

        // 乗り換えの合図の前に保存した。作り直しは通るが、試聴の子は起こさない
        let launched = harness.gens.count
        #expect(await harness.save() == nil, "前の本番が止まる前に次の試聴の子を起こした")
        await harness.beat()
        #expect(harness.gens.count == launched)
        #expect(production.isRunning)

        // 乗り換えて前の本番が止まり終えてから、保留していた試聴の子を起こす
        await harness.session.generationPromoted(pid: audition.processIdentifier)
        harness.wait(production)
        #expect(!production.isRunning)
        await harness.beat()
        let next = try #require(harness.gens.last)
        #expect(harness.gens.count == launched + 1, "止まり終えた後に試聴の子を起こさない")
        #expect(harness.session.auditionChild === next)
        #expect(harness.session.child === audition, "本番は送った子のまま")
    }

    @Test("送ってから出ると、プレビューは送った子 (いまの本番) へ戻り、本番は動かず、記録は送った版のまま")
    func leavingAfterASendKeepsTheSentVersion() async throws {
        let harness = try Harness()
        _ = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        #expect(try await harness.ask("send")["accepted"] as? Bool == true)
        await harness.session.generationPromoted(pid: audition.processIdentifier)
        let launched = harness.gens.count

        let report = try await harness.ask("leave")
        #expect(report["accepted"] as? Bool == true)
        #expect(report["auditioning"] as? Bool == false)
        #expect(pidOf(report["production"]) == audition.processIdentifier)
        #expect(harness.returned.last == audition.processIdentifier, "プレビューを送った子へ戻していない")
        await harness.beat()
        #expect(harness.gens.count == launched, "出た後に作り直した")
        #expect(try status(harness)["stamp"] as? String == "s2")
    }

    @Test("試聴に入っていない見張りの送る要求は、notAuditioning で断り、何も動かさない")
    func sendingWithoutAnAuditionIsDeclined() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        let report = try await harness.ask("send")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "notAuditioning")
        #expect(report["auditioning"] as? Bool == false)
        #expect(harness.adopted.isEmpty)
        #expect(harness.session.child === production)
    }

    /// 送る相手の子が居ない 3 つの回 (2026-11-10 の決定)。どれも noTarget で断り、試聴に留まり、作品のウィンドウは動かない。
    private func expectDeclinedAsNoTarget(
        _ report: [String: Any], _ harness: Harness, production: Process, _ comment: Comment
    ) {
        #expect(report["accepted"] as? Bool == false, comment)
        #expect(report["reason"] as? String == "noTarget", "\(comment): \(report)")
        #expect(report["auditioning"] as? Bool == true, comment)
        #expect(report["audition"] == nil, comment)
        #expect(pidOf(report["production"]) == production.processIdentifier, comment)
        #expect(harness.adopted.isEmpty, "作品のウィンドウに採らせた: \(comment)")
        #expect(harness.session.child === production && production.isRunning, comment)
        #expect(harness.session.isAuditioning, comment)
    }

    @Test("試聴に入ってまだ保存していない回の送る要求は、noTarget で断り、試聴に留まる")
    func sendingBeforeASaveIsDeclined() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        expectDeclinedAsNoTarget(try await harness.ask("send"), harness, production: production, "未保存")
    }

    @Test("試聴の子が落ちた回の送る要求は、noTarget で断り、試聴に留まる")
    func sendingAfterTheAuditionEndedIsDeclined() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        harness.tell(audition, "crash")
        #expect(!audition.isRunning)
        expectDeclinedAsNoTarget(try await harness.ask("send"), harness, production: production, "落ちた")
    }

    @Test("作り直しの最中の送る要求は、待たずに noTarget で断り、試聴に留まる")
    func sendingDuringABuildIsDeclined() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        _ = try #require(await harness.save())
        let building = try await harness.holdBuild()
        let report = try await harness.ask("send")
        harness.releaseRebuild()
        await building.value
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "noTarget", "\(report)")
        #expect(report["auditioning"] as? Bool == true)
        #expect(harness.adopted.isEmpty, "作り直しの最中に作品のウィンドウに採らせた")
        #expect(harness.session.child === production && production.isRunning)
    }
}
