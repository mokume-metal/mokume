// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// OSC を受けて送る入り口。``Sketch/createOSC(listen:send:)`` (送るだけなら ``Sketch/createOSC(send:)``) が作り、
/// 走っているスケッチへ足す。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、前のフレームの後に届いたメッセージが**全部**、
/// 届いた順に ``messages`` へ入っている ([ADR-0024] 決定 6)。最新の 1 つだけではないので、
/// 1 フレームの間に何度届いても取りこぼさない ([ADR-0028] 決定 2 の「落とさない列」)。
///
/// ```swift
/// final class Remote: Sketch {
///     var osc: OSCPort?
///     var size: Float = 0.5
///     func setup() throws { osc = try createOSC(listen: 9000, send: ("127.0.0.1", 7000)) }
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
/// **1 つのパケットは 9212 バイトまで** (9216 バイト未満で、OSC のパケットは 4 バイトの倍数)。
/// macOS の受け口は 9216 バイトを超える datagram を先頭 9216 バイトに黙って切るので、9216 バイト
/// 以上のパケットは読まずに丸ごと捨てる (切れたものと見分けられないので、ちょうど 9216 バイトの
/// ものも捨てる)。先頭だけを読むと、束の頭のメッセージだけを渡すことになるからである。
/// ``send(_:_:)`` も、符号化して 9216 バイト以上になるメッセージ (大きな blob など) は送らない。
///
/// **捨てたことは黙らない。** 読めずに捨てたパケット (大きすぎて捨てたものも) の数と、溜めきれずに
/// 捨てたメッセージの数 (1 フレームに 4096 を超えて届いたとき) は、次のフレームで診断に出る。
///
/// 空の datagram (0 バイト) は読めないパケットとして数える。ただし macOS の受け口は、空の datagram
/// を受けるとその送り元の流れを閉じることがあり、そのとき空の直後 (1 ミリ秒ほどの間) に同じ送り元
/// から届いたものは届かない。**この落ちた数は受け口から見えないので数えない。** 代わりに、空で流れが閉じたとき
/// (空は読めないパケットとして数える)、落ちたかもしれないことを**送り元ごとに 1 度だけ**診断に出す (受け口と
/// 送り元を名乗る。覚える送り元は 256 までで、超えたら先に覚えた送り元から忘れる)。実際には何も落ちていなくても出る。
///
/// ## 連続値は最新の 1 つで読む
///
/// フェーダーやセンサーのような**連続値**は、列を回して自分の変数に預けなくても、``latest(_:)`` で宛名から
/// 最新のメッセージを引ける。列 (``messages``) は出来事を落とさず読む入れ物、``latest(_:)`` は宛名ごとの
/// 「最新の 1 つ」の入れ物で、同じ受け口が両方を見せる ([ADR-0028] 決定 2)。
///
/// <!-- example: 文脈 var osc: OSCPort? -->
/// ```swift
/// func draw() {
///     for i in 1...8 {
///         let v = osc?.latest("/1/fader\(i)")?.float(0) ?? 0
///         rect(Float(i) * 100, height - v * height, 80, v * height)
///     }
/// }
/// ```
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
/// | ``SourceState/stopped`` | ``stop()`` した (足し直しても戻らない)。ランタイムが外した (``SketchPart/detach(_:)-(Inlet)``) だけなら、足し直せば受け始める |
///
/// 使用中・拒まれた・失敗したときは、1 度だけ診断に出す。
///
/// **送れないことは ``state`` に出ない。** ``state`` が名乗るのは受けるほうの様子である。送れない
/// とき (宛先で誰も受けていない・このアプリにローカルネットワークの許可が無い・ネットワークが
/// 落ちている) は、1 度だけ診断に出す。送れたら、また言えるように戻る (UDP の送信の完了は届いたことを
/// 言わず、拒否は次の送信の失敗として返るので、宛先に拒まれた後は、間 (既定 0.5 秒) を空けた次の送信まで
/// 拒まれずに終わって初めて「送れた」と読む)。
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
    /// 受けているポート。記録した列を流している・送るだけ (``Sketch/createOSC(send:)``) なら `nil`。
    public let port: Int?
    /// このフレームの前に届いたメッセージ。届いた順。何も届いていなければ空。
    public private(set) var messages: [OSCMessage] = []

    /// 宛名ごとの、最後に届いたメッセージ。``supply()`` で更新する。
    private var latestByAddress: [String: OSCMessage] = [:]
    /// 覚えておく宛名の数の上限。外から届く宛名は選べないので、`/note/123456` のように宛名に数を含める
    /// 送り手が居ても、格納が伸び続けない。上限は ``ExternalQueue`` の 1 フレームの上限に揃える。
    static let latestAddressLimit = 4096

    let input: ExternalQueue<OSCMessage>
    let source: any MessageSource<OSCMessage>
    private let outbound: (any DatagramSending)?

    /// 送り手が見たことの跡。送り手が跡を持たなければ (記録するだけの送り手・送り先の無い入り口) `nil`。
    /// 検査が、送ったものが受け口で読まれなかった回の名乗りに載せる (#3001)。読むだけで、振る舞いを決めない。
    var sendTrace: SendTrace? { (outbound as? SendTracing)?.sendTrace }
    private weak var owner: (any Sketch)?
    private let warn: (String) -> Void
    /// 知らせた送れない理由。同じものは 2 度言わない。
    private var toldSending: Set<String> = []
    /// 外されている (``close()`` の後で、まだ足し直されていない)。足し直す (``open()``) と戻る。
    private var closed = false
    /// 利用者が ``stop()`` を呼んだ。**足し直しの ``open()`` でも戻さない** (利用者の意思として粘る)。
    private var stoppedByUser = false

    init(
        port: Int?, name: String, source: any MessageSource<OSCMessage>,
        outbound: (any DatagramSending)?,
        owner: (any Sketch)?, warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.port = port
        self.source = source
        self.outbound = outbound
        self.owner = owner
        self.warn = warn
        input = ExternalQueue(name: name, state: .unavailable)
    }

    /// 宛名 `address` の、最後に届いたメッセージ。まだ 1 つも届いていなければ `nil`。
    ///
    /// **連続値 (フェーダー・つまみ・センサー) を読む口である。** ``messages`` が出来事を落とさず渡す列
    /// なのに対し、こちらは宛名ごとの「最新の 1 つ」で、MIDI の `controlChange(_:)` と同じ入れ物
    /// ([ADR-0028] 決定 2)。番号で引く MIDI と、宛名で引くこの口は引き方が違うので、名前は揃えない。
    ///
    /// <!-- example: 文脈 var osc: OSCPort? -->
    /// ```swift
    /// let fader = osc?.latest("/1/fader1")?.float(0) ?? 0
    /// ```
    ///
    /// - **フレームの頭で更新される。** ``supply()`` が ``messages`` を作るときに、同じ宛名のうち最後に
    ///   届いたものへ置き換える。1 フレームに何度届いても最後の 1 つで、何も届かないフレームは前の
    ///   ままである。同じ列を流せば、何度回しても同じ (記録した列 (``Sketch/createOSC(messages:)``) も同じで、
    ///   ``messages`` を記録すれば足りる)
    /// - **宛名は文字どおりに引く。** `/1/*` のようなワイルドカードは受けず、一致する宛名が無ければ `nil`
    /// - 覚えるのは 4096 宛名まで。超えて届いた新しい宛名は覚えず、1 度だけ診断に出す。覚えた宛名は更新し続け、
    ///   ``messages`` は落とさない
    /// - ``stop()`` の後は、``messages`` と同じく空 (`nil`)
    ///
    /// - Parameter address: 宛名 (`/1/fader1`)。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func latest(_ address: String) -> OSCMessage? {
        latestByAddress[address]
    }

    /// 出どころの状態。送るだけの口 (``Sketch/createOSC(send:)``) は受けないので、動いている間は `running`。
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
    /// 何もしない。符号化して 9216 バイト以上になる (1 つのパケットは 9212 バイトまで。大きな blob
    /// など) ときも送らずに知らせ、続く間は宛名ごとに 1 度だけ言う。送れないとき (宛先で誰も
    /// 受けていない・このアプリにローカルネットワークの許可が無い・ネットワークが落ちている) は
    /// 1 度だけ診断に出し、``state`` には出ない。どちらも、送れたら、また言えるように戻る (宛先に拒まれた後は、
    /// 間 (既定 0.5 秒) を空けた次の送信まで拒まれずに終わって初めて「送れた」と読む)。待たずに返る。
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
    /// **利用者が止めたものは、足し直しても止まったままである。** ``SketchPart/attach(_:)-(Inlet)`` で足し直しても、
    /// 受けも送りもせず、``state`` は ``SourceState/stopped`` のまま (止めたのは利用者の意思なので、足し直しで
    /// 戻さない)。受け始めるには、新しく作る。
    ///
    /// **ランタイムが外した場合は別である。** ``SketchPart/detach(_:)-(Inlet)`` で外しただけ (``stop()`` は呼んで
    /// いない) なら、``SketchPart/attach(_:)-(Inlet)`` で足し直せば、また受け始め、送れ、``state`` も戻る。
    /// 実行が終わったものは足し直す先が無い。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``SketchPart/detach(_:)-(Inlet)`` と同じ)。
    /// 走っている実行の中で起こした `Task` からも止まる。外 (初期化子の中・後片付けの後) で呼ぶと何もせず、`OSCPort.stop()` のように型を付けた名前で 1 度だけ警告する。
    public func stop() {
        // 印は、外す頼みが実行に届いたときだけ立てる。外で呼んで警告だけ出した回に立てると、走っているポートが止まる
        if owner?.detach(self, calledAs: "OSCPort.stop()") == true { stoppedByUser = true }
    }

    // MARK: - Inlet

    public func open() throws {
        // 足し直しでも呼ばれる (``close()`` の後の 2 度目)。利用者が ``stop()`` したものは戻さない。
        // ランタイムが外しただけなら、外していた間に立てた印と、「止まっている」と知らせた記憶を戻す。
        // 受け口は ``source`` が開き直し、送り手は次の送信で繋ぎ直す
        guard !stoppedByUser else { return }
        closed = false
        toldSending.remove("stopped")
        source.start(into: input)
    }

    public func supply() {
        source.pump(into: input)
        messages = input.take()
        for message in messages {
            guard
                latestByAddress[message.address] != nil
                    || latestByAddress.count < Self.latestAddressLimit
            else {
                tellOnce(
                    "latestFull",
                    "This OSC port remembers the latest message of \(Self.latestAddressLimit) addresses "
                        + "only, so latest(_:) does not know \(message.address) and the addresses "
                        + "that first arrive after it. messages still carries every message")
                continue
            }
            latestByAddress[message.address] = message
        }
    }

    public func close() {
        closed = true
        source.stop()
        outbound?.stop()
        input.setState(.stopped)
        // 届いて読まれなかった分は捨てる。足し直した最初の ``supply()`` に、外す前のものを出さない
        input.discardWaiting()
        messages = []
        latestByAddress = [:]
    }

    /// 送るだけの口は受け口ではないので、観測の応答の `inputs` に行を出さない。
    public var report: SourceReport? { source is SendOnlySource ? nil : input.report }

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
            let bytes = try OSCCodec.encode(message)
            // 送り手へ渡せば `Message too long` で送れず、受け手が居ない見当で名乗って繋ぎを捨てる。
            // 大きすぎる送りが続く間は宛名ごとに 1 度だけ言い、上限以内を送れたら、また言えるように戻す
            guard Datagram.fits(bytes.count) else {
                tellOnce(
                    Self.tooLarge + message.address,
                    "\(message.address) was not sent because it is \(bytes.count) bytes as OSC, "
                        + "and one OSC packet over UDP carries \(Self.largestPacket) bytes at most")
                return
            }
            toldSending = toldSending.filter { !$0.hasPrefix(Self.tooLarge) }
            outbound.send(bytes)
        } catch {
            tellOnce("\(error)", "Could not send OSC: \(error)")
        }
    }

    private func tellOnce(_ key: String, _ message: String) {
        guard toldSending.insert(key).inserted else { return }
        warn(message)
    }

    /// 送れる OSC のパケットの最大 (バイト)。パケットは 4 バイトの倍数なので、datagram の上限
    /// (``Datagram/sizeLimit`` 未満) に収まる 4 の倍数のうち最大のもの (9212)。
    static let largestPacket = (Datagram.sizeLimit - 1) / 4 * 4

    /// 大きすぎて送らなかったことを知らせた鍵の頭。後ろに宛名が付く。
    private static let tooLarge = "tooLarge "
}
