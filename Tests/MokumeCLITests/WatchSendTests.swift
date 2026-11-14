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

    // MARK: - 送った子の乗り換えを待つ間 (反証 3・4・5・10)

    /// 試聴に入り、試聴の子を起こして送るまで。乗り換えの合図はまだ出さない。
    private func sendWithoutSwitching(
        _ harness: Harness, previewShowsFirstFrame: Bool
    ) async throws -> (production: Process, sent: Process) {
        let production = try #require(await harness.save())
        // 作品のウィンドウは本番の 1 枚目を出している
        harness.session.generationShown(pid: production.processIdentifier)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let sent = try #require(await harness.save())
        if previewShowsFirstFrame {
            // プレビューが試聴の子へ乗り換え、1 枚目を出した (送る前)
            await harness.session.generationPromoted(pid: sent.processIdentifier, from: .preview)
            harness.session.generationShown(pid: sent.processIdentifier)
        }
        #expect(try await harness.ask("send")["accepted"] as? Bool == true)
        #expect(harness.session.waitingGeneration === sent)
        return (production, sent)
    }

    /// 送った子が乗り換えの前に終わった回の約束: 前の本番は止まらず本番に戻り、待ちは下り、名乗る。
    private func expectPreviousKept(
        _ harness: Harness, production: Process, sent: Process, _ comment: Comment
    ) throws {
        #expect(production.isRunning, "作品のウィンドウが映している前の本番が止まった: \(comment)")
        #expect(harness.session.child === production && harness.session.outgoing == nil, comment)
        #expect(harness.session.waitingGeneration == nil, comment)
        #expect(harness.session.isAuditioning, comment)
        #expect(harness.relinquished.contains([sent.processIdentifier]), "送った子を台へ手放していない: \(comment)")
        #expect(
            harness.previewLines.last?.hasPrefix("The version sent to the work's window") == true,
            "\(comment): \(harness.previewLines)")
        // 区画 `build` の記録は送る前 (試聴の版の記録) へ戻る
        #expect(try status(harness)["audition"] as? Bool == true, comment)
    }

    @Test(
        "送った子が、プレビューに 1 枚目を出した後・作品のウィンドウの乗り換えの前に終わると、前の本番は止まらず本番に戻る",
        arguments: ["bye", "crash", "fail"])
    func aSentChildEndingBeforeTheSwitchKeepsThePreviousVersion(_ ending: String) async throws {
        let harness = try Harness()
        let (production, sent) = try await sendWithoutSwitching(harness, previewShowsFirstFrame: true)
        harness.tell(sent, ending)
        #expect(!sent.isRunning)
        await harness.beat()
        try expectPreviousKept(harness, production: production, sent: sent, "1 枚目の後に \(ending)")
        // 前の本番は本番の子として走り続ける: 次の保存は試聴の子を起こす (前の本番は止まらない)
        let next = try #require(await harness.save())
        #expect(harness.session.auditionChild === next && production.isRunning)
    }

    @Test("送った子が、1 枚目を出す前・作品のウィンドウの乗り換えの前に失敗で終わっても、前の本番は止まらず本番に戻る")
    func aSentChildFailingBeforeItsFirstFrameKeepsThePreviousVersion() async throws {
        let harness = try Harness()
        let (production, sent) = try await sendWithoutSwitching(harness, previewShowsFirstFrame: false)
        harness.tell(sent, "fail")
        await harness.beat()
        try expectPreviousKept(harness, production: production, sent: sent, "1 枚目の前に fail")
    }

    @Test("作品のウィンドウが送った子へ乗り換えた後に送った子が終わると、前の本番はもう止まっている (普段の子の離脱)")
    func aSentChildEndingAfterTheSwitchIsAnOrdinaryDeparture() async throws {
        let harness = try Harness()
        let (production, sent) = try await sendWithoutSwitching(harness, previewShowsFirstFrame: true)
        await harness.session.generationPromoted(pid: sent.processIdentifier, from: .window)
        harness.wait(production)
        #expect(!production.isRunning)
        harness.tell(sent, "bye")
        await harness.beat()
        #expect(harness.previewLines.last?.hasPrefix("The sketch in the work's window") == true, "\(harness.previewLines)")
        #expect(harness.session.isAuditioning)
    }

    @Test("送った後、プレビューの合図が作品のウィンドウより先に届いても、前の本番は作品のウィンドウの合図まで止まらない")
    func thePreviewSignalDoesNotStopThePreviousVersion() async throws {
        let harness = try Harness()
        let (production, sent) = try await sendWithoutSwitching(harness, previewShowsFirstFrame: false)
        // 保存してすぐ送った: プレビューが試聴の子へ乗り換えた合図は、送った後に届く
        #expect(await harness.session.generationPromoted(pid: sent.processIdentifier, from: .preview) == nil)
        #expect(production.isRunning, "プレビューの合図で前の本番を止めた")
        #expect(harness.session.waitingGeneration === sent, "プレビューの合図で乗り換えの待ちが下りた")
        // プレビューが送った子の絵を受け取れない知らせも、作品のウィンドウのことではない
        var lines: [String] = []
        await WatchCommand.retireUndeliverable(
            .noSurface, session: harness.session, waiting: sent, pid: sent.processIdentifier, from: .preview,
            preview: { line, _ in if let line { lines.append(line) } })
        #expect(production.isRunning, "プレビューの受け取れない知らせで前の本番を止めた")
        #expect(harness.session.waitingGeneration === sent)
        #expect(lines == [WatchCommand.auditionUndeliverableLine])
        // 作品のウィンドウの合図で止まる
        await harness.session.generationPromoted(pid: sent.processIdentifier, from: .window)
        harness.wait(production)
        #expect(!production.isRunning)
        #expect(harness.session.child === sent)
    }

    @Test("送ると、出るときの戻り先として送った子と前の本番の両方をプレビューに覚えさせる")
    func sendingHoldsBothGenerationsForThePreview() async throws {
        let harness = try Harness()
        let (production, sent) = try await sendWithoutSwitching(harness, previewShowsFirstFrame: false)
        #expect(harness.held.last == [sent.processIdentifier, production.processIdentifier], "\(harness.held)")
    }

    @Test("試聴中に本番が自分で終わった後でも、送ると作品のウィンドウが送った子へ乗り換える")
    func sendingAfterTheProductionEndedSwitchesTheWorkWindow() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        harness.tell(production, "crash")
        await harness.beat()
        #expect(!production.isRunning)
        let report = try await harness.ask("send")
        #expect(report["accepted"] as? Bool == true, "\(report)")
        #expect(harness.held.last == [audition.processIdentifier], "止まった本番を戻り先に覚えさせた: \(harness.held)")
        await harness.session.generationPromoted(pid: audition.processIdentifier, from: .window)
        #expect(harness.session.child === audition && harness.session.outgoing == nil)
        #expect(harness.session.waitingGeneration == nil && audition.isRunning)
    }

    @Test("作品のウィンドウの台が試聴の子の目録を採れなければ、noTarget で断り、何も動かさない")
    func sendingIsDeclinedWhenTheWorkWindowCannotAdopt() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        harness.canAdopt = false
        let report = try await harness.ask("send")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "noTarget", "\(report)")
        #expect(pidOf(report["audition"]) == audition.processIdentifier, "試聴の子のまま名乗らない")
        #expect(harness.session.auditionChild === audition && harness.session.child === production)
        #expect(harness.session.waitingGeneration == nil && production.isRunning)
        #expect(!harness.session.windowAccepts(pid: audition.processIdentifier), "試聴の子の目録を作品のウィンドウに採らせる")
        #expect(try status(harness)["audition"] as? Bool == true, "断ったのに記録を本番の版にした")
    }

    @Test("試聴の子が番号を名乗らない版と分かった回の送る要求は、noTarget で断る")
    func sendingAnUnidentifiedAuditionIsDeclined() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        _ = try #require(await harness.save())
        // プレビューに番号を名乗らない目録が来た (古いライブラリの試聴の子)。巡回が止めるより先に送る要求を読む
        #expect(!harness.session.previewAccepts(pid: nil))
        #expect(harness.session.auditionIsUnidentified)
        let report = try await harness.ask("send")
        #expect(report["accepted"] as? Bool == false)
        #expect(report["reason"] as? String == "noTarget", "\(report)")
        #expect(harness.adopted.isEmpty, "番号を名乗らない試聴の子を作品のウィンドウに採らせた")
        #expect(harness.session.child === production && production.isRunning)
        #expect(harness.session.waitingGeneration == nil)
    }

    @Test("終われと言われた後の送る要求は、noTarget で断り、本番の枠を入れ替えない")
    func sendingAfterAStopRequestIsDeclined() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let audition = try #require(await harness.save())
        harness.session.noteStopRequested()
        let report = try await harness.ask("send")
        #expect(report["reason"] as? String == "noTarget", "\(report)")
        #expect(harness.adopted.isEmpty)
        #expect(harness.session.child === production && harness.session.auditionChild === audition)
    }

    @Test("本番が乗り換えの途中の送る要求は、乗り換えの途中と読める案内で断る")
    func sendingWhileTheProductionSettlesNamesTheSwitch() async throws {
        let harness = try Harness()
        let (_, _) = try await sendWithoutSwitching(harness, previewShowsFirstFrame: false)
        // 送った子の乗り換えを待っている間に、もう 1 度送る
        let report = try await harness.ask("send")
        #expect(report["reason"] as? String == "noTarget", "\(report)")
        #expect(harness.previewLines.last == WatchSession.sendSettlingLine, "\(harness.previewLines)")
    }

    @Test("試聴の子を起こし直してから送ると、区画 build の記録は試聴の子を起こした作り直しの版の記録になる")
    func sendingARestartedAuditionRecordsItsBuild() async throws {
        let harness = try Harness()
        _ = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let first = try #require(await harness.save())
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        let restarted = try #require(harness.session.auditionChild)
        #expect(restarted !== first, "起こし直していない")
        let report = try await harness.ask("send")
        #expect(report["accepted"] as? Bool == true, "\(report)")
        let record = try status(harness)
        #expect(record["stamp"] as? String == "s2" && record["audition"] == nil, "\(record)")
        #expect(record["ok"] as? Bool == true, "\(record)")
    }

    @Test("起こし直した試聴の子を送った後に、その子が最初の絵の前に落ちても、起こし直しの失敗とは名乗らない")
    func aSentRestartedChildIsNoLongerARestart() async throws {
        let harness = try Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        _ = try #require(await harness.save())
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        let sent = try #require(harness.session.auditionChild)
        #expect(try await harness.ask("send")["accepted"] as? Bool == true)
        await harness.session.generationPromoted(pid: sent.processIdentifier, from: .window)
        harness.wait(production)
        let linesBefore = harness.previewLines.count
        harness.tell(sent, "fail")
        await harness.beat()
        let lines = harness.previewLines[linesBefore...]
        #expect(!lines.isEmpty)
        #expect(!lines.contains { $0.hasPrefix("Could not restart it") }, "\(lines)")
    }
}
