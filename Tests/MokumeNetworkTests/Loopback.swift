// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

// 同じ機械の中で送って受ける検査が共有する道具。通信は 127.0.0.1 だけで行う。
//
// **待つ側が期限を持つ** — 届くのを待つ検査は、期限を越えたら満たされなかったとして落ちる
// (AGENTS.md「待ちを含む検査を書く」)。

/// 期限まで、条件が満ちるのを待つ。満ちなければ偽。
func until(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// フレームを回すように取り出しを続け、`count` 個届くまで (か期限まで) 集める。
func collect(_ port: TextPort, count: Int, within seconds: TimeInterval = 5) async -> [String] {
    var received: [String] = []
    _ = await until(seconds) {
        port.supply()
        received += port.messages
        return received.count >= count
    }
    return received
}

/// 受けた文字列を作例のスケッチと同じく読んだ結果 (数は大きさを置き換え、`hit` を数える)。
struct TextOutcome: Equatable {
    var size: Float = 0.5
    var hits = 0

    init(size: Float, hits: Int) {
        self.size = size
        self.hits = hits
    }

    init(_ messages: [String]) {
        for text in messages {
            if let value = Float(text) {
                size = value
            } else if text == "hit" {
                hits += 1
            }
        }
    }
}

/// 送る文字列の台本。大きさを動かし、当たりを数える。
let textScript = ["0.25", "hit", "0.75", "fade", "hit"]

/// 受け口が受け始める (`running` になる) のを、期限まで待つ。
///
/// **期限までに `running` にならなければ、受け口の状態と、その受け口が出した知らせの全行を名乗って、1 つで
/// 止まる** (`#require`・#2945)。期限で偽を言うだけだと、受け口が一度も知らせを出していないのか、失敗の理由を
/// 名乗って開き直し続けているのか、使用中のままなのかが、赤の文面から読み分けられない。
///
/// **期限は延ばさず、待ちの中で受け口を閉じて開き直さない** — 原因が分かっていないので、救うと次の 1 回で
/// 読み分ける材料が消える。`told` は、受け口の `warn:` に渡したもの。
func requireRunning(
    told: Told, within seconds: TimeInterval = 5, state: () -> SourceState
) async throws {
    let running = await until(seconds) { state() == .running }
    let current = state()
    try #require(
        running,
        "受け口が running にならなかった (状態: \(current.rawValue)・知らせ: \(told.lines)・期限 \(seconds) 秒)")
}

/// 受け始めるまで待って、実際に開いたポートを返す。`told` は受け口の `warn:` に渡したもの。
func boundPort(of server: TextPort, source: StreamSource, told: Told) async throws -> Int {
    try await requireRunning(told: told) { server.state }
    return try #require(source.boundPort)
}

/// フレームを回すように取り出しを続け、繋いでいる相手の数が `count` になるまで (か期限まで) 待つ。
func clients(_ server: TextPort, reach count: Int) async -> Bool {
    await until {
        server.supply()
        return server.connected == count
    }
}

/// 検査の側の相手の繋ぎの状態。**1 つの値で読む** — 「まだ繋がっていない」と「名乗った」を別々に
/// 読むと、間に書き換えが入って食い違う。
nonisolated enum PeerState: Equatable, Sendable {
    /// 繋ぎに行っている途中 (まだ何も名乗っていない)。
    case connecting
    /// 繋がった。
    case ready
    /// 繋ぎが成り立たないと名乗った (`waiting`・`failed` と、その理由)。
    case trouble(String)

    var text: String {
        switch self {
        case .connecting: "繋ぎの途中"
        case .ready: "繋がった"
        case .trouble(let reason): reason
        }
    }
}

/// 受け口へ繋ぎに行く、検査の側の相手 (``StreamClient``・``BrowserSocket``)。
nonisolated protocol LoopbackPeer: AnyObject, Sendable {
    /// 繋ぎの状態。
    var state: PeerState { get }
    /// 繋ぎを切る。
    func close()
}

