// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network

// UDP の受け・送り。**OSC 固有のものは持たない** — 中身のバイト列をどう読むかは上の層
// (OSC の ``OSCCodec``) が決める。TCP・UDP・WebSocket の口 (#2018) も、UDP はこの層を使う
// 前提で置く。公開の UDP の口の形はそちらが作例で決めるので、ここは internal に留める。
//
// Network.framework の受け口は待ち行列を引数に取る。ここはその待ち行列の上で受けて、
// 届いたバイト列と状態を手続きへ渡すところで手を離す ([ADR-0042] 決定 7 の条件 — 受ける点
// でしかない・境界を越えるのは `Sendable` な値だけ・利用者に漏らさない)。
//
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md

/// UDP のポートを 1 つ開いて、届いた datagram を 1 つずつ渡す。
///
/// **ポートが使えなくても投げない。** 使用中・失敗のときは ``Event`` で知らせ、
/// ``retryAfter`` 秒ごとに開き直す — 握っていた他のアプリが終われば、そこから受け始める
/// ([ADR-0028] 決定 3 の「使えなくなったことが読める」と、起動後の抜き差しへの追随)。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated final class DatagramListener: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``listener``・``senders``・``stopped``) は
    // ``queue`` の上でだけ触る。Network.framework の手続きもすべて ``queue`` で走らせる。

    /// 受け口の移り変わり。
    enum Event: Sendable, Equatable {
        /// 受けられる。`port` は実際に開いたポート (0 を頼んだときは OS が選んだ番号)。
        case ready(port: Int)
        /// 他のアプリがそのポートを使っている。開き直し続ける。
        case portInUse
        /// OS の方針 (ローカルネットワークの許可) で拒まれている。
        case denied
        /// それ以外の理由で受けられない。開き直し続ける。
        case failed(String)
    }

    /// 頼んだポート。0 なら OS が空いている番号を選ぶ。
    let port: Int
    /// 受けるアドレス。`nil` ならすべての口 (別の機械からも届く)。
    let host: String?
    /// 失敗したとき、何秒後に開き直すか。
    let retryAfter: TimeInterval
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
    private let changed: @Sendable (Event) -> Void
    private var listener: NWListener?
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
        self.port = port
        self.host = host
        self.retryAfter = retryAfter
        self.idleAfter = idleAfter
        self.received = received
        self.changed = changed
    }

    /// 開き始める。待たずに返る。
    func start() {
        queue.async { [self] in listen() }
    }

    /// いま持っている送り元の数 (検査が上限を確かめるため)。
    var connectionCount: Int { queue.sync { senders.count } }

    /// 閉じる。**閉じ終わるまで待つ** — 返った後に届いたものは渡さない。
    func stop() {
        queue.sync { [self] in
            stopped = true
            listener?.cancel()
            listener = nil
            for sender in senders { sender.connection.cancel() }
            senders.removeAll()
        }
    }

    // MARK: - 待ち行列の上

    private func listen() {
        guard !stopped else { return }
        let parameters = NWParameters.udp
        let wanted = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        let opened: NWListener
        do {
            if let host {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: wanted)
                opened = try NWListener(using: parameters)
            } else {
                opened = try NWListener(using: parameters, on: wanted)
            }
        } catch {
            fail(Self.event(for: error))
            return
        }
        listener = opened
        opened.stateUpdateHandler = { [weak self, weak opened] state in
            guard let self, let opened else { return }
            self.listenerChanged(opened, to: state)
        }
        opened.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        opened.start(queue: queue)
    }

    private func listenerChanged(_ opened: NWListener, to state: NWListener.State) {
        // 開き直した後に、前の受け口の知らせが遅れて届くことがある
        guard !stopped, opened === listener else { return }
        switch state {
        case .ready:
            changed(.ready(port: Int(opened.port?.rawValue ?? UInt16(clamping: port))))
        case .waiting(let error):
            // 経路を待っている間は Network.framework が自分で開き直す
            changed(Self.event(for: error))
        case .failed(let error):
            // 使用中はここに来る (`EADDRINUSE`。2026-10-06 に 127.0.0.1 とすべての口の両方で実測)。
            // 閉じて、間を空けて自分で開き直す
            opened.cancel()
            listener = nil
            fail(Self.event(for: error))
        default:
            break
        }
    }

    /// 知らせて、間を空けて開き直す。
    private func fail(_ event: Event) {
        changed(event)
        queue.asyncAfter(deadline: .now() + retryAfter) { [weak self] in
            guard let self, listener == nil else { return }
            listen()
        }
    }

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

    /// Network.framework の失敗を、受け口の移り変わりに読み替える。
    static func event(for error: any Error) -> Event {
        guard let error = error as? NWError else { return .failed("\(error)") }
        switch error {
        case .posix(let code) where code == .EADDRINUSE:
            return .portInUse
        case .dns(let code) where code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied):
            return .denied
        default:
            return .failed(error.localizedDescription)
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
