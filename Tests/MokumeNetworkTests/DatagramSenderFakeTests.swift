// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Testing

@testable import MokumeNetwork

/// UDP の送り手と、送り手を持つ入り口の約束を、疑似の繋ぎ (``FakeWire``) の上で確かめる (#3231)。
/// **socket を開かず、実時間を待たない。** 送ったバイト列と、繋ぎの完了・移り変わりが返る順序は検査が
/// 決めるので、同じ予定からは毎回同じ結果になる。
///
/// かつて 127.0.0.1 の受け口へ本当に送って確かめていた約束 (上限に入らない送りは出さず、続けて送ったものは
/// 出る・空の文字列は 0 バイトの送りになる・送るだけの入り口は受けずに送る) は、負荷の下の OS の socket の
/// 揺れで赤になりうる検査だった。揺れるのは OS の側で、約束の側ではない。ここでは約束だけを見る。
/// 本物の socket の検査は、往復 (`UDPPortTests` の `sendReachesTheDestination` と、空の文字列が 0 バイトの
/// datagram として届く `emptySendArrivesAsAnEmptyString`)・使用中・疑似が写している OS の実測
/// (`DatagramSenderLoopbackTests`) に絞った。
///
/// 赤の文面は `[network plan=<予定の名>]` で始める (#3207 の K1。生成器は使わないので seed は無い)。
@Suite("疑似の繋ぎで送る")
struct DatagramSenderFakeTests {
    /// 赤の文面の頭 (K1)。
    private func plan(_ name: String, _ detail: String = "") -> Comment {
        "[network plan=\(name)] \(detail)"
    }

    private func makeSender(_ wire: FakeWire, _ told: Told, port: Int = 7000) -> DatagramSender {
        DatagramSender(host: "127.0.0.1", port: port, connect: wire.connect, warn: told.append)
    }

    // MARK: - 送り手

    @Test("送るものは、作るときに決めた宛先への繋ぎ 1 つに、送った順に 1 つずつ出る。空も 0 バイトで出る")
    func sentBytesGoOutInOrderOnOneLink() {
        let name = "one-link-in-order"
        let wire = FakeWire()
        let told = Told()
        let sender = makeSender(wire, told)
        sender.send([1])
        sender.send([2, 3])
        sender.send([])
        sender.stop()

        #expect(wire.links.count == 1, plan(name, "作られた繋ぎ \(wire.links.count) 本"))
        let link = wire.links.first
        #expect(link?.host == "127.0.0.1" && link?.port == 7000, plan(name))
        #expect(link?.started == true, plan(name))
        #expect(wire.sent == [[1], [2, 3], []], plan(name, "\(wire.sent)"))
        #expect(link?.cancelled == true, plan(name, "stop() が繋ぎを閉じなかった"))
        #expect(told.lines.isEmpty, plan(name, "\(told.lines)"))
        #expect(sender.sendTrace.issued == 3 && sender.sendTrace.completed == 3, plan(name, "\(sender.sendTrace)"))
    }

    @Test("送りが拒否で返れば 1 度だけ名乗り、その繋ぎを閉じて、次の送りは新しい繋ぎで出る")
    func aRefusedSendIsToldOnceAndTheNextOneUsesANewLink() {
        let name = "refused-then-new-link"
        // 0 番の繋ぎの 2 つ目の送りが拒否で返る (本物では、拒否は次の送りの完了の誤りとして返る)
        let wire = FakeWire { link, index in link == 0 && index == 1 ? SendPlan.refused : nil }
        let told = Told()
        let sender = makeSender(wire, told)
        sender.send([1])
        sender.send([2])
        sender.send([3])
        sender.send([4])
        sender.stop()

        #expect(wire.links.count == 2, plan(name, "作られた繋ぎ \(wire.links.count) 本"))
        #expect(wire.links.first?.sent == [[1], [2]], plan(name))
        #expect(wire.links.first?.cancelled == true, plan(name, "拒否の後も同じ繋ぎを使っている"))
        #expect(wire.links.last?.sent == [[3], [4]], plan(name))
        #expect(told.lines.count == 1, plan(name, "\(told.lines)"))
        let line = told.lines.first ?? ""
        #expect(line.hasPrefix("Could not send to 127.0.0.1:7000 ("), plan(name, line))
        #expect(line.contains("Check that something is listening"), plan(name, line))
        #expect(sender.sendTrace.failed == 1, plan(name, "\(sender.sendTrace)"))
    }

