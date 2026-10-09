// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// WebSocket で繋いでくる相手 (ブラウザなど) を待つ入り口。``Sketch/createWebSocketServer(_:)`` が
/// 作り、走っているスケッチへ足す。
///
/// 相手は何人でも繋げる。どの相手から届いたものも、1 通ずつ、届いた順に ``TextPort/messages`` へ
/// 入る。``send(_:)`` は繋いでいる相手全員へ 1 通ずつ送る。受け方・状態・止め方・相手の数え方は
/// ``TextPort`` のとおり。
///
/// ```swift
/// final class Remote: Sketch {
///     var socket: WebSocketServer?
///     var size: Float = 0.5
///     func setup() { socket = try? createWebSocketServer(8025) }
///     func draw() {
///         for text in socket?.messages ?? [] { size = Float(text) ?? size }
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { socket?.send("hit") }
/// }
/// ```
///
/// ブラウザの console で `ws = new WebSocket("ws://localhost:8025")` と繋いで `ws.send("0.3")` すると
/// 円が変わり、`ws.onmessage` にクリックの `hit` が届く。
///
/// 手本 (Processing / p5.js) の本体には無いので、Swift の慣行と、ブラウザの `WebSocket.send` に
/// 揃えて 1 通を送る口を ``send(_:)`` とする ([ADR-0020] 決定 1)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public final class WebSocketServer: TextPort {
    /// このフレームの頭に繋いでいた相手の数。止めた後は 0 (``TextPort`` の「相手が居ないことも読める」)。
    public var clientCount: Int { connected }

    /// 繋いでいる相手全員へ、文字列を 1 通の text として送る。
    ///
    /// <!-- example: 文脈 var socket: WebSocketServer? -->
    /// ```swift
    /// socket?.send("hit")
    /// ```
    ///
    /// 1 回の `send` が、相手のブラウザの `onmessage` に 1 度届く。改行は足さない。
    ///
    /// **投げない。** 相手が 1 人も居ない・止めた後は、理由ごとに 1 度だけ知らせて何もしない。
    /// 送れなかった相手は切り、``clientCount`` から外れる。待たずに返る。
    ///
    /// - Parameter text: 送る文字列。
    public func send(_ text: String) {
        deliver(text, by: "WebSocket server", verb: "sent")
    }
}
