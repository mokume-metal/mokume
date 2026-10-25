// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// UDP の受け口の約束を、疑似の受け口・流れ (``FakeNetwork``) と手で進める時計 (``ManualClock``) の上で
/// 確かめる (#3219)。**socket を開かず、実時間を待たない。** 受け入れ・受け・時計の進みの順序は
/// すべて検査が決めるので、同じ予定からは毎回同じ結果になる。
///
/// かつて本物の socket で確かめていた約束 (黙った送り元を閉じる・`/late` の受け渡し・読めない
/// datagram を数える・空の datagram) は、負荷の下の OS の揺れで赤になった (#2910・#2948・#3001・
/// #3160)。揺れていたのは OS の socket の側で、約束の側ではない。ここでは約束だけを見る。本物の
/// socket の検査は、往復・使用中で待って開く・疑似が写している OS の実測 (`UDPPortTests` の
/// `emptyDatagramIsAnEmptyString`・`networkFrameworkCutsDatagramsAt9216`) に絞った。
///
/// 赤の文面は `[network plan=<予定の名>]` で始める (#3207 の K1。生成器は使わないので seed は無い)。
@Suite("疑似の受け口で受ける")
struct DatagramListenerFakeTests {
    /// 疑似の受け口の上の ``DatagramListener`` と、渡したものの記録。
    private struct Harness {
        let network = FakeNetwork()
        let clock = ManualClock(0)
        let listener: DatagramListener
        private let log = Log()

        /// 受け口の手続きが書く記録。待ち行列の上から書かれる。
        private final class Log: Sendable {
            let received = Mutex<[[UInt8]]>([])
            let emptyClosed = Mutex<[String]>([])
        }

        init(idleAfter: TimeInterval) {
            let log = log
            listener = DatagramListener(
                port: network.port, host: "127.0.0.1", retryAfter: 1, idleAfter: idleAfter,
                now: clock.provider,
                received: { bytes, _ in log.received.withLock { $0.append(bytes) } },
                closedByEmpty: { sender in log.emptyClosed.withLock { $0.append(sender) } },
                changed: { _ in }, acceptor: network.acceptor)
            listener.start()
            network.listener.play([.ready(port: network.port)])
        }

        var received: [[UInt8]] { log.received.withLock { $0 } }
        var emptyClosed: [String] { log.emptyClosed.withLock { $0 } }

        /// `index` 番目の送り元を受け入れ、datagram を 1 つ読ませる。
        @discardableResult
        func admitAndHear(_ index: Int) -> FakeFlow {
            let flow = network.flow(index)
            network.listener.offer(flow)
            flow.deliver([UInt8(truncatingIfNeeded: index)])
            return flow
        }
    }

    /// 赤の文面の頭 (K1)。
    private func plan(_ name: String, _ detail: String = "") -> Comment {
        "[network plan=\(name)] \(detail)"
    }

    // MARK: - 黙った送り元 (#2225・#3001・#3160)

