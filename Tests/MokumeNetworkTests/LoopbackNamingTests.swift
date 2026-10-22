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

    @Test("本物の送り手の跡は、出した数・誤り無しの完了・誤りの完了・最後の状態を数える")
    func datagramSenderTraceCountsWhatItSaw() async throws {
        let told = Told()
        let source = DatagramSource<String>.text(
            port: 0, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let receiver = UDPPort(
            port: 0, name: "udp :0", source: source, outbound: nil, owner: nil, warn: told.append)
        try receiver.open()
        defer { receiver.close() }
        try await requireState(told: told, tracing: source) { receiver.state }
        let port = try #require(source.boundPort)

        let sender = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { sender.stop() }
        #expect(sender.sendTrace == SendTrace(), "送る前は何も見ていない")
        sender.send(Array("a".utf8))
        sender.send(Array("b".utf8))
        #expect(sender.sendTrace.issued == 2)
        try await requireWait(
            "送り手が 2 通を誤り無しで終えて、繋ぎが ready になった", detail: { "\(sender.sendTrace)" },
            until: { sender.sendTrace.completed == 2 && sender.sendTrace.state == "ready" })
        #expect(sender.sendTrace.failed == 0)

        // 誤りつきの完了と待っている繋ぎは、それぞれの数・状態に出る
        let other = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        other.noted(.waiting(.posix(.ENETDOWN)))
        #expect(other.sendTrace.state?.hasPrefix("waiting") == true, "\(other.sendTrace)")
        other.noted(completion: .posix(.ECONNREFUSED))
        #expect(other.sendTrace.failed == 1 && other.sendTrace.completed == 0, "\(other.sendTrace)")
        other.noted(completion: nil)
        #expect(other.sendTrace.completed == 1, "\(other.sendTrace)")
    }
}
