// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

/// ``TCPServer``・``WebSocketServer``・``TCPClient``・``WebSocketClient``・``UDPPort`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。投げるのは渡した値が
/// そもそも使えないときと、走っている実行へ足せない所から呼んだとき (``notRunning(call:)``) だけで、
/// ポートを他のアプリが使っているときは投げずに作り、
/// ``TextPort/state`` が ``SourceState/unavailable`` を名乗る (空けば受け始める)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated enum NetworkFailure: Error, Equatable, Sendable {
    /// ポートの番号が 1〜65535 に入っていない。
    case invalidPort(Int)
    /// 送り先・繋ぎ先のホストが空 (``Sketch/createWebSocketClient(_:)`` では、`ws://` か `wss://` の
    /// URL として読めない綴り)。
    case invalidHost(String)
    /// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外 — 初期化子の中・
    /// 後片付けの後・`Task` の中) で作る口を呼んだ。`call` は呼んだ口の名前 (`"createTCPServer(_:)"` など)。
    /// 作ったものは走っている実行へ足さないと受けず (受けるポートは足したときに開く)、終わるときに閉じられも
    /// しないので、ポートを開く前に断る。`setup()` などから呼び直す
    /// ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。**送るだけなら、これまでは足されていなくても
    /// 届いていた** (``UDPPort/send(_:)`` は足されているかを見ない) — 送り専用のポートを走る前に作っていた作品も、
    /// いまはこの場合になる。
    /// 渡した値が使えないときは、こちらより先にその場合 (``invalidPort(_:)``・``invalidHost(_:)``) を投げる。
    ///
    /// **名前に反して、スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで起こした
    /// `Task` から呼んでもこの場合になる (``ImageFailure/notRunning(call:)`` と同じ)。
    case notRunning(call: String)
}

extension NetworkFailure: NotRunningFailure {}

extension NetworkFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPort(let port): Endpoint.unusablePort(port)
        case .invalidHost(let host): Endpoint.unusableHost(host)
        case .notRunning(let call): Self.notAttachedNotice(call)
        }
    }
}

/// ポートとホストの値が使えるかの決まり。OSC と TCP・UDP・WebSocket の作る口が同じものを使う。
nonisolated enum Endpoint {
    /// 開ける・送れるポートの番号。
    static var usablePorts: ClosedRange<Int> { 1...65535 }

    /// 送り先のホストとして使えるか (空白だけでない)。
    static func isUsable(host: String) -> Bool {
        !host.allSatisfy(\.isWhitespace)
    }

    /// 使えないポートの名乗り。
    static func unusablePort(_ port: Int) -> String {
        "The port \(port) is not usable. Pass a number from 1 to 65535 (9000, for example)"
    }

    /// 使えないホストの名乗り。
    static func unusableHost(_ host: String) -> String {
        "The host \"\(host)\" is not usable. Pass a name or an address to send to "
            + "(\"127.0.0.1\" for this machine, for example). For a WebSocket client it has to be "
            + "a ws:// or wss:// URL (\"ws://127.0.0.1:8025\", for example)"
    }

    /// WebSocket のクライアントが繋ぐ URL。`ws://` か `wss://` で、ホストが在る綴りだけ。
    ///
    /// ポートが書かれていて 1〜65535 に入っていなければ、``NetworkFailure/invalidPort(_:)`` を返す側が使えるように
    /// 別に返す。
    static func webSocketURL(_ text: String) -> (url: URL, secure: Bool, port: Int?)? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
            let scheme = components.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
            let host = components.host, !host.isEmpty, let url = components.url
        else { return nil }
        return (url, scheme == "wss", components.port)
    }
}
