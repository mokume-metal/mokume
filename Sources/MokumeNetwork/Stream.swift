// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeCore
import Network
import Synchronization

// 繋いでくる相手を待つ受け口 (TCP・WebSocket)。ポートを開く部分は UDP と ``PortListener`` を
// 共有し、ここは繋いできた相手ごとの読み・書き・数えを持つ。TCP と WebSocket で違うのは、
// 1 つのメッセージの区切り方 (行か 1 通か) と、書くときの包み方だけである。
//
// Network.framework の手続きはすべて ``StreamListener`` の待ち行列の上で走り、境界を越えるのは
// 読んだ文字列 (`Sendable`) と相手の数だけである ([ADR-0042] 決定 7 の条件)。
//
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md

/// 繋いでいる相手全員へ書ける出どころ (``TCPServer``・``WebSocketServer`` の送る向き)。
protocol Broadcasting: AnyObject {
    /// いま繋いでいる相手の数。
    var clientCount: Int { get }
    /// 繋いでいる相手全員へ書く。待たずに返る。
    func broadcast(_ text: String)
}

/// TCP か WebSocket のポートを 1 つ開いて、繋いできた相手から届いた文字列を渡す。繋いでいる
/// 相手全員へ書ける。
///
/// **ポートが使えなくても投げない。** 開く・使用中を見分ける・開き直すのは ``PortListener`` の
/// とおり。相手は何人でも繋げ、相手が閉じる・失敗すると数えから外す。
nonisolated final class StreamListener: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``clients``・``stopped``) は ``queue`` の上でだけ触る。
    // 外から読む相手の数は ``connected`` (錠を持つ) に写す。

    /// 受け口の移り変わり。
    typealias Event = PortListener.Event

    /// 方式。
    enum Kind: Sendable {
        /// 改行で区切った 1 行が 1 つ。書くときはバイト列をそのまま流す。
        case tcp
        /// 1 通が 1 つ (text も binary も UTF-8 として読む)。書くときは 1 通の text にする。
        case webSocket

        /// 診断の文面に出す名乗り。
        var label: String {
            switch self {
            case .tcp: "TCP"
            case .webSocket: "WebSocket"
            }
        }

        /// 開くたびに作る通信の設定。
        func parameters() -> NWParameters {
            let parameters = NWParameters.tcp
            if self == .webSocket {
                let options = NWProtocolWebSocket.Options()
                options.autoReplyPing = true
                parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            }
            return parameters
        }
    }

    /// 1 行のバイト数の上限 (TCP)。
    static let lineLimit = 65536

    let kind: Kind
    private let queue = DispatchQueue(label: "org.mokume.network.stream")
    private let opener: PortListener
    private let received: @Sendable (_ texts: [String], _ unreadable: Int, _ hostTime: UInt64) -> Void
    private var clients: [Client] = []
    private var stopped = false
    private let connected = Mutex(0)

    /// - Parameters:
    ///   - kind: 方式 (TCP か WebSocket)。
    ///   - port: 開くポート。0 なら OS が選ぶ。
    ///   - host: 受けるアドレス。`nil` ならすべての口。
    ///   - retryAfter: 失敗したとき、何秒後に開き直すか。
    ///   - received: 届いた文字列・読めずに捨てた数・届いた瞬間の host time。``queue`` の上で呼ばれる。
    ///   - changed: 移り変わり。``queue`` の上で呼ばれる。
    init(
        kind: Kind, port: Int, host: String?, retryAfter: TimeInterval,
        received: @escaping @Sendable (_ texts: [String], _ unreadable: Int, _ hostTime: UInt64) -> Void,
        changed: @escaping @Sendable (Event) -> Void
    ) {
        self.kind = kind
        self.received = received
        opener = PortListener(
            port: port, host: host, retryAfter: retryAfter, queue: queue,
            parameters: { kind.parameters() }, changed: changed)
    }

    /// 開き始める。待たずに返る。
    func start() {
        opener.start { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            accept(connection)
        }
    }

    /// いま繋いでいる相手の数。
    var clientCount: Int { connected.withLock { $0 } }

    /// 閉じる。繋いでいる相手も切る。**閉じ終わるまで待つ** — 返った後に届いたものは渡さない。
    func stop() {
        queue.sync { [self] in
            stopped = true
            opener.cancel()
            for client in clients { client.connection.cancel() }
            clients.removeAll()
            connected.withLock { $0 = 0 }
        }
    }

    /// 繋いでいる相手全員へ書く。待たずに返る。書けなかった相手は切る。
    ///
    /// TCP はバイト列をそのまま流し、WebSocket は 1 通の text にする。
    func broadcast(_ text: String) {
        let content = Data(text.utf8)
        let context: NWConnection.ContentContext
        switch kind {
        case .tcp:
            context = .defaultMessage
        case .webSocket:
            context = NWConnection.ContentContext(
                identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        }
        queue.async { [self] in
            for client in clients where client.ready {
                client.connection.send(
                    content: content, contentContext: context, isComplete: true,
                    completion: .contentProcessed { [weak client] error in
                        guard error != nil, let client else { return }
                        client.connection.cancel()
                    })
            }
        }
    }

    // MARK: - 待ち行列の上

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let client = Client(connection: connection)
        clients.append(client)
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            changed(client, to: state)
        }
        connection.start(queue: queue)
        switch kind {
        case .tcp: receiveLines(from: client)
        case .webSocket: receiveMessages(from: client)
        }
    }

    private func changed(_ client: Client, to state: NWConnection.State) {
        switch state {
        case .ready:
            client.ready = true
        case .failed:
            client.connection.cancel()
            clients.removeAll { $0 === client }
        case .cancelled:
            clients.removeAll { $0 === client }
        default:
            return
        }
        recount()
    }

    private func recount() {
        let count = clients.lazy.filter(\.ready).count
        connected.withLock { $0 = count }
    }

    /// TCP: 届いたバイト列を行に切って渡す。
    private func receiveLines(from client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.lineLimit) {
            [weak self, weak client] content, _, isComplete, error in
            let hostTime = mach_absolute_time()
            guard let self, let client, !stopped else { return }
            if let content, !content.isEmpty {
                let cut = client.lines.append(content)
                deliver(cut.lines, overlong: cut.overlong, hostTime: hostTime)
            }
            guard !isComplete, error == nil else {
                // 相手が閉じた。改行で終わっていない残りも 1 行として渡す
                if let rest = client.lines.finish() {
                    deliver([rest], overlong: 0, hostTime: hostTime)
                }
                client.connection.cancel()
                return
            }
            receiveLines(from: client)
        }
    }

    /// WebSocket: 1 通ずつ、末尾の改行 1 つを落として渡す。ping には Network.framework が答える。
    private func receiveMessages(from client: Client) {
        client.connection.receiveMessage { [weak self, weak client] content, context, _, error in
            let hostTime = mach_absolute_time()
            guard let self, let client, !stopped else { return }
            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard error == nil, let metadata, metadata.opcode != .close else {
                // 失敗・閉じる知らせ・印の無い終わり (相手が繋ぎごと切った)
                client.connection.cancel()
                return
            }
            if metadata.opcode == .text || metadata.opcode == .binary {
                if let text = TextDecoding.message([UInt8](content ?? Data())) {
                    received([text], 0, hostTime)
                } else {
                    received([], 1, hostTime)
                }
            }
            receiveMessages(from: client)
        }
    }

    private func deliver(_ lines: [[UInt8]], overlong: Int, hostTime: UInt64) {
        guard !lines.isEmpty || overlong > 0 else { return }
        var texts: [String] = []
        var unreadable = overlong
        for line in lines {
            if let text = TextDecoding.line(line) {
                texts.append(text)
            } else {
                unreadable += 1
            }
        }
        received(texts, unreadable, hostTime)
    }
}