    @Test(
        "多くの送り元から一度に届いても 1 つも落とさず、黙った送り元は次の受け入れで閉じる",
        arguments: [DatagramListener.connectionLimit + 6, DatagramListener.connectionLimit - 10])
    func manySendersAreAllHeardThenSwept(sending count: Int) {
        let name = "sweep-\(count)"
        let idleAfter: TimeInterval = 1
        let harness = Harness(idleAfter: idleAfter)
        defer { harness.listener.stop() }

        // 時計は止めたまま。目安 (64) を超えても、黙っていない送り元は閉じない — 閉じると読む前の
        // datagram を捨てる
        var flows = (0..<count).map { harness.admitAndHear($0) }
        #expect(harness.received.count == count, plan(name, "読めたのは \(harness.received.count) 本"))
        #expect(harness.listener.tally == SenderTally(accepted: count, closedIdle: 0, ended: 0), plan(name))
        #expect(harness.listener.connectionCount == count, plan(name))

        // **黙った送り元を閉じるのは、台帳の数が目安に届いているときの、次の受け入れだけ**
        // (`SenderLedger.admit`)。目安に届かない場面は、届くまで足す (時計は止めたまま)
        while harness.listener.connectionCount < DatagramListener.connectionLimit {
            flows.append(harness.admitAndHear(flows.count))
        }
        let full = harness.listener.connectionCount
        #expect(harness.listener.tally.closedIdle == 0, plan(name))

        // ちょうど `idleAfter` 秒黙った後に新しい送り元が来たら、黙っていた送り元を閉じてから受ける
        harness.clock.advance(by: idleAfter)
        let late = harness.admitAndHear(1000)
        harness.network.listener.drain()
        #expect(harness.listener.tally.closedIdle == full, plan(name, "閉じた数 \(harness.listener.tally)"))
        #expect(harness.listener.connectionCount == 1, plan(name))
        #expect(flows.allSatisfy { $0.cancelled }, plan(name, "閉じていない送り元が残った"))
        #expect(!late.cancelled, plan(name, "受け入れたばかりの送り元を閉じた"))
        // 黙りで閉じた送り元の待っていた受けは、空の datagram と同じ形で返る。届いていない空を渡さない
        // (#2324 の直しの反対側。本物の socket で 70 個湧いた)
        #expect(harness.received.count == full + 1, plan(name, "届いていないものを渡した"))
        #expect(harness.received.allSatisfy { !$0.isEmpty }, plan(name))
        #expect(harness.emptyClosed.isEmpty, plan(name))
    }

    @Test("まだ 1 度も読んでいない送り元は、受け入れから何秒経っても閉じない (#2225)")
    func unreadSendersAreNotSwept() {
        let name = "unread"
        let idleAfter: TimeInterval = 1
        let harness = Harness(idleAfter: idleAfter)
        defer { harness.listener.stop() }

        // 受け入れたが、まだ読んでいない (待ち行列が混んで最初に読むまでに時間が掛かった形)
        let count = DatagramListener.connectionLimit + 6
        let flows = (0..<count).map { index in
            let flow = harness.network.flow(index)
            harness.network.listener.offer(flow)
            return flow
        }
        harness.clock.advance(by: idleAfter * 10)
        harness.admitAndHear(1000)
        #expect(harness.listener.tally.closedIdle == 0, plan(name, "読む前の送り元を閉じた"))
        #expect(harness.listener.connectionCount == count + 1, plan(name))

        // 読んだ後に黙れば、次の受け入れで閉じる
        for (index, flow) in flows.enumerated() { flow.deliver([UInt8(truncatingIfNeeded: index)]) }
        harness.clock.advance(by: idleAfter)
        harness.admitAndHear(1001)
        #expect(harness.listener.tally.closedIdle == count + 1, plan(name, "\(harness.listener.tally)"))
        #expect(harness.listener.connectionCount == 1, plan(name))
    }

    @Test("/late が既存の繋ぎで渡された回は受け入れが起きず何も閉じない。次の受け入れで、黙った送り元を閉じる (#2948)")
    func lateOnAnExistingFlowDoesNotSweepUntilTheNextAdmission() {
        let name = "late-on-existing-flow"
        let idleAfter: TimeInterval = 1
        let harness = Harness(idleAfter: idleAfter)
        defer { harness.listener.stop() }
        let count = DatagramListener.connectionLimit + 6
        let flows = (0..<count).map { harness.admitAndHear($0) }
        harness.clock.advance(by: idleAfter)

        // 最初の `/late` は、Network.framework が既存の繋ぎ (0 番の送り元) で渡す (#2225 で実測した形)。
        // 受け入れは起きないので、黙った送り元を閉じる契機は来ない
        #expect(flows[0].deliver(Array("/late".utf8)), plan(name, "0 番の送り元が受けを待っていない"))
        #expect(harness.listener.tally.accepted == count, plan(name, "受け入れが起きた"))
        #expect(harness.listener.tally.closedIdle == 0, plan(name, "受け入れが起きない回に閉じた"))
        #expect(harness.listener.connectionCount == count, plan(name))
        #expect(harness.received.last == Array("/late".utf8), plan(name, "/late を渡していない"))

        // 既存の繋ぎで読んだ送り元は「いま読んだ」ので黙っていない。この時刻に受け入れが起きれば、
        // その送り元だけが残る
        harness.admitAndHear(1000)
        #expect(harness.listener.tally.closedIdle == count - 1, plan(name, "\(harness.listener.tally)"))
        #expect(harness.listener.connectionCount == 2, plan(name))
        #expect(!flows[0].cancelled, plan(name, "いま読んだ送り元を閉じた"))

        // 閉じるのは台帳が目安に届いているときだけ。残った 2 本が黙っても、目安より少なければ閉じない
        harness.clock.advance(by: idleAfter)
        harness.admitAndHear(1001)
        #expect(harness.listener.tally.closedIdle == count - 1, plan(name, "\(harness.listener.tally)"))
        #expect(harness.listener.connectionCount == 3, plan(name))
    }

