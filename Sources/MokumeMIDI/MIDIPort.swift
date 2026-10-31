// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 繋がっている MIDI 機材 1 台の、一覧での姿。``Sketch/midiDevices()`` が返し、
/// ``Sketch/createMIDI(_:)`` で 1 台を選ぶのに使う。
///
/// <!-- example: 文脈 var midi: MIDIPort? -->
/// ```swift
/// for device in midiDevices() { print(device.id, device.isConnected) }
/// if let first = midiDevices().first { midi = createMIDI(first) }
/// ```
public nonisolated struct MIDIDevice: Sendable, Equatable {
    /// 識別子。「機材名 #番号」の形で振る (`"Launchpad Mini #1"`)。番号は、同じ名前の機材が初めて繋がった順に 1 から振る
    /// (同時に見えた機材は、CoreMIDI が機材ごとに振る一意な番号の順)。
    ///
    /// **抜いて挿し直しても同じ値になる。** 同じ機種を 2 台挿していて、両方を抜いて逆の順に挿しても、
    /// その一意な番号で同じ機材へ戻る。その番号が変わって見える機材は、同じ名前で抜かれている番号の
    /// 小さいほうへ戻る。
    ///
    /// **見分けられない場合がある。** 一意な番号が挿し直しで変わる機材は、同じ名前の新しい機材と区別できない
    /// (抜かれている席があれば、新しい機材がそこへ入る)。プロセスの再起動をまたぐ約束でもない —
    /// 起動ごとに、見えた順 (同時なら一意な番号の順) に番号を振り直す。
    public let id: String
    /// 機材の名前。OS が名乗るとおり (`"Launchpad Mini"`)。
    public let name: String
    /// いま繋がっているか。抜かれた機材も一覧に残り、挿し直せば `true` に戻る。
    public let isConnected: Bool

    init(id: String, name: String, isConnected: Bool) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
    }
}

