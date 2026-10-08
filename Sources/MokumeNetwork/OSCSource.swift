// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import Synchronization

/// OSC の出どころ。**実物の UDP も注入した列も、同じ落とさない列 (``ExternalQueue``) へ
/// メッセージを入れる** ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
///
/// 列から先 (``OSCPort``) は出どころを知らない。だから注入した列で回した検査が、実物で受けた
/// ときの受け渡しの正しさをそのまま固定する。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
protocol OSCSource: AnyObject {
    /// 始める。状態は `queue` へ入れる。
    func start(into queue: ExternalQueue<OSCMessage>)
    /// フレームごと、取り出す前に呼ばれる。
    func pump(into queue: ExternalQueue<OSCMessage>)
    /// 止める。返った後は何も入れない。
    func stop()
}

/// UDP のポートで受ける出どころ。届いた datagram をその場で読み、メッセージにして列へ入れる。
///
/// 読めないところがあれば、その datagram の残りを捨てて列に数える (``OSCCodec``)。ポートが
/// 使用中・拒まれた・失敗したときは状態に写し、それぞれ 1 度だけ知らせる。
nonisolated final class NetworkOSCSource: OSCSource, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``listener`` だけで、main actor (start / stop) でだけ
    // 触る。受け口の手続きが触るのは錠の内側 (``told``・``bound``) と列 (それ自身が錠を持つ) だけ。

    let port: Int
    let host: String?
    let retryAfter: TimeInterval
    let idleAfter: TimeInterval
    /// 送り元の黙りを測る時計 (``DatagramListener`` へそのまま渡す)。
    private let now: @Sendable () -> TimeInterval
    private let warn: @Sendable (String) -> Void
    private var listener: DatagramListener?
    /// 知らせた移り変わり。同じものは 2 度言わない (受けられた後にまた言えるよう戻す)。
    private let told = Mutex<Set<String>>([])
    /// 実際に開いたポート。開くまで `nil`。
    private let bound = Mutex<Int?>(nil)

    /// 失敗したとき、何秒後に開き直すか (既定)。
    static let defaultRetry: TimeInterval = 1

    init(
        port: Int, host: String? = nil, retryAfter: TimeInterval = defaultRetry,
        idleAfter: TimeInterval = DatagramListener.defaultIdleAfter,
        now: @escaping @Sendable () -> TimeInterval = DatagramListener.systemClock,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.port = port
        self.host = host
        self.retryAfter = retryAfter
        self.idleAfter = idleAfter
        self.now = now
        self.warn = warn
    }

    /// 実際に開いたポート。0 を頼んだときに、OS が選んだ番号を知るために使う。
    var boundPort: Int? { bound.withLock { $0 } }

    /// 受け口がいま持っている送り元の数 (検査が上限を確かめるため)。
    var connectionCount: Int { listener?.connectionCount ?? 0 }

    /// 受け口の送り元の出入りの数 (検査が「黙っていない送り元は閉じない」を確かめるため)。
    var tally: SenderTally { listener?.tally ?? SenderTally() }

    func start(into queue: ExternalQueue<OSCMessage>) {
        queue.setState(.unavailable)
        let listener = DatagramListener(
            port: port, host: host, retryAfter: retryAfter, idleAfter: idleAfter, now: now,
            received: { bytes, hostTime in
                let decoded = OSCCodec.decode(bytes)
                for message in decoded.messages { queue.send(message, hostTime: hostTime) }
                if !decoded.readable { queue.discardUnreadable() }
            },
            changed: { [self] event in
                apply(event, to: queue)
            })
        self.listener = listener
        listener.start()
    }

    func pump(into queue: ExternalQueue<OSCMessage>) {}

    func stop() {
        listener?.stop()
        listener = nil
    }

    /// 移り変わりを状態に写し、初めてのものなら知らせる。
    private func apply(_ event: DatagramListener.Event, to queue: ExternalQueue<OSCMessage>) {
        switch event {
        case .ready(let opened):
            bound.withLock { $0 = opened }
            queue.setState(.running)
            told.withLock { $0.removeAll() }
        case .portInUse:
            queue.setState(.unavailable)
            tellOnce(
                "portInUse",
                "OSC cannot listen on port \(port) because another app is using it. It starts "
                    + "receiving when the port is freed")
        case .denied:
            queue.setState(.denied)
            tellOnce(
                "denied",
                "OSC on port \(port) is blocked by macOS (Local Network). Allow it in System "
                    + "Settings > Privacy & Security > Local Network, then start the sketch again")
        case .failed(let reason):
            queue.setState(queue.state == .running ? .disconnected : .unavailable)
            tellOnce(
                "failed",
                "OSC cannot listen on port \(port) (\(reason)). It tries again every "
                    + "\(Int(retryAfter.rounded(.up))) second(s)")
        }
    }

    private func tellOnce(_ key: String, _ message: String) {
        let first = told.withLock { $0.insert(key).inserted }
        if first { warn(message) }
    }
}

/// 記録したメッセージの列を、フレームごとに 1 束ずつ入れる出どころ。**ポートも開かない。**
///
/// `batches[i]` は、開いてから i 回目の取り出しで届く。終わりまで行けば始まりへ戻る。どの束が
/// 入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても同じメッセージが同じ
/// フレームに届く ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedOSCSource: OSCSource {
    let batches: [[OSCMessage]]
    private var next = 0

    init(batches: [[OSCMessage]]) {
        self.batches = batches
    }

    func start(into queue: ExternalQueue<OSCMessage>) {
        next = 0
        queue.setState(.running)
    }

    func pump(into queue: ExternalQueue<OSCMessage>) {
        guard queue.state == .running, !batches.isEmpty else { return }
        for message in batches[next] { queue.send(message) }
        next = (next + 1) % batches.count
    }

    func stop() {}
}
