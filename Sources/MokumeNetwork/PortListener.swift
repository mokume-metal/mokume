// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network

// ポートを開く層。**UDP・TCP・WebSocket の受け口に共通の部分だけを持つ** — 開く・使用中を
// 見分ける・間を空けて開き直す・移り変わりを知らせる。繋いできたもの (`NWConnection`) を
// どう読むかは持ち主 (``DatagramListener``・``StreamListener``) が決める。
//
// Network.framework の受け口は待ち行列を引数に取る。ここは持ち主の待ち行列の上で受けて、
// 移り変わりを手続きへ渡すところで手を離す ([ADR-0042] 決定 7 の条件 — 受ける点でしか
// ない・境界を越えるのは `Sendable` な値だけ・利用者に漏らさない)。
//
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md

/// ポートを 1 つ開いて、繋いできたものを持ち主へ渡す。
///
/// **ポートが使えなくても投げない。** 使用中・失敗のときは ``Event`` で知らせ、
/// ``retryAfter`` 秒ごとに開き直す — 握っていた他のアプリが終われば、そこから受け始める
/// ([ADR-0028] 決定 3 の「使えなくなったことが読める」と、起動後の抜き差しへの追随)。
///
/// 手続きはすべて持ち主の待ち行列 (``queue``) の上で走る。``cancel()`` も同じ待ち行列の上で呼ぶ。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated final class PortListener: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``listener``・``accepting``・``stopped``) は ``queue`` の
    // 上でだけ触る。Network.framework の手続きもすべて ``queue`` で走らせる。

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

    private let queue: DispatchQueue
    private let parameters: @Sendable () -> NWParameters
    private let changed: @Sendable (Event) -> Void
    private var accepting: (@Sendable (NWConnection) -> Void)?
    private var listener: NWListener?
    private var stopped = false

    /// - Parameters:
    ///   - port: 開くポート。0 なら OS が選ぶ。
    ///   - host: 受けるアドレス。`nil` ならすべての口。
    ///   - retryAfter: 失敗したとき、何秒後に開き直すか。
    ///   - queue: 持ち主の待ち行列。手続きはすべてここで走る。
    ///   - parameters: 開くたびに作る通信の設定 (UDP・TCP・WebSocket)。
    ///   - changed: 移り変わり。``queue`` の上で呼ばれる。
    init(
        port: Int, host: String?, retryAfter: TimeInterval, queue: DispatchQueue,
        parameters: @escaping @Sendable () -> NWParameters,
        changed: @escaping @Sendable (Event) -> Void
    ) {
        self.port = port
        self.host = host
        self.retryAfter = retryAfter
        self.queue = queue
        self.parameters = parameters
        self.changed = changed
    }

    /// 開き始める。待たずに返る。繋いできたものは `accepting` へ ``queue`` の上で渡す。
    func start(accepting: @escaping @Sendable (NWConnection) -> Void) {
        queue.async { [self] in
            self.accepting = accepting
            listen()
        }
    }

    /// 閉じる。**持ち主の待ち行列の上で呼ぶ。** 以後は開き直さない。
    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        listener?.cancel()
        listener = nil
    }

    // MARK: - 待ち行列の上

    private func listen() {
        guard !stopped else { return }
        let parameters = parameters()
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
            guard let self else {
                connection.cancel()
                return
            }
            self.accepting?(connection)
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
            // 使用中はここに来る (`EADDRINUSE`。2026-10-06 に UDP で 127.0.0.1 とすべての口の
            // 両方で実測。TCP も同じ — 検査が固定している)。閉じて、間を空けて自分で開き直す
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