extension LoopbackPeer {
    /// 繋がったか。
    var isReady: Bool { state == .ready }
}

nonisolated extension NWConnection.State {
    /// 検査の側の相手の状態への読み替え。繋がった後の `waiting`・`failed` は、繋がったまま読む
    /// (切れた相手は、受け口の数が示す)。
    fileprivate func peerState(after current: PeerState) -> PeerState {
        switch self {
        case .ready: return .ready
        case .waiting(let error): return current == .ready ? current : .trouble("waiting (\(error))")
        case .failed(let error): return current == .ready ? current : .trouble("failed (\(error))")
        default: return current
        }
    }
}

/// 受け口へ繋ぎに行く相手の束。**全員が繋がるまで待ち、繋がらない相手を、猶予を置いて新しい相手に
/// 替える** (#2940)。
///
/// 全段が並走する CI で、受け口へ繋ぎに行く検査の側の相手が 10〜20 秒たっても繋がらず、後の期待が
/// 連鎖して外れたことが 2 回あった (同じ suite の直後の検査は普通に繋がっていた)。**止まった繋ぎが
/// `waiting` なのか `preparing` のままなのか、なぜ止まったのかは、確かめていない** (CI のログには相手の
/// 状態が残っていなかった)。UDP の送り元が `Address already in use` で `waiting` のまま回復しなかった
/// #2910 と同じ形の見込みで、製品の ``ClientSource`` も `waiting` を自分で閉じて張り直している。
///
/// 替え方は、状態を問わない。**繋がっていない相手は、猶予 (`within` を替える回数 + 1 で割った間) が
/// 過ぎたら、古い相手を閉じてから新しい相手に替える** (1 人あたり `replacements` 回まで)。猶予を置くのは、
/// 状態が数秒続くだけで回復する場合にも、替えずに待つ余地を残すため。受け口の数との照合は厳密
/// (`==`) だが、古い相手を閉じてから替えるので、数は戻る。UDP の台帳 (読む前の繋ぎは黙りで閉じない —
/// #2937) とは違い、受け口が古い相手の繋ぎを持ち続けない。全員が繋がり、かつ受け口の数が人数に
/// 一致するまで抜けない (閉じた古い相手が受け口の数に一瞬残る隙間で、先へ進まないため)。
///
/// 待ちの上限が 10 秒なのは、以前の `clients(_, reach:)` の 5 秒に、替える分の猶予 (3 回 × 約 2.5 秒) を
/// 載せるため。5 秒のままでは、1 回替えて新しい相手の繋ぎを待つ時間が残らない。
///
/// 相手は ``subscript(_:)`` で読む。**``reach(on:replacements:within:)`` の後に読む** — 替えると
/// 同じ番号の相手が別のものになる。
final class PeerGroup<Peer: LoopbackPeer> {
    private(set) var peers: [Peer]
    private(set) var replaced = 0
    private let make: () -> Peer

    /// `count` 人の相手を作って繋ぎに行かせる。
    init(_ count: Int = 1, make: @escaping () -> Peer) {
        self.make = make
        peers = (0..<count).map { _ in make() }
    }

    subscript(index: Int) -> Peer { peers[index] }

    /// 束の全員を切る。替えた後の相手も、替えて閉じた相手の分も、これで足りる。
    func closeAll() { for peer in peers { peer.close() } }

