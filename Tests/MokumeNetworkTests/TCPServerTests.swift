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

/// 作り物の受け口の繋ぎの台帳 (#2940)。通信の揺れを入れずに、束の補助が相手をどう扱うかを確かめる。
/// 繋がった相手の数だけを持つ。
nonisolated final class ScriptedRoom: Broadcasting, Sendable {
    private let count = Mutex(0)
    var clientCount: Int { count.withLock { $0 } }
    func broadcast(_ text: String) {}
    func join() { count.withLock { $0 += 1 } }
    func leave() { count.withLock { $0 -= 1 } }

    /// この台帳を数える入り口。
    @MainActor
    func server() throws -> TCPServer {
        let server = TCPServer(
            port: nil, name: "tcp (scripted)", source: RecordedSource<String>(batches: []),
            clients: self, owner: nil, warn: { _ in })
        try server.open()
        return server
    }
}

/// 作り物の相手 (#2940)。**本物の繋ぎは使わない** — 本物は負荷で名乗ることがあり、替えた回数が揺れる。
///
/// `script` の状態で作られる。繋がる (`.ready`) 相手は、作られたとき台帳に加わり、閉じられたとき外れる。
nonisolated final class ScriptedPeer: LoopbackPeer {
    let state: PeerState
    private let room: ScriptedRoom
    private let closed = Mutex(false)

    init(_ state: PeerState, in room: ScriptedRoom) {
        self.state = state
        self.room = room
        if state == .ready { room.join() }
    }

    var isClosed: Bool { closed.withLock { $0 } }

    func close() {
        let firstClose = closed.withLock { flag -> Bool in
            let wasOpen = !flag
            flag = true
            return wasOpen
        }
        guard firstClose else { return }
        if state == .ready { room.leave() }
    }
}

/// 繋いでくる相手を待つ入り口・TCP (#2018)。GPU は要らない。通信は 127.0.0.1 だけで行い、
/// ポートは OS が選ぶ (0 を頼む)。相手は `nc` の代わりに ``StreamClient`` が務める。
///
/// 入り口を走っているスケッチに足さず、フレームの代わりに ``TextPort/supply()`` を自分で呼ぶ。
@Suite("TCP の入り口", .serialized)
struct TCPServerTests {
    /// 127.0.0.1 の `port` (既定は OS が選ぶ) で待つ入り口を開き、受け始めるまで待つ。
    private func listening(told: Told, port: Int = 0) async throws -> (server: TCPServer, port: Int) {
        let source = StreamSource(kind: .tcp, port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let server = TCPServer(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        return (server, try await boundPort(of: server, source: source, told: told))
    }

    // MARK: - 受ける

    @Test("繋いできた相手が送った行を届いた順に受け、行の途中で切れて届いてもつなぐ")
    func receivesLinesInOrder() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peers = PeerGroup { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: server, told: told)
        let peer = peers[0]

        peer.send("0.25\nhit\r\n\n")
        peer.send("0.")
        peer.send("75\n")
        let received = try await requireCollected(server, count: 4)
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
        let peers = PeerGroup(2) { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: server, told: told)
        let (first, second) = (peers[0], peers[1])

        first.send("0.5")
        first.finish()
        #expect(try await requireCollected(server, count: 1) == ["0.5"])
        try await peers.requireCount(on: server, equals: 1, told: told)
        try await requireWait("閉じた相手の繋ぎを、受け口が閉じ返さなかった") { first.closedByPeer }

        second.close()
        try await peers.requireCount(on: server, equals: 0, told: told)
        #expect(server.state == .running)  // 受け口は開いたまま。次の相手を待つ
    }

    @Test("UTF-8 として読めない行・長すぎる行は捨てて数え、前後の行は届く")
    func unreadableLinesAreDiscardedAndCounted() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peers = PeerGroup { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: server, told: told)
        let peer = peers[0]

        peer.send("before\n")
        peer.send([0x68, 0xFF, 0x0A])  // 'h' と、UTF-8 に現れないバイト
        peer.send([UInt8](repeating: 0x61, count: StreamListener.lineLimit + 10) + [0x0A])
        peer.send("after\n")
        let received = try await requireCollected(server, count: 2)
        #expect(received == ["before", "after"])
        try await requireWait(
            "読めない行が 2 つと数えられなかった", detail: { "数えた数: \(server.input.unreadable)" }
        ) {
            server.input.unreadable == 2
        }
    }

    // MARK: - 書く

    @Test("write は繋いでいる相手全員へ、改行を足さずにそのまま書く")
    func writeReachesEveryClient() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        let peers = PeerGroup(2) { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: server, told: told)
        let (first, second) = (peers[0], peers[1])

