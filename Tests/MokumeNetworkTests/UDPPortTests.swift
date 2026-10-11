// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
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

    @Test("空の datagram は空の文字列として届き、その送り元の繋ぎを閉じず、続けて届いた datagram も落とさない")
    func emptyDatagramIsAnEmptyString() async throws {
        let told = Told()
        let (udp, port) = try await listening(told: told)
        defer { udp.close() }
        let source = try #require(udp.source as? DatagramSource<String>)
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        // 1 つの送り元から間を空けずに送る。空の後ろの datagram は、受け口の同じ繋ぎに積まれている
        for text in ["a", "", "b", "c"] {
            #expect(peer.send(Array(text.utf8), to: port) == text.utf8.count)
        }
        let received = await collect(udp, count: 4)
        #expect(received == ["a", "", "b", "c"])
        #expect(udp.input.unreadable == 0)
        #expect(source.tally.ended == 0)
        #expect(told.lines.isEmpty)
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

    @Test("受けの完了は、空の datagram と繋ぎの終わりを、文脈が終わりを名乗るかで見分ける")
    func completionTellsAnEmptyDatagramFromTheEnd() {
        // 空の datagram: content は nil で、文脈は終わりを名乗らない (実測)
        #expect(DatagramListener.datagram(content: nil, context: .defaultMessage, error: nil) == [])
        #expect(DatagramListener.datagram(content: Data([1, 2]), context: .defaultMessage, error: nil) == [1, 2])
        // 受けを待っている繋ぎを閉じたとき: content も error も nil で、文脈が終わりを名乗る (実測)
        #expect(DatagramListener.datagram(content: nil, context: .finalMessage, error: nil) == nil)
        #expect(DatagramListener.datagram(content: nil, context: nil, error: nil) == nil)
        #expect(DatagramListener.datagram(content: nil, context: nil, error: .posix(.ECANCELED)) == nil)
        #expect(
            DatagramListener.datagram(content: Data([1]), context: .defaultMessage, error: .posix(.ECANCELED))
                == nil)
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
        let sender = UDPPort(
            port: 1, name: "udp :1", source: RecordedSource<String>(batches: []),
            outbound: DatagramSender(host: "127.0.0.1", port: port, warn: told.append),
            owner: nil, warn: told.append)
        defer { sender.close() }

        sender.send("")
        sender.send("x")
        let received = await collect(receiver, count: 2)
        #expect(received == ["", "x"])
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
