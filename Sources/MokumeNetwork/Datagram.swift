// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network

// UDP の受け・送り。**中身のバイト列をどう読むかは持たない** — 上の層 (OSC の ``OSCCodec``・
// 文字列の ``TextDecoding``) が決める。ポートを開く部分は TCP・WebSocket と ``PortListener`` を
// 共有する (待ち行列の扱いと ADR-0042 決定 7 の条件も、そちらの冒頭に書いた)。

/// UDP のポートを 1 つ開いて、届いた datagram を 1 つずつ渡す。
///
/// **ポートが使えなくても投げない。** 開く・使用中を見分ける・開き直すのは ``PortListener`` の
/// とおりで、移り変わりは ``Event`` で知らせる。
nonisolated final class DatagramListener: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``senders``・``stopped``) は ``queue`` の上でだけ触る。
    // Network.framework の手続きもすべて ``queue`` で走らせる。

    /// 受け口の移り変わり。
    typealias Event = PortListener.Event

    /// 頼んだポート。0 なら OS が空いている番号を選ぶ。
    var port: Int { opener.port }
    /// 受けるアドレス。`nil` ならすべての口 (別の機械からも届く)。
    var host: String? { opener.host }
    /// 失敗したとき、何秒後に開き直すか。
    var retryAfter: TimeInterval { opener.retryAfter }
    /// 何秒黙っていた送り元を、閉じてよいとするか。
    let idleAfter: TimeInterval

    /// 持つ送り元の数の目安。これに達したら、新しい送り元を受ける前に黙っている送り元を閉じる。
    ///
    /// UDP の受け口は、送り元 (アドレスとポート) ごとに `NWConnection` を 1 つ作る。送るたびに
    /// 新しいポートから送る相手 (使い捨てのソケットで送るスクリプトなど) が居ると、閉じない
    /// 限り際限なく増える。閉じた送り元からまた届けば、新しく作り直される。
    ///
    /// **閉じるのは ``idleAfter`` 秒以上黙っている送り元だけである。** 届いたばかりの送り元を
    /// 閉じると、まだ読んでいない datagram ごと捨ててしまう (多くの送り元から一度に届いたとき、
    /// 先に着いた送り元を閉じて落とすことを検査で確かめた)。だから一度に多く届いた間は数が
    /// これを超えてよく、黙った後の次の受け入れで戻る。
    static let connectionLimit = 64

    /// 黙っている送り元を閉じてよいとするまでの秒数 (既定)。
    static let defaultIdleAfter: TimeInterval = 5

    private let queue = DispatchQueue(label: "org.mokume.network.listener")
    private let received: @Sendable ([UInt8], UInt64) -> Void
    private let opener: PortListener
    /// 送り元と、最後に届いた (受け入れた) 時刻。
    private var senders: [(connection: NWConnection, heard: TimeInterval)] = []
    private var stopped = false

    /// - Parameters:
    ///   - port: 開くポート。0 なら OS が選ぶ。
    ///   - host: 受けるアドレス。`nil` ならすべての口。
    ///   - retryAfter: 失敗したとき、何秒後に開き直すか。
    ///   - idleAfter: 何秒黙っていた送り元を、閉じてよいとするか。
    ///   - received: 届いた datagram と、届いた瞬間の host time。``queue`` の上で呼ばれる。
    ///   - changed: 移り変わり。``queue`` の上で呼ばれる。
    init(
        port: Int, host: String?, retryAfter: TimeInterval,
        idleAfter: TimeInterval = defaultIdleAfter,
        received: @escaping @Sendable ([UInt8], UInt64) -> Void,
        changed: @escaping @Sendable (Event) -> Void
    ) {
        self.idleAfter = idleAfter
        self.received = received
        opener = PortListener(
            port: port, host: host, retryAfter: retryAfter, queue: queue,
            parameters: { .udp }, changed: changed)
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

    /// いま持っている送り元の数 (検査が上限を確かめるため)。
    var connectionCount: Int { queue.sync { senders.count } }

    /// 閉じる。**閉じ終わるまで待つ** — 返った後に届いたものは渡さない。
    func stop() {
        queue.sync { [self] in
            stopped = true
            opener.cancel()
            for sender in senders { sender.connection.cancel() }
            senders.removeAll()
        }
    }

    // MARK: - 待ち行列の上

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if senders.count >= Self.connectionLimit {
            senders.removeAll { sender in
                guard now - sender.heard >= idleAfter else { return false }
                sender.connection.cancel()
                return true
            }
        }
        senders.append((connection, now))
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                senders.removeAll { $0.connection === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            let hostTime = mach_absolute_time()
            guard let self, let connection, !stopped else { return }
            guard let content, error == nil else {
                connection.cancel()
                return
            }
            if let index = senders.firstIndex(where: { $0.connection === connection }) {
                senders[index].heard = ProcessInfo.processInfo.systemUptime
            }
            received([UInt8](content), hostTime)
            receive(on: connection)
        }
    }
}