/// 繋いできた相手 1 人。
private nonisolated final class Client: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``ready``・``lines``) は ``StreamListener`` の待ち行列の
    // 上でだけ触る。Network.framework の手続きも同じ待ち行列で走るので、そこから弱く握ってよい。
    let connection: NWConnection
    /// 繋ぎ終えたか (数えに入れるか)。
    var ready = false
    /// 行の途中で切れた残り。
    var lines = LineSplitter(limit: StreamListener.lineLimit)

    init(connection: NWConnection) {
        self.connection = connection
    }
}

/// 繋いでくる相手を待つ出どころ。届いた文字列を列へ入れ、繋いでいる相手全員へ書ける。
///
/// ポートが使用中・拒まれた・失敗したときは ``ListenerStatus`` が状態に写し、それぞれ 1 度だけ
/// 知らせる。
nonisolated final class StreamSource: MessageSource, Broadcasting, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``listener`` だけで、main actor (start / stop / 書く・
    // 数える) でだけ触る。受け口の手続きが触るのは ``status`` (錠を持つ) と列 (それ自身が錠を持つ) だけ。

    let kind: StreamListener.Kind
    let port: Int
    let host: String?
    let retryAfter: TimeInterval
    private let status: ListenerStatus
    private var listener: StreamListener?

    /// 失敗したとき、何秒後に開き直すか (既定)。
    static var defaultRetry: TimeInterval { 1 }

    init(
        kind: StreamListener.Kind, port: Int, host: String? = nil,
        retryAfter: TimeInterval = defaultRetry, warn: @escaping @Sendable (String) -> Void
    ) {
        self.kind = kind
        self.port = port
        self.host = host
        self.retryAfter = retryAfter
        status = ListenerStatus(label: kind.label, port: port, retryAfter: retryAfter, warn: warn)
    }

    /// 実際に開いたポート。0 を頼んだときに、OS が選んだ番号を知るために使う。
    var boundPort: Int? { status.boundPort }

    var clientCount: Int { listener?.clientCount ?? 0 }

    func start(into queue: ExternalQueue<String>) {
        queue.setState(.unavailable)
        let listener = StreamListener(
            kind: kind, port: port, host: host, retryAfter: retryAfter,
            received: { texts, unreadable, hostTime in
                for text in texts { queue.send(text, hostTime: hostTime) }
                queue.discardUnreadable(unreadable)
            },
            changed: { [status] event in
                status.apply(event, to: queue)
            })
        self.listener = listener
        listener.start()
    }

    func pump(into queue: ExternalQueue<String>) {}

    func stop() {
        listener?.stop()
        listener = nil
    }

    func broadcast(_ text: String) {
        listener?.broadcast(text)
    }
}
