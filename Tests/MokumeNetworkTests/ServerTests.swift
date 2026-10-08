// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// 書いたものを溜める相手。通信はしない。
nonisolated final class RecordingBroadcaster: Broadcasting, Sendable {
    private let store = Mutex<[String]>([])
    private let count: Int
    init(clientCount: Int) { count = clientCount }
    var clientCount: Int { count }
    var written: [String] { store.withLock { $0 } }
    func broadcast(_ text: String) { store.withLock { $0.append(text) } }
}

/// 繋いでくる相手を待つ入り口・TCP (#2018)。GPU は要らない。通信は 127.0.0.1 だけで行い、
/// ポートは OS が選ぶ (0 を頼む)。相手は `nc` の代わりに ``StreamClient`` が務める。
///
/// 入り口を走っているスケッチに足さず、フレームの代わりに ``TextPort/supply()`` を自分で呼ぶ。
@Suite("TCP の入り口", .serialized)
struct ServerTests {
    /// 127.0.0.1 の `port` (既定は OS が選ぶ) で待つ入り口を開き、受け始めるまで待つ。
    private func listening(told: Told, port: Int = 0) async throws -> (server: Server, port: Int) {
        let source = StreamSource(kind: .tcp, port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let server = Server(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        return (server, try await boundPort(of: server, source: source))
    }

    // MARK: - 受ける

    @Test("繋いできた相手が送った行を届いた順に受け、行の途中で切れて届いてもつなぐ")
    func receivesLinesInOrder() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peer = StreamClient(port: port)
        defer { peer.close() }
        #expect(await clients(server, reach: 1))

        peer.send("0.25\nhit\r\n\n")
        peer.send("0.")
        peer.send("75\n")
        let received = await collect(server, count: 4)
        #expect(received == ["0.25", "hit", "", "0.75"])
        #expect(server.lastArrival != nil)
        #expect(server.report == SourceReport(name: "tcp :0", state: .running, lastArrival: server.lastArrival))
        #expect(told.lines.isEmpty)
    }

    @Test("相手が閉じたら、改行で終わっていない残りを 1 行として渡し、clientCount が減る")
    func closingPeerEndsTheLastLine() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let first = StreamClient(port: port)
        defer { first.close() }
        let second = StreamClient(port: port)
        defer { second.close() }
        #expect(await clients(server, reach: 2))

        first.send("0.5")
        first.finish()
        #expect(await collect(server, count: 1) == ["0.5"])
        #expect(await clients(server, reach: 1))
        #expect(await until { first.closedByPeer })

        second.close()
        #expect(await clients(server, reach: 0))
        #expect(server.state == .running)  // 受け口は開いたまま。次の相手を待つ
    }

    @Test("UTF-8 として読めない行・長すぎる行は捨てて数え、前後の行は届く")
    func unreadableLinesAreDiscardedAndCounted() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peer = StreamClient(port: port)
        defer { peer.close() }
        #expect(await clients(server, reach: 1))

