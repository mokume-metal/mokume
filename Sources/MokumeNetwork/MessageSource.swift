// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import Synchronization

/// メッセージの出どころ。**実物のポートも注入した列も、同じ落とさない列 (``ExternalQueue``) へ
/// メッセージを入れる** ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
///
/// 列から先 (``OSCPort``・``TextPort``) は出どころを知らない。だから注入した列で回した検査が、
/// 実物で受けたときの受け渡しの正しさをそのまま固定する。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
protocol MessageSource<Message>: AnyObject {
    /// 届くメッセージの型。
    associatedtype Message: Sendable
    /// 始める。状態は `queue` へ入れる。
    func start(into queue: ExternalQueue<Message>)
    /// フレームごと、取り出す前に呼ばれる。
    func pump(into queue: ExternalQueue<Message>)
    /// 止める。返った後は何も入れない。
    func stop()
}

/// 記録したメッセージの列を、フレームごとに 1 束ずつ入れる出どころ。**ポートも開かない。**
///
/// `batches[i]` は、開いてから i 回目の取り出しで届く。終わりまで行けば始まりへ戻る。どの束が
/// 入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても同じメッセージが同じ
/// フレームに届く ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedSource<Message: Sendable>: MessageSource {
    let batches: [[Message]]
    private var next = 0

    init(batches: [[Message]]) {
        self.batches = batches
    }

    func start(into queue: ExternalQueue<Message>) {
        next = 0
        queue.setState(.running)
    }

    func pump(into queue: ExternalQueue<Message>) {
        guard queue.state == .running, !batches.isEmpty else { return }
        for message in batches[next] { queue.send(message) }
        next = (next + 1) % batches.count
    }

    func stop() {}
}

/// 受け口の移り変わり (``PortListener/Event``) を列の状態に写し、初めてのものを 1 度だけ言う。
///
/// OSC・UDP・TCP・WebSocket が同じ文面で名乗る (``label`` だけが違う)。受けられたら、また
/// 言えるように戻す。
nonisolated final class ListenerStatus: Sendable {
    /// 文面の頭に出す名乗り (`OSC`・`UDP`・`TCP`・`WebSocket`)。
    let label: String
    /// 頼んだポート。文面に出す。
    let port: Int
    /// 開き直すまでの秒数。文面に出す。
    let retryAfter: TimeInterval
    private let warn: @Sendable (String) -> Void
    /// 知らせた移り変わり。同じものは 2 度言わない。
    private let told = Mutex<Set<String>>([])
    /// 実際に開いたポート。開くまで `nil`。
    private let bound = Mutex<Int?>(nil)

    init(
        label: String, port: Int, retryAfter: TimeInterval,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.label = label
        self.port = port
        self.retryAfter = retryAfter
        self.warn = warn
    }

    /// 実際に開いたポート。0 を頼んだときに、OS が選んだ番号を知るために使う。
    var boundPort: Int? { bound.withLock { $0 } }

    /// 移り変わりを状態に写し、初めてのものなら知らせる。
    func apply<Value>(_ event: PortListener.Event, to queue: ExternalQueue<Value>) {
        switch event {
        case .ready(let opened):
            bound.withLock { $0 = opened }
            queue.setState(.running)
            told.withLock { $0.removeAll() }
        case .portInUse:
            queue.setState(.unavailable)
            tellOnce(
                "portInUse",
                "\(label) cannot listen on port \(port) because another app is using it. It starts "
                    + "receiving when the port is freed")
        case .denied:
            queue.setState(.denied)
            tellOnce(
                "denied",
                "\(label) on port \(port) is blocked by macOS (Local Network). Allow it in System "
                    + "Settings > Privacy & Security > Local Network, then start the sketch again")
        case .failed(let reason):
            queue.setState(queue.state == .running ? .disconnected : .unavailable)
            tellOnce(
                "failed",
                "\(label) cannot listen on port \(port) (\(reason)). It tries again every "
                    + "\(Int(retryAfter.rounded(.up))) second(s)")
        }
    }

    private func tellOnce(_ key: String, _ message: String) {
        let first = told.withLock { $0.insert(key).inserted }
        if first { warn(message) }
    }
}

/// UDP のポートで受ける出どころ。届いた datagram をその場で読み、メッセージにして列へ入れる。
///
/// 読み方 (`decode`) だけを差し替える — OSC はパケットを読み、文字列は 1 datagram を 1 つの
/// 文字列にする。読めなかった数は列に数える。ポートが使用中・拒まれた・失敗したときは
/// ``ListenerStatus`` が状態に写し、それぞれ 1 度だけ知らせる。
nonisolated final class DatagramSource<Message: Sendable>: MessageSource, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``listener`` だけで、main actor (start / stop) でだけ
    // 触る。受け口の手続きが触るのは ``status`` (錠を持つ) と列 (それ自身が錠を持つ) だけ。

    /// 1 つの datagram を読んだ結果。`unreadable` は読めずに捨てた数。
    typealias Decode = @Sendable ([UInt8]) -> (messages: [Message], unreadable: Int)

    let port: Int
    let host: String?
    let retryAfter: TimeInterval
    let idleAfter: TimeInterval
    private let decode: Decode
    private let status: ListenerStatus
    private var listener: DatagramListener?

    /// 失敗したとき、何秒後に開き直すか (既定)。
    static var defaultRetry: TimeInterval { 1 }

    init(
        label: String, port: Int, host: String? = nil, retryAfter: TimeInterval = defaultRetry,
        idleAfter: TimeInterval = DatagramListener.defaultIdleAfter,
        decode: @escaping Decode, warn: @escaping @Sendable (String) -> Void
    ) {
        self.port = port
        self.host = host
        self.retryAfter = retryAfter
        self.idleAfter = idleAfter
        self.decode = decode
        status = ListenerStatus(label: label, port: port, retryAfter: retryAfter, warn: warn)
    }

    /// 実際に開いたポート。0 を頼んだときに、OS が選んだ番号を知るために使う。
    var boundPort: Int? { status.boundPort }

    /// 受け口がいま持っている送り元の数 (検査が上限を確かめるため)。
    var connectionCount: Int { listener?.connectionCount ?? 0 }

    func start(into queue: ExternalQueue<Message>) {
        queue.setState(.unavailable)
        let listener = DatagramListener(
            port: port, host: host, retryAfter: retryAfter, idleAfter: idleAfter,
            received: { [decode] bytes, hostTime in
                let decoded = decode(bytes)
                for message in decoded.messages { queue.send(message, hostTime: hostTime) }
                queue.discardUnreadable(decoded.unreadable)
            },
            changed: { [status] event in
                status.apply(event, to: queue)
            })
        self.listener = listener
        listener.start()
    }

    func pump(into queue: ExternalQueue<Message>) {}

    func stop() {
        listener?.stop()
        listener = nil
    }
}