    @Test("受け口が失敗して閉じたら、送り元を台帳から外して閉じ、待っていた受けを空のメッセージにしない")
    func closedListenerDropsItsSenders() {
        let name = "listener-failed"
        let harness = Harness(idleAfter: 1)
        defer { harness.listener.stop() }
        let first = harness.network.flow(0)
        harness.network.listener.offer(first)
        first.deliver(Array("a".utf8))
        #expect(harness.listener.connectionCount == 1, plan(name))

        // 受け口が失敗して閉じる (本物では `EADDRINUSE` などで `failed`)。閉じた繋ぎの待っていた受けは、
        // 空の datagram と同じ形で返る
        harness.network.listener.play([.failed("Network is down")])
        harness.network.listener.drain()
        #expect(harness.listener.connectionCount == 0, plan(name))
        #expect(first.cancelled, plan(name))
        #expect(harness.received == [Array("a".utf8)], plan(name, "閉じた繋ぎの受けを渡した"))

        // 開き直した受け口は、同じ送り元を新しい繋ぎで受け直す。外した数は ended に入れない
        harness.network.listener.play([.ready(port: harness.network.port)])
        let again = harness.network.flow(0)
        harness.network.listener.offer(again)
        again.deliver(Array("b".utf8))
        #expect(harness.received == [Array("a".utf8), Array("b".utf8)], plan(name))
        #expect(harness.listener.tally == SenderTally(accepted: 2, closedIdle: 0, ended: 0), plan(name))
        // こちらが閉じた繋ぎなので、空の直後の落ちを名乗らない (#2363)
        #expect(harness.emptyClosed.isEmpty, plan(name))
    }

    // MARK: - 読み方 (UDP の文字列・OSC)

    /// 疑似の受け口で受ける UDP の入り口。開いて、受け始めた後で返す。
    private func udpPort(_ network: FakeNetwork, told: Told) throws -> (UDPPort, DatagramSource<String>) {
        let source = DatagramSource<String>.text(
            port: network.port, host: "127.0.0.1", retryAfter: 1, acceptor: network.acceptor, warn: told.append)
        let udp = UDPPort(
            port: network.port, name: "udp :\(network.port)", source: source, outbound: RecordingSender(),
            owner: nil, warn: told.append)
        try udp.open()
        network.listener.play([.ready(port: network.port)])
        return (udp, source)
    }

    /// 疑似の受け口で受ける OSC の入り口。開いて、受け始めた後で返す。
    private func oscPort(_ network: FakeNetwork, told: Told) throws -> (OSCPort, NetworkOSCSource) {
        let source = NetworkOSCSource(
            port: network.port, host: "127.0.0.1", retryAfter: 1, acceptor: network.acceptor, warn: told.append)
        let osc = OSCPort(
            port: network.port, name: "osc :\(network.port)", source: source, outbound: RecordingSender(),
            owner: nil, warn: told.append)
        try osc.open()
        network.listener.play([.ready(port: network.port)])
        return (osc, source)
    }

    /// macOS の受け口が渡す長さ (9216 バイトを超えるものは先頭 9216 バイトに黙って切る — #2325)。
    /// 切り方そのものは `UDPPortTests` の `networkFrameworkCutsDatagramsAt9216` が本物で見張る。
    private func asDelivered(_ bytes: [UInt8]) -> [UInt8] { Array(bytes.prefix(Datagram.sizeLimit)) }

