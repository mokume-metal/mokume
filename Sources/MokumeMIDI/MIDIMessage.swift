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
        }
    }

    /// 速度 0 のノートオンを、ノートオフにしたもの。ほかはそのまま。
    var releasingZeroVelocity: MIDIMessage {
        if case .noteOn(let channel, let note, 0) = self { return .noteOff(channel: channel, note: note, velocity: 0) }
        return self
    }

    static let channels = 1...16
    static let data = 0...127
}
