// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// 外のサーバへ繋ぎに行く入り口・TCP と WebSocket (#2470)。GPU は要らない。通信は 127.0.0.1 だけで行い、
/// 相手のサーバは mokume 自身の ``TCPServer``・``WebSocketServer`` が務める。
///
/// **繋ぎ直しの間隔を縮める** (`retryAfter` を 0.05 秒に) — 製品の間隔は固定の 1 秒で、検査が毎回
/// 秒単位で待たないため。**待つ側が期限を持つ** (`until`・AGENTS.md「待ちを含む検査を書く」)。
@Suite("TCP・WebSocket のクライアント", .serialized)
struct StreamClientTests {
    private static let retry = 0.05
    /// 製品の既定は 5 秒。応えない相手を待つ検査が秒単位で待たないよう縮める。
    private static let giveUp = 0.3

    // MARK: - 道具

    private func tcpServer(told: Told, port: Int = 0) async throws -> (server: TCPServer, port: Int) {
        let source = StreamSource(
            kind: .tcp, port: port, host: "127.0.0.1", retryAfter: Self.retry, warn: told.append)
        let server = TCPServer(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        return (server, try await boundPort(of: server, source: source))
    }

    private func webSocketServer(told: Told, port: Int = 0) async throws -> (server: WebSocketServer, port: Int) {
        let source = StreamSource(
            kind: .webSocket, port: port, host: "127.0.0.1", retryAfter: Self.retry, warn: told.append)
        let server = WebSocketServer(
            port: port, name: "websocket :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        return (server, try await boundPort(of: server, source: source))
    }

    private func tcpClient(port: Int, told: Told) -> TCPClient {
        let target = "127.0.0.1:\(port)"
        let source = ClientSource(
            kind: .tcp,
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!),
            target: target, retryAfter: Self.retry, connectTimeout: Self.giveUp, warn: told.append)
        return TCPClient(
            target: target, name: "tcp client \(target)", source: source, clients: source,
            owner: nil, warn: told.append)
    }

    private func webSocketClient(url: String, told: Told) throws -> WebSocketClient {
        let parsed = try #require(Endpoint.webSocketURL(url))
        let source = ClientSource(
            kind: .webSocket, endpoint: .url(parsed.url), secure: parsed.secure, target: url,
            retryAfter: Self.retry, connectTimeout: Self.giveUp, warn: told.append)
        return WebSocketClient(
            target: url, name: "websocket client \(url)", source: source, clients: source,
            owner: nil, warn: told.append)
    }

    /// 誰も待っていないポート。**番号を手放さずに握る** — 握っている間は他が同じ番号を取れず、そこへ繋ぐ相手は
    /// 返事をもらえない (`listen` しない socket は SYN を捨てる)。番号を選んで手放してから狙う形は、手放して
    /// から狙うまでの間に、並んで走る別の検査のサーバがその番号を取りうる (#2359 と同じ隙間)。サーバを
    /// 立てるときに ``VacantPort/release()`` で手放す。
    private func vacantPort() throws -> VacantPort {
        try VacantPort()
    }

    // MARK: - TCP

    @Test("write はサーバの messages に届き、サーバの write はクライアントの messages に届く")
    func tcpExchangesBothWays() async throws {
        let told = Told()
        let (server, port) = try await tcpServer(told: told)
        defer { server.close() }
        let client = tcpClient(port: port, told: told)
        try client.open()
        defer { client.close() }
        #expect(await until { client.state == .running })
        #expect(await clients(server, reach: 1))

        client.write("0.3\n")
        client.write("hit\n")
        #expect(await collect(server, count: 2) == ["0.3", "hit"])

        server.write("0.")
        server.write("75\nback\n")
        #expect(await collect(client, count: 2) == ["0.75", "back"])
        #expect(client.lastArrival != nil)
        #expect(client.report == SourceReport(name: "tcp client 127.0.0.1:\(port)", state: .running, lastArrival: client.lastArrival))
        #expect(told.lines.isEmpty)
    }

    /// 相手を止めると disconnected、相手が戻れば running に戻る。繋ぎ直しは決まった間隔で、設定する口は無い。
    @Test("サーバが止まると disconnected、サーバが戻ると running に戻って、また届く")
    func tcpReconnectsWhenTheServerReturns() async throws {
        let told = Told()
        let (first, port) = try await tcpServer(told: told)
        let client = tcpClient(port: port, told: told)
        try client.open()
        defer { client.close() }
        #expect(await until { client.state == .running })

        first.close()
        #expect(await until { client.state == .disconnected })
        #expect(told.count(containing: "lost the connection") == 1)

        // 番号を手放した直後に立て直す (並んで走る別の検査に番号を取られる隙間を狭くする)
        let (second, again) = try await tcpServer(told: told, port: port)
        defer { second.close() }
        #expect(again == port)
        #expect(await until { client.state == .running })
        #expect(await clients(second, reach: 1))
        client.write("back\n")
        #expect(await collect(second, count: 1) == ["back"])

        // 戻った後にまた切れたら、また知らせる (繋がったときに忘れる)
        second.close()
        #expect(await until { client.state == .disconnected })
        #expect(told.count(containing: "lost the connection") == 2)
    }

    @Test("サーバが居ない間は unavailable と 1 度だけ知らせ、居るようになったら繋ぐ")
    func tcpWaitsForAServerThatIsNotThereYet() async throws {
        let told = Told()
        let holder = try vacantPort()
        defer { holder.release() }
        let port = holder.port
        let client = tcpClient(port: port, told: told)
        try client.open()
        defer { client.close() }

        #expect(await until { told.count(containing: "TCP client cannot connect to 127.0.0.1:\(port)") == 1 })
        #expect(client.state == .unavailable)
        // 繋ぎ直しを何度か重ねても (期限 + 間隔で 3 回ほど)、知らせは増えない
        try await Task.sleep(for: .milliseconds(1000))
        #expect(told.count(containing: "cannot connect") == 1)
        #expect(client.state == .unavailable)

        holder.release()
        let (server, _) = try await tcpServer(told: told, port: port)
        defer { server.close() }
        #expect(await until { client.state == .running })
        #expect(await clients(server, reach: 1))
        server.write("hello\n")
        #expect(await collect(client, count: 1) == ["hello"])
    }

    @Test("繋がっていない間の write は 1 度だけ知らせて捨て、繋がった後に届かない。繋がれば、また言えるように戻る")
    func tcpWriteWhileNotConnectedIsDropped() async throws {
        let told = Told()
        let holder = try vacantPort()
        defer { holder.release() }
        let port = holder.port
        let client = tcpClient(port: port, told: told)
        try client.open()
        defer { client.close() }
        client.write("lost-1\n")
        client.write("lost-2\n")
        #expect(told.count(containing: "The TCP client is not connected to 127.0.0.1:\(port)") == 1)
        #expect(told.count(containing: "\"lost-1\\n\"") == 1)

        holder.release()
        let (server, _) = try await tcpServer(told: told, port: port)
        defer { server.close() }
        #expect(await until { client.state == .running })
        #expect(await clients(server, reach: 1))
        client.write("kept\n")
        // 繋がる前に書いたものは届かない
        #expect(await collect(server, count: 1) == ["kept"])

        server.close()
        #expect(await until { client.state == .disconnected })
        client.write("again\n")
        #expect(told.count(containing: "is not connected to") == 2)
    }

    @Test("止めたら state は stopped で、繋ぎ直さず、write は 1 度だけ知らせる")
    func tcpStopEndsEverything() async throws {
        let told = Told()
        let (server, port) = try await tcpServer(told: told)
        defer { server.close() }
        let client = tcpClient(port: port, told: told)
        try client.open()
        #expect(await until { client.state == .running })
        #expect(await clients(server, reach: 1))

        client.close()
        #expect(client.state == .stopped)
        #expect(client.messages.isEmpty)
        #expect(await clients(server, reach: 0))
        // 繋ぎ直さない
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.connected == 0)
        client.write("late\n")
        client.write("later\n")
        #expect(told.count(containing: "This TCP client is stopped") == 1)
    }