    @Test("UTF-8 として読めない datagram は捨てて数え、前後の datagram は届く")
    func unreadableTextIsDiscardedAndCounted() throws {
        let told = Told()
        let network = FakeNetwork()
        let (udp, _) = try udpPort(network, told: told)
        defer { udp.close() }
        let flow = network.flow(0)
        network.listener.offer(flow)
        for bytes in [Array("before".utf8), [0x68, 0xFF, 0xFE, 0x0A], Array("after".utf8)] {
            #expect(flow.deliver(bytes))
        }
        udp.supply()
        #expect(udp.messages == ["before", "after"], plan("udp-unreadable"))
        #expect(udp.input.unreadable == 1, plan("udp-unreadable"))
    }

    @Test("9216 バイト以上の datagram は切れた疑いがあるので丸ごと捨てて数え、9215 バイトまでは全長で届く")
    func oversizedTextIsDiscardedAndCounted() throws {
        let told = Told()
        let network = FakeNetwork()
        let (udp, _) = try udpPort(network, told: told)
        defer { udp.close() }
        let flow = network.flow(0)
        network.listener.offer(flow)
        for size in [1000, 9215, 9216, 9217, 20000, 65507] {
            flow.deliver(asDelivered([UInt8](repeating: 0x61, count: size)))
        }
        flow.deliver(Array("after".utf8))
        udp.supply()
        #expect(udp.messages.map(\.utf8.count) == [1000, 9215, 5], plan("udp-oversized"))
        #expect(udp.input.unreadable == 4, plan("udp-oversized"))
        #expect(told.lines.isEmpty, plan("udp-oversized", "\(told.lines)"))
    }

    @Test("空の datagram は、流れの終わりを名乗っても空の文字列として届き、その流れを閉じて、後から届いたものは新しい流れで受ける (#2324)")
    func emptyDatagramIsAnEmptyStringAndClosesTheFlow() throws {
        let told = Told()
        let network = FakeNetwork()
        let (udp, source) = try udpPort(network, told: told)
        defer { udp.close() }
        let flow = network.flow(0)
        network.listener.offer(flow)
        flow.deliver(Array("a".utf8))
        // 流れができて受けを待っているところへ届いた空を、Network.framework は流れの終わりと名乗って渡す
        flow.deliver(nil, isFinal: true)
        network.listener.drain()
        #expect(flow.cancelled, plan("udp-empty", "終わりを名乗った空の後、流れを閉じなかった"))
        #expect(source.tally.ended == 1, plan("udp-empty"))
        // 終わりを名乗らない空 (流れの最初に届いた空) は、渡して流れを続ける
        let next = network.flow(0)
        network.listener.offer(next)
        next.deliver(nil)
        for text in ["b", "c"] { next.deliver(Array(text.utf8)) }
        udp.supply()
        #expect(udp.messages == ["a", "", "", "b", "c"], plan("udp-empty"))
        #expect(!next.cancelled, plan("udp-empty", "終わりを名乗らない空で流れを閉じた"))
        #expect(udp.input.unreadable == 0, plan("udp-empty"))
        #expect(told.lines.count == 1, plan("udp-empty", "\(told.lines)"))
        #expect(told.lines.first?.contains("empty datagram") == true, plan("udp-empty"))
    }

