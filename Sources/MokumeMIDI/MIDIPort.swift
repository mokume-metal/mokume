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
    /// 識別子。「機材名 #番号」の形で振る (`"Launchpad Mini #1"`)。番号は、同じ名前の機材が初めて繋がった順に 1 から振る。
    ///
    /// **抜いて挿し直しても同じ値になる。** 同じ機種を 2 台挿していて、両方を抜いて逆の順に挿しても、
    /// CoreMIDI が機材ごとに振る一意な番号で同じ機材へ戻る。その番号が変わって見える機材は、同じ名前で
    /// 抜かれている番号の小さいほうへ戻る。
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
/// 許可は要らない。受けるのは ノートオン・ノートオフ・コントロールチェンジだけで、ピッチベンドなどほかの
/// メッセージは「読めずに捨てた」と数えて診断に出す。クロックは受けない。
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

    init(id: String, name: String, source: any MIDISource, capacity: Int = 4096) {
        self.id = id
        self.source = source
        inbox = MIDIInbox(name: name, state: .unavailable, capacity: capacity)
    }

    /// 出どころの状態。
    public var state: SourceState { inbox.state }

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
        if let table = inbox.controllers.take() { controllers = table }
        messages = inbox.messages.take()
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
