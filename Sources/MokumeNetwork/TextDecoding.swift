// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

extension DatagramSource where Message == String {
    /// 1 つの datagram を 1 つの文字列として読む出どころを作る (``TextDecoding/datagram(_:)``)。
    static func text(
        port: Int, host: String? = nil, retryAfter: TimeInterval = defaultRetry,
        idleAfter: TimeInterval = DatagramListener.defaultIdleAfter,
        now: @escaping @Sendable () -> TimeInterval = DatagramListener.systemClock,
        warn: @escaping @Sendable (String) -> Void
    ) -> DatagramSource<String> {
        DatagramSource(
            label: "UDP", port: port, host: host, retryAfter: retryAfter, idleAfter: idleAfter,
            now: now, decode: TextDecoding.datagram, warn: warn)
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

    /// 1 行 (TCP) を読む。UTF-8 として読めなければ `nil`。改行は ``LineSplitter`` が落としてある。
    static func line(_ bytes: [UInt8]) -> String? {
        String(validating: bytes, as: UTF8.self)
    }

    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
}

/// TCP で届くバイト列を、改行 (`\n`) で行に切る。行の終わりの `\r` は落とす (`\r\n` で送る相手)。
///
/// TCP は区切りを持たない流れなので、1 回に届くバイト列は行の途中で切れていることがある。
/// 切れた残りは次に届くまで持ち、相手が閉じたら、残りを 1 行として渡す (``finish()``) —
/// `echo -n 0.3 | nc …` のように改行で終わらない相手も届く。
///
/// **1 行には上限 (``limit``) を置く。** 改行を送らない相手のところで、持つ残りが際限なく伸び
/// ないためである。超えた行は捨てて数え、次の改行まで読み飛ばす (途中から読み直すと、行の
/// 後半を別の 1 行として渡してしまう)。
nonisolated struct LineSplitter: Sendable {
    /// 1 行のバイト数の上限。
    let limit: Int
    private var pending: [UInt8] = []
    /// 長すぎる行を捨てている途中か (次の改行まで読み飛ばす)。
    private var skipping = false

    init(limit: Int) {
        self.limit = limit
    }

    /// 届いたバイト列を足し、切れた行を返す。`overlong` は、上限を超えて捨てた行の数。
    mutating func append(_ bytes: some Sequence<UInt8>) -> (lines: [[UInt8]], overlong: Int) {
        var lines: [[UInt8]] = []
        var overlong = 0
        for byte in bytes {
            if byte == TextDecoding.newline {
                if skipping {
                    skipping = false
                } else {
                    lines.append(Self.trimmed(pending))
                }
                pending.removeAll(keepingCapacity: true)
                continue
            }
            guard !skipping else { continue }
            pending.append(byte)
            if pending.count > limit {
                pending.removeAll()
                skipping = true
                overlong += 1
            }
        }
        return (lines, overlong)
    }

    /// 相手が閉じた。改行で終わっていない残りを 1 行として返す。無ければ `nil`。
    mutating func finish() -> [UInt8]? {
        defer {
            pending.removeAll()
            skipping = false
        }
        guard !skipping, !pending.isEmpty else { return nil }
        return Self.trimmed(pending)
    }

    private static func trimmed(_ line: [UInt8]) -> [UInt8] {
        line.last == TextDecoding.carriageReturn ? Array(line.dropLast()) : line
    }
}