    @Test("空で流れが閉じたら、落ちたかもしれないことを受け口と送り元つきで、送り元ごとに 1 度だけ診断に出す (#2363)")
    func emptyClosedFlowIsToldOncePerSender() throws {
        let told = Told()
        let network = FakeNetwork()
        let (udp, _) = try udpPort(network, told: told)
        defer { udp.close() }
        /// 1 つの送り元から、流れができてから空を送って閉じる 1 周。閉じた流れの後は新しい流れで受ける。
        func cycle(_ index: Int, sender: Int) {
            let flow = network.flow(sender)
            network.listener.offer(flow)
            flow.deliver(Array("x\(index)".utf8))
            flow.deliver(nil, isFinal: true)
            network.listener.drain()
        }
        for index in 0..<3 { cycle(index, sender: 0) }
        #expect(told.lines.count == 1, plan("udp-empty-closed", "\(told.lines)"))
        let first = try #require(told.lines.first)
        #expect(first.hasPrefix("udp :\(network.port): an empty datagram from 127.0.0.1:50000 closed its flow"))
        #expect(first.contains("may have been dropped"))

        // 別の送り元は、その送り元について 1 度。もとの送り元はもう言わない
        cycle(0, sender: 1)
        #expect(told.lines.count == 2, plan("udp-empty-closed", "\(told.lines)"))
        #expect(told.lines.last?.contains("127.0.0.1:50001") == true)
        cycle(9, sender: 0)
        #expect(told.lines.count == 2, plan("udp-empty-closed", "\(told.lines)"))
        udp.supply()
        #expect(udp.messages == ["x0", "", "x1", "", "x2", "", "x0", "", "x9", ""], plan("udp-empty-closed"))
        #expect(udp.input.unreadable == 0)
    }

    @Test("OSC: 読めない部分を含むパケットはそこから後ろを捨てて数え、9216 バイト以上は丸ごと捨てて数える。前と次のパケットは届く")
    func unreadableAndOversizedPacketsAreCounted() throws {
        let told = Told()
        let network = FakeNetwork()
        let (osc, _) = try oscPort(network, told: told)
        defer { osc.close() }
        let flow = network.flow(0)
        network.listener.offer(flow)

        let before = OSCMessage("/before", 1)
        let after = OSCMessage("/after", 2)
        let next = OSCMessage("/next", 3)
        flow.deliver(
            Wire.bundle([
                try Wire.encoded(before), Wire.string("/bad") + Wire.string(",q"), try Wire.encoded(after),
            ]))
        // 12000 バイトの blob を 1 つ持つメッセージ (12012 バイト) と、頭に小さなメッセージを置いた束。
        // 先頭 9216 バイトに切れたものを読むと、頭だけが読めてしまう
        let blob = try Wire.encoded(OSCMessage("/b", arguments: [.blob([UInt8](repeating: 7, count: 12000))]))
        #expect(blob.count == 12012)
        let bundle = Wire.bundle([try Wire.encoded(OSCMessage("/head", 1)), blob])
        for packet in [blob, bundle, try Wire.encoded(next)] { flow.deliver(asDelivered(packet)) }
        osc.supply()
        #expect(osc.messages == [before, next], plan("osc-unreadable"))
        #expect(osc.input.unreadable == 3, plan("osc-unreadable"))
        #expect(told.lines.isEmpty, plan("osc-unreadable", "\(told.lines)"))
    }

    @Test("OSC: 空の datagram は読めないものとして数え、空で流れが閉じたら送り元ごとに 1 度だけ診断に出し、後から届いたメッセージも受ける (#2324・#2363)")
    func emptyDatagramIsCountedAndToldOnceForOSC() throws {
        let told = Told()
        let network = FakeNetwork()
        let (osc, source) = try oscPort(network, told: told)
        defer { osc.close() }
        let message = OSCMessage("/m", arguments: [])
        let packet = try Wire.encoded(message)
        for index in 0..<3 {
            let flow = network.flow(0)
            network.listener.offer(flow)
            flow.deliver(packet)
            flow.deliver(nil, isFinal: true)
            network.listener.drain()
            #expect(source.tally.ended == index + 1, plan("osc-empty"))
        }
        let last = network.flow(0)
        network.listener.offer(last)
        for _ in 0..<5 { last.deliver(packet) }
        osc.supply()
        #expect(osc.messages == Array(repeating: message, count: 8), plan("osc-empty"))
        #expect(osc.input.unreadable == 3, plan("osc-empty"))
        #expect(told.count(containing: "empty datagram") == 1, plan("osc-empty", "\(told.lines)"))
        let line = try #require(told.lines.first { $0.contains("empty datagram") })
        #expect(line.hasPrefix("osc :\(network.port): an empty datagram from 127.0.0.1:50000 closed its flow"))
    }

