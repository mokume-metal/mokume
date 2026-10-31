// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Synchronization
import Testing

@testable import MokumeNetwork

/// 送り手の前提が満たされなかった回の名乗り (#3001) の道具の検査。
///
/// 本物の繋ぎで揺れる赤そのものは手元で再現しない (CI で 3 回)。名乗りが読み分けの材料を
/// 揃えていることを、作り物の送り元と作り物の読み口で確かめる。**名乗りの各部を外すと、ここのどれかが赤になる。**
@Suite("送り手の前提の名乗り")
struct LoopbackNamingTests {
    @Test("rangesText は連なりを畳み、昇順で重ならずに書く")
    func rangesTextFoldsRuns() {
        #expect(rangesText([]) == "[]")
        #expect(rangesText([7, 0, 1, 2, 5, 8, 7]) == "[0…2, 5, 7…8]")
        #expect(rangesText([3]) == "[3]")
    }

    @Test("繋げなかった素の相手は、connect の errno と局所のポートと受け口のポートを名乗り、PeerGroup の名乗りにも載る (#3537)")
    func rawPeersNameAFailedConnect() async throws {
        let refuse: RawStream.Connector = { _, _ in EADDRINUSE }
        let streams = PeerGroup { StreamClient(port: 58147, connector: refuse) }
        defer { streams.closeAll() }
        let browsers = PeerGroup { BrowserSocket(port: 58147, connector: refuse) }
        defer { browsers.closeAll() }
        try await requireWait("素の相手が繋げなかったと名乗らなかった") {
            streams[0].state != .connecting && browsers[0].state != .connecting
        }
        for text in [streams.statesText, browsers.statesText] {
            #expect(text.contains("connect failed"), "\(text)")
            #expect(text.contains("errno \(EADDRINUSE) Address already in use"), "\(text)")
            #expect(text.contains("局所のポート"), "\(text)")
            #expect(text.contains("受け口のポート 58147"), "\(text)")
        }
        #expect(!streams[0].isReady && !browsers[0].isReady)
    }

    @Test("期限つきの読みは、答えない読みを期限で諦めて nil を返し、答える読みはその値を返す")
    func readWithinGivesUpOnABlockedRead() async {
        let gate = DispatchSemaphore(value: 0)
        let started = Date()
        let blocked: Int? = await readWithin(0.2) {
            gate.wait()
            return 1
        }
        #expect(blocked == nil)
        #expect(Date().timeIntervalSince(started) < 3, "期限を越えて待った")
        gate.signal()
        #expect(await readWithin(1) { 7 } == 7)
    }

    @Test("受け口の待ち行列が答えなければ、答えなかったと名乗り、受け入れ・持つ数は読めたふりをしない。送り手の名乗りは受け口の知らせに入れない")
    func receiverViewNamesAQueueThatDidNotAnswer() async {
        let told = Told()
        told.append("Could not send to 127.0.0.1:1 (Address already in use)")
        told.append("udp :1 is in use")
        let gate = DispatchSemaphore(value: 0)
        let view = await receiverView(.running, tracing: nil, told: told, within: 0.2) {
            gate.wait()
            return (SenderTally(), 0)
        }
        gate.signal()
        #expect(view.tally == nil && view.connections == nil)
        #expect(view.accepted == nil)
        #expect(view.text.contains("受け口の待ち行列が 0.2 秒答えなかった"), "\(view.text)")
        #expect(!view.text.contains("受け入れ 0"), "\(view.text)")
        // 受け口の知らせは残し、送り手の行は除く (送り手の行は送り手の側で数える)
        #expect(view.told == ["udp :1 is in use"])
        #expect(view.text.contains("受け口の知らせ 1 行"), "\(view.text)")

        let answered = await receiverView(.running, tracing: nil, told: told, within: 1) {
            (SenderTally(accepted: 3, closedIdle: 2, ended: 1), 4)
        }
        #expect(answered.text.contains("受け入れ 3・黙りで閉じた 2・終わって外れた 1・持つ数 4"), "\(answered.text)")
    }

