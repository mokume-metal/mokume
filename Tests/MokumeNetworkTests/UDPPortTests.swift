// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// UDP で文字列を受けて送る入り口 (#2018)。GPU は要らない。通信は 127.0.0.1 だけで行い、
/// ポートは OS が選ぶ (0 を頼む)。
///
/// 入り口を走っているスケッチに足さず、フレームの代わりに ``TextPort/supply()`` を自分で呼ぶ。
@Suite("UDP の入り口", .serialized)
struct UDPPortTests {
    /// 127.0.0.1 の `port` (既定は OS が選ぶ) で受ける入り口を開き、受け始めるまで待つ。
    private func listening(
        told: Told, port: Int = 0, outbound: (any DatagramSending)? = nil
    ) async throws -> (udp: UDPPort, port: Int) {
        let source = DatagramSource<String>.text(
            port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let udp = UDPPort(
            port: port, name: "udp :\(port)", source: source, outbound: outbound, owner: nil,
            warn: told.append)
        try udp.open()
        try await requireState(told: told, tracing: source) { udp.state }
        return (udp, try #require(source.boundPort))
    }

    /// 疑似の受け口で受ける入り口。開いて、受け始めた後で返す。列の送りの補助の検査が、本物のポートを開かずに
    /// 使う (#3231)。
    private func fakeListening(_ network: FakeNetwork, told: Told) throws -> UDPPort {
        let source = DatagramSource<String>.text(
            port: network.port, host: "127.0.0.1", retryAfter: 1, acceptor: network.acceptor, warn: told.append)
        let udp = UDPPort(
            port: network.port, name: "udp :\(network.port)", source: source, outbound: nil, owner: nil,
            warn: told.append)
        try udp.open()
        network.listener.play([.ready(port: network.port)])
        return udp
    }

    /// 列の送りで、前提 (送った列が全部読まれる) が満たされなかった回の名乗り (#3001)。受け口の様子と、
    /// 素の socket から 1 通送って読まれるかを添えて、1 つで止まる。名乗りの中身は
    /// ``requireSent(_:_:log:landing:)``。
    private func requireReceived(
        _ received: [String], expecting count: Int, log: SendLog, udp: UDPPort, port: Int, told: Told,
        _ note: String = ""
    ) async throws {
        try await requireSent(
            received.count >= count, "\(count) 通のうち読めたのは \(received.count) 通\(note)", log: log,
            landing: landing(of: udp, port: port, told: told))
    }

    /// 素の socket から送った通が `count` 通読まれるのを待つ。読まれなければ、受け口の様子と素の 1 通の前後の
    /// 受け入れの差を名乗って 1 つで止まる (#3105)。名乗りの中身は ``collectOrName(_:count:within:landing:_:)``。
    private func heard(
        _ udp: UDPPort, count: Int, port: Int, told: Told, from peer: RawDatagramSocket, _ note: String = ""
    ) async throws -> [String] {
        try await collectOrName(
            udp, count: count, from: peer, landing: landing(of: udp, port: port, told: told), note)
    }

    // MARK: - 受ける

    @Test("相手から届いた文字列を届いた順に受け、末尾の改行 1 つを落とす")
    func receivesTextInOrder() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }

        // nc で打った行・CRLF で終わる行・前後の空白・改行 2 つ (落とすのは 1 つだけ)。
        // 送り元が送れないと名乗ったら、まだ 1 通も読まれていない限り新しい送り元で送り直す (#2940)
        let texts = ["0.25\n", "hit\r\n", "  spaced  ", "two\n\n"]
        let log = SendLog()
        let received = try await sendAndCollect(
            texts.map { Array($0.utf8) }, expecting: 4, to: udp, senders: &senders, log: log
        ) { warn in DatagramSender(host: "127.0.0.1", port: port, warn: warn) }
        try await requireReceived(received, expecting: 4, log: log, udp: udp, port: port, told: told)
        #expect(received == ["0.25", "hit", "  spaced  ", "two\n"])
        #expect(udp.lastArrival != nil)
        #expect(udp.report == SourceReport(name: "udp :0", state: .running, lastArrival: udp.lastArrival))
        #expect(told.lines.isEmpty)

        udp.close()
        #expect(udp.state == .stopped)
        #expect(udp.messages.isEmpty)
    }

    @Test("空の datagram は、Network.framework が送り元の流れの終わりと名乗っても空の文字列として届き、後から届いたものも受ける")
    func emptyDatagramIsAnEmptyString() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        let source = try #require(udp.source as? DatagramSource<String>)
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        // 送り元の流れができて受けを待っているところへ空を送る。この形の空の datagram を、
        // Network.framework は毎回、流れの終わり (`isFinal`) と名乗って渡す (macOS 27.0.1 で実測)
        #expect(peer.send(Array("a".utf8), to: port) == 1)
        var received = try await heard(udp, count: 1, port: port, told: told, from: peer, "(a)")
        #expect(peer.send([], to: port) == 0)
        received += try await heard(udp, count: 1, port: port, told: told, from: peer, "(空)")
        #expect(received == ["a", ""])