    /// 受け口が束の人数を数え、全員が繋がるまで (か期限まで) 待つ。
    ///
    /// 数えない理由を 1 つで名乗って止まる (`#require`): 受け口の状態・数・替えた回数と、相手ごとの
    /// 状態 (名乗った理由を含む)。受け口側の原因か相手側の原因かは、これで読み分ける。
    func reach(on server: TextPort, replacements: Int = 3, within seconds: TimeInterval = 10)
        async throws
    {
        let expected = peers.count
        let patience = seconds / Double(replacements + 1)
        var attempts = [Int](repeating: 1, count: expected)
        var since = [Date](repeating: Date(), count: expected)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            server.supply()
            if server.connected == expected, peers.allSatisfy(\.isReady) { return }
            let now = Date()
            for index in peers.indices
            where !peers[index].isReady && attempts[index] <= replacements
                && now.timeIntervalSince(since[index]) >= patience
            {
                attempts[index] += 1
                since[index] = now
                replaced += 1
                peers[index].close()
                peers[index] = make()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        server.supply()
        let ready = peers.allSatisfy(\.isReady)
        try #require(
            server.connected == expected && ready,
            "\(expected) 人のうち、受け口が数えたのは \(server.connected) 人 (受け口の状態: \(server.state)・替えたのは \(replaced) 回・期限 \(seconds) 秒)。相手の様子: \(peers.enumerated().map { "#\($0.offset) \($0.element.state.text)" })"
        )
    }
}

/// 1 つの送り元から datagram の列を送り、`count` 通が届くまで (か期限まで) 集めて、読まれた文字列を返す。
///
/// **送った datagram が全部読まれる前提を置かない** (#2910・#2940)。送り元の繋ぎが `Address already
/// in use` で `waiting` のまま回復しないと、送った列は 1 通も出ない。**送れないと名乗り、まだ 1 通も
/// 読まれていない送り元は、猶予 (`within` を替える回数 + 1 で割った間) の後に、新しい送り元に替えて列を
/// 最初から送り直す**。1 通でも読まれた後は替えない — 列の途中から送り直すと、順や数が崩れる。名乗らずに
/// 読まれない送り元も替えない (読みが遅れているだけのことがあり、足すと台帳が目安から下がらなくなる —
/// #2937)。替えた古い送り元は閉じ、その遅れた名乗りは数えない。
///
/// 送り元は `senders` の末尾へ足す。呼ぶ側が検査の終わりに閉じる。名乗りは送り元の側の話なので、
/// 受け口の知らせ (`told`) には流さない。
func sendAndCollect(
    _ datagrams: [[UInt8]], expecting count: Int, to port: TextPort,
    senders: inout [any DatagramSending], replacements: Int = 3, within seconds: TimeInterval = 10,
    makeSender: (_ warn: @escaping @Sendable (String) -> Void) -> any DatagramSending
) async throws -> [String] {
    let stuck = Mutex(false)
    let current = Mutex(1)
    var attempt = 1
    let patience = seconds / Double(replacements + 1)
    func open() -> any DatagramSending {
        let mine = attempt
        let sender = makeSender { _ in
            guard current.withLock({ $0 }) == mine else { return }
            stuck.withLock { $0 = true }
        }
        for datagram in datagrams { sender.send(datagram) }
        return sender
    }
    senders.append(open())
    let index = senders.count - 1
    var received: [String] = []
    var since = Date()
    let deadline = Date().addingTimeInterval(seconds)
    while received.count < count, Date() < deadline {
        port.supply()
        received += port.messages
        if received.isEmpty, attempt <= replacements, stuck.withLock({ $0 }),
            Date().timeIntervalSince(since) >= patience
        {
            attempt += 1
            current.withLock { $0 = attempt }
            stuck.withLock { $0 = false }
            since = Date()
            senders[index].stop()
            senders[index] = open()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return received
}

/// 127.0.0.1 のポートへ、素の BSD socket から datagram を送る相手 (他のアプリの代わり)。
///
/// **1 つの socket から送るので、受け口からは 1 つの送り元に見える。** 間を空けずに続けて送れば、
/// 後ろの datagram は受け口の同じ繋ぎに積まれている。送る上限 (`SO_SNDBUF`) を広げてあり、
/// macOS の既定 (`net.inet.udp.maxdgram` の 9216 バイト) を超える datagram も送れる —
/// ``DatagramSender`` は超えると `Message too long` で送れない。
nonisolated final class RawDatagramSocket: Sendable {
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw PortHolder.Failure(call: "socket", code: errno) }
        var size: Int32 = 1 << 20
        guard
            setsockopt(
                descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            let code = errno
            close(descriptor)
            throw PortHolder.Failure(call: "setsockopt", code: code)
        }
        self.descriptor = descriptor
    }

    /// 1 つの datagram として送る。送れたバイト数を返す (送れなければ -1)。
    func send(_ bytes: [UInt8], to port: Int) -> Int {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor, buffer.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func release() { close(descriptor) }
}

/// 127.0.0.1 のポートへ TCP で繋ぐ相手 (`nc` の代わり)。届いたバイト列を溜める。
nonisolated final class StreamClient: LoopbackPeer, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は錠の内側だけ。手続きは ``queue`` で走る。
    private let queue = DispatchQueue(label: "org.mokume.test.client")
    private let connection: NWConnection
    private let bytes = Mutex<[UInt8]>([])
    private let link = Mutex(PeerState.connecting)
    private let ended = Mutex(false)

    init(port: Int) {
        connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            self?.link.withLock { $0 = state.peerState(after: $0) }
        }
        connection.start(queue: queue)
        receive()
    }

    /// 繋ぎの状態 (``LoopbackPeer``)。
    var state: PeerState { link.withLock { $0 } }
    /// 届いたバイト列を文字列にしたもの。
    var received: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }
    /// 向こうが閉じたか。
    var closedByPeer: Bool { ended.withLock { $0 } }

    func send(_ text: String) { send(Array(text.utf8)) }

    func send(_ raw: [UInt8]) {
        connection.send(content: Data(raw), completion: .idempotent)
    }

    /// 送る向きを閉じる (送ったものの後に、終わりの印が届く)。受ける向きは開いたまま。
    func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    /// 繋ぎを切る。
    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content { bytes.withLock { $0 += content } }
            if isComplete || error != nil {
                ended.withLock { $0 = true }
                return
            }
            receive()
        }
    }
}