    // MARK: - 故障の予定と名乗り (#3045・#3160)

    /// 受け口の開く試みの予定。どの予定も、同じ予定からは同じ状態の列と知らせの列になる。
    struct ListenerPlan: CustomTestStringConvertible, Sendable {
        let name: String
        let attempts: [PortListener.Event]
        /// 試みごとの、入り口の状態。
        let states: [SourceState]
        /// 知らせの行が含む言葉 (順に)。
        let told: [String]

        var testDescription: String { name }
    }

    @Test(
        "受け口の開く試みが予定どおりに失敗しても、状態はそのとおりに移り、知らせは理由ごとに 1 度だけ",
        arguments: [
            ListenerPlan(
                name: "in-use-3-then-ready",
                attempts: [.portInUse, .portInUse, .portInUse, .ready(port: 9000)],
                states: [.unavailable, .unavailable, .unavailable, .running],
                told: ["because another app is using it"]),
            ListenerPlan(
                name: "ready-failed-ready-in-use",
                attempts: [.ready(port: 9000), .failed("Network is down"), .ready(port: 9000), .portInUse],
                states: [.running, .disconnected, .running, .unavailable],
                told: ["(Network is down)", "because another app is using it"]),
            ListenerPlan(
                name: "denied-twice",
                attempts: [.denied, .denied],
                states: [.denied, .denied],
                told: ["blocked by macOS (Local Network)"]),
        ])
    func listenerFaultsAreToldPerPlan(_ listenerPlan: ListenerPlan) throws {
        func play() throws -> (states: [SourceState], told: [String]) {
            let told = Told()
            let network = FakeNetwork()
            let source = NetworkOSCSource(
                port: network.port, host: "127.0.0.1", retryAfter: 1, acceptor: network.acceptor,
                warn: told.append)
            let osc = OSCPort(
                port: network.port, name: "osc :\(network.port)", source: source, outbound: RecordingSender(),
                owner: nil, warn: told.append)
            try osc.open()
            defer { osc.close() }
            var states: [SourceState] = []
            for attempt in listenerPlan.attempts {
                network.listener.play([attempt])
                states.append(osc.state)
            }
            // 受けられる状態で終わる予定なら、受け始めている
            if osc.state == .running {
                let flow = network.flow(0)
                network.listener.offer(flow)
                flow.deliver(try Wire.encoded(OSCMessage("/back", 1)))
                osc.supply()
                #expect(osc.messages == [OSCMessage("/back", 1)], plan(listenerPlan.name))
            }
            return (states, told.lines)
        }
        let first = try play()
        #expect(first.states == listenerPlan.states, plan(listenerPlan.name, "状態の列 \(first.states)"))
        #expect(first.told.count == listenerPlan.told.count, plan(listenerPlan.name, "知らせ \(first.told)"))
        for (line, word) in zip(first.told, listenerPlan.told) {
            #expect(line.contains(word), plan(listenerPlan.name, "「\(word)」が無い: \(line)"))
        }
        let again = try play()
        #expect(again.states == first.states && again.told == first.told, plan(listenerPlan.name, "同じ予定で違う結果"))
    }

    /// 送り手の予定と、区切りごとの名乗りの行の数。
    struct SenderCase: CustomTestStringConvertible, Sendable {
        let plan: SendPlan
        let linesAtMark: [String: Int]

        var testDescription: String { plan.name }
    }

