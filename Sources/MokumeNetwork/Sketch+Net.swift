// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

// TCP・UDP・WebSocket。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0041] の地図の「連携の口 (標準)」)。`plugins` には何も
// 書かない — 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
//
// 名前 ([ADR-0020] 決定 1): TCP は Processing の `Server` (`new Server(this, port)`・`write`・
// `clientCount`) に倣い、作る口は手本の作る口 (`createCapture`) と同じく `create` + 型の名前に
// する。UDP は手本 (Processing / p5.js) の本体に無いので、Swift の慣行と OSC の作る口
// (`createOSC(listen:send:)`) に揃える。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// TCP で繋いでくる相手を待つポートを開く。届いた行は ``TextPort/messages`` から読み、
    /// ``Server/write(_:)`` で繋いでいる相手全員へ書く。
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
    /// 端末に出る。
    ///
    /// - **呼んだときだけポートを開く。** `import mokume` しただけでポートが開くことはない
    /// - この機械のすべての口で受ける。別の機械からも繋げる。相手は何人でも繋げる
    /// - 改行 (`\n`。`\r\n` も) で区切った 1 行が 1 つの文字列になる。相手が閉じたときに
    ///   改行で終わっていない残りがあれば、それも 1 行として渡す。UTF-8 として読めない行と、
    ///   64 KiB を超える行は捨てて数え、次のフレームで診断に出す
    /// - **ポートを他のアプリが使っていても作れる。** ``TextPort/state`` が
    ///   ``SourceState/unavailable`` になり、空けば受け始める
    /// - 繋いでいる相手の数は ``Server/clientCount`` で読める。相手が居ないときの
    ///   ``Server/write(_:)`` は、1 度だけ診断に出す
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter port: 待つポート (1〜65535)。
    /// - Throws: ポートの番号が 1〜65535 に入っていないとき。
    public func createServer(_ port: Int) throws(NetworkFailure) -> Server {
        guard Endpoint.usablePorts.contains(port) else { throw .invalidPort(port) }
        let source = StreamSource(port: port, warn: { Diagnostics.warn($0) })
        let server = Server(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: self)
        attach(server)
        return server
    }

    /// 記録した行の列を、相手から届いたかのように流す。**ポートを開かない。**
    ///
    /// `messages[i]` が、作ってから i 番目のフレームで ``TextPort/messages`` に入る。最後まで
    /// 行けば最初に戻る。どの行が入るかはフレームの数え方だけで決まるので、同じ列からは何度
    /// 回しても同じ行が同じフレームに届く — 相手なしで確かめるときや、展示の前に空回しする
    /// ときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var server: Server?
    ///     var size: Float = 0.5
    ///     func setup() {
    ///         // 1 フレームごとに大きさを送ってきたかのように流す
    ///         server = createServer(messages: (0..<60).map { ["\(Float($0) / 60)"] })
    ///     }
    ///     func draw() {
    ///         for line in server?.messages ?? [] { size = Float(line) ?? size }
    ///         circle(width / 2, height / 2, size * height)
    ///     }
    /// }
    /// ```
    ///
    /// 繋いでくる相手は居ない (``Server/clientCount`` は 0)。``Server/write(_:)`` を呼んでも
    /// 何も出ない (1 度だけ知らせる)。
    ///
    /// - Parameter messages: フレームごとに届く行。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createServer(messages: [[String]]) -> Server {
        let server = Server(
            port: nil, name: "server (recorded)", source: RecordedSource(batches: messages),
            clients: nil, owner: self)
        attach(server)
        return server
    }

    /// UDP で受けるポートを開く。届いた文字列は ``TextPort/messages`` から読み、
    /// ``UDPPort/send(_:)`` で `send` の宛先へ送る。
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
    /// 端末から `nc -u 127.0.0.1 6000` で繋いで `0.3` と打つと円が変わる (末尾の改行は落ちる)。
    /// `nc -u -l 6001` で待っていれば、クリックの `hit` が出る。
    ///
    /// - **呼んだときだけポートを開く。** `import mokume` しただけでポートが開くことはない
    /// - この機械のすべての口で受ける。別の機械からも届く
    /// - 1 つの datagram が 1 つの文字列になる。UTF-8 として読めないものは捨てて数え、次の
    ///   フレームで診断に出す
    /// - **ポートを他のアプリが使っていても作れる。** ``TextPort/state`` が
    ///   ``SourceState/unavailable`` になり、空けば受け始める
    /// - 送り先を自分のポート (`("127.0.0.1", listen と同じ番号)`) にすれば、自分で送って自分で
    ///   受けられる。相手が居なくても動きを確かめられる
    /// - **送れないことは ``TextPort/state`` に出ない。** 送れないとき (宛先で誰も受けていない・
    ///   このアプリにローカルネットワークの許可が無い・ネットワークが落ちている) は、1 度だけ
    ///   診断に出す
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameters:
    ///   - port: 受けるポート (1〜65535)。
    ///   - destination: 送り先のホストとポート。省けば送らない。
    /// - Throws: ポートの番号が 1〜65535 に入っていない・送り先のホストが空のとき。
    public func createUDP(
        listen port: Int, send destination: (host: String, port: Int)? = nil
    ) throws(NetworkFailure) -> UDPPort {
        guard Endpoint.usablePorts.contains(port) else { throw .invalidPort(port) }
        var outbound: DatagramSender?
        if let destination {
            guard Endpoint.usablePorts.contains(destination.port) else {
                throw .invalidPort(destination.port)
            }
            guard Endpoint.isUsable(host: destination.host) else {
                throw .invalidHost(destination.host)
            }
            outbound = DatagramSender(
                host: destination.host, port: destination.port, warn: { Diagnostics.warn($0) })
        }
        let udp = UDPPort(
            port: port, name: "udp :\(port)",
            source: DatagramSource<String>.text(port: port, warn: { Diagnostics.warn($0) }),
            outbound: outbound, owner: self)
        attach(udp)
        return udp
    }

    /// 記録した文字列の列を、UDP で受けたかのように流す。**ポートを開かない。**
    ///
    /// `messages[i]` が、作ってから i 番目のフレームで ``TextPort/messages`` に入る。最後まで
    /// 行けば最初に戻る。どの文字列が入るかはフレームの数え方だけで決まるので、同じ列からは
    /// 何度回しても同じ文字列が同じフレームに届く — 相手なしで確かめるときや、展示の前に
    /// 空回しするときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var udp: UDPPort?
    ///     var size: Float = 0.5
    ///     func setup() {
    ///         // 1 フレームごとに大きさを送ってきたかのように流す
    ///         udp = createUDP(messages: (0..<60).map { ["\(Float($0) / 60)"] })
    ///     }
    ///     func draw() {
    ///         for text in udp?.messages ?? [] { size = Float(text) ?? size }
    ///         circle(width / 2, height / 2, size * height)
    ///     }
    /// }
    /// ```
    ///
    /// 送り先は持たない。``UDPPort/send(_:)`` を呼んでも何も出ない (1 度だけ知らせる)。
    ///
    /// - Parameter messages: フレームごとに届く文字列。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createUDP(messages: [[String]]) -> UDPPort {
        let udp = UDPPort(
            port: nil, name: "udp (recorded)", source: RecordedSource(batches: messages),
            outbound: nil, owner: self)
        attach(udp)
        return udp
    }
}