/// 127.0.0.1 のポートへ WebSocket で繋ぐ相手 (ブラウザの代わり)。届いた text を 1 通ずつ溜める。
nonisolated final class BrowserSocket: LoopbackPeer, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は錠の内側だけ。手続きは ``queue`` で走る。
    private let queue = DispatchQueue(label: "org.mokume.test.websocket")
    private let connection: NWConnection
    private let texts = Mutex<[String]>([])
    private let link = Mutex(PeerState.connecting)
    private let ended = Mutex(false)

    init(port: Int, path: String = "/") {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolWebSocket.Options(), at: 0)
        connection = NWConnection(
            to: .url(URL(string: "ws://127.0.0.1:\(port)\(path)")!), using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            self?.link.withLock { $0 = state.peerState(after: $0) }
        }
        connection.start(queue: queue)
        receive()
    }

    /// 繋ぎの状態 (``LoopbackPeer``)。
    var state: PeerState { link.withLock { $0 } }
    /// 届いた text。届いた順。
    var received: [String] { texts.withLock { $0 } }
    /// 向こうが閉じたか。
    var closedByPeer: Bool { ended.withLock { $0 } }

    /// 1 通の text として送る。
    func send(_ text: String) {
        send(Data(text.utf8), opcode: .text)
    }

    /// 1 通の binary として送る。
    func sendBinary(_ bytes: [UInt8]) {
        send(Data(bytes), opcode: .binary)
    }

    /// 繋ぎを切る。
    func close() { connection.cancel() }

    private func send(_ content: Data, opcode: NWProtocolWebSocket.Opcode) {
        let context = NWConnection.ContentContext(
            identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: content, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard error == nil, let metadata, metadata.opcode != .close else {
                ended.withLock { $0 = true }
                return
            }
            // 空の 1 通は content が nil で届く。落とさずに空の文字列として積む
            if metadata.opcode == .text {
                texts.withLock { $0.append(String(decoding: content ?? Data(), as: UTF8.self)) }
            }
            receive()
        }
    }
}