/// UDP で 1 つの宛先へ送る。
protocol DatagramSending: AnyObject, Sendable {
    /// 送る。待たずに返る。
    func send(_ bytes: [UInt8])
    /// 閉じる。
    func stop()
}

/// UDP で 1 つの宛先 (ホストとポート) へ送る。
///
/// **送れなくても投げない。** 送れないときは理由を添えて 1 度だけ知らせ、送れたら、また知らせられる
/// ように戻す。知らせるのは 2 つの形である。
///
/// - **繋ぎが失敗した** (`failed`。宛先で誰も受けていない `connection refused` など) — 繋ぎを捨て、
///   次に送るときに繋ぎ直す
/// - **繋ぎが待っている** (`waiting`。`Network is down` など) — 繋ぎは Network.framework が自分で
///   待ち続けるので捨てない。待っている間は送ったものの完了が 1 度も返らず、知らせなければ**黙って
///   消える**。ネットワークが生きているのに待つなら、このアプリにローカルネットワークの許可が
///   無いことがある (束ねた `.app` で、ダイアログが出ないまま塞がれたときに実測した — #1962)。
///   `Network is down` は Wi-Fi が落ちているときにも出るので、許可の拒否と断定はしない
///
/// 送れないことは受け口の状態 (``OSCPort/state``) には出さない。
nonisolated final class DatagramSender: DatagramSending, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``connection``・``warned``) は ``queue`` の上でだけ触る。

    let host: String
    let port: Int
    private let queue = DispatchQueue(label: "org.mokume.network.sender")
    private let warn: @Sendable (String) -> Void
    private var connection: NWConnection?
    private var warned = false

    init(host: String, port: Int, warn: @escaping @Sendable (String) -> Void) {
        self.host = host
        self.port = port
        self.warn = warn
    }

    func send(_ bytes: [UInt8]) {
        queue.async { [self] in
            let connection = connection ?? open()
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { [weak self, weak connection] error in
                    self?.finished(sending: error, on: connection)
                })
        }
    }

    func stop() {
        queue.sync { [self] in
            connection?.cancel()
            connection = nil
        }
    }

    /// 待ち行列の上で手続きを走らせる。検査が状態の読み替え (``changed(to:on:)``・
    /// ``finished(sending:on:)``) を、本物の繋ぎを作らずに呼ぶための口。
    func onQueue<Result>(_ body: () -> Result) -> Result {
        queue.sync(execute: body)
    }

    // MARK: - 待ち行列の上

    private func open() -> NWConnection {
        let opened = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any,
            using: .udp)
        opened.stateUpdateHandler = { [weak self, weak opened] state in
            self?.changed(to: state, on: opened)
        }
        opened.start(queue: queue)
        connection = opened
        return opened
    }

    /// 繋ぎの移り変わりを読む。送れない形なら 1 度だけ知らせる。
    func changed(to state: NWConnection.State, on opened: NWConnection?) {
        switch state {
        case .waiting(let error):
            // 繋ぎは Network.framework が自分で待ち続ける。捨てずに、送れないことだけを言う
            tell(error, waiting: true)
        case .failed(let error):
            if let opened { drop(opened) }
            tell(error, waiting: false)
        default:
            break
        }
    }

    /// 1 つ送り終えた。送れたら、また知らせられるように戻す。
    func finished(sending error: NWError?, on sent: NWConnection?) {
        guard let error else {
            warned = false
            return
        }
        if let sent { drop(sent) }
        tell(error, waiting: false)
    }

    /// 繋ぎを捨てる。次に送るときに作り直す。
    private func drop(_ failed: NWConnection) {
        failed.cancel()
        if connection === failed { connection = nil }
    }

    private func tell(_ error: NWError, waiting: Bool) {
        guard !warned else { return }
        warned = true
        let head = "Could not send to \(host):\(port) (\(Self.describe(error)))."
        if waiting {
            warn(
                head + " If the network is up, this app may not be allowed to reach the local "
                    + "network: check System Settings > Privacy & Security > Local Network. It keeps "
                    + "waiting for the connection")
        } else {
            warn(head + " Check that something is listening there; the next message tries again")
        }
    }

    /// 失敗の名乗り。POSIX の失敗は OS の文面 (`Network is down` など) にする。
    static func describe(_ error: NWError) -> String {
        guard case .posix(let code) = error else { return error.debugDescription }
        return String(cString: strerror(code.rawValue))
    }
}
