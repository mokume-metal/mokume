// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

/// TCP で外のサーバへ繋ぎに行く入り口。``Sketch/createTCPClient(_:_:)`` が作り、走っているスケッチへ足す。
///
/// サーバから届いたものは、改行で区切った 1 行ずつ、届いた順に ``TextPort/messages`` へ入る。
/// ``write(_:)`` は繋いだ先のサーバへ書く。受け方・状態・止め方は ``TextPort`` のとおり。
///
/// ```swift
/// final class Remote: Sketch {
///     var link: TCPClient?
///     var size: Float = 0.5
///     func setup() throws { link = try createTCPClient("127.0.0.1", 7000) }
///     func draw() {
///         for line in link?.messages ?? [] { size = Float(line) ?? size }
///         background(20)
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { link?.write("hit\n") }
/// }
/// ```
///
/// **繋げなくても、切れても、1 秒ごとに繋ぎ直し続ける。** 間隔は固定で、変える口は無い。繋ぎ直す間
/// ``TextPort/state`` は、まだ一度も繋がっていなければ ``SourceState/unavailable``、繋がっていたのが切れたなら
/// ``SourceState/disconnected`` を名乗り、繋がれば ``SourceState/running`` に戻る。このアプリにローカルネットワークの
/// 許可が無くて繋げないときは ``SourceState/denied`` を名乗り、診断に許可の直し方を 1 度だけ出す (許可されれば
/// 次の繋ぎ直しで ``SourceState/running`` に戻る)。
///
/// **Processing の `Client` (`processing.net`) に当たる。** ``write(_:)`` の名前と引数の順序はそれに倣う。
/// 型の名前は方式を名乗る (``TCPServer``・``WebSocketClient`` と並べて方式が名前で分かるように —
/// [ADR-0020] 決定 1)。受けたものは、Processing の `available()` / `readString()` で引き出す形ではなく、
/// フレームごとに ``TextPort/messages`` で読む ([ADR-0010] 決定 5)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public final class TCPClient: TextPort {
    /// 繋ぎ先の綴り (`127.0.0.1:7000`)。診断の文面に出す。
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

    /// 繋いだ先のサーバへ、文字列を書く。
    ///
    /// <!-- example: 文脈 var link: TCPClient? -->
    /// ```swift
    /// link?.write("0.3\n")
    /// ```
    ///
    /// UTF-8 のバイト列を流れにそのまま書き、**改行は足さない** (Processing の `write` と同じ)。
    /// 行で読む相手 (`nc -l` や、mokume の ``TCPServer``) へは `"0.3\n"` と改行まで書く。
    ///
    /// **投げない。** 繋がっていない間・止めた後は、理由ごとに 1 度だけ知らせて何もしない — 繋がっていない
    /// 間に書いたものは、繋がった後に届かない。待たずに返る。
    ///
    /// - Parameter text: 書く文字列。
    public func write(_ text: String) {
        sendToServer(text, by: "TCP client", target: target, verb: "written")
    }
}