        server.write("hit\n")
        server.write("size 0.5")
        try await requireWait(
            "2 人の相手が同じ書き込みを受け取らなかった",
            detail: { "1 人目: \(first.received.debugDescription)・2 人目: \(second.received.debugDescription)" }
        ) {
            first.received == "hit\nsize 0.5" && second.received == "hit\nsize 0.5"
        }
        #expect(told.lines.isEmpty)
    }

    @Test("相手が居ないときの write は 1 度だけ知らせ、書けたら、また言えるように戻る")
    func writeWithoutClientsIsToldOnce() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        defer { server.close() }
        server.write("a")
        server.write("b")
        #expect(told.count(containing: "No client is connected to the TCP server on port 0") == 1)
        #expect(told.count(containing: "\"a\"") == 1)

        let peers = PeerGroup { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: server, told: told)
        let peer = peers[0]
        server.write("c")
        try await requireWait("相手が書き込みを受け取らなかった", detail: { "受け取った: \(peer.received.debugDescription)" }) {
            peer.received == "c"
        }
        peer.close()
        try await peers.requireCount(on: server, equals: 0, told: told)

        server.write("d")
        server.write("e")
        #expect(told.count(containing: "No client is connected") == 2)
        #expect(told.count(containing: "\"d\"") == 1)
    }

    @Test("止めたら相手は切れ、state は stopped・clientCount は 0 で、write は 1 度だけ知らせる")
    func stopEndsEverything() async throws {
        let told = Told()
        let (server, port) = try await listening(told: told)
        let peers = PeerGroup { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: server, told: told)
        let peer = peers[0]

        server.close()
        #expect(server.state == .stopped)
        #expect(server.clientCount == 0)
        #expect(server.messages.isEmpty)
        try await requireWait("止めた受け口が相手の繋ぎを閉じなかった") { peer.closedByPeer }
        server.write("late\n")
        server.write("later\n")
        #expect(told.count(containing: "This TCP server is stopped") == 1)
        #expect(told.count(containing: "\"late\\n\"") == 1)  // 改行は \n と書いて出す
    }

    @Test("記録した列を流す入り口には相手が居ない。write は 1 度だけ知らせて何も書かない")
    func recordedServerHasNoClients() throws {
        let told = Told()
        let recorded = TCPServer(
            port: nil, name: "tcp (recorded)", source: RecordedSource<String>(batches: [["a"]]),
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
        let live = TCPServer(
            port: 5204, name: "tcp :5204", source: RecordedSource<String>(batches: []),
            clients: present, owner: nil, warn: told.append)
        try live.open()
        live.supply()
        #expect(live.clientCount == 2)
        live.write("hit\n")
        #expect(present.written == ["hit\n"])
    }

    @Test("外して足し直した (close の後に open が来る) 入り口は、また書け、受け取りも戻る。外し直せばまた 1 度だけ知らせて書かない (#3122)")
    func reopenedServerWritesAgain() throws {
        let told = Told()
        let room = RecordingBroadcaster(clientCount: 1)
        let server = TCPServer(
            port: 5204, name: "tcp :5204", source: RecordedSource<String>(batches: [["a"]]),
            clients: room, owner: nil, warn: told.append)
        try server.open()
        server.write("before")
        server.supply()
        #expect(server.messages == ["a"])

        server.close()
        #expect(server.state == .stopped)
        server.write("while closed 1")
        server.write("while closed 2")
        #expect(room.written == ["before"])
        #expect(told.count(containing: "is stopped") == 1)

        try server.open()
        #expect(server.state == .running)
        server.write("after")
        server.supply()
        #expect(server.messages == ["a"])
        #expect(room.written == ["before", "after"])

        // 外し直せば、また書かず、また 1 度だけ知らせる
        server.close()
        server.write("again")
        #expect(room.written == ["before", "after"])
        #expect(told.count(containing: "is stopped") == 2)
    }

    @Test("実行に足されていない (外で呼んだ) stop() は何も止めず、利用者が止めた印も立てない。外して足し直せば戻る (#3122)")
    func stopWithoutARunDoesNotStick() throws {
        let room = RecordingBroadcaster(clientCount: 1)
        let server = TCPServer(
            port: 5205, name: "tcp :5205", source: RecordedSource<String>(batches: [["a"]]),
            clients: room, owner: nil)
        try server.open()
        server.stop()
        #expect(server.state == .running, "外で呼んだ stop() は何も止めない")

        server.close()
        try server.open()
        server.supply()
        server.write("back")
        #expect(server.state == .running)
        #expect(server.messages == ["a"])
        #expect(room.written == ["back"])
    }

    // MARK: - 注入

    @Test("同じ行の列は、ポートで受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let (live, port) = try await listening(told: told)
        defer { live.close() }
        let peers = PeerGroup { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: live, told: told)
        let peer = peers[0]
        peer.send(textScript.map { $0 + "\n" }.joined())
        let received = try await requireCollected(live, count: textScript.count)

        let injected = IdleSketch().createTCPServer(messages: textScript.map { [$0] })
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
        let server = TCPServer(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        defer { server.close() }

        try await requireTold(containing: "TCP cannot listen on port \(port) because another app is using it", told: told, tracing: source) { server.state }
        #expect(server.state == .unavailable)
        // 開き直しを何度か重ねても、知らせは増えない
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)
        #expect(server.state == .unavailable)

        holder.release()
        try await requireState(told: told, tracing: source) { server.state }
        let peers = PeerGroup { StreamClient(port: port) }
        defer { peers.closeAll() }
        try await peers.reach(on: server, told: told)
        let peer = peers[0]
        peer.send("back\n")
        #expect(try await requireCollected(server, count: 1) == ["back"])
    }

    @Test("受け口が期限までに running にならなければ、状態と受け口の知らせの全行を名乗って 1 つで止まる (#2945)")
    func requireStateNamesTheStateAndWhatWasTold() async throws {
        let told = Told()
        // 番号を握ったまま手放さないので、受け口は開けない
        let holder = try PortHolder(port: 0, stream: true)
        defer { holder.release() }
        let port = holder.port
        let source = StreamSource(kind: .tcp, port: port, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let server = TCPServer(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: nil,
            warn: told.append)
        try server.open()
        defer { server.close() }
        // 使用中と知らせるまでは普通に待つ。名乗りは、その後の短い期限で通して確かめる
        try await requireTold(containing: "another app is using it", count: 1, exactly: false, told: told, tracing: source) { server.state }

        let said = Mutex("")
        try await withKnownIssue {
            try await requireState(told: told, within: 0.2, tracing: source) { server.state }
        } matching: { issue in
            said.withLock { $0 = issue.comments.map(\.rawValue).joined(separator: "\n") }
            return issue.comments.contains { $0.rawValue.contains("受け口が running にならなかった") }
        }
        let text = said.withLock { $0 }
        #expect(text.contains("状態: unavailable"), "名乗り: \(text)")
        #expect(text.contains("TCP cannot listen on port \(port) because another app is using it"), "名乗り: \(text)")
        #expect(text.contains("期限 0.2 秒"), "名乗り: \(text)")
        // 口の中の移り変わり: 使用中を受けた回数 (開き直しのたびに増える) と、最後のもの
        #expect(text.contains("移り変わり ") && text.contains("最後: portInUse"), "名乗り: \(text)")
        #expect(text.contains("同じ told の全行"), "名乗り: \(text)")

        // 知らせは 1 度でも、使用中のあいだは開き直すたびに移り変わりの数が増える (止まれば増えない)
        try await requireWait("受け口の移り変わりが 3 回に届かなかった", detail: { "回数: \(source.trace.count)" }) {
            source.trace.count >= 3
        }

        // 知らせを待つ側も、言われなかったら状態と移り変わりと told の全行を名乗って止まる
        let toldSaid = Mutex("")
        try await withKnownIssue {
            try await requireTold(
                containing: "never said", told: told, within: 0.1, tracing: source
            ) { server.state }
        } matching: { issue in
            toldSaid.withLock { $0 = issue.comments.map(\.rawValue).joined(separator: "\n") }
            return issue.comments.contains { $0.rawValue.contains("「never said」を含む知らせが 1 回出なかった") }
        }
        let toldText = toldSaid.withLock { $0 }
        #expect(toldText.contains("状態: unavailable") && toldText.contains("最後: portInUse"), "名乗り: \(toldText)")
        #expect(toldText.contains("another app is using it"), "名乗り: \(toldText)")
    }

    // MARK: - 相手の束 (#2940)

    /// 期待した `#require` の失敗 (受け口が数えない) だけを既知として受ける。補助の別の失敗は吸わない。
    private nonisolated static func isNotReached(_ issue: Issue) -> Bool {
        issue.comments.contains { $0.rawValue.contains("受け口が数えたのは") }
    }

    @Test("束は、繋がっていない相手を猶予の後に新しい相手に替え、繋がった相手は替えず、全員が繋がるのを待つ")
    func peerGroupReplacesPeersThatAreNotConnected() async throws {
        let room = ScriptedRoom()
        let server = try room.server()
        defer { server.close() }

        var made: [ScriptedPeer] = []
        let peers = PeerGroup(3) {
            // 全体で 2 つ目に作る相手 (2 人目の最初) は、繋ぎが成り立たないと名乗って繋がらない。
            // 3 つ目に作る相手 (3 人目) は、何も名乗らずに繋ぎの途中のまま止まる
            let state: PeerState =
                switch made.count {
                case 1: .trouble("waiting (scripted)")
                case 2: .connecting
                default: .ready
                }
            let peer = ScriptedPeer(state, in: room)
            made.append(peer)
            return peer
        }
        defer { peers.closeAll() }
        // 替える回数は時計に頼らない (#3215): 猶予は短く決め、`within` は届かなかった回にだけ効く外枠
        try await peers.reach(on: server, within: 10, patience: 0.05)

        #expect(server.connected == 3)
        // 替えたのは繋がっていなかった 2 人 (名乗った相手と、名乗らない相手) で、古い相手は閉じられた。
        // 繋がった 1 人目は替えない。3 人 + 替え 2 回で 5 つ作った
        #expect(peers.replaced == 2)
        #expect(made.count == 5)
        #expect(made.map(\.isClosed) == [false, true, true, false, false])
    }

    @Test("束は、猶予の前には替えない")
    func peerGroupWaitsForTheGraceBeforeReplacing() async throws {
        let room = ScriptedRoom()
        let server = try room.server()
        defer { server.close() }

        var made = 0
        let peers = PeerGroup {
            made += 1
            return ScriptedPeer(made == 1 ? .trouble("waiting (scripted)") : .ready, in: room)
        }
        defer { peers.closeAll() }
        let start = Date()
        // 猶予は 0.5 秒。猶予より早く替えないことを下限で見る (遅い分には下限は割れない)。期限は外枠 (#3215)
        try await peers.reach(on: server, replacements: 3, within: 10, patience: 0.5)
        #expect(Date().timeIntervalSince(start) >= 0.5)
        #expect(made == 2)
    }

    @Test("束は、替える回数に上限を持ち、越えたら受け口の数・相手の様子を名乗って止まる")
    func peerGroupStopsReplacingAtTheLimit() async throws {
        let room = ScriptedRoom()
        let server = try room.server()
        defer { server.close() }

        var made = 0
        let peers = PeerGroup {
            made += 1
            return ScriptedPeer(.trouble("waiting (scripted)"), in: room)
        }
        defer { peers.closeAll() }
        try await withKnownIssue {
            // 回数は時計に頼らない (#3215): 猶予は短く決め、上限まで替えて名乗るのを待つ。`within` は
            // 上限に届かなかった回にだけ効く外枠
            try await peers.reach(
                on: server, replacements: 2, within: 10, patience: 0.05, endsAtLimit: true)
        } matching: {
            Self.isNotReached($0)
        }
        #expect(peers.replaced == 2)
        #expect(made == 3)
    }

    @Test("束の失敗の文面は、受け口の状態・数・替えた回数と、相手ごとの状態を名乗る")
    func peerGroupFailureNamesTheServerAndEveryPeer() async throws {
        let room = ScriptedRoom()
        let server = try room.server()
        defer { server.close() }

        let peers = PeerGroup(2) {
            ScriptedPeer(.trouble("waiting (scripted)"), in: room)
        }
        defer { peers.closeAll() }
        let told = Told()
        told.append("scripted note")
        let said = Mutex("")
        try await withKnownIssue {
            try await peers.reach(on: server, told: told, replacements: 0, within: 0.2)
        } matching: { issue in
            said.withLock { $0 = issue.comments.map(\.rawValue).joined(separator: "\n") }
            return Self.isNotReached(issue)
        }
        let text = said.withLock { $0 }
        #expect(text.contains("2 人のうち、受け口が数えたのは 0 人"))
        #expect(text.contains("受け口の状態: ") && text.contains("running"))
        #expect(text.contains("#0 waiting (scripted)") && text.contains("#1 waiting (scripted)"))
        // 渡した知らせの全行を載せる
        #expect(text.contains("同じ told の全行: [\"scripted note\"]"), "名乗り: \(text)")
    }

    // MARK: - 作る口

    @Test("ポートの番号が 1〜65535 の外なら、作るときに投げる")
    func creationRefusesUnusablePorts() throws {
        let sketch = IdleSketch()
        OutsideRun.$current.withValue(OutsideRun()) {
            #expect(throws: NetworkFailure.invalidPort(0)) { try sketch.createTCPServer(0) }
            #expect(throws: NetworkFailure.invalidPort(65536)) { try sketch.createTCPServer(65536) }
            // 両端は番号の検めを通る。走っていないスケッチなので、その後ポートを開く前に断る (#2740)
            for port in [1, 65535] {
                #expect(throws: NetworkFailure.notRunning(call: "createTCPServer(_:)")) {
                    try sketch.createTCPServer(port)
                }
            }
        }
        // 足すもの (ポートは足したときに開くので、ここでは開かない)
        let edge = sketch.tcpServer(port: 65535)
        #expect(edge.port == 65535)
        #expect(edge.state == .unavailable)
        #expect(edge.clientCount == 0)
        #expect(edge.report?.name == "tcp :65535")
        #expect((edge.source as? StreamSource)?.kind == .tcp)
    }
}