    @Test("UTF-8 として読めない行は捨てて数え、前後の行は届く")
    func tcpUnreadableLinesAreCounted() async throws {
        let told = Told()
        let (server, port) = try await tcpServer(told: told)
        defer { server.close() }
        let client = tcpClient(port: port, told: told)
        try client.open()
        defer { client.close() }
        #expect(await until { client.state == .running })
        #expect(await clients(server, reach: 1))

        server.write("before\n")
        // 'h' と、UTF-8 に現れないバイトは文字列では書けないので、別の読めない行 (長すぎる行) で見る
        server.write(String(repeating: "a", count: StreamListener.lineLimit + 10) + "\n")
        server.write("after\n")
        #expect(await collect(client, count: 2) == ["before", "after"])
        #expect(await until { client.input.unreadable == 1 })
    }

    // MARK: - WebSocket

    @Test("send はサーバの messages に 1 通ずつ届き、サーバの send はクライアントの messages に届く")
    func webSocketExchangesBothWays() async throws {
        let told = Told()
        let (server, port) = try await webSocketServer(told: told)
        defer { server.close() }
        let client = try webSocketClient(url: "ws://127.0.0.1:\(port)/room?id=3", told: told)
        try client.open()
        defer { client.close() }
        #expect(await until { client.state == .running })
        #expect(await clients(server, reach: 1))

        client.send("0.25")
        client.send("hit")
        #expect(await collect(server, count: 2) == ["0.25", "hit"])
        server.send("0.75")
        server.send("fade")
        #expect(await collect(client, count: 2) == ["0.75", "fade"])
        #expect(told.lines.isEmpty)
    }

