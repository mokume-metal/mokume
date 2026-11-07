// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// OSC を受信して送信する入力ソース。``Sketch/createOSC(listen:send:)`` (送るだけなら ``Sketch/createOSC(send:)``) が作り、
/// 実行中のスケッチへ追加する。
///
/// 毎フレーム呼ぶ API は無い。`draw()` の前に、前のフレームの後に届いたメッセージが**全部**、
/// 届いた順に ``messages`` へ入っている ([ADR-0024] 決定 6)。最新の 1 つだけではないので、
/// 1 フレームの間に何度届いても取りこぼさない ([ADR-0028] 決定 2 の落とさない列 (`ExternalQueue`))。
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
/// 読めない部分 (知らない型タグ・途中で尽きたバイト列など) を含むパケットは、**その部分から
/// 後ろを破棄する**。推測して読み進めると、後ろの値をずれた位置から読んで、黙って間違った値を
/// 出すからである。読めたものだけが ``messages`` に入る。読める型は ``OSCValue`` のとおりで、
/// バンドル (bundle) は中を開いて並んだ順に渡す (バンドルの時刻は見ない)。
///
/// **ちょうど 9216 バイトのパケットは読まずに破棄する。** macOS の受信ソケットは、ループバック (`127.0.0.1`・
/// `::1`) で届いた 9216 バイトを超える datagram を先頭 9216 バイトに黙って切り詰める (別のマシンから届いた
/// ものは全長で渡す)。切り詰められたものはちょうど 9216 バイトで届き、本物の 9216 バイトと見分けられない
/// ので破棄する。先頭だけを読むと、バンドルの先頭のメッセージだけを渡すことになるからである。9217 バイト以上の
/// パケットは全長で届き、読める。
/// **送信は 1 つのパケットが 9212 バイトまで** (9216 バイト未満で、OSC のパケットは 4 バイトの倍数)。
/// ``send(_:_:)`` は、エンコードして 9216 バイト以上になるメッセージ (大きな blob など) は送らない。
///
/// **破棄したことは黙らない。** 読めずに破棄したパケット (切り詰めの疑いで破棄したものも) の数と、バッファに入りきらずに
/// 破棄したメッセージの数 (1 フレームに 4096 を超えて届いたとき) は、次のフレームで診断に出る。
///
/// 空の datagram (0 バイト) は読めないパケットとして数える。ただし macOS の受信ソケットは、空の datagram
/// を受信するとその送信元のストリームを閉じることがあり、そのとき空の直後 (1 ミリ秒ほどの間) に同じ送信元
/// から届いたものは届かない。**このとき失われた数は受信ソケットから見えないので数えない。** 代わりに、空でストリームが閉じたとき
/// (空は読めないパケットとして数える)、失われたかもしれないことを**送信元ごとに 1 度だけ**診断に出す (受信ソケットと
/// 送信元を報告する。覚える送信元は 256 までで、超えたら先に覚えた送信元から忘れる)。実際には何も失われていなくても出る。
///
/// ## 連続値は最新の 1 つで読む
///
/// フェーダーやセンサーのような**連続値**は、列を回して自分の変数に保存しなくても、``latest(_:)`` でアドレスから
/// 最新のメッセージを引ける。列 (``messages``) はイベントを取りこぼさず読むキュー、``latest(_:)`` はアドレスごとの
/// 「最新の 1 つ」を持つ仕組みで、同じ入力ソースが両方を見せる ([ADR-0028] 決定 2)。
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
/// 届かないとき、``state`` がその理由を報告する。`observe` の応答の `inputs` にも同じものが載る
/// ([ADR-0028] 決定 4)。
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 受信している |
/// | ``SourceState/unavailable`` | 開く途中か、他のアプリがそのポートを使っている。空けば受信を始める |
/// | ``SourceState/denied`` | macOS がローカルネットワークを拒んでいる |
/// | ``SourceState/disconnected`` | 受信していたが、失敗した。開き直し続ける |
/// | ``SourceState/stopped`` | ``stop()`` した (追加し直しても戻らない)。ランタイムが外した (``SketchPart/detach(_:)-(Inlet)``) だけなら、追加し直せば受信を始める |
///
/// 使用中・拒まれた・失敗したときは、1 度だけ診断に出す。
///
/// **送信できないことは ``state`` に出ない** ([ADR-0028] 決定 4)。``state`` が示すのは受信側の様子
/// である。送信できないとき (宛先で誰も受信していない・このアプリにローカルネットワークの許可が無い・
/// ネットワークが切断されている) は、1 度だけ診断に出す。送信できたら、また出力できるように戻る (UDP の送信の完了は届いたことを
/// 保証せず、拒否は次の送信の失敗として返るので、宛先に拒否された後は、間 (既定 0.5 秒) を空けた次の送信まで
/// 拒否されずに終わって初めて「送信できた」と判断する)。
///
/// ## 観測・操作用のインターフェースとは別のもの
///
/// OSC は、実行中のスケッチを外から観測・操作するインターフェース ([ADR-0018]) ではない。あちらは socket も
/// ポートも新設せず、作業ディレクトリのファイルだけでやりとりすると決めている (決定 1)。
/// この入力ソースは、スケッチが自分で開く**外からの入力**の 1 つで、カメラやマイクと同じ入力ソース
/// (``Inlet``) を通る。ポートが開くのはスケッチが ``Sketch/createOSC(listen:send:)`` を呼んだとき
/// だけで、mokume の実行や `observe` がポートを開くことはない。エージェントが値を差し込んで描画を
/// 確かめるときは、ポートではなく `observe` のインターフェースと、記録した列の注入
/// (``Sketch/createOSC(messages:)``) を使う。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class OSCPort: Inlet {
    /// 受信しているポート。記録した列を流している・送信だけ (``Sketch/createOSC(send:)``) なら `nil`。
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

    /// アドレス `address` の、最後に届いたメッセージ。まだ 1 つも届いていなければ `nil`。
    ///
    /// **連続値 (フェーダー・つまみ・センサー) を読む API である。** ``messages`` がイベントを取りこぼさず渡す列
    /// なのに対し、こちらはアドレスごとの「最新の 1 つ」で、MIDI の `controlChange(_:)` と同じ仕組み
    /// ([ADR-0028] 決定 2)。番号で引く MIDI と、アドレスで引くこの API は引き方が違うので、名前は揃えない。
    ///
    /// <!-- example: 文脈 var osc: OSCPort? -->
    /// ```swift
    /// let fader = osc?.latest("/1/fader1")?.float(0) ?? 0
    /// ```
    ///
    /// - **フレームの頭で更新される。** ``supply()`` が ``messages`` を作るときに、同じアドレスのうち最後に
    ///   届いたものへ置き換える。1 フレームに何度届いても最後の 1 つで、何も届かないフレームは前の
    ///   ままである。同じ列を流せば、何度回しても同じ (記録した列 (``Sketch/createOSC(messages:)``) も同じで、
    ///   ``messages`` を記録すれば足りる)
    /// - **アドレスは文字どおりに引く。** `/1/*` のようなワイルドカードは受け付けず、一致するアドレスが無ければ `nil`
    /// - 覚えるのは 4096 アドレスまで。超えて届いた新しいアドレスは覚えず、1 度だけ診断に出す。覚えたアドレスは更新し続け、
    ///   ``messages`` は取りこぼさない
    /// - ``stop()`` の後は、``messages`` と同じく空 (`nil`)
    ///
    /// - Parameter address: アドレス (`/1/fader1`)。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func latest(_ address: String) -> OSCMessage? {
        latestByAddress[address]
    }

    /// 入力元の状態。送信専用の入力ソース (``Sketch/createOSC(send:)``) は受信しないので、動いている間は `running`。
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
    /// **投げない。** 送り先が無い・アドレスが `/` で始まらないときは、理由ごとに 1 度だけ警告して
    /// 何もしない。エンコードして 9216 バイト以上になる (1 つのパケットは 9212 バイトまで。大きな blob
    /// など) ときも送らずに警告し、続く間はアドレスごとに 1 度だけ出す。送信できないとき (宛先で誰も
    /// 受信していない・このアプリにローカルネットワークの許可が無い・ネットワークが切断されている) は
    /// 1 度だけ診断に出し、``state`` には出ない。どちらも、送信できたら、また出力できるように戻る (宛先に拒否された後は、
    /// 間 (既定 0.5 秒) を空けた次の送信まで拒否されずに終わって初めて「送信できた」と判断する)。待たずに返る。
    ///
    /// - Parameters:
    ///   - address: アドレス。`/` で始める。
    ///   - arguments: 引数。`Int`・`Float`・`Double`・`String`・`Bool` か ``OSCValue``
    ///     (送る形は ``OSCArgument``)。
    public func send(_ address: String, _ arguments: any OSCArgument...) {
        send(OSCMessage(address, arguments: arguments.map(\.oscValue)))
    }

    /// 止める。ポートを閉じ、以後 ``messages`` は空のままで、送っても何も出ない。
    ///
    /// **利用者が止めたものは、追加し直しても止まったままである。** ``SketchPart/attach(_:)-(Inlet)`` で追加し直しても、
    /// 受信も送信もせず、``state`` は ``SourceState/stopped`` のまま (止めたのは利用者の意思なので、追加し直しで
    /// 戻さない)。受信を始めるには、新しく作る。
    ///
    /// **ランタイムが外した場合は別である。** ``SketchPart/detach(_:)-(Inlet)`` で外しただけ (``stop()`` は呼んで
    /// いない) なら、``SketchPart/attach(_:)-(Inlet)`` で追加し直せば、また受信を始め、送信でき、``state`` も戻る。
    /// 実行が終わったものは追加し直す先が無い。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``SketchPart/detach(_:)-(Inlet)`` と同じ)。
    /// 実行中のスケッチの中で開始した `Task` からも止まる。外 (初期化子の中・終了処理の後) で呼ぶと何もせず、`OSCPort.stop()` のように型名を付けた名前で 1 度だけ警告する。
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

    /// 送信専用の入力ソースは受信ソケットではないので、`observe` の応答の `inputs` に行を出さない。
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
