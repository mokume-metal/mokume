// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// 文字列で他のアプリや機械とやりとりする入り口に共通の口。``TCPServer``・``WebSocketServer``・
/// ``UDPPort`` がこれを継ぐ。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、前のフレームの後に届いた文字列が**全部**、
/// 届いた順に ``messages`` へ入っている ([ADR-0024] 決定 6)。最新の 1 つだけではないので、
/// 1 フレームの間に何度届いても取りこぼさない ([ADR-0028] 決定 2 の「落とさない列」)。
///
/// ```swift
/// final class Remote: Sketch {
///     var server: TCPServer?
///     var size: Float = 0.5
///     func setup() { server = try? createTCPServer(5204) }
///     func draw() {
///         for line in server?.messages ?? [] {
///             size = Float(line) ?? size   // 0.3 のような数だけを読む
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
/// | UDP (``Sketch/createUDP(listen:send:)``) | 1 つの datagram | ``UDPPort/send(_:)`` — 作るときに決めた宛先へ |
///
/// **送る動詞は、区切りを誰が持つかで分ける。** TCP は流れなので、``TCPServer/write(_:)`` は
/// 書いたバイト列をそのまま流し、行の区切り (`"\n"`) は書く側が付ける (Processing の `write` と
/// 同じ)。WebSocket と UDP は 1 通が 1 つのメッセージなので、``WebSocketServer/send(_:)``・
/// ``UDPPort/send(_:)`` は 1 回で 1 通を送る。
///
/// **末尾の改行は落とす。** `nc` で打った `0.3⏎` は、そのまま `Float(text)` で読める。
/// **UTF-8 として読めないものは捨てる** — 推して読むと、黙って別の文字列を渡すからである。
/// 捨てた数と、溜めきれずに捨てた数 (1 フレームに 4096 を超えて届いたとき) は、次のフレームで
/// 診断に出す。
///
/// ## 来ないことには理由がある
///
/// 届かないとき、``state`` がその理由を名乗る。観測の応答の `inputs` にも同じものが載る
/// ([ADR-0028] 決定 4)。
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 受けている |
/// | ``SourceState/unavailable`` | 開く途中か、他のアプリがそのポートを使っている。空けば受け始める |
/// | ``SourceState/denied`` | macOS がローカルネットワークを拒んでいる |
/// | ``SourceState/disconnected`` | 受けていたが、失敗した。開き直し続ける |
/// | ``SourceState/stopped`` | ``stop()`` した |
///
/// 使用中・拒まれた・失敗したときは、1 度だけ診断に出す。
///
/// ## 相手が居ないことも読める
///
/// 繋いでくる相手を待つ入り口 (``TCPServer``・``WebSocketServer``) の `clientCount` は、そのフレームの
/// 頭に繋いでいた相手の数である。相手が切れれば減り、止めた後は 0 になる。相手が 1 人も居ないときに
/// 送っても届く先が無いので、1 度だけ診断に出す (送れたら、また言えるように戻る)。止めた後と、
/// 記録した列を流している入り口で送ったときも、1 度だけ知らせて何もしない。
///
/// ## 観測と操作の面とは別のもの
///
/// この入り口は、走っているスケッチを外から観測・操作する面 ([ADR-0018]) ではない。あちらは
/// socket もポートも新設せず、作業ディレクトリのファイルだけでやりとりすると決めている
/// (決定 1)。この入り口は、作品が自分で開く**外からの入力**の 1 つで、カメラや OSC と同じ入り口
/// (``Inlet``) を通る。ポートが開くのは作品が作る口 (``Sketch/createTCPServer(_:)`` ほか) を
/// 呼んだときだけで、mokume の実行や観測がポートを開くことはない。エージェントが値を差し込んで
/// 絵を確かめるときは、ポートではなく観測の面と、記録した列の注入
/// (``Sketch/createTCPServer(messages:)``・``Sketch/createUDP(messages:)`` ほか) を使う。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public class TextPort: Inlet {
    /// 受けているポート。記録した列を流しているなら `nil`。
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
    /// ``stop()`` した (閉じた) か。
    private(set) var closed = false

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

    /// 出どころの状態。
    public var state: SourceState { input.state }
    /// 最後に文字列が届いたフレーム。まだ 1 つも届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }

    /// 止める。ポートを閉じ、以後 ``messages`` は空のままで、送っても何も出ない。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``Sketch/detach(_:)-(Inlet)`` と同じ)。
    public func stop() {
        owner?.detach(self)
    }

    // MARK: - Inlet

    public func open() throws {
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
