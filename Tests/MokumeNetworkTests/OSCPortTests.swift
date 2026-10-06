// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// 空いている UDP のポートを 1 つ選ぶ。127.0.0.1 で番号 0 を開いて OS が選んだ番号を読み、閉じる。
nonisolated func freeUDPPort() throws -> Int {
    let holder = try PortHolder(port: 0)
    defer { holder.release() }
    return holder.port
}

/// UDP のソケットで 127.0.0.1 のポートを握る。他のアプリがそのポートを使っている状態を作る。
nonisolated final class PortHolder: Sendable {
    let port: Int
    private let descriptor: Int32

    struct Failure: Error {
        let call: String
        let code: Int32
    }

    init(port: Int) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure(call: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure(call: "bind", code: code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        self.descriptor = descriptor
        self.port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func release() { close(descriptor) }
}

/// 知らせの行き先。どのスレッドから書かれてもよい。
nonisolated final class Told: Sendable {
    private let store = Mutex<[String]>([])
    func append(_ line: String) { store.withLock { $0.append(line) } }
    var lines: [String] { store.withLock { $0 } }
    func count(containing text: String) -> Int { lines.filter { $0.contains(text) }.count }
}

/// 送ったバイト列を溜める送り手。通信はしない。
nonisolated final class RecordingSender: DatagramSending {
    private let store = Mutex<[[UInt8]]>([])
    var sent: [[UInt8]] { store.withLock { $0 } }
    func send(_ bytes: [UInt8]) { store.withLock { $0.append(bytes) } }
    func stop() {}
}

/// 作る口が値を検めるためだけのスケッチ。走らせない。
final class IdleSketch: Sketch {
    init() {}
    func draw() {}
}

/// OSC の入り口 (#1962)。GPU は要らない。通信は 127.0.0.1 だけで行う (別の機械には届かない)。
///
/// 入り口を走っているスケッチに足さず、フレームの代わりに ``OSCPort/supply()`` を自分で呼ぶ。
/// **待つ側が期限を持つ** — 届くのを待つ検査は、期限を越えたら満たされなかったとして落ちる。
@Suite("OSC の入り口", .serialized)
struct OSCPortTests {
    /// 期限まで、条件が満ちるのを待つ。満ちなければ偽。
    private func until(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// フレームを回すように取り出しを続け、`count` 個届くまで (か期限まで) 集める。
    private func collect(_ osc: OSCPort, count: Int) async -> [OSCMessage] {
        var received: [OSCMessage] = []
        _ = await until {
            osc.supply()
            received += osc.messages
            return received.count >= count
        }
        return received
    }

    /// 127.0.0.1 の `port` で受け、送り先も同じポートにした入り口。開いて返す。
    private func loopback(
        port: Int, told: Told, outbound: (any DatagramSending)? = nil,
        idleAfter: TimeInterval = DatagramListener.defaultIdleAfter
    ) throws -> OSCPort {
        let osc = OSCPort(
            port: port, name: "osc :\(port)",
            source: NetworkOSCSource(
                port: port, host: "127.0.0.1", retryAfter: 0.05, idleAfter: idleAfter,
                warn: told.append),
            outbound: outbound ?? DatagramSender(host: "127.0.0.1", port: port, warn: told.append),
            owner: nil, warn: told.append)
        try osc.open()
        return osc
    }

    /// 送るメッセージの台本。大きさを動かし、当たりを数える。
    static let script: [OSCMessage] = [
        OSCMessage("/size", Float(0.25)),
        OSCMessage("/hit", 1),
        OSCMessage("/size", Float(0.75)),
        OSCMessage("/label", "fade"),
        OSCMessage("/hit", 1),
    ]

    /// 台本を読んだ結果。作例のスケッチがすることと同じ (大きさを置き換え、当たりを足す)。
    struct Outcome: Equatable {
        var size: Float = 0.5
        var hits = 0

        init(_ messages: [OSCMessage]) {
            for message in messages {
                switch message.address {
                case "/size": size = message.float(0) ?? size
                case "/hit": hits += message.int(0) ?? 0
                default: break
                }
            }
        }
    }

    // MARK: - 同じ機械の中で送って受ける

    @Test("自分で送ったメッセージを、自分のポートで受ける")
    func sendsToItselfAndReceives() async throws {
        let told = Told()
        let port = try freeUDPPort()
        let osc = try loopback(port: port, told: told)
        defer { osc.close() }
        #expect(await until { osc.state == .running })

        osc.send("/size", Float(0.25))
        osc.send("/hit", 1)
        let received = await collect(osc, count: 2)
        #expect(received == [OSCMessage("/size", Float(0.25)), OSCMessage("/hit", 1)])
        #expect(osc.lastArrival != nil)
        #expect(osc.report == SourceReport(name: "osc :\(port)", state: .running, lastArrival: osc.lastArrival))
        #expect(told.lines.isEmpty)

        osc.close()
        #expect(osc.state == .stopped)
        #expect(osc.messages.isEmpty)
    }

    @Test("同じメッセージの列は、ポートで受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let port = try freeUDPPort()
        let live = try loopback(port: port, told: told)
        defer { live.close() }
        #expect(await until { live.state == .running })
        for message in Self.script {
            live.send(message)
        }
        let received = await collect(live, count: Self.script.count)

        let injected = OSCPort(
            port: nil, name: "osc (recorded)",
            source: RecordedOSCSource(batches: Self.script.map { [$0] }), outbound: nil, owner: nil)
        try injected.open()
        var replayed: [OSCMessage] = []
        for _ in Self.script {
            injected.supply()
            replayed += injected.messages
        }

        #expect(received == Self.script)
        #expect(replayed == Self.script)
        #expect(Outcome(received) == Outcome(replayed))
        #expect(Outcome(replayed) == Outcome(Self.script))
    }

    @Test("注入した列は、i 番目の取り出しで i 番目の束を渡し、終わりまで行けば始まりへ戻る")
    func injectedBatchesFollowTheFrames() throws {
        let first = OSCMessage("/a", 1)
        let second = OSCMessage("/b", 2)
        let osc = OSCPort(
            port: nil, name: "osc (recorded)",
            source: RecordedOSCSource(batches: [[first, second], [], [second]]), outbound: nil,
            owner: nil)
        try osc.open()
        var frames: [[OSCMessage]] = []
        for _ in 0..<4 {
            osc.supply()
            frames.append(osc.messages)
        }
        #expect(frames == [[first, second], [], [second], [first, second]])
        #expect(osc.state == .running)
    }

    // MARK: - 読めないものは打ち切る

    @Test("読めない部分を含むパケットは、そこから後ろを捨てて数える。前と次のパケットは届く")
    func unreadablePacketIsCutOffAndCounted() async throws {
        let told = Told()
        let port = try freeUDPPort()
        let osc = try loopback(port: port, told: told)
        defer { osc.close() }
        #expect(await until { osc.state == .running })

        let before = OSCMessage("/before", 1)
        let after = OSCMessage("/after", 2)
        let next = OSCMessage("/next", 3)
        let broken = Wire.bundle([
            try Wire.encoded(before), Wire.string("/bad") + Wire.string(",q"), try Wire.encoded(after),
        ])
        let raw = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { raw.stop() }
        raw.send(broken)
        raw.send(try Wire.encoded(next))

        let received = await collect(osc, count: 2)
        #expect(received == [before, next])
        #expect(osc.input.unreadable == 1)
    }

    @Test("多くの送り元から一度に届いても 1 つも落とさず、黙った送り元は次の受け入れで閉じる")
    func manySendersAreAllHeardThenSwept() async throws {
        let told = Told()
        let port = try freeUDPPort()
        let osc = try loopback(port: port, told: told, idleAfter: 0.2)
        defer { osc.close() }
        #expect(await until { osc.state == .running })
        let source = try #require(osc.source as? NetworkOSCSource)

        // 送り手ごとに別のポートから送る (使い捨てのソケットで送るスクリプトと同じ形)。
        // 目安の数を超えても、届いたばかりの送り元は閉じない — 閉じると読む前の datagram を捨てる
        let count = DatagramListener.connectionLimit + 6
        let burst = (0..<count).map { _ in
            DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        }
        defer { for sender in burst { sender.stop() } }
        for (index, sender) in burst.enumerated() {
            sender.send(try Wire.encoded(OSCMessage("/from", index)))
        }
        let received = await collect(osc, count: count)
        #expect(Set(received.compactMap { $0.int(0) }) == Set(0..<count))
        #expect(source.connectionCount == count)

        // 黙った後に新しい送り元が来たら、黙っていた送り元を閉じてから受ける
        try await Task.sleep(for: .milliseconds(400))
        let late = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { late.stop() }
        late.send(try Wire.encoded(OSCMessage("/late", 1)))
        #expect(await collect(osc, count: 1) == [OSCMessage("/late", 1)])
        #expect(source.connectionCount == 1)
    }

    // MARK: - ポートが使えないとき

    @Test("ポートを他が握っていれば unavailable と 1 度だけ知らせ、空けば受け始める")
    func portInUseWaitsUntilFreed() async throws {
        let told = Told()
        let holder = try PortHolder(port: 0)
        let port = holder.port
        let osc = try loopback(port: port, told: told)
        defer { osc.close() }

        #expect(await until { told.count(containing: "another app is using it") == 1 })
        #expect(osc.state == .unavailable)
        // 開き直しを何度か重ねても、知らせは増えない
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)
        #expect(osc.state == .unavailable)

        holder.release()
        #expect(await until { osc.state == .running })
        osc.send("/back", 1)
        #expect(await collect(osc, count: 1) == [OSCMessage("/back", 1)])
    }

    // MARK: - 作る口

    @Test("ポートの番号が 1〜65535 の外・送り先のホストが空なら、作るときに投げる")
    func creationRefusesUnusableValues() throws {
        let sketch = IdleSketch()
        #expect(throws: OSCFailure.invalidPort(0)) { try sketch.createOSC(listen: 0) }
        #expect(throws: OSCFailure.invalidPort(65536)) { try sketch.createOSC(listen: 65536) }
        #expect(throws: OSCFailure.invalidPort(0)) {
            try sketch.createOSC(listen: 9000, send: ("127.0.0.1", 0))
        }
        #expect(throws: OSCFailure.invalidHost(" ")) {
            try sketch.createOSC(listen: 9000, send: (" ", 7000))
        }
        // 両端は通る (走っていないスケッチなので、ポートは開かない)
        let edge = try sketch.createOSC(listen: 65535, send: ("127.0.0.1", 1))
        #expect(edge.port == 65535)
        #expect(edge.state == .unavailable)
    }

    // MARK: - 送れないとき

    @Test("送れない理由は、理由ごとに 1 度だけ知らせて何も送らない")
    func unsendableIsToldOncePerReason() throws {
        let told = Told()
        let recording = RecordingSender()
        let osc = OSCPort(
            port: 9000, name: "osc :9000", source: RecordedOSCSource(batches: []),
            outbound: recording, owner: nil, warn: told.append)
        osc.send("size", 1)
        osc.send("size", 2)
        #expect(recording.sent.isEmpty)
        #expect(told.lines.count == 1)
        #expect(told.lines.first?.contains("does not start with \"/\"") == true)

        osc.send("/ok", 1)
        #expect(recording.sent == [try Wire.encoded(OSCMessage("/ok", 1))])

        let nowhere = OSCPort(
            port: 9000, name: "osc :9000", source: RecordedOSCSource(batches: []), outbound: nil,
            owner: nil, warn: told.append)
        nowhere.send("/a", 1)
        nowhere.send("/b", 1)
        #expect(told.count(containing: "has nowhere to send") == 1)

        let recorded = OSCPort(
            port: nil, name: "osc (recorded)", source: RecordedOSCSource(batches: []),
            outbound: nil, owner: nil, warn: told.append)
        recorded.send("/a", 1)
        #expect(told.count(containing: "replays recorded messages") == 1)

        osc.close()
        osc.send("/late", 1)
        #expect(recording.sent.count == 1)
        #expect(told.count(containing: "is stopped") == 1)
    }
}
