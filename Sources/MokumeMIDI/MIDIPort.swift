// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 接続されている MIDI デバイス 1 台の、一覧に載る情報。``Sketch/midiDevices()`` が返し、
/// ``Sketch/createMIDI(_:)`` で 1 台を選ぶのに使う。
///
/// <!-- example: 文脈 var midi: MIDIPort? -->
/// ```swift
/// for device in midiDevices() { print(device.id, device.isConnected) }
/// if let first = midiDevices().first { midi = createMIDI(first) }
/// ```
public nonisolated struct MIDIDevice: Sendable, Equatable {
    /// 識別子。「デバイス名 #番号」の形で振る (`"Launchpad Mini #1"`)。番号は、同じ名前のデバイスが初めて接続された順に 1 から振る
    /// (同時に見えたデバイスは、CoreMIDI がデバイスごとに振る一意な番号の順)。
    ///
    /// **切断して再接続しても同じ値になる。** 同じ機種を 2 台接続していて、両方を切断して逆の順に再接続しても、
    /// その一意な番号で同じデバイスへ戻る。その番号が変わって見えるデバイスは、同じ名前で切断されている番号の
    /// 小さいほうへ戻る。
    ///
    /// **見分けられない場合がある。** 一意な番号が再接続で変わるデバイスは、同じ名前の新しいデバイスと区別できない
    /// (切断されているスロットがあれば、新しいデバイスがそこへ入る)。プロセスの再起動をまたぐ保証でもない —
    /// 起動ごとに、見えた順 (同時なら一意な番号の順) に番号を振り直す。
    public let id: String
    /// デバイスの名前。OS が報告するとおり (`"Launchpad Mini"`)。
    public let name: String
    /// いま接続されているか。切断されたデバイスも一覧に残り、再接続すれば `true` に戻る。
    public let isConnected: Bool

    init(id: String, name: String, isConnected: Bool) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
    }
}

/// MIDI デバイス 1 台からの入力ソース。``Sketch/createMIDI(_:)`` が作り、実行中のスケッチへ追加する。
///
/// 毎フレーム呼ぶ API は無い。`draw()` の前に、前のフレームの後に届いたメッセージが ``messages`` に
/// **全部、届いた順に**入り ([ADR-0028] 決定 2 の落とさない列 (`ExternalQueue`))、コントロールチェンジの現在値が
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
/// ## 切断されたことが読める
///
/// 切断されると ``state`` が ``SourceState/disconnected`` になり、押していたノートの ``MIDIMessage/noteOff(channel:note:velocity:)``
/// が ``messages`` の最後に入る (押したままのキーが残らない)。コントロールチェンジの現在値は残る — つまみは
/// 切断しても動いていない。再接続すれば同じ物が ``SourceState/running`` に戻る。`observe` の応答の `inputs` にも、デバイスごとに
/// 同じものが載る ([ADR-0028] 決定 4)。
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 接続されている |
/// | ``SourceState/disconnected`` | 切断された。再接続すれば戻る |
/// | ``SourceState/unavailable`` | そのデバイスが一度も接続されていない・実行中でないスケッチから作った・記録した列が空 |
/// | ``SourceState/stopped`` | スケッチから外した (``SketchPart/detach(_:)-(Inlet)``)。追加し直せば戻る |
///
/// 許可は要らない。受け取るのは ノートオン・ノートオフ・コントロールチェンジと、ビートを数えるクロック (``beat``)
/// だけで、ピッチベンドなどほかのメッセージは「読めなかったもの」として数え、診断に出す
/// (アクティブセンシングなど、デバイスが絶えず送るものは数えずに無視する)。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class MIDIPort: Inlet {
    /// 前のフレームの後に届いたメッセージ。届いた順で、無ければ空。
    ///
    /// **1 つも落とさない。** 1 フレームに押して離したキーも、全部入る。キューには上限があり、読まれないまま溜まりすぎると
    /// 古いものから破棄し、破棄した数を診断に出す。
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

    /// 入力元の状態。
    public var state: SourceState { inbox.state }

    /// 受信したクロックから数えたビート (0 から)。何も届いていなければ 0。
    ///
    /// <!-- example: 文脈 var midi: MIDIPort! -->
    /// ```swift
    /// // ビートごとに背景の明るさが切り替わる
    /// background(midi.beat % 2 == 0 ? 30 : 200)
    /// ```
    ///
    /// **24 クロックで 1 ビート** (4 分音符 1 つ) で、テンポは数えない。届く間隔がそのままテンポなので、DAW のテンポを
    /// 変えれば切り替わる間隔もついてくる。フレームの頭の値で答える — **届いた後の最初のフレーム**で変わり、
    /// 1 フレームにビートをまたいで複数のクロックが届けば、そのフレームの終わりのビートになる。
    ///
    /// | 届くもの | ビートの扱い |
    /// | --- | --- |
    /// | ``MIDIMessage/clock`` | 再生中だけ数える |
    /// | ``MIDIMessage/start`` | 0 に戻して、数え始める |
    /// | ``MIDIMessage/stop`` | 数えるのを止める。止めている間のクロックは進めない |
    /// | ``MIDIMessage/continue`` | 止めた位置から数え続ける |
    /// | ``MIDIMessage/songPosition(sixteenths:)`` | 16 分音符の数の 6 倍のクロックを数えたことにする |
    ///
    /// 曲の位置は、MIDI 1.0 では主に止めている間に届き、続く再開がそこから数える。**再生中に届いても、位置を設定する。**
    ///
    /// **最初の開始が届く前は、再生中として数える。** 開始を送らずクロックだけ流すデバイスでもビートが進む。
    /// 代償として、止めている間もクロックを流し続けるデバイスは、最初の開始が届くまでビートがずれて数える
    /// (開始で 0 に戻る)。
    /// 同じデバイスから後で入力ソースを作り直しても (`watch` の作り直しなど)、数えていたビートから続く。
    ///
    /// **限界が 2 つある。** UMP のグループは区別せず (1 台 1 グループの前提)、別のグループから届いたクロックも
    /// 合算で数える。システムリセット (0xFF) はビートを戻さず無視する。
    ///
    /// **クロックは ``messages`` に入らない。** ビートを進めるだけで、開始・停止・再開・曲の位置は ``messages`` にも入る。
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
    /// デバイスが 1 台で、つまみ 1 本の最小の使い方では、チャンネルを意識せずに書ける。チャンネルを渡すと、そのチャンネルで
    /// 最後に届いた値になる。
    ///
    /// **値は、監視が始まってから動いたつまみの分だけ読める。** 監視は最初に ``Sketch/midiDevices()`` か
    /// ``Sketch/createMIDI(_:)`` を呼んだときに始まり、その後に動いたつまみの値は、後から作った入力ソース・追加し直した
    /// 入力ソースからも読める。MIDI には、いまのつまみの位置をデバイスに尋ねる手段が無いので、`watch` で作り直した直後など、
    /// 監視が始まる前の位置は分からない — つまみを動かすまで `nil` のままである。
    ///
    /// MIDI の 0〜127 を 0〜1 に変換する (127 が 1)。生の値が要るなら、``messages`` の
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