    @Test("繋ぎが待っていると名乗れば、繋ぎを捨てずに 1 度だけ名乗り、送ったものはその繋ぎに積まれる")
    func aWaitingLinkIsToldOnceAndKept() {
        let name = "waiting-link-kept"
        let wire = FakeWire()
        let told = Told()
        let sender = makeSender(wire, told)
        sender.send([1])
        sender.onQueue {}
        let link = wire.links.first
        link?.move(to: .waiting(.posix(.ENETDOWN)))
        link?.move(to: .waiting(.posix(.ENETDOWN)))
        sender.send([2])
        sender.stop()

        #expect(wire.links.count == 1, plan(name, "待っている繋ぎを捨てた"))
        #expect(wire.sent == [[1], [2]], plan(name))
        #expect(told.lines.count == 1, plan(name, "\(told.lines)"))
        let line = told.lines.first ?? ""
        #expect(line.contains("Network is down") && line.contains("Local Network"), plan(name, line))
    }

    @Test("送り手の跡は、出した数・誤り無しの完了・誤りの完了・最後の状態を数える")
    func sendTraceCountsWhatItSaw() {
        let name = "send-trace"
        // 0 番の繋ぎの 3 つ目の送りだけが拒否で返る
        let wire = FakeWire { link, index in link == 0 && index == 2 ? SendPlan.refused : nil }
        let told = Told()
        let sender = makeSender(wire, told)
        #expect(sender.sendTrace == SendTrace(), plan(name, "送る前は何も見ていない"))
        sender.send([1])
        sender.send([2])
        sender.onQueue {}
        wire.links.first?.move(to: .ready)
        #expect(
            sender.sendTrace == SendTrace(issued: 2, completed: 2, failed: 0, state: "ready"),
            plan(name, "\(sender.sendTrace)"))

