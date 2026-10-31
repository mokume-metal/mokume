// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeCore
import MokumeDiagnostics
import Network
import Synchronization

// 外のサーバへ繋ぎに行く側 (TCP・WebSocket のクライアント・#2470)。待つ側の ``StreamListener`` と
// 同じ読み方・書き方で、違うのは繋ぎ方だけである — 1 本の繋ぎを自分から張り、切れたら決まった間隔で
// 張り直す。
//
// Network.framework の手続きはすべて ``StreamConnector`` の待ち行列の上で走り、境界を越えるのは
// 読んだ文字列 (`Sendable`) と繋がっているかだけである ([ADR-0042] 決定 7 の条件)。
//
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md

/// 繋ぎ先の移り変わり。
nonisolated enum ConnectorEvent: Sendable, Equatable {
    /// 繋がった。
    case connected
    /// 繋げなかった (一度も繋がっていない間、または繋ぎ直しの試みが)。
    case failed(String)
    /// OS の方針 (ローカルネットワークの許可) で拒まれている。
    case denied
    /// 繋がっていたのが切れた。
    case lost
}

/// 1 つのサーバへ繋ぎに行き、届いた文字列を渡す。切れたら ``retryAfter`` 秒ごとに繋ぎ直す。
///
/// **繋ぎ直しの間隔は固定で、設定する口は無い** ([#2470])。繋げない間も、切れた後も、同じ間隔で
/// 試し続ける。止めるのは ``stop()`` だけ。
///
/// [#2470]: https://github.com/mokume-metal/mokume/issues/2470
nonisolated final class StreamConnector: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``connection``・``ready``・``stopped``・``splitter``) は
    // ``queue`` の上でだけ触る。外から読む繋がっているか (``isConnected``) は錠を持つ。

    /// 1 回の繋ぐ試みを待つ秒数 (既定)。越えたら諦めて、``retryAfter`` 後に張り直す。
    ///
    /// **TCP の繋ぎだけでなく、TLS の握手と WebSocket の切り替えまで含めた「使えるようになるまで」の期限である。**
    /// 応えない相手 (SYN を捨てる機械・経路の無いアドレス・繋がるが握手に答えないサーバ) には、期限が無いと
    /// OS の既定 (1 分以上) か永久に張り付き、その間は繋ぎ直しの間隔が働かない。
    static var defaultConnectTimeout: TimeInterval { 5 }

    let kind: StreamListener.Kind
    let endpoint: NWEndpoint
    /// `wss://` か (WebSocket の暗号化)。
    let secure: Bool
    let retryAfter: TimeInterval
    let connectTimeout: TimeInterval

    /// 経路を待つ繋ぎが満たされない理由を読む手続き (既定は `currentPath`)。検査が差し替える。
    private let unsatisfiedReason: @Sendable (NWConnection) -> NWPath.UnsatisfiedReason?

    private let queue = DispatchQueue(label: "org.mokume.network.client")
    private let received: @Sendable (_ texts: [String], _ unreadable: Int, _ hostTime: UInt64) -> Void
    private let changed: @Sendable (ConnectorEvent) -> Void
    private var connection: NWConnection?
    private var ready = false
    private var stopped = false
    private var splitter = LineSplitter(limit: StreamListener.lineLimit)
    private let connected = Mutex(false)

    /// - Parameters:
    ///   - received: 届いた文字列・読めずに捨てた数・届いた瞬間の host time。``queue`` の上で呼ばれる。
    ///   - changed: 移り変わり。``queue`` の上で呼ばれる。
    ///   - unsatisfiedReason: 経路を待つ繋ぎが満たされない理由を読む手続き。ローカルネットワークの許可が
    ///     無いことは、エラーでなくここにだけ出る (#3593)。
    init(
        kind: StreamListener.Kind, endpoint: NWEndpoint, secure: Bool = false,
        retryAfter: TimeInterval, connectTimeout: TimeInterval = defaultConnectTimeout,
        unsatisfiedReason: @escaping @Sendable (NWConnection) -> NWPath.UnsatisfiedReason? =
            StreamConnector.currentPathReason,
        received: @escaping @Sendable (_ texts: [String], _ unreadable: Int, _ hostTime: UInt64) -> Void,
        changed: @escaping @Sendable (ConnectorEvent) -> Void
    ) {
        self.kind = kind
        self.endpoint = endpoint
        self.secure = secure
        self.retryAfter = retryAfter
        self.connectTimeout = connectTimeout
        self.unsatisfiedReason = unsatisfiedReason
        self.received = received
        self.changed = changed
    }

    /// 繋ぎ始める。待たずに返る。
    func start() {
        queue.async { [self] in connect() }
    }

    /// いま繋がっているか。
    var isConnected: Bool { connected.withLock { $0 } }

    /// 閉じる。**閉じ終わるまで待つ** — 返った後に届いたものは渡さない。
    func stop() {
        queue.sync { [self] in
            stopped = true
            connection?.cancel()
            connection = nil
            ready = false
            connected.withLock { $0 = false }
        }
    }

    /// サーバへ 1 つ書く。待たずに返る。繋がっていなければ何もしない。書けなかったら繋ぎ直す。
    ///
    /// TCP はバイト列をそのまま流し、WebSocket は 1 通の text にする。
    func send(_ text: String) {
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
            guard !stopped, ready, let sending = connection else { return }
            sending.send(
                content: content, contentContext: context, isComplete: true,
                completion: .contentProcessed { [weak self, weak sending] error in
                    guard error != nil, let self, let sending else { return }
                    queue.async { [self] in drop(sending, because: .lost) }
                })
        }
    }

    // MARK: - 待ち行列の上

    private func connect() {
        guard !stopped, connection == nil else { return }
        let next = NWConnection(to: endpoint, using: kind.clientParameters(secure: secure))
        connection = next
        ready = false
        splitter = LineSplitter(limit: StreamListener.lineLimit)
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next else { return }
            changed(next, to: state)
        }
        next.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self, weak next] in
            guard let self, let next, !stopped, next === connection, !ready else { return }
            let seconds = String(format: "%g", connectTimeout)
            drop(next, because: .failed("no answer within \(seconds) second(s)"))
        }
    }

    private func changed(_ current: NWConnection, to state: NWConnection.State) {
        // 張り直した後に、前の繋ぎの知らせが遅れて届くことがある
        guard !stopped, current === connection else { return }
        switch state {
        case .ready:
            ready = true
            connected.withLock { $0 = true }
            changed(.connected)
            switch kind {
            case .tcp: receiveLines(from: current)
            case .webSocket: receiveMessages(from: current)
            }
        case .waiting(let error):
            // 経路を待つ間の自動の張り直しには任せない — 間隔を固定にするため、自分で閉じて張り直す。
            // ローカルネットワークの許可が無いと `ENETDOWN` で待ち、拒まれたことは経路にしか出ない
            drop(current, because: Self.event(waiting: error, unsatisfiedReason: unsatisfiedReason(current)))
        case .failed(let error):
            drop(current, because: Self.event(for: error))
        default:
            return
        }
    }

    /// 繋ぎを閉じ、``retryAfter`` 秒後に張り直す。繋がっていたなら `lost`、繋がる前なら `event` で知らせる。
    private func drop(_ current: NWConnection, because event: ConnectorEvent) {
        guard !stopped, current === connection else { return }
        let wasReady = ready
        connection = nil
        ready = false
        connected.withLock { $0 = false }
        current.cancel()
        changed(wasReady ? .lost : event)
        queue.asyncAfter(deadline: .now() + retryAfter) { [weak self] in
            self?.connect()
        }
    }

    /// TCP: 届いたバイト列を行に切って渡す。
    private func receiveLines(from current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: StreamListener.lineLimit) {
            [weak self, weak current] content, _, isComplete, error in
            let hostTime = mach_absolute_time()
            guard let self, let current, !stopped, current === connection else { return }
            if let content, !content.isEmpty {
                let cut = splitter.append(content)
                deliver(cut.lines, overlong: cut.overlong, hostTime: hostTime)
            }
            guard !isComplete, error == nil else {
                // 相手が閉じた。改行で終わっていない残りも 1 行として渡す
                if let rest = splitter.finish() {
                    deliver([rest], overlong: 0, hostTime: hostTime)
                }
                drop(current, because: .lost)
                return
            }
            receiveLines(from: current)
        }
    }

    /// WebSocket: 1 通ずつ、末尾の改行 1 つを落として渡す。ping には Network.framework が答える。
    private func receiveMessages(from current: NWConnection) {
        current.receiveMessage { [weak self, weak current] content, context, _, error in
            let hostTime = mach_absolute_time()
            guard let self, let current, !stopped, current === connection else { return }
            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard error == nil, let metadata, metadata.opcode != .close else {
                // 失敗・閉じる知らせ・印の無い終わり (相手が繋ぎごと切った)
                drop(current, because: .lost)
                return
            }
            if metadata.opcode == .text || metadata.opcode == .binary {
                if let text = TextDecoding.message([UInt8](content ?? Data())) {
                    received([text], 0, hostTime)
                } else {
                    received([], 1, hostTime)
                }
            }
            receiveMessages(from: current)
        }
    }

    private func deliver(_ lines: [[UInt8]], overlong: Int, hostTime: UInt64) {
        guard !lines.isEmpty || overlong > 0 else { return }
        let read = TextDecoding.lines(lines, overlong: overlong)
        received(read.texts, read.unreadable, hostTime)
    }

    /// Network.framework の失敗を、繋ぎ先の移り変わりに読み替える (``PortListener/event(for:)`` と同じ読み方)。
    static func event(for error: any Error) -> ConnectorEvent {
        switch PortListener.event(for: error) {
        case .denied: .denied
        case .failed(let reason): .failed(reason)
        case .portInUse: .failed("the address is in use")
        case .ready: .failed("unknown")
        }
    }
}