    @Test("サーバが止まると disconnected、サーバが戻ると running に戻る")
    func webSocketReconnectsWhenTheServerReturns() async throws {
        let told = Told()
        let (first, port) = try await webSocketServer(told: told)
        let client = try webSocketClient(url: "ws://127.0.0.1:\(port)", told: told)
        try client.open()
        defer { client.close() }
        #expect(await until { client.state == .running })

        first.close()
        #expect(await until { client.state == .disconnected })
        #expect(told.count(containing: "WebSocket client lost the connection") >= 1)

        let (second, _) = try await webSocketServer(told: told, port: port)
        defer { second.close() }
        #expect(await until { client.state == .running })
        #expect(await clients(second, reach: 1))
        client.send("back")
        #expect(await collect(second, count: 1) == ["back"])
    }

    /// `wss://` は TLS の上で繋ぐ。TLS を話さない相手 (ここでは平文の WebSocket サーバ) には、
    /// 握手が成り立たず繋がらない — 暗号化の無い繋ぎへ黙って倒れない。
    @Test("wss:// は TLS で繋ぐので、平文のサーバには繋がらない")
    func secureSocketDoesNotFallBackToPlainText() async throws {
        let told = Told()
        let (server, port) = try await webSocketServer(told: told)
        defer { server.close() }
        let client = try webSocketClient(url: "wss://127.0.0.1:\(port)/room", told: told)
        try client.open()
        defer { client.close() }

        #expect(await until { told.count(containing: "WebSocket client cannot connect to wss://127.0.0.1:\(port)/room") >= 1 })
        #expect(client.state == .unavailable)
        #expect(server.connected == 0)
    }

    @Test("繋がっていない間の send は 1 度だけ知らせて捨てる")
    func webSocketSendWhileNotConnected() async throws {
        let told = Told()
        let holder = try vacantPort()
        defer { holder.release() }
        let port = holder.port
        let client = try webSocketClient(url: "ws://127.0.0.1:\(port)", told: told)
        try client.open()
        defer { client.close() }
        client.send("a")
        client.send("b")
        #expect(told.count(containing: "The WebSocket client is not connected to ws://127.0.0.1:\(port)") == 1)
    }

    // MARK: - 注入

    @Test("記録した列を流す入り口には繋ぐ先が無い。write・send は 1 度だけ知らせて何も書かない")
    func recordedClientsHaveNoServer() throws {
        let told = Told()
        let tcp = TCPClient(
            target: "tcp client (recorded)", name: "tcp client (recorded)",
            source: RecordedSource<String>(batches: [["a"], [], ["b", "c"]]), clients: nil, owner: nil,
            warn: told.append)
        try tcp.open()
        var replayed: [String] = []
        for _ in 0..<3 {
            tcp.supply()
            replayed += tcp.messages
        }
        #expect(replayed == ["a", "b", "c"])
        #expect(tcp.state == .running)
        #expect(tcp.port == nil)
        tcp.write("x")
        tcp.write("y")
        #expect(told.count(containing: "This TCP client replays recorded messages and has no server") == 1)

        let socket = WebSocketClient(
            target: "websocket client (recorded)", name: "websocket client (recorded)",
            source: RecordedSource<String>(batches: [["a"]]), clients: nil, owner: nil,
            warn: told.append)
        try socket.open()
        socket.send("x")
        socket.send("y")
        #expect(told.count(containing: "This WebSocket client replays recorded messages and has no server") == 1)
    }

