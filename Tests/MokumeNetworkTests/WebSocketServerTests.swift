// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// 繋いでくる相手を待つ入り口・WebSocket (#2018)。GPU は要らない。通信は 127.0.0.1 だけで行い、
/// ポートは OS が選ぶ (0 を頼む)。相手はブラウザの代わりに ``WebSocketClient`` が務める。
///
/// 入り口を走っているスケッチに足さず、フレームの代わりに ``TextPort/supply()`` を自分で呼ぶ。
@Suite("WebSocket の入り口", .serialized)
struct WebSocketServerTests {
    /// 127.0.0.1 の `port` (既定は OS が選ぶ) で待つ入り口を開き、受け始めるまで待つ。
    private func listening(told: Told, port: Int = 0) async throws -> (server: Server, port: Int) {
        let source = StreamSource(
            kind: .webSocket, port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let server = Server(
            port: port, name: "websocket :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        return (server, try await boundPort(of: server, source: source))
    }

    // MARK: - 受ける

    @Test("繋いできた相手が送った 1 通ずつを届いた順に受け、末尾の改行 1 つを落とす")
    func receivesMessagesInOrder() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peer = WebSocketClient(port: port, path: "/remote")  // どのパスでも同じ受け口に届く
        defer { peer.close() }
        #expect(await clients(server, reach: 1))

        for text in ["0.25", "hit\n", "a\nb", ""] { peer.send(text) }
        peer.sendBinary(Array("0.75\r\n".utf8))  // binary も UTF-8 として読む
        let received = await collect(server, count: 5)
        #expect(received == ["0.25", "hit", "a\nb", "", "0.75"])
        #expect(server.lastArrival != nil)
        #expect(server.report == SourceReport(name: "websocket :0", state: .running, lastArrival: server.lastArrival))
        #expect(told.lines.isEmpty)
    }

    @Test("UTF-8 として読めない 1 通は捨てて数え、前後の 1 通は届く")
    func unreadableIsDiscardedAndCounted() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peer = WebSocketClient(port: port)
        defer { peer.close() }
        #expect(await clients(server, reach: 1))

        peer.send("before")
        peer.sendBinary([0x68, 0xFF, 0xFE])
        peer.send("after")
        #expect(await collect(server, count: 2) == ["before", "after"])
        #expect(await until { server.input.unreadable == 1 })
    }

    // MARK: - 書く

    @Test("write は繋いでいる相手全員へ、1 回ごとに 1 通の text として届く")
    func writeReachesEveryClient() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let first = WebSocketClient(port: port)
        defer { first.close() }
        let second = WebSocketClient(port: port)
        defer { second.close() }
        #expect(await clients(server, reach: 2))

        server.write("hit")
        server.write("size 0.5\n")
        #expect(await until { first.received.count == 2 && second.received.count == 2 })
        #expect(first.received == ["hit", "size 0.5\n"])
        #expect(second.received == ["hit", "size 0.5\n"])
        #expect(told.lines.isEmpty)
    }

    @Test("相手が切れたら clientCount が減り、相手が居ないときの write は 1 度だけ知らせる")
    func disconnectedClientsAreForgotten() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peer = WebSocketClient(port: port)
        #expect(await clients(server, reach: 1))
        peer.close()
        #expect(await clients(server, reach: 0))
        #expect(server.state == .running)  // 受け口は開いたまま。次の相手を待つ

        server.write("a")
        server.write("b")
        #expect(told.count(containing: "No client is connected to the server on port 0") == 1)

        let next = WebSocketClient(port: port)
        defer { next.close() }
        #expect(await clients(server, reach: 1))
        server.write("c")
        #expect(await until { next.received == ["c"] })
    }

    @Test("止めたら相手は切れ、state は stopped・clientCount は 0 になる")
    func stopEndsEverything() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        let peer = WebSocketClient(port: port)
        defer { peer.close() }
        #expect(await clients(server, reach: 1))

        server.close()
        #expect(server.state == .stopped)
        #expect(server.clientCount == 0)
        #expect(await until { peer.closedByPeer })
    }

    // MARK: - 注入

    @Test("同じ文字列の列は、ポートで受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let (live, port) = try await listening(told: told)
        defer { live.close() }
        let peer = WebSocketClient(port: port)
        defer { peer.close() }
        #expect(await clients(live, reach: 1))
        for text in textScript { peer.send(text) }
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
    }

    // MARK: - ポートが使えないとき

    @Test("ポートを他が握っていれば unavailable と 1 度だけ知らせ、空けば受け始める")
    func portInUseWaitsUntilFreed() async throws {
        let told = Told()
        let holder = try PortHolder(port: 0, stream: true)
        let port = holder.port
        let source = StreamSource(
            kind: .webSocket, port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let server = Server(
            port: port, name: "websocket :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        defer { server.close() }

        #expect(await until { told.count(containing: "WebSocket cannot listen on port \(port) because another app is using it") == 1 })
        #expect(server.state == .unavailable)
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)

        holder.release()
        #expect(await until { server.state == .running })
        let peer = WebSocketClient(port: port)
        defer { peer.close() }
        peer.send("back")
        #expect(await collect(server, count: 1) == ["back"])
    }

    // MARK: - 作る口

    @Test("ポートの番号が 1〜65535 の外なら、作るときに投げる")
    func creationRefusesUnusablePorts() throws {
        let sketch = IdleSketch()
        #expect(throws: NetworkFailure.invalidPort(0)) { try sketch.createWebSocketServer(0) }
        #expect(throws: NetworkFailure.invalidPort(-1)) { try sketch.createWebSocketServer(-1) }
        let edge = try sketch.createWebSocketServer(65535)
        #expect(edge.port == 65535)
        #expect(edge.state == .unavailable)
        #expect(edge.report?.name == "websocket :65535")
        #expect((edge.source as? StreamSource)?.kind == .webSocket)
    }
}
