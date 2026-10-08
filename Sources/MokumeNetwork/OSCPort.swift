// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// OSC を受けて送る入り口。``Sketch/createOSC(listen:send:)`` が作り、走っているスケッチへ足す。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、前のフレームの後に届いたメッセージが**全部**、
/// 届いた順に ``messages`` へ入っている ([ADR-0024] 決定 6)。最新の 1 つだけではないので、
/// 1 フレームの間に何度届いても取りこぼさない ([ADR-0028] 決定 2 の「落とさない列」)。
///
/// ```swift
/// final class Remote: Sketch {
///     var osc: OSCPort?
///     var size: Float = 0.5
///     func setup() { osc = try? createOSC(listen: 9000, send: ("127.0.0.1", 7000)) }
///     func draw() {
///         for message in osc?.messages ?? [] where message.address == "/size" {
///             size = message.float(0) ?? size
///         }
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { osc?.send("/hit", 1) }
/// }
/// ```
///
/// ## 読めないものは打ち切る
///
/// 読めない部分 (知らない型の印・途中で尽きたバイト列など) を含むパケットは、**その部分から
/// 後ろを捨てる**。推して読み進めると、後ろの値をずれた位置から読んで、黙って間違った値を
/// 出すからである。読めたものだけが ``messages`` に入る。読める型は ``OSCValue`` のとおりで、
/// 束 (bundle) は中を開いて並んだ順に渡す (束の時刻は見ない)。
///
/// **捨てたことは黙らない。** 読めずに捨てたパケットの数と、溜めきれずに捨てたメッセージの
/// 数 (1 フレームに 4096 を超えて届いたとき) は、次のフレームで診断に出る。
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
/// **送れないことは ``state`` に出ない。** ``state`` が名乗るのは受けるほうの様子である。送れない
/// とき (宛先で誰も受けていない・このアプリにローカルネットワークの許可が無い・ネットワークが
/// 落ちている) は、1 度だけ診断に出す。送れたら、また言えるように戻る。
///
/// ## 観測と操作の面とは別のもの
///
/// OSC は、走っているスケッチを外から観測・操作する面 ([ADR-0018]) ではない。あちらは socket も
/// ポートも新設せず、作業ディレクトリのファイルだけでやりとりすると決めている (決定 1)。
/// この入り口は、作品が自分で開く**外からの入力**の 1 つで、カメラやマイクと同じ入り口
/// (``Inlet``) を通る。ポートが開くのは作品が ``Sketch/createOSC(listen:send:)`` を呼んだとき
/// だけで、mokume の実行や観測がポートを開くことはない。エージェントが値を差し込んで絵を
/// 確かめるときは、ポートではなく観測の面と、記録した列の注入
/// (``Sketch/createOSC(messages:)``) を使う。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class OSCPort: Inlet {
    /// 受けているポート。記録した列を流しているなら `nil`。
    public let port: Int?
    /// このフレームの前に届いたメッセージ。届いた順。何も届いていなければ空。
    public private(set) var messages: [OSCMessage] = []

    let input: ExternalQueue<OSCMessage>
    let source: any OSCSource
    private let outbound: (any DatagramSending)?
    private weak var owner: (any Sketch)?
    private let warn: (String) -> Void
    /// 知らせた送れない理由。同じものは 2 度言わない。
    private var toldSending: Set<String> = []
    private var closed = false

    init(
        port: Int?, name: String, source: any OSCSource, outbound: (any DatagramSending)?,
        owner: (any Sketch)?, warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.port = port
        self.source = source
        self.outbound = outbound
        self.owner = owner
        self.warn = warn
        input = ExternalQueue(name: name, state: .unavailable)
    }

    /// 出どころの状態。
    public var state: SourceState { input.state }
    /// 最後にメッセージが届いたフレーム。まだ 1 つも届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }

    /// 作るときに決めた送り先 (``Sketch/createOSC(listen:send:)`` の `send`) へ、メッセージを 1 つ送る。
    ///
    /// <!-- example: 文脈 var osc: OSCPort? -->
    /// ```swift
    /// osc?.send("/hit", 1)
    /// osc?.send("/layer", 2, 0.5, "fade")
    /// ```
    ///
    /// **投げない。** 送り先が無い・宛名が `/` で始まらないときは、理由ごとに 1 度だけ知らせて
    /// 何もしない。送れないとき (宛先で誰も受けていない・このアプリにローカルネットワークの許可が
    /// 無い・ネットワークが落ちている) は 1 度だけ診断に出し、``state`` には出ない。送れたら、
    /// また言えるように戻る。待たずに返る。
    ///
    /// - Parameters:
    ///   - address: 宛名。`/` で始める。
    ///   - arguments: 引数。`Int`・`Float`・`Double`・`String`・`Bool` か ``OSCValue``
    ///     (送る形は ``OSCArgument``)。
    public func send(_ address: String, _ arguments: any OSCArgument...) {
        send(OSCMessage(address, arguments: arguments.map(\.oscValue)))
    }

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
    }

    public func close() {
        closed = true
        source.stop()
        outbound?.stop()
        input.setState(.stopped)
        messages = []
    }

    public var report: SourceReport? { input.report }

    // MARK: - 送る

    func send(_ message: OSCMessage) {
        guard !closed else {
            tellOnce("stopped", "This OSC port is stopped, so \(message.address) was not sent")
            return
        }
        guard let outbound else {
            if port == nil {
                tellOnce(
                    "recorded",
                    "This OSC port replays recorded messages and has nowhere to send, so "
                        + "\(message.address) was not sent")
            } else {
                tellOnce(
                    "nowhere",
                    "This OSC port has nowhere to send, so \(message.address) was not sent. "
                        + "Pass send: (host, port) to createOSC(listen:send:)")
            }
            return
        }
        do {
            outbound.send(try OSCCodec.encode(message))
        } catch {
            tellOnce("\(error)", "Could not send OSC: \(error)")
        }
    }

    private func tellOnce(_ key: String, _ message: String) {
        guard toldSending.insert(key).inserted else { return }
        warn(message)
    }
}
