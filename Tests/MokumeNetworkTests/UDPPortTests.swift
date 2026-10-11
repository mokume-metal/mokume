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
        #expect(await until { udp.state == .running })
        return (udp, try #require(source.boundPort))
    }

    // MARK: - 受ける

    @Test("相手から届いた文字列を届いた順に受け、末尾の改行 1 つを落とす")
    func receivesTextInOrder() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        let peer = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { peer.stop() }

        // nc で打った行・CRLF で終わる行・前後の空白・改行 2 つ (落とすのは 1 つだけ)
        for text in ["0.25\n", "hit\r\n", "  spaced  ", "two\n\n"] {
            peer.send(Array(text.utf8))
        }
        let received = await collect(udp, count: 4)
        #expect(received == ["0.25", "hit", "  spaced  ", "two\n"])
        #expect(udp.lastArrival != nil)
        #expect(udp.report == SourceReport(name: "udp :0", state: .running, lastArrival: udp.lastArrival))
        #expect(told.lines.isEmpty)

        udp.close()
        #expect(udp.state == .stopped)
        #expect(udp.messages.isEmpty)
    }

    @Test("UTF-8 として読めない datagram は捨てて数え、前後の datagram は届く")
    func unreadableIsDiscardedAndCounted() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        let peer = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { peer.stop() }

        peer.send(Array("before".utf8))
        peer.send([0x68, 0xFF, 0xFE, 0x0A])  // 'h' と、UTF-8 に現れないバイト
        peer.send(Array("after".utf8))
        let received = await collect(udp, count: 2)
        #expect(received == ["before", "after"])
        #expect(udp.input.unreadable == 1)
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
        var received = await collect(udp, count: 1)
        #expect(peer.send([], to: port) == 0)
        received += await collect(udp, count: 1)
        #expect(received == ["a", ""])

        // その流れは次の受けで終わる。閉じた後に届いたものは、新しい流れで受ける
        _ = await until(1) { source.tally.ended >= 1 }
        for text in ["b", "c"] {
            #expect(peer.send(Array(text.utf8), to: port) == 1)
        }
        received += await collect(udp, count: 2)
        #expect(received == ["a", "", "b", "c"])
        #expect(udp.input.unreadable == 0)
        #expect(told.lines.isEmpty)
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

    @Test("9216 バイト以上の datagram は切れた疑いがあるので丸ごと捨てて数え、9215 バイトまでは全長で届く")
    func oversizedDatagramIsDiscardedAndCounted() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        // macOS の受け口は 9216 バイトを超えるものを先頭 9216 バイトに黙って切る。切れたものと
        // ちょうど 9216 バイトのものは見分けられないので、9216 バイトから捨てる
        for size in [1000, 9215, 9216, 9217, 20000, 65507] {
            #expect(peer.send([UInt8](repeating: 0x61, count: size), to: port) == size)
        }
        #expect(peer.send(Array("after".utf8), to: port) == 5)
        let received = await collect(udp, count: 3)
        #expect(received.map(\.utf8.count) == [1000, 9215, 5])
        #expect(received.last == "after")
        #expect(udp.input.unreadable == 4)
        #expect(told.lines.isEmpty)
    }

    @Test("前提: macOS の受け口は 9216 バイトを超える datagram を、先頭 9216 バイトに切って渡す")
    func networkFrameworkCutsDatagramsAt9216() async throws {
        // 上限 (Datagram.sizeLimit) の見張りを通る前の、受け口が渡す生のバイト列の長さを見る。
        // 見張りは OS が切らなくても 9216 バイト以上を捨てるので、上の検査は OS の振る舞いが
        // 変わっても緑のままになる。この検査はその前提だけを見張る (#2325)
        let lengths = Mutex<[Int]>([])
        let bound = Mutex<Int?>(nil)
        let listener = DatagramListener(
            port: 0, host: "127.0.0.1", retryAfter: 0.05,
            received: { bytes, _ in lengths.withLock { $0.append(bytes.count) } },
            changed: { event in
                if case .ready(let port) = event { bound.withLock { $0 = port } }
            })
        listener.start()
        defer { listener.stop() }
        #expect(await until { bound.withLock { $0 } != nil })
        let port = try #require(bound.withLock { $0 })
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        for size in [9215, 9216, 20000] {
            #expect(peer.send([UInt8](repeating: 0x61, count: size), to: port) == size)
        }
        #expect(await until { lengths.withLock { $0.count } >= 3 })
        #expect(
            lengths.withLock { $0 } == [9215, 9216, 9216],
            "Network.framework の切り方が変わった。#2325 の上限 (Datagram.sizeLimit) の前提を見直す")
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

        sender.send("hit")
        sender.send("size 0.5")
        #expect(await collect(receiver, count: 2) == ["hit", "size 0.5"])
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

        // 流れができてから空を送る (受け口の流れが終わりを名乗る形)
        sender.send("x")
        var received = await collect(receiver, count: 1)
        sender.send("")
        received += await collect(receiver, count: 1)
        _ = await until(1) { source.tally.ended >= 1 }
        sender.send("y")
        received += await collect(receiver, count: 1)
        #expect(received == ["x", "", "y"])
        #expect(told.lines.isEmpty)
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

    @Test("本物の宛先でも、上限に入らない文字列は送らず、続けて送った文字列は届く")
    func oversizedSendLeavesTheDestinationReachable() async throws {
        let (receiver, port) = try await listening(told: Told())
        defer { receiver.close() }
        let told = Told()
        let sender = UDPPort(
            port: 1, name: "udp :1", source: RecordedSource<String>(batches: []),
            outbound: DatagramSender(host: "127.0.0.1", port: port, warn: told.append),
            owner: nil, warn: told.append)
        defer { sender.close() }

        sender.send(String(repeating: "a", count: 20000))
        sender.send("after")
        let received = await collect(receiver, count: 1)
        #expect(received == ["after"])
        #expect(receiver.input.unreadable == 0)
        #expect(told.lines.count == 1)
        #expect(told.count(containing: "9215 bytes at most") == 1)
        #expect(told.count(containing: "listening") == 0)
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

    @Test("同じ文字列の列は、ポートで受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let (live, port) = try await listening(told: told)
        defer { live.close() }
        let peer = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { peer.stop() }
        for text in textScript { peer.send(Array("\(text)\n".utf8)) }
        let received = await collect(live, count: textScript.count)

        let injected = UDPPort(
            port: nil, name: "udp (recorded)",
            source: RecordedSource(batches: textScript.map { [$0] }), outbound: nil, owner: nil,
            warn: told.append)
        try injected.open()
        var replayed: [String] = []
        for _ in textScript {
            injected.supply()
            replayed += injected.messages
        }

        #expect(received == textScript)
        #expect(replayed == textScript)
        #expect(TextOutcome(received) == TextOutcome(replayed))
        #expect(TextOutcome(replayed) == TextOutcome(size: 0.75, hits: 2))
    }

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

        #expect(await until { told.count(containing: "UDP cannot listen on port \(port) because another app is using it") == 1 })
        #expect(udp.state == .unavailable)
        // 開き直しを何度か重ねても、知らせは増えない
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)
        #expect(udp.state == .unavailable)

        holder.release()
        #expect(await until { udp.state == .running })
        let peer = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { peer.stop() }
        peer.send(Array("back".utf8))
        #expect(await collect(udp, count: 1) == ["back"])
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
        // 両端は通る (走っていないスケッチなので、ポートは開かない)
        let edge = try sketch.createUDP(listen: 65535, send: ("127.0.0.1", 1))
        #expect(edge.port == 65535)
        #expect(edge.state == .unavailable)
    }
}