/// MIDI 機材 1 台からの入力の入り口。``Sketch/createMIDI(_:)`` が作り、走っているスケッチへ足す。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、前のフレームの後に届いたメッセージが ``messages`` に
/// **全部、届いた順に**入り ([ADR-0028] 決定 2 の「落とさない列」)、コントロールチェンジの現在値が
/// ``controlChange(_:channel:)`` から読める。
///
/// <!-- example: 文脈 var midi: MIDIPort? -->
/// ```swift
/// // 1 番のつまみで円の色相を回す
/// let hue = midi?.controlChange(1) ?? 0
/// fill(color(hue: hue * 360, saturation: 90, brightness: 100))
/// circle(width / 2, height / 2, 200)
/// ```
///
/// ## 抜かれたことが読める
///
/// 抜かれると ``state`` が ``SourceState/disconnected`` になり、押していたノートの ``MIDIMessage/noteOff(channel:note:velocity:)``
/// が ``messages`` の最後に入る (押したままの鍵が残らない)。コントロールチェンジの現在値は残る — つまみは
/// 抜いても動いていない。挿し直せば同じ物が ``SourceState/running`` に戻る。観測の応答の `inputs` にも、機材ごとに
/// 同じものが載る ([ADR-0028] 決定 4)。
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 繋がっている |
/// | ``SourceState/disconnected`` | 抜かれた。挿し直せば戻る |
/// | ``SourceState/unavailable`` | その機材が一度も繋がっていない・走っていないスケッチから作った・記録した列が空 |
/// | ``SourceState/stopped`` | スケッチから外した (``SketchPart/detach(_:)-(Inlet)``)。足し直せば戻る |
///
/// 許可は要らない。受けるのは ノートオン・ノートオフ・コントロールチェンジと、拍を数えるクロック (``beat``)
/// だけで、ピッチベンドなどほかのメッセージは「読めずに捨てた」と数えて診断に出す
/// (アクティブセンシングなど、機材が絶えず送るものは数えずに読み飛ばす)。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class MIDIPort: Inlet {
    /// 前のフレームの後に届いたメッセージ。届いた順で、無ければ空。
    ///
    /// **1 つも落とさない。** 1 フレームに押して離した鍵も、全部入る。列には上限があり、読まれないまま溜まりすぎると
    /// 古いものから捨て、捨てた数を診断に出す。
    public private(set) var messages: [MIDIMessage] = []

    let id: String
    let inbox: MIDIInbox
    private let source: any MIDISource
    private var controllers = MIDIControllers()
    private var clock = MIDIClock()

    init(id: String, name: String, source: any MIDISource, capacity: Int = 4096) {
        self.id = id
        self.source = source
        inbox = MIDIInbox(name: name, state: .unavailable, capacity: capacity)
    }

    /// 出どころの状態。
    public var state: SourceState { inbox.state }

    /// 受けたクロックから数えた拍 (0 から)。何も届いていなければ 0。
    ///
    /// <!-- example: 文脈 var midi: MIDIPort! -->
    /// ```swift
    /// // 拍ごとに背景の明るさが切り替わる
    /// background(midi.beat % 2 == 0 ? 30 : 200)
    /// ```
    ///
    /// **24 クロックで 1 拍** (4 分音符 1 つ) で、テンポは数えない。届く間隔がそのままテンポなので、DAW のテンポを
    /// 変えれば切り替わる間隔もついてくる。フレームの頭の値で答える — **届いた後の最初のフレーム**で変わり、
    /// 1 フレームに拍をまたいで複数のクロックが届けば、そのフレームの終わりの拍になる。
    ///
    /// | 届くもの | 拍の扱い |
    /// | --- | --- |
    /// | ``MIDIMessage/clock`` | 走っている間だけ数える |
    /// | ``MIDIMessage/start`` | 0 に戻して、数え始める |
    /// | ``MIDIMessage/stop`` | 数えるのを止める。止めている間のクロックは進めない |
    /// | ``MIDIMessage/continue`` | 止めた位置から数え続ける |
    /// | ``MIDIMessage/songPosition(sixteenths:)`` | 16 分音符の数の 6 倍のクロックを数えたことにする (止めている間に届き、続く再開がそこから数える) |
    ///
    /// **最初の開始が届く前は、走っているものとして数える。** 開始を送らずクロックだけ流す機材でも拍が進む。
    /// 同じ機材から後で入り口を作り直しても (`watch` の作り直しなど)、数えていた拍から続く。
    public var beat: Int { clock.beat }

    /// コントロールチェンジの現在値 (0〜1)。そのコントローラがまだ 1 度も届いていなければ `nil`。
    ///
    /// <!-- example: 文脈 var midi: MIDIPort! -->
    /// ```swift
    /// let volume = midi.controlChange(7, channel: 2) ?? 0
    /// circle(width / 2, height / 2, 20 + volume * 200)
    /// ```
    ///
    /// フレームの頭の値で答える。`channel` を省くと、**どのチャンネルでも最後に届いたその番号の値**を返す。
    /// 機材が 1 台で、つまみ 1 本の最小の使い方では、チャンネルを意識せずに書ける。チャンネルを渡すと、そのチャンネルで
    /// 最後に届いた値になる。
    ///
    /// **値は、見張りが始まってから動いたつまみの分だけ読める。** 見張りは最初に ``Sketch/midiDevices()`` か
    /// ``Sketch/createMIDI(_:)`` を呼んだときに始まり、その後に動いたつまみの値は、後から作った入り口・足し直した
    /// 入り口からも読める。MIDI には、いまのつまみの位置を機材に尋ねる手段が無いので、`watch` で作り直した直後など、
    /// 見張りが始まる前の位置は分からない — つまみを動かすまで `nil` のままである。
    ///
    /// MIDI の 0〜127 を 0〜1 に写す (127 が 1)。生の値が要るなら、``messages`` の
    /// ``MIDIMessage/controlChange(channel:controller:value:)`` を読む。
    ///
    /// - Parameters:
    ///   - controller: コントローラの番号 (0〜127)。1 がモジュレーションホイール、7 がボリューム。範囲外は `nil`。
    ///   - channel: チャンネル (1〜16)。省けば、どのチャンネルでもよい。範囲外は `nil`。
    public func controlChange(_ controller: Int, channel: Int? = nil) -> Float? {
        controllers.value(controller: controller, channel: channel).map { Float($0) / 127 }
    }

    // MARK: - Inlet

    public func open() throws {
        source.start(into: inbox)
    }

    public func supply() {
        source.pump(into: inbox)
        // 現在値の表と出来事は、同じ錠の内側で一緒に取る (同じフレームで食い違わない)
        let taken = inbox.take()
        if let table = taken.controllers { controllers = table }
        if let counted = taken.clock { clock = counted }
        messages = taken.messages
    }

    public func close() {
        source.stop()
        inbox.setState(.stopped)
        // 届いて読まれなかった出来事は捨てる。足し直した最初の `supply()` に、外す前のものを当てない。
        // 現在値の表は残す (つまみは動いていない)。足し直すとき入れ物へ戻す
        inbox.discardWaiting()
        messages = []
    }

    public var report: SourceReport? { inbox.report }
}
