// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

/// WebSocket で外のサーバへ繋ぎに行く入り口。``Sketch/createWebSocketClient(_:)`` が作り、走っている
/// スケッチへ足す。
///
/// サーバから届いたものは、1 通ずつ、届いた順に ``TextPort/messages`` へ入る。``send(_:)`` は繋いだ先の
/// サーバへ 1 通の text を送る。受け方・状態・止め方は ``TextPort`` のとおり。
///
/// ```swift
/// final class Remote: Sketch {
///     var socket: WebSocketClient?
///     var size: Float = 0.5
///     func setup() { socket = try? createWebSocketClient("wss://relay.example/room") }
///     func draw() {
///         for text in socket?.messages ?? [] { size = Float(text) ?? size }
///         background(20)
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { socket?.send("hit") }
/// }
/// ```
///
/// **繋げなくても、切れても、1 秒ごとに繋ぎ直し続ける。** 間隔は固定で、変える口は無い。状態の名乗り方は
/// ``TCPClient`` と同じ (``TextPort`` の「来ないことには理由がある」)。
///
/// 手本 (Processing / p5.js) の本体には無いので、ブラウザの `WebSocket.send` に揃えて 1 通を送る口を
/// ``send(_:)`` とする ([ADR-0020] 決定 1。``WebSocketServer`` と同じ)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public final class WebSocketClient: TextPort {
    /// 繋ぎ先の URL の綴り。診断の文面に出す。
    let target: String

    init(
        target: String, name: String, source: any MessageSource<String>,
        clients: (any Broadcasting)?, owner: (any Sketch)?,
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.target = target
        super.init(
            port: nil, name: name, source: source, clients: clients, owner: owner, warn: warn)
    }

    /// 繋いだ先のサーバへ、文字列を 1 通の text として送る。
    ///
    /// <!-- example: 文脈 var socket: WebSocketClient? -->
    /// ```swift
    /// socket?.send("hit")
    /// ```
    ///
    /// 1 回の `send` が、サーバに 1 通届く。改行は足さない。
    ///
    /// **投げない。** 繋がっていない間・止めた後は、理由ごとに 1 度だけ知らせて何もしない — 繋がっていない
    /// 間に送ったものは、繋がった後に届かない。待たずに返る。
    ///
    /// - Parameter text: 送る文字列。
    public func send(_ text: String) {
        sendToServer(text, by: "WebSocket client", target: target, verb: "sent")
    }
}
