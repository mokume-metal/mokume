// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

extension DatagramSource where Message == String {
    /// 1 つの datagram を 1 つの文字列として読む出どころを作る (``TextDecoding/datagram(_:)``)。
    static func text(
        port: Int, host: String? = nil, retryAfter: TimeInterval = defaultRetry,
        idleAfter: TimeInterval = DatagramListener.defaultIdleAfter,
        warn: @escaping @Sendable (String) -> Void
    ) -> DatagramSource<String> {
        DatagramSource(
            label: "UDP", port: port, host: host, retryAfter: retryAfter, idleAfter: idleAfter,
            decode: TextDecoding.datagram, warn: warn)
    }
}

/// 届いたバイト列を、``TextPort/messages`` に入れる文字列に読む決まり。
///
/// **末尾の改行は落とす。** `nc` で打った `0.3⏎` は `0.3\n` として届くので、落とさないと
/// `Float("0.3\n")` が `nil` になり、最小の作例が動かない。**UTF-8 として読めないものは
/// 読まずに捨てる** — 推して読むと、黙って別の文字列を渡すことになる (捨てた数は列が数える)。
nonisolated enum TextDecoding {
    /// 1 つのメッセージ (UDP の 1 datagram・WebSocket の 1 通) を読む。末尾の改行 1 つ
    /// (`\n` か `\r\n`) は落とす。UTF-8 として読めなければ `nil`。
    static func message(_ bytes: [UInt8]) -> String? {
        var end = bytes.endIndex
        if end > bytes.startIndex, bytes[end - 1] == newline {
            end -= 1
            if end > bytes.startIndex, bytes[end - 1] == carriageReturn { end -= 1 }
        }
        return String(validating: bytes[..<end], as: UTF8.self)
    }

    /// 1 つの datagram を読んだ結果 (``DatagramSource`` の読み方)。
    static func datagram(_ bytes: [UInt8]) -> (messages: [String], unreadable: Int) {
        guard let text = message(bytes) else { return ([], 1) }
        return ([text], 0)
    }

    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
}
