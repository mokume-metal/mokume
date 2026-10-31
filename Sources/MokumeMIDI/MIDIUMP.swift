// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// UMP (Universal MIDI Packet) の語の並びを、メッセージへ読む。**CoreMIDI にも機材にも触れない**
/// 純粋な関数で、検査が語を直に渡して回す。
///
/// CoreMIDI を `MIDIInputPortCreateWithProtocol` の MIDI 1.0 の写像で開くと、機材が MIDI 2.0 でも
/// 1.0 のチャンネルボイス (7 ビット) に落ちて届く。読むのはその形である。
///
/// **UMP の group は読まない。** MIDI 1.0 の口は端点ごとに受けるので、1 つの端点には group 0 の 1 本だけが届く
/// (届いたら group を問わず同じに読み、クロックは合算で数える)。システムリセット (0xFF) は拍を戻さず読み飛ばす。
///
/// | UMP の種別 | 扱い |
/// | --- | --- |
/// | 0 (ユーティリティ) | 読み飛ばす (数えない) |
/// | 1 (クロック・開始・停止などのシステム) | クロック (0xF8)・開始 (0xFA)・再開 (0xFB)・停止 (0xFC)・曲の位置 (0xF2) を読む。ほか (アクティブセンシング・リセット・MIDI タイムコード・曲の選択など) は読み飛ばす (数えない) |
/// | 2 (MIDI 1.0 チャンネルボイス) | ノートオン・ノートオフ・コントロールチェンジを読む。ほかは「読めない」 |
/// | それ以外 (SysEx など) | 「読めない」 |
nonisolated enum MIDIUMP {
    /// 読んだ結果。
    struct Decoded: Equatable {
        /// 読めたメッセージ。語の並びの順。
        var messages: [MIDIMessage] = []
        /// 読めずに捨てた数。
        var unreadable = 0
    }

    /// 語の並びを読む。途中で切れた末尾は「読めない」1 件と数える。
    static func decode(_ words: [UInt32]) -> Decoded {
        var result = Decoded()
        var index = 0
        while index < words.count {
            let word = words[index]
            let size = wordCount(ofType: Int(word >> 28))
            guard index + size <= words.count else {
                result.unreadable += 1
                break
            }
            index += size
            switch word >> 28 {
            case 0:
                continue
            case 1:
                if let message = system(word) { result.messages.append(message) }
            case 2:
                if let message = channelVoice(word) {
                    result.messages.append(message)
                } else {
                    result.unreadable += 1
                }
            default:
                result.unreadable += 1
            }
        }
        return result
    }

    /// メッセージ種別ごとの語の数 (UMP の仕様の表)。
    static func wordCount(ofType type: Int) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }

    /// システムの 1 語。拍を数える 5 種だけを読み、ほかは `nil` (読み飛ばす)。
    ///
    /// 曲の位置は 14 ビットで、データ 1 が下位 7 ビット・データ 2 が上位 7 ビット。
    private static func system(_ word: UInt32) -> MIDIMessage? {
        switch (word >> 16) & 0xFF {
        case 0xF8: .clock
        case 0xFA: .start
        case 0xFB: .continue
        case 0xFC: .stop
        case 0xF2: .songPosition(sixteenths: Int((word >> 8) & 0x7F) | Int(word & 0x7F) << 7)
        default: nil
        }
    }

    /// MIDI 1.0 チャンネルボイスの 1 語。読めない種類は `nil`。
    private static func channelVoice(_ word: UInt32) -> MIDIMessage? {
        let status = Int((word >> 16) & 0xF0)
        let channel = Int((word >> 16) & 0x0F) + 1
        let first = Int((word >> 8) & 0x7F)
        let second = Int(word & 0x7F)
        switch status {
        case 0x80: return .noteOff(channel: channel, note: first, velocity: second)
        // 速度 0 のノートオンは、そのまま返す。ノートオフにするのは入れ物 (``MIDIInbox/receive(_:hostTime:)``)
        // で、機材から届いたものも注入した列も同じ 1 か所を通す
        case 0x90: return .noteOn(channel: channel, note: first, velocity: second)
        case 0xB0: return .controlChange(channel: channel, controller: first, value: second)
        default: return nil
        }
    }
}