    @Test("同じ列は、サーバから受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let (server, port) = try await tcpServer(told: told)
        defer { server.close() }
        let client = tcpClient(port: port, told: told)
        try client.open()
        defer { client.close() }
        #expect(await until { client.state == .running })
        #expect(await clients(server, reach: 1))
        server.write(textScript.map { $0 + "\n" }.joined())
        let received = await collect(client, count: textScript.count)

        let injected = IdleSketch().createTCPClient(messages: textScript.map { [$0] })
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

    // MARK: - 作る口

    @Test("値が使えなければ、繋ぐ前に投げる。走っていない所からは notRunning を投げる")
    func creationRefusesUnusableValues() {
        let sketch = IdleSketch()
        OutsideRun.$current.withValue(OutsideRun()) {
            #expect(throws: NetworkFailure.invalidPort(0)) { try sketch.createTCPClient("127.0.0.1", 0) }
            #expect(throws: NetworkFailure.invalidPort(65536)) { try sketch.createTCPClient("127.0.0.1", 65536) }
            #expect(throws: NetworkFailure.invalidHost("")) { try sketch.createTCPClient("", 7000) }
            #expect(throws: NetworkFailure.invalidHost("  ")) { try sketch.createTCPClient("  ", 7000) }
            for bad in ["", "relay.example", "http://relay.example", "ws://", "ws:///room", "wss:"] {
                #expect(throws: NetworkFailure.invalidHost(bad), "\(bad)") {
                    try sketch.createWebSocketClient(bad)
                }
            }
            #expect(throws: NetworkFailure.invalidPort(0)) { try sketch.createWebSocketClient("ws://127.0.0.1:0") }
            // 使える値は、走っていないので繋ぐ前に断る (#2740)
            #expect(throws: NetworkFailure.notRunning(call: "createTCPClient(_:_:)")) {
                try sketch.createTCPClient("127.0.0.1", 7000)
            }
            #expect(throws: NetworkFailure.notRunning(call: "createWebSocketClient(_:)")) {
                try sketch.createWebSocketClient("ws://127.0.0.1:8025")
            }
            #expect(throws: NetworkFailure.notRunning(call: "createWebSocketClient(_:)")) {
                try sketch.createWebSocketClient("WSS://relay.example/room")
            }
        }
    }

    /// 返事をしない相手 (SYN を捨てる機械・握手に答えないサーバ) に張り付かず、期限で諦めて繋ぎ直す。
    /// 期限が無いと OS の既定 (1 分以上) か永久に待ち、その間は繋ぎ直しの間隔が働かない。
    @Test("返事をしない相手には、期限で諦めて unavailable と知らせ、繋ぎ直し続ける")
    func anUnansweringServerIsGivenUpOn() async throws {
        let told = Told()
        let holder = try vacantPort()
        defer { holder.release() }
        let client = tcpClient(port: holder.port, told: told)
        try client.open()
        defer { client.close() }

        #expect(await until { told.count(containing: "no answer within 0.3 second(s)") == 1 })
        #expect(client.state == .unavailable)
        // 1 回で諦めて終わりではなく、繋ぎ直し続ける: 後からサーバが立てば繋がる
        holder.release()
        let (server, _) = try await tcpServer(told: told, port: holder.port)
        defer { server.close() }
        #expect(await until { client.state == .running })
    }

    @Test("WebSocket の URL は ws:// か wss:// で、ホストが在る綴りだけ受ける")
    func webSocketURLsAreChecked() throws {
        let plain = try #require(Endpoint.webSocketURL("ws://127.0.0.1:8025/room?id=3"))
        #expect(plain.secure == false)
        #expect(plain.port == 8025)
        #expect(plain.url.absoluteString == "ws://127.0.0.1:8025/room?id=3")
        let secure = try #require(Endpoint.webSocketURL("WSS://relay.example/room"))
        #expect(secure.secure)
        #expect(secure.port == nil)
        #expect(Endpoint.webSocketURL("http://relay.example") == nil)
        #expect(Endpoint.webSocketURL("relay.example") == nil)
        #expect(Endpoint.webSocketURL("ws://") == nil)
    }
}


/// 127.0.0.1 の TCP の番号を握るだけで、`listen` しない socket。**握っている間は他が同じ番号を取れず、
/// そこへ繋ぐ相手は返事をもらえない** (macOS は SYN を捨てる)。``PortHolder`` は stream のときに `listen`
/// するので、「返事が無い」を作るには使えない。
nonisolated final class VacantPort: Sendable {
    let port: Int
    private let descriptor: Int32
    private let held = Mutex(true)

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PortHolder.Failure(call: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw PortHolder.Failure(call: "bind", code: code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            close(descriptor)
            throw PortHolder.Failure(call: "getsockname", code: code)
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// 手放す。2 度目からは何もしない。
    func release() {
        guard held.withLock({ held in defer { held = false }; return held }) else { return }
        close(descriptor)
    }
}