        // 終わりを名乗った空を渡したら、その流れを閉じる。閉じた後に届いたものは、新しい流れで受ける
        try await requireWait(
            "終わりを名乗った空の後、流れが閉じなかった", detail: { "ended: \(source.tally.ended)" },
            until: { source.tally.ended >= 1 })
        for text in ["b", "c"] {
            #expect(peer.send(Array(text.utf8), to: port) == 1)
        }
        received += try await heard(udp, count: 2, port: port, told: told, from: peer, "(b・c)")
        #expect(received == ["a", "", "b", "c"])
        #expect(udp.input.unreadable == 0)
        // 空で流れが閉じたことだけを、1 度言う (#2363)。ほかは何も言わない
        #expect(told.lines.count == 1)
        #expect(told.lines.first?.contains("empty datagram") == true)
    }

    @Test("受けの完了の扱い: 中身は台帳に依らず渡し、中身の無いものは台帳に居る繋ぎでだけ空として渡し、終わりを名乗れば閉じる")
    func completionIsHandledByContentFinalityAndLedger() {
        typealias Listener = DatagramListener
        // 中身のある datagram: isFinal に依らず渡して続ける。台帳から外した後に返っても、
        // 届いた datagram なので渡す
        #expect(Listener.completion(content: Data([7]), isFinal: false, failed: false, held: true) == .datagram([7]))
        #expect(Listener.completion(content: Data([7]), isFinal: true, failed: false, held: true) == .datagram([7]))
        #expect(Listener.completion(content: Data([7]), isFinal: false, failed: false, held: false) == .datagram([7]))
        // 空の datagram: 終わりを名乗らなければ続け、名乗れば渡してから閉じる
        // (閉じた流れが空を返し続けても、次の受けの error を待たずに止まる)
        #expect(Listener.completion(content: nil, isFinal: false, failed: false, held: true) == .datagram([]))
        #expect(Listener.completion(content: nil, isFinal: true, failed: false, held: true) == .last([]))
        // こちらが閉じた繋ぎ (台帳に居ない) の中身の無い受けは、届いていないので渡さない
        #expect(Listener.completion(content: nil, isFinal: true, failed: false, held: false) == .abandoned)
        #expect(Listener.completion(content: nil, isFinal: false, failed: false, held: false) == .abandoned)
        // 失敗は終わり
        #expect(Listener.completion(content: nil, isFinal: false, failed: true, held: true) == .ended)
        #expect(Listener.completion(content: Data([7]), isFinal: false, failed: true, held: true) == .ended)
    }

    @Test("空を渡して流れを閉じる扱いだけが名乗る。終わりを名乗らない空・こちらが閉じた繋ぎ・失敗は名乗らない (#2363)")
    func onlyTheEmptyThatClosesTheFlowAnnounces() {
        typealias Listener = DatagramListener
        func announces(_ content: Data?, final: Bool, failed: Bool = false, held: Bool = true) -> Bool {
            Listener.completion(content: content, isFinal: final, failed: failed, held: held).closesFlowOnEmpty
        }
        #expect(announces(nil, final: true))
        #expect(!announces(nil, final: false))  // 流れの最初に届き、流れが閉じない空
        #expect(!announces(nil, final: true, held: false))  // 黙りで閉じた・受け口が失敗した繋ぎ
        #expect(!announces(nil, final: false, held: false))
        #expect(!announces(nil, final: true, failed: true))  // 空を含まない流れの終わり
        #expect(!announces(Data([7]), final: true))  // 中身のある datagram は、終わりを名乗っても続ける
        #expect(!announces(Data([7]), final: false))
    }

    @Test("名乗った送り元の覚えは、同じ送り元に 2 度言わず、上限を超えたら先に覚えた送り元から忘れる (#2363)")
    func toldSendersAreRememberedUpToTheLimit() {
        var memory = EmptyClosedSenders(limit: 3)
        func insert(_ sender: String) -> Bool { memory.insert(sender) }
        #expect(insert("a"))
        #expect(!insert("a"))
        #expect(insert("b"))
        #expect(insert("c"))
        #expect(memory.count == 3)
        // 4 つ目で、先に覚えた a を忘れる。b・c は覚えたまま
        #expect(insert("d"))
        #expect(memory.count == 3)
        #expect(!insert("b"))
        #expect(!insert("c"))
        #expect(insert("a"), "忘れた送り元がまた閉じたら、もう 1 度言う")
        #expect(memory.count == 3)
        // 本番の上限も有限である
        #expect(DatagramListener.emptyClosedLimit == 256)
        var many = EmptyClosedSenders(limit: DatagramListener.emptyClosedLimit)
        for index in 0..<10_000 { _ = many.insert("s\(index)") }
        #expect(many.count == DatagramListener.emptyClosedLimit)
    }

    @Test("前提: macOS の受け口は、ループバックで届いた 9216 バイトを超える datagram を、先頭 9216 バイトに切って渡す")
    func networkFrameworkCutsDatagramsAt9216() async throws {
        // 上限 (Datagram.isReceivable) の見張りを通る前の、受け口が渡す生のバイト列の長さを見る。
        // 見張りはちょうど 9216 バイトだけを捨てるので、疑似の受け口の検査は OS の振る舞いが
        // 変わっても緑のままになる。この検査はその前提 (ループバックで切れる長さ) だけを見張る。
        // 別の機械から届く経路は全長で届く (#2531・#3594) が、1 台では確かめられない (#2325)
        let lengths = Mutex<[Int]>([])
        let bound = Mutex<Int?>(nil)
        let events = Mutex<[String]>([])
        let listener = DatagramListener(
            port: 0, host: "127.0.0.1", retryAfter: 0.05,
            received: { bytes, _ in lengths.withLock { $0.append(bytes.count) } },
            changed: { event in
                events.withLock { $0.append("\(event)") }
                if case .ready(let port) = event { bound.withLock { $0 = port } }
            })
        listener.start()
        defer { listener.stop() }
        try await requireWait(
            "受け口が ready にならなかった", detail: { "受けた移り変わり: \(events.withLock { $0 })" },
            until: { bound.withLock { $0 } != nil })
        let port = try #require(bound.withLock { $0 })
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        for size in [9215, 9216, 20000] {
            #expect(peer.send([UInt8](repeating: 0x61, count: size), to: port) == size)
        }
        // 素の 1 通 (`probe` の 5 バイト) は、先に届いた 3 通とは長さで見分ける
        try await requireRawArrival(
            "受け口が 3 通を渡さなかった (渡された長さ: \(lengths.withLock { $0 }))", from: peer,
            landing: landing(
                of: listener, port: port, events: { events.withLock { $0 } },
                probeArrived: { lengths.withLock { $0.contains(5) } })
        ) { lengths.withLock { $0.count } >= 3 }
        #expect(
            lengths.withLock { $0 } == [9215, 9216, 9216],
            "Network.framework の切り方が変わった。#2325・#3594 の受けの上限 (Datagram.isReceivable) の前提を見直す")
    }

    // MARK: - 送る

    @Test("send は作るときに決めた宛先へ、1 つの datagram として届く")
    func sendReachesTheDestination() async throws {
        let told = Told()
        let (receiver, port) = try await listening(told: told)
        defer { receiver.close() }
        let sender = UDPPort(
            port: 1, name: "udp :1", source: RecordedSource<String>(batches: []),
            outbound: DatagramSender(host: "127.0.0.1", port: port, warn: told.append),
            owner: nil, warn: told.append)
        defer { sender.close() }
        let log = SendLog()
        log.watch { sender.sendTrace }

        sender.send("hit")
        sender.send("size 0.5")
        let received = await collect(receiver, count: 2, log: log)
        try await requireReceived(
            received, expecting: 2, log: log, udp: receiver, port: port, told: told)
        #expect(received == ["hit", "size 0.5"])
        #expect(told.lines.isEmpty)
    }

    @Test("空の文字列の send は 0 バイトの datagram になり、mokume の受け口に空の文字列として届く")
    func emptySendArrivesAsAnEmptyString() async throws {
        let told = Told()
        let (receiver, port) = try await listening(told: told)
        defer { receiver.close() }
        let source = try #require(receiver.source as? DatagramSource<String>)
        let sender = UDPPort(
            port: 1, name: "udp :1", source: RecordedSource<String>(batches: []),
            outbound: DatagramSender(host: "127.0.0.1", port: port, warn: told.append),
            owner: nil, warn: told.append)
        defer { sender.close() }
        let log = SendLog()
        log.watch { sender.sendTrace }

        // 流れができてから空を送る (受け口の流れが終わりを名乗る形)
        sender.send("x")
        var received = await collect(receiver, count: 1, log: log)
        sender.send("")
        received += await collect(receiver, count: 1, log: log)
        try await requireWait(
            "受け口が流れの終わりを数えなかった", detail: { "終わりの数: \(source.tally.ended)" }
        ) {
            source.tally.ended >= 1
        }
        sender.send("y")
        received += await collect(receiver, count: 1, log: log)
        try await requireReceived(
            received, expecting: 3, log: log, udp: receiver, port: port, told: told, " (空の文字列も 1 通に数える)")
        #expect(received == ["x", "", "y"])
        // 受け手の流れが閉じたことだけを、1 度言う (#2363)。送り手は何も言わない
        #expect(told.lines.count == 1)
        #expect(told.lines.first?.contains("empty datagram") == true)
    }

    @Test("外して足し直した (close の後に open が来る) UDP の入り口は、また送れる。外し直せばまた 1 度だけ知らせて送らない (#3122)")
    func reopenedPortSendsAgain() throws {
        let told = Told()
        let recording = RecordingSender()
        let udp = UDPPort(
            port: 6000, name: "udp :6000", source: RecordedSource<String>(batches: [["a"]]),
            outbound: recording, owner: nil, warn: told.append)
        try udp.open()
        udp.send("before")
        udp.supply()
        #expect(udp.messages == ["a"])

        udp.close()
        #expect(udp.state == .stopped)
        udp.send("while closed 1")
        udp.send("while closed 2")
        #expect(recording.sent == [Array("before".utf8)])
        #expect(told.count(containing: "is stopped") == 1)

        try udp.open()
        #expect(udp.state == .running)
        udp.send("after")
        udp.supply()
        #expect(udp.messages == ["a"])
        #expect(recording.sent == [Array("before".utf8), Array("after".utf8)])

        udp.close()
        udp.send("again")
        #expect(recording.sent.count == 2)
        #expect(told.count(containing: "is stopped") == 2)
    }

    @Test("外して足し直した UDP の入り口は、外す前に溜まっていた文字列を出さない (#3122)")
    func reopenedPortDoesNotDeliverWhatWaitedBeforeClose() throws {
        let udp = UDPPort(
            port: 6000, name: "udp :6000", source: RecordedSource<String>(batches: [[]]),
            outbound: nil, owner: nil)
        try udp.open()
        udp.input.send("stale")
        udp.close()

        try udp.open()
        udp.supply()
        #expect(udp.messages.isEmpty, "外す前に溜まっていた分は、足し直した最初のフレームに出ない")

        udp.input.send("fresh")
        udp.supply()
        #expect(udp.messages == ["fresh"])
    }

    @Test("実行に足されていない (外で呼んだ) stop() は何も止めず、利用者が止めた印も立てない。外して足し直せば戻る (#3122)")
    func stopWithoutARunDoesNotStick() throws {
        let recording = RecordingSender()
        let udp = UDPPort(
            port: 6000, name: "udp :6000", source: RecordedSource<String>(batches: [["a"]]),
            outbound: recording, owner: nil)
        try udp.open()
        udp.stop()
        #expect(udp.state == .running, "外で呼んだ stop() は何も止めない")

        udp.close()
        try udp.open()
        udp.supply()
        udp.send("back")
        #expect(udp.state == .running)
        #expect(udp.messages == ["a"])
        #expect(recording.sent == [Array("back".utf8)])
    }

    @Test("UTF-8 で 9216 バイト以上の文字列は送り手に渡さず、大きさと上限を 1 度だけ知らせる")
    func oversizedSendIsRefusedOnce() throws {
        let told = Told()
        // 送り手に渡らなければ、送れなかったことを「受け手が居ない」見当で名乗る経路にも、
        // 繋ぎを捨てる経路にも入らない
        let recording = RecordingSender()
        let udp = UDPPort(
            port: 6000, name: "udp :6000", source: RecordedSource<String>(batches: []),
            outbound: recording, owner: nil, warn: told.append)
        udp.send(String(repeating: "a", count: 20000))
        udp.send(String(repeating: "a", count: 20000))
        udp.send(String(repeating: "a", count: 9216))
        udp.send(String(repeating: "é", count: 4608))  // 4608 字でも UTF-8 で 9216 バイト
        #expect(recording.sent.map(\.count) == [])
        #expect(told.lines.count == 1)
        let line = told.lines.first ?? ""
        #expect(line.contains("20000 bytes"))
        #expect(line.contains("9215 bytes at most"))
        #expect(!line.contains("listening"))

        udp.send(String(repeating: "a", count: 9215))
        #expect(recording.sent.map(\.count) == [9215])
        #expect(told.lines.count == 1)
    }

    @Test("大きすぎる送りが続く間は 1 度だけ知らせ、上限以内を送れたら、次の大きすぎる送りでまた知らせる")
    func oversizedSendIsToldAgainAfterASuccessfulSend() throws {
        let told = Told()
        let recording = RecordingSender()
        let udp = UDPPort(
            port: 6000, name: "udp :6000", source: RecordedSource<String>(batches: []),
            outbound: recording, owner: nil, warn: told.append)
        let large = String(repeating: "a", count: 20000)
        udp.send(large)
        udp.send(large)
        #expect(told.count(containing: "9215 bytes at most") == 1)

        udp.send("small")
        udp.send(large)
        udp.send(large)
        #expect(told.count(containing: "9215 bytes at most") == 2)
        #expect(recording.sent.map(\.count) == [5])
    }

    @Test("送れない理由は、理由ごとに 1 度だけ知らせて何も送らない")
    func unsendableIsToldOncePerReason() throws {
        let told = Told()
        let nowhere = UDPPort(
            port: 6000, name: "udp :6000", source: RecordedSource<String>(batches: []),
            outbound: nil, owner: nil, warn: told.append)
        nowhere.send("a")
        nowhere.send("b")
        #expect(told.count(containing: "has nowhere to send") == 1)
        #expect(told.count(containing: "createUDP(listen:send:)") == 1)

        let recorded = UDPPort(
            port: nil, name: "udp (recorded)", source: RecordedSource<String>(batches: []),
            outbound: nil, owner: nil, warn: told.append)
        recorded.send("a")
        recorded.send("b")
        #expect(told.count(containing: "replays recorded messages") == 1)

        let recording = RecordingSender()
        let stopped = UDPPort(
            port: 6000, name: "udp :6000", source: RecordedSource<String>(batches: []),
            outbound: recording, owner: nil, warn: told.append)
        stopped.send("ok\n")
        #expect(recording.sent == [Array("ok\n".utf8)])  // 改行は足さず、そのまま送る
        stopped.close()
        stopped.send("late")
        stopped.send("later")
        #expect(recording.sent.count == 1)
        #expect(told.count(containing: "is stopped") == 1)
        #expect(told.count(containing: "\"late\"") == 1)
    }

    // MARK: - 注入

    @Test("注入した列は、i 番目の取り出しで i 番目の束を渡し、終わりまで行けば始まりへ戻る")
    func injectedBatchesFollowTheFrames() throws {
        let udp = IdleSketch().createUDP(messages: [["a", "b"], [], ["c"]])
        try udp.open()
        var frames: [[String]] = []
        for _ in 0..<4 {
            udp.supply()
            frames.append(udp.messages)
        }
        #expect(frames == [["a", "b"], [], ["c"], ["a", "b"]])
        #expect(udp.state == .running)
        #expect(udp.port == nil)
    }

    // MARK: - ポートが使えないとき

    @Test("ポートを他が握っていれば unavailable と 1 度だけ知らせ、空けば受け始める")
    func portInUseWaitsUntilFreed() async throws {
        let told = Told()
        let holder = try PortHolder(port: 0)
        let port = holder.port
        let source = DatagramSource<String>.text(
            port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let udp = UDPPort(
            port: port, name: "udp :\(port)", source: source, outbound: nil, owner: nil,
            warn: told.append)
        try udp.open()
        defer { udp.close() }

        try await requireTold(containing: "UDP cannot listen on port \(port) because another app is using it", told: told, tracing: source) { udp.state }
        #expect(udp.state == .unavailable)
        // 開き直しを何度か重ねても、知らせは増えない
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)
        #expect(udp.state == .unavailable)

        holder.release()
        try await requireState(told: told, tracing: source) { udp.state }
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        let log = SendLog()
        let received = try await sendAndCollect(
            [Array("back".utf8)], expecting: 1, to: udp, senders: &senders, log: log
        ) { warn in DatagramSender(host: "127.0.0.1", port: port, warn: warn) }
        try await requireReceived(received, expecting: 1, log: log, udp: udp, port: port, told: told)
        #expect(received == ["back"])
    }

    // MARK: - 送り元の補助 (#2940)

    @Test("列の送りは、送れないと名乗り、まだ 1 通も読まれていない送り元を、猶予の後に替えて列を最初から送り直す")
    func sendAndCollectReplacesAStuckSender() async throws {
        let told = Told()
        let network = FakeNetwork()
        let udp = try fakeListening(network, told: told)
        defer { udp.close() }
        let port = network.port
        let flow = network.flow(0)
        network.listener.offer(flow)

        var made = 0
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        let log = SendLog()
        let received = try await sendAndCollect(
            [Array("a".utf8), Array("b".utf8)], expecting: 2, to: udp, senders: &senders,
            within: 10, patience: 0.1, log: log
        ) { warn in
            made += 1
            // 最初の送り元は、送れないと名乗って何も出さない
            return ScriptedSender(
                flow: made == 1 ? nil : flow, port: port, complaint: made == 1 ? warn : nil)
        }
        try await requireReceived(received, expecting: 2, log: log, udp: udp, port: port, told: told)
        #expect(received == ["a", "b"])
        #expect(made == 2)
    }

    @Test("列の送りは、1 通でも読まれた後は名乗っても替えず、名乗らずに読まれない送り元も替えない")
    func sendAndCollectDoesNotReplaceAfterAReadOrWithoutAComplaint() async throws {
        let told = Told()
        let network = FakeNetwork()
        let udp = try fakeListening(network, told: told)
        defer { udp.close() }
        let port = network.port
        let flow = network.flow(0)
        network.listener.offer(flow)

        // 名乗るが、出してもいる (読まれた後なので替えない。替えると列が重なる)
        var made = 0
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        let log = SendLog()
        let received = try await sendAndCollect(
            [Array("a".utf8), Array("b".utf8)], expecting: 2, to: udp, senders: &senders,
            within: 20, patience: 10, log: log
        ) { warn in
            made += 1
            return ScriptedSender(flow: flow, port: port, complaint: warn)
        }
        try await requireReceived(received, expecting: 2, log: log, udp: udp, port: port, told: told)
        #expect(received == ["a", "b"])
        #expect(made == 1)

        // 名乗らずに何も出さない送り元は替えず、期限で読まれた分 (0 通) を返す
        var silent = 0
        var more: [any DatagramSending] = []
        defer { for sender in more { sender.stop() } }
        let none = try await sendAndCollect(
            [Array("c".utf8)], expecting: 1, to: udp, senders: &more, within: 0.4
        ) { _ in
            silent += 1
            return ScriptedSender(flow: nil, port: port, complaint: nil)
        }
        #expect(none.isEmpty)
        #expect(silent == 1)
    }

    @Test("列の送りは、替える回数に上限を持ち、越えたら読まれた分(0 通)を返す")
    func sendAndCollectStopsReplacingAtTheLimit() async throws {
        let told = Told()
        let network = FakeNetwork()
        let udp = try fakeListening(network, told: told)
        defer { udp.close() }
        let port = network.port

        var made = 0
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        // 回数は時計に頼らない (#3215): 猶予は短く決め、上限まで替えて返るのを待つ。`within` は上限に届かな
        // かった回にだけ効く外枠で、遅い機械でも 3 つ目を作る前に期限が来ない広さにする
        let received = try await sendAndCollect(
            [Array("a".utf8)], expecting: 1, to: udp, senders: &senders, replacements: 2,
            within: 10, patience: 0.05, endsAtLimit: true
        ) { warn in
            made += 1
            return ScriptedSender(flow: nil, port: port, complaint: warn)
        }
        #expect(received.isEmpty)
        #expect(made == 3)
    }

    // MARK: - 前提が満たされなかった回の名乗り (#3001)

    @Test("列が期限までに読まれなければ、送り手と受け口の様子・替えた回数・名乗りの行・素の socket の 1 通と受け入れの差を名乗って 1 つで止まる")
    func requireReceivedNamesBothSidesAndStops() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        let raw = try RawDatagramSocket()
        defer { raw.release() }

        // 1 つ目は名乗って何も出さず、替えた先は 2 通のうち 1 通目と 2 通目を出すが、3 通を期待する。
        // 名乗りは送るたび (a と b の 2 通) に出るので 2 行
        var made = 0
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        let log = SendLog()
        let received = try await sendAndCollect(
            [Array("a".utf8), Array("b".utf8)], expecting: 3, to: udp, senders: &senders,
            within: 3, patience: 0.05, log: log
        ) { warn in
            made += 1
            return ScriptedSender(
                raw: made == 1 ? nil : raw, port: port, complaint: made == 1 ? warn : nil)
        }
        #expect(received == ["a", "b"])

        let text = try await said {
            try await requireReceived(received, expecting: 3, log: log, udp: udp, port: port, told: told)
        }
        #expect(text.contains("3 通のうち読めたのは 2 通"), "名乗り: \(text)")
        #expect(text.contains("期限 3.0 秒"), "名乗り: \(text)")
        // 受け口: 状態・移り変わり・受け入れた数・黙りで閉じた数・終わって外れた数・いま持つ数 (受け入れた送り元は 1 つ)
        #expect(text.contains("受け口 (1 通の前): running") && text.contains("移り変わり "), "名乗り: \(text)")
        #expect(text.contains("受け入れ 1・黙りで閉じた 0・終わって外れた 0・持つ数 1"), "名乗り: \(text)")
        #expect(text.contains("受け口の知らせは 0 行"), "名乗り: \(text)")
        // 送り手: 替えた回数・替えた後に読めた数・名乗りの行・送り元の様子 (替えた先は 2 通を出した)
        #expect(text.contains("替えた 1 回・替えた後に読めた 2 本"), "名乗り: \(text)")
        #expect(text.contains("名乗り 2 行") && text.contains("Could not send to 127.0.0.1:\(port)"), "名乗り: \(text)")
        #expect(text.contains("名乗った送り元 列[0]"), "名乗り: \(text)")
        #expect(text.contains("{出 2・誤り無し 0・誤り 0・最後 知らせ無し}×1"), "名乗り: \(text)")
        // 素の socket の 1 通は読めて、新しい送り元として受け入れが 1 つ増えた (救いには使わない — 検査は止まった)
        #expect(text.contains("素の socket の 1 通: 読めた・受け入れ +1 (新しい送り元を受けられた)"), "名乗り: \(text)")
        #expect(text.contains("受け口 (1 通の後): running") && text.contains("受け入れ 2・"), "名乗り: \(text)")
        // 1 通では分からないことを正直に書く
        #expect(text.contains("一度に来たときだけ受け口で落ちる形は、この 1 通では分からない"), "名乗り: \(text)")
    }

    @Test("黙って出ない送り元は、名乗りが 0 行で替えた回数も 0 とそのまま名乗り、閉じた受け口は素の 1 通も読めないと名乗る")
    func requireReceivedNamesASilentSender() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        let log = SendLog()
        let received = try await sendAndCollect(
            [Array("a".utf8)], expecting: 1, to: udp, senders: &senders, within: 0.4, log: log
        ) { _ in ScriptedSender(raw: nil, port: port, complaint: nil) }

        let text = try await said {
            try await requireReceived(received, expecting: 1, log: log, udp: udp, port: port, told: told)
        }
        #expect(text.contains("1 通のうち読めたのは 0 通"), "名乗り: \(text)")
        #expect(text.contains("替えた 0 回・替えた後に読めた 0 本"), "名乗り: \(text)")
        #expect(text.contains("名乗りは 0 行 (黙っている)"), "名乗り: \(text)")
        #expect(text.contains("素の socket の 1 通: 読めた"), "名乗り: \(text)")

        // 受け口が受けない形 (ここでは閉じた受け口) は、素の socket の 1 通も読まれず、受け口側と読み分けられる
        udp.close()
        let closed = try await said {
            try await requireReceived(received, expecting: 1, log: log, udp: udp, port: port, told: told)
        }
        #expect(closed.contains("受け口 (1 通の前): stopped"), "名乗り: \(closed)")
        #expect(closed.contains("素の socket の 1 通: 読めなかった"), "名乗り: \(closed)")
    }

    // MARK: - 素の socket から送った通が読まれなかった回の名乗り (#3105)

    @Test("素の socket から送った通が読まれなければ、受け口の様子と素の 1 通の前後の受け入れの差を名乗り、送り手の欄は様子を読めない送り元と言って 1 つで止まる")
    func rawSocketShortReadNamesTheReceiver() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        // 1 通だけ送って 2 通を期待する (2 通目は来ない)
        #expect(peer.send(Array("a".utf8), to: port) == 1)
        let text = try await said {
            _ = try await collectOrName(
                udp, count: 2, within: 0.5, from: peer, landing: landing(of: udp, port: port, told: told),
                "(2 通目は送っていない)")
        }
        #expect(text.contains("素の socket から送った 2 通のうち読めたのは 1 通(2 通目は送っていない)"), "名乗り: \(text)")
        #expect(text.contains("期限 0.5 秒"), "名乗り: \(text)")
        #expect(text.contains("受け口 (1 通の前): running") && text.contains("移り変わり "), "名乗り: \(text)")
        #expect(text.contains("受け入れ 1・黙りで閉じた 0・終わって外れた 0・持つ数 1"), "名乗り: \(text)")
        #expect(text.contains("受け口の知らせは 0 行"), "名乗り: \(text)")
        #expect(text.contains("素の socket の 1 通: 読めた・受け入れ +1 (新しい送り元を受けられた)"), "名乗り: \(text)")
        // 送り手の欄: 素の socket は名乗りも替えも持たない。黙っているとは言わない
        #expect(text.contains("素の socket: 読めたのは 1/2・読めなかった 1 通 (どの通かは分からない)"), "名乗り: \(text)")
        #expect(text.contains("送り元の様子 {様子を読めない送り元}×1"), "名乗り: \(text)")
        #expect(!text.contains("黙っている") && !text.contains("替えた"), "名乗り: \(text)")
        // 送った socket の sendto の戻り: 送れていたので、読めなかった理由は受け口側と読める
        #expect(text.contains("sendto は 1 回とも成功 (計 1 バイト)"), "名乗り: \(text)")

        // 受け口が受けない形 (閉じた受け口) は、素の 1 通も読まれず、受け口側と読み分けられる
        udp.close()
        let closed = try await said {
            _ = try await collectOrName(
                udp, count: 1, within: 0.3, from: peer, landing: landing(of: udp, port: port, told: told))
        }
        #expect(closed.contains("受け口 (1 通の前): stopped"), "名乗り: \(closed)")
        #expect(closed.contains("素の socket の 1 通: 読めなかった"), "名乗り: \(closed)")
    }

    @Test("受け口を直に使う検査で、素の socket から送った結果が満ちなければ、状態と知らせを持たない受け口として名乗り、受け入れの差も言って 1 つで止まる")
    func requireRawArrivalNamesABareListener() async throws {
        let received = Mutex<[String]>([])
        let bound = Mutex<Int?>(nil)
        let events = Mutex<[String]>([])
        let listener = DatagramListener(
            port: 0, host: "127.0.0.1", retryAfter: 0.05,
            received: { bytes, _ in received.withLock { $0.append(String(decoding: bytes, as: UTF8.self)) } },
            changed: { event in
                events.withLock { $0.append("\(event)") }
                if case .ready(let port) = event { bound.withLock { $0 = port } }
            })
        listener.start()
        defer { listener.stop() }
        try await requireWait(
            "受け口が ready にならなかった", detail: { "受けた移り変わり: \(events.withLock { $0 })" },
            until: { bound.withLock { $0 } != nil })
        let port = try #require(bound.withLock { $0 })
        let peer = try RawDatagramSocket()
        defer { peer.release() }
        let bare = landing(
            of: listener, port: port, events: { events.withLock { $0 } },
            probeArrived: { received.withLock { $0.contains("probe") } })

        // 満ちる条件は、満ちれば何も言わない
        #expect(peer.send(Array("a".utf8), to: port) == 1)
        try await requireRawArrival("a を読まなかった", from: peer, landing: bare) { received.withLock { $0 } == ["a"] }

        // 満ちない条件 (2 通目は送っていない) は、期限で名乗って止まる
        let text = try await said {
            try await requireRawArrival(
                "受け口が 2 通を読まなかった (読めたもの: \(received.withLock { $0 }))", within: 0.5, from: peer, landing: bare
            ) { received.withLock { $0.count } >= 2 }
        }
        #expect(text.contains("受け口が 2 通を読まなかった (読めたもの: [\"a\"])"), "名乗り: \(text)")
        #expect(text.contains("期限 0.5 秒"), "名乗り: \(text)")
        #expect(text.contains("受け口 (1 通の前): 状態は読めない・移り変わり "), "名乗り: \(text)")
        #expect(text.contains("受け入れ 1・黙りで閉じた 0・終わって外れた 0・持つ数 1"), "名乗り: \(text)")
        #expect(text.contains("受け口の知らせは持たない"), "名乗り: \(text)")
        #expect(text.contains("素の socket の 1 通: 読めた・受け入れ +1 (新しい送り元を受けられた)"), "名乗り: \(text)")
        #expect(text.contains("送り元の様子 {様子を読めない送り元}×1"), "名乗り: \(text)")
        #expect(!text.contains("黙っている") && !text.contains("替えた"), "名乗り: \(text)")
    }

    // MARK: - 作る口

    @Test("ポートの番号が 1〜65535 の外・送り先のホストが空なら、作るときに投げる")
    func creationRefusesUnusableValues() throws {
        let sketch = IdleSketch()
        #expect(throws: NetworkFailure.invalidPort(0)) { try sketch.createUDP(listen: 0) }
        #expect(throws: NetworkFailure.invalidPort(65536)) { try sketch.createUDP(listen: 65536) }
        #expect(throws: NetworkFailure.invalidPort(0)) {
            try sketch.createUDP(listen: 6000, send: ("127.0.0.1", 0))
        }
        #expect(throws: NetworkFailure.invalidHost(" ")) {
            try sketch.createUDP(listen: 6000, send: (" ", 6001))
        }
        #expect(
            NetworkFailure.invalidPort(0).description
                == "The port 0 is not usable. Pass a number from 1 to 65535 (9000, for example)")
        // 両端は値の検めを通る。走っていないスケッチなので、その後ポートを開く前に断る (#2740)
        OutsideRun.$current.withValue(OutsideRun()) {
            #expect(throws: NetworkFailure.notRunning(call: "createUDP(listen:send:)")) {
                try sketch.createUDP(listen: 65535, send: ("127.0.0.1", 1))
            }
            #expect(throws: NetworkFailure.notRunning(call: "createUDP(listen:send:)")) {
                try sketch.createUDP(listen: 1, send: ("127.0.0.1", 65535))
            }
        }
    }
}
