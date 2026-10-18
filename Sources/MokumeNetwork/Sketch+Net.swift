// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics
import Network

// TCP・UDP・WebSocket。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0041] の地図の「連携の口 (標準)」)。`plugins` には何も
// 書かない — 作る口が、走っているスケッチへ自分で入り口を足す (``SketchPart/attach(_:)-(Inlet)``)。
//
// 名前 ([ADR-0020] 決定 1。2026-10-09 の段): 公開の型は方式を名乗る (`TCPServer`・
// `WebSocketServer`・`UDPPort`)。TCP には Processing の `Server` (`write`・`clientCount`) という
// 手本があるが、方式の違う兄弟が並ぶと `Server` だけでは方式が読めないので、型の名前だけ方式を
// 名乗り、メンバの名前と引数の順序は手本に倣う。作る口は手本の作る口 (`createCapture`) と同じく
// `create` + 型の名前にする。送る動詞は、流れに書く TCP が `write`、1 通を送る WebSocket と UDP が
// `send`。UDP は OSC の作る口 (`createOSC(listen:send:)`) に揃える (#2250)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// TCP で繋いでくる相手を待つポートを開く。届いた行は ``TextPort/messages`` から読み、
    /// ``TCPServer/write(_:)`` で繋いでいる相手全員へ書く。
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
    /// - **呼んだときだけポートを開く。** `import mokume` しただけでポートが開くことはない
    /// - この機械のすべての口で受ける。別の機械からも繋げる。相手は何人でも繋げる
    /// - 改行 (`\n`。`\r\n` も) で区切った 1 行が 1 つの文字列になる。相手が閉じたときに
    ///   改行で終わっていない残りがあれば、それも 1 行として渡す。UTF-8 として読めない行と、
    ///   64 KiB を超える行は捨てて数え、次のフレームで診断に出す
    /// - **ポートを他のアプリが使っていても作れる。** ``TextPort/state`` が
    ///   ``SourceState/unavailable`` になり、空けば受け始める
    /// - 繋いでいる相手の数は ``TCPServer/clientCount`` で読める。相手が居ないときの
    ///   ``TCPServer/write(_:)`` は、1 度だけ診断に出す
    ///
    /// Processing の `new Server(this, 5204)` に当たる。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter port: 待つポート (1〜65535)。
    /// - Throws: ポートの番号が 1〜65535 に入っていないとき。使える番号を `setup()`・`draw()`・入力の
    ///   コールバックの外 (初期化子の中・後片付けの後・`Task` の中) で渡すと、ポートを開く前に
    ///   ``NetworkFailure/notRunning(call:)`` (プロセスは落ちない)。
    public func createTCPServer(_ port: Int) throws(NetworkFailure) -> TCPServer {
        guard Endpoint.usablePorts.contains(port) else { throw .invalidPort(port) }
        try requireAttachable(NetworkFailure.self, calledAs: #function)
        let server = tcpServer(port: port)
        attach(server)
        return server
    }

    /// ``createTCPServer(_:)`` が足すもの (番号は検めてある)。ポートは足したときに開く。走らせずに中身を
    /// 確かめる検査も使う — 外で呼んだ作る口は投げて、何も返さないため (#2740)。
    func tcpServer(port: Int) -> TCPServer {
        let source = StreamSource(kind: .tcp, port: port, warn: { Diagnostics.warn($0) })
        return TCPServer(
            port: port, name: "tcp :\(port)", source: source, clients: source, owner: self)
    }

    /// WebSocket で繋いでくる相手 (ブラウザなど) を待つポートを開く。届いた 1 通ずつを
    /// ``TextPort/messages`` から読み、``WebSocketServer/send(_:)`` で繋いでいる相手全員へ送る。
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
    /// ブラウザの console で次の 1 行を打つと円が変わり、クリックの `hit` が console に出る。
    ///
    /// ```js
    /// ws = new WebSocket("ws://localhost:8025"); ws.onmessage = e => console.log(e.data); ws.onopen = () => ws.send("0.3")
    /// ```
    ///
    /// - 1 通が 1 つの文字列になる (末尾の改行 1 つは落とす)。text も binary も UTF-8 として読み、
    ///   読めないものは捨てて数え、次のフレームで診断に出す。``WebSocketServer/send(_:)`` は
    ///   1 回で 1 通の text として届く
    /// - **呼んだときだけポートを開く。** `import mokume` しただけでポートが開くことはない
    /// - この機械のすべての口で受ける。どのパスで繋いでも同じ受け口に届く (`ws://localhost:8025/`
    ///   でも `ws://localhost:8025/remote` でもよい)。暗号化 (`wss://`) は持たない
    /// - **ポートを他のアプリが使っていても作れる。** ``TextPort/state`` が
    ///   ``SourceState/unavailable`` になり、空けば受け始める
    /// - 繋いでいる相手の数は ``WebSocketServer/clientCount`` で読める。相手が居ないときの
    ///   ``WebSocketServer/send(_:)`` は、1 度だけ診断に出す
    ///
    /// 相手なしで確かめるときは、記録した列を ``Sketch/createWebSocketServer(messages:)`` で流す。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter port: 待つポート (1〜65535)。
    /// - Throws: ポートの番号が 1〜65535 に入っていないとき。使える番号を `setup()`・`draw()`・入力の
    ///   コールバックの外 (初期化子の中・後片付けの後・`Task` の中) で渡すと、ポートを開く前に
    ///   ``NetworkFailure/notRunning(call:)`` (プロセスは落ちない)。
    public func createWebSocketServer(_ port: Int) throws(NetworkFailure) -> WebSocketServer {
        guard Endpoint.usablePorts.contains(port) else { throw .invalidPort(port) }
        try requireAttachable(NetworkFailure.self, calledAs: #function)
        let server = webSocketServer(port: port)
        attach(server)
        return server
    }

    /// ``createWebSocketServer(_:)`` が足すもの (番号は検めてある)。``tcpServer(port:)`` と同じく、検査も使う。
    func webSocketServer(port: Int) -> WebSocketServer {
        let source = StreamSource(kind: .webSocket, port: port, warn: { Diagnostics.warn($0) })
        return WebSocketServer(
            port: port, name: "websocket :\(port)", source: source, clients: source, owner: self)
    }

    /// 記録した文字列の列を、TCP で繋いできた相手から届いたかのように流す。**ポートを開かない。**
    ///
    /// ``Sketch/createTCPServer(_:)`` で受けるスケッチを相手なしで回すときは、これに差し替える。
    /// `messages[i]` が、作ってから i 番目のフレームで ``TextPort/messages`` に入る。最後まで行けば
    /// 最初に戻る。どの文字列が入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても
    /// 同じ文字列が同じフレームに届く — 相手なしで確かめるときや、展示の前に空回しするときに使う
    /// ([ADR-0028] 決定 6・7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var server: TCPServer?
    ///     var size: Float = 0.5
    ///     func setup() {
    ///         // 1 フレームごとに大きさを送ってきたかのように流す
    ///         server = createTCPServer(messages: (0..<60).map { ["\(Float($0) / 60)"] })
    ///     }
    ///     func draw() {
    ///         for line in server?.messages ?? [] { size = Float(line) ?? size }
    ///         circle(width / 2, height / 2, size * height)
    ///     }
    /// }
    /// ```
    ///
    /// 繋いでくる相手は居ない (``TCPServer/clientCount`` は 0)。``TCPServer/write(_:)`` を呼んでも
    /// 何も出ない (1 度だけ知らせる)。
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、何も届かない
    /// ポートを返し、この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter messages: フレームごとに届く文字列。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createTCPServer(messages: [[String]]) -> TCPServer {
        let server = TCPServer(
            port: nil, name: "tcp (recorded)", source: RecordedSource(batches: messages),
            clients: nil, owner: self)
        attach(server, calledAs: #function, returning: "a port that never receives anything")
        return server
    }

    /// 記録した文字列の列を、WebSocket で繋いできた相手から届いたかのように流す。
    /// **ポートを開かない。**
    ///
    /// ``Sketch/createWebSocketServer(_:)`` で受けるスケッチを相手なしで回すときは、これに差し替える。
    /// 流し方は ``Sketch/createTCPServer(messages:)`` と同じで、`messages[i]` が、作ってから i 番目の
    /// フレームで ``TextPort/messages`` に入る ([ADR-0028] 決定 6・7)。
    ///
    /// <!-- example: 文脈 var socket: WebSocketServer? -->
    /// ```swift
    /// socket = createWebSocketServer(messages: [["0.25"], [], ["0.75", "hit"]])
    /// ```
    ///
    /// 繋いでくる相手は居ない (``WebSocketServer/clientCount`` は 0)。``WebSocketServer/send(_:)`` を
    /// 呼んでも何も出ない (1 度だけ知らせる)。
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、何も届かない
    /// ポートを返し、この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter messages: フレームごとに届く文字列。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createWebSocketServer(messages: [[String]]) -> WebSocketServer {
        let server = WebSocketServer(
            port: nil, name: "websocket (recorded)", source: RecordedSource(batches: messages),
            clients: nil, owner: self)
        attach(server, calledAs: #function, returning: "a port that never receives anything")
        return server
    }

    /// TCP で外のサーバへ繋ぎに行く。サーバから届いた行は ``TextPort/messages`` から読み、
    /// ``TCPClient/write(_:)`` で繋いだ先のサーバへ書く。
    ///
    /// ```swift
    /// final class Remote: Sketch {
    ///     var link: TCPClient?
    ///     var size: Float = 0.5
    ///     func setup() { link = try? createTCPClient("127.0.0.1", 7000) }
    ///     func draw() {
    ///         for line in link?.messages ?? [] { size = Float(line) ?? size }
    ///         background(20)
    ///         circle(width / 2, height / 2, size * height)
    ///     }
    ///     func mousePressed() { link?.write("hit\n") }
    /// }
    /// ```
    ///
    /// 手元の制御盤や TouchDesigner の TCP/IP DAT のような、待つ側の相手に繋いで値を受ける。端末で
    /// `nc -l 7000` で待っていれば、繋がったあとのクリックの `hit` がそこに出る。
    ///
    /// - **呼んだときだけ繋ぐ。** `import mokume` しただけで繋ぎに行くことはない
    /// - 改行 (`\n`。`\r\n` も) で区切った 1 行が 1 つの文字列になる。相手が閉じたときに改行で終わって
    ///   いない残りがあれば、それも 1 行として渡す。UTF-8 として読めない行と、64 KiB を超える行は
    ///   捨てて数え、次のフレームで診断に出す
    /// - **相手が居なくても、居なくなっても作れる。** 繋げない間は ``TextPort/state`` が
    ///   ``SourceState/unavailable``、繋がると ``SourceState/running``、繋がっていたのが切れると
    ///   ``SourceState/disconnected`` になる
    /// - **切れても繋げなくても、1 秒ごとに繋ぎ直し続ける。** 間隔は固定で、変える口は無い。返事をしない
    ///   相手 (繋がるのに 5 秒かかっても使えるようにならないもの) は、5 秒で諦めて繋ぎ直す。止めるのは
    ///   ``TextPort/stop()`` だけ。繋げない・切れたことは、1 度だけ診断に出す
    /// - 繋がっていない間の ``TCPClient/write(_:)`` は、1 度だけ診断に出して何もしない
    ///
    /// Processing の `new Client(this, host, port)` に当たる。
    ///
    /// 相手なしで確かめるときは、記録した列を ``Sketch/createTCPClient(messages:)`` で流す。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameters:
    ///   - host: 繋ぐ相手のホスト (名前かアドレス。この機械なら `"127.0.0.1"`)。
    ///   - port: 繋ぐ相手のポート (1〜65535)。
    /// - Throws: ポートの番号が 1〜65535 に入っていない・ホストが空のとき。使える値を `setup()`・`draw()`・
    ///   入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で渡すと、繋ぐ前に
    ///   ``NetworkFailure/notRunning(call:)`` (プロセスは落ちない)。
    public func createTCPClient(_ host: String, _ port: Int) throws(NetworkFailure) -> TCPClient {
        guard Endpoint.usablePorts.contains(port) else { throw .invalidPort(port) }
        guard Endpoint.isUsable(host: host) else { throw .invalidHost(host) }
        try requireAttachable(NetworkFailure.self, calledAs: #function)
        let client = tcpClient(host: host, port: port)
        attach(client)
        return client
    }

    /// ``createTCPClient(_:_:)`` が足すもの (値は検めてある)。繋ぐのは足したときに始める。検査も使う。
    func tcpClient(host: String, port: Int) -> TCPClient {
        let target = "\(host):\(port)"
        let source = ClientSource(
            kind: .tcp,
            endpoint: .hostPort(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any),
            target: target, warn: { Diagnostics.warn($0) })
        return TCPClient(
            target: target, name: "tcp client \(target)", source: source, clients: source, owner: self)
    }

    /// WebSocket で外のサーバ (中継サーバなど) へ繋ぎに行く。サーバから届いた 1 通ずつを
    /// ``TextPort/messages`` から読み、``WebSocketClient/send(_:)`` で繋いだ先のサーバへ送る。
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
    /// 展示室の中継サーバに繋ぎ、別の機械のセンサーの値で円を動かす。
    ///
    /// - 1 通が 1 つの文字列になる (末尾の改行 1 つは落とす)。text も binary も UTF-8 として読み、
    ///   読めないものは捨てて数え、次のフレームで診断に出す。``WebSocketClient/send(_:)`` は
    ///   1 回で 1 通の text として届く
    /// - **`ws://` も `wss://` (暗号化) も受ける。** パスと問い合わせ (`/room?id=3`) もそのまま渡る
    /// - **呼んだときだけ繋ぐ。** `import mokume` しただけで繋ぎに行くことはない
    /// - **相手が居なくても、居なくなっても作れる。** 繋げない間は ``TextPort/state`` が
    ///   ``SourceState/unavailable``、繋がると ``SourceState/running``、繋がっていたのが切れると
    ///   ``SourceState/disconnected`` になる
    /// - **切れても繋げなくても、1 秒ごとに繋ぎ直し続ける。** 間隔は固定で、変える口は無い。返事をしない
    ///   相手 (繋がるのに 5 秒かかっても使えるようにならないもの) は、5 秒で諦めて繋ぎ直す。止めるのは
    ///   ``TextPort/stop()`` だけ。繋げない・切れたことは、1 度だけ診断に出す
    /// - 繋がっていない間の ``WebSocketClient/send(_:)`` は、1 度だけ診断に出して何もしない
    ///
    /// 相手なしで確かめるときは、記録した列を ``Sketch/createWebSocketClient(messages:)`` で流す。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter url: 繋ぐ先の URL (`ws://` か `wss://` で始まる綴り)。
    /// - Throws: URL が `ws://` か `wss://` の綴りとして読めない・ホストが空のとき
    ///   (``NetworkFailure/invalidHost(_:)``)、書かれたポートが 1〜65535 に入っていないとき。使える値を
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で渡すと、
    ///   繋ぐ前に ``NetworkFailure/notRunning(call:)`` (プロセスは落ちない)。
    public func createWebSocketClient(_ url: String) throws(NetworkFailure) -> WebSocketClient {
        guard let parsed = Endpoint.webSocketURL(url) else { throw .invalidHost(url) }
        if let port = parsed.port, !Endpoint.usablePorts.contains(port) {
            throw .invalidPort(port)
        }
        try requireAttachable(NetworkFailure.self, calledAs: #function)
        let client = webSocketClient(url: url, parsed: parsed)
        attach(client)
        return client
    }

    /// ``createWebSocketClient(_:)`` が足すもの (値は検めてある)。``tcpClient(host:port:)`` と同じく、検査も使う。
    func webSocketClient(url: String, parsed: (url: URL, secure: Bool, port: Int?)) -> WebSocketClient {
        let source = ClientSource(
            kind: .webSocket, endpoint: .url(parsed.url), secure: parsed.secure, target: url,
            warn: { Diagnostics.warn($0) })
        return WebSocketClient(
            target: url, name: "websocket client \(url)", source: source, clients: source, owner: self)
    }

    /// 記録した文字列の列を、TCP で繋いだ先のサーバから届いたかのように流す。**繋ぎに行かない。**
    ///
    /// ``Sketch/createTCPClient(_:_:)`` で受けるスケッチを相手なしで回すときは、これに差し替える。
    /// `messages[i]` が、作ってから i 番目のフレームで ``TextPort/messages`` に入る。最後まで行けば
    /// 最初に戻る。どの文字列が入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても
    /// 同じ文字列が同じフレームに届く — 相手なしで確かめるときや、展示の前に空回しするときに使う
    /// ([ADR-0028] 決定 6・7)。
    ///
    /// <!-- example: 文脈 var link: TCPClient? -->
    /// ```swift
    /// link = createTCPClient(messages: [["0.25"], [], ["0.75", "hit"]])
    /// ```
    ///
    /// 繋ぐ先は無い。``TCPClient/write(_:)`` を呼んでも何も出ない (1 度だけ知らせる)。
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、何も届かない
    /// ポートを返し、この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter messages: フレームごとに届く文字列。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createTCPClient(messages: [[String]]) -> TCPClient {
        let client = TCPClient(
            target: "tcp client (recorded)", name: "tcp client (recorded)",
            source: RecordedSource(batches: messages), clients: nil, owner: self)
        attach(client, calledAs: #function, returning: "a port that never receives anything")
        return client
    }

    /// 記録した文字列の列を、WebSocket で繋いだ先のサーバから届いたかのように流す。**繋ぎに行かない。**
    ///
    /// ``Sketch/createWebSocketClient(_:)`` で受けるスケッチを相手なしで回すときは、これに差し替える。
    /// 流し方は ``Sketch/createTCPClient(messages:)`` と同じで、`messages[i]` が、作ってから i 番目の
    /// フレームで ``TextPort/messages`` に入る ([ADR-0028] 決定 6・7)。
    ///
    /// <!-- example: 文脈 var socket: WebSocketClient? -->
    /// ```swift
    /// socket = createWebSocketClient(messages: [["0.25"], [], ["0.75", "hit"]])
    /// ```
    ///
    /// 繋ぐ先は無い。``WebSocketClient/send(_:)`` を呼んでも何も出ない (1 度だけ知らせる)。
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、何も届かない
    /// ポートを返し、この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter messages: フレームごとに届く文字列。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createWebSocketClient(messages: [[String]]) -> WebSocketClient {
        let client = WebSocketClient(
            target: "websocket client (recorded)", name: "websocket client (recorded)",
            source: RecordedSource(batches: messages), clients: nil, owner: self)
        attach(client, calledAs: #function, returning: "a port that never receives anything")
        return client
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
    /// - **1 つの datagram は 9215 バイトまで (9216 バイト未満)。** 9216 バイト以上の datagram は
    ///   macOS の受け口が黙って切るので、丸ごと捨てて数え、次のフレームで診断に出す (ちょうど
    ///   9216 バイトのものも捨てる)。``UDPPort/send(_:)`` も、UTF-8 で 9216 バイト以上の文字列は
    ///   送らず、知らせる
    /// - 空の datagram (0 バイト) は空の文字列 `""` になる。ただし macOS の受け口は、空の datagram
    ///   を受けるとその送り元の流れを閉じることがあり、そのとき空の直後 (1 ミリ秒ほどの間) に同じ
    ///   送り元から届いたものは、数えず診断にも出さずに落ちる。`""` を送った直後に同じポートから
    ///   送ったものも、相手が mokume の受け口なら落ちうる
    /// - **ポートを他のアプリが使っていても作れる。** ``TextPort/state`` が
    ///   ``SourceState/unavailable`` になり、空けば受け始める
    /// - 送り先を自分のポート (`("127.0.0.1", listen と同じ番号)`) にすれば、自分で送って自分で
    ///   受けられる。相手が居なくても動きを確かめられる
    /// - **送れないことは ``TextPort/state`` に出ない。** 送れないとき (宛先で誰も受けていない・
    ///   このアプリにローカルネットワークの許可が無い・ネットワークが落ちている) は、1 度だけ
    ///   診断に出す。宛先に拒まれた後は、間 (既定 0.5 秒) を空けた次の送信まで拒まれずに終わって初めて
    ///   「送れた」と読み、また診断に出せるように戻る
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameters:
    ///   - port: 受けるポート (1〜65535)。
    ///   - destination: 送り先のホストとポート。省けば送らない。
    /// - Throws: ポートの番号が 1〜65535 に入っていない・送り先のホストが空のとき。使える値を
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で渡すと、
    ///   ポートを開く前に ``NetworkFailure/notRunning(call:)`` (プロセスは落ちない)。
    public func createUDP(
        listen port: Int, send destination: (host: String, port: Int)? = nil
    ) throws(NetworkFailure) -> UDPPort {
        guard Endpoint.usablePorts.contains(port) else { throw .invalidPort(port) }
        if let destination {
            guard Endpoint.usablePorts.contains(destination.port) else {
                throw .invalidPort(destination.port)
            }
            guard Endpoint.isUsable(host: destination.host) else {
                throw .invalidHost(destination.host)
            }
        }
        try requireAttachable(NetworkFailure.self, calledAs: #function)
        let outbound = destination.map {
            DatagramSender(host: $0.host, port: $0.port, warn: { Diagnostics.warn($0) })
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
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、何も届かない
    /// ポートを返し、この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter messages: フレームごとに届く文字列。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createUDP(messages: [[String]]) -> UDPPort {
        let udp = UDPPort(
            port: nil, name: "udp (recorded)", source: RecordedSource(batches: messages),
            outbound: nil, owner: self)
        attach(udp, calledAs: #function, returning: "a port that never receives anything")
        return udp
    }
}
