// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

/// UDP で文字列を受けて送る入り口。``Sketch/createUDP(listen:send:)`` が作り、走っているスケッチへ足す。
///
/// 1 つの datagram が 1 つのメッセージになる。受け方・状態・止め方は ``TextPort`` のとおり。
///
/// ```swift
/// final class Remote: Sketch {
///     var udp: UDPPort?
///     var size: Float = 0.5
///     func setup() { udp = try? createUDP(listen: 6000, send: ("127.0.0.1", 6001)) }
///     func draw() {
///         for text in udp?.messages ?? [] { size = Float(text) ?? size }
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { udp?.send("hit") }
/// }
/// ```
///
/// 端末から `nc -u 127.0.0.1 6000` で繋いで `0.3` と打つと円が変わり、`nc -u -l 6001` で
/// 待っていればクリックの `hit` が出る。
///
/// **送れないことは ``TextPort/state`` に出ない。** ``TextPort/state`` が名乗るのは受けるほうの
/// 様子である。送れないとき (宛先で誰も受けていない・このアプリにローカルネットワークの許可が
/// 無い・ネットワークが落ちている) は、1 度だけ診断に出す。送れたら、また言えるように戻る。
public final class UDPPort: TextPort {
    private let outbound: (any DatagramSending)?

    init(
        port: Int?, name: String, source: any MessageSource<String>,
        outbound: (any DatagramSending)?, owner: (any Sketch)?,
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.outbound = outbound
        super.init(port: port, name: name, source: source, owner: owner, warn: warn)
    }

    /// 作るときに決めた送り先 (``Sketch/createUDP(listen:send:)`` の `send`) へ、文字列を
    /// 1 つの datagram として送る。
    ///
    /// <!-- example: 文脈 var udp: UDPPort? -->
    /// ```swift
    /// udp?.send("hit")
    /// udp?.send("size 0.5")
    /// ```
    ///
    /// UTF-8 のバイト列をそのまま送り、改行は足さない。**投げない。** 送り先が無い・止めた後は、
    /// 理由ごとに 1 度だけ知らせて何もしない。送れないとき (宛先で誰も受けていない・このアプリに
    /// ローカルネットワークの許可が無い・ネットワークが落ちている) は 1 度だけ診断に出し、
    /// ``TextPort/state`` には出ない。送れたら、また言えるように戻る。待たずに返る。
    ///
    /// - Parameter text: 送る文字列。
    public func send(_ text: String) {
        guard !closed else {
            tellOnce("stopped", "This UDP port is stopped, so \(Self.preview(text)) was not sent")
            return
        }
        guard let outbound else {
            if port == nil {
                tellOnce(
                    "recorded",
                    "This UDP port replays recorded messages and has nowhere to send, so "
                        + "\(Self.preview(text)) was not sent")
            } else {
                tellOnce(
                    "nowhere",
                    "This UDP port has nowhere to send, so \(Self.preview(text)) was not sent. "
                        + "Pass send: (host, port) to createUDP(listen:send:)")
            }
            return
        }
        outbound.send(Array(text.utf8))
    }

    override func closeOutbound() {
        outbound?.stop()
    }
}