    @Test(
        "送り手は、同じ故障の予定から同じ名乗りを出す: 受け手の居ない間は 1 行・開いた直後の残りの拒否は戻る前なら名乗らない (#3045)",
        arguments: [
            // 受け手が居ない間の拒否 (次の送信の失敗として返る)・開いた直後に残りの拒否が 1 つ・時計を
            // 進めて戻る・受け手が閉じてまた拒否。時計は戻すときにだけ進める (本物の socket の検査
            // `receiverComingAndGoing` が手で進める時計で作っていた形)
            SenderCase(
                plan: SendPlan(
                    name: "refused-then-open-with-a-leftover",
                    steps: [
                        .send(nil), .send(SendPlan.refused), .send(nil), .send(SendPlan.refused),
                        .send(nil), .send(SendPlan.refused), .mark("1 居ない間"),
                        .send(SendPlan.refused), .send(nil), .send(nil), .send(nil), .mark("2 開いた後"),
                        .wait(0.3), .send(nil), .wait(0.3), .send(nil), .mark("3 戻した後"),
                        .send(nil), .send(SendPlan.refused), .send(nil), .send(SendPlan.refused),
                        .mark("4 閉じた後"),
                    ]),
                linesAtMark: ["1 居ない間": 1, "2 開いた後": 1, "3 戻した後": 1, "4 閉じた後": 2]),
            // #3045 の見立て: 居ない間の最後の送信が誤り無く終わり、開くまでが `confirmAfter` (0.1 秒) を
            // 越える。開いた後の最初の送信で戻り、遅れて返った残りの拒否で 2 行目を名乗る (設計どおり)
            SenderCase(
                plan: SendPlan(
                    name: "leftover-after-confirmAfter",
                    steps: [
                        .send(nil), .send(SendPlan.refused), .send(nil), .mark("1 居ない間"),
                        .wait(0.2), .send(nil), .send(SendPlan.refused), .mark("2 開いた後"),
                    ]),
                linesAtMark: ["1 居ない間": 1, "2 開いた後": 2]),
            // 待っている繋ぎ (`waiting`) は 1 度だけ名乗り、誤り無しの 1 度で戻る
            SenderCase(
                plan: SendPlan(
                    name: "waiting-in-use-then-sent",
                    steps: [
                        .state(.preparing), .state(.waiting(.posix(.EADDRINUSE))),
                        .state(.waiting(.posix(.EADDRINUSE))), .mark("1 待ち"),
                        .state(.ready), .send(nil), .state(.waiting(.posix(.EADDRINUSE))), .mark("2 戻って待ち"),
                    ]),
                linesAtMark: ["1 待ち": 1, "2 戻って待ち": 2]),
        ])
    func senderFaultsAreToldPerPlan(_ senderCase: SenderCase) {
        let name = senderCase.plan.name
        let first = senderCase.plan.run()
        #expect(first.linesAtMark == senderCase.linesAtMark, plan(name, "\(first)"))
        #expect(first.lines.allSatisfy { $0.hasPrefix("Could not send to 127.0.0.1:7000 (") }, plan(name, "\(first)"))
        let again = senderCase.plan.run()
        #expect(again == first, plan(name, "同じ予定で違う名乗り: \(again)"))
    }

    @Test("送り元 70 本のうち予定した番号だけが waiting(Address already in use) なら、その番号の送り手だけが 1 行ずつ名乗る (#3160 の形)")
    func waitingSendersAreToldOneLineEach() {
        let name = "waiting-in-use-2...69"
        let waiting = Set(2..<70)
        func play() -> [[String]] {
            (0..<70).map { index in
                // 待っている繋ぎの送信は完了が返らない (本物では黙って積まれる) ので、予定に送信を置かない
                let steps: [SendPlan.Step] =
                    waiting.contains(index)
                    ? [.state(.preparing), .state(.waiting(.posix(.EADDRINUSE)))]
                    : [.state(.preparing), .state(.ready), .send(nil)]
                return SendPlan(name: "\(name)#\(index)", steps: steps).run().lines
            }
        }
        let first = play()
        let told = first.enumerated().filter { !$0.element.isEmpty }.map(\.offset)
        #expect(Set(told) == waiting, plan(name, "名乗った番号 \(rangesText(told))"))
        #expect(first.allSatisfy { $0.count <= 1 }, plan(name, "1 本で 2 行以上"))
        #expect(
            first.joined().allSatisfy { $0.contains("(Address already in use)") && $0.contains("keeps waiting") },
            plan(name, "\(first.joined().prefix(1))"))
        #expect(play() == first, plan(name, "同じ予定で違う名乗り"))
    }
}