nonisolated extension StreamConnector {
    /// 経路を待つ繋ぎが満たされない理由 (既定の読み方。検査が差し替える)。
    static let currentPathReason: @Sendable (NWConnection) -> NWPath.UnsatisfiedReason? = {
        $0.currentPath?.unsatisfiedReason
    }

    /// 経路を待つ繋ぎ (`NWConnection` の `.waiting`) の事情を、繋ぎ先の移り変わりに読み替える。
    ///
    /// ローカルネットワークの許可が無いとき、`NWConnection` は拒まれたとは言わず `ENETDOWN`
    /// (`Network is down`) で待ち、拒まれたことは経路の理由 (`.localNetworkDenied`) にしか出ない
    /// (#3593・Apple の TN3179 と一致)。それは許可の話なので `.denied` と読む。理由が他なら、
    /// エラーだけで読む (経路が本当に無い `Network is down` は、いまどおり繋げなかった)。
    static func event(
        waiting error: any Error, unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) -> ConnectorEvent {
        unsatisfiedReason == .localNetworkDenied ? .denied : event(for: error)
    }
}

extension StreamListener.Kind {
    /// 繋ぎに行くときの通信の設定。`secure` は `wss://` (TLS の上の WebSocket)。
    nonisolated func clientParameters(secure: Bool) -> NWParameters {
        let parameters: NWParameters =
            secure ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        if self == .webSocket {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        return parameters
    }
}

/// 繋ぎ先の移り変わりを列の状態に写し、初めてのものを 1 度だけ言う。
///
/// ``ListenerStatus`` の繋ぎに行く側。繋がったら、また言えるように戻す。
nonisolated final class ConnectorStatus: Sendable {
    /// 文面の頭に出す名乗り (`TCP client`・`WebSocket client`)。
    let label: String
    /// 繋ぎ先の綴り (`127.0.0.1:7000`・`ws://relay.example/room`)。
    let target: String
    let retryAfter: TimeInterval
    private let warn: @Sendable (String) -> Void
    private let told = Mutex<Set<String>>([])
    /// 一度でも繋がったか。繋がる前の失敗は `unavailable`、繋がった後は `disconnected` と名乗る。
    private let hasConnected = Mutex(false)
    private let events = Mutex(EventTrace())

    init(
        label: String, target: String, retryAfter: TimeInterval,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.label = label
        self.target = target
        self.retryAfter = retryAfter
        self.warn = warn
    }

    /// 受けた移り変わりの跡。読むだけ。
    var trace: EventTrace { events.withLock { $0 } }

    func apply<Value>(_ event: ConnectorEvent, to queue: ExternalQueue<Value>) {
        events.withLock {
            $0.count += 1
            $0.last = "\(event)"
        }
        let seconds = Int(retryAfter.rounded(.up))
        switch event {
        case .connected:
            hasConnected.withLock { $0 = true }
            queue.setState(.running)
            told.withLock { $0.removeAll() }
        case .failed(let reason):
            queue.setState(hasConnected.withLock { $0 } ? .disconnected : .unavailable)
            tellOnce(
                "failed",
                "\(label) cannot connect to \(target) (\(reason)). It tries again every \(seconds) second(s)")
        case .denied:
            queue.setState(.denied)
            tellOnce(
                "denied",
                "\(label) to \(target) is blocked by macOS (Local Network). Allow it in System "
                    + "Settings > Privacy & Security > Local Network. It connects at the next retry "
                    + "(every \(seconds) second(s)) once allowed")
        case .lost:
            queue.setState(.disconnected)
            tellOnce(
                "lost",
                "\(label) lost the connection to \(target). It tries to connect again every "
                    + "\(seconds) second(s)")
        }
    }

    private func tellOnce(_ key: String, _ message: String) {
        let first = told.withLock { $0.insert(key).inserted }
        if first { warn(message) }
    }
}

/// サーバへ繋ぎに行く出どころ。届いた文字列を列へ入れ、繋がっている間はサーバへ書ける。
///
/// 繋げない・切れたときは ``ConnectorStatus`` が状態に写し、それぞれ 1 度だけ知らせる。
nonisolated final class ClientSource: MessageSource, Broadcasting, EventTracing, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``connector`` だけで、main actor (start / stop / 書く・
    // 数える) でだけ触る。繋ぎの手続きが触るのは ``status`` (錠を持つ) と列 (それ自身が錠を持つ) だけ。

    let kind: StreamListener.Kind
    let endpoint: NWEndpoint
    let secure: Bool
    let retryAfter: TimeInterval
    let connectTimeout: TimeInterval
    private let unsatisfiedReason: @Sendable (NWConnection) -> NWPath.UnsatisfiedReason?
    private let status: ConnectorStatus
    private var connector: StreamConnector?

    /// 繋ぎの移り変わりの跡 (``EventTracing``)。
    var trace: EventTrace { status.trace }

    /// 繋ぎ直しの間隔 (秒)。**固定で、設定する口は無い** (#2470)。
    static var defaultRetry: TimeInterval { 1 }

    /// - Parameters:
    ///   - target: 診断に出す繋ぎ先の綴り。
    ///   - unsatisfiedReason: ``StreamConnector`` へそのまま渡す。検査が経路の理由を差し替える。
    init(
        kind: StreamListener.Kind, endpoint: NWEndpoint, secure: Bool = false, target: String,
        retryAfter: TimeInterval = defaultRetry,
        connectTimeout: TimeInterval = StreamConnector.defaultConnectTimeout,
        unsatisfiedReason: @escaping @Sendable (NWConnection) -> NWPath.UnsatisfiedReason? =
            StreamConnector.currentPathReason,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.kind = kind
        self.endpoint = endpoint
        self.secure = secure
        self.retryAfter = retryAfter
        self.connectTimeout = connectTimeout
        self.unsatisfiedReason = unsatisfiedReason
        status = ConnectorStatus(
            label: "\(kind.label) client", target: target, retryAfter: retryAfter, warn: warn)
    }

    /// 繋がっていれば 1、繋がっていなければ 0。
    var clientCount: Int { (connector?.isConnected ?? false) ? 1 : 0 }

    func start(into queue: ExternalQueue<String>) {
        queue.setState(.unavailable)
        let connector = StreamConnector(
            kind: kind, endpoint: endpoint, secure: secure, retryAfter: retryAfter,
            connectTimeout: connectTimeout, unsatisfiedReason: unsatisfiedReason,
            received: { texts, unreadable, hostTime in
                for text in texts { queue.send(text, hostTime: hostTime) }
                queue.discardUnreadable(unreadable)
            },
            changed: { [status] event in
                status.apply(event, to: queue)
            })
        self.connector = connector
        connector.start()
    }

    func pump(into queue: ExternalQueue<String>) {}

    func stop() {
        connector?.stop()
        connector = nil
    }

    func broadcast(_ text: String) {
        connector?.send(text)
    }
}
