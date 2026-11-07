// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// 文字列で他のアプリやマシンとやりとりする入力ソースに共通の基底クラス。``TCPServer``・``WebSocketServer``・
/// ``TCPClient``・``WebSocketClient``・``UDPPort`` がこれを継承する。
///
/// 毎フレーム呼ぶ API は無い。`draw()` の前に、前のフレームの後に届いた文字列が**全部**、
/// 届いた順に ``messages`` へ入っている ([ADR-0024] 決定 6)。最新の 1 つだけではないので、
/// 1 フレームの間に何度届いても取りこぼさない ([ADR-0028] 決定 2 の落とさない列 (`ExternalQueue`))。
///
/// ```swift
/// final class Remote: Sketch {
///     var server: TCPServer?
///     var size: Float = 0.5
///     func setup() throws { server = try createTCPServer(5204) }
///     func draw() {
///         for line in server?.messages ?? [] {
///             size = Float(line) ?? size   // Float として読めた行だけを使う ("nan"・"inf" も数として読む)
///         }
///         circle(width / 2, height / 2, size * height)
///     }
/// }
/// ```
///
/// ## 1 つのメッセージ
///
/// | 方式 | 1 つのメッセージ | 送る向き |
/// | --- | --- | --- |
/// | TCP (``Sketch/createTCPServer(_:)``) | 改行で区切った 1 行 | ``TCPServer/write(_:)`` — 繋いでいる相手全員へ |
/// | WebSocket (``Sketch/createWebSocketServer(_:)``) | 1 通 | ``WebSocketServer/send(_:)`` — 繋いでいる相手全員へ 1 通ずつ |
/// | TCP のクライアント (``Sketch/createTCPClient(_:_:)``) | 改行で区切った 1 行 | ``TCPClient/write(_:)`` — 繋いだ先のサーバへ |
/// | WebSocket のクライアント (``Sketch/createWebSocketClient(_:)``) | 1 通 | ``WebSocketClient/send(_:)`` — 繋いだ先のサーバへ 1 通 |
/// | UDP (``Sketch/createUDP(listen:send:)``) | 1 つの datagram | ``UDPPort/send(_:)`` — 作るときに決めた宛先へ |
///
/// **送る動詞は、区切りを誰が持つかで分ける。** TCP はストリームなので、``TCPServer/write(_:)`` は
/// 書いたバイト列をそのまま流し、行の区切り (`"\n"`) は書く側が付ける (Processing の `write` と
/// 同じ)。WebSocket と UDP は 1 通が 1 つのメッセージなので、``WebSocketServer/send(_:)``・
/// ``UDPPort/send(_:)`` は 1 回で 1 通を送る。
///
/// **末尾の改行は取り除く。** `nc` で打った `0.3⏎` は、そのまま `Float(text)` で読める。
/// **UTF-8 として読めないものは破棄する** — 推測して読むと、黙って別の文字列を渡すからである。
/// 破棄した数と、バッファに入りきらずに破棄した数 (1 フレームに 4096 を超えて届いたとき) は、次のフレームで
/// 診断に出す。
///
/// ## 来ないことには理由がある
///
/// 届かないとき、``state`` がその理由を報告する。`observe` の応答の `inputs` にも同じものが載る
/// ([ADR-0028] 決定 4)。
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 受けている |
/// | ``SourceState/unavailable`` | 開く途中か、他のアプリがそのポートを使っている。空けば受け始める |
/// | ``SourceState/denied`` | macOS がローカルネットワークを拒んでいる |
/// | ``SourceState/disconnected`` | 受けていたが、失敗した。開き直し続ける (クライアントは、繋がっていたのが切れた。繋ぎ直し続ける) |
/// | ``SourceState/stopped`` | ``stop()`` した (追加し直しても戻らない)。ランタイムが外した (``SketchPart/detach(_:)-(Inlet)``) だけなら、追加し直せば受け始める |
///
/// 使用中・拒まれた・失敗したときは、1 度だけ診断に出す。
///
/// **繋ぎに行く入力ソース (``TCPClient``・``WebSocketClient``) の読み方。** 繋げていない間 (まだ一度も繋がっていない)
/// は ``SourceState/unavailable``、繋がると ``SourceState/running``、繋がっていたのが切れると
/// ``SourceState/disconnected`` を報告する。このアプリにローカルネットワークの許可が無くて繋げないときは
/// ``SourceState/denied`` を報告し、許可すると次の繋ぎ直しで ``SourceState/running`` に戻る。
/// 切れても繋げなくても、**1 秒ごとに繋ぎ直し続ける** — 間隔は固定で、変える API は無い。応答しない相手は 5 秒で打ち切って繋ぎ直す。サーバが戻れば ``SourceState/running`` に戻り、止めるのは ``stop()`` だけ。
///
/// ## 相手が居ないことも読める
///
/// 繋いでくる相手を待つ入力ソース (``TCPServer``・``WebSocketServer``) の `clientCount` は、そのフレームの
/// 頭に繋いでいた相手の数である。相手が切れれば減り、止めた後は 0 になる。相手が 1 人も居ないときに
/// 送っても届く先が無いので、1 度だけ診断に出す (送れたら、また出力できるように戻る)。止めた後と、
/// 記録した列を流している入力ソースで送ったときも、1 度だけ警告して何もしない。
///
/// ## 観測・操作用のインターフェースとは別のもの
///
/// この入力ソースは、実行中のスケッチを外から観測・操作するインターフェース ([ADR-0018]) ではない。あちらは
/// socket もポートも新設せず、作業ディレクトリのファイルだけでやりとりすると決めている
/// (決定 1)。この入力ソースは、スケッチが自分で開く**外からの入力**の 1 つで、カメラや OSC と同じ入力ソース
/// (``Inlet``) を通る。ポートが開くのはスケッチが作る API (``Sketch/createTCPServer(_:)`` ほか) を
/// 呼んだときだけで、mokume の実行や `observe` がポートを開くことはない。エージェントが値を差し込んで
/// 描画を確かめるときは、ポートではなく `observe` のインターフェースと、記録した列の注入
/// (``Sketch/createTCPServer(messages:)``・``Sketch/createUDP(messages:)`` ほか) を使う。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public class TextPort: Inlet {
    /// 受けているポート。記録した列を流している・繋ぎに行く入力ソース (``TCPClient``・``WebSocketClient``) なら `nil`。
    public let port: Int?
    /// このフレームの前に届いた文字列。届いた順。何も届いていなければ空。
    public private(set) var messages: [String] = []

    let input: ExternalQueue<String>
    let source: any MessageSource<String>
    /// 繋いでくる相手へ配る先。相手を待たない入り口 (UDP) と記録した列は `nil`。
    let clients: (any Broadcasting)?
    /// このフレームの頭に繋いでいた相手の数。
    private(set) var connected = 0
    private weak var owner: (any Sketch)?
    private let warn: (String) -> Void
    /// 知らせた送れない理由。同じものは 2 度言わない。
    private var told: Set<String> = []
    /// 外されている (``close()`` の後で、まだ足し直されていない)。足し直す (``open()``) と戻る。
    private(set) var closed = false
    /// 利用者が ``stop()`` を呼んだ。**足し直しの ``open()`` でも戻さない** (利用者の意思として粘る)。
    private(set) var stoppedByUser = false

    init(
        port: Int?, name: String, source: any MessageSource<String>,
        clients: (any Broadcasting)? = nil, owner: (any Sketch)?,
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.port = port
        self.source = source
        self.clients = clients
        self.owner = owner
        self.warn = warn
        input = ExternalQueue(name: name, state: .unavailable)
    }

    /// 入力元の状態。
    public var state: SourceState { input.state }
    /// 最後に文字列が届いたフレーム。まだ 1 つも届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }

    /// 止める。ポートを閉じ、以後 ``messages`` は空のままで、送っても何も出ない。
    ///
    /// **利用者が止めたものは、追加し直しても止まったままである。** ``SketchPart/attach(_:)-(Inlet)`` で追加し直しても、
    /// 受けも送りもせず、``state`` は ``SourceState/stopped`` のまま (止めたのは利用者の意思なので、追加し直しで
    /// 戻さない)。受け始めるには、新しく作る。
    ///
    /// **ランタイムが外した場合は別である。** ``SketchPart/detach(_:)-(Inlet)`` で外しただけ (``stop()`` は呼んで
    /// いない) なら、``SketchPart/attach(_:)-(Inlet)`` で追加し直せば、また受け始め、送れ、``state`` も戻る。
    /// 実行が終わったものは追加し直す先が無い。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``SketchPart/detach(_:)-(Inlet)`` と同じ)。
    /// 実行中のスケッチの中で開始した `Task` からも止まる。外 (初期化子の中・終了処理の後) で呼ぶと何もせず、`TCPServer.stop()` のように型を付けた名前で 1 度だけ警告する。
    public func stop() {
        // 印は、外す頼みが実行に届いたときだけ立てる。外で呼んで警告だけ出した回に立てると、走っているポートが止まる
        if owner?.detach(self, calledAs: "\(type(of: self)).stop()") == true { stoppedByUser = true }
    }

    // MARK: - Inlet

    public func open() throws {
        // 足し直しでも呼ばれる (``close()`` の後の 2 度目)。利用者が ``stop()`` したものは戻さない。
        // ランタイムが外しただけなら、外していた間に立てた印と、「止まっている」と知らせた記憶を戻す。
        // 受け口・繋ぎは ``source`` が開き直す
        guard !stoppedByUser else { return }
        closed = false
        forget("stopped")
        source.start(into: input)
    }

    public func supply() {
        source.pump(into: input)
        messages = input.take()
        connected = clients?.clientCount ?? 0
    }

    public func close() {
        closed = true
        source.stop()
        closeOutbound()
        input.setState(.stopped)
        // 届いて読まれなかった分は捨てる。足し直した最初の ``supply()`` に、外す前のものを出さない
        input.discardWaiting()
        messages = []
        connected = 0
    }

    public var report: SourceReport? { input.report }

    // MARK: - 継ぐ型が足すもの

    /// 閉じるときに、送る側を閉じる。
    func closeOutbound() {}

    /// 繋いでいる相手全員へ配る。止めた後・記録した列・相手が 0 人なら、理由ごとに 1 度だけ
    /// 知らせて何もしない。`kind` は文面の名乗り (`TCP server` など)、`verb` は `written` か `sent`。
    func deliver(_ text: String, by kind: String, verb: String) {
        guard !closed else {
            tellOnce("stopped", "This \(kind) is stopped, so \(Self.preview(text)) was not \(verb)")
            return
        }
        guard let clients else {
            tellOnce(
                "recorded",
                "This \(kind) replays recorded messages and has no clients, so "
                    + "\(Self.preview(text)) was not \(verb)")
            return
        }
        guard clients.clientCount > 0 else {
            tellOnce(
                "noClient",
                "No client is connected to the \(kind) on port \(port ?? 0), so "
                    + "\(Self.preview(text)) was not \(verb). It reaches the clients connected "
                    + "when it is \(verb)")
            return
        }
        forget("noClient")
        clients.broadcast(text)
    }

    /// 繋いだ先のサーバへ書く (繋ぎに行く入り口)。止めた後・記録した列・繋がっていないときは、理由ごとに
    /// 1 度だけ知らせて何もしない。`kind` は文面の名乗り (`TCP client` など)、`target` は繋ぎ先の綴り、
    /// `verb` は `written` か `sent`。
    func sendToServer(_ text: String, by kind: String, target: String, verb: String) {
        guard !closed else {
            tellOnce("stopped", "This \(kind) is stopped, so \(Self.preview(text)) was not \(verb)")
            return
        }
        guard let clients else {
            tellOnce(
                "recorded",
                "This \(kind) replays recorded messages and has no server, so "
                    + "\(Self.preview(text)) was not \(verb)")
            return
        }
        guard clients.clientCount > 0 else {
            tellOnce(
                "notConnected",
                "The \(kind) is not connected to \(target), so \(Self.preview(text)) was not "
                    + "\(verb). It reaches the server only while connected")
            return
        }
        forget("notConnected")
        clients.broadcast(text)
    }

    /// 理由ごとに 1 度だけ知らせる。
    func tellOnce(_ key: String, _ message: String) {
        guard told.insert(key).inserted else { return }
        warn(message)
    }

    /// 知らせた理由を忘れる。次に同じことが起きたら、また知らせる。
    func forget(_ key: String) {
        told.remove(key)
    }

    /// 診断に出す、送ろうとした文字列の頭。改行は `\n` と書き、長ければ切る。
    static func preview(_ text: String) -> String {
        let limit = 32
        let quoted = String(reflecting: String(text.prefix(limit)))
        return text.count > limit ? quoted + "…" : quoted
    }
}
