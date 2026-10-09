// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// UDP のポートで受ける OSC の出どころ。届いた datagram をその場で読み、メッセージにして列へ入れる。
///
/// 読めないところがあれば、その datagram の残りを捨てて列に数える (``OSCCodec``)。ポートが
/// 使用中・拒まれた・失敗したときは状態に写し、それぞれ 1 度だけ知らせる (``ListenerStatus``)。
typealias NetworkOSCSource = DatagramSource<OSCMessage>

extension DatagramSource where Message == OSCMessage {
    /// OSC のパケットを読む出どころを作る。
    ///
    /// `now` は送り元の黙りを測る時計で、``DatagramListener`` へそのまま渡す (#2225)。
    convenience init(
        port: Int, host: String? = nil, retryAfter: TimeInterval = defaultRetry,
        idleAfter: TimeInterval = DatagramListener.defaultIdleAfter,
        now: @escaping @Sendable () -> TimeInterval = DatagramListener.systemClock,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            label: "OSC", port: port, host: host, retryAfter: retryAfter, idleAfter: idleAfter,
            now: now,
            decode: { bytes in
                let decoded = OSCCodec.decode(bytes)
                return (decoded.messages, decoded.readable ? 0 : 1)
            },
            warn: warn)
    }
}
