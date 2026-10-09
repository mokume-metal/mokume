// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// TCP で繋いでくる相手を待つ入り口。``Sketch/createTCPServer(_:)`` が作り、走っているスケッチへ足す。
///
/// 相手は何人でも繋げる。どの相手から届いたものも、改行で区切った 1 行ずつ、届いた順に
/// ``TextPort/messages`` へ入る。``write(_:)`` は繋いでいる相手全員へ書く。受け方・状態・止め方・
/// 相手の数え方は ``TextPort`` のとおり。
///
/// ```swift
/// final class Remote: Sketch {
///     var server: TCPServer?
///     var size: Float = 0.5
///     func setup() { server = try? createTCPServer(5204) }
///     func draw() {
///         for line in server?.messages ?? [] { size = Float(line) ?? size }
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { server?.write("hit\n") }
/// }
/// ```
///
/// 端末から `nc 127.0.0.1 5204` で繋いで `0.3` と打つと円が変わり、クリックの `hit` が同じ
/// 端末に出る。
///
/// **Processing の `Server` (`processing.net`) に当たる。** ``write(_:)``・``clientCount``・
/// ``TextPort/stop()`` の名前と引数の順序はそれに倣う。型の名前だけは方式を名乗る
/// (``WebSocketServer``・``UDPPort`` と並べて方式が名前で分かるように — [ADR-0020] 決定 1)。
/// 受けたものは、Processing の `available()` / `readString()` で相手ごとに引き出す形ではなく、
/// フレームごとに ``TextPort/messages`` で読む ([ADR-0010] 決定 5 — 取りこぼすと意味が変わる
/// 出来事の列は、落とさない列に溜めてフレームで読む)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public final class TCPServer: TextPort {
    /// このフレームの頭に繋いでいた相手の数。止めた後は 0 (``TextPort`` の「相手が居ないことも読める」)。
    public var clientCount: Int { connected }

    /// 繋いでいる相手全員へ、文字列を書く。
    ///
    /// <!-- example: 文脈 var server: TCPServer? -->
    /// ```swift
    /// server?.write("hit\n")
    /// ```
    ///
    /// UTF-8 のバイト列を流れにそのまま書き、**改行は足さない** (Processing の `write` と同じ)。
    /// 行で読む相手 (`nc` や、別の mokume の ``TCPServer``) へは `"hit\n"` と改行まで書く。
    ///
    /// **投げない。** 相手が 1 人も居ない・止めた後は、理由ごとに 1 度だけ知らせて何もしない。
    /// 書けなかった相手は切り、``clientCount`` から外れる。待たずに返る。
    ///
    /// - Parameter text: 書く文字列。
    public func write(_ text: String) {
        deliver(text, by: "TCP server", verb: "written")
    }
}
