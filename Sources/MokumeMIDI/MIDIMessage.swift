// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 届いた MIDI メッセージ 1 件。``MIDIPort/messages`` が、届いた順に返す。
///
/// <!-- example: 文脈 var midi: MIDIPort! -->
/// ```swift
/// for message in midi.messages {
///     if case .noteOn(_, let note, let velocity) = message {
///         circle(Float(note) * 10, height / 2, Float(velocity))
///     }
/// }
/// ```
///
/// - **チャンネルは 1〜16 で数える。** DAW やコントローラの画面に出る数と同じである
///   (配線上の 0〜15 ではない)
/// - **ノートと値は 0〜127** (MIDI の 7 ビット)。ノートの 60 が真ん中の C
/// - **速度 0 のノートオンは、ノートオフとして届く。** MIDI は「速度 0 のノートオン」でも離したことを
///   伝えるので、読む側が 2 通りを見分けなくてよいようにしてある。機材から届いたものも、
///   ``Sketch/createMIDI(messages:)`` に渡した列も同じに扱う
/// - **クロック・開始・停止・再開・曲の位置は、拍を数える材料である。** ``MIDIPort/beat`` が数えるので、拍だけが
///   要るなら読まなくてよい。クロックは 120 BPM で毎秒 48 個届くので、``MIDIPort/messages`` を読むスケッチは
///   `default` で受ける (ほかのメッセージと同じく、届いた順に全部入る)
///
/// `Codable`・`Sendable` で、記録した列として書き出して読み戻せる。``Sketch/createMIDI(messages:)`` に
/// そのまま渡せる。
public nonisolated enum MIDIMessage: Codable, Sendable, Equatable {
    /// 鍵を押した。
    case noteOn(channel: Int, note: Int, velocity: Int)
    /// 鍵を離した。`velocity` は離す速さで、送らない機材では 0。
    case noteOff(channel: Int, note: Int, velocity: Int)
    /// つまみ・フェーダ・ペダルなどの値が変わった (コントロールチェンジ)。`controller` は 0〜127 の番号で、
    /// `value` は 0〜127。
    case controlChange(channel: Int, controller: Int, value: Int)
    /// テンポのクロック。**24 個で 1 拍** (4 分音符 1 つ) で、走っている間だけ ``MIDIPort/beat`` に数える。
    case clock
    /// 演奏の開始。数えたクロックを 0 に戻し、数え始める。
    case start
    /// 演奏の停止。数えるのを止める。止めている間に届くクロックは、拍を進めない。
    case stop
    /// 演奏の再開。止めた位置 (止めている間に ``songPosition(sixteenths:)`` が届いていればその位置) から数え続ける。
    case `continue`
    /// 曲の位置 (Song Position Pointer)。16 分音符 (= 6 クロック) の数で、数えたクロックをこの数の 6 倍に置く。
    /// `sixteenths` は 0〜16383 (MIDI の 14 ビット)。
    case songPosition(sixteenths: Int)
}

nonisolated extension MIDIMessage {
    /// チャンネルと、2 つのデータが範囲に収まっているか。
    ///
    /// 配線から届くものは常に収まる (7 ビットと 4 ビットで読むため)。収まらないのは、記録した列を
    /// 手で書いたときの誤りで、入れ物が「読めずに捨てた」と数える。
    var isValid: Bool {
        switch self {
        case .noteOn(let channel, let note, let velocity), .noteOff(let channel, let note, let velocity):
            return Self.channels.contains(channel) && Self.data.contains(note) && Self.data.contains(velocity)
        case .controlChange(let channel, let controller, let value):
            return Self.channels.contains(channel) && Self.data.contains(controller)
                && Self.data.contains(value)
        case .clock, .start, .stop, .continue:
            return true
        case .songPosition(let sixteenths):
            return Self.positions.contains(sixteenths)
        }
    }

    /// 速度 0 のノートオンを、ノートオフにしたもの。ほかはそのまま。
    var releasingZeroVelocity: MIDIMessage {
        if case .noteOn(let channel, let note, 0) = self { return .noteOff(channel: channel, note: note, velocity: 0) }
        return self
    }

    static let channels = 1...16
    static let data = 0...127
    /// 曲の位置の範囲 (14 ビット)。
    static let positions = 0...16383
}