        peer.send("before\n")
        peer.send([0x68, 0xFF, 0x0A])  // 'h' と、UTF-8 に現れないバイト
        peer.send([UInt8](repeating: 0x61, count: StreamListener.lineLimit + 10) + [0x0A])
        peer.send("after\n")
        let received = await collect(server, count: 2)
        #expect(received == ["before", "after"])
        #expect(await until { server.input.unreadable == 2 })
    }

    // MARK: - 書く

    @Test("write は繋いでいる相手全員へ、改行を足さずにそのまま書く")
    func writeReachesEveryClient() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let first = StreamClient(port: port)
        defer { first.close() }
        let second = StreamClient(port: port)
        defer { second.close() }
        #expect(await clients(server, reach: 2))

        server.write("hit\n")
        server.write("size 0.5")
        #expect(await until { first.received == "hit\nsize 0.5" && second.received == "hit\nsize 0.5" })
        #expect(told.lines.isEmpty)
    }

    @Test("相手が居ないときの write は 1 度だけ知らせ、書けたら、また言えるように戻る")
    func writeWithoutClientsIsToldOnce() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        server.write("a")
        server.write("b")
        #expect(told.count(containing: "No client is connected to the server on port 0") == 1)
        #expect(told.count(containing: "\"a\"") == 1)

        let peer = StreamClient(port: port)
        #expect(await clients(server, reach: 1))
        server.write("c")
        #expect(await until { peer.received == "c" })
        peer.close()
        #expect(await clients(server, reach: 0))

        server.write("d")
        server.write("e")
        #expect(told.count(containing: "No client is connected") == 2)
        #expect(told.count(containing: "\"d\"") == 1)
    }

    @Test("止めたら相手は切れ、state は stopped・clientCount は 0 で、write は 1 度だけ知らせる")
    func stopEndsEverything() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        let peer = StreamClient(port: port)
        defer { peer.close() }
        #expect(await clients(server, reach: 1))

        server.close()
        #expect(server.state == .stopped)
        #expect(server.clientCount == 0)
        #expect(server.messages.isEmpty)
        #expect(await until { peer.closedByPeer })
        server.write("late\n")
        server.write("later\n")
        #expect(told.count(containing: "This server is stopped") == 1)
        #expect(told.count(containing: "\"late\\n\"") == 1)  // 改行は \n と書いて出す
    }

    @Test("記録した列を流す入り口には相手が居ない。write は 1 度だけ知らせて何も書かない")
    func recordedServerHasNoClients() throws {
        let told = Told()
        let recorded = Server(
            port: nil, name: "server (recorded)", source: RecordedSource<String>(batches: [["a"]]),
            clients: nil, owner: nil, warn: told.append)
        try recorded.open()
        recorded.supply()
        #expect(recorded.messages == ["a"])
        #expect(recorded.clientCount == 0)
        recorded.write("x")
        recorded.write("y")
        #expect(told.count(containing: "replays recorded messages and has no clients") == 1)

        // 書く先が居れば書き、居なければ書かない (数えは書く先が持つ)
        let present = RecordingBroadcaster(clientCount: 2)
        let live = Server(
            port: 5204, name: "tcp :5204", source: RecordedSource<String>(batches: []),
            clients: present, owner: nil, warn: told.append)
        try live.open()
        live.supply()
        #expect(live.clientCount == 2)
        live.write("hit\n")
        #expect(present.written == ["hit\n"])
    }

    // MARK: - 注入

    @Test("同じ行の列は、ポートで受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let (live, port) = try await listening(told: told)
        defer { live.close() }
        let peer = StreamClient(port: port)
        defer { peer.close() }
        #expect(await clients(live, reach: 1))
        peer.send(textScript.map { $0 + "\n" }.joined())
        let received = await collect(live, count: textScript.count)

        let injected = IdleSketch().createServer(messages: textScript.map { [$0] })
        try injected.open()
        var replayed: [String] = []
        for _ in textScript {
            injected.supply()
            replayed += injected.messages
        }

        #expect(received == textScript)
        #expect(replayed == textScript)
        #expect(TextOutcome(received) == TextOutcome(replayed))
        #expect(injected.port == nil)
        #expect(injected.state == .running)
    }

    // MARK: - ポートが使えないとき

    @Test("ポートを他が握っていれば unavailable と 1 度だけ知らせ、空けば受け始める")
    func portInUseWaitsUntilFreed() async throws {
        let told = Told()
        let holder = try PortHolder(port: 0, stream: true)
        let port = holder.port
        let source = StreamSource(kind: .tcp, port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let server = Server(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        defer { server.close() }

        #expect(await until { told.count(containing: "TCP cannot listen on port \(port) because another app is using it") == 1 })
        #expect(server.state == .unavailable)
        // 開き直しを何度か重ねても、知らせは増えない
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)
        #expect(server.state == .unavailable)

        holder.release()
        #expect(await until { server.state == .running })
        let peer = StreamClient(port: port)
        defer { peer.close() }
        peer.send("back\n")
        #expect(await collect(server, count: 1) == ["back"])
    }

    // MARK: - 作る口

    @Test("ポートの番号が 1〜65535 の外なら、作るときに投げる")
    func creationRefusesUnusablePorts() throws {
        let sketch = IdleSketch()
        #expect(throws: NetworkFailure.invalidPort(0)) { try sketch.createServer(0) }
        #expect(throws: NetworkFailure.invalidPort(65536)) { try sketch.createServer(65536) }
        // 両端は通る (走っていないスケッチなので、ポートは開かない)
        let edge = try sketch.createServer(65535)
        #expect(edge.port == 65535)
        #expect(edge.state == .unavailable)
        #expect(edge.clientCount == 0)
        #expect(edge.report?.name == "tcp :65535")
        #expect((edge.source as? StreamSource)?.kind == .tcp)
    }
}
