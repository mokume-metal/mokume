// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

/// 繋いでくる相手を待つ入り口 (TCP・WebSocket)。``Sketch/createServer(_:)`` (TCP) と
/// ``Sketch/createWebSocketServer(_:)`` が作り、走っているスケッチへ足す。
///
/// 相手は何人でも繋げる。どの相手から届いたものも、届いた順に ``TextPort/messages`` へ入る
/// (TCP は改行で区切った 1 行、WebSocket は 1 通が 1 つ)。``write(_:)`` は繋いでいる相手全員へ
/// 書く。受け方・状態・止め方は ``TextPort`` のとおり。
///
/// ```swift
/// final class Remote: Sketch {
///     var server: Server?
///     var size: Float = 0.5
///     func setup() { server = try? createServer(5204) }
///     func draw() {
///         for line in server?.messages ?? [] { size = Float(line) ?? size }
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { server?.write("hit\n") }
/// }
/// ```
///
/// 端末から `nc 127.0.0.1 5204` で繋いで `0.3` と打つと円が変わり、クリックの `hit` が同じ
/// 端末に出る。`createServer(5204)` を `createWebSocketServer(8025)` に替えれば、ブラウザから
/// `new WebSocket("ws://localhost:8025")` で繋いで `send("0.3")` した値で同じように動く。
///
/// ## 相手が居ないことも読める
///
/// ``clientCount`` は、そのフレームの頭に繋いでいた相手の数である。相手が切れれば減る。
/// 相手が 1 人も居ないときに ``write(_:)`` しても届く先が無いので、1 度だけ診断に出す (書けたら、
/// また言えるように戻る)。
///
/// 手本は Processing の `Server` (TCP) で、作る口 (`new Server(this, 5204)`)・``write(_:)``・
/// ``clientCount``・``TextPort/stop()`` の名前と引数の順序を倣う。WebSocket は手本に無いが、
/// 繋いでくる相手を待って全員へ書く点が同じなので、同じ型にした。受けたものは、Processing の
/// `available()` / `readString()` で相手ごとに引き出す形ではなく、フレームごとに ``TextPort/messages``
/// で読む ([ADR-0010] 決定 5 — 取りこぼすと意味が変わる出来事の列は、落とさない列に溜めて
/// フレームで読む)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public final class Server: TextPort {
    /// このフレームの頭に繋いでいた相手の数。止めた後は 0。
    public private(set) var clientCount = 0

    private let clients: (any Broadcasting)?

    init(
        port: Int?, name: String, source: any MessageSource<String>,
        clients: (any Broadcasting)?, owner: (any Sketch)?,
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.clients = clients
        super.init(port: port, name: name, source: source, owner: owner, warn: warn)
    }

    /// 繋いでいる相手全員へ、文字列を書く。
    ///
    /// <!-- example: 文脈 var server: Server? -->
    /// ```swift
    /// server?.write("hit\n")
    /// ```
    ///
    /// TCP では UTF-8 のバイト列をそのまま書き、**改行は足さない** (Processing の `write` と同じ)。
    /// 行で読む相手 (`nc` や、別の mokume の ``Server``) へは `"hit\n"` と改行まで書く。WebSocket
    /// では 1 回の `write` が 1 通の text になる (ブラウザの `onmessage` に 1 度届く)。
    ///
    /// **投げない。** 相手が 1 人も居ない・止めた後は、理由ごとに 1 度だけ知らせて何もしない。
    /// 書けなかった相手は切り、``clientCount`` から外れる。待たずに返る。
    ///
    /// - Parameter text: 書く文字列。
    public func write(_ text: String) {
        guard !closed else {
            tellOnce("stopped", "This server is stopped, so \(Self.preview(text)) was not written")
            return
        }
        guard let clients else {
            tellOnce(
                "recorded",
                "This server replays recorded messages and has no clients, so "
                    + "\(Self.preview(text)) was not written")
            return
        }
        guard clients.clientCount > 0 else {
            tellOnce(
                "noClient",
                "No client is connected to the server on port \(port ?? 0), so "
                    + "\(Self.preview(text)) was not written. It reaches the clients connected "
                    + "when it is written")
            return
        }
        forget("noClient")
        clients.broadcast(text)
    }

    override func refresh() {
        clientCount = clients?.clientCount ?? 0
    }
}
