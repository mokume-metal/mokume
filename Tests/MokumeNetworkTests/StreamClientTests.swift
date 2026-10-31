// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeDiagnostics
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
        return (server, try await boundPort(of: server, source: source, told: told))
    }

    private func webSocketServer(told: Told, port: Int = 0) async throws -> (server: WebSocketServer, port: Int) {
        let source = StreamSource(
            kind: .webSocket, port: port, host: "127.0.0.1", retryAfter: Self.retry, warn: told.append)
        let server = WebSocketServer(
            port: port, name: "websocket :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        return (server, try await boundPort(of: server, source: source, told: told))
    }

    private func tcpClient(
        port: Int, told: Told,
        unsatisfiedReason: @escaping @Sendable (NWConnection) -> NWPath.UnsatisfiedReason? =
            StreamConnector.currentPathReason
    ) -> TCPClient {
        let target = "127.0.0.1:\(port)"
        let source = ClientSource(
            kind: .tcp,
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!),
            target: target, retryAfter: Self.retry, connectTimeout: Self.giveUp,
            unsatisfiedReason: unsatisfiedReason, warn: told.append)
        return TCPClient(
            target: target, name: "tcp client \(target)", source: source, clients: source,
            owner: nil, warn: told.append)
    }

    private func webSocketClient(
        url: String, told: Told,
        unsatisfiedReason: @escaping @Sendable (NWConnection) -> NWPath.UnsatisfiedReason? =
            StreamConnector.currentPathReason
    ) throws -> WebSocketClient {
        let parsed = try #require(Endpoint.webSocketURL(url))
        let source = ClientSource(
            kind: .webSocket, endpoint: .url(parsed.url), secure: parsed.secure, target: url,
            retryAfter: Self.retry, connectTimeout: Self.giveUp,
            unsatisfiedReason: unsatisfiedReason, warn: told.append)
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
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(server, from: client, told: told)

        client.write("0.3\n")
        client.write("hit\n")
        #expect(try await requireCollected(server, count: 2) == ["0.3", "hit"])

        server.write("0.")
        server.write("75\nback\n")
        #expect(try await requireCollected(client, count: 2) == ["0.75", "back"])
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
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }

        first.close()
        try await requireState(.disconnected, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        #expect(told.count(containing: "lost the connection") == 1)

        // 番号を手放した直後に立て直す (並んで走る別の検査に番号を取られる隙間を狭くする)
        let (second, again) = try await tcpServer(told: told, port: port)
        defer { second.close() }
        #expect(again == port)
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(second, from: client, told: told)
        client.write("back\n")
        #expect(try await requireCollected(second, count: 1) == ["back"])

        // 戻った後にまた切れたら、また知らせる (繋がったときに忘れる)
        second.close()
        try await requireState(.disconnected, what: "繋ぎ", told: told, tracing: client.source) { client.state }
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

        try await requireTold(containing: "TCP client cannot connect to 127.0.0.1:\(port)", told: told, tracing: client.source) { client.state }
        #expect(client.state == .unavailable)
        // 繋ぎ直しを何度か重ねても (期限 + 間隔で 3 回ほど)、知らせは増えない
        try await Task.sleep(for: .milliseconds(1000))
        #expect(told.count(containing: "cannot connect") == 1)
        #expect(client.state == .unavailable)

        holder.release()
        let (server, _) = try await tcpServer(told: told, port: port)
        defer { server.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(server, from: client, told: told)
        server.write("hello\n")
        #expect(try await requireCollected(client, count: 1) == ["hello"])
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
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(server, from: client, told: told)
        client.write("kept\n")
        // 繋がる前に書いたものは届かない
        #expect(try await requireCollected(server, count: 1) == ["kept"])

        server.close()
        try await requireState(.disconnected, what: "繋ぎ", told: told, tracing: client.source) { client.state }
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
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(server, from: client, told: told)

        client.close()
        #expect(client.state == .stopped)
        #expect(client.messages.isEmpty)
        try await requireCounted(server, count: 0, told: told, what: "クライアントを閉じても、受け口の数が 0 に戻らなかった") {
            "クライアント: 状態 \(client.state.rawValue)"
        }
        // 繋ぎ直さない
        try await Task.sleep(for: .milliseconds(300))
        server.supply()  // connected は supply (取り出し) でしか書き換わらない。読む前に回す
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
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(server, from: client, told: told)

        server.write("before\n")
        // 'h' と、UTF-8 に現れないバイトは文字列では書けないので、別の読めない行 (長すぎる行) で見る
        server.write(String(repeating: "a", count: StreamListener.lineLimit + 10) + "\n")
        server.write("after\n")
        #expect(try await requireCollected(client, count: 2) == ["before", "after"])
        try await requireWait(
            "読めない行が 1 つと数えられなかった", detail: { "数えた数: \(client.input.unreadable)" }
        ) {
            client.input.unreadable == 1
        }
    }

    // MARK: - ローカルネットワークの許可が無いときの名乗り (#3593)

    /// 許可が無いとき `NWConnection` は拒まれたと言わず、`ENETDOWN` で待ち、経路の理由にだけ
    /// `.localNetworkDenied` を出す (#2224 の実測)。本物の許可の拒否はこの機械で起こせないので、経路の理由だけを
    /// 差し替えて、繋ぎが `.waiting` になる実物の経路 (閉じたサーバへの繋ぎ直し) を通す。
    @Test("経路の理由が localNetworkDenied なら読み替えは denied、他の理由・理由なしなら、いまどおりエラーで読む")
    func waitingIsReadAsDeniedOnlyForALocalNetworkDenial() {
        let down = NWError.posix(.ENETDOWN)
        #expect(StreamConnector.event(waiting: down, unsatisfiedReason: .localNetworkDenied) == .denied)
        #expect(
            StreamConnector.event(waiting: down, unsatisfiedReason: .notAvailable)
                == .failed(Diagnostics.posixReason(ENETDOWN)))
        #expect(
            StreamConnector.event(waiting: down, unsatisfiedReason: nil)
                == .failed(Diagnostics.posixReason(ENETDOWN)))
        // 許可の理由が付いているなら、エラーが何でも許可の話である
        #expect(
            StreamConnector.event(waiting: NWError.posix(.ECONNREFUSED), unsatisfiedReason: .localNetworkDenied)
                == .denied)
        // `.failed` の読み替え (理由を取らない) は変えない
        #expect(StreamConnector.event(for: down) == .failed(Diagnostics.posixReason(ENETDOWN)))
    }

    @Test("TCP: 許可が無くて繋ぎ直せないとき state は denied で、許可の直し方を 1 度だけ知らせる")
    func tcpIsDeniedWhenTheLocalNetworkIsDenied() async throws {
        let told = Told()
        let (server, port) = try await tcpServer(told: told)
        let client = tcpClient(port: port, told: told, unsatisfiedReason: { _ in .localNetworkDenied })
        try client.open()
        defer { client.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }

        // サーバが居なくなった後の繋ぎ直しは拒まれて `.waiting` になる。その経路の理由が許可の拒否
        server.close()
        try await requireState(.denied, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireTold(
            containing: "TCP client to 127.0.0.1:\(port) is blocked by macOS (Local Network)", told: told,
            tracing: client.source) { client.state }
        try await Task.sleep(for: .milliseconds(600))
        #expect(client.state == .denied)
        #expect(told.count(containing: "blocked by macOS (Local Network)") == 1)
        #expect(told.count(containing: "cannot connect") == 0)
        // クライアントは自動で繋ぎ直す。受け口の文面 (スケッチを始め直す) を言わない
        #expect(told.count(containing: "connects at the next retry") == 1)
        #expect(told.count(containing: "start the sketch again") == 0)
    }

    @Test("TCP: 拒まれていない繋げなさ (理由が許可でない) は denied にならず、いまどおり disconnected と cannot connect")
    func tcpIsNotDeniedWhenThePathReasonIsNotLocalNetwork() async throws {
        let told = Told()
        let (server, port) = try await tcpServer(told: told)
        let client = tcpClient(port: port, told: told, unsatisfiedReason: { _ in .notAvailable })
        try client.open()
        defer { client.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }

        server.close()
        try await requireTold(
            containing: "TCP client cannot connect to 127.0.0.1:\(port)", told: told, tracing: client.source) {
                client.state
            }
        #expect(client.state == .disconnected)
        #expect(told.count(containing: "blocked by macOS") == 0)
    }

    @Test("WebSocket: 許可が無くて繋ぎ直せないとき state は denied で、許可の直し方を 1 度だけ知らせる")
    func webSocketIsDeniedWhenTheLocalNetworkIsDenied() async throws {
        let told = Told()
        let (server, port) = try await webSocketServer(told: told)
        let url = "ws://127.0.0.1:\(port)/room"
        let client = try webSocketClient(url: url, told: told, unsatisfiedReason: { _ in .localNetworkDenied })
        try client.open()
        defer { client.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }

        server.close()
        try await requireState(.denied, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireTold(
            containing: "WebSocket client to \(url) is blocked by macOS (Local Network)", told: told,
            tracing: client.source) { client.state }
        try await Task.sleep(for: .milliseconds(600))
        #expect(told.count(containing: "blocked by macOS (Local Network)") == 1)
    }

    // MARK: - 繋ぎに行く側の前提が満たされなかった回の名乗り (#3104)

    @Test("受け口が相手を数えなければ、受け口とクライアントの状態・移り変わり・数と、知らせの全行を名乗って 1 つで止まる。数えれば何も言わない")
    func requireClientsNamesBothSidesAndStops() async throws {
        let told = Told()
        let (server, port) = try await tcpServer(told: told)
        defer { server.close() }

        // 数える形: 繋がれば、何も言わずに通る
        let connected = tcpClient(port: port, told: told)
        try connected.open()
        defer { connected.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: connected.source) { connected.state }
        try await requireClients(server, from: connected, told: told)

        // 繋がっている 1 人を 2 人と数えてほしい形: 数えたのは 1 人と名乗る
        let short = try await said {
            try await requireClients(server, reach: 2, from: connected, told: told, within: 0.3)
        }
        #expect(short.contains("相手 2 人のうち、受け口が数えたのは 1 人 (待った "), "名乗り: \(short)")
        #expect(short.contains("/期限 0.3 秒)"), "名乗り: \(short)")
        #expect(short.contains("受け口: 状態 running・移り変わり "), "名乗り: \(short)")
        // 見えないものも、名乗りに書く (受け口が数えるのは .ready の繋ぎだけ)
        #expect(short.contains("受け入れたがまだ .ready でない繋ぎの数と、failed・cancelled で外した回は、ここからは見えない"), "名乗り: \(short)")
        #expect(short.contains("クライアント: 状態 running・移り変わり "), "名乗り: \(short)")

        // 誰も待っていないポートへ繋ぎに行くクライアント (作り物の相手): 繋がらず、受け口は 0 人と数える
        let holder = try vacantPort()
        defer { holder.release() }
        let lost = tcpClient(port: holder.port, told: told)
        try lost.open()
        defer { lost.close() }
        try await requireTold(
            containing: "TCP client cannot connect to 127.0.0.1:\(holder.port)", told: told,
            tracing: lost.source) { lost.state }
        let (alone, _) = try await tcpServer(told: told)
        defer { alone.close() }
        let text = try await said {
            try await requireClients(alone, from: lost, told: told, within: 0.3)
        }
        #expect(text.contains("相手 1 人のうち、受け口が数えたのは 0 人 (待った "), "名乗り: \(text)")
        // 受け口側: 状態と、移り変わりの数・最後
        #expect(text.contains("受け口: 状態 running・移り変わり 1 回・最後: ready(port: "), "名乗り: \(text)")
        // クライアント側: 状態と、移り変わりの数・最後 (繋げなかったので unavailable)
        #expect(text.contains("クライアント: 状態 unavailable・移り変わり "), "名乗り: \(text)")
        // 知らせの全行 (クライアントの「繋げない」も載る。ラベルで見分ける)
        #expect(text.contains("TCP client cannot connect to 127.0.0.1:\(holder.port)"), "名乗り: \(text)")

        // 受け口が閉じた形は、受け口の状態で読み分けられる
        alone.close()
        let closed = try await said {
            try await requireClients(alone, from: connected, told: told, within: 0.3)
        }
        #expect(closed.contains("受け口: 状態 stopped"), "名乗り: \(closed)")
    }

    /// 読むたびに 0・1・2… と数える作り物の受け口の相手の数。
    private nonisolated final class CountingClients: Broadcasting, @unchecked Sendable {
        private let reads = Mutex(0)
        var clientCount: Int { reads.withLock { value in defer { value += 1 }; return value } }
        /// これまで数を読まれた回数。
        var readCount: Int { reads.withLock { $0 } }
        func broadcast(_ text: String) {}
    }

    @Test("名乗る数は止まると決めた時点のもので、名乗りの前に読み直さない。待った秒数も名乗る")
    func requireCountedNamesTheValueItDecidedOn() async throws {
        let counting = CountingClients()
        let server = TextPort(
            port: nil, name: "counting", source: RecordedSource<String>(batches: [[]]),
            clients: counting, owner: nil, warn: { _ in })
        try server.open()
        let text = try await said {
            try await requireCounted(
                server, count: 1_000_000, within: 0.1, told: nil, what: "数えなかった", others: { "相手側" })
        }
        // 期限の後の最後の 1 回まで読んだ数が、名乗りの数。名乗りのために読み直していない
        let reads = counting.readCount
        #expect(text.contains("数えたのは \(reads - 1) 人 (待った "), "名乗り: \(text) (読んだ回数 \(reads))")
        #expect(text.contains("/期限 0.1 秒)"), "名乗り: \(text)")
        #expect(text.contains("同じ told の全行: 知らせを持たない"), "名乗り: \(text)")
        #expect(text.contains("相手側"), "名乗り: \(text)")
    }

    @Test("満たしたときは取り出しを足さない。受け口の届き物を次の読みの前に捨てない")
    func requireCountedDoesNotSupplyAfterBeingMet() async throws {
        let server = TextPort(
            port: nil, name: "recorded", source: RecordedSource<String>(batches: [["a"], ["b"]]),
            clients: nil, owner: nil, warn: { _ in })
        try server.open()
        // 数は最初から 0 で、1 回の取り出しで満たす。もう 1 回回すと、届き物は ["b"] に替わる
        try await requireCounted(server, count: 0, told: Told(), what: "数えなかった", others: { "" })
        #expect(server.messages == ["a"])
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
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(server, from: client, told: told)

        client.send("0.25")
        client.send("hit")
        #expect(try await requireCollected(server, count: 2) == ["0.25", "hit"])
        server.send("0.75")
        server.send("fade")
        #expect(try await requireCollected(client, count: 2) == ["0.75", "fade"])
        #expect(told.lines.isEmpty)
    }

    @Test("サーバが止まると disconnected、サーバが戻ると running に戻る")
    func webSocketReconnectsWhenTheServerReturns() async throws {
        let told = Told()
        let (first, port) = try await webSocketServer(told: told)
        let client = try webSocketClient(url: "ws://127.0.0.1:\(port)", told: told)
        try client.open()
        defer { client.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }

        first.close()
        try await requireState(.disconnected, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        #expect(told.count(containing: "WebSocket client lost the connection") >= 1)

        let (second, _) = try await webSocketServer(told: told, port: port)
        defer { second.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(second, from: client, told: told)
        client.send("back")
        #expect(try await requireCollected(second, count: 1) == ["back"])
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

        try await requireTold(containing: "WebSocket client cannot connect to wss://127.0.0.1:\(port)/room", count: 1, exactly: false, told: told, tracing: client.source) { client.state }
        #expect(client.state == .unavailable)
        server.supply()  // connected は supply (取り出し) でしか書き換わらない
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
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
        try await requireClients(server, from: client, told: told)
        server.write(textScript.map { $0 + "\n" }.joined())
        let received = try await requireCollected(client, count: textScript.count)

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

        try await requireTold(containing: "no answer within 0.3 second(s)", told: told, tracing: client.source) { client.state }
        #expect(client.state == .unavailable)
        // 1 回で諦めて終わりではなく、繋ぎ直し続ける: 後からサーバが立てば繋がる
        holder.release()
        let (server, _) = try await tcpServer(told: told, port: holder.port)
        defer { server.close() }
        try await requireState(.running, what: "繋ぎ", told: told, tracing: client.source) { client.state }
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