    /// 呼ばれた順を記録する作り物の読み口。
    private final class Calls: Sendable {
        let order = Mutex<[String]>([])
        func add(_ name: String) { order.withLock { $0.append(name) } }
    }

    private func scripted(
        _ calls: Calls = Calls(), before: Int?, after: Int?, probe: Bool
    ) -> Landing {
        let views = Mutex([before, after])
        return Landing(
            receiver: {
                calls.add("受け口")
                let accepted = views.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? nil
                return ReceiverView(
                    state: .running, trace: nil,
                    tally: accepted.map { SenderTally(accepted: $0) }, connections: accepted,
                    told: [], patience: 3)
            },
            probe: {
                calls.add("1 通")
                return probe
            })
    }

    @Test("1 通が読まれても、受け入れの数が増えなければ別の繋ぎで渡されたと名乗り、増えれば新しい送り元を受けられたと名乗る")
    func requireSentNamesTheAcceptedDifference() async throws {
        let log = SendLog()
        let unchanged = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(unchanged.contains("読めたが受け入れは増えていない (差 0。別の繋ぎで渡された)"), "\(unchanged)")

        let grown = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 6, probe: true))
        }
        #expect(grown.contains("読めた・受け入れ +1 (新しい送り元を受けられた)"), "\(grown)")

        let notRead = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 5, probe: false))
        }
        #expect(notRead.contains("読めなかった (受け口が 3 秒のうちに新しい送り元の datagram を渡さなかった)"), "\(notRead)")

        // 受け口の待ち行列が答えなければ、受け入れの数の差は言えない
        let unanswered = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: nil, after: nil, probe: true))
        }
        #expect(unanswered.contains("読めた (受け入れの数は読めない)"), "\(unanswered)")
        #expect(unanswered.contains("受け口の待ち行列が 3.0 秒答えなかった"), "\(unanswered)")

        // 1 通で分からないことを、どの名乗りにも正直に書く
        for text in [unchanged, grown, notRead, unanswered] {
            #expect(text.contains("一度に来たときだけ受け口で落ちる形は、この 1 通では分からない"), "\(text)")
        }
    }

    @Test("素の socket から送る記録は、名乗りの 0 行を黙っていると読ませず、替えた回数を言わず、様子を読めない送り元と名乗り、待っただけの段も秒数を名乗る")
    func requireSentNamesARawSocketSender() async throws {
        let log = SendLog(rawSocket: true)
        log.watch("素の socket") { nil }
        log.record(
            label: "素の socket", expected: 3, heard: 1, missing: nil, replacements: 0,
            heardAfterReplacement: 0, waited: 1, limit: 5)
        let text = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 6, probe: true))
        }
        #expect(text.contains("素の socket: 読めたのは 1/3・読めなかった 2 通 (どの通かは分からない)"), "\(text)")
        #expect(text.contains("送り元の様子 {様子を読めない送り元}×1"), "\(text)")
        #expect(text.contains("素の socket から直に送った"), "\(text)")
        #expect(!text.contains("黙っている") && !text.contains("替えた"), "\(text)")
        #expect(text.contains("待った 1.0 秒/期限 5.0 秒"), "\(text)")

        // 通の数を数えない待ちは、待った秒数と期限だけを足す (数え方の欄は出ない)
        let waiting = SendLog(rawSocket: true)
        waiting.recordWait(waited: 0.5, limit: 2)
        waiting.recordWait(waited: 0.3, limit: 3)
        #expect(waiting.waitText == "待った 0.8 秒/期限 5.0 秒", "\(waiting.waitText)")
        #expect(!waiting.senderText.contains("読めたのは"), "\(waiting.senderText)")

        // 素の socket でない記録は、従来どおり黙っていると名乗る
        let silent = try await said {
            try await requireSent(
                false, "読めなかった", log: SendLog(), landing: scripted(before: 5, after: 6, probe: true))
        }
        #expect(silent.contains("名乗りは 0 行 (黙っている)"), "\(silent)")
    }

    @Test("素の socket の sendto が失敗していたら、送り手で出なかったと名乗って受け口のせいと読ませず、成功していればそう言い、戻りを記録していなければそう言う")
    func requireSentNamesTheRawSendResult() async throws {
        let peer = try RawDatagramSocket()
        defer { peer.release() }
        // ポート 0 へは送れない (送り手で出ない形)
        #expect(peer.send([1, 2, 3], to: 0) == -1)
        #expect(peer.sendRecord.attempts == 1 && peer.sendRecord.failures == 1)
        #expect(peer.sendRecord.firstFailure?.requested == 3)

        let log = SendLog(rawSocket: true)
        log.watch(raw: peer)
        let failed = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(failed.contains("素の socket の sendto が失敗した: 1 回のうち 1 回・最初の失敗は errno "), "\(failed)")
        #expect(failed.contains("3 バイトを送ろうとした"), "\(failed)")
        #expect(failed.contains("送り手で出なかった回があり、読めなかった理由は受け口ではなく送り手側の見込み"), "\(failed)")
        #expect(!failed.contains("とも成功"), "\(failed)")

        // 送れていれば、そう言う (誰も待っていないポートへも、sendto 自体は成功する)
        let sender = try RawDatagramSocket()
        defer { sender.release() }
        #expect(sender.send(Array("hello".utf8), to: 9) == 5)
        #expect(sender.send(Array("x".utf8), to: 9) == 1)
        let sentLog = SendLog(rawSocket: true)
        sentLog.watch(raw: sender)
        let sent = try await said {
            try await requireSent(
                false, "読めなかった", log: sentLog, landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(sent.contains("sendto は 2 回とも成功 (計 6 バイト)"), "\(sent)")
        #expect(!sent.contains("送り手で出なかった"), "\(sent)")

        // 戻りを記録していない記録 (送った socket を渡さなかった) は、そう言う
        let unwatched = try await said {
            try await requireSent(
                false, "読めなかった", log: SendLog(rawSocket: true),
                landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(unwatched.contains("sendto の戻りは記録していない"), "\(unwatched)")
    }

    @Test("名乗りは、送り手の様子と受け口の様子を同じ時点で撮ってから 1 通を送り、その後にもう 1 度受け口を撮る。満たされたときは何もしない")
    func requireSentTakesSnapshotsAroundTheProbe() async throws {
        let calls = Calls()
        let log = SendLog()
        log.watch {
            calls.add("送り手")
            return nil
        }
        _ = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(calls, before: 1, after: 2, probe: true))
        }
        #expect(calls.order.withLock { $0 } == ["送り手", "受け口", "1 通", "受け口"])

        let satisfied = Calls()
        try await requireSent(
            true, "名乗らない", log: log, landing: scripted(satisfied, before: 1, after: 2, probe: true))
        #expect(satisfied.order.withLock { $0 }.isEmpty)
    }

    @Test("読めなかった番号と、そのうち名乗った送り元・黙っている送り元を、名乗りが届いた順に依らず同じ文で名乗る")
    func senderTextNamesMissingNumbersInAStableOrder() {
        func log(arrival: [Int]) -> SendLog {
            let log = SendLog()
            for index in 0..<6 {
                let trace = SendTrace(
                    issued: 1, completed: index == 4 ? 1 : 0, failed: 0,
                    state: index == 4 ? "ready" : "preparing")
                log.watch("/from", index: index) { trace }
            }
            for index in arrival {
                log.complain("Could not send to 127.0.0.1:9 (Address already in use)", label: "/from", index: index)
            }
            // 0 と 3 は読めた。1・2・4・5 は読めなかった (1 と 5 が名乗った)
            log.record(
                label: "/from", expected: 6, heard: 2, missing: [1, 2, 4, 5], replacements: 2,
                heardAfterReplacement: 1, waited: 1.5, limit: 2)
            return log
        }
        let first = log(arrival: [5, 1, 3]).senderText
        let second = log(arrival: [3, 1, 5]).senderText
        #expect(first == second, "名乗りの届いた順で文が揺れた")
        #expect(
            first.contains("/from: 読めたのは 2/6・読めなかった 4 本 [1…2, 4…5]・うち名乗った [1, 5]・名乗らずに黙っている [2, 4]"),
            "\(first)")
        // 読めなかった側と読めた側で、送り元の様子を分けて数える。名乗った 3 は読めた側
        #expect(
            first.contains("読めなかった側の送り元の様子 {出 1・誤り無し 0・誤り 0・最後 preparing}×3 {出 1・誤り無し 1・誤り 0・最後 ready}×1"),
            "\(first)")
        #expect(first.contains("読めた側の送り元の様子 {出 1・誤り無し 0・誤り 0・最後 preparing}×2"), "\(first)")
        #expect(first.contains("名乗った送り元 /from[1, 3, 5]・名乗り 3 行"), "\(first)")
        #expect(log(arrival: []).senderText.contains("名乗りは 0 行 (黙っている)"))
    }

    // MARK: - 待ちの道具 (#3124)

    @Test("前提を待つ道具は、満たされなければ何が・どれだけ待って満たされなかったかを名乗って止まり、満たされれば何も言わない")
    func requireWaitNamesWhatDidNotHappen() async throws {
        let bare = try await said {
            try await requireWait("相手が閉じなかった", within: 0.1) { false }
        }
        #expect(bare.contains("相手が閉じなかった"), "\(bare)")
        #expect(bare.contains("期限 0.1 秒"), "\(bare)")

        let detailed = try await said {
            try await requireWait("数が揃わなかった", within: 0.1, detail: { "数えたのは 2" }) { false }
        }
        #expect(detailed.contains("数が揃わなかった") && detailed.contains("数えたのは 2"), "\(detailed)")

        // 満たされれば、止まらずに返る (止まれば検査が赤になる)
        try await requireWait("すぐ満ちる", within: 0.1) { true }
    }

    @Test("集める道具は、足りなければ個数と読めた数と手がかりを名乗って止まり、揃えば読めたものを返す")
    func requireCollectedNamesTheShortfall() async throws {
        var given = false
        let short = try await said {
            _ = try await requireCollected(
                count: 3, within: 0.1, what: "受け口が読めなかった", detail: { "状態: running" }
            ) {
                defer { given = true }
                return given ? [] : ["a"]
            }
        }
        #expect(short.contains("受け口が読めなかった"), "\(short)")
        #expect(short.contains("3 個のうち読めたのは"), "\(short)")
        #expect(short.contains("状態: running"), "\(short)")

        var round = 0
        let enough = try await requireCollected(count: 3, within: 1, what: "集める") {
            round += 1
            return round == 1 ? ["a", "b"] : ["c"]
        }
        #expect(enough == ["a", "b", "c"])
    }

    @Test("満たされなかったときの名乗りを呼ぶ側が行う待ちは、名乗る段を呼び、その段が投げなくても止まる")
    func requireArrivalCallsTheNamingStep() async throws {
        let called = Mutex(0)
        let thrown = try await said {
            try await requireArrival("着かなかった", within: 0.1, until: { false }) {
                called.withLock { $0 += 1 }
                try #require(Bool(false), "名乗る段の文")
            }
        }
        #expect(called.withLock { $0 } == 1)
        #expect(thrown.contains("名乗る段の文"), "\(thrown)")

        let silent = try await said {
            try await requireArrival("着かなかった", within: 0.1, until: { false }) {
                called.withLock { $0 += 1 }
            }
        }
        #expect(silent.contains("着かなかった"), "名乗る段が黙っても止まる: \(silent)")

        try await requireArrival("すぐ着く", within: 0.1, until: { true }) {
            called.withLock { $0 += 100 }
        }
        #expect(called.withLock { $0 } == 2, "満たされたら名乗る段は呼ばない")
    }

    @Test("起きないことの観測は、期限まで起きなければ真、起きれば偽")
    func doesNotHappenIsTrueOnlyWhenItNeverHappens() async {
        #expect(await doesNotHappen(within: 0.05) { false })
        #expect(await !doesNotHappen(within: 0.5) { true })
    }
}