        // 誤りつきの完了は、誤りの完了の数に出る
        sender.send([3])
        sender.stop()
        #expect(
            sender.sendTrace == SendTrace(issued: 3, completed: 2, failed: 1, state: "ready"),
            plan(name, "\(sender.sendTrace)"))

        // 待っている繋ぎと、跡だけを残す口 (読み替えには触れない)
        let other = makeSender(FakeWire(), told)
        other.noted(.waiting(.posix(.ENETDOWN)))
        #expect(other.sendTrace.state?.hasPrefix("waiting") == true, plan(name, "\(other.sendTrace)"))
        other.noted(completion: .posix(.ECONNREFUSED))
        #expect(other.sendTrace.failed == 1 && other.sendTrace.completed == 0, plan(name, "\(other.sendTrace)"))
        other.noted(completion: nil)
        #expect(other.sendTrace.completed == 1, plan(name, "\(other.sendTrace)"))
        #expect(told.lines.count == 1, plan(name, "拒否の 1 度だけ名乗る: \(told.lines)"))
    }

    // MARK: - 送り手を持つ入り口

    @Test("UTF-8 で 9216 バイト以上の文字列は繋ぎへ出さず、続けて送った文字列は出る")
    func oversizedTextIsNotSentAndTheNextTextIs() {
        let name = "udp-oversized-then-text"
        let wire = FakeWire()
        let told = Told()
        let udp = UDPPort(
            port: 1, name: "udp :1", source: RecordedSource<String>(batches: []),
            outbound: makeSender(wire, told, port: 6001), owner: nil, warn: told.append)
        udp.send(String(repeating: "a", count: 20000))
        udp.send("after")
        udp.close()

        #expect(wire.sent == [Array("after".utf8)], plan(name, "出たもの \(wire.sent.map(\.count)) バイト"))
        #expect(wire.links.first?.port == 6001, plan(name))
        #expect(told.lines.count == 1, plan(name, "\(told.lines)"))
        #expect(told.count(containing: "9215 bytes at most") == 1, plan(name, "\(told.lines)"))
        #expect(told.count(containing: "listening") == 0, plan(name, "\(told.lines)"))
    }

    @Test("符号化して 9216 バイト以上になる OSC のメッセージは繋ぎへ出さず、続けて送ったメッセージは出る")
    func oversizedMessageIsNotSentAndTheNextMessageIs() throws {
        let name = "osc-oversized-then-message"
        let wire = FakeWire()
        let told = Told()
        let osc = OSCPort(
            port: nil, name: "osc (send only)", source: RecordedSource<OSCMessage>(batches: []),
            outbound: makeSender(wire, told, port: 9000), owner: nil, warn: told.append)
        osc.send(OSCMessage("/big", arguments: [.blob([UInt8](repeating: 7, count: 12000))]))
        osc.send("/after", 1)
        osc.close()

        #expect(wire.sent == [try Wire.encoded(OSCMessage("/after", 1))], plan(name, "出たもの \(wire.sent.map(\.count)) バイト"))
        #expect(told.lines.count == 1, plan(name, "\(told.lines)"))
        #expect(told.count(containing: "9212 bytes at most") == 1, plan(name, "\(told.lines)"))
        #expect(told.count(containing: "listening") == 0, plan(name, "\(told.lines)"))
    }

    @Test("空の文字列の send は、0 バイトの datagram として繋ぎへ出る。前後の文字列は変わらず出て、送り手は何も言わない")
    func emptyTextIsSentAsZeroBytes() {
        let name = "udp-empty-text"
        let wire = FakeWire()
        let told = Told()
        let udp = UDPPort(
            port: 1, name: "udp :1", source: RecordedSource<String>(batches: []),
            outbound: makeSender(wire, told, port: 6001), owner: nil, warn: told.append)
        udp.send("x")
        udp.send("")
        udp.send("y")
        udp.close()

        #expect(wire.sent == [Array("x".utf8), [], Array("y".utf8)], plan(name, "\(wire.sent)"))
        #expect(told.lines.isEmpty, plan(name, "\(told.lines)"))
    }

    @Test("送るだけの入り口は、受けるポートを開かず、何も受けず、観測の inputs に行を出さず、送ったものは宛先への繋ぎに出る (#2469)")
    func sendOnlyPortSendsWithoutListening() throws {
        let name = "osc-send-only"
        let wire = FakeWire()
        let told = Told()
        // `createOSC(send:)` が組むのと同じ部品 (何も受けない出どころ・共通の送り手)
        let osc = OSCPort(
            port: nil, name: "osc (send only)", source: SendOnlySource(),
            outbound: makeSender(wire, told, port: 7000), owner: nil, warn: told.append)
        try osc.open()
        #expect(osc.port == nil, plan(name))
        #expect(osc.state == .running, plan(name))
        #expect(osc.report == nil, plan(name, "受け口ではないので、inputs に載らない"))

        osc.send("/size", Float(0.25))
        osc.send("/hit", 1)
        osc.supply()
        #expect(osc.messages.isEmpty, plan(name))
        #expect(osc.latest("/size") == nil, plan(name))
        #expect(osc.lastArrival == nil, plan(name))
        #expect(told.lines.isEmpty, plan(name, "\(told.lines)"))

        osc.close()
        #expect(osc.state == .stopped, plan(name))
        osc.send("/late", 1)
        #expect(told.count(containing: "is stopped") == 1, plan(name, "\(told.lines)"))
        #expect(
            wire.sent == [
                try Wire.encoded(OSCMessage("/size", Float(0.25))), try Wire.encoded(OSCMessage("/hit", 1)),
            ], plan(name, "出たもの \(wire.sent.map(\.count)) バイト"))
        #expect(wire.links.count == 1 && wire.links.first?.port == 7000, plan(name))
    }
}
